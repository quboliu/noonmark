import AppKit
import Foundation
@_spi(ClassificationUserDecision) import NoonmarkCore
import NoonmarkDayContext
import NoonmarkMacRuntime
import NoonmarkStorage
import NoonmarkSync
import NoonmarkZhulong
import UniformTypeIdentifiers

struct StoreMutationMoment {
    let instant: Date
    let naturalDay: NaturalDayMoment

    var today: LocalDate { naturalDay.today }
    var state: NaturalDayState { naturalDay.state }
}

private struct EngineMutationBackgroundContext {
    let databaseURL: URL?
    let syncDeviceID: SyncDeviceID?
    let automaticClassificationEnabled: Bool
    let automaticClassificationProviderIsReady: Bool
    let automaticClassificationTransitionAt: Date
    let injectPersistenceFailure: Bool
}

private struct EngineMutationBackgroundResult<Result: Sendable>:
    @unchecked Sendable
{
    let result: Result
    let moment: StoreMutationMoment
    let automaticClassificationPolicy:
        NoonmarkStore.EngineMutationAutomaticClassificationPolicy
    let automaticClassificationPlan:
        AutomaticClassificationJobMutationPlan
    let mutationMilliseconds: Double
    let automaticClassificationMilliseconds: Double
    let persistenceMilliseconds: Double
}

extension NoonmarkStore {
    func flushInputDraftsForTermination() async -> Bool {
        guard await inputDraftFlushCoordinator.flushAll() else {
            return false
        }
        await publishDeferredEngineMutations()
        return true
    }

    func prepareForTermination() throws {
        engineMutationLane?.drain()
        toastScheduler.cancel()
        localFirstSyncAutomationTask?.cancel()
        automaticClassificationWorkerRestartRequested = false
        automaticClassificationWorkerTask?.cancel()
        automaticClassificationBacklogDecisionTask?.cancel()
        automaticClassificationCircuitRetryTask?.cancel()
        cloudKitAccountCheckTask?.cancel()
        zhulongProviderTask?.cancel()
        naturalDayObservation?.cancel()
        accessibilityDisplayObservation?.cancel()
        try repository?.finalizeForTermination()
        metricKitDiagnosticSubscriber?.stop()
    }

    func refreshNaturalDay() {
        let moment: NaturalDayMoment
        do {
            moment = try dayContext.moment()
        } catch {
            _ = recordOperationFailureEvidence(
                .naturalDay,
                error: error
            )
            blockNaturalDay(
                candidate: today,
                message: AppPresentation(language: engine.preferences.language)
                    .failureMessage(for: .naturalDay),
                signal: .applicationBecameActive
            )
            return
        }
        try? reconcileNaturalDay(moment, signal: .applicationBecameActive)
    }

    func retryNaturalDay() {
        refreshNaturalDay()
    }

    func handleNaturalDayEvent(_ event: NaturalDayEvent) {
        switch event {
        case let .refreshed(moment, signal):
            try? reconcileNaturalDay(moment, signal: signal)
        case let .failed(failure, lastKnown, signal):
            _ = recordOperationFailureEvidence(
                .naturalDay,
                error: failure
            )
            blockNaturalDay(
                candidate: lastKnown?.today ?? today,
                message: AppPresentation(language: engine.preferences.language)
                    .failureMessage(for: .naturalDay),
                signal: signal
            )
        }
    }

    func reconcileNaturalDay(
        _ moment: NaturalDayMoment,
        signal: NaturalDaySignal
    ) throws {
        let alreadyApplied = today == moment.today
            && dayBoundaryState.appliedThrough == moment.today
            && dayBoundaryState.isReady
        if alreadyApplied {
            naturalDayState = moment.state
            return
        }
        try assertEngineWriteAllowed()

        let previousToday = today
        let followsToday = selectedDate == previousToday
        let calendarFollowsToday = selectedCalendarDate == previousToday
        dayBoundaryState = .reconciling(candidate: moment.today)

        do {
            let candidate = try dayRolloverCoordinator.reconcile(
                engine: engine,
                moment: moment
            ) { candidate, mutationInstant in
                try save(candidate, mutationAt: mutationInstant)
            }
            engine = candidate
            if previousToday != moment.today {
                clearUndoHistory()
            }
            naturalDayState = moment.state
            today = moment.today
            if followsToday {
                selectedDate = moment.today
            }
            if calendarFollowsToday {
                selectedCalendarDate = moment.today
            }
            let shouldClearSelection = previousToday != moment.today
                && (followsToday || calendarFollowsToday)
            if shouldClearSelection {
                clearSelection()
            }
            dayBoundaryState = .ready(appliedThrough: moment.today)
        } catch {
            _ = recordOperationFailureEvidence(
                .naturalDay,
                error: error
            )
            blockNaturalDay(
                candidate: moment.today,
                message: AppPresentation(language: engine.preferences.language)
                    .failureMessage(for: .naturalDay),
                signal: signal
            )
            throw error
        }
    }

    func reconcileNaturalDayAtLaunch(
        _ moment: NaturalDayMoment
    ) throws {
        do {
            try reconcileNaturalDay(moment, signal: .subscription)
        } catch StoreMutationGateError.pendingZhulongApplication {
            blockNaturalDay(
                candidate: moment.today,
                message: AppPresentation(
                    language: engine.preferences.language
                ).zhulong.pendingApplicationMutationBlocked,
                signal: .subscription
            )
        }
    }

    private func blockNaturalDay(
        candidate: LocalDate,
        message: String,
        signal: NaturalDaySignal
    ) {
        dayBoundaryState = .blocked(
            appliedThrough: today,
            candidate: candidate,
            message: message
        )
        _ = signal
    }

