import Foundation
import NoonmarkCore

public enum SyncSnapshotDifferError: Error, Equatable, Sendable {
    case classificationHistoryDiverged
    case classificationCommitsMustBePersistedIndividually(count: Int)
    case unsupportedClassificationTransition(changeRecordID: UUID?, reason: String)
    case invalidChainReactivationBoundary(chainID: TaskChainID)
    case invalidThemeLanguageClock
    case themeLanguageClockDidNotAdvance
    case themeLanguageClockChangedWithoutValues
    case themeLanguageClockDoesNotMatchJournal
}

public struct SyncSnapshotDiffer: Sendable {
    private let mapper: SyncRecordMapper

    public init(mapper: SyncRecordMapper = SyncRecordMapper()) {
        self.mapper = mapper
    }

    public func journalEntries(
        from oldSnapshot: NoonmarkSnapshot,
        to newSnapshot: NoonmarkSnapshot,
        changedAt: Date,
        deviceID: SyncDeviceID
    ) throws -> [SyncJournalEntry] {
        try validateThemeLanguageClock(
            from: oldSnapshot.preferences,
            to: newSnapshot.preferences,
            changedAt: changedAt
        )
        let classificationDelta = try classificationDelta(
            from: oldSnapshot.classifications,
            to: newSnapshot.classifications
        )
        let reactivationPayloads = try chainReactivationPayloads(
            from: oldSnapshot,
            to: newSnapshot
        )
        let preferencesPayload = try appPreferencesPayload(
            from: oldSnapshot.preferences,
            to: newSnapshot.preferences,
            deviceID: deviceID
        )
        var entries = changedEntities(
            from: oldSnapshot,
            to: newSnapshot
        ).map { entity in
            SyncJournalEntry(
                entityType: entity.type,
                entityID: entity.id,
                operation: .upsert,
                changedAt: changedAt,
                deviceID: deviceID,
                recordPayload: journalPayload(
                    for: entity,
                    reactivationPayloads: reactivationPayloads,
                    preferencesPayload: preferencesPayload
                )
            )
        }
        if let classificationEntry = try classificationCommitEntry(
            delta: classificationDelta,
            deviceID: deviceID
        ) {
            entries.append(classificationEntry)
        }
        entries.append(contentsOf: try traceClassificationEventEntries(
            delta: classificationDelta,
            deviceID: deviceID
        ))
        return entries.sorted {
            if $0.entityType.dependencyOrder != $1.entityType.dependencyOrder {
                return $0.entityType.dependencyOrder < $1.entityType.dependencyOrder
            }
            return $0.entityID < $1.entityID
        }
    }

    private func appPreferencesPayload(
        from oldPreferences: AppPreferences,
        to newPreferences: AppPreferences,
        deviceID: SyncDeviceID
    ) throws -> Data? {
        guard oldPreferences.theme != newPreferences.theme
                || oldPreferences.language != newPreferences.language
        else {
            return nil
        }
        return try mapper.record(
            for: AppPreferencesEnvelope(preferences: newPreferences),
            modifiedBy: deviceID
        ).payload
    }

    private func journalPayload(
        for entity: ChangedEntity,
        reactivationPayloads: [String: Data],
        preferencesPayload: Data?
    ) -> Data? {
        switch entity.type {
        case .taskChain:
            reactivationPayloads[entity.id]
        case .appPreferences:
            preferencesPayload
        case .day, .taskCycleSeries, .taskDefinition, .dayTrace, .subtask,
             .ideaEntry, .classificationBaseline, .classificationCommit,
             .traceClassificationEvent:
            nil
        }
    }

    private func validateThemeLanguageClock(
        from oldPreferences: AppPreferences,
        to newPreferences: AppPreferences,
        changedAt: Date
    ) throws {
        let oldClock = oldPreferences.themeLanguageUpdatedAt
        let newClock = newPreferences.themeLanguageUpdatedAt
        guard oldClock.timeIntervalSinceReferenceDate.isFinite,
              newClock.timeIntervalSinceReferenceDate.isFinite
        else {
            throw SyncSnapshotDifferError.invalidThemeLanguageClock
        }

        let valuesChanged = oldPreferences.theme != newPreferences.theme
            || oldPreferences.language != newPreferences.language
        if valuesChanged {
            guard newClock > oldClock else {
                throw SyncSnapshotDifferError
                    .themeLanguageClockDidNotAdvance
            }
            guard changedAt.timeIntervalSinceReferenceDate.isFinite,
                  exactDateBits(newClock) == exactDateBits(changedAt)
            else {
                throw SyncSnapshotDifferError
                    .themeLanguageClockDoesNotMatchJournal
            }
        } else if exactDateBits(newClock) != exactDateBits(oldClock) {
            throw SyncSnapshotDifferError
                .themeLanguageClockChangedWithoutValues
        }
    }

