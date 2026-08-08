import Foundation

public actor InMemorySyncTransport: SyncRecordTransport {
    private static let producerID = "in-memory"

    private var records: [SyncRecordID: SyncRecord]
    private var batches: [[SyncRecord]]
    private let currentRecordMerger: CurrentSyncRecordMerger

    public init() {
        records = [:]
        batches = []
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
                    recordID: record.id,
                    reason: .unknown
                )
            }
        }
        self.records = staged
        batches = batch.records.isEmpty ? [] : [batch.records]
        currentRecordMerger = merger
    }

    public func pushAccepting(
        _ records: [SyncRecord]
    ) async throws -> SyncTransportPushReceipt {
        guard records.isEmpty == false else {
            return SyncTransportPushReceipt(
                batches: [],
                confirmation: .confirmed
            )
        }
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
        let incomingEvidenceByID = Dictionary(grouping: records, by: \.id)
        var staged = self.records
        var published: [SyncRecord] = []

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
                    let merged = try currentRecordMerger.merge(
                        existing: existing,
                        incoming: record,
                        context: batch.mergeContext
                    )
                    if merged.exactlyMatches(existing) == false {
                        staged[record.id] = merged
                        published.append(merged)
                    } else if incomingEvidenceByID[record.id]?.contains(
                        where: { $0.exactlyMatches(existing) == false }
                    ) == true {
                        // A stale writer must observe the canonical current
                        // fact even when the authoritative state did not
                        // change. Re-appending that fact is the incremental
                        // protocol's convergence acknowledgement: a frontier
                        // consumer may have already observed the older fact
                        // before it made its now-rejected local change.
                        published.append(merged)
                    }
                } catch {
                    throw SyncRecordTransportError.invalidCurrentRecordMerge(
                        recordID: record.id,
                        reason: SyncRecordMergeFailureReason(underlying: error)
                    )
                }
                continue
            }
            staged[record.id] = record
            published.append(record)
        }
        self.records = staged
        guard published.isEmpty == false else {
            return SyncTransportPushReceipt(
                batches: [],
                confirmation: .confirmed
            )
        }
        batches.append(published)
        let sequence = UInt64(batches.count)
        return SyncTransportPushReceipt(
            batches: [
                SyncTransportBatchReference(
                    producerID: Self.producerID,
                    sequence: sequence,
                    contentHash: "memory-\(sequence)"
                )
            ],
            confirmation: .confirmed
        )
    }

    public func pull(
        after frontier: SyncTransportFrontier,
        limit: Int
    ) async throws -> SyncTransportChangePage {
        let unknownProducers = frontier.positions.keys.filter {
            $0 != Self.producerID
        }
        guard unknownProducers.isEmpty else {
            throw SyncRecordTransportError.invalidFrontier
        }
        let position = frontier.position(for: Self.producerID)
        let sequence = position?.sequence ?? 0
        guard sequence <= UInt64(batches.count),
              position == nil
                || position?.contentHash == "memory-\(sequence)"
        else {
            throw SyncRecordTransportError.invalidFrontier
        }
        let pageLimit = max(limit, 1)
        var nextSequence = sequence
        var pageRecords: [SyncRecord] = []
        var references: [SyncTransportBatchReference] = []
        while nextSequence < UInt64(batches.count) {
            let candidateSequence = nextSequence + 1
            let candidateRecords = batches[Int(candidateSequence - 1)]
            if pageRecords.isEmpty == false,
               pageRecords.count + candidateRecords.count > pageLimit
            {
                break
            }
            pageRecords.append(contentsOf: candidateRecords)
            references.append(
                SyncTransportBatchReference(
                    producerID: Self.producerID,
                    sequence: candidateSequence,
                    contentHash: "memory-\(candidateSequence)"
                )
            )
            nextSequence = candidateSequence
            if pageRecords.count >= pageLimit {
                break
            }
        }
        let nextFrontier = nextSequence == 0
            ? SyncTransportFrontier.origin
            : SyncTransportFrontier(
                positions: [
                    Self.producerID: SyncTransportPosition(
                        sequence: nextSequence,
                        contentHash: "memory-\(nextSequence)"
                    )
                ]
            )
        return SyncTransportChangePage(
            records: pageRecords,
            frontier: nextFrontier,
            hasMore: nextSequence < UInt64(batches.count),
            batches: references,
            observedProducerCount: batches.isEmpty ? 0 : 1,
            openedBatchCount: references.count
        )
    }

    public func removeAll() {
        records.removeAll()
        batches.removeAll()
    }
}
