import Foundation

public struct TaskPoolStatisticsItem: Equatable, Sendable {
    public let categoryID: String?
    public let labelIDs: Set<String>
    public let hasContext: Bool
    public let hasPlannedSubtasks: Bool
    public let hasReturnedToPool: Bool

    public init(
        categoryID: String?,
        labelIDs: Set<String>,
        hasContext: Bool,
        hasPlannedSubtasks: Bool,
        hasReturnedToPool: Bool
    ) {
        self.categoryID = categoryID
        self.labelIDs = labelIDs
        self.hasContext = hasContext
        self.hasPlannedSubtasks = hasPlannedSubtasks
        self.hasReturnedToPool = hasReturnedToPool
    }
}

public struct TaskPoolStatisticsSnapshot: Equatable, Sendable {
    public let taskCount: Int
    public let categoryCount: Int
    public let labelCount: Int
    public let ungroupedTaskCount: Int
    public let contextualTaskCount: Int
    public let plannedTaskCount: Int
    public let returnedTaskCount: Int

    public init(items: [TaskPoolStatisticsItem]) {
        taskCount = items.count
        categoryCount = Set(items.compactMap(\.categoryID)).count
        labelCount = Set(items.flatMap(\.labelIDs)).count
        ungroupedTaskCount = items.count { $0.categoryID == nil }
        contextualTaskCount = items.count { $0.hasContext }
        plannedTaskCount = items.count { $0.hasPlannedSubtasks }
        returnedTaskCount = items.count { $0.hasReturnedToPool }
    }
}

public enum TaskPoolAnalysisAvailability: Equatable, Sendable {
    case unavailable
    case ready

    public init(providerConfigurationIsReady: Bool) {
        self = providerConfigurationIsReady ? .ready : .unavailable
    }

    public var isVisible: Bool {
        self == .ready
    }
}