    private func exactDateBits(_ value: Date) -> UInt64 {
        value.timeIntervalSinceReferenceDate.bitPattern
    }

    private func chainReactivationPayloads(
        from oldSnapshot: NoonmarkSnapshot,
        to newSnapshot: NoonmarkSnapshot
    ) throws -> [String: Data] {
        let oldChains = Dictionary(
            uniqueKeysWithValues: oldSnapshot.chains.map { ($0.id, $0) }
        )
        let oldTraces = Dictionary(
            uniqueKeysWithValues: oldSnapshot.traces.map { ($0.id, $0) }
        )
        let newTraces = Dictionary(
            uniqueKeysWithValues: newSnapshot.traces.map { ($0.id, $0) }
        )

        let witnesses = try newSnapshot.chains.compactMap { restoredChain -> (
            String,
            Data
        )? in
            guard let abandonedChain = oldChains[restoredChain.id],
                  abandonedChain.state == .abandoned,
                  restoredChain.state == .active
            else {
                return nil
            }
            let envelope = try chainReactivationEnvelope(
                abandonedChain: abandonedChain,
                restoredChain: restoredChain,
                oldTraces: oldTraces,
                newTraces: newTraces
            )
            return (
                restoredChain.id.rawValue.uuidString,
                try envelope.canonicalData()
            )
        }
        return Dictionary(uniqueKeysWithValues: witnesses)
    }

    private func chainReactivationEnvelope(
        abandonedChain: TaskChain,
        restoredChain: TaskChain,
        oldTraces: [DayTraceID: DayTrace],
        newTraces: [DayTraceID: DayTrace]
    ) throws -> ChainReactivationEnvelope {
        let boundaryTraces = oldTraces.values.filter {
            $0.chainID == restoredChain.id
                && [.abandoned, .cancelledDraft].contains($0.status)
        }
        var changedBoundary: (DayTrace, DayTrace)?
        for abandonedTrace in boundaryTraces {
            guard let restoredTrace = newTraces[abandonedTrace.id] else {
                throw SyncSnapshotDifferError
                    .invalidChainReactivationBoundary(
                        chainID: restoredChain.id
                    )
            }
            guard abandonedTrace != restoredTrace else { continue }
            guard changedBoundary == nil else {
                throw SyncSnapshotDifferError
                    .invalidChainReactivationBoundary(
                        chainID: restoredChain.id
                    )
            }
            changedBoundary = (abandonedTrace, restoredTrace)
        }

        do {
            return try ChainReactivationEnvelope(
                abandonedChain: abandonedChain,
                restoredChain: restoredChain,
                abandonedTrace: changedBoundary?.0,
                restoredTrace: changedBoundary?.1
            )
        } catch {
            throw SyncSnapshotDifferError.invalidChainReactivationBoundary(
                chainID: restoredChain.id
            )
        }
    }

    private func traceClassificationEventEntries(
        delta: ClassificationDelta,
        deviceID: SyncDeviceID
    ) throws -> [SyncJournalEntry] {
        try delta.appendedEventsByTraceID.values
            .flatMap { $0 }
            .map { event in
                let envelope = try TraceClassificationEventEnvelope(
                    event: event,
                    predecessorEventID: delta.predecessorByEventID[event.id] ?? nil
                )
                return SyncJournalEntry(
                    entityType: .traceClassificationEvent,
                    entityID: event.id.uuidString,
                    changedAt: event.capturedAt,
                    deviceID: deviceID,
                    recordPayload: try envelope.canonicalData()
                )
            }
    }

    private func classificationCommitEntry(
        delta: ClassificationDelta,
        deviceID: SyncDeviceID
    ) throws -> SyncJournalEntry? {
        guard let record = delta.changeRecord else { return nil }
        do {
            let envelope = try ClassificationCommitEnvelope(
                before: delta.stateBeforeCommit,
                after: delta.resultState,
                changeRecord: record
            )
            return SyncJournalEntry(
                entityType: .classificationCommit,
                entityID: record.id.uuidString,
                changedAt: record.committedAt,
                deviceID: deviceID,
                recordPayload: try envelope.canonicalData()
            )
        } catch {
            throw SyncSnapshotDifferError.unsupportedClassificationTransition(
                changeRecordID: record.id,
                reason: String(describing: error)
            )
        }
    }

