import Foundation

public struct SnapshotUndoOutcome: Equatable, Sendable {
    public let automaticClassificationCancelledChainIDs: [TaskChainID]
    public let automaticClassificationRestoredChainIDs: [TaskChainID]

    public init(
        automaticClassificationCancelledChainIDs: [TaskChainID] = [],
        automaticClassificationRestoredChainIDs: [TaskChainID] = []
    ) {
        self.automaticClassificationCancelledChainIDs =
            automaticClassificationCancelledChainIDs
        self.automaticClassificationRestoredChainIDs =
            automaticClassificationRestoredChainIDs
    }
}

public final class NoonmarkEngine {
    public private(set) var days: [LocalDate: Day]
    public private(set) var chains: [TaskChainID: TaskChain]
    public private(set) var definitions: [TaskDefinitionID: TaskDefinition]
    public private(set) var traces: [DayTraceID: DayTrace]
    public private(set) var subtasks: [SubtaskID: Subtask]
    public private(set) var preferences: AppPreferences
    var classificationState: TaskClassificationState

    public init() {
        self.days = [:]
        self.chains = [:]
        self.definitions = [:]
        self.traces = [:]
        self.subtasks = [:]
        self.preferences = AppPreferences()
        self.classificationState = TaskClassificationState()
    }

    public convenience init(snapshot: NoonmarkSnapshot) throws {
        self.init()
        try snapshot.validateIntegrity()
        days = Dictionary(uniqueKeysWithValues: snapshot.days.map { ($0.date, $0) })
        chains = Dictionary(uniqueKeysWithValues: snapshot.chains.map { ($0.id, $0) })
        definitions = Dictionary(uniqueKeysWithValues: snapshot.definitions.map { ($0.id, $0) })
        traces = Dictionary(uniqueKeysWithValues: snapshot.traces.map { ($0.id, $0) })
        subtasks = Dictionary(uniqueKeysWithValues: snapshot.subtasks.map { ($0.id, $0) })
        preferences = snapshot.preferences
        classificationState = snapshot.classifications
    }

    public func snapshot() -> NoonmarkSnapshot {
        let traceByID = traces
        return NoonmarkSnapshot(
            days: days.values.sorted { $0.date < $1.date },
            chains: chains.values.sorted {
                if $0.createdAt == $1.createdAt {
                    return $0.id.description < $1.id.description
                }
                return $0.createdAt < $1.createdAt
            },
            definitions: definitions.values.sorted {
                if $0.chainID == $1.chainID {
                    return $0.sequence < $1.sequence
                }
                return $0.chainID.description < $1.chainID.description
            },
            traces: traces.values.sorted(by: traceChronology),
            subtasks: subtasks.values.sorted {
                if let lhsTrace = traceByID[$0.traceID], let rhsTrace = traceByID[$1.traceID], lhsTrace != rhsTrace {
                    return traceChronology(lhsTrace, rhsTrace)
                }
                if $0.traceID == $1.traceID, $0.position != $1.position {
                    return $0.position < $1.position
                }
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                return $0.id.description < $1.id.description
            },
            preferences: preferences,
            classifications: classificationState
        )
    }

    @discardableResult
    public func prepareSnapshotUndo(
        replacing currentSnapshot: NoonmarkSnapshot,
        now: Date = Date()
    ) throws -> SnapshotUndoOutcome {
        let candidate = try NoonmarkEngine(snapshot: snapshot())
        let outcome = try candidate.prepareSnapshotUndoInPlace(
            replacing: currentSnapshot,
            now: now
        )
        adoptState(from: candidate)
        return outcome
    }

    private func prepareSnapshotUndoInPlace(
        replacing currentSnapshot: NoonmarkSnapshot,
        now: Date
    ) throws -> SnapshotUndoOutcome {
        try currentSnapshot.validateIntegrity()
        let current = SnapshotUndoCurrentFacts(currentSnapshot)
        let outcome = snapshotUndoOutcome(from: current)
        retainCurrentOnlySnapshotUndoFacts(from: current, now: now)
        try restoreSnapshotUndoChains(from: current, now: now)
        try restoreSnapshotUndoDefinitions(from: current, now: now)
        try restoreSnapshotUndoTraces(from: current, now: now)
        try restoreSnapshotUndoSubtasks(from: current, now: now)

        // Classification commits and captured history are immutable audit facts.
        // New-task undo compensates only current automatic relations. Explicit,
        // inherited and deterministic relations remain current across undo/redo.
        classificationState = currentSnapshot.classifications
        for chainID in outcome.automaticClassificationCancelledChainIDs {
            try removeAutomaticClassificationForSnapshotUndo(
                chainID: chainID,
                now: now
            )
        }
        try snapshot().validateIntegrity()
        return outcome
    }

    private func adoptState(from candidate: NoonmarkEngine) {
        days = candidate.days
        chains = candidate.chains
        definitions = candidate.definitions
        traces = candidate.traces
        subtasks = candidate.subtasks
        preferences = candidate.preferences
        classificationState = candidate.classificationState
    }

    @discardableResult
    public func createPoolTask(
        title: String,
        descriptionText: String? = nil,
        initialNoteBody: String? = nil,
        now: Date = Date()
    ) throws -> TaskChainID {
        let normalizedTitle = try normalizeTitle(title)
        let noteEntries = try normalizedOptionalText(initialNoteBody)
            .map { [try TaskNoteEntry(body: $0, now: now)] } ?? []
        let chain = TaskChain(noteEntries: noteEntries, now: now)
        let definition = TaskDefinition(
            chainID: chain.id,
            sequence: 1,
            title: normalizedTitle,
            descriptionText: descriptionText,
            now: now
        )

        chains[chain.id] = chain
        definitions[definition.id] = definition
        return chain.id
    }

    public func updatePoolTask(
        chainID: TaskChainID,
        title: String,
        descriptionText: String? = nil,
        plannedSubtasks: [PlannedSubtask]? = nil,
        now: Date = Date()
    ) throws {
        let normalizedTitle = try normalizeTitle(title)
        var definition = try currentDefinition(for: chainID)
        guard traces.values.contains(where: {
            $0.chainID == chainID && $0.formsDayHistory
        }) == false else {
            throw NoonmarkError.invalidTransition("task definitions with traces cannot be overwritten")
        }

        let nextPlannedSubtasks = plannedSubtasks?
            .sorted { $0.position < $1.position } ?? definition.plannedSubtasks
        guard definition.title != normalizedTitle
            || definition.descriptionText != descriptionText
            || definition.plannedSubtasks != nextPlannedSubtasks
        else { return }
        try definition.markContentModified(at: now)
        definition.title = normalizedTitle
        definition.descriptionText = descriptionText
        definition.plannedSubtasks = nextPlannedSubtasks
        definitions[definition.id] = definition
        try touchChain(chainID, now: now)
    }

    @discardableResult
    public func appendPoolNote(
        chainID: TaskChainID,
        body: String,
        now: Date = Date()
    ) throws -> TaskNoteEntryID {
        guard isInTaskPool(chainID) else {
            throw NoonmarkError.invalidTransition("only task-pool tasks can append notes")
        }
        var chain = try chain(chainID)
        try TaskNoteEntry.validateMutationTime(now, notBefore: chain.createdAt)
        let note = try TaskNoteEntry(body: body, now: now)
        chain.noteEntries.append(note)
        chains[chain.id] = chain
        return note.id
    }

    public func editPoolNote(
        chainID: TaskChainID,
        noteID: TaskNoteEntryID,
        body: String,
        now: Date = Date()
    ) throws {
        guard isInTaskPool(chainID) else {
            throw NoonmarkError.invalidTransition("only task-pool tasks can edit notes")
        }
        var chain = try chain(chainID)
        try chain.noteEntries.editTaskNote(
            id: noteID,
            body: body,
            now: now,
            ownerUpdatedAt: chain.createdAt
        )
        chains[chain.id] = chain
    }

    public func deletePoolNote(
        chainID: TaskChainID,
        noteID: TaskNoteEntryID,
        now: Date = Date()
    ) throws {
        guard isInTaskPool(chainID) else {
            throw NoonmarkError.invalidTransition("only task-pool tasks can delete notes")
        }
        var chain = try chain(chainID)
        try chain.noteEntries.deleteTaskNote(
            id: noteID,
            now: now,
            ownerUpdatedAt: chain.createdAt
        )
        chains[chain.id] = chain
    }

