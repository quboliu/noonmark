import Foundation
import SuntraceCore

public struct SyncSnapshotDiffer: Sendable {
    public init() {}

    public func journalEntries(
        from oldSnapshot: SuntraceSnapshot,
        to newSnapshot: SuntraceSnapshot,
        changedAt: Date,
        deviceID: SyncDeviceID
    ) -> [SyncJournalEntry] {
        changedEntities(from: oldSnapshot, to: newSnapshot).map { entity in
            SyncJournalEntry(
                entityType: entity.type,
                entityID: entity.id,
                operation: .upsert,
                changedAt: changedAt,
                deviceID: deviceID
            )
        }
    }

    private func changedEntities(from oldSnapshot: SuntraceSnapshot, to newSnapshot: SuntraceSnapshot) -> [ChangedEntity] {
        var entities: [ChangedEntity] = []
        entities += changedDays(from: oldSnapshot.days, to: newSnapshot.days)
        entities += changedChains(from: oldSnapshot.chains, to: newSnapshot.chains)
        entities += changedDefinitions(from: oldSnapshot.definitions, to: newSnapshot.definitions)
        entities += changedTraces(from: oldSnapshot.traces, to: newSnapshot.traces)
        entities += changedSubtasks(from: oldSnapshot.subtasks, to: newSnapshot.subtasks)

        if oldSnapshot.preferences != newSnapshot.preferences {
            entities.append(ChangedEntity(type: .appPreferences, id: "default"))
        }

        return entities.sorted()
    }

    private func changedDays(from oldDays: [Day], to newDays: [Day]) -> [ChangedEntity] {
        let oldByDate = Dictionary(uniqueKeysWithValues: oldDays.map { ($0.date, $0) })
        return newDays.compactMap { day in
            oldByDate[day.date] == day ? nil : ChangedEntity(type: .day, id: day.date.description)
        }
    }

    private func changedChains(from oldChains: [TaskChain], to newChains: [TaskChain]) -> [ChangedEntity] {
        let oldByID = Dictionary(uniqueKeysWithValues: oldChains.map { ($0.id, $0) })
        return newChains.compactMap { chain in
            oldByID[chain.id] == chain ? nil : ChangedEntity(type: .taskChain, id: chain.id.rawValue.uuidString)
        }
    }

    private func changedDefinitions(
        from oldDefinitions: [TaskDefinition],
        to newDefinitions: [TaskDefinition]
    ) -> [ChangedEntity] {
        let oldByID = Dictionary(uniqueKeysWithValues: oldDefinitions.map { ($0.id, $0) })
        return newDefinitions.compactMap { definition in
            oldByID[definition.id] == definition ? nil : ChangedEntity(type: .taskDefinition, id: definition.id.rawValue.uuidString)
        }
    }

    private func changedTraces(from oldTraces: [DayTrace], to newTraces: [DayTrace]) -> [ChangedEntity] {
        let oldByID = Dictionary(uniqueKeysWithValues: oldTraces.map { ($0.id, $0) })
        return newTraces.compactMap { trace in
            oldByID[trace.id] == trace ? nil : ChangedEntity(type: .dayTrace, id: trace.id.rawValue.uuidString)
        }
    }

    private func changedSubtasks(from oldSubtasks: [Subtask], to newSubtasks: [Subtask]) -> [ChangedEntity] {
        let oldByID = Dictionary(uniqueKeysWithValues: oldSubtasks.map { ($0.id, $0) })
        return newSubtasks.compactMap { subtask in
            oldByID[subtask.id] == subtask ? nil : ChangedEntity(type: .subtask, id: subtask.id.rawValue.uuidString)
        }
    }
}

private struct ChangedEntity: Comparable {
    var type: SyncEntityType
    var id: String

    static func < (lhs: ChangedEntity, rhs: ChangedEntity) -> Bool {
        if lhs.type.syncOrder != rhs.type.syncOrder {
            return lhs.type.syncOrder < rhs.type.syncOrder
        }
        return lhs.id < rhs.id
    }
}

private extension SyncEntityType {
    var syncOrder: Int {
        switch self {
        case .taskChain:
            return 0
        case .taskDefinition:
            return 1
        case .day:
            return 2
        case .dayTrace:
            return 3
        case .subtask:
            return 4
        case .appPreferences:
            return 5
        }
    }
}
