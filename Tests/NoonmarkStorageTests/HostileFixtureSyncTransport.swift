import NoonmarkSync

/// Test-only append-only transport for exercising the download boundary with
/// provider facts that a conforming production transport rejects before
/// publication. Its delivery model deliberately matches the real incremental
/// protocol: a persisted frontier never causes old evidence to be replayed.
actor HostileFixtureSyncTransport: SyncRecordTransport {
    private static let producerID = "hostile-fixture"
    private var batches: [[SyncRecord]]

    init(uncheckedRecords: [SyncRecord]) {
        batches = uncheckedRecords.isEmpty ? [] : [uncheckedRecords]
    }

    func pushAccepting(
        _ records: [SyncRecord]
    ) async throws -> SyncTransportPushReceipt {
        guard records.isEmpty == false else { return fixturePushReceipt() }
        batches.append(records)
        let sequence = UInt64(batches.count)
        return SyncTransportPushReceipt(
            batches: [
                SyncTransportBatchReference(
                    producerID: Self.producerID,
                    sequence: sequence,
                    contentHash: "hostile-\(sequence)"
                )
            ],
            confirmation: .confirmed
        )
    }

    func pull(
        after frontier: SyncTransportFrontier,
        limit: Int
    ) async throws -> SyncTransportChangePage {
        guard frontier.positions.keys.allSatisfy({ $0 == Self.producerID })
        else {
            throw SyncRecordTransportError.invalidFrontier
        }
        let position = frontier.position(for: Self.producerID)
        let sequence = position?.sequence ?? 0
        guard sequence <= UInt64(batches.count),
              position == nil || position?.contentHash == "hostile-\(sequence)"
        else {
            throw SyncRecordTransportError.invalidFrontier
        }

        let pageLimit = max(limit, 1)
        var nextSequence = sequence
        var records: [SyncRecord] = []
        var references: [SyncTransportBatchReference] = []
        while nextSequence < UInt64(batches.count) {
            let candidateSequence = nextSequence + 1
            let candidateRecords = batches[Int(candidateSequence - 1)]
            if records.isEmpty == false,
               records.count + candidateRecords.count > pageLimit
            {
                break
            }
            records.append(contentsOf: candidateRecords)
            references.append(
                SyncTransportBatchReference(
                    producerID: Self.producerID,
                    sequence: candidateSequence,
                    contentHash: "hostile-\(candidateSequence)"
                )
            )
            nextSequence = candidateSequence
            if records.count >= pageLimit {
                break
            }
        }
        let nextFrontier = nextSequence == 0
            ? SyncTransportFrontier.origin
            : SyncTransportFrontier(
                positions: [
                    Self.producerID: SyncTransportPosition(
                        sequence: nextSequence,
                        contentHash: "hostile-\(nextSequence)"
                    )
                ]
            )
        return SyncTransportChangePage(
            records: records,
            frontier: nextFrontier,
            hasMore: nextSequence < UInt64(batches.count),
            batches: references,
            observedProducerCount: batches.isEmpty ? 0 : 1,
            openedBatchCount: references.count
        )
    }

    func removeAll() {
        batches.removeAll()
    }
}
