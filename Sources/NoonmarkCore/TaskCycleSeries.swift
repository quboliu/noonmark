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
}

public struct TaskCycleMembership: Codable, Equatable, Hashable, Sendable {
    public let seriesID: TaskCycleSeriesID
    public let occurrenceDate: LocalDate
    public let startDate: LocalDate
    public let endDate: LocalDate
    public let schedule: TaskCycleSchedule

    public init(
        seriesID: TaskCycleSeriesID,
        occurrenceDate: LocalDate,
        startDate: LocalDate,
        endDate: LocalDate,
        schedule: TaskCycleSchedule
    ) {
        self.seriesID = seriesID
        self.occurrenceDate = occurrenceDate
        self.startDate = startDate
        self.endDate = endDate
        self.schedule = schedule
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

public struct TaskCycleTrackDay: Equatable, Identifiable, Sendable {
    public var id: LocalDate { date }
    public let date: LocalDate
    public let state: TaskCycleTrackDayState
    public let chainID: TaskChainID?
    public let traceID: DayTraceID?
    public let traceDate: LocalDate?
    public let futurePlanTraceID: DayTraceID?
    public let futurePlanDate: LocalDate?

    public init(
        date: LocalDate,
        state: TaskCycleTrackDayState,
        chainID: TaskChainID?,
        traceID: DayTraceID?,
        traceDate: LocalDate? = nil,
        futurePlanTraceID: DayTraceID? = nil,
        futurePlanDate: LocalDate? = nil
    ) {
        self.date = date
        self.state = state
        self.chainID = chainID
        self.traceID = traceID
        self.traceDate = traceDate
        self.futurePlanTraceID = futurePlanTraceID
        self.futurePlanDate = futurePlanDate
    }
}

public enum TaskCycleCollection: Equatable, Hashable, Sendable {
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
        days.count { $0.state == .completed }
    }

    public var unfinishedCount: Int {
        days.count { $0.state == .unfinished || $0.state == .abandoned }
    }

    public var plannedCount: Int {
        days.count { $0.state == .planned }
    }

    public var futurePlanCount: Int {
        days.count { $0.futurePlanTraceID != nil }
    }

    public func appears(in collection: TaskCycleCollection) -> Bool {
        switch collection {
        case .future:
            futurePlanCount > 0
        case .unfinished:
            days.contains {
                $0.state == .unfinished || $0.state == .abandoned
            }
        case .completed:
            days.contains { $0.state == .completed }
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
        let dates = try TaskCycleCivilCalendar.dates(
            from: startDate,
            through: endDate
        )
        guard dates.count <= 366 else {
            throw NoonmarkError.invalidInput(
                "task cycle cannot materialize more than 366 calendar days"
            )
        }
        let occurrenceDates = dates.filter(schedule.includes)
        guard occurrenceDates.isEmpty == false else {
            throw NoonmarkError.invalidInput(
                "task cycle schedule contains no occurrences"
            )
        }

        let seriesID = TaskCycleSeriesID()
        for occurrenceDate in occurrenceDates {
            let membership = TaskCycleMembership(
                seriesID: seriesID,
                occurrenceDate: occurrenceDate,
                startDate: startDate,
                endDate: endDate,
                schedule: schedule
            )
            installTaskCycleOccurrence(
                normalizedTitle: normalizedTitle,
                descriptionText: descriptionText,
                membership: membership,
                now: now
            )
        }
        return seriesID
    }

    func taskCycleTracks(today: LocalDate) -> [TaskCycleTrack] {
        let members = chains.values.compactMap { chain -> (TaskChain, TaskCycleMembership)? in
            guard let membership = chain.cycleMembership else { return nil }
            return (chain, membership)
        }
        return Dictionary(grouping: members, by: { $0.1.seriesID })
            .compactMap { seriesID, entries -> TaskCycleTrack? in
                guard let descriptor = entries.first?.1,
                      let dates = try? TaskCycleCivilCalendar.dates(
                          from: descriptor.startDate,
                          through: descriptor.endDate
                      )
                else {
                    return nil
                }
                let entriesByDate = Dictionary(
                    uniqueKeysWithValues: entries.map {
                        ($0.1.occurrenceDate, $0.0)
                    }
                )
                let firstEntry = entries.min {
                    $0.1.occurrenceDate < $1.1.occurrenceDate
                }
                let title = firstEntry.flatMap { firstEntry in
                    definitions.values
                        .filter {
                            $0.chainID == firstEntry.0.id
                                && $0.supersededAt == nil
                        }
                        .max { $0.sequence < $1.sequence }?
                        .title
                } ?? ""
                let days = dates.map { date in
                    guard let chain = entriesByDate[date] else {
                        return TaskCycleTrackDay(
                            date: date,
                            state: .notScheduled,
                            chainID: nil,
                            traceID: nil,
                            traceDate: nil,
                            futurePlanTraceID: nil,
                            futurePlanDate: nil
                        )
                    }
                    let chainTraces = traces.values.filter {
                        $0.chainID == chain.id
                    }
                    let scheduledTrace = latestTaskCycleTrace(
                        chainTraces.filter { $0.date == date }
                    )
                    let representativeTrace =
                        scheduledTrace
                        ?? latestTaskCycleTrace(chainTraces)
                    let futurePlanTrace = latestTaskCycleTrace(
                        chainTraces.filter {
                            $0.status == .pending && $0.date > today
                        }
                    )
                    return TaskCycleTrackDay(
                        date: date,
                        state: taskCycleTrackState(
                            trace: representativeTrace,
                            date: representativeTrace?.date ?? date,
                            today: today
                        ),
                        chainID: chain.id,
                        traceID: representativeTrace?.id,
                        traceDate: representativeTrace?.date,
                        futurePlanTraceID: futurePlanTrace?.id,
                        futurePlanDate: futurePlanTrace?.date
                    )
                }
                return TaskCycleTrack(
                    id: seriesID,
                    title: title,
                    startDate: descriptor.startDate,
                    endDate: descriptor.endDate,
                    schedule: descriptor.schedule,
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
        trace: DayTrace?,
        date: LocalDate,
        today: LocalDate
    ) -> TaskCycleTrackDayState {
        guard let trace else { return .skipped }
        if trace.status == .pending {
            if date < today { return .pendingPast }
            if date == today { return .pendingToday }
            return .planned
        }
        if trace.status == .cancelledDraft {
            return .skipped
        }
        guard let state = TaskCycleTrackDayState(
            rawValue: trace.status.rawValue
        ) else {
            preconditionFailure("visible trace status must map to cycle state")
        }
        return state
    }
}

enum TaskCycleCivilCalendar {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    static func weekday(for date: LocalDate) -> Int? {
        guard let instant = instant(for: date) else { return nil }
        return calendar.component(.weekday, from: instant)
    }

    static func dates(
        from startDate: LocalDate,
        through endDate: LocalDate
    ) throws -> [LocalDate] {
        guard startDate <= endDate,
              let start = instant(for: startDate),
              let end = instant(for: endDate)
        else {
            throw NoonmarkError.invalidInput("invalid task cycle date range")
        }
        var dates: [LocalDate] = []
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
