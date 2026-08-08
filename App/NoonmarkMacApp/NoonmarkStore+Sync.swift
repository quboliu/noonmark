import Foundation
@_spi(ClassificationUserDecision) import NoonmarkCore
import NoonmarkDayContext
import NoonmarkDiagnostics
import NoonmarkMacRuntime
import NoonmarkStorage
import NoonmarkSync

extension NoonmarkStore {
    func setTheme(_ theme: AppTheme) {
        guard engine.preferences.theme != theme else { return }
        do {
            try commitEngineMutation(undoPolicy: .invalidate) { candidate, moment in
                try candidate.updateTheme(
                    theme,
                    writerID: self.themeLanguageWriterID,
                    now: moment.instant
                )
            }
            Theme.apply(theme)
        } catch {
            showOperationFailure(.preferences, error: error)
        }
    }

    func setLanguage(_ language: AppLanguage) {
        guard engine.preferences.language != language else { return }
        do {
            try commitEngineMutation(undoPolicy: .invalidate) { candidate, moment in
                try candidate.updateLanguage(
                    language,
                    writerID: self.themeLanguageWriterID,
                    now: moment.instant
                )
            }
            onLanguageChange?()
        } catch {
            showOperationFailure(.preferences, error: error)
        }
    }

    func setSettingsPoemEnabled(_ enabled: Bool) {
        var policy = engine.preferences.settingsPoemDisplayPolicy
        policy.enabled = enabled
        do {
            try commitEngineMutation(undoPolicy: .invalidate) { candidate, _ in
                candidate.updateSettingsPoemDisplayPolicy(policy)
            }
        } catch {
            showOperationFailure(.preferences, error: error)
        }
    }

    private var themeLanguageWriterID: String {
        syncDeviceIdentity?.deviceID.rawValue
            ?? AppPreferences.defaultLocalThemeLanguageWriterID
    }

    func setSettingsPoemText(_ text: String) {
        var policy = engine.preferences.settingsPoemDisplayPolicy
        policy.text = text
        do {
            try commitEngineMutation(undoPolicy: .invalidate) { candidate, _ in
                candidate.updateSettingsPoemDisplayPolicy(policy)
            }
        } catch {
            showOperationFailure(.preferences, error: error)
        }
    }

    @discardableResult
    func autosaveSettingsPoemText(
        _ text: String
    ) async -> Bool {
        do {
            try await commitEngineMutationInBackground(
                undoPolicy: .invalidate,
                publishesEngine: false
            ) { candidate, _ in
                var policy = candidate.preferences
                    .settingsPoemDisplayPolicy
                policy.text = text
                candidate.updateSettingsPoemDisplayPolicy(
                    policy
                )
            }
            resolveOperationFailure(.preferences)
            return true
        } catch {
            showOperationFailure(.preferences, error: error)
            return false
        }
    }

    func resetSettingsPoemText() {
        var policy = engine.preferences.settingsPoemDisplayPolicy
        policy.text = SettingsPoemDisplayPolicy.defaultText
        do {
            try commitEngineMutation(undoPolicy: .invalidate) { candidate, _ in
                candidate.updateSettingsPoemDisplayPolicy(policy)
            }
            showToast(copy.settingsPoemResetToast)
        } catch {
            showOperationFailure(.preferences, error: error)
        }
    }

    func setDataMode(_ dataMode: AppDataMode) {
        guard engine.preferences.dataMode != dataMode else { return }
        do {
            try commitEngineMutation(undoPolicy: .invalidate) { candidate, _ in
                candidate.updateDataMode(dataMode)
            }
            if dataMode != .localFirst {
                cancelCloudKitAccountCheck()
                discardCloudKitTransport()
            }
            restartLocalFirstSyncAutomation()
            showToast(copy.dataModeChangedToast(for: dataMode))
        } catch {
            showOperationFailure(.preferences, error: error)
        }
    }

