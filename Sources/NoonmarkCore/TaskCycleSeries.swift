import Foundation

public enum TaskCycleSchedule: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case daily
    case weekdays

    public func includes(_ date: LocalDate) -> Bool {
        switch self {
        case .daily:
            return true
        case .weekdays:
            guard let weekday = TaskCycleCivilCalendar.weekday(for: date) else {
                return false
            }
            return weekday != 1 && weekday != 7
        }
    }

    public func occurrenceCount(
        from startDate: LocalDate,
        through endDate: LocalDate
    ) throws -> Int {
        try TaskCycleCivilCalendar.materializableDates(
            from: startDate,
            through: endDate
        ).count(where: includes)
    }
}

public enum TaskCycleCancellationScope: Codable, Equatable, Hashable, Sendable {
    case occurrence(LocalDate)
    case followingDates(after: LocalDate)
}

public struct TaskCycleCancellationFact: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let scope: TaskCycleCancellationScope
    public let recordedAt: Date

    public init(
        id: UUID = UUID(),
        scope: TaskCycleCancellationScope,
        recordedAt: Date
    ) {
        self.id = id
        self.scope = scope
        self.recordedAt = recordedAt
    }
}

public struct TaskCycleSeries: Codable, Equatable, Sendable {
    public let id: TaskCycleSeriesID
    public private(set) var title: String
    public private(set) var descriptionText: String?
    public let startDate: LocalDate
    public let endDate: LocalDate
    public let schedule: TaskCycleSchedule
    public private(set) var cancellationFacts: [TaskCycleCancellationFact]
    public let createdAt: Date
    public private(set) var updatedAt: Date

    public init(
        id: TaskCycleSeriesID = TaskCycleSeriesID(),
        title: String,
        descriptionText: String? = nil,
        startDate: LocalDate,
        endDate: LocalDate,
        schedule: TaskCycleSchedule,
        cancellationFacts: [TaskCycleCancellationFact] = [],
        createdAt: Date,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.descriptionText = descriptionText
        self.startDate = startDate
        self.endDate = endDate
        self.schedule = schedule
        self.cancellationFacts = cancellationFacts
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    public var stoppedAfterDate: LocalDate? {
        cancellationFacts.compactMap { fact in
            if case let .followingDates(after: date) = fact.scope {
                return date
            }
            return nil
        }.min()
    }

    public func isOccurrenceSkipped(_ date: LocalDate) -> Bool {
        cancellationFacts.contains { fact in
            if case let .occurrence(skippedDate) = fact.scope {
                return skippedDate == date
            }
            return false
        }
    }

    mutating func appendCancellation(
        _ scope: TaskCycleCancellationScope,
        now: Date
    ) throws {
        guard updatedAt.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite,
              now >= updatedAt
        else {
            throw NoonmarkError.invalidInput(
                "content mutation time cannot move backwards"
            )
        }
        updatedAt = now
        cancellationFacts.append(
            TaskCycleCancellationFact(scope: scope, recordedAt: now)
        )
    }

    public func validateIntegrity() throws {
        let normalizedTitle = title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard normalizedTitle.isEmpty == false,
              normalizedTitle == title,
              createdAt.timeIntervalSinceReferenceDate.isFinite,
              updatedAt.timeIntervalSinceReferenceDate.isFinite,
              updatedAt >= createdAt
        else {
            throw NoonmarkError.invalidInput(
                "task cycle series contains invalid content facts"
            )
        }
        let dates = try TaskCycleCivilCalendar.materializableDates(
            from: startDate,
            through: endDate
        )
        let scheduledDates = Set(dates.filter(schedule.includes))
        guard scheduledDates.isEmpty == false,
              Set(cancellationFacts.map(\.id)).count
              == cancellationFacts.count
        else {
            throw NoonmarkError.invalidInput(
                "task cycle series contains invalid schedule facts"
            )
        }
        for fact in cancellationFacts {
            guard fact.recordedAt.timeIntervalSinceReferenceDate.isFinite,
                  fact.recordedAt >= createdAt,
                  fact.recordedAt <= updatedAt
            else {
                throw NoonmarkError.invalidInput(
                    "task cycle series contains invalid cancellation facts"
                )
            }
            switch fact.scope {
            case let .occurrence(date):
                guard scheduledDates.contains(date) else {
                    throw NoonmarkError.invalidInput(
                        "task cycle series contains invalid cancellation facts"
                    )
                }
            case let .followingDates(after: date):
                guard date < endDate else {
                    throw NoonmarkError.invalidInput(
                        "task cycle series contains invalid cancellation facts"
                    )
                }
            }
        }
    }
}

public struct TaskCycleMembership: Codable, Equatable, Hashable, Sendable {
    public let seriesID: TaskCycleSeriesID
    public let occurrenceDate: LocalDate

