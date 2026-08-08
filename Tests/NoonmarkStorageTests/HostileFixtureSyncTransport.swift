import NoonmarkSync

/// Test-only transport for exercising the download boundary with provider facts
/// that a conforming production transport must reject before publication.
actor HostileFixtureSyncTransport: SyncRecordTransport {
    private var records: [SyncRecord]

    init(uncheckedRecords: [SyncRecord]) {
        records = uncheckedRecords
    }

    func pushAccepting(
        _ records: [SyncRecord]
    ) async throws -> SyncTransportPushReceipt {
        self.records.append(contentsOf: records)
        return fixturePushReceipt()
    }

    func pull(
        after frontier: SyncTransportFrontier,
        limit _: Int
    ) async throws -> SyncTransportChangePage {
        fixturePage(records: records, after: frontier)
    }

    func removeAll() {
        records.removeAll()
    }
}
