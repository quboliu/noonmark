import Foundation

public struct SyncMetadataEntry: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case key
        case value
        case updatedAt
    }

    public let key: String
    public var value: Data
    public var updatedAt: Date

    public init(key: String, value: Data, updatedAt: Date = Date()) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(trimmed.isEmpty == false, "sync metadata key cannot be empty")
        self.key = trimmed
        self.value = value
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let key = try container.decode(String.self, forKey: .key)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw DecodingError.dataCorruptedError(
                forKey: .key,
                in: container,
                debugDescription: "sync metadata key cannot be empty"
            )
        }
        self.key = trimmed
        value = try container.decode(Data.self, forKey: .value)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

public enum SyncAuditDirection: String, Codable, Hashable, Sendable {
    case upload
    case download
    case merge
}

public struct SyncAuditLogEntry: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case direction
        case entityType
        case entityID
        case sourceEvidenceID
        case canonicalEvidenceID
        case action
        case createdAt
        case message
    }

    public var id: UUID
    public var direction: SyncAuditDirection
    public var entityType: SyncEntityType
    public var entityID: String
    public var sourceEvidenceID: SyncRecordEvidenceID?
    public var canonicalEvidenceID: SyncRecordEvidenceID?
    public let action: String
    public var createdAt: Date
    public var message: String?

    public init(
        id: UUID = UUID(),
        direction: SyncAuditDirection,
        entityType: SyncEntityType,
        entityID: String,
        sourceEvidenceID: SyncRecordEvidenceID? = nil,
        canonicalEvidenceID: SyncRecordEvidenceID? = nil,
        action: String,
        createdAt: Date = Date(),
        message: String? = nil
    ) {
        let trimmedAction = action.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(trimmedAction.isEmpty == false, "sync audit action cannot be empty")
        self.id = id
        self.direction = direction
        self.entityType = entityType
        self.entityID = entityID
        self.sourceEvidenceID = sourceEvidenceID
        self.canonicalEvidenceID = canonicalEvidenceID
        self.action = trimmedAction
        self.createdAt = createdAt
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let action = try container.decode(String.self, forKey: .action)
        let trimmedAction = action.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard trimmedAction.isEmpty == false else {
            throw DecodingError.dataCorruptedError(
                forKey: .action,
                in: container,
                debugDescription: "sync audit action cannot be empty"
            )
        }
        id = try container.decode(UUID.self, forKey: .id)
        direction = try container.decode(
            SyncAuditDirection.self,
            forKey: .direction
        )
        entityType = try container.decode(
            SyncEntityType.self,
            forKey: .entityType
        )
        entityID = try container.decode(String.self, forKey: .entityID)
        sourceEvidenceID = try container.decodeIfPresent(
            SyncRecordEvidenceID.self,
            forKey: .sourceEvidenceID
        )
        canonicalEvidenceID = try container.decodeIfPresent(
            SyncRecordEvidenceID.self,
            forKey: .canonicalEvidenceID
        )
        self.action = trimmedAction
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        message = try container.decodeIfPresent(String.self, forKey: .message)
    }
}
