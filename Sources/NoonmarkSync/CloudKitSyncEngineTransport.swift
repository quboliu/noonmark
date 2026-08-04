import CloudKit
import Foundation

enum CloudKitRecordSaveFailureDisposition: Equatable {
    case mergeServerRecord
    case provisionMissingZone
    case blockDeletedZone
    case blockDeletedRecord
    case retry
    case fail
}

enum CloudKitErrorRetryPolicy {
    static func isRetryable(_ code: CKError.Code) -> Bool {
        switch code {
        case .networkFailure, .networkUnavailable, .zoneBusy,
             .serviceUnavailable, .requestRateLimited,
             .notAuthenticated, .operationCancelled:
            true
        default:
            false
        }
    }
}

enum CloudKitRecordSaveFailurePolicy {
    static func disposition(
        for code: CKError.Code,
        zoneWasProvisioned: Bool
    ) -> CloudKitRecordSaveFailureDisposition {
        switch code {
        case .serverRecordChanged:
            .mergeServerRecord
        case .zoneNotFound:
            zoneWasProvisioned ? .blockDeletedZone : .provisionMissingZone
        case .unknownItem:
            .blockDeletedRecord
        case .userDeletedZone:
            .blockDeletedZone
        default:
            CloudKitErrorRetryPolicy.isRetryable(code) ? .retry : .fail
        }
    }
}

