import AppKit
import CryptoKit
import Darwin
import Foundation
import NoonmarkCore
import NoonmarkDiagnostics
import NoonmarkStorage
import NoonmarkSync

@MainActor
struct ReplicationV2StressE2EAutomation: LaunchAutomationRunnable {
    private enum Mode: String {
        case exercise
        case verifyRestart = "verify-restart"
        case authorityFault = "authority-fault"
    }

    private enum EndpointMode: Equatable {
        case localFolder
        case iCloud

        var kind: CloudSyncEndpointKind {
            switch self {
            case .localFolder: .localFolder
            case .iCloud: .iCloud
            }
        }
    }

    private enum FailureCode: String, Error {
        case wrongRuntimeProfile = "wrong-runtime-profile"
        case databaseMismatch = "database-mismatch"
        case unsafeBackup = "unsafe-backup"
        case configurationDidNotSettle = "configuration-did-not-settle"
        case importLeakedSyncState = "import-leaked-sync-state"
        case syncCommandMissing = "sync-command-missing"
        case syncDidNotEnterRunningState = "sync-did-not-enter-running-state"
        case syncIncidentDetected = "sync-incident-detected"
        case syncDidNotConverge = "sync-did-not-converge"
        case syncTimestampMissing = "sync-timestamp-missing"
        case authorityMissing = "authority-missing"
        case outboxNotDrained = "outbox-not-drained"
        case diagnosticsMissing = "diagnostics-missing"
        case diagnosticFailure = "diagnostic-failure"
        case mutationWasRejected = "mutation-was-rejected"
        case restartStateMismatch = "restart-state-mismatch"
        case mixedTaskDecorationFailed = "mixed-task-decoration-failed"
        case mixedSchedulingFailed = "mixed-scheduling-failed"
        case mixedCompletionFailed = "mixed-completion-failed"
        case mixedIdeaCreateFailed = "mixed-idea-create-failed"
        case mixedIdeaEditFailed = "mixed-idea-edit-failed"
        case mixedIdeaDeleteFailed = "mixed-idea-delete-failed"
        case mixedSettingsFailed = "mixed-settings-failed"
        case iCloudRoundUnavailable = "icloud-round-unavailable"
        case authorityMarkerWriteFailed = "authority-marker-write-failed"
        case authorityWasAccepted = "authority-was-accepted"
        case authorityLedgerMutated = "authority-ledger-mutated"
        case authorityRepositoryMutated = "authority-repository-mutated"
        case authorityErrorMissing = "authority-error-missing"
        case stateFileInvalid = "state-file-invalid"
        case resultWriteFailed = "result-write-failed"
    }

    private struct StagedFailure: Error {
        let code: FailureCode
        let underlyingErrorKind: String
    }

    private struct SnapshotCounts: Codable, Equatable {
        let days: Int
        let chains: Int
        let definitions: Int
        let traces: Int
        let subtasks: Int
        let ideas: Int
        let activeNotes: Int
        let plannedSubtasks: Int
        let completedTraces: Int
        let activeIdeas: Int
        let theme: String

        init(_ snapshot: NoonmarkSnapshot) {
            days = snapshot.days.count
            chains = snapshot.chains.count
            definitions = snapshot.definitions.count
            traces = snapshot.traces.count
            subtasks = snapshot.subtasks.count
            ideas = snapshot.ideas.count
            activeNotes = snapshot.chains.reduce(into: 0) { count, chain in
                count += chain.activeNoteEntries.count
            }
            plannedSubtasks = snapshot.definitions.reduce(into: 0) {
                count,
                definition in
                count += definition.plannedSubtasks.count
            }
            completedTraces = snapshot.traces.count {
                $0.status == .completed
            }
            activeIdeas = snapshot.ideas.count { $0.deletedAt == nil }
            theme = snapshot.preferences.theme.rawValue
        }
    }

    private struct RestartState: Codable {
        let afterExerciseSnapshot: SnapshotCounts
        let afterExercisePoolCount: Int
        let importedTaskCount: Int
    }

    private struct DiagnosticCounts {
        let succeededSyncOperations: Int
        let failedSyncOperations: Int
        let mutationRejections: Int
        let firstFailure: DiagnosticFailure?
        let firstFailureStage: DiagnosticOperationStage?
    }

    private struct WorkloadCounts {
        let importedTasks: Int
        let created: Int
        let edited: Int
        let deleted: Int
        let mixedDomainMutations: Int
        let syncRuns: Int
    }

    private struct StressResult: Codable {
        let status: String
        let phase: String
        let errorCode: String?
        let underlyingErrorKind: String?
        let authorityErrorVerdict: String?
        let importedTaskCount: Int
        let createdCount: Int
        let editedCount: Int
        let deletedCount: Int
        let mixedDomainMutationCount: Int
        let syncRunCount: Int
        let pendingOutboxCount: Int
        let confirmedOutboxCount: Int
        let lastSyncedPresent: Bool
        let lastEffectiveSyncedPresent: Bool
        let convergence: String
        let diagnosticSyncSucceededCount: Int
        let diagnosticSyncFailedCount: Int
        let mutationRejectionCount: Int
        let diagnosticFailureDomain: String?
        let diagnosticFailureCode: Int?
        let diagnosticFailureStage: String?
        let sqliteFailurePoint: String?
    }

