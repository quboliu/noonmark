import Foundation

public final class SuntraceEngine {
    public private(set) var days: [LocalDate: Day]
    public private(set) var chains: [TaskChainID: TaskChain]
    public private(set) var definitions: [TaskDefinitionID: TaskDefinition]
    public private(set) var traces: [DayTraceID: DayTrace]
    public private(set) var subtasks: [SubtaskID: Subtask]

    public init() {
        self.days = [:]
        self.chains = [:]
        self.definitions = [:]
        self.traces = [:]
        self.subtasks = [:]
    }

    @discardableResult
    public func createPoolTask(title: String, notes: String? = nil, now: Date = Date()) throws -> TaskChainID {
        let normalizedTitle = try normalizeTitle(title)
        let chain = TaskChain(now: now)
        let definition = TaskDefinition(
            chainID: chain.id,
            sequence: 1,
            title: normalizedTitle,
            notes: notes,
            now: now
        )

        chains[chain.id] = chain
        definitions[definition.id] = definition
        return chain.id
    }

    public func updatePoolTask(chainID: TaskChainID, title: String, notes: String? = nil) throws {
        let normalizedTitle = try normalizeTitle(title)
        let definition = try currentDefinition(for: chainID)
        guard traces.values.contains(where: { $0.chainID == chainID }) == false else {
            throw SuntraceError.invalidTransition("task definitions with traces cannot be overwritten")
        }

        definitions[definition.id]?.title = normalizedTitle
        definitions[definition.id]?.notes = notes
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
            throw SuntraceError.invalidTransition("only task-pool tasks can be scheduled from pool")
        }

