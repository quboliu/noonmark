import CloudKit
import Foundation

public enum CloudKitSyncEngineTransportError: Error, Equatable, Sendable {
    case accountUnavailable(CloudKitAccountAvailability)
    case accountChanged(previous: String, current: String)
    case invalidEngineState
    case invalidServerRecordSystemFields
    case unexpectedRemoteRecordDeletion(String)
    case recordZoneDeleted
    case liveValidationZoneRequired
    case syncScopeChanged(
        previous: CloudKitSyncScopeIdentity,
        current: CloudKitSyncScopeIdentity
    )
    case cloudKitFailure(String)
    case missingEntitlement(String)
}

extension CloudKitSyncEngineTransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .accountUnavailable(availability):
            "CloudKit account is unavailable: \(availability.rawValue)."
        case let .accountChanged(previous, current):
            "CloudKit account changed from \(previous) to \(current); explicit confirmation is required."
        case .invalidEngineState:
            "Persisted CKSyncEngine state cannot be decoded."
        case .invalidServerRecordSystemFields:
            "Persisted CloudKit server record fields cannot be decoded."
        case let .unexpectedRemoteRecordDeletion(recordName):
            "CloudKit record \(recordName) was deleted outside Noonmark."
        case .recordZoneDeleted:
            "The Noonmark CloudKit record zone was deleted."
        case .liveValidationZoneRequired:
            "CloudKit cleanup is restricted to an isolated live-validation zone."
        case .syncScopeChanged:
            "CloudKit container, zone, or environment changed; explicit reset is required."
        case let .cloudKitFailure(message):
            "CloudKit operation failed: \(message)"
        case let .missingEntitlement(key):
            "CloudKit cannot start because entitlement \(key) is missing or invalid."
        }
    }
}

public struct CloudKitRecordSystemFieldsCodec: Sendable {
    public init() {}

    public func encode(_ record: CKRecord) throws -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    public func decode(_ data: Data) throws -> CKRecord {
        do {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
            unarchiver.requiresSecureCoding = true
            defer { unarchiver.finishDecoding() }
            guard let record = CKRecord(coder: unarchiver) else {
                throw CloudKitSyncEngineTransportError
                    .invalidServerRecordSystemFields
            }
            return record
        } catch let error as CloudKitSyncEngineTransportError {
            throw error
        } catch {
            throw CloudKitSyncEngineTransportError
                .invalidServerRecordSystemFields
        }
    }
}

private actor CloudKitSyncSessionAccessGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard waiters.isEmpty == false else {
            isHeld = false
            return
        }
        waiters.removeFirst().resume()
    }
}