public final actor CloudKitSyncEngineTransport: SyncRecordTransport {
    public static let defaultZoneName = "NoonmarkUserDataV1"
    public static let liveValidationZonePrefix = "NoonmarkLiveValidation-"

    public let containerIdentifier: String
    public let zoneID: CKRecordZone.ID

    private let session: CloudKitSyncSession
    private let automaticallySync: Bool
    private var cloudContainer: CKContainer?
    private var runtimeEnvironment: CloudKitSyncEnvironment?
    private var syncEngine: CKSyncEngine?
    private var operationFailure: (any Error)?

    public init(
        containerIdentifier: String,
        persistence: any CloudKitSyncPersistence,
        zoneName: String,
        automaticallySync: Bool = true
    ) throws {
        let trimmedContainerID = containerIdentifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let trimmedZoneName = zoneName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard trimmedContainerID.hasPrefix("iCloud."),
              trimmedContainerID.count > "iCloud.".count,
              trimmedZoneName.isEmpty == false
        else {
            throw CloudKitSyncEngineTransportError.cloudKitFailure(
                "invalid CloudKit container or zone identifier"
            )
        }

        self.containerIdentifier = trimmedContainerID
        zoneID = CKRecordZone.ID(zoneName: trimmedZoneName)
        self.automaticallySync = automaticallySync
        session = CloudKitSyncSession(
            persistence: persistence,
            codec: CloudKitSyncRecordCodec(zoneID: zoneID)
        )
    }

    public func accountAvailability() async throws -> CloudKitAccountAvailability {
        let container = try resolvedContainer()
        do {
            return await CloudKitAccountAvailability(try container.accountStatus())
        } catch {
            throw translatedCloudKitError(error)
        }
    }

    public func push(_ records: [SyncRecord]) async throws {
        guard records.isEmpty == false else { return }
        let engine = try await preparedEngine()
        let recordIDs = try await session.stageLocal(records)
        try await enqueueZoneIfNeeded(on: engine)
        engine.state.add(
            pendingRecordZoneChanges: recordIDs.map {
                .saveRecord($0)
            }
        )
        operationFailure = nil
        do {
            try await engine.sendChanges(
                CKSyncEngine.SendChangesOptions(
                    scope: .zoneIDs([zoneID])
                )
            )
        } catch {
            throw translatedCloudKitError(error)
        }
        try throwOperationFailureIfPresent()
        let stillPending = pendingSaveRecordIDs(on: engine)
        guard recordIDs.allSatisfy({ stillPending.contains($0) == false }) else {
            throw CloudKitSyncEngineTransportError.cloudKitFailure(
                "one or more records remain pending after manual send"
            )
        }
    }

    public func fetchAll() async throws -> [SyncRecord] {
        let engine = try await preparedEngine()
        try await enqueueZoneIfNeeded(on: engine)
        operationFailure = nil
        do {
            try await engine.sendChanges(
                CKSyncEngine.SendChangesOptions(
                    scope: .zoneIDs([zoneID])
                )
            )
            try await engine.fetchChanges(
                CKSyncEngine.FetchChangesOptions(
                    scope: .zoneIDs([zoneID])
                )
            )
        } catch {
            throw translatedCloudKitError(error)
        }
        try throwOperationFailureIfPresent()
        return try await session.records()
    }

    public func deleteLiveValidationZone() async throws {
        guard zoneID.zoneName.hasPrefix(Self.liveValidationZonePrefix),
              zoneID.zoneName.count > Self.liveValidationZonePrefix.count
        else {
            throw CloudKitSyncEngineTransportError.liveValidationZoneRequired
        }
        let availability = try await accountAvailability()
        guard availability.canSync else {
            throw CloudKitSyncEngineTransportError.accountUnavailable(
                availability
            )
        }
        do {
            _ = try await resolvedContainer().privateCloudDatabase
                .deleteRecordZone(withID: zoneID)
        } catch let error as CKError where error.code == .zoneNotFound {
            return
        } catch {
            throw translatedCloudKitError(error)
        }
    }

    public func shutdown() async {
        if let syncEngine {
            await syncEngine.cancelOperations()
        }
        syncEngine = nil
        cloudContainer = nil
        operationFailure = nil
    }

    private func preparedEngine() async throws -> CKSyncEngine {
        let container = try resolvedContainer()
        guard let runtimeEnvironment else {
            throw CloudKitSyncEngineTransportError.missingEntitlement(
                CloudKitEntitlementProbe.environmentKey
            )
        }
        try await session.bindScope(
            CloudKitSyncScopeIdentity(
                containerIdentifier: containerIdentifier,
                zoneName: zoneID.zoneName,
                environment: runtimeEnvironment
            )
        )
        try await session.blockingErrorIfPresent()
        let availability: CloudKitAccountAvailability
        do {
            availability = await CloudKitAccountAvailability(
                try container.accountStatus()
            )
        } catch {
            throw translatedCloudKitError(error)
        }
        guard availability.canSync else {
            throw CloudKitSyncEngineTransportError.accountUnavailable(
                availability
            )
        }
        let userRecordID: CKRecord.ID
        do {
            userRecordID = try await container.userRecordID()
        } catch {
            throw translatedCloudKitError(error)
        }
        try await session.bindAccount(recordName: userRecordID.recordName)

        if let syncEngine { return syncEngine }
        var configuration = await CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: try session.engineStateSerialization(),
            delegate: self
        )
        configuration.automaticallySync = automaticallySync
        configuration.subscriptionID = "noonmark-sync-engine-v1"
        let engine = CKSyncEngine(configuration)
        syncEngine = engine
        return engine
    }

    private func resolvedContainer() throws -> CKContainer {
        if let cloudContainer { return cloudContainer }
        runtimeEnvironment = try CloudKitEntitlementProbe.validateCurrentProcess(
            containerIdentifier: containerIdentifier
        )
        let container = CKContainer(identifier: containerIdentifier)
        cloudContainer = container
        return container
    }

    private func enqueueZoneIfNeeded(on engine: CKSyncEngine) async throws {
        guard try await session.zoneIsProvisioned() == false else { return }
        engine.state.add(
            pendingDatabaseChanges: [
                .saveZone(CKRecordZone(zoneID: zoneID))
            ]
        )
    }

    private func throwOperationFailureIfPresent() throws {
        guard let operationFailure else { return }
        self.operationFailure = nil
        throw operationFailure
    }

    private func pendingSaveRecordIDs(on engine: CKSyncEngine) -> Set<CKRecord.ID> {
        Set(engine.state.pendingRecordZoneChanges.compactMap { change in
            if case let .saveRecord(recordID) = change {
                return recordID
            }
            return nil
        })
    }

    private func recordOperationFailure(_ error: Error) {
        if let error = error as? CloudKitSyncEngineTransportError {
            operationFailure = error
        } else if error is SyncRecordTransportError {
            // Typed sync errors carry a privacy-safe diagnostic mapping of
            // their own; keep them intact instead of reclassifying them as a
            // generic CloudKit failure.
            operationFailure = error
        } else {
            operationFailure = CloudKitSyncEngineTransportError.cloudKitFailure(
                String(describing: error)
            )
        }
    }

    private func translatedCloudKitError(
        _ error: Error
    ) -> CloudKitSyncEngineTransportError {
        if let error = error as? CloudKitSyncEngineTransportError {
            return error
        }
        guard let cloudError = error as? CKError else {
            return .cloudKitFailure(String(describing: error))
        }
        var message = "code=\(cloudError.code.rawValue)"
        if let retryAfter = cloudError.retryAfterSeconds {
            message += " retryAfter=\(retryAfter)"
        }
        return .cloudKitFailure(message)
    }
}

