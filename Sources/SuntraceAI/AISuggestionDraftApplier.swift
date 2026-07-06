import Foundation
import SuntraceCore

public enum AISuggestionApplyError: Error, Equatable, Sendable {
    case unsupportedOperation(String)
}

public struct AISuggestionApplyResult: Equatable, Sendable {
    public let operation: AIProposedOperation
    public let message: String

    public init(operation: AIProposedOperation, message: String) {
        self.operation = operation
        self.message = message
    }
}

public struct AISuggestionDraftApplier: Sendable {
    public init() {}

    public func applyConfirmed(
        _ operation: AIProposedOperation,
        to engine: SuntraceEngine,
        today: LocalDate,
        now: Date = Date()
    ) throws -> AISuggestionApplyResult {
        switch operation {
        case let .createPoolTask(title, descriptionText, note):
            _ = try engine.createPoolTask(title: title, descriptionText: descriptionText, note: note, now: now)
            return AISuggestionApplyResult(operation: operation, message: "已创建任务池任务")

        case let .addSubtask(traceID, title, difficulty):
            _ = try engine.addSubtask(traceID: traceID, title: title, difficulty: difficulty, now: now)
            return AISuggestionApplyResult(operation: operation, message: "已添加子任务")

        case let .scheduleFromPool(chainID, targetDate):
            _ = try engine.scheduleFromPool(chainID: chainID, date: targetDate, today: today, now: now)
            return AISuggestionApplyResult(operation: operation, message: "已排期到 \(targetDate)")

        case let .continueTrace(traceID, targetDate):
            _ = try engine.continueTrace(traceID: traceID, targetDate: targetDate, today: today, now: now)
            return AISuggestionApplyResult(operation: operation, message: "已延续到 \(targetDate)")

        case let .abandonChain(traceID):
            try engine.abandonChain(from: traceID, now: now)
            return AISuggestionApplyResult(operation: operation, message: "任务链已废弃")

        case .assignLabel:
            throw AISuggestionApplyError.unsupportedOperation("label 尚未进入核心领域模型")

        case let .updateDailyReview(date, summary, unfinishedReason, tomorrowNote):
            engine.updateDailyReview(
                date: date,
                summary: summary,
                unfinishedReason: unfinishedReason,
                tomorrowNote: tomorrowNote,
                now: now
            )
            return AISuggestionApplyResult(operation: operation, message: "已更新每日复盘")
        }
    }
}
