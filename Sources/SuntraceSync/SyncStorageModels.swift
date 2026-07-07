import Foundation

public struct SyncMetadataEntry: Codable, Equatable, Sendable {
    public var key: String
    public var value: Data
    public var updatedAt: Date

    public init(key: String, value: Data, updatedAt: Date = Date()) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(trimmed.isEmpty == false, "sync metadata key cannot be empty")
        self.key = trimmed
        self.value = value
        self.updatedAt = updatedAt
    }
}

public enum SyncAuditDirection: String, Codable, Hashable, Sendable {
    case upload
    case download
    case merge
}

public struct SyncAuditLogEntry: Codable, Equatable, Sendable {
    public var id: UUID
    public var direction: SyncAuditDirection
    public var entityType: SyncEntityType
    public var entityID: String
    public var action: String
    public var createdAt: Date
    public var message: String?

    public init(
        id: UUID = UUID(),
        direction: SyncAuditDirection,
        entityType: SyncEntityType,
        entityID: String,
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
        self.action = trimmedAction
        self.createdAt = createdAt
        self.message = message
    }
}
