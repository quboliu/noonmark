import Foundation
import NoonmarkCore

public enum SyncRecordMaterializerError: Error, Equatable, Sendable {
    case missingEntity(SyncEntityType, String)
    case unsupportedDelete(SyncEntityType, String)
    case invalidJournalPayload(SyncEntityType, String)
    case invalidImmutablePayload(SyncEntityType, String)
}

public struct SyncRecordMaterializer: Sendable {
    private let mapper: SyncRecordMapper

    public init(mapper: SyncRecordMapper = SyncRecordMapper()) {
        self.mapper = mapper
    }

    public func records(for entries: [SyncJournalEntry], in snapshot: NoonmarkSnapshot) throws -> [SyncRecord] {
        try entries.map { try record(for: $0, in: snapshot) }
    }

    public func record(for entry: SyncJournalEntry, in snapshot: NoonmarkSnapshot) throws -> SyncRecord {
        guard entry.hasValidJournalPayloadInvariant else {
            throw SyncRecordMaterializerError.invalidJournalPayload(
                entry.entityType,
                entry.entityID
            )
        }
        guard entry.operation == .upsert else {
            throw SyncRecordMaterializerError.unsupportedDelete(entry.entityType, entry.entityID)
        }

        switch entry.entityType {
        case .day:
            return try dayRecord(for: entry, in: snapshot)
        case .taskCycleSeries:
            return try taskCycleSeriesRecord(
                for: entry,
                in: snapshot
            )
        case .taskChain:
            return try chainRecord(for: entry, in: snapshot)
        case .taskDefinition:
            return try definitionRecord(for: entry, in: snapshot)
        case .dayTrace:
            return try traceRecord(for: entry, in: snapshot)
        case .subtask:
            return try subtaskRecord(for: entry, in: snapshot)
        case .appPreferences:
            return try preferencesRecord(for: entry)
        case .classificationBaseline:
            return try classificationBaselineRecord(for: entry)
        case .classificationCommit:
            return try classificationCommitRecord(for: entry)
        case .traceClassificationEvent:
            return try traceClassificationEventRecord(for: entry)
        }
    }

    private func dayRecord(for entry: SyncJournalEntry, in snapshot: NoonmarkSnapshot) throws -> SyncRecord {
        guard let day = snapshot.days.first(where: { $0.date.description == entry.entityID }) else {
            throw SyncRecordMaterializerError.missingEntity(entry.entityType, entry.entityID)
        }
        return try mapper.record(for: day, modifiedBy: entry.deviceID)
    }

    private func taskCycleSeriesRecord(
        for entry: SyncJournalEntry,
        in snapshot: NoonmarkSnapshot
    ) throws -> SyncRecord {
        guard let series = snapshot.taskCycleSeries.first(where: {
            $0.id.description == entry.entityID
        }) else {
            throw SyncRecordMaterializerError.missingEntity(
                entry.entityType,
                entry.entityID
            )
        }
        return try mapper.record(
            for: series,
            modifiedBy: entry.deviceID
        )
    }

    private func chainRecord(for entry: SyncJournalEntry, in snapshot: NoonmarkSnapshot) throws -> SyncRecord {
        guard let chain = snapshot.chains.first(where: { $0.id.rawValue.uuidString == entry.entityID }) else {
            throw SyncRecordMaterializerError.missingEntity(entry.entityType, entry.entityID)
        }
        let witnesses: [ChainReactivationEnvelope]
        if let payload = entry.recordPayload {
            do {
                witnesses = [try ChainReactivationEnvelope.decode(payload)]
            } catch {
                throw SyncRecordMaterializerError.invalidImmutablePayload(
                    entry.entityType,
                    entry.entityID
                )
            }
        } else {
            witnesses = []
        }
        return try mapper.record(
            for: chain,
            modifiedBy: entry.deviceID,
            reactivationWitnesses: witnesses
        )
    }

    private func definitionRecord(for entry: SyncJournalEntry, in snapshot: NoonmarkSnapshot) throws -> SyncRecord {
        guard let definition = snapshot.definitions.first(where: { $0.id.rawValue.uuidString == entry.entityID }) else {
            throw SyncRecordMaterializerError.missingEntity(entry.entityType, entry.entityID)
        }
        return try mapper.record(for: definition, modifiedBy: entry.deviceID)
    }

