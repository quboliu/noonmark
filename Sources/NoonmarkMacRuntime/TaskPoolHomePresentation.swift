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

public enum TaskPoolAnalysisConfidence:
    String,
    Equatable,
    Sendable
{
    case low
    case medium
    case high
}

public struct TaskPoolAnalysisFindingPresentation:
    Equatable,
    Sendable
{
    public let conclusion: String
    public let evidenceTitles: [String?]
    public let confidence: TaskPoolAnalysisConfidence
    public let uncertainty: String
    public let recommendation: String

    public init(
        conclusion: String,
        evidenceTitles: [String?],
        confidence: TaskPoolAnalysisConfidence,
        uncertainty: String,
        recommendation: String
    ) {
        self.conclusion = conclusion
        self.evidenceTitles = evidenceTitles
        self.confidence = confidence
        self.uncertainty = uncertainty
        self.recommendation = recommendation
    }
}

public struct TaskPoolAnalysisReportPresentation:
    Equatable,
    Sendable
{
    public let generatedAt: Date
    public let findings: [TaskPoolAnalysisFindingPresentation]

    public init(
        generatedAt: Date,
        findings: [TaskPoolAnalysisFindingPresentation]
    ) {
        self.generatedAt = generatedAt
        self.findings = findings
    }
}

public enum TaskPoolAnalysisRunSnapshot: Equatable, Sendable {
    case running
    case succeeded(
        contextVersion: String,
        report: TaskPoolAnalysisReportPresentation
    )
    case stopped
    case failed
}

public enum TaskPoolAnalysisFreshness: Equatable, Sendable {
    case current
    case outdated
}

public enum TaskPoolAnalysisState: Equatable, Sendable {
    case notGenerated
    case generating
    case report(
        TaskPoolAnalysisReportPresentation,
        freshness: TaskPoolAnalysisFreshness
    )
    case failed
}

public enum TaskPoolAnalysisProjection {
    public static func state(
        availability: TaskPoolAnalysisAvailability,
        run: TaskPoolAnalysisRunSnapshot?,
        currentContextVersion: String
    ) -> TaskPoolAnalysisState? {
        guard availability.isVisible else { return nil }
        guard let run else { return .notGenerated }
        switch run {
        case .running:
            return .generating
        case let .succeeded(contextVersion, report):
            return .report(
                report,
                freshness: contextVersion == currentContextVersion
                    ? .current
                    : .outdated
            )
        case .stopped:
            return .notGenerated
        case .failed:
            return .failed
        }
    }
}
