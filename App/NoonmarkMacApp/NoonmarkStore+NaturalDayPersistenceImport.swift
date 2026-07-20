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

extension NoonmarkStore {
    func prepareForTermination() {
        toastScheduler.cancel()
        localFirstSyncAutomationTask?.cancel()
        automaticClassificationWorkerRestartRequested = false
        automaticClassificationWorkerTask?.cancel()
        automaticClassificationBacklogDecisionTask?.cancel()
        automaticClassificationCircuitRetryTask?.cancel()
        cloudKitAccountCheckTask?.cancel()
        naturalDayObservation?.cancel()
        accessibilityDisplayObservation?.cancel()
    }

    func refreshNaturalDay() {
        let moment: NaturalDayMoment
        do {
            moment = try dayContext.moment()
        } catch {
            NSLog(
                "Noonmark natural day refresh failed: %@",
                String(reflecting: error)
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
            NSLog(
                "Noonmark natural day observation failed: %@",
                String(reflecting: failure)
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
            NSLog(
                "Noonmark natural day reconciled signal=%@ previous=%@ current=%@",
                String(describing: signal),
                previousToday.description,
                moment.today.description
            )
        } catch {
            NSLog(
                "Noonmark natural day reconciliation failed: %@",
                String(reflecting: error)
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
        NSLog(
            "Noonmark natural day blocked signal=%@ applied=%@ candidate=%@ error=%@",
            String(describing: signal),
            today.description,
            candidate.description,
            message
        )
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
            NSLog(
                "Noonmark mutation date preparation failed: %@",
                String(reflecting: error)
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
        try replacePersistedData(with: importedEngine)
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
            NSLog("Noonmark sync status reset failed: %@", String(describing: error))
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
            NSLog("Noonmark persistence skipped during exclusive engine replacement")
            return
        }
        do {
            let naturalDay = try dayContext.moment()
            try save(
                engine,
                mutationAt: engine.nextMutationDate(
                    reference: naturalDay.instant
                )
            )
        } catch {
            if error is StoreMutationGateError {
                showOperationFailure(.persistence, error: error)
                return
            }
            NSLog("Noonmark persistence save failed: %@", String(describing: error))
            showOperationFailure(.persistence, error: error)
        }
    }

    func save(
        _ candidate: NoonmarkEngine,
        mutationAt mutationInstant: Date
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
                recordingChangesFor: syncDeviceIdentity.deviceID,
                changedAt: mutationInstant
            )
        } else {
            try repository.save(candidate)
        }
    }

    func save(
        _ candidate: NoonmarkEngine,
        mutationAt mutationInstant: Date,
        enqueuingAutomaticClassificationJobs jobs: [
            AutomaticClassificationJobEnqueue
        ]
    ) throws {
        guard jobs.isEmpty == false else {
            try save(candidate, mutationAt: mutationInstant)
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
            recordingChangesFor: syncDeviceIdentity.deviceID,
            changedAt: mutationInstant,
            enqueuingAutomaticClassificationJobs: jobs
        )
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

    func saveUserClassificationWinningOverAutomaticWork(
        _ candidate: NoonmarkEngine,
        chainID: TaskChainID,
        mutationAt mutationInstant: Date
    ) throws {
        try assertEngineWriteAllowed()
        guard let repository, let syncDeviceIdentity else {
            try save(candidate, mutationAt: mutationInstant)
            return
        }
        if persistenceFailuresRemainingForE2E > 0 {
            persistenceFailuresRemainingForE2E -= 1
            throw PersistenceFailureE2EError.injectedSaveFailure
        }
        try repository.save(
            candidate.snapshot(),
            recordingChangesFor: syncDeviceIdentity.deviceID,
            changedAt: mutationInstant,
            supersedingAutomaticClassificationJobsForChain: chainID,
            automaticClassificationTransitionAt:
            automaticClassificationOperationalClock.now()
        )
    }

    func saveSnapshotUndo(
        _ candidate: NoonmarkEngine,
        outcome: SnapshotUndoOutcome,
        mutationAt mutationInstant: Date
    ) throws {
        guard outcome.automaticClassificationCancelledChainIDs.count <= 1 else {
            throw NoonmarkError.invalidTransition(
                "one undo operation cannot cancel multiple automatic classification jobs"
            )
        }
        guard let chainID = outcome.automaticClassificationCancelledChainIDs.first,
              let repository,
              let syncDeviceIdentity
        else {
            try save(candidate, mutationAt: mutationInstant)
            return
        }
        try assertEngineWriteAllowed()
        if persistenceFailuresRemainingForE2E > 0 {
            persistenceFailuresRemainingForE2E -= 1
            throw PersistenceFailureE2EError.injectedSaveFailure
        }
        try repository.save(
            candidate.snapshot(),
            recordingChangesFor: syncDeviceIdentity.deviceID,
            changedAt: mutationInstant,
            cancellingAutomaticClassificationJobsForUndoneChain: chainID,
            automaticClassificationTransitionAt:
            automaticClassificationOperationalClock.now()
        )
    }

    func saveSnapshotRedo(
        _ candidate: NoonmarkEngine,
        redo: AutomaticClassificationJobRedo?,
        mutationAt mutationInstant: Date
    ) throws {
        guard let redo, let repository, let syncDeviceIdentity else {
            try save(candidate, mutationAt: mutationInstant)
            return
        }
        try assertEngineWriteAllowed()
        if persistenceFailuresRemainingForE2E > 0 {
            persistenceFailuresRemainingForE2E -= 1
            throw PersistenceFailureE2EError.injectedSaveFailure
        }
        try repository.save(
            candidate.snapshot(),
            recordingChangesFor: syncDeviceIdentity.deviceID,
            changedAt: mutationInstant,
            requeuingAutomaticClassificationJobForRedo: redo
        )
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
        let jobs = try automaticClassificationJobs(
            for: .newlyCreatedTaskChains,
            candidate: candidate,
            originalSnapshot: originalSnapshot
        )
        pendingZhulongEngineWriteAuthorized = true
        defer { pendingZhulongEngineWriteAuthorized = false }
        try save(
            candidate,
            mutationAt: mutationInstant,
            enqueuingAutomaticClassificationJobs: jobs
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
        guard pendingZhulongEngineWriteAuthorized == false else { return }
        do {
            try zhulongWorkspace.assertNoPendingApplication()
        } catch {
            throw StoreMutationGateError.pendingZhulongApplication
        }
    }

    @discardableResult
    func commitEngineMutation<Result>(
        undoPolicy: EngineMutationUndoPolicy = .preserve,
        automaticClassificationPolicy: EngineMutationAutomaticClassificationPolicy = .none,
        _ mutation: (NoonmarkEngine, StoreMutationMoment) throws -> Result
    ) throws -> Result {
        let moment = try prepareStoreMutation()
        let originalSnapshot = engine.snapshot()
        let undoEntry = makeUndoEntry(
            for: undoPolicy,
            originalSnapshot: originalSnapshot,
            moment: moment
        )
        let candidate = try NoonmarkEngine(snapshot: originalSnapshot)
        let result = try mutation(candidate, moment)
        let automaticClassificationJobs = try automaticClassificationJobs(
            for: automaticClassificationPolicy,
            candidate: candidate,
            originalSnapshot: originalSnapshot
        )
        do {
            switch automaticClassificationPolicy {
            case .none:
                try save(candidate, mutationAt: moment.instant)
            case .newlyCreatedTaskChains:
                try save(
                    candidate,
                    mutationAt: moment.instant,
                    enqueuingAutomaticClassificationJobs: automaticClassificationJobs
                )
            case let .userClassificationWins(chainID):
                try saveUserClassificationWinningOverAutomaticWork(
                    candidate,
                    chainID: chainID,
                    mutationAt: moment.instant
                )
            }
        } catch let gateError as StoreMutationGateError {
            throw gateError
        } catch {
            if error is PersistenceFailureE2EError {
                NSLog("Noonmark E2E injected persistence save failure")
            } else {
                NSLog("Noonmark persistence save failed: %@", String(describing: error))
            }
            throw EnginePersistenceCommitError(underlying: error)
        }
        engine = candidate
        redoStack.removeAll()
        applyCommittedUndoPolicy(undoPolicy, undoEntry: undoEntry)
        switch automaticClassificationPolicy {
        case .none:
            break
        case .newlyCreatedTaskChains, .userClassificationWins:
            automaticClassificationJobsDidChange()
        }
        return result
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
