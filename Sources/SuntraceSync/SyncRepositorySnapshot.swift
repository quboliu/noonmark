import CryptoKit
import Foundation

public struct SyncRepositorySnapshot: Codable, Equatable, Sendable {
    public var id: String
    public var memo: String
    public var createdAt: Date
    public var deviceID: SyncDeviceID
    public var recordIDs: [SyncRecordID]
    public var recordCount: Int
    public var payloadDigest: String

    public init(
        id: String,
        memo: String,
        createdAt: Date,
        deviceID: SyncDeviceID,
        recordIDs: [SyncRecordID],
        recordCount: Int,
        payloadDigest: String
    ) {
        self.id = id
        self.memo = memo
        self.createdAt = createdAt
        self.deviceID = deviceID
        self.recordIDs = recordIDs
        self.recordCount = recordCount
        self.payloadDigest = payloadDigest
    }
}

public struct SyncRepositorySnapshotBuilder: Sendable {
    public init() {}

    public func snapshot(
        records: [SyncRecord],
        memo: String = "[Sync] Cloud sync",
        createdAt: Date = Date(),
        deviceID: SyncDeviceID
    ) throws -> SyncRepositorySnapshot {
        let orderedRecords = records.sorted {
            if $0.entityType.rawValue != $1.entityType.rawValue {
                return $0.entityType.rawValue < $1.entityType.rawValue
            }
            return $0.id.rawValue < $1.id.rawValue
        }
        let payloadDigest = try digest(for: orderedRecords)
        let id = digest(for: "\(payloadDigest)|\(createdAt.timeIntervalSince1970)|\(deviceID.rawValue)")
        return SyncRepositorySnapshot(
            id: id,
            memo: memo,
            createdAt: createdAt,
            deviceID: deviceID,
            recordIDs: orderedRecords.map(\.id),
            recordCount: orderedRecords.count,
            payloadDigest: payloadDigest
        )
    }

    private func digest(for records: [SyncRecord]) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return digest(for: try encoder.encode(records))
    }

    private func digest(for string: String) -> String {
        digest(for: Data(string.utf8))
    }

    private func digest(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