    private static let e2eBundleIdentifier = "app.noonmark.mac.e2e"
    private static let exerciseCreateCount = 120
    private static let exerciseEditCount = 80
    private static let exerciseDeleteCount = 40
    private static let restartCreateCount = 30
    private static let restartEditCount = 20
    private static let restartDeleteCount = 10
    private static let syncBatchSize = 20
    private static let incompatibleAuthorityGenerationID = UUID(
        uuidString: "97000000-0000-0000-0000-000000000099"
    )!

    private let mode: Mode
    private let backupURL: URL?
    private let stateURL: URL
    private let resultURL: URL
    private let databaseURL: URL
    private let endpointMode: EndpointMode
    private let iCloudSessionID: UUID?
    private let iCloudRoundID: UUID?

    static func fromCommandLine() -> Self? {
        guard Bundle.main.bundleIdentifier == "app.noonmark.mac.e2e" else {
            return nil
        }
        let mode: Mode
        if AppLaunchArguments.contains(
            "--e2e-replication-v2-stress-exercise"
        ) {
            mode = .exercise
        } else if AppLaunchArguments.contains(
            "--e2e-replication-v2-stress-verify-restart"
        ) {
            mode = .verifyRestart
        } else if AppLaunchArguments.contains(
            "--e2e-replication-v2-stress-authority-fault"
        ) {
            mode = .authorityFault
        } else {
            return nil
        }
        let usesLocalFolder = AppLaunchArguments.contains(
            "--e2e-replication-v2-stress-local-folder"
        )
        let usesICloud = AppLaunchArguments.contains(
            "--e2e-replication-v2-stress-icloud"
        )
        guard [usesLocalFolder, usesICloud].filter(\.self).count == 1,
            let statePath = AppLaunchArguments.value(
                after: "--e2e-replication-v2-stress-state-url"
            ),
            let resultPath = AppLaunchArguments.value(
                after: "--e2e-replication-v2-stress-result-url"
            ),
            let databasePath = AppLaunchArguments.value(after: "--data-url")
        else {
            return nil
        }
        let endpointMode: EndpointMode = usesLocalFolder
            ? .localFolder
            : .iCloud
        let iCloudSessionID = AppLaunchArguments.value(
            after: "--e2e-replication-v2-stress-icloud-session-id"
        ).flatMap(UUID.init(uuidString:))
        let iCloudRoundID = AppLaunchArguments.value(
            after: "--e2e-replication-v2-stress-icloud-round-id"
        ).flatMap(UUID.init(uuidString:))
        guard endpointMode == .localFolder
                || (iCloudSessionID != nil && iCloudRoundID != nil)
        else { return nil }
        guard mode != .authorityFault || endpointMode == .iCloud else {
            return nil
        }
        let backupURL = AppLaunchArguments.value(
            after: "--e2e-replication-v2-stress-backup-url"
        ).map { URL(fileURLWithPath: $0) }
        guard mode != .exercise || backupURL != nil else { return nil }
        return Self(
            mode: mode,
            backupURL: backupURL,
            stateURL: URL(fileURLWithPath: statePath),
            resultURL: URL(fileURLWithPath: resultPath),
            databaseURL: URL(fileURLWithPath: databasePath),
            endpointMode: endpointMode,
            iCloudSessionID: iCloudSessionID,
            iCloudRoundID: iCloudRoundID
        )
    }

