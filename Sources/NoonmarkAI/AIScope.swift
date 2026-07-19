import Foundation
import NoonmarkCore

public enum AIScopeRange: Equatable, Sendable {
    case currentDay(LocalDate)
    case historicalDay(LocalDate)
    case dateRange(LocalDate, LocalDate)
    case taskPool
    case unfinishedPool
    case completedPool
    case selectedTaskChain(TaskChainID)
}

public struct AITraceSnapshot: Equatable, Sendable {
    public let trace: DayTrace
    public let definition: TaskDefinition
    public let subtasks: [Subtask]
    public let subtaskProgress: SubtaskProgress

    public init?(
        trace: DayTrace,
        definition: TaskDefinition,
        subtasks: [Subtask],
        subtaskProgress: SubtaskProgress
    ) {
        guard trace.formsDayHistory else {
            return nil
        }
        self.trace = trace
        self.definition = definition
        self.subtasks = subtasks
        self.subtaskProgress = subtaskProgress
    }
}

public struct AIDayTodoSnapshot: Equatable, Sendable {
    public let date: LocalDate
    public let day: Day?
    public let traces: [AITraceSnapshot]
    public let stats: DailyReviewStats

    public init(date: LocalDate, day: Day?, traces: [AITraceSnapshot], stats: DailyReviewStats) {
        self.date = date
        self.day = day
        self.traces = traces
        self.stats = stats
    }
}

public struct AIUnfinishedPoolSnapshot: Equatable, Sendable {
    public let item: UnfinishedPoolItem
    public let unfinishedTraces: [AITraceSnapshot]
    public let activeTrace: AITraceSnapshot?

    public init(item: UnfinishedPoolItem, unfinishedTraces: [AITraceSnapshot], activeTrace: AITraceSnapshot?) {
        self.item = item
        self.unfinishedTraces = unfinishedTraces
        self.activeTrace = activeTrace
    }
}

public struct AIClassificationCatalogSnapshot: Equatable, Sendable {
    public let categories: [String]
    public let labels: [String]

    public var isEmpty: Bool {
        categories.isEmpty && labels.isEmpty
    }

    public init(categories: [String] = [], labels: [String] = []) {
        self.categories = categories
        self.labels = labels
    }
}

public struct AIScopeSnapshot: Equatable, Sendable {
    public let requestedAt: Date
    public let ranges: [AIScopeRange]
    public let dayTodos: [AIDayTodoSnapshot]
    public let taskPool: [PoolTask]
    public let unfinishedPool: [AIUnfinishedPoolSnapshot]
    public let completedPool: [CompletedPoolItem]
    public let classifications: AIClassificationCatalogSnapshot

    public var isEmpty: Bool {
        dayTodos.isEmpty && taskPool.isEmpty && unfinishedPool.isEmpty && completedPool.isEmpty && classifications.isEmpty
    }

    public init(
        requestedAt: Date = Date(),
        ranges: [AIScopeRange],
        dayTodos: [AIDayTodoSnapshot] = [],
        taskPool: [PoolTask] = [],
        unfinishedPool: [AIUnfinishedPoolSnapshot] = [],
        completedPool: [CompletedPoolItem] = [],
        classifications: AIClassificationCatalogSnapshot = AIClassificationCatalogSnapshot()
    ) {
        self.requestedAt = requestedAt
        self.ranges = ranges
        self.dayTodos = dayTodos
        self.taskPool = taskPool
        self.unfinishedPool = unfinishedPool
        self.completedPool = completedPool
        self.classifications = classifications
    }
}

public extension AIScopeSnapshot {
    static func day(
        date: LocalDate,
        from engine: NoonmarkEngine,
        isCurrentDay: Bool = false,
        requestedAt: Date = Date()
    ) -> AIScopeSnapshot {
        let view = engine.getDayTodo(date: date)
        return AIScopeSnapshot(
            requestedAt: requestedAt,
            ranges: [isCurrentDay ? .currentDay(date) : .historicalDay(date)],
            dayTodos: [
                AIDayTodoSnapshot(
                    date: date,
                    day: view.day,
                    traces: view.traces.compactMap { traceSnapshot(for: $0, from: engine) },
                    stats: engine.dailyReviewStats(date: date)
                )
            ]
        )
    }

    static func pools(
        from engine: NoonmarkEngine,
        includeTaskPool: Bool = true,
        includeUnfinishedPool: Bool = true,
        includeCompletedPool: Bool = true,
        requestedAt: Date = Date()
    ) -> AIScopeSnapshot {
        var ranges: [AIScopeRange] = []
        if includeTaskPool {
            ranges.append(.taskPool)
        }
        if includeUnfinishedPool {
            ranges.append(.unfinishedPool)
        }
        if includeCompletedPool {
            ranges.append(.completedPool)
        }

        let unfinished = includeUnfinishedPool ? engine.unfinishedPool().map { item in
            AIUnfinishedPoolSnapshot(
                item: item,
                unfinishedTraces: item.unfinishedTraces.compactMap { traceSnapshot(for: $0, from: engine) },
                activeTrace: item.activeTrace.flatMap { traceSnapshot(for: $0, from: engine) }
            )
        } : []

        return AIScopeSnapshot(
            requestedAt: requestedAt,
            ranges: ranges,
            taskPool: includeTaskPool ? engine.taskPool() : [],
            unfinishedPool: unfinished,
            completedPool: includeCompletedPool ? engine.completedPool() : []
        )
    }

    static func combined(_ scopes: [AIScopeSnapshot], requestedAt: Date = Date()) -> AIScopeSnapshot {
        AIScopeSnapshot(
            requestedAt: requestedAt,
            ranges: scopes.flatMap(\.ranges),
            dayTodos: scopes.flatMap(\.dayTodos),
            taskPool: scopes.flatMap(\.taskPool),
            unfinishedPool: scopes.flatMap(\.unfinishedPool),
            completedPool: scopes.flatMap(\.completedPool),
            classifications: AIClassificationCatalogSnapshot(
                categories: Array(Set(scopes.flatMap(\.classifications.categories))).sorted(),
                labels: Array(Set(scopes.flatMap(\.classifications.labels))).sorted()
            )
        )
    }

    private static func traceSnapshot(for trace: DayTrace, from engine: NoonmarkEngine) -> AITraceSnapshot? {
        guard let definition = engine.definitions[trace.definitionID] else {
            return nil
        }
        let subtasks = engine.subtasks.values
            .filter {
                $0.traceID == trace.id && $0.isUserPresentable
            }
            .sorted {
                if $0.position != $1.position {
                    return $0.position < $1.position
                }
                return $0.createdAt < $1.createdAt
            }
        return AITraceSnapshot(
            trace: trace,
            definition: definition,
            subtasks: subtasks,
            subtaskProgress: engine.subtaskProgress(for: trace.id)
        )
    }
}
