import AppKit
import Foundation
import NoonmarkDiagnostics
import NoonmarkStorage

/// Drives the V2 three-process diagnostic closure used by `scripts/test-e2e`:
/// persist one failed reconcile, interrupt another while the endpoint is
/// blocked, then prove that the restarted App can export the complete typed
/// evidence through its real Help-menu UI. The blocked endpoint must not hold
/// a mutation lease, so an ordinary task mutation succeeds; an independently
/// injected persistence failure must still reject the next mutation and bind
/// that evidence to the active sync operation.
struct DiagnosticEvidenceClosureE2EAutomation: LaunchAutomationRunnable {
    private enum Mode {
        case seedFailure
        case stallAndMutate
        case verifyRestartAndExport
    }

    private struct State: Codable, Equatable {
        var failedOperationID: UUID
        var failedIncidentID: UUID
        var stalledOperationID: UUID?
        var rejectedMutationIncidentID: UUID?
        var taskCountAfterMutation: Int?
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
              AppLaunchArguments.contains(
                  "--e2e-replication-v2-lifecycle-endpoint"
              ),
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
            mode = .stallAndMutate
            exportURL = nil
        } else {
            guard let exportPath = AppLaunchArguments.value(
                after: "--e2e-diagnostic-evidence-export-url"
            ), isAbsolutePath(exportPath),
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
                    try writeResult("ok: V2 seed failure persisted")
                    E2EApplicationTermination.schedule()
                case .stallAndMutate:
                    try await stallAndMutate(on: store)
                    try writeResult(
                        "ready: stalled V2 sync committed and rejected exact mutations"
                    )
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
        store.setDataMode(.localFirst)
        store.setLocalFirstSyncEndpoint(.localFolder)
        store.setLocalFirstSyncMode(.manual)
        store.setLocalFirstSyncEnabled(true)
        try await requireConfiguredRuntime(on: store)
        guard let endpoint = store.localFirstReplicationLifecycleE2EEndpoint,
              await endpoint.armReadFailure()
        else {
            throw Failure.failed("V2 diagnostic failure seam is unavailable")
        }

        store.syncLocalFolderNow()
        guard let command = store.localFirstReplicationCommandTask else {
            throw Failure.failed("V2 diagnostic failure reconcile did not start")
        }
        _ = await command.result
        guard let recorder = store.localDiagnosticRecorder else {
            throw Failure.failed("file diagnostic recorder is unavailable")
        }
        var failedCapsule: DiagnosticOperationCapsule?
        try await waitUntil("V2 failure did not persist exact diagnostics") {
            guard let incidentID = store.operationFailureNotice?
                .diagnosticIncidentID
            else { return false }
            let package = try await recorder.snapshotPackage()
            failedCapsule = package.operationCapsules.first {
                $0.incidentID == incidentID
                    && $0.kind == .localFirstSync
                    && $0.endpoint == .localFolder
                    && $0.outcome == .failed
            }
            return failedCapsule != nil
        }
        guard let failedCapsule,
              let failedIncidentID = failedCapsule.incidentID
        else {
            throw Failure.failed("V2 failed sync lost its correlation")
        }
        try writeState(
            State(
                failedOperationID: failedCapsule.operationID.rawValue,
                failedIncidentID: failedIncidentID.rawValue,
                stalledOperationID: nil,
                rejectedMutationIncidentID: nil,
                taskCountAfterMutation: nil
            )
        )
    }

    @MainActor
    private func stallAndMutate(on store: NoonmarkStore) async throws {
        var state = try readState()
        try await requireConfiguredRuntime(on: store)
        guard let endpoint = store.localFirstReplicationLifecycleE2EEndpoint,
              await endpoint.armBlockingRead()
        else {
            throw Failure.failed("V2 diagnostic blocking seam is unavailable")
        }
        guard let recorder = store.localDiagnosticRecorder else {
            throw Failure.failed("file diagnostic recorder is unavailable")
        }
        let taskCountBefore = store.engine.snapshot().definitions.count
        store.syncLocalFolderNow()
        guard store.localFirstReplicationCommandTask != nil else {
            throw Failure.failed("V2 diagnostic stalled reconcile did not start")
        }
        try await waitUntil("V2 sync did not enter endpoint wait") {
            await endpoint.isReadBlocked()
        }
        var stalledOperation: DiagnosticActiveOperation?
        try await waitUntil("V2 stalled operation was not durably active") {
            let package = try await recorder.snapshotPackage()
            stalledOperation = package.activeOperations.first {
                $0.kind == .localFirstSync
                    && $0.endpoint == .localFolder
                    && $0.lastStage == .transportPrepare
            }
            return stalledOperation != nil
        }

        store.quickText = Self.privacySentinel
        store.addQuickTask()
        let taskCountAfter = store.engine.snapshot().definitions.count
        guard store.quickText.isEmpty,
              taskCountAfter == taskCountBefore + 1,
              store.operationFailureNotice?.context != .taskMutation
        else {
            throw Failure.failed(
                "V2 endpoint wait rejected an ordinary local mutation"
            )
        }
        let package = try await recorder.snapshotPackage()
        guard package.records.contains(where: {
            $0.event.code == .mutationRejected
                && $0.event.operationID == stalledOperation?.id
        }) == false,
            let stalledOperation
        else {
            throw Failure.failed(
                "V2 endpoint wait emitted a mutation rejection"
            )
        }
        try store.armPersistenceFailureForE2E()
        store.quickText = Self.privacySentinel + "_REJECTED"
        store.addQuickTask()
        store.disarmPersistenceFailureForE2E()
        guard store.quickText.isEmpty == false,
              store.engine.snapshot().definitions.count == taskCountAfter,
              store.operationFailureNotice?.context == .taskMutation
        else {
            throw Failure.failed(
                "V2 persistence failure did not reject the exact mutation"
            )
        }
        var rejectedIncidentID: DiagnosticIncidentID?
        try await waitUntil("V2 rejected mutation lost sync correlation") {
            let package = try await recorder.snapshotPackage()
            rejectedIncidentID = package.records.first {
                $0.event.code == .mutationRejected
                    && $0.event.operationID == stalledOperation.id
            }?.event.incidentID
            return rejectedIncidentID != nil
        }
        store.quickText = ""
        state.stalledOperationID = stalledOperation.id.rawValue
        state.rejectedMutationIncidentID = rejectedIncidentID?.rawValue
        state.taskCountAfterMutation = taskCountAfter
        try writeState(state)
    }

