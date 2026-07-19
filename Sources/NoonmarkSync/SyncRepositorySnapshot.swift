import CryptoKit
import Foundation

public enum SyncRepositorySnapshotError: Error, Equatable, Sendable {
    case invalidCreatedAt
}

public struct SyncRepositorySnapshot: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case memo
        case createdAt
        case deviceID
        case recordIDs
        case recordCount
        case payloadDigest
    }

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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        memo = try container.decode(String.self, forKey: .memo)
        let createdAtBits = try container.decode(
            UInt64.self,
            forKey: .createdAt
        )
        let createdAtSeconds = Double(bitPattern: createdAtBits)
        guard createdAtSeconds.isFinite else {
            throw DecodingError.dataCorruptedError(
                forKey: .createdAt,
                in: container,
                debugDescription: "sync snapshot createdAt must be finite"
            )
        }
        createdAt = Date(
            timeIntervalSinceReferenceDate: createdAtSeconds
        )
        deviceID = try container.decode(
            SyncDeviceID.self,
            forKey: .deviceID
        )
        recordIDs = try container.decode(
            [SyncRecordID].self,
            forKey: .recordIDs
        )
        recordCount = try container.decode(Int.self, forKey: .recordCount)
        payloadDigest = try container.decode(
            String.self,
            forKey: .payloadDigest
        )
    }

    public func encode(to encoder: Encoder) throws {
        let createdAtSeconds = createdAt.timeIntervalSinceReferenceDate
        guard createdAtSeconds.isFinite else {
            throw EncodingError.invalidValue(
                createdAt,
                .init(
                    codingPath: encoder.codingPath + [CodingKeys.createdAt],
                    debugDescription: "sync snapshot createdAt must be finite"
                )
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(memo, forKey: .memo)
        try container.encode(
            createdAtSeconds.bitPattern,
            forKey: .createdAt
        )
        try container.encode(deviceID, forKey: .deviceID)
        try container.encode(recordIDs, forKey: .recordIDs)
        try container.encode(recordCount, forKey: .recordCount)
        try container.encode(payloadDigest, forKey: .payloadDigest)
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
        let createdAtSeconds = createdAt.timeIntervalSinceReferenceDate
        guard createdAtSeconds.isFinite else {
            throw SyncRepositorySnapshotError.invalidCreatedAt
        }
        let orderedRecords = records.sorted {
            if $0.entityType.rawValue != $1.entityType.rawValue {
                return $0.entityType.rawValue < $1.entityType.rawValue
            }
            return $0.id.rawValue < $1.id.rawValue
        }
        let payloadDigest = try digest(for: orderedRecords)
        let id = digest(
            for: "\(payloadDigest)|\(createdAtSeconds.bitPattern)|"
                + deviceID.rawValue
        )
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
