import Foundation

public enum CloudKitSyncMirrorError: Error, Equatable, Sendable {
    case invalidPersistedCurrentRecord(SyncRecordID)
    case ambiguousServerRecordSystemFields(SyncRecordID)
}

public struct CloudKitSyncMirrorMergeResult: Equatable, Sendable {
    public let recordIDsNeedingUpload: [SyncRecordID]

    public init(recordIDsNeedingUpload: [SyncRecordID]) {
        self.recordIDsNeedingUpload = recordIDsNeedingUpload
    }
}

public struct CloudKitSyncMirror {
    private struct SourceMirrorSelection {
        let mirror: CloudKitMirroredSyncRecord
        let canonicalIsSourceFact: Bool
    }

    private enum Source {
        case local
        case server
    }

    private var recordsByID: [SyncRecordID: CloudKitMirroredSyncRecord]
    private let merger: CurrentSyncRecordMerger

    public init(snapshot: CloudKitSyncPersistenceSnapshot) throws {
        let merger = CurrentSyncRecordMerger()
        for mirrored in snapshot.records
        where mirrored.record.entityType.requiresImmutableRecordPayload == false {
            do {
                try merger.validate(mirrored.record)
            } catch {
                throw CloudKitSyncMirrorError.invalidPersistedCurrentRecord(
                    mirrored.record.id
                )
            }
        }
        recordsByID = Dictionary(
            uniqueKeysWithValues: snapshot.records.map {
                ($0.record.id, $0)
            }
        )
        self.merger = merger
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
        let incomingByID = Dictionary(grouping: incoming) { $0.record.id }
        var uploadIDs: Set<SyncRecordID> = []
        var stagedRecordsByID = recordsByID

        for incomingRecord in batch.records {
            guard let candidates = incomingByID[incomingRecord.id],
                  let selection = try sourceMirror(
                      for: incomingRecord,
                      candidates: candidates
                  )
            else {
                continue
            }
            let existingMirror = stagedRecordsByID[incomingRecord.id]
            let canonicalRecord = try canonicalRecord(
                existing: existingMirror?.record,
                incoming: incomingRecord,
                context: batch.mergeContext
            )

            let systemFields = switch source {
            case .local:
                existingMirror?.serverRecordSystemFields
            case .server:
                selection.mirror.serverRecordSystemFields
            }
            stagedRecordsByID[incomingRecord.id] = CloudKitMirroredSyncRecord(
                record: canonicalRecord,
                serverRecordSystemFields: systemFields
            )

            switch source {
            case .local:
                uploadIDs.insert(incomingRecord.id)
            case .server:
                let requiresUpload =
                    canonicalRecord.exactlyMatches(incomingRecord) == false
                        || selection.canonicalIsSourceFact == false
                if requiresUpload {
                    uploadIDs.insert(incomingRecord.id)
                }
            }
        }

        recordsByID = stagedRecordsByID

        return CloudKitSyncMirrorMergeResult(
            recordIDsNeedingUpload: uploadIDs.sorted(by: recordIDComesBefore)
        )
    }

    private func sourceMirror(
        for canonicalRecord: SyncRecord,
        candidates: [CloudKitMirroredSyncRecord]
    ) throws -> SourceMirrorSelection? {
        let exact = candidates.filter {
            $0.record.exactlyMatches(canonicalRecord)
        }
        if let mirror = try unambiguousMirror(
            exact,
            recordID: canonicalRecord.id
        ) {
            return SourceMirrorSelection(
                mirror: mirror,
                canonicalIsSourceFact: true
            )
        }
        let matchingHeader = candidates.filter {
            $0.record.entityType == canonicalRecord.entityType
                && $0.record.operation == canonicalRecord.operation
                && $0.record.modifiedByDeviceID
                == canonicalRecord.modifiedByDeviceID
                && $0.record.modifiedAt.timeIntervalSinceReferenceDate
                .bitPattern
                == canonicalRecord.modifiedAt.timeIntervalSinceReferenceDate
                .bitPattern
        }
        if let mirror = try unambiguousMirror(
            matchingHeader,
            recordID: canonicalRecord.id
        ) {
            return SourceMirrorSelection(
                mirror: mirror,
                canonicalIsSourceFact: false
            )
        }
        guard let mirror = candidates.max(by: {
            $1.record.currentRecordLWWOrder(comparedTo: $0.record) == .after
        }) else {
            return nil
        }
        return SourceMirrorSelection(
            mirror: mirror,
            canonicalIsSourceFact: false
        )
    }

    private func unambiguousMirror(
        _ candidates: [CloudKitMirroredSyncRecord],
        recordID: SyncRecordID
    ) throws -> CloudKitMirroredSyncRecord? {
        guard let mirror = candidates.last else { return nil }
        let fields = Set(candidates.map(\.serverRecordSystemFields))
        guard fields.count <= 1 else {
            throw CloudKitSyncMirrorError
                .ambiguousServerRecordSystemFields(recordID)
        }
        return mirror
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
                recordID: incoming.id,
                reason: SyncRecordMergeFailureReason(underlying: error)
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