    public init(
        seriesID: TaskCycleSeriesID,
        occurrenceDate: LocalDate
    ) {
        self.seriesID = seriesID
        self.occurrenceDate = occurrenceDate
    }
}

public enum TaskCycleTrackDayState: String, Codable, Equatable, Hashable, Sendable {
    case notScheduled
    case pendingPast
    case pendingToday
    case planned
    case completed
    case unfinished
    case deferred
    case changed
    case returnedToPool
    case skipped
    case abandoned
}

public struct TaskCycleTraceTarget: Equatable, Sendable {
    public let traceID: DayTraceID
    public let date: LocalDate
    public let state: TaskCycleTrackDayState
}

public struct TaskCycleTrackDay: Equatable, Identifiable, Sendable {
    public var id: LocalDate { date }
    public let date: LocalDate
    public let chainID: TaskChainID?
    public let occurrenceTarget: TaskCycleTraceTarget?
    public let futurePlanTarget: TaskCycleTraceTarget?
    public let unfinishedTarget: TaskCycleTraceTarget?
    public let completedTarget: TaskCycleTraceTarget?

    public var state: TaskCycleTrackDayState {
        occurrenceTarget?.state ?? .notScheduled
    }

    public init(
        date: LocalDate,
        chainID: TaskChainID?,
        occurrenceTarget: TaskCycleTraceTarget?,
        futurePlanTarget: TaskCycleTraceTarget?,
        unfinishedTarget: TaskCycleTraceTarget?,
        completedTarget: TaskCycleTraceTarget?
    ) {
        self.date = date
        self.chainID = chainID
        self.occurrenceTarget = occurrenceTarget
        self.futurePlanTarget = futurePlanTarget
        self.unfinishedTarget = unfinishedTarget
        self.completedTarget = completedTarget
    }

    public func semanticTarget(
        in collection: TaskCycleCollection
    ) -> TaskCycleTraceTarget? {
        switch collection {
        case .pool:
            occurrenceTarget
        case .future:
            futurePlanTarget
        case .unfinished:
            unfinishedTarget
        case .completed:
            completedTarget
        }
    }

    public func navigationTarget(
        in collection: TaskCycleCollection
    ) -> TaskCycleTraceTarget? {
        guard state != .skipped, state != .returnedToPool else {
            return nil
        }
        return semanticTarget(in: collection) ?? occurrenceTarget
    }

    public func presentationState(
        in collection: TaskCycleCollection
    ) -> TaskCycleTrackDayState {
        semanticTarget(in: collection)?.state ?? state
    }
}

public enum TaskCycleCollection: Equatable, Hashable, Sendable {
    case pool
    case future
    case unfinished
    case completed
}

public struct TaskCycleTrack: Equatable, Identifiable, Sendable {
    public let id: TaskCycleSeriesID
    public let title: String
    public let startDate: LocalDate
    public let endDate: LocalDate
    public let schedule: TaskCycleSchedule
    public let days: [TaskCycleTrackDay]

