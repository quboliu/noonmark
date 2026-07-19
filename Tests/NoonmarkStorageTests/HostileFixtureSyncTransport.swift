import NoonmarkSync

/// Test-only transport for exercising the download boundary with provider facts
/// that a conforming production transport must reject before publication.
actor HostileFixtureSyncTransport: SyncRecordTransport {
    private var records: [SyncRecord]

    init(uncheckedRecords: [SyncRecord]) {
        records = uncheckedRecords
    }

    func push(_ records: [SyncRecord]) async throws {
        self.records.append(contentsOf: records)
    }

    func fetchAll() async throws -> [SyncRecord] {
        records
    }

    func removeAll() {
        records.removeAll()
    }
}
