@testable import NoonmarkAI
@testable import NoonmarkCore
import XCTest

final class CancelledDraftBoundaryTests: XCTestCase {
    private let today = LocalDate("2026-07-16")
    private let futureDate = LocalDate("2026-07-17")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCancelledFutureDraftCannotConstructAITraceSnapshot() throws {
        let fixture = try makeCancelledFutureDraft()
        let hiddenTrace = try XCTUnwrap(fixture.engine.traces[fixture.traceID])
        let definition = try XCTUnwrap(fixture.engine.definitions[hiddenTrace.definitionID])
        let hiddenSnapshot: AITraceSnapshot? = AITraceSnapshot(
            trace: hiddenTrace,
            definition: definition,
            subtasks: fixture.engine.subtasks.values.filter { $0.traceID == fixture.traceID },
            subtaskProgress: fixture.engine.subtaskProgress(for: fixture.traceID)
        )

        XCTAssertFalse(hiddenTrace.formsDayHistory)
        XCTAssertNil(hiddenSnapshot)

        let visibleEngine = NoonmarkEngine()
        let visibleChainID = try visibleEngine.createPoolTask(title: "可见任务", now: now)
        let visibleTraceID = try visibleEngine.scheduleFromPool(
            chainID: visibleChainID,
            date: today,
            today: today,
            now: now
        )
        let visibleTrace = try XCTUnwrap(visibleEngine.traces[visibleTraceID])
        let visibleDefinition = try XCTUnwrap(visibleEngine.definitions[visibleTrace.definitionID])

        XCTAssertNotNil(
            AITraceSnapshot(
                trace: visibleTrace,
                definition: visibleDefinition,
                subtasks: [],
                subtaskProgress: visibleEngine.subtaskProgress(for: visibleTraceID)
            )
        )
    }

    func testCancelledFutureDraftDoesNotEnterDayScopeInsightOrPrompt() throws {
        let fixture = try makeCancelledFutureDraft()

        let scope = AIScopeSnapshot.day(
            date: futureDate,
            from: fixture.engine,
            requestedAt: now.addingTimeInterval(5)
        )
        let dayTodo = try XCTUnwrap(scope.dayTodos.first)
        let report = LocalInsightAnalyzer().analyze(scope)
        let request = AIPromptBuilder().buildRequest(
            task: .dailyReview,
            scope: scope,
            report: report
        )

        XCTAssertTrue(dayTodo.traces.isEmpty)
        XCTAssertEqual(dayTodo.stats.total, 0)
        XCTAssertTrue(report.evidence.isEmpty)
        XCTAssertTrue(report.facts.isEmpty)
        XCTAssertFalse(request.userPrompt.contains(fixture.hiddenTitle))
        XCTAssertFalse(request.userPrompt.contains(fixture.hiddenNote))
        XCTAssertFalse(request.userPrompt.contains(fixture.hiddenSubtaskTitle))
        XCTAssertFalse(request.userPrompt.contains(TraceStatus.cancelledDraft.rawValue))
    }

