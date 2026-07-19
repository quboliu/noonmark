import Foundation
@_spi(ClassificationUserDecision) import NoonmarkCore
import NoonmarkDayContext
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
                    showOperationFailure(.sync, error: error)
                    localFirstSyncMessage = operationFailure
                    return
                }
            }
        }
        policy.enabled = enabled
        commitLocalFirstSyncPolicy(policy)
    }

    var isICloudDriveAvailable: Bool {
        (try? ICloudDriveSyncTransport.defaultRootURL()) != nil
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
            _ = try ICloudDriveSyncTransport.defaultRootURL()
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
                showOperationFailure(.sync, error: error)
                localFirstSyncMessage = operationFailure
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
            showOperationFailure(.sync, error: error)
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
        localFirstSyncMessage = nil
        resetPersistedLocalFirstSyncStatus()
        restartLocalFirstSyncAutomation()
        showToast(copy.localFirstSyncChangedToast)
    }

    func syncLocalFolderNow() {
        runLocalFolderSync(showToastOnSuccess: true)
    }

    private func runLocalFolderSync(showToastOnSuccess: Bool) {
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

        let transport: any SyncRecordTransport
        do {
            transport = try localFirstSyncTransport(
                for: engine.preferences.localFirstSyncPolicy.endpoint,
                databaseURL: databaseURL
            )
        } catch {
            showOperationFailure(.sync, error: error)
            localFirstSyncMessage = operationFailure
            return
        }

        do {
            try save(
                engine,
                mutationAt: engine.nextMutationDate(
                    reference: naturalDay.instant
                )
            )
        } catch {
            showOperationFailure(.persistence, error: error)
            localFirstSyncMessage = operationFailure
            return
        }
        isLocalFirstSyncing = true
        localFirstSyncMessage = copy.syncingWithEllipsis
        Task { [databaseURL, transport] in
            do {
                let coordinator = SQLiteLocalFirstSyncCoordinator(
                    databaseURL: databaseURL,
                    transport: transport
                )
                let result = try await coordinator.sync()
                let unresolvedConflictCount = try SQLiteSyncRepository(
                    databaseURL: databaseURL
                ).unresolvedConflicts().count
                try await MainActor.run {
                    let loaded = try SQLiteEngineRepository(
                        databaseURL: databaseURL
                    ).load()
                    let moment = try dayContext.moment()
                    let previousLanguage = engine.preferences.language
                    let automationConfigurationChanged =
                        engine.preferences.dataMode != loaded.preferences.dataMode
                        || engine.preferences.localFirstSyncPolicy
                            != loaded.preferences.localFirstSyncPolicy
                    try installExternallyLoadedEngine(
                        loaded,
                        moment: moment
                    )
                    Theme.apply(engine.preferences.theme)
                    if previousLanguage != engine.preferences.language {
                        onLanguageChange?()
                    }
                    isLocalFirstSyncing = false
                    localFirstSyncMessage = copy.localFirstSyncResult(
                        result,
                        unresolvedConflictCount: unresolvedConflictCount
                    )
                    if showToastOnSuccess {
                        showToast(localFirstSyncMessage ?? copy.localFirstSyncChangedToast)
                    }
                    if automationConfigurationChanged {
                        restartLocalFirstSyncAutomation()
                    }
                }
            } catch {
                await MainActor.run {
                    isLocalFirstSyncing = false
                    showOperationFailure(.sync, error: error)
                    localFirstSyncMessage = operationFailure
                }
            }
        }
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
        databaseURL: URL
    ) throws -> any SyncRecordTransport {
        switch endpoint {
        case .iCloud:
            if cloudKitSyncConfiguration != nil {
                return try cloudKitTransport(databaseURL: databaseURL)
            }
            return try ICloudDriveSyncTransport()
        case .localFolder:
            return LocalFolderSyncTransport(
                rootURL: Self.configuredSyncFolderURL()
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
                    self?.runLocalFolderSync(showToastOnSuccess: false)
                }
                do {
                    try await Task.sleep(nanoseconds: intervalNanoseconds)
                } catch {
                    return
                }
            }
        }
    }

    func restoreLocalFirstSyncStatus() {
        guard let databaseURL else { return }
        let policy = engine.preferences.localFirstSyncPolicy
        guard engine.preferences.dataMode == .localFirst,
              policy.enabled,
              supportsRunnableLocalFirstSync(policy.endpoint)
        else {
            localFirstSyncMessage = nil
            return
        }
        if policy.endpoint == .iCloud {
            do {
                try validateICloudSyncEndpoint()
            } catch {
                localFirstSyncMessage = AppPresentation(
                    language: engine.preferences.language
                ).failureMessage(for: .sync)
                return
            }
        }
        do {
            let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
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
            case let .succeeded(result):
                localFirstSyncMessage = copy.localFirstSyncResult(
                    result,
                    unresolvedConflictCount: try syncRepository.unresolvedConflicts().count
                )
            case let .failed(message, _):
                NSLog("Noonmark previous sync failed: %@", message)
                localFirstSyncMessage = AppPresentation(
                    language: engine.preferences.language
                ).failureMessage(for: .sync)
            }
        } catch {
            NSLog("Noonmark sync status load failed: %@", String(describing: error))
            localFirstSyncMessage = AppPresentation(
                language: engine.preferences.language
            ).failureMessage(for: .sync)
        }
    }

    static func configuredSyncFolderURL() -> URL {
        if let path = AppLaunchArguments.value(after: "--sync-folder-url"), path.isEmpty == false {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("noonmark", isDirectory: true)
            .appendingPathComponent("sync-repository", isDirectory: true)
    }

    static func configuredLocalFirstSyncEndpointURL(for endpoint: CloudSyncEndpointKind) -> URL? {
        switch endpoint {
        case .iCloud:
            return try? ICloudDriveSyncTransport.defaultRootURL()
        case .localFolder:
            return configuredSyncFolderURL()
        case .s3, .webDAV:
            return nil
        }
    }

    static func loadOrCreateSyncDeviceIdentity(databaseURL: URL) -> SyncDeviceIdentity {
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
            NSLog("Noonmark sync identity load failed: %@", String(describing: error))
            return SyncDeviceIdentity(
                displayName: Host.current().localizedName,
                createdAt: Date()
            )
        }
    }
}