    public func renameTaskTitle(
        chainID: TaskChainID,
        title: String,
        today: LocalDate,
        now: Date = Date()
    ) throws {
        let normalizedTitle = try normalizeTitle(title)
        let chain = try chain(chainID)
        guard chain.state == .active else {
            throw NoonmarkError.chainAbandoned
        }

        let chainTraces = traces.values.filter {
            $0.chainID == chainID && $0.formsDayHistory
        }
        let editableStatuses: Set<TraceStatus> = [.pending, .returnedToPool]
        guard chainTraces.isEmpty || chainTraces.contains(where: { editableStatuses.contains($0.status) }) else {
            throw NoonmarkError.invalidTransition("completed and unfinished task facts cannot be renamed")
        }
        guard chainTraces.allSatisfy({ $0.status != .pending || $0.date >= today }) else {
            throw NoonmarkError.immutableHistory
        }
        for trace in chainTraces where trace.status == .pending {
            try ensureUnlockedDay(trace.date)
        }

        var currentDefinition = try currentDefinition(for: chainID)
        guard currentDefinition.title != normalizedTitle else { return }

        if chainTraces.isEmpty {
            try currentDefinition.markContentModified(at: now)
            currentDefinition.title = normalizedTitle
            definitions[currentDefinition.id] = currentDefinition
        } else {
            let nextSequence = (definitions.values
                .filter { $0.chainID == chainID }
                .map(\.sequence)
                .max() ?? currentDefinition.sequence) + 1
            let renamedDefinition = TaskDefinition(
                chainID: chainID,
                sequence: nextSequence,
                title: normalizedTitle,
                descriptionText: currentDefinition.descriptionText,
                plannedSubtasks: currentDefinition.plannedSubtasks,
                now: now
            )

            try currentDefinition.markContentModified(at: now)
            currentDefinition.supersededAt = now
            currentDefinition.supersededByDefinitionID = renamedDefinition.id
            var renamedTraces: [DayTrace] = []
            for trace in chainTraces where trace.status == .pending {
                var renamedTrace = trace
                try renamedTrace.markContentModified(at: now)
                renamedTrace.definitionID = renamedDefinition.id
                renamedTraces.append(renamedTrace)
            }

            definitions[currentDefinition.id] = currentDefinition
            definitions[renamedDefinition.id] = renamedDefinition
            for renamedTrace in renamedTraces {
                traces[renamedTrace.id] = renamedTrace
            }
        }

        try touchChain(chainID, now: now)
    }

    @discardableResult
    public func addPlannedSubtask(
        chainID: TaskChainID,
        title: String,
        difficulty: SubtaskDifficulty = .simple,
        now: Date = Date()
    ) throws -> PlannedSubtaskID {
        let normalizedTitle = try normalizeTitle(title)
        var definition = try currentDefinition(for: chainID)
        guard traces.values.contains(where: {
            $0.chainID == chainID && $0.formsDayHistory
        }) == false else {
            throw NoonmarkError.invalidTransition("planned subtasks can only be edited before scheduling")
        }

        let plannedSubtask = PlannedSubtask(
            title: normalizedTitle,
            difficulty: difficulty,
            position: definition.plannedSubtasks.count + 1,
            now: now
        )
        try definition.markContentModified(at: now)
        definition.plannedSubtasks.append(plannedSubtask)
        definitions[definition.id] = definition
        try touchChain(chainID, now: now)
        return plannedSubtask.id
    }

    public func removePlannedSubtask(
        chainID: TaskChainID,
        plannedSubtaskID: PlannedSubtaskID,
        now: Date = Date()
    ) throws {
        var definition = try currentDefinition(for: chainID)
        guard traces.values.contains(where: {
            $0.chainID == chainID && $0.formsDayHistory
        }) == false else {
            throw NoonmarkError.invalidTransition("planned subtasks can only be edited before scheduling")
        }
        guard definition.plannedSubtasks.contains(where: { $0.id == plannedSubtaskID }) else {
            throw NoonmarkError.notFound("planned subtask")
        }

        let nextPlannedSubtasks = definition.plannedSubtasks
            .filter { $0.id != plannedSubtaskID }
            .enumerated()
            .map { index, plannedSubtask in
                var plannedSubtask = plannedSubtask
                plannedSubtask.position = index + 1
                return plannedSubtask
            }
        try definition.markContentModified(at: now)
        definition.plannedSubtasks = nextPlannedSubtasks
        definitions[definition.id] = definition
        try touchChain(chainID, now: now)
    }

    public func updatePlannedSubtaskDifficulty(
        chainID: TaskChainID,
        plannedSubtaskID: PlannedSubtaskID,
        difficulty: SubtaskDifficulty,
        now: Date = Date()
    ) throws {
        var definition = try currentDefinition(for: chainID)
        guard traces.values.contains(where: {
            $0.chainID == chainID && $0.formsDayHistory
        }) == false else {
            throw NoonmarkError.invalidTransition("planned subtasks can only be edited before scheduling")
        }
        guard let index = definition.plannedSubtasks.firstIndex(where: { $0.id == plannedSubtaskID }) else {
            throw NoonmarkError.notFound("planned subtask")
        }
        guard definition.plannedSubtasks[index].difficulty != difficulty else { return }

        try definition.markContentModified(at: now)
        definition.plannedSubtasks[index].difficulty = difficulty
        definitions[definition.id] = definition
        try touchChain(chainID, now: now)
    }

    @discardableResult
    public func scheduleFromPool(
        chainID: TaskChainID,
        date: LocalDate,
        today: LocalDate,
        now: Date = Date()
    ) throws -> DayTraceID {
        try ensureActiveChain(chainID)
        guard isInTaskPool(chainID) else {
            throw NoonmarkError.invalidTransition("only task-pool tasks can be scheduled from pool")
        }
        guard date >= today else {
            throw NoonmarkError.invalidTransition("task-pool tasks cannot be scheduled into the past")
        }
        try ensureUnlockedDay(date)

        let definition = try currentDefinition(for: chainID)
        let chain = try chain(chainID)
        let trace = DayTrace(
            chainID: chainID,
            definitionID: definition.id,
            date: date,
            priority: nextPriority(on: date),
            descriptionText: definition.descriptionText,
            noteEntries: chain.activeNoteEntries,
            now: now
        )
        traces[trace.id] = trace
        copyPlannedSubtasks(from: definition, to: trace.id, now: now)
        ensureDay(date, now: now)
        return trace.id
    }

    @discardableResult
    public func deleteUnscheduledTask(
        chainID: TaskChainID,
        now: Date = Date()
    ) throws -> TaskPoolRemovalOutcome {
        guard traces.values.contains(where: { $0.chainID == chainID }) == false else {
            throw NoonmarkError.invalidTransition("scheduled tasks cannot be deleted")
        }
        guard chains[chainID] != nil else {
            throw NoonmarkError.notFound("task chain")
        }

        let keepsClassificationHistory =
            classificationState.referencesTaskChain(chainID)
        var chain = try chain(chainID)
        try chain.markContentModified(at: now)
        if keepsClassificationHistory {
            try removeCurrentClassificationForRetiredTask(chainID: chainID, now: now)
        }

        // “删除”是用户投影语义；存储与同步必须保留同一 chain／definition
        // 身份作为 append-only 取消事实，避免旧 creation record 在重启或
        // 其他设备上复活。
        chain.state = .abandoned
        chains[chainID] = chain
        return keepsClassificationHistory
            ? .removedKeepingHistory
            : .deleted
    }

    @discardableResult
    public func removeTaskFromPool(
        chainID: TaskChainID,
        now: Date = Date()
    ) throws -> TaskPoolRemovalOutcome {
        guard isInTaskPool(chainID) else {
            throw NoonmarkError.invalidTransition("only task-pool tasks can be removed")
        }

        let chainTraces = traces.values.filter { $0.chainID == chainID }
        guard chainTraces.allSatisfy({
            $0.status == .returnedToPool || $0.status == .cancelledDraft
        }) else {
            throw NoonmarkError.invalidTransition("completed and unfinished task facts cannot be deleted")
        }

        guard chainTraces.isEmpty == false else {
            return try deleteUnscheduledTask(chainID: chainID, now: now)
        }

        var chain = try chain(chainID)
        try chain.markContentModified(at: now)
        try removeCurrentClassificationForRetiredTask(
            chainID: chainID,
            now: now
        )
        chain.state = .abandoned
        chains[chainID] = chain
        return .removedKeepingHistory
    }

