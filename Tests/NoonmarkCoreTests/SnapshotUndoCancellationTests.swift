@testable import NoonmarkCore
import XCTest

final class SnapshotUndoCancellationTests: XCTestCase {
    private let today = LocalDate("2026-07-16")
    private let tomorrow = LocalDate("2026-07-17")
    private let base = Date(timeIntervalSinceReferenceDate: 900_000)

    func testUndoingNewDayTaskRetainsHiddenAppendOnlyFacts() throws {
        let before = NoonmarkEngine().snapshot()
        let current = NoonmarkEngine()
        let chainID = try current.createPoolTask(
            title: "撤销新增今日任务",
            now: base
        )
        _ = try current.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: base
        )
        let currentSnapshot = current.snapshot()
        let traceID = try XCTUnwrap(
            currentSnapshot.traces.first { $0.chainID == chainID }?.id
        )

        let undone = try NoonmarkEngine(snapshot: before)
        try undone.prepareSnapshotUndo(
            replacing: currentSnapshot,
            now: base.addingTimeInterval(1)
        )

        XCTAssertNotNil(undone.chains[chainID])
        XCTAssertEqual(
            undone.definitions.values.filter { $0.chainID == chainID }.count,
            1
        )
        XCTAssertEqual(
            undone.traces.values.filter { $0.chainID == chainID }.count,
            1
        )
        XCTAssertTrue(undone.getDayTodo(date: today).traces.isEmpty)
        XCTAssertFalse(undone.taskPool().contains { $0.chain.id == chainID })
        XCTAssertEqual(undone.chains[chainID]?.state, .abandoned)
        XCTAssertEqual(undone.traces[traceID]?.status, .cancelledDraft)
        XCTAssertEqual(undone.chains[chainID]?.createdAt, base)
        XCTAssertEqual(
            undone.chains[chainID]?.updatedAt,
            base.addingTimeInterval(1)
        )
        XCTAssertEqual(undone.traces[traceID]?.createdAt, base)
        XCTAssertEqual(
            undone.traces[traceID]?.contentUpdatedAt,
            base.addingTimeInterval(1)
        )
        XCTAssertEqual(
            undone.traces[traceID]?.settledAt,
            base.addingTimeInterval(1)
        )
        XCTAssertEqual(
            undone.traces[traceID]?.draftCancelledOn,
            today
        )
        XCTAssertNotNil(undone.traces[traceID]?.draftCancellationID)
        XCTAssertNoThrow(try undone.snapshot().validateIntegrity())