actor CloudKitSyncSession {
    private struct State {
        var scope: CloudKitSyncScopeIdentity?
        var mirror: CloudKitSyncMirror
        var engineState: Data?
        var accountRecordName: String?
        var zoneIsProvisioned: Bool
        var blockReason: CloudKitSyncBlockReason?
    }

    private let persistence: any CloudKitSyncPersistence
    private let codec: CloudKitSyncRecordCodec
    private let systemFieldsCodec: CloudKitRecordSystemFieldsCodec
    private let accessGate = CloudKitSyncSessionAccessGate()
    private var state: State?

    init(
        persistence: any CloudKitSyncPersistence,
        codec: CloudKitSyncRecordCodec,
        systemFieldsCodec: CloudKitRecordSystemFieldsCodec = .init()
    ) {
        self.persistence = persistence
        self.codec = codec
        self.systemFieldsCodec = systemFieldsCodec
    }

    func stageLocal(_ records: [SyncRecord]) async throws -> [CKRecord.ID] {
        try await withExclusiveAccess {
            var candidate = try await loadedState()
            let result = try candidate.mirror.mergeLocal(records)
            try await commit(candidate)
            return result.recordIDsNeedingUpload.map(codec.recordID(for:))
        }
    }

    func applyFetched(_ records: [CKRecord]) async throws -> [CKRecord.ID] {
        try await withExclusiveAccess {
            let mirrored = try records.map { cloudRecord in
                CloudKitMirroredSyncRecord(
                    record: try codec.decode(cloudRecord),
                    serverRecordSystemFields: try systemFieldsCodec.encode(
                        cloudRecord
                    )
                )
            }
            var candidate = try await loadedState()
            let result = try candidate.mirror.mergeServer(mirrored)
            try await commit(candidate)
            return result.recordIDsNeedingUpload.map(codec.recordID(for:))
        }
    }

    func cloudRecord(for recordID: CKRecord.ID) async throws -> CKRecord? {
        try await withExclusiveAccess {
            let current = try await loadedState()
            guard let mirrored = current.mirror.records
                .first(where: { codec.recordID(for: $0.id) == recordID })
                .flatMap({ current.mirror.mirroredRecord(for: $0.id) })
            else { return nil }
            let serverRecord = try mirrored.serverRecordSystemFields.map(
                systemFieldsCodec.decode
            )
            return try codec.encode(
                mirrored.record,
                reusing: serverRecord
            )
        }
    }

    func records() async throws -> [SyncRecord] {
        try await withExclusiveAccess {
            try await loadedState().mirror.records
        }
    }

    func bindAccount(recordName: String) async throws {
        try await withExclusiveAccess {
            var candidate = try await loadedState()
            if let existing = candidate.accountRecordName {
                guard existing == recordName else {
                    throw CloudKitSyncEngineTransportError.accountChanged(
                        previous: existing,
                        current: recordName
                    )
                }
                return
            }
            candidate.accountRecordName = recordName
            try await commit(candidate)
        }
    }

    func bindScope(_ scope: CloudKitSyncScopeIdentity) async throws {
        try await withExclusiveAccess {
            var candidate = try await loadedState()
            if let existing = candidate.scope {
                guard existing == scope else {
                    throw CloudKitSyncEngineTransportError.syncScopeChanged(
                        previous: existing,
                        current: scope
                    )
                }
                return
            }
            guard candidate.engineState == nil,
                  candidate.accountRecordName == nil,
                  candidate.zoneIsProvisioned == false,
                  candidate.blockReason == nil,
                  candidate.mirror.records.isEmpty
            else {
                throw CloudKitSyncPersistenceError.invalidSnapshot
            }
            candidate.scope = scope
            try await commit(candidate)
        }
    }

    func engineStateData() async throws -> Data? {
        try await withExclusiveAccess {
            try await loadedState().engineState
        }
    }

    func updateEngineState(_ engineState: Data) async throws {
        try await withExclusiveAccess {
            var candidate = try await loadedState()
            candidate.engineState = engineState
            try await commit(candidate)
        }
    }

    func engineStateSerialization() async throws -> CKSyncEngine.State.Serialization? {
        try await withExclusiveAccess {
            guard let data = try await loadedState().engineState else { return nil }
            do {
                return try JSONDecoder().decode(
                    CKSyncEngine.State.Serialization.self,
                    from: data
                )
            } catch {
                throw CloudKitSyncEngineTransportError.invalidEngineState
            }
        }
    }

    func updateEngineState(
        _ serialization: CKSyncEngine.State.Serialization
    ) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let engineState = try encoder.encode(serialization)
        try await withExclusiveAccess {
            var candidate = try await loadedState()
            candidate.engineState = engineState
            try await commit(candidate)
        }
    }

    func zoneIsProvisioned() async throws -> Bool {
        try await withExclusiveAccess {
            let current = try await loadedState()
            try throwBlockingError(for: current.blockReason)
            return current.zoneIsProvisioned
        }
    }

    func markZoneProvisioned() async throws {
        try await withExclusiveAccess {
            var candidate = try await loadedState()
            candidate.zoneIsProvisioned = true
            try await commit(candidate)
        }
    }

    func markZoneNeedsProvisioning() async throws {
        try await withExclusiveAccess {
            var candidate = try await loadedState()
            candidate.zoneIsProvisioned = false
            try await commit(candidate)
        }
    }

    func clearServerRecordSystemFields(
        for recordIDs: [SyncRecordID]
    ) async throws {
        try await withExclusiveAccess {
            var candidate = try await loadedState()
            candidate.mirror.clearServerRecordSystemFields(for: recordIDs)
            try await commit(candidate)
        }
    }

    func syncRecordID(for cloudRecordID: CKRecord.ID) async throws -> SyncRecordID? {
        try await withExclusiveAccess {
            try await loadedState().mirror.records.first {
                codec.recordID(for: $0.id) == cloudRecordID
            }?.id
        }
    }

    func block(_ reason: CloudKitSyncBlockReason) async throws {
        try await withExclusiveAccess {
            var candidate = try await loadedState()
            candidate.blockReason = reason
            if reason == .recordZoneDeleted {
                candidate.zoneIsProvisioned = false
            }
            try await commit(candidate)
        }
    }

    func blockingErrorIfPresent() async throws {
        try await withExclusiveAccess {
            try await throwBlockingError(for: try loadedState().blockReason)
        }
    }

    private func throwBlockingError(
        for reason: CloudKitSyncBlockReason?
    ) throws {
        guard let reason else { return }
        switch reason {
        case .recordZoneDeleted:
            throw CloudKitSyncEngineTransportError.recordZoneDeleted
        case let .unexpectedRemoteRecordDeletion(recordName):
            throw CloudKitSyncEngineTransportError
                .unexpectedRemoteRecordDeletion(recordName)
        }
    }

    private func withExclusiveAccess<Result>(
        _ operation: () async throws -> Result
    ) async throws -> Result {
        await accessGate.acquire()
        do {
            try Task.checkCancellation()
            let result = try await operation()
            await accessGate.release()
            return result
        } catch {
            await accessGate.release()
            throw error
        }
    }

    private func loadedState() async throws -> State {
        if let state { return state }
        let snapshot = try await persistence.load()
        let loaded = State(
            scope: snapshot.scope,
            mirror: try CloudKitSyncMirror(snapshot: snapshot),
            engineState: snapshot.engineState,
            accountRecordName: snapshot.accountRecordName,
            zoneIsProvisioned: snapshot.zoneIsProvisioned,
            blockReason: snapshot.blockReason
        )
        state = loaded
        return loaded
    }

    private func commit(_ candidate: State) async throws {
        let snapshot = try candidate.mirror.persistenceSnapshot(
            scope: candidate.scope,
            engineState: candidate.engineState,
            accountRecordName: candidate.accountRecordName,
            zoneIsProvisioned: candidate.zoneIsProvisioned,
            blockReason: candidate.blockReason
        )
        try await persistence.save(snapshot)
        state = candidate
    }
}