    public init(
        id: TaskCycleSeriesID,
        title: String,
        startDate: LocalDate,
        endDate: LocalDate,
        schedule: TaskCycleSchedule,
        days: [TaskCycleTrackDay]
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.schedule = schedule
        self.days = days
    }

    public var scheduledCount: Int {
        days.count { $0.state != .notScheduled }
    }

    public var completedCount: Int {
        days.count { $0.completedTarget != nil }
    }

    public var unfinishedCount: Int {
        days.count { $0.unfinishedTarget != nil }
    }

    public var plannedCount: Int {
        days.count { $0.state == .planned }
    }

    public var futurePlanCount: Int {
        days.count { $0.futurePlanTarget != nil }
    }

    public func appears(in collection: TaskCycleCollection) -> Bool {
        switch collection {
        case .pool:
            true
        case .future:
            futurePlanCount > 0
        case .unfinished:
            unfinishedCount > 0
        case .completed:
            completedCount > 0
        }
    }
}

public extension NoonmarkEngine {
    @discardableResult
    func createTaskCycleSeries(
        title: String,
        descriptionText: String? = nil,
        startDate: LocalDate,
        endDate: LocalDate,
        schedule: TaskCycleSchedule,
        today: LocalDate,
        now: Date = Date()
    ) throws -> TaskCycleSeriesID {
        try createTaskCycleSeries(
            title: title,
            descriptionText: descriptionText,
            plannedSubtasks: [],
            startDate: startDate,
            endDate: endDate,
            schedule: schedule,
            today: today,
            now: now
        )
    }

    @discardableResult
    func createTaskCycleSeries(
        title: String,
        descriptionText: String? = nil,
        plannedSubtasks: [PlannedSubtask],
        startDate: LocalDate,
        endDate: LocalDate,
        schedule: TaskCycleSchedule,
        today: LocalDate,
        now: Date = Date()
    ) throws -> TaskCycleSeriesID {
        let normalizedTitle = try normalizedTaskCycleTitle(title)
        guard startDate >= today else {
            throw NoonmarkError.invalidTransition(
                "task cycle cannot begin in the past"
            )
        }
        guard startDate <= endDate else {
            throw NoonmarkError.invalidInput(
                "task cycle end date must not precede its start date"
            )
        }
        let dates = try TaskCycleCivilCalendar.materializableDates(
            from: startDate,
            through: endDate
        )
        let occurrenceDates = dates.filter(schedule.includes)
        guard occurrenceDates.isEmpty == false else {
            throw NoonmarkError.invalidInput(
                "task cycle schedule contains no occurrences"
            )
        }

        let series = TaskCycleSeries(
            title: normalizedTitle,
            descriptionText: descriptionText,
            startDate: startDate,
            endDate: endDate,
            schedule: schedule,
            createdAt: now
        )
        storeTaskCycleSeries(series)
        for occurrenceDate in occurrenceDates {
            let membership = TaskCycleMembership(
                seriesID: series.id,
                occurrenceDate: occurrenceDate
            )
            installTaskCycleOccurrence(
                normalizedTitle: normalizedTitle,
                descriptionText: descriptionText,
                plannedSubtasks: plannedSubtasks,
                membership: membership,
                now: now
            )
        }
        return series.id
    }