    private func classificationDelta(
        from oldState: TaskClassificationState,
        to newState: TaskClassificationState
    ) throws -> ClassificationDelta {
        let changeRecord = try appendedChangeRecord(from: oldState, to: newState)
        let eventDelta = try appendedTraceEvents(from: oldState, to: newState)
        try validateClassificationResult(
            stateBeforeCommit: eventDelta.stateBeforeCommit,
            resultState: newState,
            changeRecord: changeRecord
        )

        return ClassificationDelta(
            stateBeforeCommit: eventDelta.stateBeforeCommit,
            resultState: newState,
            appendedEventsByTraceID: eventDelta.appendedEventsByTraceID,
            predecessorByEventID: eventDelta.predecessorByEventID,
            changeRecord: changeRecord
        )
    }

    private func appendedChangeRecord(
        from oldState: TaskClassificationState,
        to newState: TaskClassificationState
    ) throws -> ClassificationChangeRecord? {
        do {
            try oldState.validateIntegrity()
            try newState.validateIntegrity()
        } catch {
            throw SyncSnapshotDifferError.classificationHistoryDiverged
        }
        let oldRecordsByID = Dictionary(
            uniqueKeysWithValues: oldState.changeRecords.map { ($0.id, $0) }
        )
        let newRecordsByID = Dictionary(
            uniqueKeysWithValues: newState.changeRecords.map { ($0.id, $0) }
        )
        guard oldRecordsByID.allSatisfy({ newRecordsByID[$0.key] == $0.value }) else {
            throw SyncSnapshotDifferError.classificationHistoryDiverged
        }
        let appended = newState.changeRecords.filter { oldRecordsByID[$0.id] == nil }
        guard appended.count <= 1 else {
            throw SyncSnapshotDifferError.classificationCommitsMustBePersistedIndividually(
                count: appended.count
            )
        }
        return appended.first
    }

    private func appendedTraceEvents(
        from oldState: TaskClassificationState,
        to newState: TaskClassificationState
    ) throws -> ClassificationTraceEventDelta {
        var stateBeforeCommit = oldState
        var appendedByTraceID: [DayTraceID: [TraceClassificationSnapshot]] = [:]
        var predecessorByEventID: [UUID: UUID?] = [:]
        for (traceID, newEvents) in newState.snapshotEventsByTraceID {
            let oldEvents = oldState.snapshotEventsByTraceID[traceID] ?? []
            guard newEvents.starts(with: oldEvents) else {
                throw SyncSnapshotDifferError.classificationHistoryDiverged
            }
            let appended = Array(newEvents.dropFirst(oldEvents.count))
            guard appended.isEmpty == false else { continue }
            appendedByTraceID[traceID] = appended
            recordEventPredecessors(
                appended,
                after: oldEvents,
                into: &predecessorByEventID
            )
            stateBeforeCommit.snapshotEventsByTraceID[traceID] = newEvents
            stateBeforeCommit.snapshotsByTraceID[traceID] = newEvents.last
        }
        guard oldState.snapshotEventsByTraceID.keys.allSatisfy({
            newState.snapshotEventsByTraceID[$0] != nil
        }) else {
            throw SyncSnapshotDifferError.classificationHistoryDiverged
        }
        let appendedCount = appendedByTraceID.values.reduce(0) { $0 + $1.count }
        guard let eventCount = UInt64(exactly: appendedCount),
              oldState.revision <= UInt64.max - eventCount
        else {
            throw SyncSnapshotDifferError.classificationHistoryDiverged
        }
        stateBeforeCommit.revision = oldState.revision + eventCount
        return ClassificationTraceEventDelta(
            stateBeforeCommit: stateBeforeCommit,
            appendedEventsByTraceID: appendedByTraceID,
            predecessorByEventID: predecessorByEventID
        )
    }

    private func recordEventPredecessors(
        _ appended: [TraceClassificationSnapshot],
        after existing: [TraceClassificationSnapshot],
        into predecessors: inout [UUID: UUID?]
    ) {
        var predecessorID = existing.last?.id
        for event in appended {
            predecessors[event.id] = predecessorID
            predecessorID = event.id
        }
    }

    private func validateClassificationResult(
        stateBeforeCommit: TaskClassificationState,
        resultState: TaskClassificationState,
        changeRecord: ClassificationChangeRecord?
    ) throws {
        guard let changeRecord else {
            guard stateBeforeCommit == resultState else {
                throw SyncSnapshotDifferError.unsupportedClassificationTransition(
                    changeRecordID: nil,
                    reason: "分类状态变化既不是追加轨迹快照，也没有对应 commit record"
                )
            }
            return
        }
        let expectedRevision = try classificationResultRevision(
            after: stateBeforeCommit.revision,
            for: changeRecord
        )
        guard changeRecord.revision == expectedRevision,
              resultState.revision == expectedRevision
        else {
            throw SyncSnapshotDifferError.unsupportedClassificationTransition(
                changeRecordID: changeRecord.id,
                reason: "分类 commit 与轨迹快照的 revision 顺序不连续"
            )
        }
    }