    func testSnapshotUndoCancelledSubtaskDoesNotEnterAIScopeOrPrompt() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "可见父任务",
            now: now
        )
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now
        )
        let before = engine.snapshot()
        let hiddenTitle = "撤销后不可进入 Provider 的子任务"
        _ = try engine.addSubtask(
            traceID: traceID,
            title: hiddenTitle,
            now: now.addingTimeInterval(1)
        )
        let undone = try NoonmarkEngine(snapshot: before)
        try undone.prepareSnapshotUndo(
            replacing: engine.snapshot(),
            now: now.addingTimeInterval(2)
        )

        let scope = AIScopeSnapshot.day(
            date: today,
            from: undone,
            requestedAt: now.addingTimeInterval(3)
        )
        let trace = try XCTUnwrap(scope.dayTodos.first?.traces.first)
        let report = LocalInsightAnalyzer().analyze(scope)
        let request = AIPromptBuilder().buildRequest(
            task: .dailyReview,
            scope: scope,
            report: report
        )

        XCTAssertTrue(trace.subtasks.isEmpty)
        XCTAssertEqual(trace.subtaskProgress.total, 0)
        XCTAssertFalse(request.userPrompt.contains(hiddenTitle))
        XCTAssertFalse(
            request.userPrompt.contains(
                SubtaskStatus.cancelledDraft.rawValue
            )
        )
    }

    func testLocalInsightAnalyzerRejectsCancelledDraftFromForgedCompletedTrajectory() throws {
        let fixture = try makeCancelledFutureDraft()
        var hiddenTrace = try XCTUnwrap(fixture.engine.traces[fixture.traceID])
        hiddenTrace.continuationSeq = 9
        let definition = try XCTUnwrap(fixture.engine.definitions[hiddenTrace.definitionID])
        let forgedItem = CompletedPoolItem(
            trace: hiddenTrace,
            definition: definition,
            trajectory: CompletedTaskTrajectory(
                startDate: hiddenTrace.date,
                continuedDates: [hiddenTrace.date],
                completedDate: hiddenTrace.date,
                traces: [hiddenTrace],
                subtaskTrajectories: []
            )
        )
        let scope = AIScopeSnapshot(
            requestedAt: now.addingTimeInterval(5),
            ranges: [.completedPool],
            completedPool: [forgedItem]
        )

        let report = LocalInsightAnalyzer().analyze(scope)
        let request = AIPromptBuilder().buildRequest(
            task: .dailyReview,
            scope: scope,
            report: report
        )

        XCTAssertTrue(report.evidence.isEmpty)
        XCTAssertTrue(report.facts.isEmpty)
        XCTAssertFalse(request.userPrompt.contains(fixture.hiddenTitle))
        XCTAssertFalse(request.userPrompt.contains(fixture.hiddenNote))
        XCTAssertFalse(request.userPrompt.contains(fixture.hiddenSubtaskTitle))
        XCTAssertFalse(request.userPrompt.contains(TraceStatus.cancelledDraft.rawValue))
    }

    func testAnalyzerAndPromptRejectCancelledDraftFromForgedUnfinishedPool() throws {
        let fixture = try makeCancelledFutureDraft()
        let hiddenTrace = try XCTUnwrap(fixture.engine.traces[fixture.traceID])
        let chain = try XCTUnwrap(fixture.engine.chains[hiddenTrace.chainID])
        let definition = try XCTUnwrap(fixture.engine.definitions[hiddenTrace.definitionID])
        let forgedItem = UnfinishedPoolItem(
            chain: chain,
            definition: definition,
            unfinishedTraces: [hiddenTrace],
            activeTrace: nil
        )
        let scope = AIScopeSnapshot(
            requestedAt: now.addingTimeInterval(5),
            ranges: [.unfinishedPool],
            unfinishedPool: [
                AIUnfinishedPoolSnapshot(
                    item: forgedItem,
                    unfinishedTraces: [],
                    activeTrace: nil
                )
            ]
        )

        let report = LocalInsightAnalyzer().analyze(scope)
        let request = AIPromptBuilder().buildRequest(
            task: .dailyReview,
            scope: scope,
            report: report
        )

        XCTAssertTrue(report.evidence.isEmpty)
        XCTAssertTrue(report.facts.isEmpty)
        XCTAssertFalse(request.userPrompt.contains(fixture.hiddenTitle))
        XCTAssertFalse(request.userPrompt.contains(fixture.hiddenNote))
        XCTAssertFalse(request.userPrompt.contains(fixture.hiddenSubtaskTitle))
        XCTAssertFalse(request.userPrompt.contains(TraceStatus.cancelledDraft.rawValue))
    }

    private func makeCancelledFutureDraft() throws -> CancelledFutureDraftFixture {
        let hiddenTitle = "AI-隐藏未来任务"
        let hiddenNote = "AI-隐藏轨迹附言"
        let hiddenSubtaskTitle = "AI-隐藏子任务"
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: hiddenTitle,
            now: now
        )
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: futureDate,
            today: today,
            now: now.addingTimeInterval(1)
        )
        _ = try engine.appendTraceNote(
            traceID: traceID,
            body: hiddenNote,
            today: today,
            now: now.addingTimeInterval(2)
        )
        _ = try engine.addSubtask(
            traceID: traceID,
            title: hiddenSubtaskTitle,
            now: now.addingTimeInterval(3)
        )
        try engine.returnToPool(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(4)
        )

        return CancelledFutureDraftFixture(
            engine: engine,
            traceID: traceID,
            hiddenTitle: hiddenTitle,
            hiddenNote: hiddenNote,
            hiddenSubtaskTitle: hiddenSubtaskTitle
        )
    }
}

private struct CancelledFutureDraftFixture {
    let engine: NoonmarkEngine
    let traceID: DayTraceID
    let hiddenTitle: String
    let hiddenNote: String
    let hiddenSubtaskTitle: String
}
