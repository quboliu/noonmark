import Foundation

public enum TaskChainState: String, Codable, Hashable, Sendable {
    case active
    case abandoned
}

public enum TraceStatus: String, Codable, Hashable, Sendable {
    case pending
    case completed
    case unfinished
    case continued
    case changed
    case returnedToPool
    case abandoned
}

public enum NewTaskTarget: Equatable, Sendable {
    case taskPool
    case date(LocalDate)
}

public enum ViewSort: String, Codable, Hashable, Sendable {
    case priority
    case createdAt
    case title
}

public struct Day: Codable, Equatable, Sendable {
    public var id: DayID
    public var date: LocalDate
    public var lockedAt: Date?
    public var reviewSummary: String?
    public var reviewUnfinishedReason: String?
    public var reviewTomorrowNote: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: DayID = DayID(), date: LocalDate, now: Date) {
        self.id = id
        self.date = date
        self.lockedAt = nil
        self.reviewSummary = nil
        self.reviewUnfinishedReason = nil
        self.reviewTomorrowNote = nil
        self.createdAt = now
        self.updatedAt = now
    }
}

public struct TaskChain: Codable, Equatable, Sendable {
    public var id: TaskChainID
    public var state: TaskChainState
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: TaskChainID = TaskChainID(), state: TaskChainState = .active, now: Date) {
        self.id = id
        self.state = state
        self.createdAt = now
        self.updatedAt = now
    }
}

public struct TaskDefinition: Codable, Equatable, Sendable {
    public var id: TaskDefinitionID
    public var chainID: TaskChainID
    public var sequence: Int
    public var title: String
    public var notes: String?
    public var createdAt: Date
    public var supersededAt: Date?
    public var supersededByDefinitionID: TaskDefinitionID?

    public init(
        id: TaskDefinitionID = TaskDefinitionID(),
        chainID: TaskChainID,
        sequence: Int,
        title: String,
        notes: String?,
        now: Date
    ) {
        self.id = id
        self.chainID = chainID
        self.sequence = sequence
        self.title = title
        self.notes = notes
        self.createdAt = now
        self.supersededAt = nil
        self.supersededByDefinitionID = nil
    }
}

public struct DayTrace: Codable, Equatable, Sendable {
    public var id: DayTraceID
    public var chainID: TaskChainID
    public var definitionID: TaskDefinitionID
    public var date: LocalDate
    public var status: TraceStatus
    public var priority: Int
    public var continuationSeq: Int
    public var continuedFromTraceID: DayTraceID?
    public var changedToTraceID: DayTraceID?
    public var createdAt: Date
    public var completedAt: Date?
    public var settledAt: Date?

    public init(
        id: DayTraceID = DayTraceID(),
        chainID: TaskChainID,
        definitionID: TaskDefinitionID,
        date: LocalDate,
        status: TraceStatus = .pending,
        priority: Int,
        continuationSeq: Int = 0,
        continuedFromTraceID: DayTraceID? = nil,
        now: Date
    ) {
        self.id = id
        self.chainID = chainID
        self.definitionID = definitionID
        self.date = date
        self.status = status
        self.priority = priority
        self.continuationSeq = continuationSeq
        self.continuedFromTraceID = continuedFromTraceID
        self.changedToTraceID = nil
        self.createdAt = now
        self.completedAt = nil
        self.settledAt = nil
    }
}

public struct Subtask: Codable, Equatable, Sendable {
    public var id: SubtaskID
    public var traceID: DayTraceID
    public var title: String
    public var isDone: Bool
    public var position: Int
    public var createdAt: Date
    public var completedAt: Date?

    public init(id: SubtaskID = SubtaskID(), traceID: DayTraceID, title: String, position: Int, now: Date) {
        self.id = id
        self.traceID = traceID
        self.title = title
        self.isDone = false
        self.position = position
        self.createdAt = now
        self.completedAt = nil
    }
}

public struct PoolTask: Equatable, Sendable {
    public let chain: TaskChain
    public let definition: TaskDefinition
}

public struct DayTodoView: Equatable, Sendable {
    public let day: Day?
    public let traces: [DayTrace]
}

public struct FuturePlanItem: Equatable, Sendable {
    public let trace: DayTrace
    public let definition: TaskDefinition
}

public struct UnfinishedPoolItem: Equatable, Sendable {
    public let chain: TaskChain
    public let definition: TaskDefinition
    public let unfinishedTraces: [DayTrace]
    public let activeTrace: DayTrace?

    public var isContinuedPending: Bool {
        activeTrace?.status == .pending
    }
}

public struct CompletedTaskTrajectory: Equatable, Sendable {
    public let startDate: LocalDate
    public let continuedDates: [LocalDate]
    public let completedDate: LocalDate
    public let traces: [DayTrace]
}

public struct CompletedPoolItem: Equatable, Sendable {
    public let trace: DayTrace
    public let definition: TaskDefinition
    public let trajectory: CompletedTaskTrajectory
}

public struct DailyReviewStats: Equatable, Sendable {
    public var total: Int
    public var completed: Int
    public var unfinished: Int
    public var continued: Int
    public var changed: Int
    public var returnedToPool: Int
    public var abandoned: Int
}