    func run(on store: NoonmarkStore) {
        Task { @MainActor in
            let result: StressResult
            do {
                try validateBoundary(on: store)
                switch mode {
                case .exercise:
                    result = try await exercise(on: store)
                case .verifyRestart:
                    result = try await verifyRestart(on: store)
                case .authorityFault:
                    result = try await exerciseAuthorityFault(on: store)
                }
            } catch {
                let stagedFailure = error as? StagedFailure
                let code = stagedFailure?.code.rawValue
                    ?? (error as? FailureCode)?.rawValue
                    ?? "unexpected-\(String(describing: type(of: error)))"
                let diagnostics = await diagnosticCounts(on: store)
                result = StressResult(
                    status: "failed",
                    phase: mode.rawValue,
                    errorCode: code,
                    underlyingErrorKind:
                    stagedFailure?.underlyingErrorKind,
                    authorityErrorVerdict:
                    store.localFirstReplicationLastAuthorityVerdict,
                    importedTaskCount: 0,
                    createdCount: 0,
                    editedCount: 0,
                    deletedCount: 0,
                    mixedDomainMutationCount: 0,
                    syncRunCount: 0,
                    pendingOutboxCount: -1,
                    confirmedOutboxCount: -1,
                    lastSyncedPresent: false,
                    lastEffectiveSyncedPresent: false,
                    convergence: "unknown",
                    diagnosticSyncSucceededCount:
                    diagnostics?.succeededSyncOperations ?? 0,
                    diagnosticSyncFailedCount:
                    diagnostics?.failedSyncOperations ?? 0,
                    mutationRejectionCount:
                    diagnostics?.mutationRejections ?? 0,
                    diagnosticFailureDomain:
                    diagnostics?.firstFailure?.domain.rawValue,
                    diagnosticFailureCode: diagnostics?.firstFailure?.code,
                    diagnosticFailureStage:
                    diagnostics?.firstFailureStage?.rawValue,
                    sqliteFailurePoint:
                    store.localFirstReplicationLastSQLiteFailurePoint
                        ?? appSQLiteFailurePoint(error)
                )
            }
            do {
                try write(result, to: resultURL)
            } catch {
                try? write(
                    StressResult(
                        status: "failed",
                        phase: mode.rawValue,
                        errorCode: FailureCode.resultWriteFailed.rawValue,
                        underlyingErrorKind: nil,
                        authorityErrorVerdict: nil,
                        importedTaskCount: 0,
                        createdCount: 0,
                        editedCount: 0,
                        deletedCount: 0,
                        mixedDomainMutationCount: 0,
                        syncRunCount: 0,
                        pendingOutboxCount: -1,
                        confirmedOutboxCount: -1,
                        lastSyncedPresent: false,
                        lastEffectiveSyncedPresent: false,
                        convergence: "unknown",
                        diagnosticSyncSucceededCount: 0,
                        diagnosticSyncFailedCount: 0,
                        mutationRejectionCount: 0,
                        diagnosticFailureDomain: nil,
                        diagnosticFailureCode: nil,
                        diagnosticFailureStage: nil,
                        sqliteFailurePoint: nil
                    ),
                    to: resultURL
                )
            }
            E2EApplicationTermination.schedule()
        }
    }

    private func validateBoundary(on store: NoonmarkStore) throws {
        guard try AppLaunchArguments.runtimeProfile == .e2e else {
            throw FailureCode.wrongRuntimeProfile
        }
        guard store.databaseURL?.standardizedFileURL
            == databaseURL.standardizedFileURL
        else {
            throw FailureCode.databaseMismatch
        }
        switch endpointMode {
        case .localFolder:
            guard AppLaunchArguments.value(after: "--sync-folder-url") != nil,
                  iCloudSessionID == nil,
                  iCloudRoundID == nil
            else {
                throw FailureCode.configurationDidNotSettle
            }
        case .iCloud:
            guard AppLaunchArguments.value(after: "--sync-folder-url") == nil,
                  let iCloudSessionID,
                  let iCloudRoundID
            else {
                throw FailureCode.configurationDidNotSettle
            }
            guard mode == .verifyRestart else { return }
            do {
                _ = try ICloudAppendOnlyTestNamespace.reopenRound(
                    sessionID: iCloudSessionID,
                    roundID: iCloudRoundID
                )
            } catch {
                throw FailureCode.iCloudRoundUnavailable
            }
        }
    }