    private func classificationResultRevision(
        after baseRevision: UInt64,
        for changeRecord: ClassificationChangeRecord
    ) throws -> UInt64 {
        guard changeRecord.advancesStateRevision else { return baseRevision }
        let (next, overflow) = baseRevision.addingReportingOverflow(1)
        guard overflow == false else {
            throw SyncSnapshotDifferError.unsupportedClassificationTransition(
                changeRecordID: changeRecord.id,
                reason: "分类 commit revision 溢出"
            )
        }
        return next
    }

    private func changedEntities(
        from oldSnapshot: NoonmarkSnapshot,
        to newSnapshot: NoonmarkSnapshot
    ) -> [ChangedEntity] {
        var entities: [ChangedEntity] = []
        entities += changedDays(from: oldSnapshot.days, to: newSnapshot.days)
        entities += changedTaskCycleSeries(
            from: oldSnapshot.taskCycleSeries,
            to: newSnapshot.taskCycleSeries
        )
        entities += changedChains(from: oldSnapshot.chains, to: newSnapshot.chains)
        entities += changedDefinitions(from: oldSnapshot.definitions, to: newSnapshot.definitions)
        entities += changedTraces(
            from: oldSnapshot.traces,
            to: newSnapshot.traces
        )
        entities += changedSubtasks(from: oldSnapshot.subtasks, to: newSnapshot.subtasks)
        entities += changedIdeas(from: oldSnapshot.ideas, to: newSnapshot.ideas)

        let themeChanged = oldSnapshot.preferences.theme != newSnapshot.preferences.theme
        let languageChanged = oldSnapshot.preferences.language != newSnapshot.preferences.language
        if themeChanged || languageChanged {
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

    private func changedTaskCycleSeries(
        from oldSeries: [TaskCycleSeries],
        to newSeries: [TaskCycleSeries]
    ) -> [ChangedEntity] {
        let oldByID = Dictionary(
            uniqueKeysWithValues: oldSeries.map { ($0.id, $0) }
        )
        return newSeries.compactMap { series in
            oldByID[series.id] == series
                ? nil
                : ChangedEntity(
                    type: .taskCycleSeries,
                    id: series.id.description
                )
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

    private func changedTraces(
        from oldTraces: [DayTrace],
        to newTraces: [DayTrace]
    ) -> [ChangedEntity] {
        let oldByID = Dictionary(uniqueKeysWithValues: oldTraces.map { ($0.id, $0) })
        return newTraces.compactMap { trace in
            oldByID[trace.id] == trace
                ? nil
                : ChangedEntity(type: .dayTrace, id: trace.id.rawValue.uuidString)
        }
    }

    private func changedSubtasks(from oldSubtasks: [Subtask], to newSubtasks: [Subtask]) -> [ChangedEntity] {
        let oldByID = Dictionary(uniqueKeysWithValues: oldSubtasks.map { ($0.id, $0) })
        return newSubtasks.compactMap { subtask in
            oldByID[subtask.id] == subtask ? nil : ChangedEntity(type: .subtask, id: subtask.id.rawValue.uuidString)
        }
    }

    private func changedIdeas(from oldIdeas: [IdeaEntry], to newIdeas: [IdeaEntry]) -> [ChangedEntity] {
        let oldByID = Dictionary(uniqueKeysWithValues: oldIdeas.map { ($0.id, $0) })
        return newIdeas.compactMap { idea in
            oldByID[idea.id] == idea ? nil : ChangedEntity(type: .ideaEntry, id: idea.id.rawValue.uuidString)
        }
    }
}

private struct ClassificationTraceEventDelta {
    let stateBeforeCommit: TaskClassificationState
    let appendedEventsByTraceID: [DayTraceID: [TraceClassificationSnapshot]]
    let predecessorByEventID: [UUID: UUID?]
}

private struct ClassificationDelta {
    let stateBeforeCommit: TaskClassificationState
    let resultState: TaskClassificationState
    let appendedEventsByTraceID: [DayTraceID: [TraceClassificationSnapshot]]
    let predecessorByEventID: [UUID: UUID?]
    let changeRecord: ClassificationChangeRecord?
}

private struct ChangedEntity: Comparable {
    var type: SyncEntityType
    var id: String

    static func < (lhs: ChangedEntity, rhs: ChangedEntity) -> Bool {
        if lhs.type.dependencyOrder != rhs.type.dependencyOrder {
            return lhs.type.dependencyOrder < rhs.type.dependencyOrder
        }
        return lhs.id < rhs.id
    }
}
