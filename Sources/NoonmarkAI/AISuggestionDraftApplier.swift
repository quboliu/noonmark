import Foundation
import NoonmarkCore

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
        from draft: AISuggestionDraft,
        to engine: NoonmarkEngine,
        today: LocalDate,
        now: Date = Date()
    ) throws -> AISuggestionApplyResult {
        try require(operation, belongsTo: draft)
        switch operation {
        case let .createPoolTask(title, descriptionText, initialNoteBody):
            _ = try engine.createPoolTask(
                title: title,
                descriptionText: descriptionText,
                initialNoteBody: initialNoteBody,
                now: now
            )
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
            throw AISuggestionApplyError.unsupportedOperation(
                "classification operations require confirmation at the user decision boundary"
            )

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

    public func prepareClassification(
        _ operation: AIProposedOperation,
        from draft: AISuggestionDraft,
        interactionID: UUID,
        on engine: NoonmarkEngine,
        now: Date = Date()
    ) throws -> ClassificationPlan {
        try require(operation, belongsTo: draft)
        guard case let .assignLabel(chainID, label) = operation else {
            throw AISuggestionApplyError.unsupportedOperation(
                "operation does not prepare a classification plan"
            )
        }

        let state = engine.snapshot().classifications
        let current = state.currentByChainID[chainID]
        let category = current?.categoryID.map(TaskCategoryChoice.existing)
        var labels = (current?.labelIDs ?? [])
            .sorted { $0.description < $1.description }
            .map(TaskLabelChoice.existing)
        labels.append(.new(name: label, colorHex: "#0E9488"))
        return try engine.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: category,
                    labels: labels
                )
            ),
            source: .zhulongSuggestion(
                sessionID: draft.sessionID,
                draftID: draft.id.rawValue,
                draftVersion: draft.version,
                evidenceID: draft.evidenceID
            ),
            interactionID: interactionID,
            now: now
        )
    }

    private func require(
        _ operation: AIProposedOperation,
        belongsTo draft: AISuggestionDraft
    ) throws {
        guard draft.proposedOperations.contains(operation) else {
            throw AISuggestionApplyError.unsupportedOperation(
                "operation does not belong to the confirmed suggestion draft"
            )
        }
    }
}
