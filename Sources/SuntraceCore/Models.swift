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

public enum SubtaskDifficulty: Int, Codable, Hashable, Sendable, CaseIterable {
    case simple = 1
    case medium = 2
    case hard = 3

    public var label: String {
        switch self {
        case .simple:
            return "简"
        case .medium:
            return "中"
        case .hard:
            return "难"
        }
    }
}

public enum TraceProgressMode: String, Codable, Hashable, Sendable {
    case manual
    case weightedSubtasks
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

public enum AppTheme: String, Codable, Hashable, Sendable, CaseIterable {
    case coolGray
    case warmPaper
}

public enum AppLanguage: String, Codable, Hashable, Sendable, CaseIterable {
    case chinese
    case english
}

public enum AppDataMode: String, Codable, Hashable, Sendable, CaseIterable {
    case localFirst
    case onlineFirst
}

public enum BackupDestinationKind: String, Codable, Hashable, Sendable, CaseIterable {
    case iCloudDrive
    case s3
}

public enum ScheduledBackupFrequency: String, Codable, Hashable, Sendable, CaseIterable {
    case off
    case daily
    case weekly
}

public struct ScheduledBackupPolicy: Codable, Equatable, Sendable {
    public var frequency: ScheduledBackupFrequency
    public var destination: BackupDestinationKind

    public var isEnabled: Bool {
        frequency != .off
    }

    public init(
        frequency: ScheduledBackupFrequency = .off,
        destination: BackupDestinationKind = .iCloudDrive
    ) {
        self.frequency = frequency
        self.destination = destination
    }
}

public enum SyncEndpointKind: String, Codable, Hashable, Sendable, CaseIterable {
    case customEndpoint
    case iCloud
}

public enum SyncEndpointAvailability: String, Codable, Hashable, Sendable {
    case planned
}

public struct SyncEndpointOption: Codable, Equatable, Sendable {
    public let kind: SyncEndpointKind
    public let title: String
    public let description: String
    public let availability: SyncEndpointAvailability

    public init(kind: SyncEndpointKind, title: String, description: String, availability: SyncEndpointAvailability) {
        self.kind = kind
        self.title = title
        self.description = description
        self.availability = availability
    }
}

public struct AppPreferences: Codable, Equatable, Sendable {
    public var theme: AppTheme
    public var language: AppLanguage
    public var dataMode: AppDataMode
    public var backupPolicy: ScheduledBackupPolicy
    public var syncEndpointOptions: [SyncEndpointOption]

    public init(
        theme: AppTheme = .coolGray,
        language: AppLanguage = .chinese,
        dataMode: AppDataMode = .localFirst,
        backupPolicy: ScheduledBackupPolicy = ScheduledBackupPolicy(),
        syncEndpointOptions: [SyncEndpointOption] = AppPreferences.defaultSyncEndpointOptions
    ) {
        self.theme = theme
        self.language = language
        self.dataMode = dataMode
        self.backupPolicy = backupPolicy
        self.syncEndpointOptions = syncEndpointOptions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        theme = try container.decodeIfPresent(AppTheme.self, forKey: .theme) ?? .coolGray
        language = try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .chinese
        dataMode = try container.decodeIfPresent(AppDataMode.self, forKey: .dataMode) ?? .localFirst
        backupPolicy = try container.decodeIfPresent(
            ScheduledBackupPolicy.self,
            forKey: .backupPolicy
        ) ?? ScheduledBackupPolicy()
        syncEndpointOptions = try container.decodeIfPresent(
            [SyncEndpointOption].self,
            forKey: .syncEndpointOptions
        ) ?? AppPreferences.defaultSyncEndpointOptions
    }

    public static let defaultSyncEndpointOptions: [SyncEndpointOption] = [
        SyncEndpointOption(
            kind: .customEndpoint,
            title: "自定义同步端点",
            description: "连接自有服务端",
            availability: .planned
        ),
        SyncEndpointOption(
            kind: .iCloud,
            title: "iCloud 云同步",
            description: "原生云同步",
            availability: .planned
        )
    ]
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
    public var descriptionText: String?
    public var note: String?
    public var createdAt: Date
    public var supersededAt: Date?
    public var supersededByDefinitionID: TaskDefinitionID?

    public var notes: String? {
        get { descriptionText }
        set { descriptionText = newValue }
    }

    public init(
        id: TaskDefinitionID = TaskDefinitionID(),
        chainID: TaskChainID,
        sequence: Int,
        title: String,
        descriptionText: String? = nil,
        note: String? = nil,
        notes: String? = nil,
        now: Date
    ) {
        self.id = id
        self.chainID = chainID
        self.sequence = sequence
        self.title = title
        self.descriptionText = descriptionText ?? notes
        self.note = note
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
    public var descriptionText: String?
    public var note: String?
    public var manualProgressPercent: Int?
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
        descriptionText: String? = nil,
        note: String? = nil,
        manualProgressPercent: Int? = nil,
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
        self.descriptionText = descriptionText
        self.note = note
        self.manualProgressPercent = manualProgressPercent
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
    public var difficulty: SubtaskDifficulty
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
        difficulty: SubtaskDifficulty = .simple,
        position: Int,
        continuedFromSubtaskID: SubtaskID? = nil,
        now: Date
    ) {
        self.id = id
        self.lineageID = lineageID
        self.traceID = traceID
        self.title = title
        self.status = status
        self.difficulty = difficulty
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

    public init(total: Int, completed: Int, pending: Int, unfinished: Int, continued: Int, abandoned: Int) {
        self.total = total
        self.completed = completed
        self.pending = pending
        self.unfinished = unfinished
        self.continued = continued
        self.abandoned = abandoned
    }

    public var isPartiallyCompleted: Bool {
        let actionableTotal = total - abandoned
        return completed > 0 && completed < actionableTotal
    }

    public var canCompleteParent: Bool {
        pending == 0 && unfinished == 0
    }
}

public struct TraceProgress: Equatable, Sendable {
    public let mode: TraceProgressMode
    public let percent: Int
    public let floorPercent: Int
    public let completedWeight: Int
    public let totalWeight: Int

    public init(mode: TraceProgressMode, percent: Int, floorPercent: Int, completedWeight: Int, totalWeight: Int) {
        self.mode = mode
        self.percent = percent
        self.floorPercent = floorPercent
        self.completedWeight = completedWeight
        self.totalWeight = totalWeight
    }
}

public struct CalendarDaySummary: Equatable, Sendable {
    public let date: LocalDate
    public let total: Int
    public let completed: Int
    public let pending: Int
    public let unfinished: Int
    public let heatLevel: Int

    public init(date: LocalDate, total: Int, completed: Int, pending: Int, unfinished: Int, heatLevel: Int) {
        self.date = date
        self.total = total
        self.completed = completed
        self.pending = pending
        self.unfinished = unfinished
        self.heatLevel = heatLevel
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

public struct CompletedSubtaskRecord: Equatable, Sendable {
    public let date: LocalDate
    public let subtask: Subtask
    public let parentTrace: DayTrace
    public let parentDefinition: TaskDefinition
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