    private func exerciseAuthorityFault(
        on store: NoonmarkStore
    ) async throws -> StressResult {
        guard endpointMode == .iCloud,
              let iCloudSessionID,
              let iCloudRoundID
        else {
            throw FailureCode.iCloudRoundUnavailable
        }
        await settleConfiguration(on: store)
        let ledger = SQLiteReplicationLedger(databaseURL: databaseURL)
        guard store.localFirstReplicationRuntime == nil,
              try ledger.cleanCutAuthority() == nil,
              try LocalFirstReplication.persistedState(
                  databaseURL: databaseURL
              ) == nil
        else {
            throw FailureCode.authorityLedgerMutated
        }

        let round: ICloudAppendOnlyTestRound
        do {
            let session = try ICloudAppendOnlyTestNamespace.beginSession(
                sessionID: iCloudSessionID
            )
            round = try ICloudAppendOnlyTestNamespace.createRound(
                in: session,
                roundID: iCloudRoundID
            )
        } catch {
            throw FailureCode.iCloudRoundUnavailable
        }
        do {
            try writeExclusiveAuthorityMarker(
                in: round,
                generationID: Self.incompatibleAuthorityGenerationID
            )
        } catch {
            throw FailureCode.authorityMarkerWriteFailed
        }
        let inventoryBefore = try roundInventory(at: round.rootURL)
        guard inventoryBefore.count == 1,
              inventoryBefore[
                  FileReplicationRepositoryBootstrap.markerFilename
              ] != nil
        else {
            throw FailureCode.authorityRepositoryMutated
        }

        store.setLocalFirstSyncEndpoint(endpointMode.kind)
        store.setLocalFirstSyncMode(.manual)
        store.setLocalFirstSyncEnabled(true)
        await settleConfiguration(on: store)

        guard store.engine.preferences.localFirstSyncPolicy.enabled,
              store.engine.preferences.localFirstSyncPolicy.endpoint == .iCloud
        else {
            throw FailureCode.configurationDidNotSettle
        }
        guard store.localFirstReplicationRuntime == nil else {
            throw FailureCode.authorityWasAccepted
        }
        guard try ledger.cleanCutAuthority() == nil,
              try LocalFirstReplication.persistedState(
                  databaseURL: databaseURL
              ) == nil
        else {
            throw FailureCode.authorityLedgerMutated
        }
        guard store.localFirstReplicationLastErrorKind
            == "ICloudReplicationRepositoryAuthorityError",
            store.localFirstReplicationLastAuthorityVerdict
            == ICloudReplicationRepositoryAuthorityError
                .divergentMarkerVersion.rawValue,
            let failureMessage = store.localFirstSyncMessage,
            failureMessage.isEmpty == false
        else {
            throw FailureCode.authorityErrorMissing
        }
        let outbox = try ledger.outboxSnapshot(
            generationID: Self.incompatibleAuthorityGenerationID
        )
        guard outbox.pendingCount == 0, outbox.confirmedCount == 0 else {
            throw FailureCode.authorityLedgerMutated
        }
        let inventoryAfter = try roundInventory(at: round.rootURL)
        guard inventoryBefore == inventoryAfter else {
            throw FailureCode.authorityRepositoryMutated
        }
        guard let diagnostics = await diagnosticCounts(on: store) else {
            throw FailureCode.diagnosticsMissing
        }
        guard diagnostics.failedSyncOperations == 0,
              diagnostics.mutationRejections == 0
        else {
            throw FailureCode.diagnosticFailure
        }
        return StressResult(
            status: "ok",
            phase: mode.rawValue,
            errorCode: nil,
            underlyingErrorKind:
            store.localFirstReplicationLastErrorKind,
            authorityErrorVerdict:
            store.localFirstReplicationLastAuthorityVerdict,
            importedTaskCount: 0,
            createdCount: 0,
            editedCount: 0,
            deletedCount: 0,
            mixedDomainMutationCount: 0,
            syncRunCount: 0,
            pendingOutboxCount: outbox.pendingCount,
            confirmedOutboxCount: outbox.confirmedCount,
            lastSyncedPresent: false,
            lastEffectiveSyncedPresent: false,
            convergence: "blocked-authority",
            diagnosticSyncSucceededCount:
            diagnostics.succeededSyncOperations,
            diagnosticSyncFailedCount: diagnostics.failedSyncOperations,
            mutationRejectionCount: diagnostics.mutationRejections,
            diagnosticFailureDomain: nil,
            diagnosticFailureCode: nil,
            diagnosticFailureStage: nil,
            sqliteFailurePoint: nil
        )
    }

