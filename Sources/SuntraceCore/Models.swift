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

public enum CloudSyncEndpointKind: String, Codable, Hashable, Sendable, CaseIterable {
    case iCloud
    case s3
    case webDAV
    case localFolder
}

public enum CloudSyncMode: String, Codable, Hashable, Sendable, CaseIterable {
    case manual
    case automatic
}

public struct SyncSnapshotRetentionPolicy: Codable, Equatable, Sendable {
    public var indexRetentionDays: Int
    public var retentionIndexesDaily: Int

    public init(indexRetentionDays: Int = 180, retentionIndexesDaily: Int = 2) {
        self.indexRetentionDays = max(1, indexRetentionDays)
        self.retentionIndexesDaily = max(1, retentionIndexesDaily)
    }
}

public struct LocalFirstCloudSyncPolicy: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var endpoint: CloudSyncEndpointKind
    public var mode: CloudSyncMode
    public var intervalSeconds: Int
    public var generateConflictCopy: Bool
    public var snapshotRetention: SyncSnapshotRetentionPolicy

    public init(
        enabled: Bool = false,
        endpoint: CloudSyncEndpointKind = .iCloud,
        mode: CloudSyncMode = .manual,
        intervalSeconds: Int = 300,
        generateConflictCopy: Bool = true,
        snapshotRetention: SyncSnapshotRetentionPolicy = SyncSnapshotRetentionPolicy()
    ) {
        self.enabled = enabled
        self.endpoint = endpoint
        self.mode = mode
        self.intervalSeconds = min(max(intervalSeconds, 30), 43200)
        self.generateConflictCopy = generateConflictCopy
        self.snapshotRetention = snapshotRetention
    }
}

public struct SettingsPoemDisplayPolicy: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var text: String

    public init(enabled: Bool = true, text: String = SettingsPoemDisplayPolicy.defaultText) {
        self.enabled = enabled
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.text = trimmed.isEmpty ? SettingsPoemDisplayPolicy.defaultText : text
    }

    public static let defaultText = """
    飞光飞光，劝尔一杯酒。
    吾不识青天高，黄地厚。
    唯见月寒日暖，来煎人寿。
    食熊则肥，食蛙则瘦。
    神君何在？太一安有？
    天东有若木，下置衔烛龙。
    吾将斩龙足，嚼龙肉，
    使之朝不得回，夜不得伏。
    自然老者不死，少者不哭。
    何为服黄金，吞白玉？
    谁似任公子，云中骑碧驴？
    刘彻茂陵多滞骨，嬴政梓棺费鲍鱼。
    """
}

public enum TaskTagStatus: String, Codable, Equatable, Sendable, CaseIterable {
    case active
    case inactive
}

public enum TaskTagSlot: Int, Codable, Equatable, Hashable, Sendable, CaseIterable, Comparable {
    case tagI = 1
    case tagII = 2
    case tagIII = 3

    public static func < (lhs: TaskTagSlot, rhs: TaskTagSlot) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct TaskTag: Codable, Equatable, Sendable, Identifiable {
    public var id: TaskTagID
    public var name: String
    public var status: TaskTagStatus
    public var colorHex: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: TaskTagID = TaskTagID(),
        name: String,
        status: TaskTagStatus = .active,
        colorHex: String = "#2A6FDB",
        now: Date
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.colorHex = colorHex
        self.createdAt = now
        self.updatedAt = now
    }
}

public struct TaskTagAssignment: Codable, Equatable, Sendable, Identifiable {
    public var tagID: TaskTagID
    public var slot: TaskTagSlot
    public var createdAt: Date
    public var updatedAt: Date

    public var id: Int { slot.rawValue }

    public init(tagID: TaskTagID, slot: TaskTagSlot, now: Date) {
        self.tagID = tagID
        self.slot = slot
        self.createdAt = now
        self.updatedAt = now
    }
}

public enum SyncEndpointKind: String, Codable, Hashable, Sendable, CaseIterable {
    case customEndpoint
    case iCloud
    case s3
    case webDAV
    case localFolder
}

public enum SyncEndpointAvailability: String, Codable, Hashable, Sendable {
    case available
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
    public var localFirstSyncPolicy: LocalFirstCloudSyncPolicy
    public var settingsPoemDisplayPolicy: SettingsPoemDisplayPolicy
    public var taskTags: [TaskTag]
    public var syncEndpointOptions: [SyncEndpointOption]