    @discardableResult
    private func prepareNaturalDayForMutation() throws -> NaturalDayMoment {
        guard exclusiveEngineOperation == nil else {
            throw StoreMutationGateError.exclusiveOperationInProgress
        }
        try assertEngineWriteAllowed()
        let moment: NaturalDayMoment
        do {
            moment = try dayContext.moment()
        } catch {
            _ = recordOperationFailureEvidence(
                .naturalDay,
                error: error
            )
            blockNaturalDay(
                candidate: dayBoundaryState.candidate,
                message: AppPresentation(language: engine.preferences.language)
                    .failureMessage(for: .naturalDay),
                signal: .manual
            )
            throw error
        }
        let requiresReconciliation = today != moment.today
            || dayBoundaryState.appliedThrough != moment.today
            || dayBoundaryState.isReady == false
        if requiresReconciliation {
            try reconcileNaturalDay(moment, signal: .manual)
        }
        guard dayBoundaryState.isReady,
              dayBoundaryState.appliedThrough == moment.today
        else {
            throw NaturalDayMutationError.boundaryNotApplied
        }
        return moment
    }

    func prepareNaturalDayForUserMutation() -> NaturalDayMoment? {
        do {
            return try prepareNaturalDayForMutation()
        } catch {
            if error is StoreMutationGateError {
                showOperationFailure(.taskMutation, error: error)
            }
            return nil
        }
    }

    func prepareStoreMutationForUser() -> StoreMutationMoment? {
        do {
            return try prepareStoreMutation()
        } catch {
            if error is StoreMutationGateError {
                showOperationFailure(.taskMutation, error: error)
            }
            return nil
        }
    }

