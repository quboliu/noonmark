import Foundation

public final class SuntraceEngine {
    public private(set) var days: [LocalDate: Day]
    public private(set) var chains: [TaskChainID: TaskChain]
    public private(set) var definitions: [TaskDefinitionID: TaskDefinition]
    public private(set) var traces: [DayTraceID: DayTrace]
    public private(set) var subtasks: [SubtaskID: Subtask]
    public private(set) var preferences: AppPreferences

    public init() {
        self.days = [:]
        self.chains = [:]
        self.definitions = [:]
        self.traces = [:]
        self.subtasks = [:]
        self.preferences = AppPreferences()
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
        notes: String? = nil
    ) throws {
        let normalizedTitle = try normalizeTitle(title)
        let definition = try currentDefinition(for: chainID)
        guard traces.values.contains(where: { $0.chainID == chainID }) == false else {
            throw SuntraceError.invalidTransition("task definitions with traces cannot be overwritten")
        }

        definitions[definition.id]?.title = normalizedTitle
        definitions[definition.id]?.descriptionText = descriptionText ?? notes
        definitions[definition.id]?.note = note
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
            descriptionText: definition.descriptionText,
            note: definition.note,
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
                throw SuntraceError.futurePlanCannotComplete
            }
            throw SuntraceError.immutableHistory
        }
        guard trace.status == .pending else {
            throw SuntraceError.invalidTransition("only pending traces can be completed")
        }
        guard subtaskProgress(for: traceID).canCompleteParent else {
            throw SuntraceError.invalidTransition("parent trace cannot complete while subtasks are still open")
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
            descriptionText: source.descriptionText,
            note: source.note,
            manualProgressPercent: traceProgress(for: source.id).percent,
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
            throw SuntraceError.invalidTransition("only pending current-day traces can change definition")
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
        let newChainID = try createPoolTask(
            title: sourceDefinition.title,
            descriptionText: source.descriptionText ?? sourceDefinition.descriptionText,
            note: source.note ?? sourceDefinition.note,
            now: now
        )

        if case let .date(date) = target {
            _ = try scheduleFromPool(chainID: newChainID, date: date, today: today, now: now)
        }

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
            throw SuntraceError.invalidTransition("subtasks can only be added to pending traces")
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
            throw SuntraceError.notFound("subtask")
        }
        let trace = try trace(subtask.traceID)
        guard trace.date == today, trace.status == .pending else {
            throw SuntraceError.immutableHistory
        }
        guard subtask.status == .pending else {
            throw SuntraceError.invalidTransition("only pending subtasks can be completed")
        }
        subtask.status = .completed
        subtask.completedAt = now
        subtasks[subtask.id] = subtask
    }

    public func abandonSubtask(_ subtaskID: SubtaskID, today: LocalDate, now: Date = Date()) throws {
        guard var subtask = subtasks[subtaskID] else {
            throw SuntraceError.notFound("subtask")
        }
        let trace = try trace(subtask.traceID)
        guard trace.date == today, trace.status == .pending else {
            throw SuntraceError.immutableHistory
        }
        guard subtask.status == .pending else {
            throw SuntraceError.invalidTransition("only pending subtasks can be abandoned")
        }
        subtask.status = .abandoned
        subtask.settledAt = now
        subtasks[subtask.id] = subtask
    }

    public func updateSubtaskDifficulty(_ subtaskID: SubtaskID, difficulty: SubtaskDifficulty, today: LocalDate) throws {
        guard var subtask = subtasks[subtaskID] else {
            throw SuntraceError.notFound("subtask")
        }
        let trace = try trace(subtask.traceID)
        guard trace.date == today, trace.status == .pending else {
            throw SuntraceError.immutableHistory
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
            throw SuntraceError.invalidTransition("only pending traces can update descriptive text")
        }
        guard trace.date >= today else {
            throw SuntraceError.immutableHistory
        }

        trace.descriptionText = normalizedOptionalText(descriptionText)
        trace.note = normalizedOptionalText(note)
        traces[trace.id] = trace
    }

    public func setManualProgress(traceID: DayTraceID, percent: Int, today: LocalDate) throws {
        var trace = try trace(traceID)
        guard trace.date == today, trace.status == .pending else {
            throw SuntraceError.immutableHistory
        }
        guard hasSubtasks(in: trace.chainID) == false else {
            throw SuntraceError.invalidTransition("manual progress is unavailable when subtasks define weighted progress")
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
                settleOpenSubtasks(on: settled.id, now: now)
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

    public func syncEndpointOptions() -> [SyncEndpointOption] {
        preferences.syncEndpointOptions
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

    func settleOpenSubtasks(on traceID: DayTraceID, now: Date) {
        for subtask in subtasks.values where subtask.traceID == traceID && subtask.status == .pending {
            var settled = subtask
            settled.status = .unfinished
            settled.settledAt = now
            subtasks[settled.id] = settled
        }
    }
}
