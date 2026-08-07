import AppKit
import Foundation
import NoonmarkDiagnostics
import NoonmarkStorage

/// Drives the three-process diagnostic evidence closure used by `scripts/test-e2e`:
/// persist one failed sync, interrupt a second sync while it waits for the
/// repository lock, then prove that the restarted app can export the complete
/// evidence through its real Help-menu UI.
struct DiagnosticEvidenceClosureE2EAutomation: LaunchAutomationRunnable {
    private enum Mode {
        case seedFailure
        case stallAndReject
        case verifyRestartAndExport
    }

    private struct State: Codable, Equatable {
        var failedOperationID: UUID
        var failedIncidentID: UUID
        var stalledOperationID: UUID?
        var mutationIncidentID: UUID?
    }

    private static let privacySentinel =
        "E2E_PRIVATE_TASK_CONTENT_MUST_NOT_ENTER_DIAGNOSTICS_8D31A6"

    private let mode: Mode
    private let stateURL: URL
    private let resultURL: URL
    private let exportURL: URL?

    @MainActor
    static func fromCommandLine() -> Self? {
        let seeds = AppLaunchArguments.contains(
            "--e2e-diagnostic-evidence-seed-failure"
        )
        let stalls = AppLaunchArguments.contains(
            "--e2e-diagnostic-evidence-stall"
        )
        let restarts = AppLaunchArguments.contains(
            "--e2e-diagnostic-evidence-restart"
        )
        guard [seeds, stalls, restarts].filter(\.self).count == 1,
              Bundle.main.bundleIdentifier == "app.noonmark.mac.e2e",
              let statePath = AppLaunchArguments.value(
                  after: "--e2e-diagnostic-evidence-state-url"
              ),
              let resultPath = AppLaunchArguments.value(
                  after: "--e2e-diagnostic-evidence-result-url"
              ),
              isAbsolutePath(statePath),
              isAbsolutePath(resultPath),
              let rawLaunchToken = AppLaunchArguments.value(
                  after: "--e2e-diagnostic-evidence-launch-token"
              ),
              UUID(uuidString: rawLaunchToken)?.uuidString == rawLaunchToken,
              AppLaunchArguments.value(after: "--data-url") != nil,
              AppLaunchArguments.value(after: "--sync-folder-url") != nil
        else { return nil }

        let mode: Mode
        let exportURL: URL?
        if seeds {
            mode = .seedFailure
            exportURL = nil
        } else if stalls {
            mode = .stallAndReject
            exportURL = nil
        } else {
            guard let exportPath = AppLaunchArguments.value(
                after: "--e2e-diagnostic-evidence-export-url"
            ),
                isAbsolutePath(exportPath),
                exportPath != statePath,
                exportPath != resultPath
            else { return nil }
            mode = .verifyRestartAndExport
            exportURL = URL(fileURLWithPath: exportPath)
        }
        return Self(
            mode: mode,
            stateURL: URL(fileURLWithPath: statePath),
            resultURL: URL(fileURLWithPath: resultPath),
            exportURL: exportURL
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        Task { @MainActor in
            do {
                try validateIsolation(store)
                switch mode {
                case .seedFailure:
                    try await seedFailure(on: store)
                    try writeResult("ok: seed failure persisted")
                    E2EApplicationTermination.schedule()
                case .stallAndReject:
                    try await stallAndReject(on: store)
                    try writeResult("ready: stalled sync and rejected mutation")
                case .verifyRestartAndExport:
                    try await verifyRestartAndExport(on: store)
                    try writeResult("ok: restarted evidence exported through UI")
                    E2EApplicationTermination.schedule(after: 2)
                }
            } catch {
                try? writeResult("failed: \(error.localizedDescription)")
                E2EApplicationTermination.schedule()
            }
        }
    }

    @MainActor
    private func seedFailure(on store: NoonmarkStore) async throws {
        guard FileManager.default.fileExists(
            atPath: NoonmarkStore.configuredSyncFolderURL().path
        ) else {
            throw Failure.failed("invalid sync-root fixture is missing")
        }
        store.setDataMode(.localFirst)
        store.setLocalFirstSyncEndpoint(.localFolder)
        store.setLocalFirstSyncMode(.manual)
        store.setLocalFirstSyncEnabled(true)
        guard store.engine.preferences.dataMode == .localFirst,
              store.engine.preferences.localFirstSyncPolicy.endpoint == .localFolder,
              store.engine.preferences.localFirstSyncPolicy.mode == .manual,
              store.engine.preferences.localFirstSyncPolicy.enabled
        else {
            throw Failure.failed("local-folder manual sync policy was not installed")
        }

        store.syncLocalFolderNow()
        try await waitUntil("invalid sync root did not produce a failed status") {
            guard store.isLocalFirstSyncing == false,
                  let correlation = try persistedFailureCorrelation(
                      store,
                      expectedReason: .transportOrStorage
                  )
            else { return false }
            return store.operationFailureNotice?.context == .sync
                && store.operationFailureNotice?.diagnosticIncidentID
                == correlation.incidentID
        }
        guard let correlation = try persistedFailureCorrelation(
            store,
            expectedReason: .transportOrStorage
        ),
              let recorder = store.localDiagnosticRecorder
        else {
            throw Failure.failed("failed sync lost its persistent correlation")
        }
        let package = try await recorder.snapshotPackage()
        try assertFailedSync(
            package,
            operationID: correlation.operationID,
            incidentID: correlation.incidentID
        )
        try writeState(
            State(
                failedOperationID: correlation.operationID.rawValue,
                failedIncidentID: correlation.incidentID.rawValue,
                stalledOperationID: nil,
                mutationIncidentID: nil
            )
        )
    }

    @MainActor
    private func stallAndReject(on store: NoonmarkStore) async throws {
        var state = try readState()
        try await waitUntil("persisted sync failure was not restored") {
            store.operationFailureNotice?.context == .sync
                && store.operationFailureNotice?.diagnosticIncidentID?.rawValue
                == state.failedIncidentID
        }
        let snapshotBefore = store.engine.snapshot()
        store.syncLocalFolderNow()
        try await waitUntil("sync did not enter the external repository-lock wait") {
            guard store.isLocalFirstSyncing,
                  case let .localFirstSync(rawOperationID) =
                  store.exclusiveEngineOperation,
                  let recorder = store.localDiagnosticRecorder
            else { return false }
            let package = try await recorder.snapshotPackage()
            return package.activeOperations.contains {
                $0.id.rawValue == rawOperationID
                    && $0.kind == .localFirstSync
                    && $0.endpoint == .localFolder
                    && $0.lastStage == .transportLockWait
            }
        }
        guard case let .localFirstSync(stalledOperationID) =
            store.exclusiveEngineOperation
        else {
            throw Failure.failed("stalled sync operation identity disappeared")
        }

        store.quickText = Self.privacySentinel
        store.addQuickTask()
        guard store.engine.snapshot() == snapshotBefore,
              store.quickText == Self.privacySentinel,
              store.operationFailureNotice?.context == .taskMutation,
              let mutationIncidentID =
              store.operationFailureNotice?.diagnosticIncidentID
        else {
            throw Failure.failed("in-flight sync did not reject the exact task mutation")
        }
        let diagnosticOperationID = DiagnosticOperationID(
            rawValue: stalledOperationID
        )
        guard let recorder = store.localDiagnosticRecorder else {
            throw Failure.failed("file diagnostic recorder became unavailable")
        }
        try await waitUntil("mutation rejection was not durably recorded") {
            let package = try await recorder.snapshotPackage()
            return package.records.contains {
                $0.event.code == .mutationRejected
                    && $0.event.operationID == diagnosticOperationID
                    && $0.event.incidentID == mutationIncidentID
                    && $0.event.mutationContext == .task
                    && $0.event.mutationRejectionReason
                    == .exclusiveOperationInProgress
            }
        }
        let package = try await recorder.snapshotPackage()
        guard package.activeOperations.contains(where: {
            $0.id == diagnosticOperationID
                && $0.lastStage == .transportLockWait
        }) else {
            throw Failure.failed("stalled operation was not active at lock-wait stage")
        }
        state.stalledOperationID = stalledOperationID
        state.mutationIncidentID = mutationIncidentID.rawValue
        try writeState(state)
    }

    @MainActor
    private func verifyRestartAndExport(on store: NoonmarkStore) async throws {
        let state = try readState()
        guard let stalledOperationID = state.stalledOperationID,
              let mutationIncidentID = state.mutationIncidentID,
              let recorder = store.localDiagnosticRecorder,
              let exportURL
        else {
            throw Failure.failed("restart state is incomplete")
        }
        let failedOperationID = DiagnosticOperationID(
            rawValue: state.failedOperationID
        )
        let failedIncidentID = DiagnosticIncidentID(
            rawValue: state.failedIncidentID
        )
        let interruptedOperationID = DiagnosticOperationID(
            rawValue: stalledOperationID
        )
        let rejectedIncidentID = DiagnosticIncidentID(
            rawValue: mutationIncidentID
        )

        try await waitUntil("restart evidence did not converge") {
            let package = try await recorder.snapshotPackage()
            guard hasRestartEvidence(
                package,
                failedOperationID: failedOperationID,
                failedIncidentID: failedIncidentID,
                interruptedOperationID: interruptedOperationID,
                rejectedIncidentID: rejectedIncidentID
            ),
                let persistedCorrelation = try persistedFailureCorrelation(
                    store,
                    expectedReason: .operationInterrupted
                )
            else { return false }
            return persistedCorrelation.operationID == interruptedOperationID
                && persistedCorrelation.incidentID == rejectedIncidentID
                && store.operationFailureNotice?.context == .sync
                && store.operationFailureNotice?.diagnosticIncidentID
                == rejectedIncidentID
        }
        try requireAbsent(exportURL, description: "diagnostic export")
        guard AppViewTreeE2E.activateMainWindow() else {
            throw Failure.failed("main window could not become active for UI export")
        }
        try writeResult("ready: restart evidence converged")

        try await waitUntil(
            "external UI harness did not create the diagnostic export",
            attempts: 1200,
            delayNanoseconds: 50_000_000
        ) {
            FileManager.default.fileExists(atPath: exportURL.path)
        }
        let exportData = try Data(contentsOf: exportURL)
        guard exportData.count <= 8 * 1024 * 1024,
              exportData.range(of: Data(Self.privacySentinel.utf8)) == nil
        else {
            throw Failure.failed("diagnostic export exceeded its cap or leaked task text")
        }
        let decoder = JSONDecoder()
        let package = try decoder.decode(
            DiagnosticExportPackage.self,
            from: exportData
        )
        guard hasRestartEvidence(
            package,
            failedOperationID: failedOperationID,
            failedIncidentID: failedIncidentID,
            interruptedOperationID: interruptedOperationID,
            rejectedIncidentID: rejectedIncidentID
        ) else {
            throw Failure.failed("UI export omitted required cross-session evidence")
        }
        let health = await recorder.health()
        guard health.allocatedBytes <= 4 * 1024 * 1024 else {
            throw Failure.failed("managed diagnostics exceeded the four-megabyte cap")
        }
    }

    private func validateIsolation(_ store: NoonmarkStore) throws {
        guard AppLaunchArguments.validatedRuntimeProfile == .e2e,
              store.databaseURL != nil,
              store.dataRootProcessLease != nil,
              store.localDiagnosticRecorder != nil,
              let dataPath = AppLaunchArguments.value(after: "--data-url"),
              let syncPath = AppLaunchArguments.value(after: "--sync-folder-url"),
              dataPath.contains("e2e-diagnostic-closure"),
              syncPath.contains("e2e-diagnostic-closure")
        else {
            throw Failure.failed("diagnostic closure escaped the dedicated E2E profile")
        }
    }

    private func persistedFailureCorrelation(
        _ store: NoonmarkStore,
        expectedReason: SQLiteLocalFirstSyncFailureReason
    ) throws -> DiagnosticOperationCorrelation? {
        guard let databaseURL = store.databaseURL,
              let metadata = try SQLiteSyncRepository(databaseURL: databaseURL)
              .metadata(
                  for: SQLiteLocalFirstSyncCoordinator.lastStatusMetadataKey
              )
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let status = try decoder.decode(
            SQLiteLocalFirstSyncStatus.self,
            from: metadata.value
        )
        guard case let .failed(
            reason,
            _,
            _,
            diagnosticCorrelation
        ) = status,
            reason == expectedReason
        else { return nil }
        return diagnosticCorrelation
    }

    private func assertFailedSync(
        _ package: DiagnosticExportPackage,
        operationID: DiagnosticOperationID,
        incidentID: DiagnosticIncidentID
    ) throws {
        guard package.operationCapsules.contains(where: {
            $0.operationID == operationID
                && $0.incidentID == incidentID
                && $0.kind == .localFirstSync
                && $0.endpoint == .localFolder
                && $0.outcome == .failed
        }) else {
            throw Failure.failed("failed sync capsule lost its exact correlation")
        }
    }

    private func hasRestartEvidence(
        _ package: DiagnosticExportPackage,
        failedOperationID: DiagnosticOperationID,
        failedIncidentID: DiagnosticIncidentID,
        interruptedOperationID: DiagnosticOperationID,
        rejectedIncidentID: DiagnosticIncidentID
    ) -> Bool {
        let failedCapsule = package.operationCapsules.contains {
            $0.operationID == failedOperationID
                && $0.incidentID == failedIncidentID
                && $0.kind == .localFirstSync
                && $0.endpoint == .localFolder
                && $0.outcome == .failed
        }
        let interruptedCapsule = package.operationCapsules.contains {
            $0.operationID == interruptedOperationID
                && $0.incidentID == rejectedIncidentID
                && $0.kind == .localFirstSync
                && $0.endpoint == .localFolder
                && $0.lastStage == .transportLockWait
                && $0.outcome == .interrupted
        }
        let interruptedEvent = package.records.contains {
            $0.event.code == .previousSessionInterrupted
                && $0.event.operationID == interruptedOperationID
                && $0.event.incidentID == rejectedIncidentID
                && $0.event.operationKind == .localFirstSync
                && $0.event.endpoint == .localFolder
                && $0.event.stage == .transportLockWait
        }
        let rejection = package.records.contains {
            $0.event.code == .mutationRejected
                && $0.event.operationID == interruptedOperationID
                && $0.event.incidentID == rejectedIncidentID
                && $0.event.mutationContext == .task
                && $0.event.mutationRejectionReason
                == .exclusiveOperationInProgress
        }
        let restoredFailure = package.records.contains {
            $0.event.code == .persistedSyncFailureLoaded
                && $0.event.operationID == interruptedOperationID
                && $0.event.incidentID == rejectedIncidentID
        }
        return failedCapsule
            && interruptedCapsule
            && interruptedEvent
            && rejection
            && restoredFailure
    }

    private func waitUntil(
        _ message: String,
        attempts: Int = 400,
        delayNanoseconds: UInt64 = 25_000_000,
        condition: @MainActor () async throws -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if try await condition() {
                return
            }
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        throw Failure.failed(message)
    }

    private func readState() throws -> State {
        let decoder = JSONDecoder()
        return try decoder.decode(State.self, from: Data(contentsOf: stateURL))
    }

    private func writeState(_ state: State) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    private func writeResult(_ value: String) throws {
        try value.write(to: resultURL, atomically: true, encoding: .utf8)
    }

    private func requireAbsent(_ url: URL, description: String) throws {
        guard FileManager.default.fileExists(atPath: url.path) == false else {
            throw Failure.failed("\(description) already exists")
        }
    }

    private static func isAbsolutePath(_ path: String) -> Bool {
        path.hasPrefix("/")
            && path.unicodeScalars.allSatisfy {
                CharacterSet.controlCharacters.contains($0) == false
            }
            && URL(fileURLWithPath: path).standardizedFileURL.path == path
    }

    private enum Failure: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(message):
                message
            }
        }
    }
}
