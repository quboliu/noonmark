import AppKit
import Foundation
@_spi(ClassificationUserDecision) import NoonmarkCore
import NoonmarkDayContext
import NoonmarkMacRuntime
import NoonmarkStorage
import NoonmarkSync
import UniformTypeIdentifiers

extension NoonmarkStore {
    func prepareForTermination() {
        toastScheduler.cancel()
        localFirstSyncAutomationTask?.cancel()
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

        let previousToday = today
        let followsToday = selectedDate == previousToday
        let calendarFollowsToday = selectedCalendarDate == previousToday
        dayBoundaryState = .reconciling(candidate: moment.today)

        do {
            let candidate = try dayRolloverCoordinator.reconcile(
                engine: engine,
                moment: moment,
                persist: save
            )
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
            now: moment.instant
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
            seed()
            return
        }

        let loaded = try repository.load()
        let snapshot = loaded.snapshot()
        engine = loaded
        Theme.apply(engine.preferences.theme)
        if snapshot.days.isEmpty && snapshot.chains.isEmpty && snapshot.traces.isEmpty {
            try save(engine)
        }
    }

    func persist() {
        guard exclusiveEngineOperation == nil else {
            NSLog("Noonmark persistence skipped during exclusive engine replacement")
            return
        }
        do {
            try save(engine)
        } catch {
            NSLog("Noonmark persistence save failed: %@", String(describing: error))
            showOperationFailure(.persistence, error: error)
        }
    }

    func save(_ candidate: NoonmarkEngine) throws {
        guard let repository else { return }
        if persistenceFailuresRemainingForE2E > 0 {
            persistenceFailuresRemainingForE2E -= 1
            throw PersistenceFailureE2EError.injectedSaveFailure
        }
        if let syncDeviceIdentity {
            try repository.save(
                candidate.snapshot(),
                recordingChangesFor: syncDeviceIdentity.deviceID
            )
        } else {
            try repository.save(candidate)
        }
    }

    private func replacePersistedData(with candidate: NoonmarkEngine) throws {
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

    @discardableResult
    func commitEngineMutation<Result>(
        undoPolicy: EngineMutationUndoPolicy = .preserve,
        _ mutation: (NoonmarkEngine, NaturalDayMoment) throws -> Result
    ) throws -> Result {
        let moment = try prepareNaturalDayForMutation()
        let originalSnapshot = engine.snapshot()
        let undoEntry: UndoEntry? = switch undoPolicy {
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
        let candidate = try NoonmarkEngine(snapshot: originalSnapshot)
        let result = try mutation(candidate, moment)
        do {
            try save(candidate)
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
        switch undoPolicy {
        case .preserve:
            break
        case .snapshot, .snapshotIfAllowed:
            if let undoEntry {
                pushUndoEntry(with: undoEntry)
            }
        case .invalidate:
            clearUndoHistory()
        }
        return result
    }

    @discardableResult
    func commitEngineMutation<Result>(
        undoPolicy: EngineMutationUndoPolicy = .preserve,
        _ mutation: (NoonmarkEngine) throws -> Result
    ) throws -> Result {
        try commitEngineMutation(undoPolicy: undoPolicy) { candidate, _ in
            try mutation(candidate)
        }
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
