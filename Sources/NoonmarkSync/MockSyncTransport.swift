import Foundation

public actor InMemorySyncTransport: SyncRecordTransport {
    private var records: [SyncRecordID: SyncRecord]
    private let currentRecordMerger: CurrentSyncRecordMerger

    public init() {
        records = [:]
        currentRecordMerger = CurrentSyncRecordMerger()
    }

    public init(records: [SyncRecord]) throws {
        let merger = CurrentSyncRecordMerger()
        try ImmutableSyncRecordCASPreflight.validate(
            existing: [],
            incoming: records.map {
                ImmutableSyncRecordCASCandidate(
                    record: $0,
                    exactData: nil
                )
            }
        )
        let batch = try merger.prepareTransportBatch(
            existingRecords: [],
            incomingRecords: records
        )
        var staged: [SyncRecordID: SyncRecord] = [:]
        for record in batch.records {
            guard staged.updateValue(record, forKey: record.id) == nil else {
                throw SyncRecordTransportError.invalidCurrentRecordMerge(
                    recordID: record.id
                )
            }
        }
        self.records = staged
        currentRecordMerger = merger
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
        var staged = self.records

        for record in batch.records {
            if let existing = staged[record.id] {
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
                    staged[record.id] = try currentRecordMerger.merge(
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
            staged[record.id] = record
        }
        self.records = staged
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