extension CloudKitSyncEngineTransport: CKSyncEngineDelegate {
    public func handleEvent(
        _ event: CKSyncEngine.Event,
        syncEngine: CKSyncEngine
    ) async {
        do {
            switch event {
            case let .stateUpdate(event):
                try await session.updateEngineState(event.stateSerialization)
            case let .accountChange(event):
                try await handleAccountChange(event, syncEngine: syncEngine)
            case let .fetchedDatabaseChanges(event):
                try await handleFetchedDatabaseChanges(event)
            case let .fetchedRecordZoneChanges(event):
                try await handleFetchedRecordZoneChanges(
                    event,
                    syncEngine: syncEngine
                )
            case let .sentDatabaseChanges(event):
                try await handleSentDatabaseChanges(event)
            case let .sentRecordZoneChanges(event):
                try await handleSentRecordZoneChanges(
                    event,
                    syncEngine: syncEngine
                )
            case .willFetchChanges, .willFetchRecordZoneChanges,
                 .didFetchRecordZoneChanges, .didFetchChanges,
                 .willSendChanges, .didSendChanges:
                break
            @unknown default:
                recordOperationFailure(
                    CloudKitSyncEngineTransportError.cloudKitFailure(
                        "unknown CKSyncEngine event"
                    )
                )
            }
        } catch {
            recordOperationFailure(error)
        }
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let changes = syncEngine.state.pendingRecordZoneChanges.filter {
            context.options.scope.contains($0)
        }
        var recordsToSave: [CKRecord] = []

        for change in changes {
            switch change {
            case let .saveRecord(recordID):
                do {
                    guard let record = try await session.cloudRecord(
                        for: recordID
                    ) else {
                        syncEngine.state.remove(
                            pendingRecordZoneChanges: [change]
                        )
                        throw CloudKitSyncEngineTransportError.cloudKitFailure(
                            "pending record is missing from the durable mirror"
                        )
                    }
                    recordsToSave.append(record)
                } catch {
                    recordOperationFailure(error)
                    return nil
                }
            case .deleteRecord:
                recordOperationFailure(
                    CloudKitSyncEngineTransportError.cloudKitFailure(
                        "hard-delete pending changes are not supported"
                    )
                )
                return nil
            @unknown default:
                recordOperationFailure(
                    CloudKitSyncEngineTransportError.cloudKitFailure(
                        "unknown pending CloudKit record change"
                    )
                )
                return nil
            }
        }
        return CKSyncEngine.RecordZoneChangeBatch(
            recordsToSave: recordsToSave,
            recordIDsToDelete: [],
            atomicByZone: true
        )
    }

    public func nextFetchChangesOptions(
        _ context: CKSyncEngine.FetchChangesContext,
        syncEngine _: CKSyncEngine
    ) async -> CKSyncEngine.FetchChangesOptions {
        CKSyncEngine.FetchChangesOptions(
            scope: .zoneIDs([zoneID]),
            operationGroup: context.options.operationGroup
        )
    }

    private func handleAccountChange(
        _ event: CKSyncEngine.Event.AccountChange,
        syncEngine: CKSyncEngine
    ) async throws {
        switch event.changeType {
        case let .signIn(currentUser):
            try await session.bindAccount(recordName: currentUser.recordName)
            try await enqueueZoneIfNeeded(on: syncEngine)
        case .signOut:
            throw CloudKitSyncEngineTransportError.accountUnavailable(
                .noAccount
            )
        case let .switchAccounts(_, currentUser):
            try await session.bindAccount(recordName: currentUser.recordName)
        @unknown default:
            throw CloudKitSyncEngineTransportError.accountUnavailable(
                .couldNotDetermine
            )
        }
    }

    private func handleFetchedDatabaseChanges(
        _ event: CKSyncEngine.Event.FetchedDatabaseChanges
    ) async throws {
        if event.modifications.contains(where: { $0.zoneID == zoneID }) {
            try await session.markZoneProvisioned()
        }
        if event.deletions.contains(where: { $0.zoneID == zoneID }) {
            try await session.block(.recordZoneDeleted)
            throw CloudKitSyncEngineTransportError.recordZoneDeleted
        }
    }

