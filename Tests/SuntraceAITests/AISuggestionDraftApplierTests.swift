@testable import SuntraceAI
@testable import SuntraceCore
import XCTest

final class AISuggestionDraftApplierTests: XCTestCase {
    private let today = LocalDate("2026-07-05")
    private let tomorrow = LocalDate("2026-07-06")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testConfirmedAddSubtaskUsesCoreDomainInterface() throws {
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "整理原型差距", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: today, today: today, now: now)

        let operation = AIProposedOperation.addSubtask(traceID: traceID, title: "补截图验收", difficulty: .medium)
        let draft = makeDraft(operation)
        let result = try AISuggestionDraftApplier().applyConfirmed(
            operation,
            from: draft,
            to: engine,
            today: today,
            now: now
        )

        XCTAssertEqual(result.operation, operation)
        XCTAssertEqual(result.message, "已添加子任务")
        let subtasks = engine.subtasks.values.filter { $0.traceID == traceID }
        XCTAssertEqual(subtasks.count, 1)
        XCTAssertEqual(subtasks.first?.title, "补截图验收")
        XCTAssertEqual(subtasks.first?.difficulty, .medium)
    }

    func testConfirmedScheduleFromPoolCreatesPendingDayTrace() throws {
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "打包 DMG", now: now)

        let operation = AIProposedOperation.scheduleFromPool(chainID: chainID, targetDate: tomorrow)
        _ = try AISuggestionDraftApplier().applyConfirmed(
            operation,
            from: makeDraft(operation),
            to: engine,
            today: today,
            now: now
        )

        let scheduled = engine.futurePlans(today: today).first
        XCTAssertEqual(scheduled?.definition.title, "打包 DMG")
        XCTAssertEqual(scheduled?.trace.date, tomorrow)
        XCTAssertEqual(scheduled?.trace.status, .pending)
    }

    func testAssignLabelPreparesPlanWithoutWritingUntilUserBoundaryConfirms() throws {
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "分类任务", now: now)
        let operation = AIProposedOperation.assignLabel(chainID: chainID, label: "工程")
        let draft = makeDraft(operation)
        let decisionID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!

        let plan = try AISuggestionDraftApplier().prepareClassification(
            operation,
            from: draft,
            interactionID: decisionID,
            on: engine,
            now: now
        )
        XCTAssertTrue(engine.snapshot().classifications.labels.isEmpty)

        let receipt = try engine.commitClassification(
            plan,
            confirmation: .user(confirming: plan, decisionID: decisionID),
            now: now
        )

        XCTAssertEqual(receipt.decisionID, decisionID)
        let state = engine.snapshot().classifications
        let labelID = try XCTUnwrap(state.labels.values.first(where: { $0.name == "工程" })?.id)
        XCTAssertEqual(state.currentByChainID[chainID]?.labelIDs, [labelID])
        let record = try XCTUnwrap(state.changeRecords.last)
        XCTAssertEqual(record.decisionID, decisionID)
        XCTAssertEqual(
            record.source,
            .zhulongSuggestion(
                sessionID: draft.sessionID,
                draftID: draft.id.rawValue,
                draftVersion: draft.version,
                evidenceID: draft.evidenceID
            )
        )
    }

    func testApplyFailsClosedWhenOperationIsNotPartOfConfirmedDraft() throws {
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "分类任务", now: now)
        let confirmedOperation = AIProposedOperation.assignLabel(chainID: chainID, label: "工程")
        let unrelatedOperation = AIProposedOperation.assignLabel(chainID: chainID, label: "私人")

        XCTAssertThrowsError(
            try AISuggestionDraftApplier().applyConfirmed(
                unrelatedOperation,
                from: makeDraft(confirmedOperation),
                to: engine,
                today: today,
                now: now
            )
        ) { error in
            XCTAssertEqual(
                error as? AISuggestionApplyError,
                .unsupportedOperation(
                    "operation does not belong to the confirmed suggestion draft"
                )
            )
        }
    }

    func testAssignLabelCannotCommitInsideAIModule() throws {
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "分类任务", now: now)
        let operation = AIProposedOperation.assignLabel(chainID: chainID, label: "工程")

        XCTAssertThrowsError(
            try AISuggestionDraftApplier().applyConfirmed(
                operation,
                from: makeDraft(operation),
                to: engine,
                today: today,
                now: now
            )
        ) { error in
            XCTAssertEqual(
                error as? AISuggestionApplyError,
                .unsupportedOperation(
                    "classification operations require confirmation at the user decision boundary"
                )
            )
        }
        XCTAssertTrue(engine.snapshot().classifications.labels.isEmpty)
    }

    private func makeDraft(_ operation: AIProposedOperation) -> AISuggestionDraft {
        AISuggestionDraft(
            id: AISuggestionDraftID(
                UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
            ),
            sessionID: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!,
            version: 1,
            evidenceID: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000003")!,
            kind: .labelClassification,
            createdAt: now,
            sourceScope: AIScopeSnapshot(ranges: []),
            localReport: LocalInsightReport(evidence: [], facts: []),
            summary: "测试建议",
            proposedOperations: [operation],
            confidence: 1
        )
    }
}