    @MainActor
    private func verifyRestartAndExport(on store: NoonmarkStore) async throws {
        let state = try readState()
        guard let stalledOperationID = state.stalledOperationID,
              let rejectedMutationIncidentID = state.rejectedMutationIncidentID,
              let taskCountAfterMutation = state.taskCountAfterMutation,
              store.engine.snapshot().definitions.count
              == taskCountAfterMutation,
              let recorder = store.localDiagnosticRecorder,
              let exportURL
        else {
            throw Failure.failed("V2 diagnostic restart state is incomplete")
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
            rawValue: rejectedMutationIncidentID
        )

        try await waitUntil("V2 restart evidence did not converge") {
            let package = try await recorder.snapshotPackage()
            return hasRestartEvidence(
                package,
                failedOperationID: failedOperationID,
                failedIncidentID: failedIncidentID,
                interruptedOperationID: interruptedOperationID,
                rejectedMutationIncidentID: rejectedIncidentID
            ) && store.operationFailureNotice == nil
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
            throw Failure.failed(
                "diagnostic export exceeded its cap or leaked task text"
            )
        }
        let package = try JSONDecoder().decode(
            DiagnosticExportPackage.self,
            from: exportData
        )
        guard hasRestartEvidence(
            package,
            failedOperationID: failedOperationID,
            failedIncidentID: failedIncidentID,
            interruptedOperationID: interruptedOperationID,
            rejectedMutationIncidentID: rejectedIncidentID
        ) else {
            throw Failure.failed("UI export omitted V2 cross-session evidence")
        }
        let health = await recorder.health()
        guard health.allocatedBytes <= 4 * 1024 * 1024 else {
            throw Failure.failed("managed diagnostics exceeded its capacity cap")
        }
    }

    @MainActor
    private func requireConfiguredRuntime(on store: NoonmarkStore) async throws {
        for _ in 0 ..< 8 {
            guard let task = store.localFirstReplicationConfigurationTask else {
                await Task.yield()
                continue
            }
            _ = await task.result
            await Task.yield()
        }
        guard store.localFirstReplicationRuntime != nil else {
            throw Failure.failed("V2 diagnostic runtime did not settle")
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
            throw Failure.failed(
                "diagnostic closure escaped the dedicated E2E profile"
            )
        }
    }

    private func hasRestartEvidence(
        _ package: DiagnosticExportPackage,
        failedOperationID: DiagnosticOperationID,
        failedIncidentID: DiagnosticIncidentID,
        interruptedOperationID: DiagnosticOperationID,
        rejectedMutationIncidentID: DiagnosticIncidentID
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
                && $0.incidentID == rejectedMutationIncidentID
                && $0.kind == .localFirstSync
                && $0.endpoint == .localFolder
                && $0.lastStage == .transportPrepare
                && $0.outcome == .interrupted
        }
        let interruptedEvent = package.records.contains {
            $0.event.code == .previousSessionInterrupted
                && $0.event.operationID == interruptedOperationID
                && $0.event.incidentID == rejectedMutationIncidentID
                && $0.event.operationKind == .localFirstSync
                && $0.event.endpoint == .localFolder
                && $0.event.stage == .transportPrepare
        }
        let rejectedMutation = package.records.contains {
            $0.event.code == .mutationRejected
                && $0.event.operationID == interruptedOperationID
                && $0.event.incidentID == rejectedMutationIncidentID
        }
        return failedCapsule
            && interruptedCapsule
            && interruptedEvent
            && rejectedMutation
    }

    private func waitUntil(
        _ message: String,
        attempts: Int = 400,
        delayNanoseconds: UInt64 = 25_000_000,
        condition: @MainActor () async throws -> Bool
    ) async throws {
        for _ in 0 ..< attempts {
            if try await condition() {
                return
            }
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        throw Failure.failed(message)
    }

    private func readState() throws -> State {
        try JSONDecoder().decode(
            State.self,
            from: Data(contentsOf: stateURL)
        )
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
            case let .failed(message): message
            }
        }
    }
}