    @discardableResult
    func convertTaskToCycleSeries(
        chainID: TaskChainID,
        startDate: LocalDate,
        endDate: LocalDate,
        schedule: TaskCycleSchedule,
        today: LocalDate,
        now: Date = Date()
    ) throws -> TaskCycleSeriesID {
        let source = try taskCycleConversionSource(chainID: chainID)
        let sourceChain = source.chain
        guard sourceChain.state == .active,
              sourceChain.cycleMembership == nil
        else {
            throw NoonmarkError.invalidTransition(
                "only a standalone active task can become recurring"
            )
        }
        let definition = source.definition
        let normalizedTitle = try normalizedTaskCycleTitle(
            definition.title
        )
        guard startDate >= today, startDate <= endDate else {
            throw NoonmarkError.invalidTransition(
                "task cycle cannot begin in the past"
            )
        }
        let dates = try TaskCycleCivilCalendar.materializableDates(
            from: startDate,
            through: endDate
        )
        let occurrenceDates = dates.filter(schedule.includes)
        guard let firstOccurrenceDate = occurrenceDates.first else {
            throw NoonmarkError.invalidInput(
                "task cycle schedule contains no occurrences"
            )
        }
        let active = source.activeTrace
        if let active {
            guard active.status == .pending,
                  active.date == firstOccurrenceDate
            else {
                throw NoonmarkError.invalidTransition(
                    "an active task must keep its scheduled date when becoming recurring"
                )
            }
        } else {
            guard source.isInTaskPool else {
                throw NoonmarkError.invalidTransition(
                    "historical tasks cannot be rewritten as recurring occurrences"
                )
            }
        }
        try ensureTaskCycleDatesUnlocked(occurrenceDates)

        let descriptionText = active?.descriptionText
            ?? definition.descriptionText
        let series = TaskCycleSeries(
            title: normalizedTitle,
            descriptionText: descriptionText,
            startDate: startDate,
            endDate: endDate,
            schedule: schedule,
            createdAt: now
        )
        let adoption = try prepareTaskCycleAdoption(
            chainID: chainID,
            membership: TaskCycleMembership(
                seriesID: series.id,
                occurrenceDate: firstOccurrenceDate
            ),
            descriptionText: descriptionText,
            now: now
        )
        storeTaskCycleSeries(series)
        storePreparedTaskCycleAdoption(
            chain: adoption.chain,
            insertedTrace: adoption.insertedTrace,
            now: now
        )
        for occurrenceDate in occurrenceDates.dropFirst() {
            installTaskCycleOccurrence(
                normalizedTitle: normalizedTitle,
                descriptionText: descriptionText,
                plannedSubtasks: definition.plannedSubtasks,
                membership: TaskCycleMembership(
                    seriesID: series.id,
                    occurrenceDate: occurrenceDate
                ),
                now: now
            )
        }
        return series.id
    }

    func taskCycleTracks(today: LocalDate) -> [TaskCycleTrack] {
        let membersBySeries = Dictionary(
            grouping: chains.values.compactMap {
                chain -> (TaskChain, TaskCycleMembership)? in
                guard let membership = chain.cycleMembership else {
                    return nil
                }
                return (chain, membership)
            },
            by: { $0.1.seriesID }
        )
        return taskCycleSeries.values
            .compactMap { series -> TaskCycleTrack? in
                guard let dates = try? TaskCycleCivilCalendar.materializableDates(
                    from: series.startDate,
                    through: series.endDate
                ) else {
                    return nil
                }
                let entries = membersBySeries[series.id] ?? []
                let entriesByDate = Dictionary(
                    uniqueKeysWithValues: entries.map {
                        ($0.1.occurrenceDate, $0.0)
                    }
                )
                let days = dates.map { date in
                    guard let chain = entriesByDate[date] else {
                        return TaskCycleTrackDay(
                            date: date,
                            chainID: nil,
                            occurrenceTarget: nil,
                            futurePlanTarget: nil,
                            unfinishedTarget: nil,
                            completedTarget: nil
                        )
                    }
                    let chainTraces = traces.values.filter {
                        $0.chainID == chain.id
                    }
                    let scheduledTrace = latestTaskCycleTrace(
                        chainTraces.filter { $0.date == date }
                    )
                    let latestTrace = latestTaskCycleTrace(chainTraces)
                    let representativeTrace =
                        if scheduledTrace?.status == .cancelledDraft,
                           latestTrace?.id != scheduledTrace?.id
                        {
                            latestTrace
                        } else {
                            scheduledTrace ?? latestTrace
                        }
                    let futurePlanTrace = latestTaskCycleTrace(
                        chainTraces.filter {
                            $0.status == .pending && $0.date > today
                        }
                    )
                    let completedTrace = latestTaskCycleTrace(
                        chainTraces.filter {
                            $0.status == .completed
                        }
                    )
                    let unfinishedTrace = completedTrace == nil
                        ? latestTaskCycleTrace(
                            chainTraces.filter {
                                $0.status == .unfinished
                                    || $0.status == .abandoned
                            }
                        )
                        : nil
                    return TaskCycleTrackDay(
                        date: date,
                        chainID: chain.id,
                        occurrenceTarget: taskCycleTraceTarget(
                            representativeTrace,
                            today: today,
                            cancelledState: series
                                .isOccurrenceSkipped(date)
                                ? .skipped
                                : .returnedToPool
                        ),
                        futurePlanTarget: taskCycleTraceTarget(
                            futurePlanTrace,
                            today: today
                        ),
                        unfinishedTarget: taskCycleTraceTarget(
                            unfinishedTrace,
                            today: today
                        ),
                        completedTarget: taskCycleTraceTarget(
                            completedTrace,
                            today: today
                        )
                    )
                }
                return TaskCycleTrack(
                    id: series.id,
                    title: series.title,
                    startDate: series.startDate,
                    endDate: series.endDate,
                    schedule: series.schedule,
                    days: days
                )
            }
            .sorted {
                if $0.startDate != $1.startDate {
                    return $0.startDate < $1.startDate
                }
                return $0.id.description < $1.id.description
            }
    }

