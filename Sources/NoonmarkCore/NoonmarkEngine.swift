import Foundation

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
    public func createPoolTask(
        title: String,
        descriptionText: String? = nil,
        note: String? = nil,
        notes: String? = nil,
        now: Date = Date()
    ) throws -> TaskChainID {
        let normalizedTitle = try normalizeTitle(title)
        let chain = TaskChain(now: now)
        let definition = TaskDefinition(
            chainID: chain.id,
            sequence: 1,
            title: normalizedTitle,
            descriptionText: descriptionText,
            note: note,
            notes: notes,
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
        note: String? = nil,
        notes: String? = nil,
        plannedSubtasks: [PlannedSubtask]? = nil
    ) throws {
        let normalizedTitle = try normalizeTitle(title)
        let definition = try currentDefinition(for: chainID)
        guard traces.values.contains(where: { $0.chainID == chainID }) == false else {
            throw NoonmarkError.invalidTransition("task definitions with traces cannot be overwritten")
        }

        definitions[definition.id]?.title = normalizedTitle
        definitions[definition.id]?.descriptionText = descriptionText ?? notes
        definitions[definition.id]?.note = note
        if let plannedSubtasks {
            definitions[definition.id]?.plannedSubtasks = plannedSubtasks.sorted { $0.position < $1.position }
        }
    }

    public func renameTaskTitle(
        chainID: TaskChainID,
        title: String,
        today: LocalDate,
        now: Date = Date()
    ) throws {
        let normalizedTitle = try normalizeTitle(title)
        var chain = try chain(chainID)
        guard chain.state == .active else {
            throw NoonmarkError.chainAbandoned
        }

        let chainTraces = traces.values.filter { $0.chainID == chainID }
        let editableStatuses: Set<TraceStatus> = [.pending, .returnedToPool]
        guard chainTraces.isEmpty || chainTraces.contains(where: { editableStatuses.contains($0.status) }) else {
            throw NoonmarkError.invalidTransition("completed and unfinished task facts cannot be renamed")
        }
        guard chainTraces.allSatisfy({ $0.status != .pending || $0.date >= today }) else {
            throw NoonmarkError.immutableHistory
        }

        var currentDefinition = try currentDefinition(for: chainID)
        guard currentDefinition.title != normalizedTitle else { return }

        if chainTraces.isEmpty {
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
                note: currentDefinition.note,
                plannedSubtasks: currentDefinition.plannedSubtasks,
                now: now
            )

            currentDefinition.supersededAt = now
            currentDefinition.supersededByDefinitionID = renamedDefinition.id
            definitions[currentDefinition.id] = currentDefinition
            definitions[renamedDefinition.id] = renamedDefinition

            for trace in chainTraces where trace.status == .pending {
                var renamedTrace = trace
                renamedTrace.definitionID = renamedDefinition.id
                traces[renamedTrace.id] = renamedTrace
            }
        }

        chain.updatedAt = now
        chains[chainID] = chain
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
        guard traces.values.contains(where: { $0.chainID == chainID }) == false else {
            throw NoonmarkError.invalidTransition("planned subtasks can only be edited before scheduling")
        }

        let plannedSubtask = PlannedSubtask(
            title: normalizedTitle,
            difficulty: difficulty,
            position: definition.plannedSubtasks.count + 1,
            now: now
        )
        definition.plannedSubtasks.append(plannedSubtask)
        definitions[definition.id] = definition
        touchChain(chainID, now: now)
        return plannedSubtask.id
    }

    public func removePlannedSubtask(
        chainID: TaskChainID,
        plannedSubtaskID: PlannedSubtaskID,
        now: Date = Date()
    ) throws {
        var definition = try currentDefinition(for: chainID)
        guard traces.values.contains(where: { $0.chainID == chainID }) == false else {
            throw NoonmarkError.invalidTransition("planned subtasks can only be edited before scheduling")
        }
        guard definition.plannedSubtasks.contains(where: { $0.id == plannedSubtaskID }) else {
            throw NoonmarkError.notFound("planned subtask")
        }

        definition.plannedSubtasks = definition.plannedSubtasks
            .filter { $0.id != plannedSubtaskID }
            .enumerated()
            .map { index, plannedSubtask in
                var plannedSubtask = plannedSubtask
                plannedSubtask.position = index + 1
                return plannedSubtask
            }
        definitions[definition.id] = definition
        touchChain(chainID, now: now)
    }

    public func updatePlannedSubtaskDifficulty(
        chainID: TaskChainID,
        plannedSubtaskID: PlannedSubtaskID,
        difficulty: SubtaskDifficulty,
        now: Date = Date()
    ) throws {
        var definition = try currentDefinition(for: chainID)
        guard traces.values.contains(where: { $0.chainID == chainID }) == false else {
            throw NoonmarkError.invalidTransition("planned subtasks can only be edited before scheduling")
        }
        guard let index = definition.plannedSubtasks.firstIndex(where: { $0.id == plannedSubtaskID }) else {
            throw NoonmarkError.notFound("planned subtask")
        }

        definition.plannedSubtasks[index].difficulty = difficulty
        definitions[definition.id] = definition
        touchChain(chainID, now: now)
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

        let definition = try currentDefinition(for: chainID)
        let trace = DayTrace(
            chainID: chainID,
            definitionID: definition.id,
            date: date,
            priority: nextPriority(on: date),
            descriptionText: definition.descriptionText,
            note: definition.note,
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

        if classificationState.referencesTaskChain(chainID) {
            try removeCurrentClassificationForRetiredTask(chainID: chainID, now: now)
            var chain = try chain(chainID)
            chain.state = .abandoned
            chain.updatedAt = now
            chains[chainID] = chain
            return .removedKeepingHistory
        }

        chains.removeValue(forKey: chainID)

        for definition in definitions.values where definition.chainID == chainID {
            definitions.removeValue(forKey: definition.id)
        }
        return .deleted
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
        guard chainTraces.allSatisfy({ $0.status == .returnedToPool }) else {
            throw NoonmarkError.invalidTransition("completed and unfinished task facts cannot be deleted")
        }

        guard chainTraces.isEmpty == false else {
            return try deleteUnscheduledTask(chainID: chainID, now: now)
        }

        var chain = try chain(chainID)
        chain.state = .abandoned
        chain.updatedAt = now
        chains[chainID] = chain
        return .removedKeepingHistory
    }

    private func removeCurrentClassificationForRetiredTask(
        chainID: TaskChainID,
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
            source: .deterministicDomainAction(
                reason: "task removed from task pool while preserving classification history"
            ),
            interactionID: interactionID,
            now: now
        )
        _ = try commitClassification(
            plan,
            confirmation: .user(confirming: plan, decisionID: interactionID),
            now: now
        )
    }

    public func getDayTodo(date: LocalDate, sort: ViewSort = .priority) -> DayTodoView {
        let items = traces.values.filter { $0.date == date }
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

    public func markCompleted(traceID: DayTraceID, today: LocalDate, now: Date = Date()) throws {
        var trace = try trace(traceID)
        guard trace.date == today else {
            if trace.date > today {
                throw NoonmarkError.futurePlanCannotComplete
            }
            throw NoonmarkError.immutableHistory
        }
        guard trace.status == .pending else {
            throw NoonmarkError.invalidTransition("only pending traces can be completed")
        }
        guard subtaskProgress(for: traceID).canCompleteParent else {
            throw NoonmarkError.openSubtasksPreventCompletion
        }

        trace.status = .completed
        trace.completedAt = now
        traces[trace.id] = trace
        touchChain(trace.chainID, now: now)
    }

    public func undoCompleted(traceID: DayTraceID, today: LocalDate, now: Date = Date()) throws {
        var trace = try trace(traceID)
        guard trace.date == today else {
            throw NoonmarkError.historicalCompletionCannotBeUndone
        }
        guard trace.status == .completed else {
            throw NoonmarkError.invalidTransition("only completed traces can be undone")
        }

        trace.status = .pending
        trace.completedAt = nil
        traces[trace.id] = trace
        touchChain(trace.chainID, now: now)
    }

    public func returnToPool(traceID: DayTraceID, today: LocalDate, now: Date = Date()) throws {
        var trace = try trace(traceID)

        if trace.date > today {
            guard trace.continuedFromTraceID == nil else {
                throw NoonmarkError.invalidTransition("continued future traces cannot return to pool without a trace")
            }
            for subtask in subtasks.values where subtask.traceID == traceID {
                subtasks.removeValue(forKey: subtask.id)
            }
            traces.removeValue(forKey: traceID)
            touchChain(trace.chainID, now: now)
            return
        }

        guard trace.date == today else {
            throw NoonmarkError.immutableHistory
        }
        guard trace.status == .pending else {
            throw NoonmarkError.invalidTransition("only pending current-day traces can return to pool")
        }

        trace.status = .returnedToPool
        trace.settledAt = now
        traces[trace.id] = trace
        captureClassificationSnapshot(traceID: trace.id, chainID: trace.chainID, now: now)
        touchChain(trace.chainID, now: now)
    }

    public func rescheduleFuturePlan(traceID: DayTraceID, targetDate: LocalDate, today: LocalDate, now: Date = Date()) throws {
        var trace = try trace(traceID)
        guard trace.date > today, targetDate > today else {
            throw NoonmarkError.invalidTransition("only future plans can be rescheduled to future dates")
        }
        guard trace.status == .pending else {
            throw NoonmarkError.invalidTransition("only pending future plans can be rescheduled")
        }

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
            note: source.note,
            manualProgressPercent: traceProgress(for: source.id).percent,
            continuedFromTraceID: source.id,
            now: now
        )

        let sourceWasUnfinished = source.status == .unfinished
        source.status = .continued
        source.settledAt = sourceWasUnfinished ? (source.settledAt ?? now) : nil
        traces[source.id] = source
        traces[nextTrace.id] = nextTrace
        captureClassificationSnapshot(traceID: source.id, chainID: source.chainID, now: now)

        copyOpenSubtasks(from: source.id, to: nextTrace.id, now: now)
        ensureDay(targetDate, now: now)
        touchChain(source.chainID, now: now)
        return nextTrace.id
    }

    @discardableResult
    public func changeTrace(
        traceID: DayTraceID,
        newTitle: String,
        newDescriptionText: String? = nil,
        newNote: String? = nil,
        newNotes: String? = nil,
        today: LocalDate,
        now: Date = Date()
    ) throws -> DayTraceID {
        let normalizedTitle = try normalizeTitle(newTitle)
        var oldTrace = try trace(traceID)
        try ensureActiveChain(oldTrace.chainID)
        guard oldTrace.date == today, oldTrace.status == .pending else {
            throw NoonmarkError.invalidTransition("only pending current-day traces can change definition")
        }

        let newChain = TaskChain(now: now)
        let newDefinition = TaskDefinition(
            chainID: newChain.id,
            sequence: 1,
            title: normalizedTitle,
            descriptionText: newDescriptionText,
            note: newNote,
            notes: newNotes,
            now: now
        )

        let newTrace = DayTrace(
            chainID: newChain.id,
            definitionID: newDefinition.id,
            date: today,
            priority: oldTrace.priority + 1,
            descriptionText: newDefinition.descriptionText,
            note: newDefinition.note,
            now: now
        )

        oldTrace.status = .changed
        oldTrace.changedToTraceID = newTrace.id
        oldTrace.settledAt = now

        chains[newChain.id] = newChain
        definitions[newDefinition.id] = newDefinition
        traces[oldTrace.id] = oldTrace
        traces[newTrace.id] = newTrace
        captureClassificationSnapshot(traceID: oldTrace.id, chainID: oldTrace.chainID, now: now)
        try inheritCurrentClassification(from: oldTrace.chainID, to: newChain.id, now: now)
        touchChain(oldTrace.chainID, now: now)
        return newTrace.id
    }

    public func abandonChain(from traceID: DayTraceID, now: Date = Date()) throws {
        var trace = try trace(traceID)
        var chain = try chain(trace.chainID)
        guard chain.state == .active else {
            throw NoonmarkError.chainAbandoned
        }
        guard trace.status == .pending || trace.status == .unfinished else {
            throw NoonmarkError.invalidTransition("only pending or unfinished traces can abandon their chain")
        }

        trace.status = .abandoned
        trace.settledAt = now
        chain.state = .abandoned
        chain.updatedAt = now

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

        if source.date >= today {
            source.status = .pending
            source.settledAt = nil
        } else {
            source.status = .unfinished
            source.settledAt = source.settledAt ?? now
        }
        chain.state = .active
        chain.updatedAt = now

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
        let newChainID = try createPoolTask(
            title: sourceDefinition.title,
            descriptionText: source.descriptionText ?? sourceDefinition.descriptionText,
            note: source.note ?? sourceDefinition.note,
            now: now
        )

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
        guard trace.date == today, trace.status == .pending else {
            throw NoonmarkError.immutableHistory
        }
        guard subtask.status == .pending else {
            throw NoonmarkError.invalidTransition("only pending subtasks can be completed")
        }
        subtask.status = .completed
        subtask.completedAt = now
        subtasks[subtask.id] = subtask
    }

    public func undoCompletedSubtask(_ subtaskID: SubtaskID, today: LocalDate) throws {
        guard var subtask = subtasks[subtaskID] else {
            throw NoonmarkError.notFound("subtask")
        }
        let trace = try trace(subtask.traceID)
        guard trace.date == today, trace.status == .pending else {
            throw NoonmarkError.immutableHistory
        }
        guard subtask.status == .completed else {
            throw NoonmarkError.invalidTransition("only completed subtasks can be undone")
        }

        subtask.status = .pending
        subtask.completedAt = nil
        subtasks[subtask.id] = subtask
    }

    public func abandonSubtask(_ subtaskID: SubtaskID, today: LocalDate, now: Date = Date()) throws {
        guard var subtask = subtasks[subtaskID] else {
            throw NoonmarkError.notFound("subtask")
        }
        let trace = try trace(subtask.traceID)
        guard trace.date == today, trace.status == .pending else {
            throw NoonmarkError.immutableHistory
        }
        guard subtask.status == .pending else {
            throw NoonmarkError.invalidTransition("only pending subtasks can be abandoned")
        }
        subtask.status = .abandoned
        subtask.settledAt = now
        subtasks[subtask.id] = subtask
    }

    public func updateSubtaskDifficulty(_ subtaskID: SubtaskID, difficulty: SubtaskDifficulty, today: LocalDate) throws {
        guard var subtask = subtasks[subtaskID] else {
            throw NoonmarkError.notFound("subtask")
        }
        let trace = try trace(subtask.traceID)
        guard trace.date == today, trace.status == .pending else {
            throw NoonmarkError.immutableHistory
        }

        subtask.difficulty = difficulty
        subtasks[subtask.id] = subtask
    }

    public func updateTraceText(
        traceID: DayTraceID,
        descriptionText: String?,
        note: String?,
        today: LocalDate
    ) throws {
        var trace = try trace(traceID)
        guard trace.status == .pending else {
            throw NoonmarkError.invalidTransition("only pending traces can update descriptive text")
        }
        guard trace.date >= today else {
            throw NoonmarkError.immutableHistory
        }

        trace.descriptionText = normalizedOptionalText(descriptionText)
        trace.note = normalizedOptionalText(note)
        traces[trace.id] = trace
    }

    public func setManualProgress(traceID: DayTraceID, percent: Int, today: LocalDate) throws {
        var trace = try trace(traceID)
        guard trace.date == today, trace.status == .pending else {
            throw NoonmarkError.immutableHistory
        }
        guard hasSubtasks(in: trace.chainID) == false else {
            throw NoonmarkError.invalidTransition("manual progress is unavailable when subtasks define weighted progress")
        }

        let clamped = min(100, max(0, percent))
        let floor = progressFloor(for: trace)
        trace.manualProgressPercent = max(floor, clamped)
        traces[trace.id] = trace
    }

    public func subtaskProgress(for traceID: DayTraceID) -> SubtaskProgress {
        let items = subtasks.values.filter { $0.traceID == traceID }
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
            .filter { $0.chainID == trace.chainID }
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
        let items = traces.values.filter { $0.date == date }
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

    public func updatePriority(traceID: DayTraceID, newPriority: Int, today: LocalDate) throws {
        var trace = try trace(traceID)
        guard trace.date >= today else {
            throw NoonmarkError.immutableHistory
        }
        trace.priority = newPriority
        traces[trace.id] = trace
    }

    public func settleDays(upTo today: LocalDate, now: Date = Date()) {
        let dates = Set(traces.values.map(\.date)).filter { $0 < today }
        for date in dates {
            ensureDay(date, now: now)

            guard days[date]?.lockedAt == nil else {
                continue
            }

            var traceIDsNeedingClassificationSnapshot: Set<DayTraceID> = []
            for trace in traces.values where trace.date == date && trace.status == .pending {
                var settled = trace
                settled.status = .unfinished
                settled.settledAt = now
                traces[settled.id] = settled
                traceIDsNeedingClassificationSnapshot.insert(settled.id)
                settleOpenSubtasks(on: settled.id, now: now)
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
        let items = traces.values.filter { $0.date == date }
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

    public func updateTheme(_ theme: AppTheme) {
        preferences.theme = theme
    }

    public func updateLanguage(_ language: AppLanguage) {
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
}

private extension NoonmarkEngine {
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

    func sorted(_ traces: [DayTrace], by sort: ViewSort) -> [DayTrace] {
        switch sort {
        case .priority:
            return traces.sorted { $0.priority < $1.priority }
        case .createdAt:
            return traces.sorted { $0.createdAt < $1.createdAt }
        case .title:
            return traces.sorted {
                let lhs = definitions[$0.definitionID]?.title ?? ""
                let rhs = definitions[$1.definitionID]?.title ?? ""
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
        }
    }

    func nextPriority(on date: LocalDate) -> Int {
        (traces.values.filter { $0.date == date }.map(\.priority).max() ?? 0) + 1
    }

    func ensureDay(_ date: LocalDate, now: Date) {
        if days[date] == nil {
            days[date] = Day(date: date, now: now)
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

    func touchChain(_ id: TaskChainID, now: Date) {
        chains[id]?.updatedAt = now
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
        return chainTraces.isEmpty || chainTraces.allSatisfy { $0.status == .returnedToPool }
    }

    func hasCompletedTrace(_ chainID: TaskChainID) -> Bool {
        traces.values.contains { $0.chainID == chainID && $0.status == .completed }
    }

    func hasSubtasks(in chainID: TaskChainID) -> Bool {
        let traceIDs = Set(traces.values.filter { $0.chainID == chainID }.map(\.id))
        return subtasks.values.contains { traceIDs.contains($0.traceID) }
    }

    func rawProgress(for trace: DayTrace, chainTraces: [DayTrace]) -> TraceProgress {
        if trace.status == .completed {
            return TraceProgress(mode: .manual, percent: 100, floorPercent: 0, completedWeight: 1, totalWeight: 1)
        }

        let traceByID = Dictionary(uniqueKeysWithValues: chainTraces.map { ($0.id, $0) })
        let lineageRecords = Dictionary(grouping: subtasks.values.compactMap { subtask -> (SubtaskLineageID, Subtask, DayTrace)? in
            guard let subtaskTrace = traceByID[subtask.traceID], subtaskTrace.date <= trace.date else {
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
            .filter { $0.chainID == trace.chainID }
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
            .filter { $0.chainID == completedTrace.chainID }
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
        let groupedSubtasks = Dictionary(grouping: subtasks.values.filter { traceIDs.contains($0.traceID) }) {
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
        return lhs.createdAt < rhs.createdAt
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

    func copyOpenSubtasks(from sourceTraceID: DayTraceID, to targetTraceID: DayTraceID, now: Date) {
        let openSubtasks = subtasks.values
            .filter { $0.traceID == sourceTraceID && ($0.status == .pending || $0.status == .unfinished) }
            .sorted { $0.position < $1.position }

        for (index, oldSubtask) in openSubtasks.enumerated() {
            var continuedSubtask = oldSubtask
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

    func settleOpenSubtasks(on traceID: DayTraceID, now: Date) {
        for subtask in subtasks.values where subtask.traceID == traceID && subtask.status == .pending {
            var settled = subtask
            settled.status = .unfinished
            settled.settledAt = now
            subtasks[settled.id] = settled
        }
    }
}