    private func exercise(on store: NoonmarkStore) async throws
        -> StressResult
    {
        guard let backupURL, try isOwnerRegularFile(backupURL) else {
            throw FailureCode.unsafeBackup
        }
        await settleConfiguration(on: store)
        let preview = try await store.prepareDataImport(from: backupURL)
        try await store.commitDataImport(
            preview,
            confirmation: .confirmed(previewID: preview.id)
        )

        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let ledger = SQLiteReplicationLedger(databaseURL: databaseURL)
        guard try syncRepository.journalEntries().isEmpty,
              try ledger.cleanCutAuthority() == nil
        else {
            throw FailureCode.importLeakedSyncState
        }
        let importedTaskCount = preview.summary.taskCount

        if endpointMode == .iCloud {
            guard let iCloudSessionID, let iCloudRoundID else {
                throw FailureCode.iCloudRoundUnavailable
            }
            do {
                let session = try ICloudAppendOnlyTestNamespace.beginSession(
                    sessionID: iCloudSessionID
                )
                _ = try ICloudAppendOnlyTestNamespace.createRound(
                    in: session,
                    roundID: iCloudRoundID
                )
            } catch {
                throw FailureCode.iCloudRoundUnavailable
            }
        }
        store.setLocalFirstSyncEndpoint(endpointMode.kind)
        store.setLocalFirstSyncMode(.manual)
        store.setLocalFirstSyncEnabled(true)
        try await requireConfiguration(on: store)
        guard store.engine.preferences.localFirstSyncPolicy.enabled,
              store.engine.preferences.localFirstSyncPolicy.endpoint
              == endpointMode.kind
        else {
            throw FailureCode.configurationDidNotSettle
        }

        var createdIDs: [TaskChainID] = []
        var syncRuns = 0

        // Start the large imported baseline, wait until the real Runtime reports
        // running, then commit through the normal Store lane. This is the
        // symptom-level guard against sync refusing ordinary user edits.
        let overlapping = try await syncWhileCreatingFirstTask(on: store)
        createdIDs.append(overlapping.chainID)
        syncRuns += overlapping.syncAttempts
        _ = try await runSyncPass(on: store)
        syncRuns += 1
        // Fail at the first overlap boundary so later successful retries cannot
        // bury the exact user-visible refusal mechanism in a long stress run.
        _ = try await requireHealthyDiagnostics(on: store)

        for index in 1 ..< Self.exerciseCreateCount {
            createdIDs.append(try createTask(index: index, on: store))
            if (index + 1).isMultiple(of: Self.syncBatchSize) {
                _ = try await runSyncPass(on: store)
                syncRuns += 1
            }
        }
        for index in 0 ..< Self.exerciseEditCount {
            try editTask(createdIDs[index], index: index, on: store)
            if (index + 1).isMultiple(of: Self.syncBatchSize) {
                _ = try await runSyncPass(on: store)
                syncRuns += 1
            }
        }
        for index in 0 ..< Self.exerciseDeleteCount {
            try deleteTask(createdIDs[index], on: store)
            if (index + 1).isMultiple(of: Self.syncBatchSize) {
                _ = try await runSyncPass(on: store)
                syncRuns += 1
            }
        }
        let mixedDomainMutationCount = try exerciseMixedDomainMutations(
            taskIDs: Array(
                createdIDs[
                    Self.exerciseDeleteCount ..< Self.exerciseDeleteCount + 10
                ]
            ),
            on: store
        )
        syncRuns += try await runSync(on: store)

        let finalState = try requireConvergedState()
        let authority = try requireAuthority(ledger)
        let outbox = try ledger.outboxSnapshot(
            generationID: authority.generationID
        )
        guard outbox.pendingCount == 0 else {
            throw FailureCode.outboxNotDrained
        }
        let diagnostics = try await requireHealthyDiagnostics(on: store)
        let restartState = RestartState(
            afterExerciseSnapshot: SnapshotCounts(store.engine.snapshot()),
            afterExercisePoolCount: store.engine.taskPoolCount(),
            importedTaskCount: importedTaskCount
        )
        try write(restartState, to: stateURL)
        return makeSuccessResult(
            workload: WorkloadCounts(
                importedTasks: importedTaskCount,
                created: Self.exerciseCreateCount,
                edited: Self.exerciseEditCount,
                deleted: Self.exerciseDeleteCount,
                mixedDomainMutations: mixedDomainMutationCount,
                syncRuns: syncRuns
            ),
            state: finalState,
            outbox: outbox,
            diagnostics: diagnostics
        )
    }

    private func verifyRestart(on store: NoonmarkStore) async throws
        -> StressResult
    {
        let restartState: RestartState
        do {
            restartState = try read(RestartState.self, from: stateURL)
        } catch {
            throw FailureCode.stateFileInvalid
        }
        guard SnapshotCounts(store.engine.snapshot())
            == restartState.afterExerciseSnapshot,
            store.engine.taskPoolCount() == restartState.afterExercisePoolCount
        else {
            throw FailureCode.restartStateMismatch
        }
        try await requireConfiguration(on: store)
        var syncRuns = 0
        syncRuns += try await runSync(on: store)

        var createdIDs: [TaskChainID] = []
        for index in 0 ..< Self.restartCreateCount {
            createdIDs.append(try createTask(index: 10000 + index, on: store))
            if (index + 1).isMultiple(of: Self.syncBatchSize) {
                _ = try await runSyncPass(on: store)
                syncRuns += 1
            }
        }
        for index in 0 ..< Self.restartEditCount {
            try editTask(createdIDs[index], index: 10000 + index, on: store)
        }
        syncRuns += try await runSync(on: store)
        for index in 0 ..< Self.restartDeleteCount {
            try deleteTask(createdIDs[index], on: store)
        }
        syncRuns += try await runSync(on: store)

        guard store.engine.taskPoolCount()
            == restartState.afterExercisePoolCount
            + Self.restartCreateCount - Self.restartDeleteCount
        else {
            throw FailureCode.restartStateMismatch
        }
        let finalState = try requireConvergedState()
        let ledger = SQLiteReplicationLedger(databaseURL: databaseURL)
        let authority = try requireAuthority(ledger)
        let outbox = try ledger.outboxSnapshot(
            generationID: authority.generationID
        )
        guard outbox.pendingCount == 0 else {
            throw FailureCode.outboxNotDrained
        }
        let diagnostics = try await requireHealthyDiagnostics(on: store)
        return makeSuccessResult(
            workload: WorkloadCounts(
                importedTasks: restartState.importedTaskCount,
                created: Self.restartCreateCount,
                edited: Self.restartEditCount,
                deleted: Self.restartDeleteCount,
                mixedDomainMutations: 0,
                syncRuns: syncRuns
            ),
            state: finalState,
            outbox: outbox,
            diagnostics: diagnostics
        )
    }