    private func removeCurrentClassificationForRetiredTask(
        chainID: TaskChainID,
        reason: String = "task removed from task pool while preserving classification history",
        now: Date
    ) throws {
        guard let current = classificationState.currentByChainID[chainID],
              current.category != nil || current.labels.isEmpty == false
        else { return }

        let interactionID = UUID()
        let plan = try prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: nil,
                    labels: []
                )
            ),
            source: .deterministicDomainAction(reason: reason),
            interactionID: interactionID,
            now: now
        )
        try commitDeterministicDomainClassification(plan, now: now)
    }

    private func removeAutomaticClassificationForSnapshotUndo(
        chainID: TaskChainID,
        now: Date
    ) throws {
        guard let current = classificationState.currentByChainID[chainID]
        else { return }
        let category = current.category.flatMap { relation in
            guard case .automaticAI = relation.source else {
                return TaskCategoryChoice.existing(relation.categoryID)
            }
            return nil
        }
        let labels = current.labels.compactMap { relation in
            guard case .automaticAI = relation.source else {
                return TaskLabelChoice.existing(relation.labelID)
            }
            return nil
        }
        guard category != current.categoryID.map(TaskCategoryChoice.existing)
            || labels.count != current.labels.count
        else { return }
        let plan = try prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: category,
                    labels: labels
                )
            ),
            source: .deterministicDomainAction(
                reason: "snapshot undo cancelled a new task classification"
            ),
            interactionID: UUID(),
            now: now
        )
        try commitDeterministicDomainClassification(plan, now: now)
    }

    public func getDayTodo(date: LocalDate, sort: ViewSort = .priority) -> DayTodoView {
        let items = traces.values.filter {
            $0.date == date && $0.formsDayHistory
        }
        return DayTodoView(day: days[date], traces: sorted(items, by: sort))
    }

    public func taskPool() -> [PoolTask] {
        chains.values
            .filter { chain in
                isInTaskPool(chain.id)
            }
            .compactMap { chain in
                guard let definition = try? currentDefinition(for: chain.id) else { return nil }
                return PoolTask(chain: chain, definition: definition)
            }
            .sorted { $0.definition.createdAt < $1.definition.createdAt }
    }

    public func futurePlans(today: LocalDate) -> [FuturePlanItem] {
        traces.values
            .filter { $0.status == .pending && $0.date > today }
            .compactMap { trace in
                guard let definition = definitions[trace.definitionID] else { return nil }
                return FuturePlanItem(trace: trace, definition: definition)
            }
            .sorted {
                if $0.trace.date == $1.trace.date {
                    return $0.trace.priority < $1.trace.priority
                }
                return $0.trace.date < $1.trace.date
            }
    }

    public func unfinishedPool() -> [UnfinishedPoolItem] {
        let unresolvedStatuses: Set<TraceStatus> = [.unfinished, .continued, .abandoned]
        let unresolvedCandidatesByChain = Dictionary(grouping: traces.values.filter { unresolvedStatuses.contains($0.status) }) {
            $0.chainID
        }

        return unresolvedCandidatesByChain.compactMap { chainID, candidateTraces in
            let continuedCount = candidateTraces.filter { $0.status == .continued }.count
            let unfinishedTraces = candidateTraces.filter { trace in
                trace.status == .unfinished
                    || trace.status == .abandoned
                    || (trace.status == .continued && (trace.settledAt != nil || continuedCount > 1))
            }

            guard
                unfinishedTraces.isEmpty == false,
                var chain = chains[chainID],
                chain.state == .active || chain.state == .abandoned,
                let definition = try? currentDefinition(for: chainID),
                hasCompletedTrace(chainID) == false
            else {
                return nil
            }

            let activeTrace = activeTrace(for: chainID)
            chain.updatedAt = unfinishedTraces.map(\.createdAt).max() ?? chain.updatedAt
            return UnfinishedPoolItem(
                chain: chain,
                definition: definition,
                unfinishedTraces: unfinishedTraces.sorted { $0.date < $1.date },
                activeTrace: activeTrace
            )
        }
        .sorted { lhs, rhs in
            if lhs.chain.createdAt != rhs.chain.createdAt {
                return lhs.chain.createdAt < rhs.chain.createdAt
            }
            return lhs.definition.title.localizedStandardCompare(rhs.definition.title) == .orderedAscending
        }
    }

    public func completedPool() -> [CompletedPoolItem] {
        traces.values
            .filter { $0.status == .completed }
            .compactMap { trace in
                guard let definition = definitions[trace.definitionID] else { return nil }
                return CompletedPoolItem(
                    trace: trace,
                    definition: definition,
                    trajectory: completedTrajectory(for: trace)
                )
            }
            .sorted {
                if $0.trace.date == $1.trace.date {
                    return ($0.trace.completedAt ?? $0.trace.createdAt) > ($1.trace.completedAt ?? $1.trace.createdAt)
                }
                return $0.trace.date > $1.trace.date
            }
    }

    public func completedSubtaskRecords() -> [CompletedSubtaskRecord] {
        subtasks.values
            .filter { $0.status == .completed }
            .compactMap { subtask -> CompletedSubtaskRecord? in
                guard
                    let trace = traces[subtask.traceID],
                    trace.formsDayHistory,
                    let definition = definitions[trace.definitionID]
                else {
                    return nil
                }
                return CompletedSubtaskRecord(
                    date: trace.date,
                    subtask: subtask,
                    parentTrace: trace,
                    parentDefinition: definition
                )
            }
            .sorted {
                if $0.date != $1.date {
                    return $0.date > $1.date
                }
                if $0.subtask.position != $1.subtask.position {
                    return $0.subtask.position < $1.subtask.position
                }
                return $0.subtask.createdAt < $1.subtask.createdAt
            }
    }

    public func completionCapability(
        for traceID: DayTraceID,
        today: LocalDate
    ) throws -> DayTraceCompletionCapability {
        completionCapability(
            for: try trace(traceID),
            today: today
        )
    }

    public func markCompleted(traceID: DayTraceID, today: LocalDate, now: Date = Date()) throws {
        var trace = try tracePermittedForCompletionAction(
            .complete,
            traceID: traceID,
            today: today
        )

        try trace.markContentModified(at: now)
        trace.status = .completed
        trace.completedAt = now
        traces[trace.id] = trace
        try touchChain(trace.chainID, now: now)
    }

    public func undoCompleted(traceID: DayTraceID, today: LocalDate, now: Date = Date()) throws {
        var trace = try tracePermittedForCompletionAction(
            .undo,
            traceID: traceID,
            today: today
        )

        try trace.markContentModified(at: now)
        trace.status = .pending
        trace.completedAt = nil
        traces[trace.id] = trace
        try touchChain(trace.chainID, now: now)
    }

    public func returnToPool(traceID: DayTraceID, today: LocalDate, now: Date = Date()) throws {
        var trace = try trace(traceID)
        try ensureUnlockedDay(trace.date)

        if trace.date > today {
            guard trace.continuedFromTraceID == nil else {
                throw NoonmarkError.invalidTransition("continued future traces cannot return to pool without a trace")
            }
            guard trace.status == .pending else {
                throw NoonmarkError.invalidTransition(
                    "only pending future plans can return to pool"
                )
            }
            try trace.markContentModified(at: now)
            trace.status = .cancelledDraft
            trace.settledAt = now
            trace.draftCancellationID = UUID()
            trace.draftCancelledOn = today
            traces[trace.id] = trace
            try touchChain(trace.chainID, now: now)
            return
        }

        guard trace.date == today else {
            throw NoonmarkError.immutableHistory
        }
        guard trace.status == .pending else {
            throw NoonmarkError.invalidTransition("only pending current-day traces can return to pool")
        }

        try trace.markContentModified(at: now)
        trace.status = .returnedToPool
        trace.settledAt = now
        traces[trace.id] = trace
        captureClassificationSnapshot(traceID: trace.id, chainID: trace.chainID, now: now)
        try touchChain(trace.chainID, now: now)
    }

    public func rescheduleFuturePlan(traceID: DayTraceID, targetDate: LocalDate, today: LocalDate, now: Date = Date()) throws {
        var trace = try trace(traceID)
        try ensureUnlockedDay(trace.date)
        try ensureUnlockedDay(targetDate)
        guard trace.date > today, targetDate > today else {
            throw NoonmarkError.invalidTransition("only future plans can be rescheduled to future dates")
        }
        guard trace.status == .pending else {
            throw NoonmarkError.invalidTransition("only pending future plans can be rescheduled")
        }

        try trace.markContentModified(at: now)
        trace.date = targetDate
        trace.priority = nextPriority(on: targetDate)
        traces[trace.id] = trace
        ensureDay(targetDate, now: now)
    }

    @discardableResult
    public func continueTrace(
        traceID: DayTraceID,
        targetDate: LocalDate,
        today: LocalDate,
        now: Date = Date()
    ) throws -> DayTraceID {
        var source = try trace(traceID)
        try ensureActiveChain(source.chainID)
        try ensureUnlockedDay(targetDate)
        guard targetDate >= today else {
            throw NoonmarkError.invalidTransition("continuation target cannot be in the past")
        }
        guard source.status == .unfinished || (source.status == .pending && source.date == today) else {
            throw NoonmarkError.invalidTransition("only historical unfinished or current pending traces can continue")
        }

        if let active = activeTrace(for: source.chainID), active.id != source.id {
            throw NoonmarkError.activeTraceAlreadyExists
        }

        let definition = try currentDefinition(for: source.chainID)
        let nextTrace = DayTrace(
            chainID: source.chainID,
            definitionID: definition.id,
            date: targetDate,
            priority: nextPriority(on: targetDate),
            continuationSeq: source.continuationSeq + 1,
            descriptionText: source.descriptionText,
            noteEntries: source.activeNoteEntries,
            manualProgressPercent: traceProgress(for: source.id).percent,
            continuedFromTraceID: source.id,
            now: now
        )

        let sourceWasUnfinished = source.status == .unfinished
        try source.markContentModified(at: now)
        source.status = .continued
        source.settledAt = sourceWasUnfinished ? (source.settledAt ?? now) : nil
        traces[source.id] = source
        traces[nextTrace.id] = nextTrace
        captureClassificationSnapshot(traceID: source.id, chainID: source.chainID, now: now)

        try copyOpenSubtasks(from: source.id, to: nextTrace.id, now: now)
        ensureDay(targetDate, now: now)
        try touchChain(source.chainID, now: now)
        return nextTrace.id
    }

    @discardableResult
    public func changeTrace(
        traceID: DayTraceID,
        newTitle: String,
        newDescriptionText: String? = nil,
        initialNoteBody: String? = nil,
        today: LocalDate,
        now: Date = Date()
    ) throws -> DayTraceID {
        let normalizedTitle = try normalizeTitle(newTitle)
        let noteEntries = try normalizedOptionalText(initialNoteBody)
            .map { [try TaskNoteEntry(body: $0, now: now)] } ?? []
        var oldTrace = try trace(traceID)
        try ensureActiveChain(oldTrace.chainID)
        try ensureUnlockedDay(oldTrace.date)
        guard oldTrace.date == today, oldTrace.status == .pending else {
            throw NoonmarkError.invalidTransition("only pending current-day traces can change definition")
        }

        let newChain = TaskChain(noteEntries: noteEntries, now: now)
        let newDefinition = TaskDefinition(
            chainID: newChain.id,
            sequence: 1,
            title: normalizedTitle,
            descriptionText: newDescriptionText,
            now: now
        )

        let newTrace = DayTrace(
            chainID: newChain.id,
            definitionID: newDefinition.id,
            date: today,
            priority: nextPriority(on: today),
            descriptionText: newDefinition.descriptionText,
            noteEntries: newChain.activeNoteEntries,
            now: now
        )

        try oldTrace.markContentModified(at: now)
        oldTrace.status = .changed
        oldTrace.changedToTraceID = newTrace.id
        oldTrace.settledAt = now

        chains[newChain.id] = newChain
        definitions[newDefinition.id] = newDefinition
        traces[oldTrace.id] = oldTrace
        traces[newTrace.id] = newTrace
        captureClassificationSnapshot(traceID: oldTrace.id, chainID: oldTrace.chainID, now: now)
        try inheritCurrentClassification(from: oldTrace.chainID, to: newChain.id, now: now)
        try touchChain(oldTrace.chainID, now: now)
        return newTrace.id
    }

    public func abandonChain(from traceID: DayTraceID, now: Date = Date()) throws {
        let requestedTrace = try trace(traceID)
        var chain = try chain(requestedTrace.chainID)
        guard chain.state == .active else {
            throw NoonmarkError.chainAbandoned
        }
        var trace = activeTrace(for: requestedTrace.chainID) ?? requestedTrace
        guard trace.status == .pending || trace.status == .unfinished else {
            throw NoonmarkError.invalidTransition("only pending or unfinished traces can abandon their chain")
        }

        try trace.markContentModified(at: now)
        try chain.markContentModified(at: now)
        trace.status = .abandoned
        trace.settledAt = now
        chain.state = .abandoned

        traces[trace.id] = trace
        chains[chain.id] = chain
        captureClassificationSnapshot(traceID: trace.id, chainID: trace.chainID, now: now)
    }

    @discardableResult
    public func reactivateAbandonedChain(
        from traceID: DayTraceID,
        today: LocalDate,
        now: Date = Date()
    ) throws -> DayTraceID {
        var source = try trace(traceID)
        var chain = try chain(source.chainID)
        guard chain.state == .abandoned, source.status == .abandoned else {
            throw NoonmarkError.invalidTransition("only abandoned chains can be reactivated")
        }
        if activeTrace(for: source.chainID) != nil {
            throw NoonmarkError.activeTraceAlreadyExists
        }

        try source.markContentModified(at: now)
        try chain.markContentModified(at: now)
        if days[source.date]?.lockedAt != nil {
            source.status = .unfinished
            source.settledAt = source.settledAt ?? now
        } else if source.date >= today {
            source.status = .pending
            source.settledAt = nil
        } else {
            source.status = .unfinished
            source.settledAt = source.settledAt ?? now
        }
        chain.state = .active

        traces[source.id] = source
        chains[chain.id] = chain
        if source.status == .unfinished {
            captureClassificationSnapshot(traceID: source.id, chainID: source.chainID, now: now)
        }
        return source.id
    }

    @discardableResult
    public func copyAsNewTask(
        from traceID: DayTraceID,
        target: NewTaskTarget,
        today: LocalDate,
        now: Date = Date()
    ) throws -> TaskChainID {
        let source = try trace(traceID)
        let sourceDefinition = try definition(source.definitionID)
        let sourceNotes = source.activeNoteEntries
        let newChainID = try createPoolTask(
            title: sourceDefinition.title,
            descriptionText: source.descriptionText ?? sourceDefinition.descriptionText,
            initialNoteBody: sourceNotes.first?.body,
            now: now
        )
        for note in sourceNotes.dropFirst() {
            _ = try appendPoolNote(chainID: newChainID, body: note.body, now: now)
        }

        if case let .date(date) = target {
            _ = try scheduleFromPool(chainID: newChainID, date: date, today: today, now: now)
        }

        try inheritCurrentClassification(from: source.chainID, to: newChainID, now: now)
        return newChainID
    }

    @discardableResult
    public func addSubtask(
        traceID: DayTraceID,
        title: String,
        difficulty: SubtaskDifficulty = .simple,
        now: Date = Date()
    ) throws -> SubtaskID {
        let normalizedTitle = try normalizeTitle(title)
        let trace = try trace(traceID)
        try ensureUnlockedDay(trace.date)
        guard trace.status == .pending else {
            throw NoonmarkError.invalidTransition("subtasks can only be added to pending traces")
        }

        let position = subtasks.values.filter { $0.traceID == traceID }.count + 1
        let subtask = Subtask(
            traceID: trace.id,
            title: normalizedTitle,
            difficulty: difficulty,
            position: position,
            now: now
        )
        subtasks[subtask.id] = subtask
        return subtask.id
    }

    public func completeSubtask(_ subtaskID: SubtaskID, today: LocalDate, now: Date = Date()) throws {
        guard var subtask = subtasks[subtaskID] else {
            throw NoonmarkError.notFound("subtask")
        }
        let trace = try trace(subtask.traceID)
        try ensureUnlockedDay(trace.date)
        guard trace.date == today, trace.status == .pending else {
            throw NoonmarkError.immutableHistory
        }
        guard subtask.status == .pending else {
            throw NoonmarkError.invalidTransition("only pending subtasks can be completed")
        }
        try subtask.markContentModified(at: now)
        subtask.status = .completed
        subtask.completedAt = now
        subtasks[subtask.id] = subtask
    }

    public func undoCompletedSubtask(
        _ subtaskID: SubtaskID,
        today: LocalDate,
        now: Date
    ) throws {
        guard var subtask = subtasks[subtaskID] else {
            throw NoonmarkError.notFound("subtask")
        }
        let trace = try trace(subtask.traceID)
        try ensureUnlockedDay(trace.date)
        guard trace.date == today, trace.status == .pending else {
            throw NoonmarkError.immutableHistory
        }
        guard subtask.status == .completed else {
            throw NoonmarkError.invalidTransition("only completed subtasks can be undone")
        }

        try subtask.markContentModified(at: now)
        subtask.status = .pending
        subtask.completedAt = nil
        subtasks[subtask.id] = subtask
    }

    public func abandonSubtask(_ subtaskID: SubtaskID, today: LocalDate, now: Date = Date()) throws {
        guard var subtask = subtasks[subtaskID] else {
            throw NoonmarkError.notFound("subtask")
        }
        let trace = try trace(subtask.traceID)
        try ensureUnlockedDay(trace.date)
        guard trace.date == today, trace.status == .pending else {
            throw NoonmarkError.immutableHistory
        }
        guard subtask.status == .pending else {
            throw NoonmarkError.invalidTransition("only pending subtasks can be abandoned")
        }
        try subtask.markContentModified(at: now)
        subtask.status = .abandoned
        subtask.settledAt = now
        subtasks[subtask.id] = subtask
    }

    public func updateSubtaskDifficulty(
        _ subtaskID: SubtaskID,
        difficulty: SubtaskDifficulty,
        today: LocalDate,
        now: Date
    ) throws {
        guard var subtask = subtasks[subtaskID] else {
            throw NoonmarkError.notFound("subtask")
        }
        let trace = try trace(subtask.traceID)
        try ensureUnlockedDay(trace.date)
        guard trace.date == today, trace.status == .pending else {
            throw NoonmarkError.immutableHistory
        }
        guard subtask.status != .cancelledDraft else {
            throw NoonmarkError.notFound("subtask")
        }

        guard subtask.difficulty != difficulty else { return }
        try subtask.markContentModified(at: now)
        subtask.difficulty = difficulty
        subtasks[subtask.id] = subtask
    }

    public func updateTraceText(
        traceID: DayTraceID,
        descriptionText: String?,
        today: LocalDate,
        now: Date = Date()
    ) throws {
        var trace = try trace(traceID)
        try ensureUnlockedDay(trace.date)
        guard trace.status == .pending else {
            throw NoonmarkError.invalidTransition("only pending traces can update descriptive text")
        }
        guard trace.date >= today else {
            throw NoonmarkError.immutableHistory
        }

        let normalizedDescription = normalizedOptionalText(descriptionText)
        guard trace.descriptionText != normalizedDescription else { return }
        try trace.markContentModified(at: now)
        trace.descriptionText = normalizedDescription
        traces[trace.id] = trace
    }

    public func editTraceNote(
        traceID: DayTraceID,
        noteID: TaskNoteEntryID,
        body: String,
        today: LocalDate,
        now: Date = Date()
    ) throws {
        var trace = try trace(traceID)
        try ensureUnlockedDay(trace.date)
        guard trace.status == .pending else {
            throw NoonmarkError.invalidTransition("only pending traces can edit notes")
        }
        guard trace.date >= today else {
            throw NoonmarkError.immutableHistory
        }
        try trace.noteEntries.editTaskNote(id: noteID, body: body, now: now)
        traces[trace.id] = trace
    }

    @discardableResult
    public func appendTraceNote(
        traceID: DayTraceID,
        body: String,
        today: LocalDate,
        now: Date = Date()
    ) throws -> TaskNoteEntryID {
        var trace = try trace(traceID)
        try ensureUnlockedDay(trace.date)
        guard trace.status == .pending else {
            throw NoonmarkError.invalidTransition("only pending traces can append notes")
        }
        guard trace.date >= today else {
            throw NoonmarkError.immutableHistory
        }
        try TaskNoteEntry.validateMutationTime(now, notBefore: trace.createdAt)
        let note = try TaskNoteEntry(body: body, now: now)
        trace.noteEntries.append(note)
        traces[trace.id] = trace
        return note.id
    }

    public func deleteTraceNote(
        traceID: DayTraceID,
        noteID: TaskNoteEntryID,
        today: LocalDate,
        now: Date = Date()
    ) throws {
        var trace = try trace(traceID)
        try ensureUnlockedDay(trace.date)
        guard trace.status == .pending else {
            throw NoonmarkError.invalidTransition("only pending traces can delete notes")
        }
        guard trace.date >= today else {
            throw NoonmarkError.immutableHistory
        }
        try trace.noteEntries.deleteTaskNote(id: noteID, now: now)
        traces[trace.id] = trace
    }

    public func setManualProgress(
        traceID: DayTraceID,
        percent: Int,
        today: LocalDate,
        now: Date = Date()
    ) throws {
        var trace = try trace(traceID)
        try ensureUnlockedDay(trace.date)
        guard trace.date == today, trace.status == .pending else {
            throw NoonmarkError.immutableHistory
        }
        guard hasSubtasks(in: trace.chainID) == false else {
            throw NoonmarkError.invalidTransition("manual progress is unavailable when subtasks define weighted progress")
        }

        let clamped = min(100, max(0, percent))
        let floor = progressFloor(for: trace)
        let nextProgress = max(floor, clamped)
        guard trace.manualProgressPercent != nextProgress else { return }
        try trace.markContentModified(at: now)
        trace.manualProgressPercent = nextProgress
        traces[trace.id] = trace
    }

    public func subtaskProgress(for traceID: DayTraceID) -> SubtaskProgress {
        let items = subtasks.values.filter {
            $0.traceID == traceID && $0.isUserPresentable
        }
        return SubtaskProgress(
            total: items.count,
            completed: items.filter { $0.status == .completed }.count,
            pending: items.filter { $0.status == .pending }.count,
            unfinished: items.filter { $0.status == .unfinished }.count,
            continued: items.filter { $0.status == .continued }.count,
            abandoned: items.filter { $0.status == .abandoned }.count
        )
    }

    public func traceProgress(for traceID: DayTraceID) -> TraceProgress {
        guard let trace = traces[traceID] else {
            return TraceProgress(mode: .manual, percent: 0, floorPercent: 0, completedWeight: 0, totalWeight: 0)
        }

        let chainTraces = traces.values
            .filter {
                $0.chainID == trace.chainID && $0.formsDayHistory
            }
            .sorted(by: traceChronology)
        let raw = rawProgress(for: trace, chainTraces: chainTraces)
        let floor = progressFloor(for: trace, chainTraces: chainTraces)
        return TraceProgress(
            mode: raw.mode,
            percent: max(raw.percent, floor),
            floorPercent: floor,
            completedWeight: raw.completedWeight,
            totalWeight: raw.totalWeight
        )
    }

    public func calendarSummary(for date: LocalDate) -> CalendarDaySummary {
        let items = traces.values.filter {
            $0.date == date && $0.formsDayHistory
        }
        let completed = items.filter { $0.status == .completed }.count
        return CalendarDaySummary(
            date: date,
            total: items.count,
            completed: completed,
            pending: items.filter { $0.status == .pending }.count,
            unfinished: items.filter { $0.status == .unfinished }.count,
            heatLevel: min(completed, 4)
        )
    }

    public func updatePriority(
        traceID: DayTraceID,
        newPriority: Int,
        today: LocalDate,
        now: Date = Date()
    ) throws {
        let trace = try trace(traceID)
        try ensureUnlockedDay(trace.date)
        guard trace.date >= today else {
            throw NoonmarkError.immutableHistory
        }
        guard trace.status == .pending else {
            throw NoonmarkError.invalidTransition(
                "only pending day traces can change priority"
            )
        }
        let pendingSlots = pendingPrioritySlots(on: trace.date)
        guard let currentIndex = pendingSlots.firstIndex(where: { $0.id == traceID }) else {
            throw NoonmarkError.notFound("day trace priority")
        }
        let targetIndices = pendingSlots.indices.filter {
            pendingSlots[$0].priority == newPriority
        }
        guard targetIndices.count == 1, let targetIndex = targetIndices.first else {
            throw NoonmarkError.invalidInput(
                "priority must reference an existing pending day-trace slot"
            )
        }
        guard currentIndex != targetIndex else { return }

        let targetTraceID: DayTraceID?
        if targetIndex < currentIndex {
            targetTraceID = pendingSlots[targetIndex].id
        } else {
            let followingIndex = targetIndex + 1
            targetTraceID = pendingSlots.indices.contains(followingIndex)
                ? pendingSlots[followingIndex].id
                : nil
        }
        try reorderDayTrace(
            traceID,
            before: targetTraceID,
            today: today,
            now: now
        )
    }

    public func reorderDayTrace(
        _ traceID: DayTraceID,
        before targetTraceID: DayTraceID?,
        today: LocalDate,
        now: Date = Date()
    ) throws {
        let movingTrace = try trace(traceID)
        try ensureUnlockedDay(movingTrace.date)
        guard movingTrace.date >= today else {
            throw NoonmarkError.immutableHistory
        }
        guard movingTrace.status == .pending else {
            throw NoonmarkError.invalidTransition(
                "only pending day traces can change priority"
            )
        }
        try validatePriorityTarget(
            targetTraceID,
            movingTrace: movingTrace
        )
        guard targetTraceID != traceID else { return }

        let pendingSlots = pendingPrioritySlots(on: movingTrace.date)
        let prioritySlots = pendingSlots.map(\.priority)
        var orderedIDs = pendingSlots.map(\.id)
        guard let movingIndex = orderedIDs.firstIndex(of: traceID) else {
            throw NoonmarkError.notFound("day trace priority")
        }
        orderedIDs.remove(at: movingIndex)
        if let targetTraceID, let targetIndex = orderedIDs.firstIndex(of: targetTraceID) {
            orderedIDs.insert(traceID, at: targetIndex)
        } else {
            orderedIDs.append(traceID)
        }

        var reordered: [DayTrace] = []
        reordered.reserveCapacity(orderedIDs.count)
        for (id, priority) in zip(orderedIDs, prioritySlots) {
            var candidate = try trace(id)
            if candidate.priority != priority {
                try candidate.markContentModified(at: now)
                candidate.priority = priority
            }
            reordered.append(candidate)
        }
        for candidate in reordered {
            traces[candidate.id] = candidate
        }
    }

    public func settleDays(upTo today: LocalDate, now: Date = Date()) throws {
        let dates = Set(
            traces.values
                .filter(\.formsDayHistory)
                .map(\.date)
        ).filter { $0 < today }
        for date in dates where days[date]?.lockedAt == nil {
            if let day = days[date] {
                guard now.timeIntervalSinceReferenceDate.isFinite,
                      now >= day.updatedAt
                else {
                    throw NoonmarkError.invalidInput(
                        "day settlement time cannot move backwards"
                    )
                }
            }
            for trace in traces.values where trace.date == date && trace.status == .pending {
                var candidate = trace
                try candidate.markContentModified(at: now)
            }
        }

        for date in dates {
            ensureDay(date, now: now)

            guard days[date]?.lockedAt == nil else {
                continue
            }

            var traceIDsNeedingClassificationSnapshot: Set<DayTraceID> = []
            for trace in traces.values where trace.date == date && trace.status == .pending {
                var settled = trace
                try settled.markContentModified(at: now)
                settled.status = .unfinished
                settled.settledAt = now
                traces[settled.id] = settled
                traceIDsNeedingClassificationSnapshot.insert(settled.id)
                try settleOpenSubtasks(on: settled.id, now: now)
            }

            for trace in traces.values where trace.date == date && trace.status == .completed {
                traceIDsNeedingClassificationSnapshot.insert(trace.id)
            }

            for traceID in traceIDsNeedingClassificationSnapshot {
                guard let trace = traces[traceID] else { continue }
                captureClassificationSnapshot(traceID: trace.id, chainID: trace.chainID, now: now)
            }

            days[date]?.lockedAt = now
            days[date]?.updatedAt = now
        }
    }

    public func dailyReviewStats(date: LocalDate) -> DailyReviewStats {
        let items = traces.values.filter {
            $0.date == date && $0.formsDayHistory
        }
        return DailyReviewStats(
            total: items.count,
            completed: items.filter { $0.status == .completed }.count,
            unfinished: items.filter { $0.status == .unfinished }.count,
            continued: items.filter { $0.status == .continued }.count,
            changed: items.filter { $0.status == .changed }.count,
            returnedToPool: items.filter { $0.status == .returnedToPool }.count,
            abandoned: items.filter { $0.status == .abandoned }.count
        )
    }

    public func updateDailyReview(
        date: LocalDate,
        summary: String?,
        unfinishedReason: String?,
        tomorrowNote: String?,
        now: Date = Date()
    ) {
        ensureDay(date, now: now)
        days[date]?.reviewSummary = summary
        days[date]?.reviewUnfinishedReason = unfinishedReason
        days[date]?.reviewTomorrowNote = tomorrowNote
        days[date]?.updatedAt = now
    }

    public func updateTheme(
        _ theme: AppTheme,
        writerID: String = AppPreferences.defaultLocalThemeLanguageWriterID,
        now: Date
    ) throws {
        guard preferences.theme != theme else { return }
        try advanceThemeLanguageClock(to: now, writerID: writerID)
        preferences.theme = theme
    }

    public func updateLanguage(
        _ language: AppLanguage,
        writerID: String = AppPreferences.defaultLocalThemeLanguageWriterID,
        now: Date
    ) throws {
        guard preferences.language != language else { return }
        try advanceThemeLanguageClock(to: now, writerID: writerID)
        preferences.language = language
    }

    public func updateDataMode(_ dataMode: AppDataMode) {
        preferences.dataMode = dataMode
        if dataMode == .localFirst {
            preferences.backupPolicy = ScheduledBackupPolicy()
        }
    }

    public func updateBackupPolicy(_ backupPolicy: ScheduledBackupPolicy) {
        preferences.backupPolicy = backupPolicy
    }

    public func updateLocalFirstSyncPolicy(_ policy: LocalFirstCloudSyncPolicy) {
        preferences.localFirstSyncPolicy = policy
    }

    public func updateSettingsPoemDisplayPolicy(_ policy: SettingsPoemDisplayPolicy) {
        preferences.settingsPoemDisplayPolicy = policy
    }

    public func syncEndpointOptions() -> [SyncEndpointOption] {
        preferences.syncEndpointOptions
    }

    private func advanceThemeLanguageClock(
        to now: Date,
        writerID: String
    ) throws {
        let currentSeconds = preferences.themeLanguageUpdatedAt
            .timeIntervalSinceReferenceDate
        let nextSeconds = now.timeIntervalSinceReferenceDate
        let trimmedWriterID = writerID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard currentSeconds.isFinite,
              nextSeconds.isFinite,
              now > preferences.themeLanguageUpdatedAt,
              trimmedWriterID.isEmpty == false
        else {
            throw NoonmarkError.invalidInput(
                "theme and language mutation time must advance"
            )
        }
        preferences = try preferences.applyingSyncedThemeLanguage(
            theme: preferences.theme,
            language: preferences.language,
            updatedAt: now,
            writerID: writerID
        )
    }
}

