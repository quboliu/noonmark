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
    case classificationCommit
    case traceClassificationEvent

    public var requiresImmutableRecordPayload: Bool {
        self == .classificationCommit || self == .traceClassificationEvent
    }

    var dependencyOrder: Int {
        switch self {
        case .taskChain:
            0
        case .taskDefinition:
            1
        case .day:
            2
        case .classificationCommit:
            3
        case .dayTrace:
            4
        case .traceClassificationEvent:
            5
        case .subtask:
            6
        case .appPreferences:
            7
        }
    }
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
    private enum CodingKeys: String, CodingKey {
        case id
        case entityType
        case entityID
        case operation
        case modifiedAt
        case modifiedByDeviceID
        case payload
    }

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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(SyncRecordID.self, forKey: .id)
        entityType = try container.decode(SyncEntityType.self, forKey: .entityType)
        entityID = try container.decode(String.self, forKey: .entityID)
        operation = try container.decode(SyncOperation.self, forKey: .operation)
        let modifiedAtBitPattern = try container.decode(
            UInt64.self,
            forKey: .modifiedAt
        )
        let modifiedAtSeconds = Double(bitPattern: modifiedAtBitPattern)
        guard modifiedAtSeconds.isFinite else {
            throw DecodingError.dataCorruptedError(
                forKey: .modifiedAt,
                in: container,
                debugDescription: "sync record modifiedAt must be finite"
            )
        }
        modifiedAt = Date(timeIntervalSinceReferenceDate: modifiedAtSeconds)
        modifiedByDeviceID = try container.decode(
            SyncDeviceID.self,
            forKey: .modifiedByDeviceID
        )
        payload = try container.decode(Data.self, forKey: .payload)
    }

    public func encode(to encoder: Encoder) throws {
        guard modifiedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw EncodingError.invalidValue(
                modifiedAt,
                EncodingError.Context(
                    codingPath: encoder.codingPath + [CodingKeys.modifiedAt],
                    debugDescription: "sync record modifiedAt must be finite"
                )
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(entityType, forKey: .entityType)
        try container.encode(entityID, forKey: .entityID)
        try container.encode(operation, forKey: .operation)
        try container.encode(
            modifiedAt.timeIntervalSinceReferenceDate.bitPattern,
            forKey: .modifiedAt
        )
        try container.encode(modifiedByDeviceID, forKey: .modifiedByDeviceID)
        try container.encode(payload, forKey: .payload)
    }
}

public enum SyncRecordPayload: Equatable, Sendable {
    case day(Day)
    case taskChain(TaskChain)
    case taskDefinition(TaskDefinition)
    case dayTrace(DayTrace)
    case subtask(Subtask)
    case appPreferences(AppPreferencesEnvelope)
    case classificationCommit(ClassificationCommitEnvelope)
    case traceClassificationEvent(TraceClassificationEventEnvelope)
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
    private enum CodingKeys: String, CodingKey {
        case id
        case entityType
        case entityID
        case operation
        case changedAt
        case deviceID
        case state
        case retryCount
        case lastError
        case recordPayload
    }

    public var id: UUID
    public var entityType: SyncEntityType
    public var entityID: String
    public var operation: SyncOperation
    public var changedAt: Date
    public var deviceID: SyncDeviceID
    public var state: SyncChangeState
    public var retryCount: Int
    public var lastError: String?
    /// Immutable classification commit 与 trace classification event 直接随 journal
    /// 持久化 wire payload。
    /// 其他实体仍从保存后的 current snapshot 物化，且必须保持为 `nil`。
    public var recordPayload: Data?

    public init(
        id: UUID = UUID(),
        entityType: SyncEntityType,
        entityID: String,
        operation: SyncOperation = .upsert,
        changedAt: Date,
        deviceID: SyncDeviceID,
        state: SyncChangeState = .pendingUpload,
        retryCount: Int = 0,
        lastError: String? = nil,
        recordPayload: Data? = nil
    ) {
        precondition(
            entityType.requiresImmutableRecordPayload == (recordPayload != nil),
            "immutable sync journal entries require record payloads, and ordinary entries must not carry one"
        )
        self.id = id
        self.entityType = entityType
        self.entityID = entityID
        self.operation = operation
        self.changedAt = changedAt
        self.deviceID = deviceID
        self.state = state
        self.retryCount = retryCount
        self.lastError = lastError
        self.recordPayload = recordPayload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let entityType = try container.decode(SyncEntityType.self, forKey: .entityType)
        let recordPayload = try container.decodeIfPresent(Data.self, forKey: .recordPayload)
        guard entityType.requiresImmutableRecordPayload == (recordPayload != nil) else {
            throw DecodingError.dataCorruptedError(
                forKey: .recordPayload,
                in: container,
                debugDescription: "immutable sync journal payload invariant is invalid"
            )
        }
        id = try container.decode(UUID.self, forKey: .id)
        self.entityType = entityType
        entityID = try container.decode(String.self, forKey: .entityID)
        operation = try container.decode(SyncOperation.self, forKey: .operation)
        changedAt = try container.decode(Date.self, forKey: .changedAt)
        deviceID = try container.decode(SyncDeviceID.self, forKey: .deviceID)
        state = try container.decode(SyncChangeState.self, forKey: .state)
        retryCount = try container.decode(Int.self, forKey: .retryCount)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        self.recordPayload = recordPayload
    }

    var hasValidRecordPayloadInvariant: Bool {
        entityType.requiresImmutableRecordPayload == (recordPayload != nil)
    }
}
