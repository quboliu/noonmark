import Foundation

public actor InMemorySyncTransport: SyncRecordTransport {
    private var records: [SyncRecordID: SyncRecord]
    private let currentRecordMerger: CurrentSyncRecordMerger

    public init(records: [SyncRecord] = []) {
        self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        currentRecordMerger = CurrentSyncRecordMerger()
    }

    public func push(_ records: [SyncRecord]) async throws {
        guard records.isEmpty == false else { return }
        let existingRecords = Array(self.records.values)
        try ImmutableSyncRecordCASPreflight.validate(
            existing: existingRecords.map {
                ImmutableSyncRecordCASCandidate(
                    record: $0,
                    exactData: nil
                )
            },
            incoming: records.map {
                ImmutableSyncRecordCASCandidate(
                    record: $0,
                    exactData: nil
                )
            }
        )
        let batch = try currentRecordMerger.prepareTransportBatch(
            existingRecords: existingRecords,
            incomingRecords: records
        )

        for record in batch.records {
            if let existing = self.records[record.id] {
                let requiresImmutableCAS = existing.entityType.requiresImmutableRecordPayload
                    || record.entityType.requiresImmutableRecordPayload
                if requiresImmutableCAS {
                    guard record.exactlyMatches(existing) else {
                        throw SyncRecordTransportError.immutableRecordCollision(
                            recordID: record.id
                        )
                    }
                    continue
                }
                do {
                    self.records[record.id] = try currentRecordMerger.merge(
                        existing: existing,
                        incoming: record,
                        context: batch.mergeContext
                    )
                } catch {
                    throw SyncRecordTransportError.invalidCurrentRecordMerge(
                        recordID: record.id
                    )
                }
                continue
            }
            self.records[record.id] = record
        }
    }

    public func fetchAll() async throws -> [SyncRecord] {
        records.values.sorted {
            if $0.entityType.rawValue != $1.entityType.rawValue {
                return $0.entityType.rawValue < $1.entityType.rawValue
            }
            return $0.id.rawValue < $1.id.rawValue
        }
    }

    public func removeAll() {
        records.removeAll()
    }
}