private struct SnapshotUndoCurrentFacts {
    let days: [LocalDate: Day]
    let chains: [TaskChainID: TaskChain]
    let definitions: [TaskDefinitionID: TaskDefinition]
    let traces: [DayTraceID: DayTrace]
    let subtasks: [SubtaskID: Subtask]

    init(_ snapshot: NoonmarkSnapshot) {
        days = Dictionary(
            uniqueKeysWithValues: snapshot.days.map { ($0.date, $0) }
        )
        chains = Dictionary(
            uniqueKeysWithValues: snapshot.chains.map { ($0.id, $0) }
        )
        definitions = Dictionary(
            uniqueKeysWithValues: snapshot.definitions.map { ($0.id, $0) }
        )
        traces = Dictionary(
            uniqueKeysWithValues: snapshot.traces.map { ($0.id, $0) }
        )
        subtasks = Dictionary(
            uniqueKeysWithValues: snapshot.subtasks.map { ($0.id, $0) }
        )
    }
}

private extension NoonmarkEngine {
    func snapshotUndoOutcome(
        from current: SnapshotUndoCurrentFacts
    ) -> SnapshotUndoOutcome {
        let cancelled: [TaskChainID] = current.chains.compactMap { entry -> TaskChainID? in
            let (chainID, chain) = entry
            guard chain.state == .active,
                  chains[chainID]?.state != .active
            else { return nil }
            return chainID
        }
        .sorted { $0.description < $1.description }
        let restored: [TaskChainID] = chains.compactMap { entry -> TaskChainID? in
            let (chainID, chain) = entry
            guard chain.state == .active,
                  current.chains[chainID]?.state == .abandoned
            else { return nil }
            return chainID
        }
        .sorted { $0.description < $1.description }
        return SnapshotUndoOutcome(
            automaticClassificationCancelledChainIDs: cancelled,
            automaticClassificationRestoredChainIDs: restored
        )
    }

