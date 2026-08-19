import Foundation
@_spi(ClassificationUserDecision) import NoonmarkCore
import NoonmarkDayContext
import NoonmarkDiagnostics
import NoonmarkMacRuntime
import NoonmarkStorage
import NoonmarkSync

private enum AppReplicationConfigurationError: Error {
    case unavailableEndpoint
}

func appSQLiteFailurePoint(_ candidate: Error) -> String? {
    let candidate = if let wrapped = candidate as? EnginePersistenceCommitError {
        wrapped.underlying
    } else {
        candidate
    }
    guard let error = candidate as? SQLiteRepositoryError else { return nil }
    switch error {
    case .transientContention: return "transient-contention"
    case .openFailed: return "open"
    case .prepareFailed: return "prepare"
    case let .executeFailed(message, _):
        let source = if message.hasPrefix("engine repository ") {
            "engine"
        } else if message.hasPrefix("replication ledger ") {
            "replication-ledger"
        } else if message.hasPrefix("sync repository ") {
            "sync-repository"
        } else if message.hasPrefix("schema:") {
            "schema"
        } else {
            "unknown"
        }
        let depth = if message.contains("writerDepth=1") {
            "depth-1"
        } else if message.contains("writerDepth=2") {
            "depth-2"
        } else {
            "depth-other"
        }
        if message.contains("BEGIN IMMEDIATE") {
            return "execute-begin-immediate-\(source)-\(depth)"
        } else if message.contains("COMMIT") {
            return "execute-commit-\(source)"
        } else if message.contains("ROLLBACK") {
            return "execute-rollback-\(source)"
        } else if message.contains("PRAGMA foreign_keys") {
            return "execute-foreign-keys-\(source)"
        } else {
            return "execute-other-\(source)"
        }
    case .stepFailed: return "step"
    case .invalidStoredValue: return "stored-value"
    case .backupFailed: return "backup"
    }
}

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
    func autosaveSettingsPoemText(_ text: String) async -> Bool {
        do {
            try await commitEngineMutationInBackground(
                undoPolicy: .invalidate,
                publishesEngine: false
            ) { candidate, _ in
                var policy = candidate.preferences.settingsPoemDisplayPolicy
                policy.text = text
                candidate.updateSettingsPoemDisplayPolicy(policy)
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
            restartLocalFirstSyncAutomation()
            showToast(copy.dataModeChangedToast(for: dataMode))
        } catch {
            showOperationFailure(.preferences, error: error)
        }
    }

    func setLocalFirstSyncEndpoint(_ endpoint: CloudSyncEndpointKind) {
        guard engine.preferences.localFirstSyncPolicy.endpoint != endpoint else {
            return
        }
        var policy = engine.preferences.localFirstSyncPolicy
        policy.endpoint = endpoint
        if supportsRunnableLocalFirstSync(endpoint) == false {
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
        guard engine.preferences.localFirstSyncPolicy.enabled != enabled else {
            return
        }
        var policy = engine.preferences.localFirstSyncPolicy
        if enabled, supportsRunnableLocalFirstSync(policy.endpoint) == false {
            showToast(copy.localFirstSyncUnavailableToast)
            return
        }
        if enabled, policy.endpoint == .iCloud,
           isICloudSyncEndpointAvailable == false
        {
            showToast(copy.localFirstSyncUnavailableToast)
            return
        }
        policy.enabled = enabled
        commitLocalFirstSyncPolicy(policy)
    }

    private func commitLocalFirstSyncPolicy(
        _ policy: LocalFirstCloudSyncPolicy
    ) {
        do {
            try commitEngineMutation(undoPolicy: .invalidate) { candidate, _ in
                candidate.updateLocalFirstSyncPolicy(policy)
            }
            restartLocalFirstSyncAutomation()
            showToast(copy.localFirstSyncChangedToast)
        } catch {
            showOperationFailure(.preferences, error: error)
        }
    }

    func syncLocalFolderNow() {
        guard engine.preferences.dataMode == .localFirst,
              engine.preferences.localFirstSyncPolicy.enabled,
              supportsRunnableLocalFirstSync(
                  engine.preferences.localFirstSyncPolicy.endpoint
              )
        else {
            showToast(copy.localFirstSyncUnavailableToast)
            return
        }
        guard localFirstReplicationCommandTask == nil else { return }
        localFirstReplicationCommandTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { localFirstReplicationCommandTask = nil }
            let operation = diagnostics.startOperation(
                kind: .localFirstSync,
                endpoint: diagnosticEndpoint(
                    for: engine.preferences.localFirstSyncPolicy.endpoint
                )
            )
            localFirstReplicationDiagnosticOperationID = operation.id
            defer {
                if localFirstReplicationDiagnosticOperationID == operation.id {
                    localFirstReplicationDiagnosticOperationID = nil
                }
            }
            operation.stage(.transportPrepare)
            do {
                let runtime = try prepareLocalFirstReplicationRuntime()
                _ = try await runtime.send(.enable)
                let result = try await runtime.send(.reconcile(now: Date()))
                try Task.checkCancellation()
                operation.succeed(
                    progress: DiagnosticProgress(
                        recordCount: result.confirmedLocalPublicationCount
                            + result.appliedRemotePublicationCount,
                        pendingCount: result.pendingLocalPublicationCount,
                        appliedCount: result.appliedRemotePublicationCount,
                        conflictCount: result.actionableForkConflict?
                            .conflicts.count ?? 0
                    )
                )
                installLocalFirstReplicationState(result)
                if result.convergence == .converged {
                    showToast(localFirstSyncMessage ?? copy.localFirstSyncChangedToast)
                }
            } catch is CancellationError {
                return
            } catch {
                localFirstReplicationLastSQLiteFailurePoint =
                    appSQLiteFailurePoint(error)
                localFirstReplicationLastErrorKind = String(
                    describing: type(of: error)
                )
                let incidentID = operation.fail(
                    AppDiagnosticFailureMapping.map(error)
                )
                presentLocalFirstReplicationFailure(
                    error,
                    diagnosticIncidentID: incidentID
                )
            }
        }
    }

    func restartLocalFirstSyncAutomation() {
        let previous = localFirstReplicationConfigurationTask
        localFirstReplicationConfigurationTask = Task { @MainActor [weak self] in
            if let previous {
                _ = await previous.result
            }
            guard let self else { return }
            let policy = engine.preferences.localFirstSyncPolicy
            guard databaseURL != nil,
                  engine.preferences.dataMode == .localFirst,
                  policy.enabled,
                  supportsRunnableLocalFirstSync(policy.endpoint)
            else {
                var disableFailure: Error?
                if policy.enabled == false,
                   let runtime = localFirstReplicationRuntime
                {
                    do {
                        let disabled = try await runtime.send(.disable)
                        installLocalFirstReplicationState(disabled)
                    } catch {
                        disableFailure = error
                    }
                }
                var shutdownFailure: Error?
                do {
                    try await shutdownAndReleaseLocalFirstReplication()
                } catch {
                    shutdownFailure = error
                }
                if let failure = disableFailure ?? shutdownFailure {
                    localFirstReplicationLastErrorKind = String(
                        describing: type(of: failure)
                    )
                    presentLocalFirstReplicationFailure(failure)
                }
                return
            }
            do {
                if localFirstReplicationEndpointKind != nil,
                   localFirstReplicationEndpointKind != policy.endpoint
                {
                    try await shutdownAndReleaseLocalFirstReplication()
                }
                let runtime = try prepareLocalFirstReplicationRuntime()
                _ = try await runtime.send(.enable)
                if policy.mode == .automatic {
                    try await runtime.startAutomatic(
                        interval: .seconds(policy.intervalSeconds)
                    )
                } else {
                    await runtime.stopAutomatic()
                }
                resolveOperationFailure(.sync)
            } catch is CancellationError {
                return
            } catch {
                localFirstReplicationLastErrorKind = String(
                    describing: type(of: error)
                )
                presentLocalFirstReplicationFailure(error)
            }
        }
    }

    func restoreLocalFirstSyncStatus(
        interruptedOperation: DiagnosticOperationCapsule? = nil
    ) {
        guard let databaseURL else { return }
        do {
            if let state = try LocalFirstReplication.persistedState(
                databaseURL: databaseURL
            ) {
                installLocalFirstReplicationState(state)
            }
            if interruptedOperation?.kind == .localFirstSync,
               interruptedOperation?.outcome == .interrupted
            {
                localFirstSyncMessage = copy
                    .localFirstSyncInterruptedRecoveryMessage
            }
        } catch {
            presentLocalFirstReplicationFailure(error)
        }
    }

    func shutdownAndReleaseLocalFirstReplication() async throws {
        if let runtime = localFirstReplicationRuntime {
            _ = try await runtime.shutdown()
        }
        localFirstReplicationCommandTask?.cancel()
        localFirstReplicationCommandTask = nil
        localFirstReplicationStateTask?.cancel()
        localFirstReplicationStateTask = nil
        localFirstReplicationRuntime = nil
        localFirstReplicationEndpointKind = nil
        localFirstReplicationLifecycleE2EEndpoint = nil
        isLocalFirstSyncing = false
        isLocalFirstSyncStopping = false
    }

    var isICloudDriveAvailable: Bool {
        (try? ICloudDriveRepositoryLocator.defaultRootURL(
            repositoryName: AppLaunchArguments.validatedRuntimeProfile
                .iCloudRepositoryName
        )) != nil
    }

    var isICloudSyncEndpointAvailable: Bool {
        isICloudDriveAvailable
    }

    static func configuredSyncFolderURL() -> URL {
        if let path = AppLaunchArguments.value(after: "--sync-folder-url"),
           path.isEmpty == false
        {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support",
                isDirectory: true
            )
        return AppLaunchArguments.validatedRuntimeProfile
            .localSyncRepositoryURL(baseURL: base)
    }

    static func configuredLocalFirstSyncEndpointURL(
        for endpoint: CloudSyncEndpointKind
    ) -> URL? {
        switch endpoint {
        case .iCloud:
            try? ICloudDriveRepositoryLocator.defaultRootURL(
                repositoryName: AppLaunchArguments.validatedRuntimeProfile
                    .iCloudRepositoryName
            )
        case .localFolder:
            configuredSyncFolderURL()
        case .s3, .webDAV:
            nil
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

    func reportLocalFirstReplicationFailure(_ error: Error) {
        presentLocalFirstReplicationFailure(error)
    }
}

private extension NoonmarkStore {
    func supportsRunnableLocalFirstSync(
        _ endpoint: CloudSyncEndpointKind
    ) -> Bool {
        endpoint == .iCloud || endpoint == .localFolder
    }

    func prepareLocalFirstReplicationRuntime() throws
        -> LocalFirstReplication
    {
        if let runtime = localFirstReplicationRuntime {
            return runtime
        }
        guard let databaseURL else {
            throw AppReplicationConfigurationError.unavailableEndpoint
        }
        let endpointKind = engine.preferences.localFirstSyncPolicy.endpoint
        let authority = try SQLiteReplicationLedger(
            databaseURL: databaseURL
        ).cleanCutAuthority()
        var endpoint: any ReplicationEndpoint
        let generationID: UUID
        let repositoryWasCreated: Bool
        switch endpointKind {
        case .iCloud:
            let iCloud = if let round = try appReplicationV2StressICloudRound() {
                try ICloudDriveReplicationEndpoint(
                    round: round,
                    existingGenerationID: authority?.generationID
                )
            } else {
                try ICloudDriveReplicationEndpoint(
                    repositoryName: AppLaunchArguments.validatedRuntimeProfile
                        .iCloudRepositoryName,
                    existingGenerationID: authority?.generationID
                )
            }
            endpoint = iCloud
            generationID = iCloud.generationID
            repositoryWasCreated = iCloud.repositoryWasCreated
        case .localFolder:
            let folder = try ContentAddressedFileReplicationEndpoint
                .openCleanRepository(
                    rootURL: Self.configuredSyncFolderURL(),
                    generationID: { authority?.generationID ?? UUID() }
                )
            endpoint = folder
            generationID = folder.generationID
            repositoryWasCreated = folder.repositoryWasCreated
        case .s3, .webDAV:
            throw AppReplicationConfigurationError.unavailableEndpoint
        }
        if Bundle.main.bundleIdentifier == "app.noonmark.mac.e2e",
           AppLaunchArguments.contains(
               "--e2e-replication-v2-lifecycle-endpoint"
           )
        {
            let lifecycleEndpoint = ReplicationV2LifecycleE2EEndpoint(
                underlying: endpoint
            )
            endpoint = lifecycleEndpoint
            localFirstReplicationLifecycleE2EEndpoint = lifecycleEndpoint
        } else {
            localFirstReplicationLifecycleE2EEndpoint = nil
        }
        let runtime = try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: endpoint,
            generationID: generationID,
            producerID: UUID(),
            publicationWatermarkStore:
                KeychainReplicationPublicationWatermarkStore(
                    service: AppLaunchArguments.validatedRuntimeProfile
                        .replicationWatermarkKeychainService
                ),
            repositoryWasCreated: repositoryWasCreated
        )
        localFirstReplicationRuntime = runtime
        localFirstReplicationEndpointKind = endpointKind
        subscribeToLocalFirstReplication(runtime)
        return runtime
    }

    func subscribeToLocalFirstReplication(
        _ runtime: LocalFirstReplication
    ) {
        localFirstReplicationStateTask?.cancel()
        localFirstReplicationStateTask = Task { @MainActor [weak self] in
            let stream = await runtime.states()
            for await state in stream {
                guard Task.isCancelled == false, let self else { return }
                installLocalFirstReplicationState(state)
            }
        }
    }

    func installLocalFirstReplicationState(
        _ state: LocalFirstReplicationState
    ) {
        isLocalFirstSyncing = state.worker == .running
        isLocalFirstSyncStopping = state.worker == .stopping
            || state.worker == .stoppingDelayed
        if let lastSyncedAt = state.lastSyncedAt {
            localFirstSyncTimestamps = SQLiteLocalFirstSyncTimestamps(
                lastSyncedAt: lastSyncedAt,
                lastEffectiveSyncedAt: state.lastEffectiveSyncedAt
            )
        }
        switch state.worker {
        case .running:
            localFirstSyncMessage = copy.syncingWithEllipsis
        case .stopping, .stoppingDelayed:
            localFirstSyncMessage = copy.localFirstSyncStopping
        case .disabled:
            localFirstSyncMessage = copy.localFirstSyncDisabled
            resolveOperationFailure(.sync)
        case .idle:
            switch state.convergence {
            case .converged:
                localFirstSyncMessage = engine.preferences.language == .chinese
                    ? "同步完成"
                    : "Sync complete"
                resolveOperationFailure(.sync)
            case .waitingForEndpoint:
                localFirstSyncMessage = engine.preferences.language == .chinese
                    ? "等待 iCloud 上传确认"
                    : "Waiting for iCloud upload confirmation"
            case .blocked:
                localFirstSyncMessage = replicationIncidentMessage(
                    state.incident
                )
            }
        }
        if state.appliedRemotePublicationCount > 0 {
            do {
                try installExternallyLoadedEngineAfterReplication()
            } catch {
                presentLocalFirstReplicationFailure(error)
            }
        }
    }

    func installExternallyLoadedEngineAfterReplication() throws {
        guard let repository else { return }
        let moment = try dayContext.moment()
        let loaded = try repository.load()
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

    func presentLocalFirstReplicationFailure(
        _ error: Error,
        diagnosticIncidentID: DiagnosticIncidentID? = nil
    ) {
        if error as? ReplicationRepositoryBootstrapError
            == .legacyRepositoryRequiresManualReset
        {
            localFirstSyncMessage = engine.preferences.language == .chinese
                ? "检测到旧同步目录。请您在 Finder 中手工删除该目录后重试；晷迹不会自动删除或迁移其中任何内容。"
                : "A legacy sync directory was found. Delete it manually in Finder and retry; Noonmark will not delete or migrate it."
        } else if error as? ReplicationRepositoryBootstrapError
            == .markerPublicationInProgress
        {
            localFirstSyncMessage = engine.preferences.language == .chinese
                ? "同步仓库仍在完成初始化，请稍后重试。"
                : "The sync repository is still initializing. Try again shortly."
        } else {
            localFirstSyncMessage = AppPresentation(
                language: engine.preferences.language
            ).failureMessage(for: .sync)
        }
        showOperationFailure(
            .sync,
            error: error,
            diagnosticIncidentID: diagnosticIncidentID
        )
    }

    func replicationIncidentMessage(
        _ incident: LocalFirstReplicationIncident?
    ) -> String {
        let chinese = engine.preferences.language == .chinese
        switch incident {
        case .endpointRequiresUserAttention:
            return chinese ? "同步端点需要您处理" : "The sync endpoint needs attention"
        case .endpointCorruption:
            return chinese ? "同步仓库完整性校验失败" : "Sync repository integrity check failed"
        case .producerForkDetected:
            return chinese ? "检测到同步分叉，等待冲突决定" : "A sync fork needs a conflict decision"
        case .repairBaselineRejected:
            return chinese ? "同步修复基线被拒绝" : "The sync repair baseline was rejected"
        case .runtimeFailure, nil:
            return chinese ? "同步未完成，请重试" : "Sync did not complete; retry"
        }
    }

    func diagnosticEndpoint(
        for endpoint: CloudSyncEndpointKind
    ) -> DiagnosticEndpoint {
        switch endpoint {
        case .iCloud: .iCloudDrive
        case .localFolder: .localFolder
        case .s3, .webDAV: .none
        }
    }
}

private func appReplicationV2StressICloudRound() throws
    -> ICloudAppendOnlyTestRound?
{
    let isStress = AppLaunchArguments.contains(
        "--e2e-replication-v2-stress-exercise"
    ) || AppLaunchArguments.contains(
        "--e2e-replication-v2-stress-verify-restart"
    )
    guard isStress else { return nil }
    guard AppLaunchArguments.validatedRuntimeProfile == .e2e,
          let sessionValue = AppLaunchArguments.value(
              after: "--e2e-replication-v2-stress-icloud-session-id"
          ),
          let roundValue = AppLaunchArguments.value(
              after: "--e2e-replication-v2-stress-icloud-round-id"
          ),
          let sessionID = UUID(uuidString: sessionValue),
          let roundID = UUID(uuidString: roundValue)
    else {
        throw AppReplicationConfigurationError.unavailableEndpoint
    }
    return try ICloudAppendOnlyTestNamespace.reopenRound(
        sessionID: sessionID,
        roundID: roundID
    )
}
