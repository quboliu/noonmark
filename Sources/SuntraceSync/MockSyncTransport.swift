import Foundation

public actor InMemorySyncTransport: SyncRecordTransport {
    private var records: [SyncRecordID: SyncRecord]

    public init(records: [SyncRecord] = []) {
        self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    }

    public func push(_ records: [SyncRecord]) async throws {
        for record in records {
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
                guard record.currentRecordLWWOrder(comparedTo: existing) == .after else {
                    continue
                }
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