    private func traceRecord(for entry: SyncJournalEntry, in snapshot: NoonmarkSnapshot) throws -> SyncRecord {
        guard let trace = snapshot.traces.first(where: { $0.id.rawValue.uuidString == entry.entityID }) else {
            throw SyncRecordMaterializerError.missingEntity(entry.entityType, entry.entityID)
        }
        return try mapper.record(for: trace, modifiedBy: entry.deviceID)
    }

    private func subtaskRecord(for entry: SyncJournalEntry, in snapshot: NoonmarkSnapshot) throws -> SyncRecord {
        guard let subtask = snapshot.subtasks.first(where: { $0.id.rawValue.uuidString == entry.entityID }) else {
            throw SyncRecordMaterializerError.missingEntity(entry.entityType, entry.entityID)
        }
        return try mapper.record(for: subtask, modifiedBy: entry.deviceID)
    }

    private func preferencesRecord(
        for entry: SyncJournalEntry
    ) throws -> SyncRecord {
        guard entry.entityID == "default",
              let payload = entry.recordPayload
        else {
            throw SyncRecordMaterializerError.invalidJournalPayload(
                entry.entityType,
                entry.entityID
            )
        }
        let record = SyncRecord(
            id: SyncRecordID("preferences:default"),
            entityType: .appPreferences,
            entityID: "default",
            modifiedAt: entry.changedAt,
            modifiedByDeviceID: entry.deviceID,
            payload: payload
        )
        do {
            _ = try mapper.decodeAppPreferences(record)
            return record
        } catch {
            throw SyncRecordMaterializerError.invalidJournalPayload(
                entry.entityType,
                entry.entityID
            )
        }
    }

    private func classificationCommitRecord(
        for entry: SyncJournalEntry
    ) throws -> SyncRecord {
        guard let payload = entry.recordPayload else {
            throw SyncRecordMaterializerError.missingEntity(entry.entityType, entry.entityID)
        }
        let envelope: ClassificationCommitEnvelope
        do {
            envelope = try ClassificationCommitEnvelope.decode(payload)
        } catch {
            throw SyncRecordMaterializerError.invalidImmutablePayload(
                entry.entityType,
                entry.entityID
            )
        }
        guard envelope.changeRecord.id.uuidString == entry.entityID else {
            throw SyncRecordMaterializerError.invalidImmutablePayload(
                entry.entityType,
                entry.entityID
            )
        }
        return try mapper.record(for: envelope, modifiedBy: entry.deviceID)
    }

    private func classificationBaselineRecord(
        for entry: SyncJournalEntry
    ) throws -> SyncRecord {
        guard let payload = entry.recordPayload else {
            throw SyncRecordMaterializerError.missingEntity(
                entry.entityType,
                entry.entityID
            )
        }
        let envelope: ClassificationBaselineEnvelope
        do {
            envelope = try ClassificationBaselineEnvelope.decode(payload)
        } catch {
            throw SyncRecordMaterializerError.invalidImmutablePayload(
                entry.entityType,
                entry.entityID
            )
        }
        guard envelope.baselineID.uuidString == entry.entityID else {
            throw SyncRecordMaterializerError.invalidImmutablePayload(
                entry.entityType,
                entry.entityID
            )
        }
        return try mapper.record(
            for: envelope,
            modifiedBy: entry.deviceID
        )
    }

    private func traceClassificationEventRecord(
        for entry: SyncJournalEntry
    ) throws -> SyncRecord {
        guard let payload = entry.recordPayload else {
            throw SyncRecordMaterializerError.missingEntity(
                entry.entityType,
                entry.entityID
            )
        }
        let envelope: TraceClassificationEventEnvelope
        do {
            envelope = try TraceClassificationEventEnvelope.decode(payload)
        } catch {
            throw SyncRecordMaterializerError.invalidImmutablePayload(
                entry.entityType,
                entry.entityID
            )
        }
        guard envelope.event.id.uuidString == entry.entityID else {
            throw SyncRecordMaterializerError.invalidImmutablePayload(
                entry.entityType,
                entry.entityID
            )
        }
        return try mapper.record(for: envelope, modifiedBy: entry.deviceID)
    }
}