    private func syncWhileCreatingFirstTask(on store: NoonmarkStore) async throws
        -> (chainID: TaskChainID, syncAttempts: Int)
    {
        store.syncLocalFolderNow()
        guard let command = store.localFirstReplicationCommandTask else {
            throw FailureCode.syncCommandMissing
        }
        var observedRunning = store.isLocalFirstSyncing
        for _ in 0 ..< 2000 where observedRunning == false {
            try await Task.sleep(for: .milliseconds(1))
            observedRunning = store.isLocalFirstSyncing
            if command.isCancelled {
                break
            }
        }
        guard observedRunning else {
            throw FailureCode.syncDidNotEnterRunningState
        }
        let chainID = try createTask(index: 0, on: store)
        _ = await command.result
        return (chainID, 1)
    }

    private func runSync(on store: NoonmarkStore) async throws -> Int {
        for attempt in 1 ... 600 {
            let state = try await runSyncPass(on: store)
            if state.worker == .idle,
            state.convergence == .converged,
            state.pendingLocalPublicationCount == 0,
            state.waitingRecordCount == 0 {
                _ = try requireConvergedState()
                return attempt
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw FailureCode.syncDidNotConverge
    }

    private func runSyncPass(
        on store: NoonmarkStore
    ) async throws -> LocalFirstReplicationState {
        store.syncLocalFolderNow()
        guard let command = store.localFirstReplicationCommandTask else {
            throw FailureCode.syncCommandMissing
        }
        _ = await command.result
        guard let state = try LocalFirstReplication.persistedState(
            databaseURL: databaseURL
        ) else {
            throw FailureCode.syncDidNotConverge
        }
        guard state.incident == nil else {
            throw FailureCode.syncIncidentDetected
        }
        return state
    }

    private func requireConvergedState() throws -> LocalFirstReplicationState {
        guard let state = try LocalFirstReplication.persistedState(
            databaseURL: databaseURL
        ), state.worker == .idle,
        state.convergence == .converged,
        state.incident == nil,
        state.pendingLocalPublicationCount == 0,
        state.waitingRecordCount == 0
        else {
            throw FailureCode.syncDidNotConverge
        }
        guard state.lastSyncedAt != nil,
              state.lastEffectiveSyncedAt != nil
        else {
            throw FailureCode.syncTimestampMissing
        }
        return state
    }

    private func requireAuthority(
        _ ledger: SQLiteReplicationLedger
    ) throws -> SQLiteReplicationCleanCutAuthority {
        guard let authority = try ledger.cleanCutAuthority() else {
            throw FailureCode.authorityMissing
        }
        return authority
    }

    private func settleConfiguration(on store: NoonmarkStore) async {
        for _ in 0 ..< 4 {
            guard let task = store.localFirstReplicationConfigurationTask else {
                await Task.yield()
                continue
            }
            _ = await task.result
            await Task.yield()
        }
    }

    private func requireConfiguration(on store: NoonmarkStore) async throws {
        await settleConfiguration(on: store)
        guard store.localFirstReplicationRuntime != nil else {
            throw FailureCode.configurationDidNotSettle
        }
    }

    private func createTask(index: Int, on store: NoonmarkStore) throws
        -> TaskChainID
    {
        try store.commitEngineMutation { candidate, moment in
            try candidate.createPoolTask(
                title: "Replication V2 stress item \(index)",
                descriptionText: "Signed isolated App stress mutation.",
                now: moment.instant
            )
        }
    }

    private func editTask(
        _ chainID: TaskChainID,
        index: Int,
        on store: NoonmarkStore
    ) throws {
        try store.commitEngineMutation { candidate, moment in
            try candidate.updatePoolTask(
                chainID: chainID,
                title: "Replication V2 stress item \(index) edited",
                descriptionText: "Signed isolated App stress edit.",
                now: moment.instant
            )
        }
    }

    private func deleteTask(
        _ chainID: TaskChainID,
        on store: NoonmarkStore
    ) throws {
        try store.commitEngineMutation { candidate, moment in
            _ = try candidate.removeTaskFromPool(
                chainID: chainID,
                now: moment.instant
            )
        }
    }

    private func exerciseMixedDomainMutations(
        taskIDs: [TaskChainID],
        on store: NoonmarkStore
    ) throws -> Int {
        guard taskIDs.count == 10 else {
            throw FailureCode.restartStateMismatch
        }
        var mutationCount = 0
        do {
            for (index, chainID) in taskIDs.enumerated() {
                try store.commitEngineMutation { candidate, moment in
                    _ = try candidate.appendPoolNote(
                        chainID: chainID,
                        body: "Replication V2 stress note \(index)",
                        now: moment.instant
                    )
                }
                mutationCount += 1
                try store.commitEngineMutation { candidate, moment in
                    _ = try candidate.addPlannedSubtask(
                        chainID: chainID,
                        title: "Replication V2 stress subtask \(index)",
                        difficulty: index.isMultiple(of: 2) ? .simple : .hard,
                        now: moment.instant
                    )
                }
                mutationCount += 1
            }
        } catch {
            throw staged(.mixedTaskDecorationFailed, error: error)
        }

        var traceIDs: [DayTraceID] = []
        do {
            for chainID in taskIDs {
                traceIDs.append(
                    try store.commitEngineMutation { candidate, moment in
                        try candidate.scheduleFromPool(
                            chainID: chainID,
                            date: moment.today,
                            today: moment.today,
                            now: moment.instant
                        )
                    }
                )
                mutationCount += 1
            }
        } catch {
            throw staged(.mixedSchedulingFailed, error: error)
        }
        do {
            for traceID in traceIDs.prefix(5) {
                try store.commitEngineMutation { candidate, moment in
                    let subtaskIDs = candidate.subtasks.values.filter {
                        $0.traceID == traceID
                    }.map(\.id)
                    for subtaskID in subtaskIDs {
                        try candidate.completeSubtask(
                            subtaskID,
                            today: moment.today,
                            now: moment.instant
                        )
                    }
                    try candidate.markCompleted(
                        traceID: traceID,
                        today: moment.today,
                        now: moment.instant
                    )
                }
                mutationCount += 1
            }
        } catch {
            throw staged(.mixedCompletionFailed, error: error)
        }

        var ideaIDs: [IdeaID] = []
        do {
            for index in 0 ..< 20 {
                ideaIDs.append(
                    try store.commitEngineMutation { candidate, moment in
                        try candidate.appendIdea(
                            body: "Replication V2 stress flylight \(index)",
                            now: moment.instant
                        ).id
                    }
                )
                mutationCount += 1
            }
        } catch {
            throw staged(.mixedIdeaCreateFailed, error: error)
        }
        do {
            for (index, ideaID) in ideaIDs.prefix(10).enumerated() {
                try store.commitEngineMutation { candidate, moment in
                    try candidate.editIdea(
                        id: ideaID,
                        body: "Replication V2 stress flylight \(index) edited",
                        now: moment.instant
                    )
                }
                mutationCount += 1
            }
        } catch {
            throw staged(.mixedIdeaEditFailed, error: error)
        }
        do {
            for ideaID in ideaIDs.prefix(5) {
                try store.commitEngineMutation { candidate, moment in
                    try candidate.deleteIdea(id: ideaID, now: moment.instant)
                }
                mutationCount += 1
            }
        } catch {
            throw staged(.mixedIdeaDeleteFailed, error: error)
        }
        do {
            try store.commitEngineMutation { candidate, moment in
                let nextTheme: AppTheme = candidate.preferences.theme == .coolGray
                    ? .warmPaper
                    : .coolGray
                try candidate.updateTheme(
                    nextTheme,
                    writerID: store.syncDeviceIdentity?.deviceID.rawValue
                        ?? AppPreferences.defaultLocalThemeLanguageWriterID,
                    now: moment.instant
                )
            }
            mutationCount += 1
        } catch {
            throw staged(.mixedSettingsFailed, error: error)
        }
        return mutationCount
    }

    private func staged(
        _ code: FailureCode,
        error: Error
    ) -> StagedFailure {
        StagedFailure(
            code: code,
            underlyingErrorKind: safeErrorKind(error)
        )
    }

    private func safeErrorKind(_ error: Error) -> String {
        guard let error = error as? NoonmarkError else {
            return String(describing: type(of: error))
        }
        switch error {
        case .notFound:
            return "noonmark-not-found"
        case .invalidTitle:
            return "noonmark-invalid-title"
        case .chainAbandoned:
            return "noonmark-chain-abandoned"
        case .immutableHistory:
            return "noonmark-immutable-history"
        case .activeTraceAlreadyExists:
            return "noonmark-active-trace-already-exists"
        case .noActiveTrace:
            return "noonmark-no-active-trace"
        case .invalidInput:
            return "noonmark-invalid-input"
        case .invalidTransition:
            return "noonmark-invalid-transition"
        case .lockedDay:
            return "noonmark-locked-day"
        case .futurePlanCannotComplete:
            return "noonmark-future-plan-cannot-complete"
        case .historicalCompletionCannotBeUndone:
            return "noonmark-historical-completion-cannot-be-undone"
        case .openSubtasksPreventCompletion:
            return "noonmark-open-subtasks-prevent-completion"
        }
    }

    private func requireHealthyDiagnostics(on store: NoonmarkStore) async throws
        -> DiagnosticCounts
    {
        guard let counts = await diagnosticCounts(on: store) else {
            throw FailureCode.diagnosticsMissing
        }
        guard counts.failedSyncOperations == 0 else {
            throw FailureCode.diagnosticFailure
        }
        guard counts.mutationRejections == 0 else {
            throw FailureCode.mutationWasRejected
        }
        guard counts.succeededSyncOperations > 0 else {
            throw FailureCode.diagnosticsMissing
        }
        return counts
    }

    private func diagnosticCounts(on store: NoonmarkStore) async
        -> DiagnosticCounts?
    {
        guard let recorder = store.localDiagnosticRecorder,
              let package = try? await recorder.snapshotPackage()
        else { return nil }
        let succeeded = package.operationCapsules.filter {
            $0.kind == .localFirstSync && $0.outcome == .succeeded
        }.count
        let failures = package.operationCapsules.filter {
            $0.kind == .localFirstSync
                && ($0.outcome == .failed || $0.outcome == .interrupted)
        }
        let rejected = package.records.filter {
            $0.event.code == .mutationRejected
        }.count
        return DiagnosticCounts(
            succeededSyncOperations: succeeded,
            failedSyncOperations: failures.count,
            mutationRejections: rejected,
            firstFailure: failures.first?.failure,
            firstFailureStage: failures.first?.lastStage
        )
    }

    private func makeSuccessResult(
        workload: WorkloadCounts,
        state: LocalFirstReplicationState,
        outbox: SQLiteReplicationOutboxSnapshot,
        diagnostics: DiagnosticCounts
    ) -> StressResult {
        StressResult(
            status: "ok",
            phase: mode.rawValue,
            errorCode: nil,
            underlyingErrorKind: nil,
            authorityErrorVerdict: nil,
            importedTaskCount: workload.importedTasks,
            createdCount: workload.created,
            editedCount: workload.edited,
            deletedCount: workload.deleted,
            mixedDomainMutationCount: workload.mixedDomainMutations,
            syncRunCount: workload.syncRuns,
            pendingOutboxCount: outbox.pendingCount,
            confirmedOutboxCount: outbox.confirmedCount,
            lastSyncedPresent: state.lastSyncedAt != nil,
            lastEffectiveSyncedPresent: state.lastEffectiveSyncedAt != nil,
            convergence: state.convergence.rawValue,
            diagnosticSyncSucceededCount:
            diagnostics.succeededSyncOperations,
            diagnosticSyncFailedCount: diagnostics.failedSyncOperations,
            mutationRejectionCount: diagnostics.mutationRejections,
            diagnosticFailureDomain: nil,
            diagnosticFailureCode: nil,
            diagnosticFailureStage: nil,
            sqliteFailurePoint: nil
        )
    }

    private func writeExclusiveAuthorityMarker(
        in round: ICloudAppendOnlyTestRound,
        generationID: UUID
    ) throws {
        let markerData = try ReplicationPublicationBuilder
            .canonicalEncoder().encode(
                ReplicationRepositoryDescriptor(
                    formatVersion: FileReplicationRepositoryBootstrap
                        .formatVersion,
                    generationID: generationID
                )
            )
        let markerURL = round.rootURL.appendingPathComponent(
            FileReplicationRepositoryBootstrap.markerFilename
        )
        let fileDescriptor = markerURL.withUnsafeFileSystemRepresentation {
            path in
            guard let path else { return Int32(-1) }
            return Darwin.open(
                path,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard fileDescriptor >= 0 else {
            throw FailureCode.authorityMarkerWriteFailed
        }
        let wroteAllBytes = markerData.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return false }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        let synchronized = wroteAllBytes && fsync(fileDescriptor) == 0
        let closed = close(fileDescriptor) == 0
        guard synchronized, closed else {
            throw FailureCode.authorityMarkerWriteFailed
        }
    }

    private func roundInventory(
        at rootURL: URL
    ) throws -> [String: String] {
        let root = rootURL.standardizedFileURL
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ]
        let children = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: []
        )
        var inventory: [String: String] = [:]
        for child in children {
            let item = child.standardizedFileURL
            guard item.deletingLastPathComponent() == root else {
                throw FailureCode.authorityRepositoryMutated
            }
            let values = try item.resourceValues(forKeys: keys)
            let evidence: String
            if values.isSymbolicLink == true {
                throw FailureCode.authorityRepositoryMutated
            } else if values.isRegularFile == true {
                let bytes = try Data(
                    contentsOf: item,
                    options: [.mappedIfSafe]
                )
                evidence = "file:" + SHA256.hash(data: bytes).map {
                    String(format: "%02x", $0)
                }.joined()
            } else if values.isDirectory == true {
                evidence = "directory"
            } else {
                throw FailureCode.authorityRepositoryMutated
            }
            guard inventory.updateValue(
                evidence,
                forKey: item.lastPathComponent
            ) == nil else {
                throw FailureCode.authorityRepositoryMutated
            }
        }
        return inventory
    }

    private func isOwnerRegularFile(_ url: URL) throws -> Bool {
        var information = stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path, lstat(path, &information) == 0 else {
                return false
            }
            return information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
                && information.st_uid == getuid()
        }
    }

    private func write(
        _ value: some Encodable,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func read<Value: Decodable>(
        _ type: Value.Type,
        from url: URL
    ) throws -> Value {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}