    private func handleFetchedRecordZoneChanges(
        _ event: CKSyncEngine.Event.FetchedRecordZoneChanges,
        syncEngine: CKSyncEngine
    ) async throws {
        let deletions = event.deletions.filter { $0.recordID.zoneID == zoneID }
        if let deletion = deletions.first {
            let reason = CloudKitSyncBlockReason
                .unexpectedRemoteRecordDeletion(deletion.recordID.recordName)
            try await session.block(reason)
            throw CloudKitSyncEngineTransportError
                .unexpectedRemoteRecordDeletion(deletion.recordID.recordName)
        }
        let records = event.modifications
            .map(\.record)
            .filter { $0.recordID.zoneID == zoneID }
        guard records.isEmpty == false else { return }
        let reuploadIDs = try await session.applyFetched(records)
        syncEngine.state.add(
            pendingRecordZoneChanges: reuploadIDs.map {
                .saveRecord($0)
            }
        )
    }

    private func handleSentDatabaseChanges(
        _ event: CKSyncEngine.Event.SentDatabaseChanges
    ) async throws {
        if event.savedZones.contains(where: { $0.zoneID == zoneID }) {
            try await session.markZoneProvisioned()
        }
        for failure in event.failedZoneSaves where failure.zone.zoneID == zoneID {
            if failure.error.code == .userDeletedZone {
                try await session.block(.recordZoneDeleted)
                throw CloudKitSyncEngineTransportError.recordZoneDeleted
            }
            if CloudKitErrorRetryPolicy.isRetryable(failure.error.code) == false {
                throw translatedCloudKitError(failure.error)
            }
        }
    }

    private func handleSentRecordZoneChanges(
        _ event: CKSyncEngine.Event.SentRecordZoneChanges,
        syncEngine: CKSyncEngine
    ) async throws {
        if event.savedRecords.isEmpty == false {
            let reuploadIDs = try await session.applyFetched(
                event.savedRecords.filter { $0.recordID.zoneID == zoneID }
            )
            syncEngine.state.add(
                pendingRecordZoneChanges: reuploadIDs.map {
                    .saveRecord($0)
                }
            )
        }

        for failure in event.failedRecordSaves
        where failure.record.recordID.zoneID == zoneID {
            let recordID = failure.record.recordID
            let zoneWasProvisioned = try await session.zoneIsProvisioned()
            switch CloudKitRecordSaveFailurePolicy.disposition(
                for: failure.error.code,
                zoneWasProvisioned: zoneWasProvisioned
            ) {
            case .mergeServerRecord:
                guard let serverRecord = failure.error.serverRecord else {
                    throw translatedCloudKitError(failure.error)
                }
                let reuploadIDs = try await session.applyFetched([serverRecord])
                syncEngine.state.add(
                    pendingRecordZoneChanges: reuploadIDs.map {
                        .saveRecord($0)
                    }
                )
            case .provisionMissingZone:
                try await clearServerFields(for: recordID)
                try await session.markZoneNeedsProvisioning()
                syncEngine.state.add(
                    pendingDatabaseChanges: [
                        .saveZone(CKRecordZone(zoneID: zoneID))
                    ]
                )
                syncEngine.state.add(
                    pendingRecordZoneChanges: [.saveRecord(recordID)]
                )
            case .blockDeletedZone:
                try await session.block(.recordZoneDeleted)
                throw CloudKitSyncEngineTransportError.recordZoneDeleted
            case .blockDeletedRecord:
                let reason = CloudKitSyncBlockReason
                    .unexpectedRemoteRecordDeletion(recordID.recordName)
                try await session.block(reason)
                throw CloudKitSyncEngineTransportError
                    .unexpectedRemoteRecordDeletion(recordID.recordName)
            case .retry:
                break
            case .fail:
                throw translatedCloudKitError(failure.error)
            }
        }
    }

    private func clearServerFields(
        for cloudRecordID: CKRecord.ID
    ) async throws {
        guard let syncRecordID = try await session.syncRecordID(
            for: cloudRecordID
        ) else {
            throw CloudKitSyncEngineTransportError.cloudKitFailure(
                "failed CloudKit record is missing from the durable mirror"
            )
        }
        try await session.clearServerRecordSystemFields(for: [syncRecordID])
    }
}