    func retainCurrentOnlySnapshotUndoFacts(
        from current: SnapshotUndoCurrentFacts,
        now: Date
    ) {
        let targetChainIDs = Set(chains.keys)
        let targetCurrentDefinitions = snapshotUndoCurrentDefinitionsByChain()
        let currentOnlyTraceIDs = Set(current.traces.keys).subtracting(
            traces.keys
        )

        retainCurrentOnlyDays(from: current.days)
        retainCurrentOnlyChains(from: current.chains)
        retainCurrentOnlyDefinitions(
            from: current.definitions,
            targetChainIDs: targetChainIDs,
            targetCurrentDefinitions: targetCurrentDefinitions,
            now: now
        )
        retainCurrentOnlyTraces(
            from: current.traces,
            ids: currentOnlyTraceIDs,
            now: now
        )
        retainCurrentOnlySubtasks(
            from: current.subtasks,
            currentOnlyTraceIDs: currentOnlyTraceIDs,
            now: now
        )
    }

    func retainCurrentOnlyDays(from currentDays: [LocalDate: Day]) {
        for (date, day) in currentDays where days[date] == nil {
            days[date] = day
        }
    }

    func retainCurrentOnlyChains(
        from currentChains: [TaskChainID: TaskChain]
    ) {
        for (id, current) in currentChains where chains[id] == nil {
            var hidden = current
            hidden.state = .abandoned
            chains[id] = hidden
        }
    }

