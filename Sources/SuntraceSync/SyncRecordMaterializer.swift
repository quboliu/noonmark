import Foundation
import SuntraceCore

public enum SyncRecordMaterializerError: Error, Equatable, Sendable {
    case missingEntity(SyncEntityType, String)
    case unsupportedDelete(SyncEntityType, String)
}

public struct SyncRecordMaterializer: Sendable {
    private let mapper: SyncRecordMapper

    public init(mapper: SyncRecordMapper = SyncRecordMapper()) {
        self.mapper = mapper
    }

    public func records(for entries: [SyncJournalEntry], in snapshot: SuntraceSnapshot) throws -> [SyncRecord] {
        try entries.map { try record(for: $0, in: snapshot) }
    }

    public func record(for entry: SyncJournalEntry, in snapshot: SuntraceSnapshot) throws -> SyncRecord {
        guard entry.operation == .upsert else {
            throw SyncRecordMaterializerError.unsupportedDelete(entry.entityType, entry.entityID)
        }

        switch entry.entityType {
        case .day:
            return try dayRecord(for: entry, in: snapshot)
        case .taskChain:
            return try chainRecord(for: entry, in: snapshot)
        case .taskDefinition:
            return try definitionRecord(for: entry, in: snapshot)
        case .dayTrace:
            return try traceRecord(for: entry, in: snapshot)
        case .subtask:
            return try subtaskRecord(for: entry, in: snapshot)
        case .appPreferences:
            return try preferencesRecord(for: entry, in: snapshot)
        }
    }

    private func dayRecord(for entry: SyncJournalEntry, in snapshot: SuntraceSnapshot) throws -> SyncRecord {
        guard let day = snapshot.days.first(where: { $0.date.description == entry.entityID }) else {
            throw SyncRecordMaterializerError.missingEntity(entry.entityType, entry.entityID)
        }
        return try mapper.record(for: day, modifiedBy: entry.deviceID)
    }

    private func chainRecord(for entry: SyncJournalEntry, in snapshot: SuntraceSnapshot) throws -> SyncRecord {
        guard let chain = snapshot.chains.first(where: { $0.id.rawValue.uuidString == entry.entityID }) else {
            throw SyncRecordMaterializerError.missingEntity(entry.entityType, entry.entityID)
        }
        return try mapper.record(for: chain, modifiedBy: entry.deviceID)
    }

    private func definitionRecord(for entry: SyncJournalEntry, in snapshot: SuntraceSnapshot) throws -> SyncRecord {
        guard let definition = snapshot.definitions.first(where: { $0.id.rawValue.uuidString == entry.entityID }) else {
            throw SyncRecordMaterializerError.missingEntity(entry.entityType, entry.entityID)
        }
        return try mapper.record(for: definition, modifiedBy: entry.deviceID)
    }

    private func traceRecord(for entry: SyncJournalEntry, in snapshot: SuntraceSnapshot) throws -> SyncRecord {
        guard let trace = snapshot.traces.first(where: { $0.id.rawValue.uuidString == entry.entityID }) else {
            throw SyncRecordMaterializerError.missingEntity(entry.entityType, entry.entityID)
        }
        return try mapper.record(for: trace, modifiedBy: entry.deviceID)
    }

    private func subtaskRecord(for entry: SyncJournalEntry, in snapshot: SuntraceSnapshot) throws -> SyncRecord {
        guard let subtask = snapshot.subtasks.first(where: { $0.id.rawValue.uuidString == entry.entityID }) else {
            throw SyncRecordMaterializerError.missingEntity(entry.entityType, entry.entityID)
        }
        return try mapper.record(for: subtask, modifiedBy: entry.deviceID)
    }

    private func preferencesRecord(for entry: SyncJournalEntry, in snapshot: SuntraceSnapshot) throws -> SyncRecord {
        guard entry.entityID == "default" else {
            throw SyncRecordMaterializerError.missingEntity(entry.entityType, entry.entityID)
        }
        return try mapper.record(
            for: AppPreferencesEnvelope(preferences: snapshot.preferences, updatedAt: entry.changedAt),
            modifiedBy: entry.deviceID
        )
    }
}
