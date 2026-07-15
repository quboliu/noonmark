import Foundation

public struct CloudKitSyncMirrorMergeResult: Equatable, Sendable {
    public let recordIDsNeedingUpload: [SyncRecordID]

    public init(recordIDsNeedingUpload: [SyncRecordID]) {
        self.recordIDsNeedingUpload = recordIDsNeedingUpload
    }
}

public struct CloudKitSyncMirror {
    private enum Source {
        case local
        case server
    }

    private var recordsByID: [SyncRecordID: CloudKitMirroredSyncRecord]
    private let merger: CurrentSyncRecordMerger

    public init(snapshot: CloudKitSyncPersistenceSnapshot) throws {
        recordsByID = Dictionary(
            uniqueKeysWithValues: snapshot.records.map {
                ($0.record.id, $0)
            }
        )
        merger = CurrentSyncRecordMerger()
    }

    public var records: [SyncRecord] {
        recordsByID.values
            .map(\.record)
            .sorted(by: recordComesBefore)
    }

    public func mirroredRecord(
        for recordID: SyncRecordID
    ) -> CloudKitMirroredSyncRecord? {
        recordsByID[recordID]
    }

    public mutating func mergeLocal(
        _ records: [SyncRecord]
    ) throws -> CloudKitSyncMirrorMergeResult {
        try merge(
            records.map {
                CloudKitMirroredSyncRecord(
                    record: $0,
                    serverRecordSystemFields: nil
                )
            },
            source: .local
        )
    }

    public mutating func mergeServer(
        _ records: [CloudKitMirroredSyncRecord]
    ) throws -> CloudKitSyncMirrorMergeResult {
        try merge(records, source: .server)
    }

    public func persistenceSnapshot(
        scope: CloudKitSyncScopeIdentity? = nil,
        engineState: Data?,
        accountRecordName: String?,
        zoneIsProvisioned: Bool = false,
        blockReason: CloudKitSyncBlockReason? = nil
    ) throws -> CloudKitSyncPersistenceSnapshot {
        try CloudKitSyncPersistenceSnapshot(
            scope: scope,
            engineState: engineState,
            accountRecordName: accountRecordName,
            zoneIsProvisioned: zoneIsProvisioned,
            blockReason: blockReason,
            records: Array(recordsByID.values)
        )
    }

    mutating func clearServerRecordSystemFields(
        for recordIDs: [SyncRecordID]
    ) {
        for recordID in recordIDs {
            guard let mirrored = recordsByID[recordID] else { continue }
            recordsByID[recordID] = CloudKitMirroredSyncRecord(
                record: mirrored.record,
                serverRecordSystemFields: nil
            )
        }
    }

    private mutating func merge(
        _ incoming: [CloudKitMirroredSyncRecord],
        source: Source
    ) throws -> CloudKitSyncMirrorMergeResult {
        guard incoming.isEmpty == false else {
            return CloudKitSyncMirrorMergeResult(recordIDsNeedingUpload: [])
        }
        _ = try CloudKitSyncPersistenceSnapshot(records: incoming)
        let existingRecords = records
        let incomingRecords = incoming.map(\.record)
        try ImmutableSyncRecordCASPreflight.validate(
            existing: existingRecords.map {
                ImmutableSyncRecordCASCandidate(record: $0, exactData: nil)
            },
            incoming: incomingRecords.map {
                ImmutableSyncRecordCASCandidate(record: $0, exactData: nil)
            }
        )
        let batch = try merger.prepareTransportBatch(
            existingRecords: existingRecords,
            incomingRecords: incomingRecords
        )
        let incomingByID = Dictionary(
            uniqueKeysWithValues: incoming.map { ($0.record.id, $0) }
        )
        var uploadIDs: Set<SyncRecordID> = []

        for incomingRecord in batch.records {
            guard let incomingMirror = incomingByID[incomingRecord.id] else {
                continue
            }
            let existingMirror = recordsByID[incomingRecord.id]
            let canonicalRecord = try canonicalRecord(
                existing: existingMirror?.record,
                incoming: incomingRecord,
                context: batch.mergeContext
            )

            let systemFields = switch source {
            case .local:
                existingMirror?.serverRecordSystemFields
            case .server:
                incomingMirror.serverRecordSystemFields
            }
            recordsByID[incomingRecord.id] = CloudKitMirroredSyncRecord(
                record: canonicalRecord,
                serverRecordSystemFields: systemFields
            )

            switch source {
            case .local:
                uploadIDs.insert(incomingRecord.id)
            case .server:
                if canonicalRecord.exactlyMatches(incomingRecord) == false {
                    uploadIDs.insert(incomingRecord.id)
                }
            }
        }

        return CloudKitSyncMirrorMergeResult(
            recordIDsNeedingUpload: uploadIDs.sorted(by: recordIDComesBefore)
        )
    }

    private func canonicalRecord(
        existing: SyncRecord?,
        incoming: SyncRecord,
        context: CurrentSyncRecordMergeContext
    ) throws -> SyncRecord {
        guard let existing else { return incoming }
        let requiresImmutableCAS = existing.entityType
            .requiresImmutableRecordPayload
            || incoming.entityType.requiresImmutableRecordPayload
        guard requiresImmutableCAS == false else { return existing }
        do {
            return try merger.merge(
                existing: existing,
                incoming: incoming,
                context: context
            )
        } catch {
            throw SyncRecordTransportError.invalidCurrentRecordMerge(
                recordID: incoming.id
            )
        }
    }

    private func recordComesBefore(_ lhs: SyncRecord, _ rhs: SyncRecord) -> Bool {
        if lhs.entityType.rawValue != rhs.entityType.rawValue {
            return lhs.entityType.rawValue < rhs.entityType.rawValue
        }
        return recordIDComesBefore(lhs.id, rhs.id)
    }

    private func recordIDComesBefore(
        _ lhs: SyncRecordID,
        _ rhs: SyncRecordID
    ) -> Bool {
        Data(lhs.rawValue.utf8).lexicographicallyPrecedes(
            Data(rhs.rawValue.utf8)
        )
    }
}
