import Foundation
import SuntraceCore

public struct SyncDeviceID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String = UUID().uuidString) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(trimmed.isEmpty == false, "device id cannot be empty")
        self.rawValue = trimmed
    }

    public var description: String { rawValue }
}

public enum SyncEntityType: String, Codable, CaseIterable, Hashable, Sendable {
    case day
    case taskChain
    case taskDefinition
    case dayTrace
    case subtask
    case appPreferences
}

public enum SyncOperation: String, Codable, Hashable, Sendable {
    case upsert
    case delete
}

public struct SyncRecordID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(trimmed.isEmpty == false, "sync record id cannot be empty")
        self.rawValue = trimmed
    }

    public var description: String { rawValue }
}

public struct SyncRecord: Codable, Equatable, Sendable {
    public var id: SyncRecordID
    public var entityType: SyncEntityType
    public var entityID: String
    public var operation: SyncOperation
    public var modifiedAt: Date
    public var modifiedByDeviceID: SyncDeviceID
    public var payload: Data

    public init(
        id: SyncRecordID,
        entityType: SyncEntityType,
        entityID: String,
        operation: SyncOperation = .upsert,
        modifiedAt: Date,
        modifiedByDeviceID: SyncDeviceID,
        payload: Data
    ) {
        self.id = id
        self.entityType = entityType
        self.entityID = entityID
        self.operation = operation
        self.modifiedAt = modifiedAt
        self.modifiedByDeviceID = modifiedByDeviceID
        self.payload = payload
    }
}

public enum SyncRecordPayload: Equatable, Sendable {
    case day(Day)
    case taskChain(TaskChain)
    case taskDefinition(TaskDefinition)
    case dayTrace(DayTrace)
    case subtask(Subtask)
    case appPreferences(AppPreferencesEnvelope)
}

public struct AppPreferencesEnvelope: Codable, Equatable, Sendable {
    public var preferences: AppPreferences
    public var updatedAt: Date

    public init(preferences: AppPreferences, updatedAt: Date) {
        self.preferences = preferences
        self.updatedAt = updatedAt
    }
}

public struct SyncDeviceIdentity: Codable, Equatable, Sendable {
    public var deviceID: SyncDeviceID
    public var displayName: String?
    public var createdAt: Date

    public init(deviceID: SyncDeviceID = SyncDeviceID(), displayName: String? = nil, createdAt: Date = Date()) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.createdAt = createdAt
    }
}

public enum SyncChangeState: String, Codable, Hashable, Sendable {
    case pendingUpload
    case uploaded
    case failed
}

public struct SyncJournalEntry: Codable, Equatable, Sendable {
    public var id: UUID
    public var entityType: SyncEntityType
    public var entityID: String
    public var operation: SyncOperation
    public var changedAt: Date
    public var deviceID: SyncDeviceID
    public var state: SyncChangeState
    public var retryCount: Int
    public var lastError: String?

    public init(
        id: UUID = UUID(),
        entityType: SyncEntityType,
        entityID: String,
        operation: SyncOperation = .upsert,
        changedAt: Date,
        deviceID: SyncDeviceID,
        state: SyncChangeState = .pendingUpload,
        retryCount: Int = 0,
        lastError: String? = nil
    ) {
        self.id = id
        self.entityType = entityType
        self.entityID = entityID
        self.operation = operation
        self.changedAt = changedAt
        self.deviceID = deviceID
        self.state = state
        self.retryCount = retryCount
        self.lastError = lastError
    }
}
