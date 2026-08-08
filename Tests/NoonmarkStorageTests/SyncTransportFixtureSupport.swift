import NoonmarkSync

func fixturePushReceipt() -> SyncTransportPushReceipt {
    SyncTransportPushReceipt(batches: [], confirmation: .confirmed)
}

func fixturePage(
    records: [SyncRecord],
    after frontier: SyncTransportFrontier
) -> SyncTransportChangePage {
    let producerID = "test-fixture"
    let contentHash = records.map(\.id.rawValue).sorted().joined(separator: "|")
    if frontier.position(for: producerID)?.contentHash == contentHash {
        return SyncTransportChangePage(
            records: [], frontier: frontier, hasMore: false, observedProducerCount: 1
        )
    }
    let nextSequence = (frontier.position(for: producerID)?.sequence ?? 0) + 1
    return SyncTransportChangePage(
        records: records,
        frontier: frontier.advancing(
            producerID: producerID,
            to: SyncTransportPosition(sequence: nextSequence, contentHash: contentHash)
        ),
        hasMore: false,
        observedProducerCount: 1,
        openedBatchCount: records.isEmpty ? 0 : 1
    )
}