    func taskCycleTracks(
        today: LocalDate,
        collection: TaskCycleCollection
    ) -> [TaskCycleTrack] {
        taskCycleTracks(today: today).filter {
            $0.appears(in: collection)
        }
    }

    func skipTaskCycleOccurrence(
        seriesID: TaskCycleSeriesID,
        occurrenceDate: LocalDate,
        today: LocalDate,
        now: Date = Date()
    ) throws {
        var series = try taskCycleSeriesValue(seriesID)
        guard let chain = chains.values.first(where: {
            $0.cycleMembership?.seriesID == seriesID
                && $0.cycleMembership?.occurrenceDate == occurrenceDate
        }),
            let trace = traces.values.first(where: {
                $0.chainID == chain.id
                    && $0.status == .pending
                    && $0.date > today
            }),
            occurrenceDate > today
        else {
            throw NoonmarkError.invalidTransition(
                "only a future pending task cycle occurrence can be skipped"
            )
        }
        try ensureTaskCycleDatesUnlocked([trace.date])
        try series.appendCancellation(
            .occurrence(occurrenceDate),
            now: now
        )
        let preparedTrace = try prepareTaskCycleTraceCancellation(
            trace,
            today: today,
            now: now
        )
        storeTaskCycleSeries(series)
        storePreparedTaskCycleTraceCancellations(
            [preparedTrace],
            now: now
        )
    }

    @discardableResult
    func stopTaskCycleSeries(
        seriesID: TaskCycleSeriesID,
        today: LocalDate,
        now: Date = Date()
    ) throws -> Int {
        var series = try taskCycleSeriesValue(seriesID)
        guard today < series.endDate else { return 0 }
        if let stoppedAfterDate = series.stoppedAfterDate,
           stoppedAfterDate <= today
        {
            return 0
        }
        let futurePendingOccurrences = chains.values.compactMap {
            chain -> (occurrenceDate: LocalDate, trace: DayTrace)? in
            guard chain.cycleMembership?.seriesID == seriesID,
                  let membership = chain.cycleMembership,
                  membership.occurrenceDate > today
            else {
                return nil
            }
            guard let trace = traces.values.first(where: {
                $0.chainID == chain.id
                    && $0.status == .pending
                    && $0.date > today
            }) else {
                return nil
            }
            return (membership.occurrenceDate, trace)
        }
        .sorted {
            $0.occurrenceDate < $1.occurrenceDate
        }
        try ensureTaskCycleDatesUnlocked(
            futurePendingOccurrences.map(\.trace.date)
        )
        for occurrence in futurePendingOccurrences {
            try series.appendCancellation(
                .occurrence(occurrence.occurrenceDate),
                now: now
            )
        }
        try series.appendCancellation(
            .followingDates(after: today),
            now: now
        )
        let preparedTraces = try futurePendingOccurrences.map {
            try prepareTaskCycleTraceCancellation(
                $0.trace,
                today: today,
                now: now
            )
        }
        storeTaskCycleSeries(series)
        storePreparedTaskCycleTraceCancellations(
            preparedTraces,
            now: now
        )
        return futurePendingOccurrences.count
    }

