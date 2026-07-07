import Foundation

public protocol SyncRecordTransport: Sendable {
    func push(_ records: [SyncRecord]) async throws
    func fetchAll() async throws -> [SyncRecord]
}

public actor InMemorySyncTransport: SyncRecordTransport {
    private var records: [SyncRecordID: SyncRecord]

    public init(records: [SyncRecord] = []) {
        self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    }

    public func push(_ records: [SyncRecord]) async throws {
        for record in records {
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
