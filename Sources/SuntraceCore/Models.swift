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

public enum SubtaskStatus: String, Codable, Hashable, Sendable {
    case pending
    case completed
    case unfinished
    case continued
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
    public var lineageID: SubtaskLineageID
    public var traceID: DayTraceID
    public var title: String
    public var status: SubtaskStatus
    public var position: Int
    public var continuedFromSubtaskID: SubtaskID?
    public var createdAt: Date
    public var completedAt: Date?
    public var settledAt: Date?

    public var isDone: Bool {
        status == .completed
    }

    public init(
        id: SubtaskID = SubtaskID(),
        lineageID: SubtaskLineageID = SubtaskLineageID(),
        traceID: DayTraceID,
        title: String,
        status: SubtaskStatus = .pending,
        position: Int,
        continuedFromSubtaskID: SubtaskID? = nil,
        now: Date
    ) {
        self.id = id
        self.lineageID = lineageID
        self.traceID = traceID
        self.title = title
        self.status = status
        self.position = position
        self.continuedFromSubtaskID = continuedFromSubtaskID
        self.createdAt = now
        self.completedAt = nil
        self.settledAt = nil
    }
}

public struct SubtaskProgress: Equatable, Sendable {
    public let total: Int
    public let completed: Int
    public let pending: Int
    public let unfinished: Int
    public let continued: Int
    public let abandoned: Int

    public var isPartiallyCompleted: Bool {
        let actionableTotal = total - abandoned
        return completed > 0 && completed < actionableTotal
    }

    public var canCompleteParent: Bool {
        pending == 0 && unfinished == 0
    }
}

public struct SubtaskTrajectoryRecord: Equatable, Sendable {
    public let subtask: Subtask
    public let date: LocalDate
}

public struct SubtaskTrajectory: Equatable, Sendable {
    public let lineageID: SubtaskLineageID
    public let title: String
    public let startDate: LocalDate
    public let continuedDates: [LocalDate]
    public let completedDate: LocalDate?
    public let records: [SubtaskTrajectoryRecord]
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
    public let subtaskTrajectories: [SubtaskTrajectory]
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
