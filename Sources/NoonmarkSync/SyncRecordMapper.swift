import Foundation
import NoonmarkCore

public enum SyncRecordMapperError: Error, Equatable, Sendable {
    case entityTypeMismatch(expected: SyncEntityType, actual: SyncEntityType)
    case invalidPayload(SyncEntityType)
    case classificationStateRequiresCommitRecords
}

public struct SyncRecordMapper: Sendable {
    public static let currentOrdinaryPayloadFormatVersion = 1

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSinceReferenceDate.bitPattern)
        }
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let seconds = Double(bitPattern: try container.decode(UInt64.self))
            guard seconds.isFinite else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "sync payload date is not finite"
                )
            }
            return Date(timeIntervalSinceReferenceDate: seconds)
        }
        self.encoder = encoder
        self.decoder = decoder
    }

    public func records(
        from snapshot: NoonmarkSnapshot,
        modifiedBy deviceID: SyncDeviceID,
        preferencesUpdatedAt: Date = Date(timeIntervalSince1970: 0)
    ) throws -> [SyncRecord] {
        guard snapshot.classifications == TaskClassificationState() else {
            throw SyncRecordMapperError.classificationStateRequiresCommitRecords
        }
        return try snapshot.days.map { try record(for: $0, modifiedBy: deviceID) }
            + snapshot.chains.map { try record(for: $0, modifiedBy: deviceID) }
            + snapshot.definitions.map { try record(for: $0, modifiedBy: deviceID) }
            + snapshot.traces.map { try record(for: $0, modifiedBy: deviceID) }
            + snapshot.subtasks.map { try record(for: $0, modifiedBy: deviceID) }
            + [try record(for: AppPreferencesEnvelope(preferences: snapshot.preferences, updatedAt: preferencesUpdatedAt), modifiedBy: deviceID)]
    }

    public func record(for day: Day, modifiedBy deviceID: SyncDeviceID) throws -> SyncRecord {
        return try makeRecord(
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
                modifiedAt: definition.noteEntries.reduce(
                    definition.supersededAt ?? definition.createdAt
                ) { max($0, $1.updatedAt) },
                deviceID: deviceID
            ),
            payload: definition
        )
    }

    public func record(
        for trace: DayTrace,
        modifiedBy deviceID: SyncDeviceID
    ) throws -> SyncRecord {
        return try makeRecord(
            header: RecordHeader(
                id: "trace:\(trace.id.rawValue.uuidString)",
                type: .dayTrace,
                entityID: trace.id.rawValue.uuidString,
                modifiedAt: trace.noteEntries.reduce(
                    trace.settledAt ?? trace.completedAt ?? trace.createdAt
                ) { max($0, $1.updatedAt) },
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

    public func record(
        for envelope: ClassificationCommitEnvelope,
        modifiedBy deviceID: SyncDeviceID
    ) throws -> SyncRecord {
        return SyncRecord(
            id: SyncRecordID("classification-commit:\(envelope.changeRecord.id.uuidString)"),
            entityType: .classificationCommit,
            entityID: envelope.changeRecord.id.uuidString,
            modifiedAt: envelope.changeRecord.committedAt,
            modifiedByDeviceID: deviceID,
            payload: try envelope.canonicalData()
        )
    }

    public func record(
        for envelope: TraceClassificationEventEnvelope,
        modifiedBy deviceID: SyncDeviceID
    ) throws -> SyncRecord {
        SyncRecord(
            id: SyncRecordID(
                "trace-classification-event:\(envelope.event.id.uuidString)"
            ),
            entityType: .traceClassificationEvent,
            entityID: envelope.event.id.uuidString,
            modifiedAt: envelope.event.capturedAt,
            modifiedByDeviceID: deviceID,
            payload: try envelope.canonicalData()
        )
    }

    public func payload(from record: SyncRecord) throws -> SyncRecordPayload {
        switch record.entityType {
        case .day:
            return .day(try decodeDay(record))
        case .taskChain:
            return .taskChain(try decodeTaskChain(record))
        case .taskDefinition:
            return .taskDefinition(try decodeTaskDefinition(record))
        case .dayTrace:
            return .dayTrace(try decodeDayTrace(record))
        case .subtask:
            return .subtask(try decodeSubtask(record))
        case .appPreferences:
            return .appPreferences(try decodeAppPreferences(record))
        case .classificationCommit:
            return .classificationCommit(try decodeClassificationCommit(record))
        case .traceClassificationEvent:
            return .traceClassificationEvent(
                try decodeTraceClassificationEvent(record)
            )
        }
    }

    public func decodeDay(_ record: SyncRecord) throws -> Day {
        try require(record, type: .day)
        let day = try decode(Day.self, from: record)
        try requireIdentity(
            record,
            id: "day:\(day.date.description)",
            entityID: day.date.description
        )
        return day
    }

    public func decodeTaskChain(_ record: SyncRecord) throws -> TaskChain {
        try require(record, type: .taskChain)
        let chain = try decode(TaskChain.self, from: record)
        try requireIdentity(
            record,
            id: "chain:\(chain.id.description)",
            entityID: chain.id.description
        )
        return chain
    }

    public func decodeTaskDefinition(_ record: SyncRecord) throws -> TaskDefinition {
        try require(record, type: .taskDefinition)
        let definition = try decode(TaskDefinition.self, from: record)
        try requireIdentity(
            record,
            id: "definition:\(definition.id.description)",
            entityID: definition.id.description
        )
        return definition
    }

    public func decodeDayTrace(_ record: SyncRecord) throws -> DayTrace {
        try require(record, type: .dayTrace)
        let trace = try decode(DayTrace.self, from: record)
        try requireIdentity(
            record,
            id: "trace:\(trace.id.description)",
            entityID: trace.id.description
        )
        return trace
    }

    public func decodeSubtask(_ record: SyncRecord) throws -> Subtask {
        try require(record, type: .subtask)
        let subtask = try decode(Subtask.self, from: record)
        try requireIdentity(
            record,
            id: "subtask:\(subtask.id.description)",
            entityID: subtask.id.description
        )
        return subtask
    }

    public func decodeAppPreferences(_ record: SyncRecord) throws -> AppPreferencesEnvelope {
        try require(record, type: .appPreferences)
        let envelope = try decode(AppPreferencesEnvelope.self, from: record)
        try requireIdentity(record, id: "preferences:default", entityID: "default")
        return envelope
    }

    public func decodeClassificationCommit(
        _ record: SyncRecord
    ) throws -> ClassificationCommitEnvelope {
        try require(record, type: .classificationCommit)
        do {
            let envelope = try ClassificationCommitEnvelope.decode(record.payload)
            guard try envelope.canonicalData() == record.payload,
                  record.entityID == envelope.changeRecord.id.uuidString,
                  record.id.rawValue == "classification-commit:\(record.entityID)"
            else {
                throw SyncRecordMapperError.invalidPayload(.classificationCommit)
            }
            return envelope
        } catch let error as SyncRecordMapperError {
            throw error
        } catch {
            throw SyncRecordMapperError.invalidPayload(.classificationCommit)
        }
    }

    public func decodeTraceClassificationEvent(
        _ record: SyncRecord
    ) throws -> TraceClassificationEventEnvelope {
        try require(record, type: .traceClassificationEvent)
        do {
            let envelope = try TraceClassificationEventEnvelope.decode(record.payload)
            guard record.entityID == envelope.event.id.uuidString,
                  record.id.rawValue
                  == "trace-classification-event:\(record.entityID)"
            else {
                throw SyncRecordMapperError.invalidPayload(
                    .traceClassificationEvent
                )
            }
            return envelope
        } catch let error as SyncRecordMapperError {
            throw error
        } catch {
            throw SyncRecordMapperError.invalidPayload(.traceClassificationEvent)
        }
    }

    private func makeRecord(
        header: RecordHeader,
        payload: some Codable
    ) throws -> SyncRecord {
        let envelope = CurrentSyncPayloadEnvelope(
            formatVersion: Self.currentOrdinaryPayloadFormatVersion,
            payload: payload
        )
        return SyncRecord(
            id: SyncRecordID(header.id),
            entityType: header.type,
            entityID: header.entityID,
            modifiedAt: header.modifiedAt,
            modifiedByDeviceID: header.deviceID,
            payload: try encoder.encode(envelope)
        )
    }

    private func require(_ record: SyncRecord, type: SyncEntityType) throws {
        guard record.entityType == type else {
            throw SyncRecordMapperError.entityTypeMismatch(expected: type, actual: record.entityType)
        }
    }

    private func requireIdentity(
        _ record: SyncRecord,
        id: String,
        entityID: String
    ) throws {
        guard record.id.rawValue == id, record.entityID == entityID else {
            throw SyncRecordMapperError.invalidPayload(record.entityType)
        }
    }

    private func decode<T: Codable>(_ type: T.Type, from record: SyncRecord) throws -> T {
        do {
            let envelope = try decoder.decode(
                CurrentSyncPayloadEnvelope<T>.self,
                from: record.payload
            )
            guard envelope.formatVersion == Self.currentOrdinaryPayloadFormatVersion,
                  try encoder.encode(envelope) == record.payload
            else {
                throw SyncRecordMapperError.invalidPayload(record.entityType)
            }
            return envelope.payload
        } catch let error as SyncRecordMapperError {
            throw error
        } catch {
            throw SyncRecordMapperError.invalidPayload(record.entityType)
        }
    }
}

private struct CurrentSyncPayloadEnvelope<Payload: Codable>: Codable {
    let formatVersion: Int
    let payload: Payload
}

private struct RecordHeader {
    var id: String
    var type: SyncEntityType
    var entityID: String
    var modifiedAt: Date
    var deviceID: SyncDeviceID
}