    func retainCurrentOnlyDefinitions(
        from currentDefinitions: [TaskDefinitionID: TaskDefinition],
        targetChainIDs: Set<TaskChainID>,
        targetCurrentDefinitions: [TaskChainID: TaskDefinition],
        now: Date
    ) {
        for (id, current) in currentDefinitions where definitions[id] == nil {
            var hidden = current
            if targetChainIDs.contains(current.chainID), let restored = targetCurrentDefinitions[current.chainID] {
                hidden.supersededAt = now
                hidden.supersededByDefinitionID = restored.id
            }
            definitions[id] = hidden
        }
    }

    func retainCurrentOnlyTraces(
        from currentTraces: [DayTraceID: DayTrace],
        ids currentOnlyTraceIDs: Set<DayTraceID>,
        now: Date
    ) {
        for id in currentOnlyTraceIDs {
            guard var hidden = currentTraces[id] else { continue }
            hidden.status = .cancelledDraft
            hidden.completedAt = nil
            hidden.settledAt = now
            hidden.draftCancellationID = hidden.draftCancellationID ?? UUID()
            hidden.draftCancelledOn = hidden.date
            traces[id] = hidden
        }
    }

    func retainCurrentOnlySubtasks(
        from currentSubtasks: [SubtaskID: Subtask],
        currentOnlyTraceIDs: Set<DayTraceID>,
        now: Date
    ) {
        for (id, current) in currentSubtasks where subtasks[id] == nil {
            var hidden = current
            if currentOnlyTraceIDs.contains(current.traceID) == false {
                hidden.status = .cancelledDraft
                hidden.completedAt = nil
                hidden.settledAt = now
                hidden.draftCancellationID =
                    hidden.draftCancellationID ?? UUID()
            }
            subtasks[id] = hidden
        }
    }

    func snapshotUndoCurrentDefinitionsByChain() -> [TaskChainID: TaskDefinition] {
        definitions.values.reduce(
            into: [TaskChainID: TaskDefinition]()
        ) { result, definition in
            guard definition.supersededAt == nil else { return }
            if let existing = result[definition.chainID], existing.sequence >= definition.sequence {
                return
            }
            result[definition.chainID] = definition
        }
    }

    func restoreSnapshotUndoChains(
        from current: SnapshotUndoCurrentFacts,
        now: Date
    ) throws {
        for (id, storedChain) in chains {
            var candidate = storedChain
            guard let currentChain = current.chains[id] else {
                candidate.updatedAt = max(candidate.updatedAt, now)
                chains[id] = candidate
                continue
            }
            // Task-note versions are append-only sync facts. A snapshot undo
            // restores other chain fields while carrying the current note log
            // forward instead of rolling it back.
            candidate.noteEntries = currentChain.noteEntries
            candidate.updatedAt = if candidate.state == currentChain.state {
                currentChain.updatedAt
            } else {
                try forwardMutationDate(
                    after: currentChain.updatedAt,
                    now: now
                )
            }
            chains[id] = candidate
        }
    }

    func restoreSnapshotUndoDefinitions(
        from current: SnapshotUndoCurrentFacts,
        now: Date
    ) throws {
        for (id, storedDefinition) in definitions {
            var candidate = storedDefinition
            guard let currentDefinition = current.definitions[id] else {
                try candidate.markContentModified(at: now)
                definitions[id] = candidate
                continue
            }
            let restoresSupersededDefinition =
                currentDefinition.supersededAt != nil
                    && candidate.supersededAt == nil
            if restoresSupersededDefinition, let transitionWitnessID = currentDefinition.supersededByDefinitionID {
                candidate.supersededByDefinitionID = transitionWitnessID
            }
            let clock = taskDefinitionContentMatches(
                candidate,
                currentDefinition
            )
                ? currentDefinition.contentUpdatedAt
                : try forwardMutationDate(
                    after: currentDefinition.contentUpdatedAt,
                    now: now
                )
            try candidate.markContentModified(at: clock)
            definitions[id] = candidate
        }
    }