        let definition = try currentDefinition(for: chainID)
        let trace = DayTrace(
            chainID: chainID,
            definitionID: definition.id,
            date: date,
            priority: nextPriority(on: date),
            now: now
        )
        traces[trace.id] = trace
        ensureDay(date, now: now)
        return trace.id
    }

    public func deleteUnscheduledTask(chainID: TaskChainID) throws {
        guard traces.values.contains(where: { $0.chainID == chainID }) == false else {
            throw SuntraceError.invalidTransition("scheduled tasks cannot be deleted")
        }
        guard chains.removeValue(forKey: chainID) != nil else {
            throw SuntraceError.notFound("task chain")
        }

        for definition in definitions.values where definition.chainID == chainID {
            definitions.removeValue(forKey: definition.id)
        }
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
        let unresolvedHistoryByChain = Dictionary(grouping: traces.values.filter { $0.status == .unfinished || $0.status == .continued }) {
            $0.chainID
        }

        return unresolvedHistoryByChain.compactMap { chainID, unfinishedTraces in
            guard
                var chain = chains[chainID],
                chain.state == .active,
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
            let lhsDate = lhs.unfinishedTraces.last?.date ?? LocalDate("0001-01-01")
            let rhsDate = rhs.unfinishedTraces.last?.date ?? LocalDate("0001-01-01")
            return lhsDate > rhsDate
        }
    }

    public func completedPool() -> [CompletedPoolItem] {
        traces.values
            .filter { $0.status == .completed }
            .compactMap { trace in
                guard let definition = definitions[trace.definitionID] else { return nil }
                return CompletedPoolItem(trace: trace, definition: definition)
            }
            .sorted {
                if $0.trace.date == $1.trace.date {
                    return ($0.trace.completedAt ?? $0.trace.createdAt) > ($1.trace.completedAt ?? $1.trace.createdAt)
                }
                return $0.trace.date > $1.trace.date
            }
    }

    public func markCompleted(traceID: DayTraceID, today: LocalDate, now: Date = Date()) throws {
        var trace = try trace(traceID)
        guard trace.date == today else {
            if trace.date > today {
                throw SuntraceError.futurePlanCannotComplete
            }
            throw SuntraceError.immutableHistory
        }
        guard trace.status == .pending else {
            throw SuntraceError.invalidTransition("only pending traces can be completed")
        }

        trace.status = .completed
        trace.completedAt = now
        traces[trace.id] = trace
        touchChain(trace.chainID, now: now)
    }

    public func undoCompleted(traceID: DayTraceID, today: LocalDate, now: Date = Date()) throws {
        var trace = try trace(traceID)
        guard trace.date == today else {
            throw SuntraceError.historicalCompletionCannotBeUndone
        }
        guard trace.status == .completed else {
            throw SuntraceError.invalidTransition("only completed traces can be undone")
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
                throw SuntraceError.invalidTransition("continued future traces cannot return to pool without a trace")
            }
            traces.removeValue(forKey: traceID)
            return
        }

        guard trace.date == today else {
            throw SuntraceError.immutableHistory
        }
        guard trace.status == .pending else {
            throw SuntraceError.invalidTransition("only pending current-day traces can return to pool")
        }

        trace.status = .returnedToPool
        trace.settledAt = now
        traces[trace.id] = trace
        touchChain(trace.chainID, now: now)
    }

    public func rescheduleFuturePlan(traceID: DayTraceID, targetDate: LocalDate, today: LocalDate) throws {
        var trace = try trace(traceID)
        guard trace.date > today, targetDate > today else {
            throw SuntraceError.invalidTransition("only future plans can be rescheduled to future dates")
        }
        guard trace.status == .pending else {
            throw SuntraceError.invalidTransition("only pending future plans can be rescheduled")
        }

        trace.date = targetDate
        trace.priority = nextPriority(on: targetDate)
        traces[trace.id] = trace
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
            throw SuntraceError.invalidTransition("continuation target cannot be in the past")
        }
        guard source.status == .unfinished || (source.status == .pending && source.date == today) else {
            throw SuntraceError.invalidTransition("only historical unfinished or current pending traces can continue")
        }

        if let active = activeTrace(for: source.chainID), active.id != source.id {
            throw SuntraceError.activeTraceAlreadyExists
        }

        let definition = try currentDefinition(for: source.chainID)
        let nextTrace = DayTrace(
            chainID: source.chainID,
            definitionID: definition.id,
            date: targetDate,
            priority: nextPriority(on: targetDate),
            continuationSeq: source.continuationSeq + 1,
            continuedFromTraceID: source.id,
            now: now
        )

        source.status = .continued
        source.settledAt = now
        traces[source.id] = source
        traces[nextTrace.id] = nextTrace

        copyOpenSubtasks(from: source.id, to: nextTrace.id, now: now)
        ensureDay(targetDate, now: now)
        touchChain(source.chainID, now: now)
        return nextTrace.id
    }

    @discardableResult
    public func changeTrace(
        traceID: DayTraceID,
        newTitle: String,
        newNotes: String? = nil,
        today: LocalDate,
        now: Date = Date()
    ) throws -> DayTraceID {
        let normalizedTitle = try normalizeTitle(newTitle)
        var oldTrace = try trace(traceID)
        try ensureActiveChain(oldTrace.chainID)
        guard oldTrace.date == today, oldTrace.status == .pending else {
            throw SuntraceError.invalidTransition("only pending current-day traces can change definition")
        }

        var oldDefinition = try currentDefinition(for: oldTrace.chainID)
        let newDefinition = TaskDefinition(
            chainID: oldTrace.chainID,
            sequence: oldDefinition.sequence + 1,
            title: normalizedTitle,
            notes: newNotes,
            now: now
        )
        oldDefinition.supersededAt = now
        oldDefinition.supersededByDefinitionID = newDefinition.id

        let newTrace = DayTrace(
            chainID: oldTrace.chainID,
            definitionID: newDefinition.id,
            date: today,
            priority: oldTrace.priority + 1,
            continuationSeq: oldTrace.continuationSeq,
            now: now
        )

        oldTrace.status = .changed
        oldTrace.changedToTraceID = newTrace.id
        oldTrace.settledAt = now

        definitions[oldDefinition.id] = oldDefinition
        definitions[newDefinition.id] = newDefinition
        traces[oldTrace.id] = oldTrace
        traces[newTrace.id] = newTrace
        touchChain(oldTrace.chainID, now: now)
        return newTrace.id
    }

    public func abandonChain(from traceID: DayTraceID, now: Date = Date()) throws {
        var trace = try trace(traceID)
        var chain = try chain(trace.chainID)
        guard chain.state == .active else {
            throw SuntraceError.chainAbandoned
        }
        guard trace.status == .pending || trace.status == .unfinished else {
            throw SuntraceError.invalidTransition("only pending or unfinished traces can abandon their chain")
        }

        trace.status = .abandoned
        trace.settledAt = now
        chain.state = .abandoned
        chain.updatedAt = now

        traces[trace.id] = trace
        chains[chain.id] = chain
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
        let newChainID = try createPoolTask(title: sourceDefinition.title, notes: sourceDefinition.notes, now: now)

        if case let .date(date) = target {
            _ = try scheduleFromPool(chainID: newChainID, date: date, today: today, now: now)
        }

        return newChainID
    }

    @discardableResult
    public func addSubtask(traceID: DayTraceID, title: String, now: Date = Date()) throws -> SubtaskID {
        let normalizedTitle = try normalizeTitle(title)
        let trace = try trace(traceID)
        guard trace.status == .pending else {
            throw SuntraceError.invalidTransition("subtasks can only be added to pending traces")
        }

        let position = subtasks.values.filter { $0.traceID == traceID }.count + 1
        let subtask = Subtask(traceID: trace.id, title: normalizedTitle, position: position, now: now)
        subtasks[subtask.id] = subtask
        return subtask.id
    }

    public func completeSubtask(_ subtaskID: SubtaskID, now: Date = Date()) throws {
        guard var subtask = subtasks[subtaskID] else {
            throw SuntraceError.notFound("subtask")
        }
        subtask.isDone = true
        subtask.completedAt = now
        subtasks[subtask.id] = subtask
    }

    public func updatePriority(traceID: DayTraceID, newPriority: Int, today: LocalDate) throws {
        var trace = try trace(traceID)
        guard trace.date >= today else {
            throw SuntraceError.immutableHistory
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

            for trace in traces.values where trace.date == date && trace.status == .pending {
                var settled = trace
                settled.status = .unfinished
                settled.settledAt = now
                traces[settled.id] = settled
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
}

private extension SuntraceEngine {
    func normalizeTitle(_ title: String) throws -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw SuntraceError.invalidTitle
        }
        return trimmed
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
            throw SuntraceError.notFound("day trace")
        }
        return trace
    }

    func chain(_ id: TaskChainID) throws -> TaskChain {
        guard let chain = chains[id] else {
            throw SuntraceError.notFound("task chain")
        }
        return chain
    }

    func definition(_ id: TaskDefinitionID) throws -> TaskDefinition {
        guard let definition = definitions[id] else {
            throw SuntraceError.notFound("task definition")
        }
        return definition
    }

    func currentDefinition(for chainID: TaskChainID) throws -> TaskDefinition {
        let candidates = definitions.values.filter { $0.chainID == chainID && $0.supersededAt == nil }
        guard let definition = candidates.max(by: { $0.sequence < $1.sequence }) else {
            throw SuntraceError.notFound("current task definition")
        }
        return definition
    }

    func ensureActiveChain(_ id: TaskChainID) throws {
        let chain = try chain(id)
        guard chain.state == .active else {
            throw SuntraceError.chainAbandoned
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

    func copyOpenSubtasks(from sourceTraceID: DayTraceID, to targetTraceID: DayTraceID, now: Date) {
        let openSubtasks = subtasks.values
            .filter { $0.traceID == sourceTraceID && $0.isDone == false }
            .sorted { $0.position < $1.position }

        for (index, oldSubtask) in openSubtasks.enumerated() {
            let newSubtask = Subtask(
                traceID: targetTraceID,
                title: oldSubtask.title,
                position: index + 1,
                now: now
            )
            subtasks[newSubtask.id] = newSubtask
        }
    }
}