    func setLocalFirstSyncEndpoint(_ endpoint: CloudSyncEndpointKind) {
        guard engine.preferences.localFirstSyncPolicy.endpoint != endpoint else { return }
        if endpoint != .iCloud {
            cancelCloudKitAccountCheck()
        }
        var policy = engine.preferences.localFirstSyncPolicy
        policy.endpoint = endpoint
        let endpointIsUnavailable = supportsRunnableLocalFirstSync(endpoint) == false
            || (endpoint == .iCloud && isICloudSyncEndpointAvailable == false)
        if endpointIsUnavailable {
            policy.enabled = false
        }
        commitLocalFirstSyncPolicy(policy)
    }

    func setLocalFirstSyncMode(_ mode: CloudSyncMode) {
        guard engine.preferences.localFirstSyncPolicy.mode != mode else { return }
        var policy = engine.preferences.localFirstSyncPolicy
        policy.mode = mode
        commitLocalFirstSyncPolicy(policy)
    }

    func setLocalFirstSyncEnabled(_ enabled: Bool) {
        if enabled == false {
            cancelCloudKitAccountCheck()
        }
        guard engine.preferences.localFirstSyncPolicy.enabled != enabled else { return }
        var policy = engine.preferences.localFirstSyncPolicy
        if enabled {
            guard supportsRunnableLocalFirstSync(policy.endpoint) else {
                showToast(copy.localFirstSyncUnavailableToast)
                return
            }
            if policy.endpoint == .iCloud {
                if cloudKitSyncConfiguration != nil {
                    beginCloudKitSyncEnablement()
                    return
                }
                do {
                    try validateICloudSyncEndpoint()
                } catch {
                    presentLocalFirstSyncFailure(error)
                    return
                }
            }
        }
        policy.enabled = enabled
        commitLocalFirstSyncPolicy(policy)
    }

    var isICloudDriveAvailable: Bool {
        (try? ICloudDriveSyncTransport.defaultRootURL(
            repositoryName: AppLaunchArguments.validatedRuntimeProfile
                .iCloudRepositoryName
        )) != nil
    }

    var cloudKitSyncConfiguration: CloudKitSyncLaunchConfiguration? {
        try? CloudKitSyncLaunchConfiguration.resolve(
            arguments: AppLaunchArguments.values
        )
    }

    var isCloudKitSyncConfigured: Bool {
        cloudKitSyncConfiguration != nil
    }

    var isICloudSyncEndpointAvailable: Bool {
        do {
            try validateICloudSyncEndpoint()
            return true
        } catch {
            return false
        }
    }

    private func validateICloudSyncEndpoint() throws {
        if let cloudKitSyncConfiguration {
            try CloudKitEntitlementProbe.validateCurrentProcess(
                containerIdentifier: cloudKitSyncConfiguration
                    .containerIdentifier
            )
            guard let cloudKitAccountAvailability,
                  cloudKitAccountAvailability.canSync
            else {
                throw CloudKitSyncEngineTransportError.accountUnavailable(
                    cloudKitAccountAvailability ?? .couldNotDetermine
                )
            }
        } else {
            _ = try ICloudDriveSyncTransport.defaultRootURL(
                repositoryName: AppLaunchArguments.validatedRuntimeProfile
                    .iCloudRepositoryName
            )
        }
    }

    func refreshCloudKitAccountAvailability() {
        guard cloudKitSyncConfiguration != nil else {
            cancelCloudKitAccountCheck()
            if cloudKitAccountAvailability != nil {
                cloudKitAccountAvailability = nil
            }
            return
        }
        cancelCloudKitAccountCheck()
        cloudKitAccountCheckTask = Task { [weak self] in
            guard let self else { return }
            do {
                let availability = try await resolvedCloudKitAccountAvailability()
                try Task.checkCancellation()
                cloudKitAccountAvailability = availability
                if availability.canSync {
                    restoreLocalFirstSyncStatus()
                } else if engine.preferences.localFirstSyncPolicy.endpoint == .iCloud {
                    localFirstSyncMessage = AppPresentation(
                        language: engine.preferences.language
                    ).failureMessage(for: .sync)
                }
                restartLocalFirstSyncAutomation()
            } catch is CancellationError {
                return
            } catch {
                cloudKitAccountAvailability = nil
                if engine.preferences.localFirstSyncPolicy.endpoint == .iCloud {
                    localFirstSyncMessage = AppPresentation(
                        language: engine.preferences.language
                    ).failureMessage(for: .sync)
                }
                restartLocalFirstSyncAutomation()
            }
        }
    }