    func restoreSnapshotUndoTraces(
        from current: SnapshotUndoCurrentFacts,
        now: Date
    ) throws {
        for (id, storedTrace) in traces {
            var candidate = storedTrace
            guard let currentTrace = current.traces[id] else {
                try candidate.markContentModified(at: now)
                traces[id] = candidate
                continue
            }
            // Undo composes with later note commands by preserving their
            // current version/tombstone history.
            candidate.noteEntries = currentTrace.noteEntries
            let restoresCancelledDraft =
                currentTrace.status == .cancelledDraft
                    && candidate.status == .pending
            if restoresCancelledDraft, let cancellationID = currentTrace.draftCancellationID {
                candidate.draftCancellationID = cancellationID
                candidate.draftCancelledOn = nil
            }
            let clock = dayTraceContentMatches(candidate, currentTrace)
                ? currentTrace.contentUpdatedAt
                : try forwardMutationDate(
                    after: currentTrace.contentUpdatedAt,
                    now: now
                )
            try candidate.markContentModified(at: clock)
            traces[id] = candidate
        }
    }

    func restoreSnapshotUndoSubtasks(
        from current: SnapshotUndoCurrentFacts,
        now: Date
    ) throws {
        for (id, storedSubtask) in subtasks {
            var candidate = storedSubtask
            guard let currentSubtask = current.subtasks[id] else {
                let clock = try forwardMutationDate(
                    after: candidate.updatedAt,
                    now: now
                )
                try candidate.markContentModified(at: clock)
                subtasks[id] = candidate
                continue
            }
            let restoresCancelledDraft =
                currentSubtask.status == .cancelledDraft
                    && candidate.status == .pending
            if restoresCancelledDraft, let cancellationID = currentSubtask.draftCancellationID {
                candidate.draftCancellationID = cancellationID
                candidate.settledAt = nil
            }
            let clock = subtaskContentMatches(candidate, currentSubtask)
                ? currentSubtask.updatedAt
                : try forwardMutationDate(
                    after: currentSubtask.updatedAt,
                    now: now
                )
            try candidate.markContentModified(at: clock)
            subtasks[id] = candidate
        }
    }

    func forwardMutationDate(after frontier: Date, now: Date) throws -> Date {
        let frontierSeconds = frontier.timeIntervalSinceReferenceDate
        let nowSeconds = now.timeIntervalSinceReferenceDate
        guard frontierSeconds.isFinite, nowSeconds.isFinite,
              frontierSeconds.nextUp.isFinite
        else {
            throw NoonmarkError.invalidInput("undo mutation time is invalid")
        }
        return Date(
            timeIntervalSinceReferenceDate: max(frontierSeconds.nextUp, nowSeconds)
        )
    }

    func taskDefinitionContentMatches(
        _ lhs: TaskDefinition,
        _ rhs: TaskDefinition
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.chainID == rhs.chainID
            && lhs.sequence == rhs.sequence
            && lhs.title == rhs.title
            && lhs.descriptionText == rhs.descriptionText
            && lhs.plannedSubtasks == rhs.plannedSubtasks
            && lhs.createdAt == rhs.createdAt
            && lhs.supersededAt == rhs.supersededAt
            && lhs.supersededByDefinitionID == rhs.supersededByDefinitionID
    }

    func subtaskContentMatches(
        _ lhs: Subtask,
        _ rhs: Subtask
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.lineageID == rhs.lineageID
            && lhs.traceID == rhs.traceID
            && lhs.title == rhs.title
            && lhs.status == rhs.status
            && lhs.difficulty == rhs.difficulty
            && lhs.position == rhs.position
            && lhs.continuedFromSubtaskID == rhs.continuedFromSubtaskID
            && lhs.createdAt == rhs.createdAt
            && lhs.completedAt == rhs.completedAt
            && lhs.settledAt == rhs.settledAt
            && lhs.draftCancellationID == rhs.draftCancellationID
    }

    func dayTraceContentMatches(_ lhs: DayTrace, _ rhs: DayTrace) -> Bool {
        lhs.id == rhs.id
            && lhs.chainID == rhs.chainID
            && lhs.definitionID == rhs.definitionID
            && lhs.date == rhs.date
            && lhs.status == rhs.status
            && lhs.priority == rhs.priority
            && lhs.continuationSeq == rhs.continuationSeq
            && lhs.descriptionText == rhs.descriptionText
            && lhs.manualProgressPercent == rhs.manualProgressPercent
            && lhs.continuedFromTraceID == rhs.continuedFromTraceID
            && lhs.changedToTraceID == rhs.changedToTraceID
            && lhs.createdAt == rhs.createdAt
            && lhs.completedAt == rhs.completedAt
            && lhs.settledAt == rhs.settledAt
            && lhs.draftCancellationID == rhs.draftCancellationID
            && lhs.draftCancelledOn == rhs.draftCancelledOn
    }

    func normalizeTitle(_ title: String) throws -> String {
        let normalized = title
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else {
            throw NoonmarkError.invalidTitle
        }
        return normalized
    }

    func normalizedOptionalText(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == true ? nil : trimmed
    }

    func pendingPrioritySlots(on date: LocalDate) -> [DayTrace] {
        getDayTodo(date: date).traces.filter { $0.status == .pending }
    }

    func validatePriorityTarget(
        _ targetTraceID: DayTraceID?,
        movingTrace: DayTrace
    ) throws {
        guard let targetTraceID else { return }
        let targetTrace = try trace(targetTraceID)
        guard targetTrace.date == movingTrace.date else {
            throw NoonmarkError.invalidInput(
                "day traces can only be reordered within the same date"
            )
        }
        guard targetTrace.status == .pending else {
            throw NoonmarkError.invalidTransition(
                "priority targets must be pending day traces"
            )
        }
    }