    private func taskCycleSeriesValue(
        _ id: TaskCycleSeriesID
    ) throws -> TaskCycleSeries {
        guard let series = taskCycleSeries[id] else {
            throw NoonmarkError.notFound("task cycle series")
        }
        return series
    }

    private func latestTaskCycleTrace(
        _ candidates: [DayTrace]
    ) -> DayTrace? {
        candidates.max {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            return $0.id.description < $1.id.description
        }
    }

    private func taskCycleTrackState(
        trace: DayTrace,
        date: LocalDate,
        today: LocalDate,
        cancelledState: TaskCycleTrackDayState
    ) -> TaskCycleTrackDayState {
        if trace.status == .pending {
            if date < today { return .pendingPast }
            if date == today { return .pendingToday }
            return .planned
        }
        if trace.status == .cancelledDraft {
            return cancelledState
        }
        guard let state = TaskCycleTrackDayState(
            rawValue: trace.status.rawValue
        ) else {
            preconditionFailure("visible trace status must map to cycle state")
        }
        return state
    }

    private func taskCycleTraceTarget(
        _ trace: DayTrace?,
        today: LocalDate,
        cancelledState: TaskCycleTrackDayState = .returnedToPool
    ) -> TaskCycleTraceTarget? {
        guard let trace else { return nil }
        return TaskCycleTraceTarget(
            traceID: trace.id,
            date: trace.date,
            state: taskCycleTrackState(
                trace: trace,
                date: trace.date,
                today: today,
                cancelledState: cancelledState
            )
        )
    }
}

enum TaskCycleCivilCalendar {
    static let maximumMaterializedDayCount = 366

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    static func weekday(for date: LocalDate) -> Int? {
        guard let instant = instant(for: date) else { return nil }
        return calendar.component(.weekday, from: instant)
    }

    static func materializableDates(
        from startDate: LocalDate,
        through endDate: LocalDate
    ) throws -> [LocalDate] {
        guard startDate <= endDate,
              let start = instant(for: startDate),
              let end = instant(for: endDate)
        else {
            throw NoonmarkError.invalidInput("invalid task cycle date range")
        }
        guard let distance = calendar.dateComponents(
            [.day],
            from: start,
            to: end
        ).day,
            distance >= 0,
            distance < maximumMaterializedDayCount
        else {
            throw NoonmarkError.invalidInput(
                "task cycle cannot materialize more than 366 calendar days"
            )
        }
        var dates: [LocalDate] = []
        dates.reserveCapacity(distance + 1)
        var cursor = start
        while cursor <= end {
            let components = calendar.dateComponents(
                [.year, .month, .day],
                from: cursor
            )
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day
            else {
                throw NoonmarkError.invalidInput(
                    "task cycle date could not be resolved"
                )
            }
            dates.append(LocalDate(year: year, month: month, day: day))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor)
            else {
                throw NoonmarkError.invalidInput(
                    "task cycle date range could not advance"
                )
            }
            cursor = next
        }
        return dates
    }

    private static func instant(for date: LocalDate) -> Date? {
        calendar.date(
            from: DateComponents(
                year: date.year,
                month: date.month,
                day: date.day
            )
        )
    }
}
