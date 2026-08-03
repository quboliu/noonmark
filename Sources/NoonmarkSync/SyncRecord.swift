import Foundation
import NoonmarkCore

public struct SyncDeviceID: Codable, Hashable, Sendable, CustomStringConvertible {
    private enum CodingKeys: String, CodingKey {
        case rawValue
    }

    public let rawValue: String

    public init(_ rawValue: String = UUID().uuidString) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(trimmed.isEmpty == false, "device id cannot be empty")
        self.rawValue = trimmed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawValue = try container.decode(String.self, forKey: .rawValue)
        let trimmed = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard trimmed.isEmpty == false else {
            throw DecodingError.dataCorruptedError(
                forKey: .rawValue,
                in: container,
                debugDescription: "device id cannot be empty"
            )
        }
        self.rawValue = trimmed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawValue, forKey: .rawValue)
    }

    public var description: String { rawValue }
}

public enum SyncEntityType: String, Codable, CaseIterable, Hashable, Sendable {
    case day
    case taskCycleSeries
    case taskChain
    case taskDefinition
    case dayTrace
    case subtask
    case ideaEntry
    case appPreferences
    case classificationBaseline
    case classificationCommit
    case traceClassificationEvent

    public var requiresImmutableRecordPayload: Bool {
        self == .classificationBaseline
            || self == .classificationCommit
            || self == .traceClassificationEvent
    }

    public var dependencyOrder: Int {
        switch self {
        case .taskCycleSeries:
            0
        case .taskChain:
            1
        case .taskDefinition:
            2
        case .day:
            3
        case .classificationBaseline:
            4
        case .classificationCommit:
            5
        case .dayTrace:
            6
        case .traceClassificationEvent:
            7
        case .subtask:
            8
        case .appPreferences:
            9
        case .ideaEntry:
            10
        }
    }
}

public enum SyncOperation: String, Codable, Hashable, Sendable {
    case upsert
    case delete
}

public struct SyncRecordID: Codable, Hashable, Sendable, CustomStringConvertible {
    private enum CodingKeys: String, CodingKey {
        case rawValue
    }

    public let rawValue: String

    public init(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(trimmed.isEmpty == false, "sync record id cannot be empty")
        self.rawValue = trimmed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawValue = try container.decode(String.self, forKey: .rawValue)
        let trimmed = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard trimmed.isEmpty == false else {
            throw DecodingError.dataCorruptedError(
                forKey: .rawValue,
                in: container,
                debugDescription: "sync record id cannot be empty"
            )
        }
        self.rawValue = trimmed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawValue, forKey: .rawValue)
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
        case reactivationWitnesses
    }

    public var id: SyncRecordID
    public var entityType: SyncEntityType
    public var entityID: String
    public var operation: SyncOperation
    public var modifiedAt: Date
    public var modifiedByDeviceID: SyncDeviceID
    public var payload: Data
    public private(set) var reactivationWitnesses: [Data]

    public init(
        id: SyncRecordID,
        entityType: SyncEntityType,
        entityID: String,
        operation: SyncOperation = .upsert,
        modifiedAt: Date,
        modifiedByDeviceID: SyncDeviceID,
        payload: Data
    ) {
        self.init(
            id: id,
            entityType: entityType,
            entityID: entityID,
            operation: operation,
            modifiedAt: modifiedAt,
            modifiedByDeviceID: modifiedByDeviceID,
            payload: payload,
            reactivationWitnesses: []
        )
    }

    public init(
        id: SyncRecordID,
        entityType: SyncEntityType,
        entityID: String,
        operation: SyncOperation = .upsert,
        modifiedAt: Date,
        modifiedByDeviceID: SyncDeviceID,
        payload: Data,
        reactivationWitnesses: [Data]
    ) {
        self.id = id
        self.entityType = entityType
        self.entityID = entityID
        self.operation = operation
        self.modifiedAt = modifiedAt
        self.modifiedByDeviceID = modifiedByDeviceID
        self.payload = payload
        self.reactivationWitnesses = Self.canonicalWitnesses(
            reactivationWitnesses
        )
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
        let reactivationWitnesses = try container.decode(
            [Data].self,
            forKey: .reactivationWitnesses
        )
        let canonicalWitnesses = Self.canonicalWitnesses(
            reactivationWitnesses
        )
        guard canonicalWitnesses == reactivationWitnesses else {
            throw DecodingError.dataCorruptedError(
                forKey: .reactivationWitnesses,
                in: container,
                debugDescription: "reactivation witnesses must be unique and canonically ordered"
            )
        }
        self.reactivationWitnesses = canonicalWitnesses
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
        try container.encode(
            reactivationWitnesses,
            forKey: .reactivationWitnesses
        )
    }

    private static func canonicalWitnesses(_ witnesses: [Data]) -> [Data] {
        var unique: [Data] = []
        for witness in witnesses.sorted(by: { $0.lexicographicallyPrecedes($1) })
        where unique.last != witness {
            unique.append(witness)
        }
        return unique
    }
}