    func exportDataPackage() {
        let panel = NSSavePanel()
        panel.title = copy.exportDataPanelTitle
        panel.nameFieldStringValue = "noonmark-backup-\(today.description).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try exportDataPackage(to: url)
            showToast(copy.exportSucceeded(url.lastPathComponent))
        } catch {
            showOperationFailure(.dataTransfer, error: error)
        }
    }

    func importDataPackage() {
        let panel = NSOpenPanel()
        panel.title = copy.importPanelTitle
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await prepareDataImport(from: url)
            } catch {
                showOperationFailure(.dataTransfer, error: error)
            }
        }
    }

    @discardableResult
    func exportDataPackage(to url: URL) throws -> DataPackageWriteReceipt {
        var snapshot = engine.snapshot()
        snapshot.preferences.localFirstSyncPolicy.enabled = false
        return try withSecurityScopedAccess(to: url) {
            try NoonmarkDataPackage.write(snapshot, to: url)
        }
    }

    func prepareDataImport(from url: URL) async throws -> PreparedDataImport {
        try assertEngineWriteAllowed()
        guard exclusiveEngineOperation == nil else {
            throw DataImportTransactionError.anotherEngineOperationIsInProgress
        }
        guard isLocalFirstSyncing == false else {
            throw DataPackageImportError.syncInProgress
        }
        var snapshot = try withSecurityScopedAccess(to: url) {
            try NoonmarkDataPackage.read(from: url)
        }
        snapshot.preferences.localFirstSyncPolicy.enabled = false
        _ = try NoonmarkEngine(snapshot: snapshot)
        let preview = PreparedDataImport(sourceURL: url, snapshot: snapshot)
        preparedDataImport = preview
        return preview
    }

    func confirmPreparedDataImport() {
        guard let preview = preparedDataImport else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await commitDataImport(
                    preview,
                    confirmation: .confirmed(previewID: preview.id)
                )
                showToast(copy.importSucceeded(preview.sourceURL.lastPathComponent))
            } catch {
                showOperationFailure(.dataTransfer, error: error)
            }
        }
    }

    func cancelPreparedDataImport() {
        preparedDataImport = nil
    }

    func commitDataImport(
        _ preview: PreparedDataImport,
        confirmation: DataImportConfirmation
    ) async throws {
        guard preparedDataImport?.id == preview.id else {
            throw DataImportTransactionError.previewExpired
        }
        guard confirmation == .confirmed(previewID: preview.id) else {
            throw DataImportTransactionError.confirmationMismatch
        }
        guard isLocalFirstSyncing == false else {
            throw DataPackageImportError.syncInProgress
        }
        let startingRevision = try beginDataImportCommit(previewID: preview.id)
        defer {
            exclusiveEngineOperation = nil
            restartLocalFirstSyncAutomation()
        }
        cancelCloudKitAccountCheck()
        localFirstSyncAutomationTask?.cancel()
        localFirstSyncAutomationTask = nil
        await pauseDataImportCommitForE2EIfArmed()
        await discardCloudKitTransportAndWait()
        guard preparedDataImport?.id == preview.id else {
            throw DataImportTransactionError.previewExpired
        }
        guard isLocalFirstSyncing == false else {
            throw DataPackageImportError.syncInProgress
        }
        guard engineRevision == startingRevision else {
            preparedDataImport = nil
            throw DataImportTransactionError.engineChangedWhilePreparingCommit
        }
        let moment = try dayContext.moment()
        let importedEngine = try NoonmarkEngine(snapshot: preview.snapshot)
        try importedEngine.settleDays(
            upTo: moment.today,
            now: try importedEngine.nextMutationDate(
                reference: moment.instant
            )
        )
        try withExclusiveEngineWriteAuthorization(
            for: .dataImport(preview.id)
        ) {
            try replacePersistedData(with: importedEngine)
        }
        clearUndoHistory()
        engine = importedEngine
        naturalDayState = moment.state
        today = moment.today
        dayBoundaryState = .ready(appliedThrough: moment.today)
        Theme.apply(engine.preferences.theme)
        selectedDate = today
        selectedCalendarDate = today
        clearSelection()
        localFirstSyncMessage = nil
        resetPersistedLocalFirstSyncStatus()
        preparedDataImport = nil
    }

    private func beginDataImportCommit(previewID: UUID) throws -> UInt64 {
        try assertEngineWriteAllowed()
        guard exclusiveEngineOperation == nil else {
            throw DataImportTransactionError.anotherEngineOperationIsInProgress
        }
        exclusiveEngineOperation = .dataImport(previewID)
        return engineRevision
    }

    func armDataImportCommitPauseForE2E() throws {
        guard AppLaunchArguments.contains("--e2e-data-package-workflow"),
              AppLaunchArguments.value(after: "--data-url") != nil,
              Bundle.main.bundleIdentifier == "app.noonmark.mac.e2e"
        else {
            throw DataImportCommitE2EError.unsafePauseRequest
        }
        guard shouldPauseNextDataImportCommitForE2E == false,
              isDataImportCommitPausedForE2E == false,
              dataImportCommitContinuationForE2E == nil
        else {
            throw DataImportCommitE2EError.pauseAlreadyArmed
        }
        shouldPauseNextDataImportCommitForE2E = true
    }

    func resumeDataImportCommitForE2E() {
        shouldPauseNextDataImportCommitForE2E = false
        let continuation = dataImportCommitContinuationForE2E
        dataImportCommitContinuationForE2E = nil
        continuation?.resume()
    }

    private func pauseDataImportCommitForE2EIfArmed() async {
        guard shouldPauseNextDataImportCommitForE2E else { return }
        shouldPauseNextDataImportCommitForE2E = false
        isDataImportCommitPausedForE2E = true
        await withCheckedContinuation { continuation in
            dataImportCommitContinuationForE2E = continuation
        }
        isDataImportCommitPausedForE2E = false
    }

    func resetPersistedLocalFirstSyncStatus(now: Date = Date()) {
        guard let databaseURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try SQLiteSyncRepository(databaseURL: databaseURL).saveMetadata(
                SyncMetadataEntry(
                    key: SQLiteLocalFirstSyncCoordinator.lastStatusMetadataKey,
                    value: try encoder.encode(
                        SQLiteLocalFirstSyncStatus.idle(since: now)
                    ),
                    updatedAt: now
                )
            )
        } catch {
            _ = recordOperationFailureEvidence(
                .persistence,
                error: error
            )
            localFirstSyncMessage = AppPresentation(
                language: engine.preferences.language
            ).failureMessage(for: .sync)
        }
    }

    private func withSecurityScopedAccess<Result>(
        to url: URL,
        _ operation: () throws -> Result
    ) throws -> Result {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try operation()
    }

    static func configuredDatabaseURL() -> URL {
        if let path = AppLaunchArguments.value(after: "--data-url"), path.isEmpty == false {
            return URL(fileURLWithPath: path)
        }
        return defaultDatabaseURL()
    }

    static func defaultDatabaseURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("noonmark", isDirectory: true)
            .appendingPathComponent("Noonmark.sqlite")
    }

    func loadOrSeed() throws {
        guard let repository else {
            try seed()
            return
        }

        let loaded = try repository.load()
        let snapshot = loaded.snapshot()
        engine = loaded
        Theme.apply(engine.preferences.theme)
        if snapshot.days.isEmpty && snapshot.chains.isEmpty && snapshot.traces.isEmpty {
            do {
                try assertEngineWriteAllowed()
            } catch StoreMutationGateError.pendingZhulongApplication {
                // An empty snapshot is already a valid bootstrap state. When
                // recovery owns the cross-store timeline, leave it untouched
                // and let recoverPendingZhulongApplication reconcile it next.
                return
            }
            try repository.save(engine)
        }
    }

    func persist() {
        guard exclusiveEngineOperation == nil else {
            return
        }
        do {
            synchronizeEngineMutationHead()
            let naturalDay = try dayContext.moment()
            try save(
                engine,
                mutationAt: engine.nextMutationDate(
                    reference: naturalDay.instant
                )
            )
            // Explicit persistence is the boundary used after a domain fixture
            // or another direct engine replacement. Advance the ordered lane
            // to that same durable engine so the next background autosave
            // cannot start from an older in-memory head.
            replaceEngineMutationHead(with: engine)
        } catch {
            if error is StoreMutationGateError {
                showOperationFailure(.persistence, error: error)
                return
            }
            showOperationFailure(.persistence, error: error)
        }
    }

    func save(
        _ candidate: NoonmarkEngine,
        mutationAt mutationInstant: Date,
        changedFrom sourceSnapshot: NoonmarkSnapshot? = nil
    ) throws {
        try assertEngineWriteAllowed()
        guard let repository else { return }
        if persistenceFailuresRemainingForE2E > 0 {
            persistenceFailuresRemainingForE2E -= 1
            throw PersistenceFailureE2EError.injectedSaveFailure
        }
        let snapshot = candidate.snapshot()
        if let syncDeviceIdentity {
            try repository.save(
                snapshot,
                changedFrom: sourceSnapshot,
                recordingChangesFor: syncDeviceIdentity.deviceID,
                changedAt: mutationInstant
            )
        } else if let sourceSnapshot {
            try repository.save(
                snapshot,
                changedFrom: sourceSnapshot
            )
        } else {
            try repository.save(snapshot)
        }
    }

    func save(
        _ candidate: NoonmarkEngine,
        classificationCommitBoundaries: [NoonmarkSnapshot],
        mutationAt mutationInstant: Date,
        changedFrom sourceSnapshot: NoonmarkSnapshot? = nil
    ) throws {
        try assertEngineWriteAllowed()
        guard let repository else { return }
        if persistenceFailuresRemainingForE2E > 0 {
            persistenceFailuresRemainingForE2E -= 1
            throw PersistenceFailureE2EError.injectedSaveFailure
        }
        if let syncDeviceIdentity {
            try repository.save(
                candidate.snapshot(),
                changedFrom: sourceSnapshot,
                classificationCommitBoundaries:
                classificationCommitBoundaries,
                recordingChangesFor: syncDeviceIdentity.deviceID,
                changedAt: mutationInstant
            )
        } else if let sourceSnapshot {
            try repository.save(
                candidate.snapshot(),
                changedFrom: sourceSnapshot
            )
        } else {
            try repository.save(candidate.snapshot())
        }
    }

    func save(
        _ candidate: NoonmarkEngine,
        mutationAt mutationInstant: Date,
        enqueuingAutomaticClassificationJobs jobs: [
            AutomaticClassificationJobEnqueue
        ],
        changedFrom sourceSnapshot: NoonmarkSnapshot? = nil
    ) throws {
        guard jobs.isEmpty == false else {
            try save(
                candidate,
                mutationAt: mutationInstant,
                changedFrom: sourceSnapshot
            )
            return
        }
        try assertEngineWriteAllowed()
        guard let repository, let syncDeviceIdentity else {
            throw AutomaticClassificationAppError.persistenceUnavailable
        }
        if persistenceFailuresRemainingForE2E > 0 {
            persistenceFailuresRemainingForE2E -= 1
            throw PersistenceFailureE2EError.injectedSaveFailure
        }
        try repository.save(
            candidate.snapshot(),
            changedFrom: sourceSnapshot,
            recordingChangesFor: syncDeviceIdentity.deviceID,
            changedAt: mutationInstant,
            enqueuingAutomaticClassificationJobs: jobs
        )
    }

    func save(
        _ candidate: NoonmarkEngine,
        mutationAt mutationInstant: Date,
        applyingAutomaticClassificationPlan plan: AutomaticClassificationJobMutationPlan,
        changedFrom sourceSnapshot: NoonmarkSnapshot? = nil
    ) throws {
        guard plan.isEmpty == false else {
            try save(
                candidate,
                mutationAt: mutationInstant,
                changedFrom: sourceSnapshot
            )
            return
        }
        try assertEngineWriteAllowed()
        guard let repository, let syncDeviceIdentity else {
            throw AutomaticClassificationAppError.persistenceUnavailable
        }
        if persistenceFailuresRemainingForE2E > 0 {
            persistenceFailuresRemainingForE2E -= 1
            throw PersistenceFailureE2EError.injectedSaveFailure
        }
        try repository.save(
            candidate.snapshot(),
            changedFrom: sourceSnapshot,
            recordingChangesFor: syncDeviceIdentity.deviceID,
            changedAt: mutationInstant,
            enqueuingAutomaticClassificationJobs: plan.enqueues,
            applyingAutomaticClassificationJobMutations: plan.mutations,
            automaticClassificationTransitionAt:
            automaticClassificationOperationalClock.now()
        )
        recordAutomaticClassificationMutationDiagnostics(plan)
    }

    func save(
        _ candidate: NoonmarkEngine,
        classificationCommitBoundaries: [NoonmarkSnapshot],
        mutationAt mutationInstant: Date,
        applyingAutomaticClassificationPlan plan:
        AutomaticClassificationJobMutationPlan,
        changedFrom sourceSnapshot: NoonmarkSnapshot? = nil
    ) throws {
        guard plan.isEmpty == false else {
            try save(
                candidate,
                classificationCommitBoundaries:
                classificationCommitBoundaries,
                mutationAt: mutationInstant,
                changedFrom: sourceSnapshot
            )
            return
        }
        try assertEngineWriteAllowed()
        guard let repository, let syncDeviceIdentity else {
            throw AutomaticClassificationAppError.persistenceUnavailable
        }
        if persistenceFailuresRemainingForE2E > 0 {
            persistenceFailuresRemainingForE2E -= 1
            throw PersistenceFailureE2EError.injectedSaveFailure
        }
        try repository.save(
            candidate.snapshot(),
            changedFrom: sourceSnapshot,
            classificationCommitBoundaries:
            classificationCommitBoundaries,
            recordingChangesFor: syncDeviceIdentity.deviceID,
            changedAt: mutationInstant,
            enqueuingAutomaticClassificationJobs: plan.enqueues,
            applyingAutomaticClassificationJobMutations: plan.mutations,
            automaticClassificationTransitionAt:
            automaticClassificationOperationalClock.now()
        )
        recordAutomaticClassificationMutationDiagnostics(plan)
    }

    func saveAutomaticClassificationCompletion(
        _ candidate: NoonmarkEngine,
        claim: AutomaticClassificationJobClaim,
        mutationAt mutationInstant: Date
    ) throws {
        try assertEngineWriteAllowed()
        guard let repository, let syncDeviceIdentity else {
            throw AutomaticClassificationAppError.persistenceUnavailable
        }
        if persistenceFailuresRemainingForE2E > 0 {
            persistenceFailuresRemainingForE2E -= 1
            throw PersistenceFailureE2EError.injectedSaveFailure
        }
        try repository.save(
            candidate.snapshot(),
            recordingChangesFor: syncDeviceIdentity.deviceID,
            changedAt: mutationInstant,
            completingAutomaticClassificationJob: claim,
            automaticClassificationTransitionAt:
            automaticClassificationOperationalClock.now()
        )
    }

    func saveSnapshotUndo(
        _ candidate: NoonmarkEngine,
        outcome: SnapshotUndoOutcome,
        mutationAt mutationInstant: Date
    ) throws -> Bool {
        guard outcome.automaticClassificationCancelledChainIDs.count <= 1 else {
            throw NoonmarkError.invalidTransition(
                "one undo operation cannot cancel multiple automatic classification jobs"
            )
        }
        guard repository != nil, syncDeviceIdentity != nil else {
            try save(candidate, mutationAt: mutationInstant)
            return false
        }
        var mutations = outcome.automaticClassificationCancelledChainIDs.map {
            AutomaticClassificationJobMutation.cancelForUndo($0)
        }
        var enqueues: [AutomaticClassificationJobEnqueue] = []
        for chainID in outcome.automaticClassificationRestoredChainIDs {
            let restoration = try automaticClassificationMutationPlan(
                for: .taskBecameEligible(chainID),
                candidate: candidate,
                originalSnapshot: engine.snapshot()
            )
            enqueues.append(contentsOf: restoration.enqueues)
            mutations.append(contentsOf: restoration.mutations)
        }
        let plan = AutomaticClassificationJobMutationPlan(
            enqueues: enqueues,
            mutations: mutations
        )
        try save(
            candidate,
            mutationAt: mutationInstant,
            applyingAutomaticClassificationPlan: plan
        )
        return plan.isEmpty == false
    }

    func saveSnapshotRedo(
        _ candidate: NoonmarkEngine,
        outcome: SnapshotUndoOutcome,
        redo: AutomaticClassificationJobRedo?,
        mutationAt mutationInstant: Date
    ) throws -> Bool {
        guard repository != nil, syncDeviceIdentity != nil else {
            try save(candidate, mutationAt: mutationInstant)
            return false
        }
        var mutations = outcome.automaticClassificationCancelledChainIDs.map {
            AutomaticClassificationJobMutation.invalidateChain($0)
        }
        if let redo {
            mutations.append(.requeueCancelledByUndo(redo))
        }
        let plan = AutomaticClassificationJobMutationPlan(
            enqueues: [],
            mutations: mutations
        )
        try save(
            candidate,
            mutationAt: mutationInstant,
            applyingAutomaticClassificationPlan: plan
        )
        return plan.isEmpty == false
    }

    private func replacePersistedData(with candidate: NoonmarkEngine) throws {
        try assertEngineWriteAllowed()
        guard let repository else { return }
        if persistenceFailuresRemainingForE2E > 0 {
            persistenceFailuresRemainingForE2E -= 1
            throw PersistenceFailureE2EError.injectedSaveFailure
        }
        try repository.replaceForDataImport(
            candidate.snapshot(),
            preserving: syncDeviceIdentity
        )
    }

    func savePendingZhulongApplication(
        _ candidate: NoonmarkEngine,
        mutationAt mutationInstant: Date
    ) throws {
        guard pendingZhulongEngineWriteAuthorized == false else {
            throw StoreMutationGateError.exclusiveOperationInProgress
        }
        try zhulongWorkspace.assertMatchesPendingApplicationAfterSnapshot(
            candidate
        )
        pendingZhulongEngineWriteAuthorized = true
        defer { pendingZhulongEngineWriteAuthorized = false }
        try save(candidate, mutationAt: mutationInstant)
    }

    func savePendingZhulongApplication(
        _ candidate: NoonmarkEngine,
        originalSnapshot: NoonmarkSnapshot,
        mutationAt mutationInstant: Date
    ) throws {
        guard pendingZhulongEngineWriteAuthorized == false else {
            throw StoreMutationGateError.exclusiveOperationInProgress
        }
        try zhulongWorkspace.assertMatchesPendingApplicationAfterSnapshot(
            candidate
        )
        let automaticClassificationPlan = try automaticClassificationMutationPlan(
            for: .newlyCreatedTaskChains,
            candidate: candidate,
            originalSnapshot: originalSnapshot
        )
        pendingZhulongEngineWriteAuthorized = true
        defer { pendingZhulongEngineWriteAuthorized = false }
        try save(
            candidate,
            mutationAt: mutationInstant,
            applyingAutomaticClassificationPlan: automaticClassificationPlan
        )
    }

    func reconcileZhulongEnginePersistenceFailure(
        for pendingApplication: ZhulongPendingApplication
    ) throws -> ZhulongEnginePersistenceResolution {
        guard let repository else {
            throw ZhulongCommitReconciliationError
                .durableEngineStateUnavailable
        }
        return try ZhulongEnginePersistenceInspector.resolve(
            persistedEngine: repository.load(),
            pendingApplication: pendingApplication
        )
    }

    func assertEngineWriteAllowed() throws {
        if let exclusiveEngineOperation,
           authorizedExclusiveEngineWrite != exclusiveEngineOperation
        {
            throw StoreMutationGateError
                .exclusiveOperationInProgress
        }
        guard pendingZhulongEngineWriteAuthorized == false else { return }
        do {
            try zhulongWorkspace.assertNoPendingApplication()
        } catch {
            throw StoreMutationGateError.pendingZhulongApplication
        }
    }

    func withExclusiveEngineWriteAuthorization<Result>(
        for operation: ExclusiveEngineOperation,
        _ body: () throws -> Result
    ) throws -> Result {
        guard exclusiveEngineOperation == operation,
              authorizedExclusiveEngineWrite == nil
        else {
            throw StoreMutationGateError
                .exclusiveOperationInProgress
        }
        authorizedExclusiveEngineWrite = operation
        defer { authorizedExclusiveEngineWrite = nil }
        return try body()
    }

    @discardableResult
    func commitEngineMutation<Result>(
        undoPolicy: EngineMutationUndoPolicy = .preserve,
        automaticClassificationPolicy: EngineMutationAutomaticClassificationPolicy = .none,
        classificationCommitBoundaries:
        ((Result) -> [NoonmarkSnapshot]?)? = nil,
        _ mutation: (NoonmarkEngine, StoreMutationMoment) throws -> Result
    ) throws -> Result {
        let performanceStartedAt =
            ProcessInfo.processInfo.systemUptime
        synchronizeEngineMutationHead()
        let moment = try prepareStoreMutation()
        let preparedAt =
            ProcessInfo.processInfo.systemUptime
        let originalSnapshot = engine.snapshot()
        let snapshotAt =
            ProcessInfo.processInfo.systemUptime
        let undoEntry = makeUndoEntry(
            for: undoPolicy,
            originalSnapshot: originalSnapshot,
            moment: moment
        )
        let candidate = NoonmarkEngine(copying: engine)
        let clonedAt =
            ProcessInfo.processInfo.systemUptime
        let result = try mutation(candidate, moment)
        let mutatedAt =
            ProcessInfo.processInfo.systemUptime
        let automaticClassificationPlan = try automaticClassificationMutationPlan(
            for: automaticClassificationPolicy,
            candidate: candidate,
            originalSnapshot: originalSnapshot
        )
        let classifiedAt =
            ProcessInfo.processInfo.systemUptime
        do {
            let boundaries = classificationCommitBoundaries?(result)
            switch automaticClassificationPolicy {
            case .none:
                if let boundaries {
                    try save(
                        candidate,
                        classificationCommitBoundaries: boundaries,
                        mutationAt: moment.instant,
                        changedFrom: originalSnapshot
                    )
                } else {
                    try save(
                        candidate,
                        mutationAt: moment.instant,
                        changedFrom: originalSnapshot
                    )
                }
            case .taskDefinitionChanged, .classificationCatalogChanged,
                 .newlyCreatedTaskChains,
                 .taskBecameIneligible,
                 .taskBecameEligible,
                 .userClassificationWins:
                if let boundaries {
                    try save(
                        candidate,
                        classificationCommitBoundaries: boundaries,
                        mutationAt: moment.instant,
                        applyingAutomaticClassificationPlan:
                        automaticClassificationPlan,
                        changedFrom: originalSnapshot
                    )
                } else {
                    try save(
                        candidate,
                        mutationAt: moment.instant,
                        applyingAutomaticClassificationPlan:
                        automaticClassificationPlan,
                        changedFrom: originalSnapshot
                    )
                }
            }
        } catch let gateError as StoreMutationGateError {
            throw gateError
        } catch {
            throw wrappedPersistenceCommitError(error)
        }
        let persistedAt =
            ProcessInfo.processInfo.systemUptime
        replaceEngineMutationHead(with: candidate)
        redoStack.removeAll()
        applyCommittedUndoPolicy(undoPolicy, undoEntry: undoEntry)
        switch automaticClassificationPolicy {
        case .none:
            break
        case .taskDefinitionChanged, .classificationCatalogChanged,
             .newlyCreatedTaskChains,
             .taskBecameIneligible,
             .taskBecameEligible,
             .userClassificationWins:
            if automaticClassificationPlan.isEmpty == false {
                automaticClassificationJobsDidChange()
            }
        }
        let publishedAt =
            ProcessInfo.processInfo.systemUptime
        if AppLaunchArguments.contains(
            "--e2e-tencent-ime-input-realistic-workload"
        ) {
            e2eLastEngineMutationPerformanceSample =
                EngineMutationPerformanceSample(
                    prepareMilliseconds:
                    (preparedAt - performanceStartedAt) * 1000,
                    snapshotMilliseconds:
                    (snapshotAt - preparedAt) * 1000,
                    cloneMilliseconds:
                    (clonedAt - snapshotAt) * 1000,
                    mutationMilliseconds:
                    (mutatedAt - clonedAt) * 1000,
                    automaticClassificationMilliseconds:
                    (classifiedAt - mutatedAt) * 1000,
                    persistenceMilliseconds:
                    (persistedAt - classifiedAt) * 1000,
                    publishMilliseconds:
                    (publishedAt - persistedAt) * 1000,
                    totalMilliseconds:
                    (publishedAt - performanceStartedAt) * 1000,
                    mainActorBlockingMilliseconds:
                    (publishedAt - performanceStartedAt) * 1000
                )
        }
        return result
    }

    @discardableResult
    func commitEngineMutationInBackground<Result: Sendable>(
        undoPolicy: EngineMutationUndoPolicy = .preserve,
        publishesEngine: Bool = true,
        automaticClassificationPolicy:
        @escaping @Sendable (NoonmarkEngine)
            -> EngineMutationAutomaticClassificationPolicy = {
                _ in .none
            },
        classificationCommitBoundaries:
        (@Sendable (Result) -> [NoonmarkSnapshot]?)? = nil,
        _ mutation: @escaping @Sendable (
            NoonmarkEngine,
            StoreMutationMoment
        ) throws -> Result
    ) async throws -> Result {
        let performanceStartedAt =
            ProcessInfo.processInfo.systemUptime
        let naturalDay = try prepareNaturalDayForMutation()
        let preparedAt =
            ProcessInfo.processInfo.systemUptime
        let backgroundContext =
            makeEngineMutationBackgroundContext()
        let lane = orderedEngineMutationLane()
        let commit: OrderedEngineMutationLane.Commit<
            EngineMutationBackgroundResult<Result>
        >
        do {
            commit = try await lane.commit {
                candidate,
                originalSnapshot in
                try Self.executeEngineMutation(
                    candidate: candidate,
                    originalSnapshot: originalSnapshot,
                    naturalDay: naturalDay,
                    automaticClassificationPolicy:
                    automaticClassificationPolicy,
                    classificationCommitBoundaries:
                    classificationCommitBoundaries,
                    backgroundContext: backgroundContext,
                    mutation: mutation
                )
            }
        } catch let gateError as StoreMutationGateError {
            throw gateError
        } catch {
            throw wrappedPersistenceCommitError(error)
        }
        let background = commit.result
        let undoEntry = makeUndoEntry(
            for: undoPolicy,
            originalSnapshot: commit.sourceSnapshot,
            moment: background.moment
        )
        let publishStartedAt =
            ProcessInfo.processInfo.systemUptime
        publishEngineMutationCommit(
            commit,
            publishesEngine: publishesEngine
        )
        redoStack.removeAll()
        applyCommittedUndoPolicy(
            undoPolicy,
            undoEntry: undoEntry
        )
        if background.automaticClassificationPlan.isEmpty
            == false
        {
            recordAutomaticClassificationMutationDiagnostics(
                background.automaticClassificationPlan
            )
            if publishesEngine {
                automaticClassificationJobsDidChange()
            } else {
                hasDeferredAutomaticClassificationMutation =
                    true
            }
        }
        let publishedAt =
            ProcessInfo.processInfo.systemUptime
        if AppLaunchArguments.contains(
            "--e2e-tencent-ime-input-realistic-workload"
        ) {
            let prepareMilliseconds =
                (preparedAt - performanceStartedAt) * 1000
            let publishMilliseconds =
                (publishedAt - publishStartedAt) * 1000
            e2eLastEngineMutationPerformanceSample =
                EngineMutationPerformanceSample(
                    prepareMilliseconds:
                    prepareMilliseconds,
                    snapshotMilliseconds:
                    commit.sourceSnapshotMilliseconds,
                    cloneMilliseconds:
                    commit.cloneMilliseconds,
                    mutationMilliseconds:
                    background.mutationMilliseconds,
                    automaticClassificationMilliseconds:
                    background
                        .automaticClassificationMilliseconds,
                    persistenceMilliseconds:
                    background.persistenceMilliseconds,
                    publishMilliseconds:
                    publishMilliseconds,
                    totalMilliseconds:
                    (publishedAt - performanceStartedAt)
                        * 1000,
                    mainActorBlockingMilliseconds:
                    prepareMilliseconds + publishMilliseconds
                )
        }
        return background.result
    }

    private func orderedEngineMutationLane()
        -> OrderedEngineMutationLane
    {
        if let engineMutationLane {
            return engineMutationLane
        }
        let lane = OrderedEngineMutationLane(engine: engine)
        engineMutationLane = lane
        return lane
    }

    private func synchronizeEngineMutationHead() {
        guard let engineMutationLane else {
            return
        }
        let head = engineMutationLane.headAndWait()
        guard head.sequence
            > publishedEngineMutationSequence
        else {
            return
        }
        publishedEngineMutationSequence = head.sequence
        installEngineMutationLaneHead(head.engine)
    }

    private func makeEngineMutationBackgroundContext()
        -> EngineMutationBackgroundContext
    {
        let shouldInjectFailure =
            repository != nil
                && persistenceFailuresRemainingForE2E > 0
        if shouldInjectFailure {
            persistenceFailuresRemainingForE2E -= 1
        }
        let providerIsReady = if case .configured =
            automaticClassificationProviderExecution
        {
            true
        } else {
            false
        }
        return EngineMutationBackgroundContext(
            databaseURL: databaseURL,
            syncDeviceID: syncDeviceIdentity?.deviceID,
            automaticClassificationEnabled:
            isAutomaticClassificationEnabled,
            automaticClassificationProviderIsReady:
            providerIsReady,
            automaticClassificationTransitionAt:
            automaticClassificationOperationalClock.now(),
            injectPersistenceFailure:
            shouldInjectFailure
        )
    }

    private func publishEngineMutationCommit(
        _ commit: OrderedEngineMutationLane.Commit<some Any>,
        publishesEngine: Bool = true
    ) {
        guard commit.sequence
            > publishedEngineMutationSequence
        else {
            return
        }
        publishedEngineMutationSequence = commit.sequence
        installEngineMutationLaneHead(
            commit.engine,
            publishesEngine: publishesEngine
        )
        if publishesEngine {
            notifiedEngineMutationSequence = commit.sequence
        }
    }

    @discardableResult
    func replaceEngineMutationHead(
        with replacement: NoonmarkEngine
    ) -> UInt64 {
        let sequence = orderedEngineMutationLane()
            .replaceAndWait(with: replacement)
        publishedEngineMutationSequence = sequence
        installEngineMutationLaneHead(
            replacement,
            publishesEngine: true
        )
        notifiedEngineMutationSequence = sequence
        return sequence
    }

    private func installEngineMutationLaneHead(
        _ committedEngine: NoonmarkEngine,
        publishesEngine: Bool = false
    ) {
        isInstallingEngineMutationLaneHead = true
        suppressesEngineObjectWillChange =
            publishesEngine == false
        engine = committedEngine
        suppressesEngineObjectWillChange = false
        isInstallingEngineMutationLaneHead = false
    }

    func publishDeferredEngineMutations() async {
        guard let engineMutationLane else {
            return
        }
        let head = await engineMutationLane.head()
        if head.sequence > publishedEngineMutationSequence {
            publishedEngineMutationSequence = head.sequence
            installEngineMutationLaneHead(
                head.engine,
                publishesEngine: false
            )
        }
        guard publishedEngineMutationSequence
            > notifiedEngineMutationSequence
        else {
            return
        }
        objectWillChange.send()
        notifiedEngineMutationSequence =
            publishedEngineMutationSequence
        if hasDeferredAutomaticClassificationMutation {
            hasDeferredAutomaticClassificationMutation = false
            automaticClassificationJobsDidChange()
        }
    }

    private func wrappedPersistenceCommitError(
        _ error: Error
    ) -> Error {
        return EnginePersistenceCommitError(
            underlying: error
        )
    }

    private nonisolated static func executeEngineMutation<
        Result: Sendable
    >(
        candidate: NoonmarkEngine,
        originalSnapshot: NoonmarkSnapshot,
        naturalDay: NaturalDayMoment,
        automaticClassificationPolicy:
        @Sendable (NoonmarkEngine)
            -> EngineMutationAutomaticClassificationPolicy,
        classificationCommitBoundaries:
        (@Sendable (Result) -> [NoonmarkSnapshot]?)?,
        backgroundContext:
        EngineMutationBackgroundContext,
        mutation: @Sendable (
            NoonmarkEngine,
            StoreMutationMoment
        ) throws -> Result
    ) throws -> EngineMutationBackgroundResult<Result> {
        let mutationStartedAt =
            ProcessInfo.processInfo.systemUptime
        let moment = StoreMutationMoment(
            instant: try candidate.nextMutationDate(
                reference: naturalDay.instant
            ),
            naturalDay: naturalDay
        )
        let policy = automaticClassificationPolicy(
            candidate
        )
        let result = try mutation(candidate, moment)
        let mutatedAt =
            ProcessInfo.processInfo.systemUptime
        let plan = try backgroundAutomaticClassificationPlan(
            for: policy,
            candidate: candidate,
            originalSnapshot: originalSnapshot,
            context: backgroundContext
        )
        let classifiedAt =
            ProcessInfo.processInfo.systemUptime
        try persistEngineMutation(
            candidate: candidate,
            originalSnapshot: originalSnapshot,
            classificationCommitBoundaries:
            classificationCommitBoundaries?(result),
            automaticClassificationPlan: plan,
            moment: moment,
            context: backgroundContext
        )
        let persistedAt =
            ProcessInfo.processInfo.systemUptime
        return EngineMutationBackgroundResult(
            result: result,
            moment: moment,
            automaticClassificationPolicy: policy,
            automaticClassificationPlan: plan,
            mutationMilliseconds:
            (mutatedAt - mutationStartedAt) * 1000,
            automaticClassificationMilliseconds:
            (classifiedAt - mutatedAt) * 1000,
            persistenceMilliseconds:
            (persistedAt - classifiedAt) * 1000
        )
    }

    private nonisolated static func
        backgroundAutomaticClassificationPlan(
            for policy:
            EngineMutationAutomaticClassificationPolicy,
            candidate: NoonmarkEngine,
            originalSnapshot: NoonmarkSnapshot,
            context: EngineMutationBackgroundContext
        ) throws -> AutomaticClassificationJobMutationPlan
    {
        guard case .none = policy else {
            guard let databaseURL = context.databaseURL,
                  context.syncDeviceID != nil
            else {
                return AutomaticClassificationJobMutationPlan(
                    enqueues: [],
                    mutations: []
                )
            }
            let storagePolicy:
                AutomaticClassificationJobMutationPolicy =
                switch policy {
                case .none:
                    .reconcileExisting
                case let .taskDefinitionChanged(chainID):
                    .taskDefinitionChanged(chainID)
                case .classificationCatalogChanged:
                    .classificationCatalogChanged
                case .newlyCreatedTaskChains:
                    .newlyCreatedTaskChains
                case let .taskBecameIneligible(chainID):
                    .taskBecameIneligible(chainID)
                case let .taskBecameEligible(chainID):
                    .taskBecameEligible(chainID)
                case let .userClassificationWins(chainID):
                    .userClassificationWins(chainID)
                }
            let plan =
                try AutomaticClassificationJobMutationPlanner()
                    .plan(
                        policy: storagePolicy,
                        candidate: candidate,
                        originalSnapshot: originalSnapshot,
                        existingJobs:
                        try SQLiteAutomaticClassificationJobRepository(
                            databaseURL: databaseURL
                        ).jobs(),
                        providerIsReady:
                        context
                            .automaticClassificationProviderIsReady,
                        operationalNow:
                        context
                            .automaticClassificationTransitionAt
                    )
            guard context.automaticClassificationEnabled
            else {
                return AutomaticClassificationJobMutationPlan(
                    enqueues: [],
                    mutations: plan.mutations
                )
            }
            return plan
        }
        return AutomaticClassificationJobMutationPlan(
            enqueues: [],
            mutations: []
        )
    }

    private nonisolated static func persistEngineMutation(
        candidate: NoonmarkEngine,
        originalSnapshot: NoonmarkSnapshot,
        classificationCommitBoundaries:
        [NoonmarkSnapshot]?,
        automaticClassificationPlan:
        AutomaticClassificationJobMutationPlan,
        moment: StoreMutationMoment,
        context: EngineMutationBackgroundContext
    ) throws {
        guard let databaseURL = context.databaseURL else {
            return
        }
        if context.injectPersistenceFailure {
            throw PersistenceFailureE2EError
                .injectedSaveFailure
        }
        let repository = SQLiteEngineRepository(
            databaseURL: databaseURL
        )
        let snapshot = candidate.snapshot()
        guard let deviceID = context.syncDeviceID else {
            try repository.save(
                snapshot,
                changedFrom: originalSnapshot
            )
            return
        }
        if automaticClassificationPlan.isEmpty {
            if let classificationCommitBoundaries {
                try repository.save(
                    snapshot,
                    changedFrom: originalSnapshot,
                    classificationCommitBoundaries:
                    classificationCommitBoundaries,
                    recordingChangesFor: deviceID,
                    changedAt: moment.instant
                )
            } else {
                try repository.save(
                    snapshot,
                    changedFrom: originalSnapshot,
                    recordingChangesFor: deviceID,
                    changedAt: moment.instant
                )
            }
            return
        }
        if let classificationCommitBoundaries {
            try repository.save(
                snapshot,
                changedFrom: originalSnapshot,
                classificationCommitBoundaries:
                classificationCommitBoundaries,
                recordingChangesFor: deviceID,
                changedAt: moment.instant,
                enqueuingAutomaticClassificationJobs:
                automaticClassificationPlan.enqueues,
                applyingAutomaticClassificationJobMutations:
                automaticClassificationPlan.mutations,
                automaticClassificationTransitionAt:
                context
                    .automaticClassificationTransitionAt
            )
        } else {
            try repository.save(
                snapshot,
                changedFrom: originalSnapshot,
                recordingChangesFor: deviceID,
                changedAt: moment.instant,
                enqueuingAutomaticClassificationJobs:
                automaticClassificationPlan.enqueues,
                applyingAutomaticClassificationJobMutations:
                automaticClassificationPlan.mutations,
                automaticClassificationTransitionAt:
                context
                    .automaticClassificationTransitionAt
            )
        }
    }

    private func makeUndoEntry(
        for undoPolicy: EngineMutationUndoPolicy,
        originalSnapshot: NoonmarkSnapshot,
        moment: StoreMutationMoment
    ) -> UndoEntry? {
        switch undoPolicy {
        case .preserve, .invalidate:
            nil
        case let .snapshot(action):
            .snapshot(originalSnapshot, action: action)
        case let .snapshotIfAllowed(date, action):
            if date >= moment.today, engine.days[date]?.lockedAt == nil {
                .snapshot(originalSnapshot, action: action)
            } else {
                nil
            }
        }
    }

    private func applyCommittedUndoPolicy(
        _ undoPolicy: EngineMutationUndoPolicy,
        undoEntry: UndoEntry?
    ) {
        switch undoPolicy {
        case .preserve:
            break
        case .snapshot, .snapshotIfAllowed:
            if let undoEntry { pushUndoEntry(with: undoEntry) }
        case .invalidate:
            clearUndoHistory()
        }
    }

    private func prepareStoreMutation() throws -> StoreMutationMoment {
        let naturalDay = try prepareNaturalDayForMutation()
        return StoreMutationMoment(
            instant: try engine.nextMutationDate(
                reference: naturalDay.instant
            ),
            naturalDay: naturalDay
        )
    }

    func prepareStoreMutationForAutomaticClassification() throws -> StoreMutationMoment {
        try prepareStoreMutation()
    }

    func armPersistenceFailureForE2E(count: Int = 1) throws {
        guard permitsPersistenceFailureE2E, count > 0 else {
            throw PersistenceFailureE2EError.unsafeFailpointRequest
        }
        persistenceFailuresRemainingForE2E += count
    }

    func disarmPersistenceFailureForE2E() {
        persistenceFailuresRemainingForE2E = 0
    }
}