    func sorted(_ traces: [DayTrace], by sort: ViewSort) -> [DayTrace] {
        switch sort {
        case .priority:
            return traces.sorted(by: tracePriorityOrder)
        case .createdAt:
            return traces.sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                return $0.id.description < $1.id.description
            }
        case .title:
            return traces.sorted {
                let lhs = definitions[$0.definitionID]?.title ?? ""
                let rhs = definitions[$1.definitionID]?.title ?? ""
                let comparison = lhs.localizedStandardCompare(rhs)
                if comparison != .orderedSame {
                    return comparison == .orderedAscending
                }
                return $0.id.description < $1.id.description
            }
        }
    }

    func tracePriorityOrder(_ lhs: DayTrace, _ rhs: DayTrace) -> Bool {
        if lhs.priority != rhs.priority {
            return lhs.priority < rhs.priority
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.description < rhs.id.description
    }

    func nextPriority(on date: LocalDate) -> Int {
        (
            traces.values
                .filter { $0.date == date && $0.formsDayHistory }
                .map(\.priority)
                .max() ?? 0
        ) + 1
    }

    func ensureDay(_ date: LocalDate, now: Date) {
        if days[date] == nil {
            days[date] = Day(date: date, now: now)
        }
    }

    func ensureUnlockedDay(_ date: LocalDate) throws {
        guard days[date]?.lockedAt == nil else {
            throw NoonmarkError.immutableHistory
        }
    }

    func completionCapability(
        for trace: DayTrace,
        today: LocalDate
    ) -> DayTraceCompletionCapability {
        if days[trace.date]?.lockedAt != nil {
            return .unavailable(.lockedDay)
        }
        if trace.date < today {
            return .unavailable(.historicalDay)
        }
        if trace.date > today {
            return .unavailable(.futureDay)
        }
        switch trace.status {
        case .pending:
            return subtaskProgress(for: trace.id).canCompleteParent
                ? .available(.complete)
                : .unavailable(.openSubtasks)
        case .completed:
            return .available(.undo)
        case .unfinished, .continued, .changed, .returnedToPool, .cancelledDraft, .abandoned:
            return .unavailable(.unsupportedStatus(trace.status))
        }
    }

    func tracePermittedForCompletionAction(
        _ requestedAction: DayTraceCompletionAction,
        traceID: DayTraceID,
        today: LocalDate
    ) throws -> DayTrace {
        let trace = try trace(traceID)
        let capability = completionCapability(for: trace, today: today)
        guard capability == .available(requestedAction) else {
            throw completionError(
                for: requestedAction,
                capability: capability
            )
        }
        return trace
    }

    func completionError(
        for requestedAction: DayTraceCompletionAction,
        capability: DayTraceCompletionCapability
    ) -> NoonmarkError {
        switch requestedAction {
        case .complete:
            switch capability {
            case .unavailable(.lockedDay), .unavailable(.historicalDay):
                return .immutableHistory
            case .unavailable(.futureDay):
                return .futurePlanCannotComplete
            case .unavailable(.openSubtasks):
                return .openSubtasksPreventCompletion
            case .available, .unavailable(.unsupportedStatus):
                return .invalidTransition("only pending traces can be completed")
            }
        case .undo:
            switch capability {
            case .unavailable(.lockedDay):
                return .immutableHistory
            case .unavailable(.historicalDay), .unavailable(.futureDay):
                return .historicalCompletionCannotBeUndone
            case .available, .unavailable(.unsupportedStatus), .unavailable(.openSubtasks):
                return .invalidTransition("only completed traces can be undone")
            }
        }
    }

    func trace(_ id: DayTraceID) throws -> DayTrace {
        guard let trace = traces[id] else {
            throw NoonmarkError.notFound("day trace")
        }
        return trace
    }

    func chain(_ id: TaskChainID) throws -> TaskChain {
        guard let chain = chains[id] else {
            throw NoonmarkError.notFound("task chain")
        }
        return chain
    }

    func definition(_ id: TaskDefinitionID) throws -> TaskDefinition {
        guard let definition = definitions[id] else {
            throw NoonmarkError.notFound("task definition")
        }
        return definition
    }

    func currentDefinition(for chainID: TaskChainID) throws -> TaskDefinition {
        let candidates = definitions.values.filter { $0.chainID == chainID && $0.supersededAt == nil }
        guard let definition = candidates.max(by: { $0.sequence < $1.sequence }) else {
            throw NoonmarkError.notFound("current task definition")
        }
        return definition
    }

    func ensureActiveChain(_ id: TaskChainID) throws {
        let chain = try chain(id)
        guard chain.state == .active else {
            throw NoonmarkError.chainAbandoned
        }
    }

    func touchChain(_ id: TaskChainID, now: Date) throws {
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw NoonmarkError.invalidInput("task chain mutation time is invalid")
        }
        if let updatedAt = chains[id]?.updatedAt {
            chains[id]?.updatedAt = max(updatedAt, now)
        }
    }

    func activeTrace(for chainID: TaskChainID) -> DayTrace? {
        traces.values
            .filter { $0.chainID == chainID && $0.status == .pending }
            .sorted { $0.createdAt > $1.createdAt }
            .first
    }

    func isInTaskPool(_ chainID: TaskChainID) -> Bool {
        guard chains[chainID]?.state == .active else {
            return false
        }

        let chainTraces = traces.values.filter { $0.chainID == chainID }
        return chainTraces.isEmpty || chainTraces.allSatisfy {
            $0.status == .returnedToPool || $0.status == .cancelledDraft
        }
    }

    func hasCompletedTrace(_ chainID: TaskChainID) -> Bool {
        traces.values.contains { $0.chainID == chainID && $0.status == .completed }
    }

    func hasSubtasks(in chainID: TaskChainID) -> Bool {
        let traceIDs = Set(
            traces.values
                .filter {
                    $0.chainID == chainID && $0.formsDayHistory
                }
                .map(\.id)
        )
        return subtasks.values.contains {
            traceIDs.contains($0.traceID) && $0.isUserPresentable
        }
    }

    func rawProgress(for trace: DayTrace, chainTraces: [DayTrace]) -> TraceProgress {
        if trace.status == .completed {
            return TraceProgress(mode: .manual, percent: 100, floorPercent: 0, completedWeight: 1, totalWeight: 1)
        }

        let traceByID = Dictionary(uniqueKeysWithValues: chainTraces.map { ($0.id, $0) })
        let lineageRecords = Dictionary(grouping: subtasks.values.compactMap { subtask -> (SubtaskLineageID, Subtask, DayTrace)? in
            guard subtask.isUserPresentable,
                  let subtaskTrace = traceByID[subtask.traceID],
                  subtaskTrace.date <= trace.date
            else {
                return nil
            }
            return (subtask.lineageID, subtask, subtaskTrace)
        }) { $0.0 }

        if lineageRecords.isEmpty == false {
            var totalWeight = 0
            var completedWeight = 0

            for (_, records) in lineageRecords {
                let sortedRecords = records.sorted {
                    if $0.2.date != $1.2.date {
                        return $0.2.date < $1.2.date
                    }
                    return $0.1.createdAt < $1.1.createdAt
                }
                let weight = sortedRecords.map { $0.1.difficulty.rawValue }.max() ?? SubtaskDifficulty.simple.rawValue
                totalWeight += weight

                if sortedRecords.contains(where: { $0.1.status == .completed && $0.2.date <= trace.date }) {
                    completedWeight += weight
                }
            }

            let percent = totalWeight == 0 ? 0 : Int((Double(completedWeight) / Double(totalWeight) * 100).rounded())
            return TraceProgress(
                mode: .weightedSubtasks,
                percent: percent,
                floorPercent: 0,
                completedWeight: completedWeight,
                totalWeight: totalWeight
            )
        }

        return TraceProgress(
            mode: .manual,
            percent: trace.manualProgressPercent ?? 0,
            floorPercent: 0,
            completedWeight: trace.manualProgressPercent ?? 0,
            totalWeight: 100
        )
    }

    func progressFloor(for trace: DayTrace) -> Int {
        let chainTraces = traces.values
            .filter {
                $0.chainID == trace.chainID && $0.formsDayHistory
            }
            .sorted(by: traceChronology)
        return progressFloor(for: trace, chainTraces: chainTraces)
    }

    func progressFloor(for trace: DayTrace, chainTraces: [DayTrace]) -> Int {
        chainTraces
            .filter { $0.date < trace.date || ($0.date == trace.date && $0.continuationSeq < trace.continuationSeq) }
            .map { rawProgress(for: $0, chainTraces: chainTraces).percent }
            .max() ?? 0
    }

    func completedTrajectory(for completedTrace: DayTrace) -> CompletedTaskTrajectory {
        let chainTraces = traces.values
            .filter {
                $0.chainID == completedTrace.chainID && $0.formsDayHistory
            }
            .sorted(by: traceChronology)

        return CompletedTaskTrajectory(
            startDate: chainTraces.first?.date ?? completedTrace.date,
            continuedDates: uniqueDates(
                chainTraces
                    .filter { $0.continuationSeq > 0 }
                    .map(\.date)
            ),
            completedDate: completedTrace.date,
            traces: chainTraces,
            subtaskTrajectories: completedSubtaskTrajectories(for: chainTraces)
        )
    }

    func completedSubtaskTrajectories(for chainTraces: [DayTrace]) -> [SubtaskTrajectory] {
        let traceByID = Dictionary(uniqueKeysWithValues: chainTraces.map { ($0.id, $0) })
        let traceIDs = Set(traceByID.keys)
        let groupedSubtasks = Dictionary(grouping: subtasks.values.filter {
            traceIDs.contains($0.traceID) && $0.isUserPresentable
        }) {
            $0.lineageID
        }

        return groupedSubtasks.map { lineageID, items in
            let records = items
                .compactMap { subtask -> SubtaskTrajectoryRecord? in
                    guard let trace = traceByID[subtask.traceID] else { return nil }
                    return SubtaskTrajectoryRecord(subtask: subtask, date: trace.date)
                }
                .sorted(by: subtaskRecordChronology)

            return SubtaskTrajectory(
                lineageID: lineageID,
                title: records.first?.subtask.title ?? "",
                startDate: records.first?.date ?? LocalDate("0001-01-01"),
                continuedDates: uniqueDates(
                    records
                        .filter { $0.subtask.continuedFromSubtaskID != nil }
                        .map(\.date)
                ),
                completedDate: records.first(where: { $0.subtask.status == .completed })?.date,
                records: records
            )
        }
        .sorted {
            if $0.startDate != $1.startDate {
                return $0.startDate < $1.startDate
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    func traceChronology(_ lhs: DayTrace, _ rhs: DayTrace) -> Bool {
        if lhs.date != rhs.date {
            return lhs.date < rhs.date
        }
        if lhs.continuationSeq != rhs.continuationSeq {
            return lhs.continuationSeq < rhs.continuationSeq
        }
        if lhs.priority != rhs.priority {
            return lhs.priority < rhs.priority
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.description < rhs.id.description
    }

    func subtaskRecordChronology(_ lhs: SubtaskTrajectoryRecord, _ rhs: SubtaskTrajectoryRecord) -> Bool {
        if lhs.date != rhs.date {
            return lhs.date < rhs.date
        }
        if lhs.subtask.position != rhs.subtask.position {
            return lhs.subtask.position < rhs.subtask.position
        }
        return lhs.subtask.createdAt < rhs.subtask.createdAt
    }

    func uniqueDates(_ dates: [LocalDate]) -> [LocalDate] {
        var seen = Set<LocalDate>()
        var result: [LocalDate] = []

        for date in dates where seen.insert(date).inserted {
            result.append(date)
        }

        return result
    }

    func copyOpenSubtasks(
        from sourceTraceID: DayTraceID,
        to targetTraceID: DayTraceID,
        now: Date
    ) throws {
        let openSubtasks = subtasks.values
            .filter { $0.traceID == sourceTraceID && ($0.status == .pending || $0.status == .unfinished) }
            .sorted { $0.position < $1.position }

        for (index, oldSubtask) in openSubtasks.enumerated() {
            var continuedSubtask = oldSubtask
            try continuedSubtask.markContentModified(at: now)
            continuedSubtask.status = .continued
            continuedSubtask.settledAt = now
            subtasks[continuedSubtask.id] = continuedSubtask

            let newSubtask = Subtask(
                lineageID: oldSubtask.lineageID,
                traceID: targetTraceID,
                title: oldSubtask.title,
                difficulty: oldSubtask.difficulty,
                position: index + 1,
                continuedFromSubtaskID: oldSubtask.id,
                now: now
            )
            subtasks[newSubtask.id] = newSubtask
        }
    }

    func copyPlannedSubtasks(from definition: TaskDefinition, to traceID: DayTraceID, now: Date) {
        for (index, plannedSubtask) in definition.plannedSubtasks.sorted(by: { $0.position < $1.position }).enumerated() {
            let subtask = Subtask(
                lineageID: plannedSubtask.lineageID,
                traceID: traceID,
                title: plannedSubtask.title,
                difficulty: plannedSubtask.difficulty,
                position: index + 1,
                now: now
            )
            subtasks[subtask.id] = subtask
        }
    }

    func settleOpenSubtasks(on traceID: DayTraceID, now: Date) throws {
        for subtask in subtasks.values where subtask.traceID == traceID && subtask.status == .pending {
            var settled = subtask
            try settled.markContentModified(at: now)
            settled.status = .unfinished
            settled.settledAt = now
            subtasks[settled.id] = settled
        }
    }
}