public enum SyncRecordPayload: Equatable, Sendable {
    case day(Day)
    case taskCycleSeries(TaskCycleSeries)
    case taskChain(TaskChain)
    case taskDefinition(TaskDefinition)
    case dayTrace(DayTrace)
    case subtask(Subtask)
    case ideaEntry(IdeaEntry)
    case appPreferences(AppPreferencesEnvelope)
    case classificationBaseline(ClassificationBaselineEnvelope)
    case classificationCommit(ClassificationCommitEnvelope)
    case traceClassificationEvent(TraceClassificationEventEnvelope)
}

public struct AppPreferencesEnvelope: Codable, Equatable, Sendable {
    static let unspecifiedWriterDeviceID = SyncDeviceID(
        "noonmark.unspecified-preference-writer"
    )

    public var theme: AppTheme
    public var language: AppLanguage
    public var updatedAt: Date
    public var writerDeviceID: SyncDeviceID

    public init(preferences: AppPreferences) {
        theme = preferences.theme
        language = preferences.language
        updatedAt = preferences.themeLanguageUpdatedAt
        writerDeviceID = SyncDeviceID(
            preferences.themeLanguageWriterID
        )
    }

    public init(
        theme: AppTheme,
        language: AppLanguage,
        updatedAt: Date,
        writerDeviceID: SyncDeviceID = SyncDeviceID(
            "noonmark.unspecified-preference-writer"
        )
    ) {
        self.theme = theme
        self.language = language
        self.updatedAt = updatedAt
        self.writerDeviceID = writerDeviceID
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
    /// Journal 会保存无法从当前 snapshot 安全重建的 mutation evidence：
    /// immutable classification records、task-chain reactivation witness，以及
    /// app-preferences 每一次 mutation 当时的 ordinary current-record payload。
    /// 这项 journal 约束不等于 transport immutable CAS 约束。
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
            Self.hasValidJournalPayloadShape(
                entityType: entityType,
                recordPayload: recordPayload
            ),
            "sync journal record payload shape is invalid"
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
        guard Self.hasValidJournalPayloadShape(
            entityType: entityType,
            recordPayload: recordPayload
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .recordPayload,
                in: container,
                debugDescription: "sync journal payload invariant is invalid"
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

    var hasValidJournalPayloadInvariant: Bool {
        Self.hasValidJournalPayloadShape(
            entityType: entityType,
            recordPayload: recordPayload
        )
    }

    public static func hasValidJournalPayloadShape(
        entityType: SyncEntityType,
        recordPayload: Data?
    ) -> Bool {
        if entityType.requiresImmutableRecordPayload || entityType == .appPreferences {
            return recordPayload?.isEmpty == false
        }
        if entityType == .taskChain {
            return recordPayload == nil || recordPayload?.isEmpty == false
        }
        return recordPayload == nil
    }
}