        let redone = try NoonmarkEngine(snapshot: currentSnapshot)
        try redone.prepareSnapshotUndo(
            replacing: undone.snapshot(),
            now: base.addingTimeInterval(2)
        )
        XCTAssertEqual(redone.chains[chainID]?.state, .active)
        XCTAssertEqual(redone.traces[traceID]?.status, .pending)
        XCTAssertEqual(
            redone.traces[traceID]?.draftCancellationID,
            undone.traces[traceID]?.draftCancellationID
        )
        XCTAssertEqual(redone.getDayTodo(date: today).traces.map(\.id), [
            traceID
        ])
        XCTAssertNoThrow(try redone.snapshot().validateIntegrity())
    }

    func testUndoingScheduleRetainsHiddenTraceAndDayFacts() throws {
        let current = NoonmarkEngine()
        let chainID = try current.createPoolTask(
            title: "撤销排期",
            now: base
        )
        let before = current.snapshot()
        let traceID = try current.scheduleFromPool(
            chainID: chainID,
            date: tomorrow,
            today: today,
            now: base.addingTimeInterval(1)
        )

        let undone = try NoonmarkEngine(snapshot: before)
        try undone.prepareSnapshotUndo(
            replacing: current.snapshot(),
            now: base.addingTimeInterval(2)
        )

        XCTAssertNotNil(undone.days[tomorrow])
        XCTAssertNotNil(undone.traces[traceID])
        XCTAssertEqual(undone.traces[traceID]?.status, .cancelledDraft)
        XCTAssertEqual(undone.chains[chainID]?.createdAt, base)
        XCTAssertEqual(undone.chains[chainID]?.updatedAt, base)
        XCTAssertEqual(
            undone.traces[traceID]?.createdAt,
            base.addingTimeInterval(1)
        )
        XCTAssertEqual(
            undone.traces[traceID]?.contentUpdatedAt,
            base.addingTimeInterval(2)
        )
        XCTAssertEqual(
            undone.traces[traceID]?.settledAt,
            base.addingTimeInterval(2)
        )
        XCTAssertEqual(
            undone.traces[traceID]?.draftCancelledOn,
            tomorrow
        )
        XCTAssertTrue(undone.futurePlans(today: today).isEmpty)
        XCTAssertEqual(undone.taskPool().map(\.chain.id), [chainID])
        XCTAssertNoThrow(try undone.snapshot().validateIntegrity())
    }

    func testUndoingHistoricalRenameRetainsRetiredDefinitionFact() throws {
        let current = NoonmarkEngine()
        let chainID = try current.createPoolTask(
            title: "重命名前",
            now: base
        )
        _ = try current.scheduleFromPool(
            chainID: chainID,
            date: tomorrow,
            today: today,
            now: base.addingTimeInterval(1)
        )
        let before = current.snapshot()
        try current.renameTaskTitle(
            chainID: chainID,
            title: "重命名后",
            today: today,
            now: base.addingTimeInterval(2)
        )
        let renamedDefinitionID = try XCTUnwrap(
            current.definitions.values.first { $0.title == "重命名后" }?.id
        )

        let undone = try NoonmarkEngine(snapshot: before)
        try undone.prepareSnapshotUndo(
            replacing: current.snapshot(),
            now: base.addingTimeInterval(3)
        )

        XCTAssertNotNil(undone.definitions[renamedDefinitionID])
        XCTAssertNotNil(
            undone.definitions[renamedDefinitionID]?.supersededAt
        )
        XCTAssertEqual(
            undone.taskPool().first?.definition.title,
            nil
        )
        XCTAssertEqual(
            undone.futurePlans(today: today).first?.definition.title,
            "重命名前"
        )
        XCTAssertNoThrow(try undone.snapshot().validateIntegrity())
    }

    func testUndoingAddedSubtaskRetainsHiddenSubtaskFact() throws {
        let current = NoonmarkEngine()
        let chainID = try current.createPoolTask(
            title: "撤销新增子任务",
            now: base
        )
        let traceID = try current.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: base.addingTimeInterval(1)
        )
        let before = current.snapshot()
        let subtaskID = try current.addSubtask(
            traceID: traceID,
            title: "应成为隐藏取消事实",
            now: base.addingTimeInterval(2)
        )

        let undone = try NoonmarkEngine(snapshot: before)
        try undone.prepareSnapshotUndo(
            replacing: current.snapshot(),
            now: base.addingTimeInterval(3)
        )

        XCTAssertNotNil(undone.subtasks[subtaskID])
        XCTAssertEqual(
            undone.subtasks[subtaskID]?.status,
            .cancelledDraft
        )
        XCTAssertEqual(
            undone.subtasks[subtaskID]?.updatedAt,
            base.addingTimeInterval(3)
        )
        XCTAssertEqual(
            undone.subtasks[subtaskID]?.settledAt,
            base.addingTimeInterval(3)
        )
        XCTAssertNotNil(
            undone.subtasks[subtaskID]?.draftCancellationID
        )
        XCTAssertFalse(
            try XCTUnwrap(undone.subtasks[subtaskID])
                .isUserPresentable
        )
        XCTAssertEqual(undone.subtaskProgress(for: traceID).total, 0)
        XCTAssertEqual(
            undone.traceProgress(for: traceID).mode,
            .manual
        )
        XCTAssertNoThrow(try undone.snapshot().validateIntegrity())

        let redone = try NoonmarkEngine(snapshot: current.snapshot())
        try redone.prepareSnapshotUndo(
            replacing: undone.snapshot(),
            now: base.addingTimeInterval(4)
        )
        XCTAssertEqual(redone.subtasks[subtaskID]?.status, .pending)
        XCTAssertEqual(
            redone.subtasks[subtaskID]?.updatedAt,
            base.addingTimeInterval(4)
        )
        XCTAssertNil(redone.subtasks[subtaskID]?.settledAt)
        XCTAssertEqual(
            redone.subtasks[subtaskID]?.draftCancellationID,
            undone.subtasks[subtaskID]?.draftCancellationID
        )
        XCTAssertEqual(redone.subtaskProgress(for: traceID).total, 1)
        XCTAssertNoThrow(try redone.snapshot().validateIntegrity())
    }

    func testUndoingContinuationRetainsHiddenTargetLineageForRedo() throws {
        let current = NoonmarkEngine()
        let chainID = try current.createPoolTask(
            title: "撤销延续",
            now: base
        )
        let sourceTraceID = try current.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: base.addingTimeInterval(1)
        )
        let sourceSubtaskID = try current.addSubtask(
            traceID: sourceTraceID,
            title: "跨日子任务",
            now: base.addingTimeInterval(2)
        )
        let before = current.snapshot()
        let targetTraceID = try current.deferCurrentTrace(
            traceID: sourceTraceID,
            targetDate: tomorrow,
            today: today,
            now: base.addingTimeInterval(3)
        )
        let forward = current.snapshot()
        let targetSubtaskID = try XCTUnwrap(
            current.subtasks.values.first {
                $0.traceID == targetTraceID
            }?.id
        )

        let undone = try NoonmarkEngine(snapshot: before)
        try undone.prepareSnapshotUndo(
            replacing: forward,
            now: base.addingTimeInterval(4)
        )

        XCTAssertEqual(undone.traces[sourceTraceID]?.status, .pending)
        XCTAssertEqual(
            undone.chains[chainID]?.updatedAt,
            base.addingTimeInterval(3)
        )
        XCTAssertEqual(
            undone.traces[targetTraceID]?.status,
            .cancelledDraft
        )
        XCTAssertEqual(
            undone.traces[sourceTraceID]?.contentUpdatedAt,
            base.addingTimeInterval(4)
        )
        XCTAssertEqual(
            undone.traces[targetTraceID]?.contentUpdatedAt,
            base.addingTimeInterval(4)
        )
        XCTAssertEqual(
            undone.traces[targetTraceID]?.settledAt,
            base.addingTimeInterval(4)
        )
        XCTAssertEqual(
            undone.traces[targetTraceID]?.carriedFromTraceID,
            sourceTraceID
        )
        XCTAssertEqual(
            undone.subtasks[targetSubtaskID]?.carriedFromSubtaskID,
            sourceSubtaskID
        )
        XCTAssertEqual(
            undone.subtasks[targetSubtaskID]?.status,
            .pending
        )
        XCTAssertTrue(undone.futurePlans(today: today).isEmpty)
        XCTAssertEqual(
            undone.subtaskProgress(for: sourceTraceID).total,
            1
        )
        XCTAssertNoThrow(try undone.snapshot().validateIntegrity())

        let redone = try NoonmarkEngine(snapshot: forward)
        try redone.prepareSnapshotUndo(
            replacing: undone.snapshot(),
            now: base.addingTimeInterval(5)
        )

        XCTAssertEqual(redone.traces[sourceTraceID]?.status, .deferred)
        XCTAssertEqual(redone.traces[targetTraceID]?.status, .pending)
        XCTAssertEqual(
            redone.subtasks[targetSubtaskID]?.carriedFromSubtaskID,
            sourceSubtaskID
        )
        XCTAssertEqual(
            redone.futurePlans(today: today).map(\.trace.id),
            [targetTraceID]
        )
        XCTAssertNoThrow(try redone.snapshot().validateIntegrity())
    }

    func testUndoingChangeTaskRetainsHiddenReplacementFacts() throws {
        let current = NoonmarkEngine()
        let originalChainID = try current.createPoolTask(
            title: "改任务前",
            now: base
        )
        let originalTraceID = try current.scheduleFromPool(
            chainID: originalChainID,
            date: today,
            today: today,
            now: base.addingTimeInterval(1)
        )
        let before = current.snapshot()
        let replacementTraceID = try current.changeTrace(
            traceID: originalTraceID,
            newTitle: "替换任务",
            today: today,
            now: base.addingTimeInterval(2)
        )
        let forward = current.snapshot()
        let replacementChainID = try XCTUnwrap(
            current.traces[replacementTraceID]?.chainID
        )

        let undone = try NoonmarkEngine(snapshot: before)
        try undone.prepareSnapshotUndo(
            replacing: forward,
            now: base.addingTimeInterval(3)
        )

        XCTAssertEqual(undone.traces[originalTraceID]?.status, .pending)
        XCTAssertNil(undone.traces[originalTraceID]?.changedToTraceID)
        XCTAssertEqual(
            undone.traces[replacementTraceID]?.status,
            .cancelledDraft
        )
        XCTAssertEqual(
            undone.chains[replacementChainID]?.state,
            .abandoned
        )
        XCTAssertEqual(
            undone.getDayTodo(date: today).traces.map(\.id),
            [originalTraceID]
        )
        XCTAssertNoThrow(try undone.snapshot().validateIntegrity())

        let redone = try NoonmarkEngine(snapshot: forward)
        try redone.prepareSnapshotUndo(
            replacing: undone.snapshot(),
            now: base.addingTimeInterval(4)
        )

        XCTAssertEqual(redone.traces[originalTraceID]?.status, .changed)
        XCTAssertEqual(
            redone.traces[originalTraceID]?.changedToTraceID,
            replacementTraceID
        )
        XCTAssertEqual(
            redone.traces[replacementTraceID]?.status,
            .pending
        )
        XCTAssertEqual(
            redone.chains[replacementChainID]?.state,
            .active
        )
        XCTAssertEqual(
            redone.getDayTodo(date: today).traces.map(\.id),
            [replacementTraceID]
        )
        XCTAssertEqual(redone.traces[originalTraceID]?.status, .changed)
        XCTAssertNoThrow(try redone.snapshot().validateIntegrity())
    }
}