    public init(
        theme: AppTheme = .coolGray,
        language: AppLanguage = .chinese,
        dataMode: AppDataMode = .localFirst,
        backupPolicy: ScheduledBackupPolicy = ScheduledBackupPolicy(),
        localFirstSyncPolicy: LocalFirstCloudSyncPolicy = LocalFirstCloudSyncPolicy(),
        settingsPoemDisplayPolicy: SettingsPoemDisplayPolicy = SettingsPoemDisplayPolicy(),
        taskTags: [TaskTag] = [],
        syncEndpointOptions: [SyncEndpointOption] = AppPreferences.defaultSyncEndpointOptions
    ) {
        self.theme = theme
        self.language = language
        self.dataMode = dataMode
        self.backupPolicy = backupPolicy
        self.localFirstSyncPolicy = localFirstSyncPolicy
        self.settingsPoemDisplayPolicy = settingsPoemDisplayPolicy
        self.taskTags = taskTags
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
        localFirstSyncPolicy = try container.decodeIfPresent(
            LocalFirstCloudSyncPolicy.self,
            forKey: .localFirstSyncPolicy
        ) ?? LocalFirstCloudSyncPolicy()
        settingsPoemDisplayPolicy = try container.decodeIfPresent(
            SettingsPoemDisplayPolicy.self,
            forKey: .settingsPoemDisplayPolicy
        ) ?? SettingsPoemDisplayPolicy()
        taskTags = try container.decodeIfPresent([TaskTag].self, forKey: .taskTags) ?? []
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
            description: "写入当前 Apple Account 的 iCloud Drive 同步仓库",
            availability: .available
        ),
        SyncEndpointOption(
            kind: .s3,
            title: "S3 云同步",
            description: "兼容对象存储同步端点",
            availability: .planned
        ),
        SyncEndpointOption(
            kind: .webDAV,
            title: "WebDAV 云同步",
            description: "兼容 WebDAV 的同步端点",
            availability: .planned
        ),
        SyncEndpointOption(
            kind: .localFolder,
            title: "本地同步文件夹",
            description: "自管目录或局域网共享端点",
            availability: .available
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
    public var tagAssignments: [TaskTagAssignment]
    public var createdAt: Date
    public var updatedAt: Date

    public var primaryTagID: TaskTagID? {
        tagAssignments.first { $0.slot == .tagI }?.tagID
    }

    public init(
        id: TaskChainID = TaskChainID(),
        state: TaskChainState = .active,
        tagAssignments: [TaskTagAssignment] = [],
        now: Date
    ) {
        self.id = id
        self.state = state
        self.tagAssignments = tagAssignments.sorted { $0.slot < $1.slot }
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
    public var plannedSubtasks: [PlannedSubtask]
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
        plannedSubtasks: [PlannedSubtask] = [],
        now: Date
    ) {
        self.id = id
        self.chainID = chainID
        self.sequence = sequence
        self.title = title
        self.descriptionText = descriptionText ?? notes
        self.note = note
        self.plannedSubtasks = plannedSubtasks.sorted { $0.position < $1.position }
        self.createdAt = now
        self.supersededAt = nil
        self.supersededByDefinitionID = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case chainID
        case sequence
        case title
        case descriptionText
        case note
        case plannedSubtasks
        case createdAt
        case supersededAt
        case supersededByDefinitionID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(TaskDefinitionID.self, forKey: .id)
        chainID = try container.decode(TaskChainID.self, forKey: .chainID)
        sequence = try container.decode(Int.self, forKey: .sequence)
        title = try container.decode(String.self, forKey: .title)
        descriptionText = try container.decodeIfPresent(String.self, forKey: .descriptionText)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        plannedSubtasks = try container.decodeIfPresent([PlannedSubtask].self, forKey: .plannedSubtasks) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        supersededAt = try container.decodeIfPresent(Date.self, forKey: .supersededAt)
        supersededByDefinitionID = try container.decodeIfPresent(TaskDefinitionID.self, forKey: .supersededByDefinitionID)
    }
}

public struct PlannedSubtask: Codable, Equatable, Sendable, Identifiable {
    public var id: PlannedSubtaskID
    public var lineageID: SubtaskLineageID
    public var title: String
    public var difficulty: SubtaskDifficulty
    public var position: Int
    public var createdAt: Date

    public init(
        id: PlannedSubtaskID = PlannedSubtaskID(),
        lineageID: SubtaskLineageID = SubtaskLineageID(),
        title: String,
        difficulty: SubtaskDifficulty = .simple,
        position: Int,
        now: Date
    ) {
        self.id = id
        self.lineageID = lineageID
        self.title = title
        self.difficulty = difficulty
        self.position = position
        self.createdAt = now
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