    func enableCloudKitSyncAfterAccountCheck() async throws {
        let availability = try await resolvedCloudKitAccountAvailability()
        try Task.checkCancellation()
        cloudKitAccountAvailability = availability
        guard availability.canSync else {
            throw CloudKitSyncEngineTransportError.accountUnavailable(availability)
        }
        guard engine.preferences.dataMode == .localFirst,
              engine.preferences.localFirstSyncPolicy.endpoint == .iCloud
        else {
            throw CloudKitSyncEngineTransportError.cloudKitFailure(
                "CloudKit enablement was cancelled because the data mode or endpoint changed"
            )
        }
        var policy = engine.preferences.localFirstSyncPolicy
        guard policy.enabled == false else { return }
        policy.enabled = true
        try applyLocalFirstSyncPolicy(policy)
    }

    private func resolvedCloudKitAccountAvailability() async throws -> CloudKitAccountAvailability {
        guard let databaseURL, cloudKitSyncConfiguration != nil else {
            throw CloudKitSyncEngineTransportError.cloudKitFailure(
                "CloudKit account validation requires a persistent database"
            )
        }
        return try await cloudKitTransport(
            databaseURL: databaseURL
        ).accountAvailability()
    }

    private func beginCloudKitSyncEnablement() {
        cancelCloudKitAccountCheck()
        cloudKitAccountCheckTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await enableCloudKitSyncAfterAccountCheck()
            } catch is CancellationError {
                return
            } catch {
                presentLocalFirstSyncFailure(error)
            }
        }
    }

    func cancelCloudKitAccountCheck() {
        cloudKitAccountCheckTask?.cancel()
        cloudKitAccountCheckTask = nil
    }

    private func commitLocalFirstSyncPolicy(_ policy: LocalFirstCloudSyncPolicy) {
        do {
            try applyLocalFirstSyncPolicy(policy)
        } catch {
            showOperationFailure(.preferences, error: error)
        }
    }

    private func applyLocalFirstSyncPolicy(
        _ policy: LocalFirstCloudSyncPolicy
    ) throws {
        try commitEngineMutation(undoPolicy: .invalidate) { candidate, _ in
            candidate.updateLocalFirstSyncPolicy(policy)
        }
        if policy.enabled == false || policy.endpoint != .iCloud {
            discardCloudKitTransport()
        }
        restoreLocalFirstSyncStatus()
        restartLocalFirstSyncAutomation()
        showToast(copy.localFirstSyncChangedToast)
    }

    func syncLocalFolderNow() {
        localFirstSyncConfirmationRetryCount = 0
        runLocalFolderSync(
            showToastOnSuccess: true,
            retriesUserAttentionBlocks: true
        )
    }

    private func runLocalFolderSync(
        showToastOnSuccess: Bool,
        retriesUserAttentionBlocks: Bool
    ) {
        guard let naturalDay = prepareNaturalDayForUserMutation() else { return }
        guard engine.preferences.dataMode == .localFirst,
              engine.preferences.localFirstSyncPolicy.enabled,
              supportsRunnableLocalFirstSync(engine.preferences.localFirstSyncPolicy.endpoint)
        else {
            showToast(copy.localFirstSyncUnavailableToast)
            return
        }
        guard isLocalFirstSyncing == false else { return }
        guard let databaseURL else {
            showToast(copy.ephemeralFolderSyncUnavailable)
            return
        }

        let diagnosticOperation = diagnostics.startOperation(
            kind: .localFirstSync,
            endpoint: diagnosticEndpoint(
                for: engine.preferences.localFirstSyncPolicy.endpoint
            )
        )
        diagnosticOperation.stage(.transportPrepare)
        let syncOperationID = diagnosticOperation.id.rawValue

        let transport: any SyncRecordTransport
        do {
            transport = try localFirstSyncTransport(
                for: engine.preferences.localFirstSyncPolicy.endpoint,
                databaseURL: databaseURL,
                diagnosticOperation: diagnosticOperation
            )
            if retriesUserAttentionBlocks {
                try SQLiteSyncRepository(databaseURL: databaseURL)
                    .requeueJournalEntriesBlockedForUserAttention()
            }
            diagnosticOperation.stage(.persistenceCommit)
            try save(
                engine,
                mutationAt: engine.nextMutationDate(
                    reference: naturalDay.instant
                )
            )
        } catch {
            let failedAt = SQLiteLocalFirstSyncCoordinator
                .persistedFailureTimestamp(Date())
            let diagnosticCorrelation = diagnosticOperation
                .failWithCorrelation(
                    persistedSyncDiagnosticFailure(for: error),
                    detail: diagnosticFailure(for: error),
                    at: failedAt
                )
            presentLocalFirstSyncFailure(
                error,
                failedAt: failedAt,
                diagnosticCorrelation: diagnosticCorrelation
            )
            return
        }
        exclusiveEngineOperation = .localFirstSync(syncOperationID)
        isLocalFirstSyncing = true
        localFirstSyncMessage = copy.syncingWithEllipsis
        Task {
            let coordinator = SQLiteLocalFirstSyncCoordinator(
                databaseURL: databaseURL,
                transport: transport,
                diagnosticOperation: diagnosticOperation,
                completesDiagnosticOperationOnSuccess: false,
                completesDiagnosticOperationOnFailure: true
            )
            let result: SQLiteLocalFirstSyncResult
            do {
                result = try await coordinator.sync()
            } catch {
                let diagnosticCorrelation = diagnosticOperation
                    .failWithCorrelation(
                        persistedSyncDiagnosticFailure(for: error),
                        detail: diagnosticFailure(for: error)
                    )
                await MainActor.run {
                    localFirstSyncConfirmationRetryCount = 0
                    finishLocalFirstSyncOperation(syncOperationID)
                    presentLocalFirstSyncFailure(
                        error,
                        diagnosticCorrelation: diagnosticCorrelation,
                        persistsFailure: false
                    )
                }
                return
            }

            do {
                let syncRepository = SQLiteSyncRepository(
                    databaseURL: databaseURL
                )
                let unresolvedConflictCount =
                    try syncRepository.unresolvedConflicts().count
                let timestamps =
                    try SQLiteLocalFirstSyncCoordinator.timestamps(
                        in: syncRepository
                    )
                diagnosticOperation.stage(.installMergedState)
                try await MainActor.run {
                    try consumePostSyncFailureForE2EIfArmed()
                    let loaded = try SQLiteEngineRepository(
                        databaseURL: databaseURL
                    ).load()
                    let moment = try dayContext.moment()
                    let previousLanguage = engine.preferences.language
                    let automationConfigurationChanged =
                        engine.preferences.dataMode != loaded.preferences.dataMode
                        || engine.preferences.localFirstSyncPolicy
                            != loaded.preferences.localFirstSyncPolicy
                    try withExclusiveEngineWriteAuthorization(
                        for: .localFirstSync(syncOperationID)
                    ) {
                        try installExternallyLoadedEngine(
                            loaded,
                            moment: moment
                        )
                    }
                    Theme.apply(engine.preferences.theme)
                    if previousLanguage != engine.preferences.language {
                        onLanguageChange?()
                    }
                    finishLocalFirstSyncOperation(syncOperationID)
                    if result.isAwaitingUploadConfirmation == false {
                        localFirstSyncConfirmationRetryCount = 0
                        resolveOperationFailure(.sync)
                    }
                    localFirstSyncTimestamps = timestamps
                    localFirstSyncMessage = copy.localFirstSyncResult(
                        result,
                        unresolvedConflictCount: unresolvedConflictCount
                    )
                    if result.isAwaitingUploadConfirmation {
                        scheduleUploadConfirmationRetry()
                    }
                    if showToastOnSuccess {
                        showToast(localFirstSyncMessage ?? copy.localFirstSyncChangedToast)
                    }
                    if automationConfigurationChanged {
                        restartLocalFirstSyncAutomation()
                    }
                }
                diagnosticOperation.succeed(
                    progress: DiagnosticProgress(
                        recordCount: result.upload.uploadedCount
                            + result.download.fetchedCount,
                        pendingCount: result.upload.pendingCount,
                        appliedCount: result.download.appliedCount,
                        conflictCount: unresolvedConflictCount
                    )
                )
            } catch {
                let failedAt = SQLiteLocalFirstSyncCoordinator
                    .persistedFailureTimestamp(Date())
                let diagnosticCorrelation = diagnosticOperation
                    .failWithCorrelation(
                        persistedSyncDiagnosticFailure(for: error),
                        detail: diagnosticFailure(for: error),
                        at: failedAt
                    )
                await MainActor.run {
                    localFirstSyncConfirmationRetryCount = 0
                    finishLocalFirstSyncOperation(syncOperationID)
                    presentLocalFirstSyncFailure(
                        error,
                        failedAt: failedAt,
                        diagnosticCorrelation: diagnosticCorrelation,
                        persistsFailure: true
                    )
                }
            }
        }
    }

    private func scheduleUploadConfirmationRetry() {
        let retryExponent = min(
            localFirstSyncConfirmationRetryCount,
            5
        )
        let retryDelaySeconds = min(1 << retryExponent, 30)
        localFirstSyncConfirmationRetryCount = min(
            localFirstSyncConfirmationRetryCount + 1,
            5
        )
        Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    for: .seconds(retryDelaySeconds)
                )
            } catch {
                return
            }
            guard let self,
                  isLocalFirstSyncing == false,
                  let databaseURL,
                  engine.preferences.dataMode == .localFirst,
                  engine.preferences.localFirstSyncPolicy.enabled,
                  supportsRunnableLocalFirstSync(
                      engine.preferences.localFirstSyncPolicy.endpoint
                  ),
                  try SQLiteSyncRepository(databaseURL: databaseURL)
                  .journalEntries(state: .publishedLocal).isEmpty == false
            else { return }
            runLocalFolderSync(
                showToastOnSuccess: false,
                retriesUserAttentionBlocks: false
            )
        }
    }

    private func finishLocalFirstSyncOperation(_ operationID: UUID) {
        if exclusiveEngineOperation == .localFirstSync(operationID) {
            exclusiveEngineOperation = nil
        }
        isLocalFirstSyncing = false
    }

    private func consumePostSyncFailureForE2EIfArmed() throws {
        guard persistenceFailuresRemainingForE2E > 0 else { return }
        persistenceFailuresRemainingForE2E -= 1
        throw PersistenceFailureE2EError.injectedSaveFailure
    }

    private func presentLocalFirstSyncFailure(
        _ error: Error,
        failedAt: Date = Date(),
        diagnosticCorrelation existingCorrelation:
            DiagnosticOperationCorrelation? = nil,
        persistsFailure: Bool = true
    ) {
        let failedAt = SQLiteLocalFirstSyncCoordinator
            .persistedFailureTimestamp(failedAt)
        let correlation: DiagnosticOperationCorrelation = if let existingCorrelation {
            existingCorrelation
        } else {
            diagnostics.startOperation(
                kind: .localFirstSync,
                endpoint: diagnosticEndpoint(
                    for: engine.preferences.localFirstSyncPolicy.endpoint
                ),
                at: failedAt
            )
            .failWithCorrelation(
                persistedSyncDiagnosticFailure(for: error),
                detail: diagnosticFailure(for: error),
                at: failedAt
            )
        }
        if persistsFailure, let databaseURL {
            do {
                try SQLiteLocalFirstSyncCoordinator.persistFailure(
                    error,
                    at: failedAt,
                    diagnosticCorrelation: correlation,
                    in: SQLiteSyncRepository(
                        databaseURL: databaseURL
                    )
                )
            } catch {
                diagnostics.record(
                    .persistenceFailed(
                        failure: AppDiagnosticFailureMapping.map(error),
                        incidentID: correlation.incidentID
                    )
                )
            }
        }
        showOperationFailure(
            .sync,
            error: error,
            diagnosticIncidentID: correlation.incidentID
        )
        localFirstSyncMessage = operationFailure
    }

    private func installExternallyLoadedEngine(
        _ loaded: NoonmarkEngine,
        moment: NaturalDayMoment
    ) throws {
        try assertEngineWriteAllowed()
        let previousToday = today
        let followsToday = selectedDate == previousToday
        let calendarFollowsToday = selectedCalendarDate == previousToday
        let candidate = try dayRolloverCoordinator.reconcile(
            engine: loaded,
            moment: moment
        ) { candidate, mutationInstant in
            try save(candidate, mutationAt: mutationInstant)
        }
        engine = candidate
        clearUndoHistory()
        naturalDayState = moment.state
        today = moment.today
        dayBoundaryState = .ready(appliedThrough: moment.today)
        if followsToday {
            selectedDate = moment.today
        }
        if calendarFollowsToday {
            selectedCalendarDate = moment.today
        }
        normalizeSelection()
    }

    private func supportsRunnableLocalFirstSync(_ endpoint: CloudSyncEndpointKind) -> Bool {
        endpoint == .iCloud || endpoint == .localFolder
    }

    private func localFirstSyncTransport(
        for endpoint: CloudSyncEndpointKind,
        databaseURL: URL,
        diagnosticOperation: DiagnosticOperation
    ) throws -> any SyncRecordTransport {
        let producerEpochID = try SQLiteSyncRepository(
            databaseURL: databaseURL
        ).loadOrCreateTransportProducerEpochID()
        switch endpoint {
        case .iCloud:
            if cloudKitSyncConfiguration != nil {
                return try cloudKitTransport(databaseURL: databaseURL)
            }
            return try ICloudDriveSyncTransport(
                repositoryName: AppLaunchArguments.validatedRuntimeProfile
                    .iCloudRepositoryName,
                producerEpochID: producerEpochID,
                diagnosticOperation: diagnosticOperation
            )
        case .localFolder:
            return LocalFolderSyncTransport(
                rootURL: Self.configuredSyncFolderURL(),
                producerEpochID: producerEpochID,
                diagnosticOperation: diagnosticOperation
            )
        case .s3, .webDAV:
            throw ICloudDriveSyncTransportError.unavailable
        }
    }

    private func cloudKitTransport(
        databaseURL: URL
    ) throws -> CloudKitSyncEngineTransport {
        if let retainedCloudKitSyncTransport {
            return retainedCloudKitSyncTransport
        }
        guard let configuration = cloudKitSyncConfiguration else {
            throw CloudKitSyncLaunchConfigurationError.invalidArguments
        }
        let lease = CloudKitSyncPersistenceLease()
        let transport = try CloudKitSyncEngineTransport(
            containerIdentifier: configuration.containerIdentifier,
            persistence: SQLiteCloudKitSyncPersistence(
                databaseURL: databaseURL,
                lease: lease
            ),
            zoneName: configuration.zoneName
        )
        retainedCloudKitSyncLease = lease
        retainedCloudKitSyncTransport = transport
        return transport
    }

    private func discardCloudKitTransport() {
        guard let transport = detachCloudKitTransport() else { return }
        Task {
            await transport.shutdown()
        }
    }

    func discardCloudKitTransportAndWait() async {
        guard let transport = detachCloudKitTransport() else { return }
        await transport.shutdown()
    }

    private func detachCloudKitTransport() -> CloudKitSyncEngineTransport? {
        retainedCloudKitSyncLease?.invalidate()
        retainedCloudKitSyncLease = nil
        defer { retainedCloudKitSyncTransport = nil }
        return retainedCloudKitSyncTransport
    }

    func deleteCloudKitLiveValidationZone() async throws {
        guard let databaseURL else {
            throw CloudKitSyncEngineTransportError.cloudKitFailure(
                "CloudKit live validation requires a persistent database"
            )
        }
        try await cloudKitTransport(
            databaseURL: databaseURL
        ).deleteLiveValidationZone()
    }

    func restartLocalFirstSyncAutomation() {
        localFirstSyncAutomationTask?.cancel()
        localFirstSyncAutomationTask = nil
        guard (try? assertEngineWriteAllowed()) != nil else { return }
        let policy = engine.preferences.localFirstSyncPolicy
        guard databaseURL != nil,
              engine.preferences.dataMode == .localFirst,
              policy.enabled,
              supportsRunnableLocalFirstSync(policy.endpoint),
              policy.endpoint != .iCloud || isICloudSyncEndpointAvailable,
              policy.mode == .automatic
        else { return }

        let intervalNanoseconds = UInt64(policy.intervalSeconds) * 1_000_000_000
        localFirstSyncAutomationTask = Task { [weak self] in
            while Task.isCancelled == false {
                await MainActor.run {
                    self?.localFirstSyncConfirmationRetryCount = 0
                    self?.runLocalFolderSync(
                        showToastOnSuccess: false,
                        retriesUserAttentionBlocks: false
                    )
                }
                do {
                    try await Task.sleep(nanoseconds: intervalNanoseconds)
                } catch {
                    return
                }
            }
        }
    }

    func restoreLocalFirstSyncStatus(
        interruptedOperation: DiagnosticOperationCapsule? = nil
    ) {
        guard let databaseURL else { return }
        do {
            let syncRepository = SQLiteSyncRepository(
                databaseURL: databaseURL
            )
            if let interruptedOperation,
               interruptedOperation.kind == .localFirstSync,
               interruptedOperation.outcome == .interrupted,
               let incidentID = interruptedOperation.incidentID
            {
                _ = try SQLiteLocalFirstSyncCoordinator
                    .persistInterruptedSyncFailureIfNewer(
                        at: interruptedOperation.finishedAt,
                        diagnosticCorrelation: DiagnosticOperationCorrelation(
                            operationID: interruptedOperation.operationID,
                            incidentID: incidentID
                        ),
                        in: syncRepository
                    )
            }
            localFirstSyncTimestamps =
                try SQLiteLocalFirstSyncCoordinator.timestamps(
                    in: syncRepository
                )
            guard let metadata = try syncRepository.metadata(
                for: SQLiteLocalFirstSyncCoordinator.lastStatusMetadataKey
            ) else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let status = try decoder.decode(
                SQLiteLocalFirstSyncStatus.self,
                from: metadata.value
            )
            switch status {
            case .idle:
                localFirstSyncMessage = nil
                resolveOperationFailure(.sync)
            case let .awaitingUploadConfirmation(result, _):
                localFirstSyncMessage = copy.localFirstSyncResult(
                    result,
                    unresolvedConflictCount: try syncRepository
                        .unresolvedConflicts().count
                )
            case let .succeeded(result):
                localFirstSyncMessage = copy.localFirstSyncResult(
                    result,
                    unresolvedConflictCount: try syncRepository.unresolvedConflicts().count
                )
                resolveOperationFailure(.sync)
            case let .failed(reason, _, failedAt, diagnosticCorrelation):
                let presentation = AppPresentation(
                    language: engine.preferences.language
                )
                let failureMessage: String = if let appReason = reason.appPresentationReason {
                    presentation
                        .syncFailureMessage(for: appReason)
                } else {
                    presentation
                        .failureMessage(for: .sync)
                }
                localFirstSyncMessage = failureMessage
                restorePersistedLocalFirstSyncFailure(
                    reason: reason,
                    failedAt: failedAt,
                    diagnosticCorrelation: diagnosticCorrelation,
                    failureMessage,
                    repository: syncRepository
                )
            }
        } catch {
            _ = recordOperationFailureEvidence(
                .persistence,
                error: error
            )
            let failureMessage = AppPresentation(
                language: engine.preferences.language
            ).failureMessage(for: .sync)
            localFirstSyncMessage = failureMessage
            showPersistentFailureMessage(
                failureMessage,
                context: .sync
            )
        }
    }

    private func restorePersistedLocalFirstSyncFailure(
        reason: SQLiteLocalFirstSyncFailureReason,
        failedAt: Date,
        diagnosticCorrelation: DiagnosticOperationCorrelation?,
        _ failureMessage: String,
        repository: SQLiteSyncRepository
    ) {
        let failure = reason.diagnosticFailure
        let diagnostics = diagnostics
        Task { [weak self] in
            let correlation = if let diagnosticCorrelation {
                diagnosticCorrelation
            } else {
                await diagnostics.persistedSyncFailureCorrelation(
                    failure: failure,
                    failedAt: failedAt
                )
            }
            guard let self,
                  persistedSyncFailureStillMatches(
                      reason: reason,
                      failedAt: failedAt,
                      diagnosticCorrelation: diagnosticCorrelation,
                      repository: repository
                  )
            else { return }
            diagnostics.record(
                .persistedSyncFailureLoaded(
                    failure: failure,
                    operationID: correlation?.operationID,
                    incidentID: correlation?.incidentID
                )
            )
            showPersistentFailureMessage(
                failureMessage,
                context: .sync,
                diagnosticIncidentID: correlation?.incidentID
            )
        }
    }

    private func persistedSyncFailureStillMatches(
        reason: SQLiteLocalFirstSyncFailureReason,
        failedAt: Date,
        diagnosticCorrelation: DiagnosticOperationCorrelation?,
        repository: SQLiteSyncRepository
    ) -> Bool {
        guard let metadata = try? repository.metadata(
            for: SQLiteLocalFirstSyncCoordinator.lastStatusMetadataKey
        ) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let status = try? decoder.decode(
            SQLiteLocalFirstSyncStatus.self,
            from: metadata.value
        ),
            case let .failed(
                currentReason,
                _,
                currentFailedAt,
                currentDiagnosticCorrelation
            ) = status
        else { return false }
        return currentReason == reason
            && currentFailedAt == failedAt
            && currentDiagnosticCorrelation == diagnosticCorrelation
    }

    static func configuredSyncFolderURL() -> URL {
        if let path = AppLaunchArguments.value(after: "--sync-folder-url"), path.isEmpty == false {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return AppLaunchArguments.validatedRuntimeProfile
            .localSyncRepositoryURL(baseURL: base)
    }

    static func configuredLocalFirstSyncEndpointURL(for endpoint: CloudSyncEndpointKind) -> URL? {
        switch endpoint {
        case .iCloud:
            return try? ICloudDriveSyncTransport.defaultRootURL(
                repositoryName: AppLaunchArguments.validatedRuntimeProfile
                    .iCloudRepositoryName
            )
        case .localFolder:
            return configuredSyncFolderURL()
        case .s3, .webDAV:
            return nil
        }
    }

    static func loadOrCreateSyncDeviceIdentity(
        databaseURL: URL,
        diagnostics: (any DiagnosticRecording)? = nil
    ) -> SyncDeviceIdentity {
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        do {
            if let identity = try syncRepository.loadDeviceIdentity() {
                return identity
            }
            let identity = SyncDeviceIdentity(
                displayName: Host.current().localizedName,
                createdAt: Date()
            )
            try syncRepository.saveDeviceIdentity(identity)
            return identity
        } catch {
            diagnostics?.record(
                .persistenceFailed(
                    failure: AppDiagnosticFailureMapping.map(error),
                    incidentID: DiagnosticIncidentID()
                )
            )
            return SyncDeviceIdentity(
                displayName: Host.current().localizedName,
                createdAt: Date()
            )
        }
    }

    private func diagnosticEndpoint(
        for endpoint: CloudSyncEndpointKind
    ) -> DiagnosticEndpoint {
        switch endpoint {
        case .iCloud:
            cloudKitSyncConfiguration == nil ? .iCloudDrive : .cloudKit
        case .localFolder:
            .localFolder
        case .s3, .webDAV:
            .none
        }
    }

    private func persistedSyncDiagnosticFailure(
        for error: Error
    ) -> DiagnosticFailure {
        ((error as? SQLiteLocalFirstSyncError)?.failureReason
            ?? .transportOrStorage).diagnosticFailure
    }
}
