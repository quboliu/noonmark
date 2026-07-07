import Foundation
import SuntraceCore

public enum SyncRecordMapperError: Error, Equatable, Sendable {
    case entityTypeMismatch(expected: SyncEntityType, actual: SyncEntityType)
    case invalidPayload(SyncEntityType)
}

public struct SyncRecordMapper: Sendable {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.encoder = encoder
        self.decoder = decoder
    }

    public func records(
        from snapshot: SuntraceSnapshot,
        modifiedBy deviceID: SyncDeviceID,
        preferencesUpdatedAt: Date = Date(timeIntervalSince1970: 0)
    ) throws -> [SyncRecord] {
        try snapshot.days.map { try record(for: $0, modifiedBy: deviceID) }
            + snapshot.chains.map { try record(for: $0, modifiedBy: deviceID) }
            + snapshot.definitions.map { try record(for: $0, modifiedBy: deviceID) }
            + snapshot.traces.map { try record(for: $0, modifiedBy: deviceID) }
            + snapshot.subtasks.map { try record(for: $0, modifiedBy: deviceID) }
            + [try record(for: AppPreferencesEnvelope(preferences: snapshot.preferences, updatedAt: preferencesUpdatedAt), modifiedBy: deviceID)]
    }

    public func record(for day: Day, modifiedBy deviceID: SyncDeviceID) throws -> SyncRecord {
        try makeRecord(
            header: RecordHeader(
                id: "day:\(day.date.description)",
                type: .day,
                entityID: day.date.description,
                modifiedAt: day.updatedAt,
                deviceID: deviceID
            ),
            payload: day
        )
    }

    public func record(for chain: TaskChain, modifiedBy deviceID: SyncDeviceID) throws -> SyncRecord {
        try makeRecord(
            header: RecordHeader(
                id: "chain:\(chain.id.rawValue.uuidString)",
                type: .taskChain,
                entityID: chain.id.rawValue.uuidString,
                modifiedAt: chain.updatedAt,
                deviceID: deviceID
            ),
            payload: chain
        )
    }

    public func record(for definition: TaskDefinition, modifiedBy deviceID: SyncDeviceID) throws -> SyncRecord {
        try makeRecord(
            header: RecordHeader(
                id: "definition:\(definition.id.rawValue.uuidString)",
                type: .taskDefinition,
                entityID: definition.id.rawValue.uuidString,
                modifiedAt: definition.supersededAt ?? definition.createdAt,
                deviceID: deviceID
            ),
            payload: definition
        )
    }

    public func record(for trace: DayTrace, modifiedBy deviceID: SyncDeviceID) throws -> SyncRecord {
        try makeRecord(
            header: RecordHeader(
                id: "trace:\(trace.id.rawValue.uuidString)",
                type: .dayTrace,
                entityID: trace.id.rawValue.uuidString,
                modifiedAt: trace.settledAt ?? trace.completedAt ?? trace.createdAt,
                deviceID: deviceID
            ),
            payload: trace
        )
    }

    public func record(for subtask: Subtask, modifiedBy deviceID: SyncDeviceID) throws -> SyncRecord {
        try makeRecord(
            header: RecordHeader(
                id: "subtask:\(subtask.id.rawValue.uuidString)",
                type: .subtask,
                entityID: subtask.id.rawValue.uuidString,
                modifiedAt: subtask.settledAt ?? subtask.completedAt ?? subtask.createdAt,
                deviceID: deviceID
            ),
            payload: subtask
        )
    }

    public func record(for envelope: AppPreferencesEnvelope, modifiedBy deviceID: SyncDeviceID) throws -> SyncRecord {
        try makeRecord(
            header: RecordHeader(
                id: "preferences:default",
                type: .appPreferences,
                entityID: "default",
                modifiedAt: envelope.updatedAt,
                deviceID: deviceID
            ),
            payload: envelope
        )
    }

    public func payload(from record: SyncRecord) throws -> SyncRecordPayload {
        switch record.entityType {
        case .day:
            return .day(try decode(Day.self, from: record))
        case .taskChain:
            return .taskChain(try decode(TaskChain.self, from: record))
        case .taskDefinition:
            return .taskDefinition(try decode(TaskDefinition.self, from: record))
        case .dayTrace:
            return .dayTrace(try decode(DayTrace.self, from: record))
        case .subtask:
            return .subtask(try decode(Subtask.self, from: record))
        case .appPreferences:
            return .appPreferences(try decode(AppPreferencesEnvelope.self, from: record))
        }
    }

    public func decodeDay(_ record: SyncRecord) throws -> Day {
        try require(record, type: .day)
        return try decode(Day.self, from: record)
    }

    public func decodeTaskChain(_ record: SyncRecord) throws -> TaskChain {
        try require(record, type: .taskChain)
        return try decode(TaskChain.self, from: record)
    }

    public func decodeTaskDefinition(_ record: SyncRecord) throws -> TaskDefinition {
        try require(record, type: .taskDefinition)
        return try decode(TaskDefinition.self, from: record)
    }

    public func decodeDayTrace(_ record: SyncRecord) throws -> DayTrace {
        try require(record, type: .dayTrace)
        return try decode(DayTrace.self, from: record)
    }

    public func decodeSubtask(_ record: SyncRecord) throws -> Subtask {
        try require(record, type: .subtask)
        return try decode(Subtask.self, from: record)
    }

    public func decodeAppPreferences(_ record: SyncRecord) throws -> AppPreferencesEnvelope {
        try require(record, type: .appPreferences)
        return try decode(AppPreferencesEnvelope.self, from: record)
    }

    private func makeRecord(
        header: RecordHeader,
        payload: some Encodable
    ) throws -> SyncRecord {
        SyncRecord(
            id: SyncRecordID(header.id),
            entityType: header.type,
            entityID: header.entityID,
            modifiedAt: header.modifiedAt,
            modifiedByDeviceID: header.deviceID,
            payload: try encoder.encode(payload)
        )
    }

    private func require(_ record: SyncRecord, type: SyncEntityType) throws {
        guard record.entityType == type else {
            throw SyncRecordMapperError.entityTypeMismatch(expected: type, actual: record.entityType)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from record: SyncRecord) throws -> T {
        do {
            return try decoder.decode(type, from: record.payload)
        } catch {
            throw SyncRecordMapperError.invalidPayload(record.entityType)
        }
    }
}

private struct RecordHeader {
    var id: String
    var type: SyncEntityType
    var entityID: String
    var modifiedAt: Date
    var deviceID: SyncDeviceID
}
