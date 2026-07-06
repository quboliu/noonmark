import Foundation
import SuntraceCore

public enum ZhulongTask: String, Codable, Hashable, Sendable {
    case dailyReview
    case habitInsight
    case taskDecomposition
    case scheduling
    case labelClassification
    case theoryAnalysis
}

public enum AISuggestionKind: String, Codable, Hashable, Sendable {
    case dailyReview
    case habitInsight
    case taskDecomposition
    case scheduling
    case labelClassification
    case theoryAnalysis
}

public enum AIProposedOperation: Equatable, Sendable {
    case createPoolTask(title: String, descriptionText: String?, note: String?)
    case addSubtask(traceID: DayTraceID, title: String, difficulty: SubtaskDifficulty)
    case scheduleFromPool(chainID: TaskChainID, targetDate: LocalDate)
    case continueTrace(traceID: DayTraceID, targetDate: LocalDate)
    case abandonChain(traceID: DayTraceID)
    case assignLabel(chainID: TaskChainID, label: String)
    case updateDailyReview(date: LocalDate, summary: String?, unfinishedReason: String?, tomorrowNote: String?)
}

public struct AISuggestionDraft: Equatable, Sendable {
    public let id: AISuggestionDraftID
    public let kind: AISuggestionKind
    public let createdAt: Date
    public let sourceScope: AIScopeSnapshot
    public let localReport: LocalInsightReport
    public let summary: String
    public let proposedOperations: [AIProposedOperation]
    public let confidence: Double?

    public init(
        id: AISuggestionDraftID = AISuggestionDraftID(),
        kind: AISuggestionKind,
        createdAt: Date = Date(),
        sourceScope: AIScopeSnapshot,
        localReport: LocalInsightReport,
        summary: String,
        proposedOperations: [AIProposedOperation],
        confidence: Double?
    ) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.sourceScope = sourceScope
        self.localReport = localReport
        self.summary = summary
        self.proposedOperations = proposedOperations
        self.confidence = confidence
    }
}

public extension ZhulongTask {
    var suggestionKind: AISuggestionKind {
        switch self {
        case .dailyReview:
            return .dailyReview
        case .habitInsight:
            return .habitInsight
        case .taskDecomposition:
            return .taskDecomposition
        case .scheduling:
            return .scheduling
        case .labelClassification:
            return .labelClassification
        case .theoryAnalysis:
            return .theoryAnalysis
        }
    }
}
