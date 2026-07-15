@testable import NoonmarkCore
import XCTest

final class NoonmarkEngineTests: XCTestCase {
    private let day1 = LocalDate("2026-07-05")
    private let day2 = LocalDate("2026-07-06")
    private let day3 = LocalDate("2026-07-07")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSchedulingFromPoolCreatesDayTraceAndRemovesFromTaskPool() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "  写一期规格  ", now: now)

        XCTAssertEqual(engine.taskPool().count, 1)

        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)

        XCTAssertTrue(engine.taskPool().isEmpty)
        XCTAssertEqual(engine.traces[traceID]?.status, .pending)
        XCTAssertEqual(engine.getDayTodo(date: day1).traces.map(\.id), [traceID])
    }

    func testSchedulingFromPoolCannotTargetPastDate() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "不能排期到过去", now: now)

        XCTAssertThrowsError(try engine.scheduleFromPool(chainID: chainID, date: day1, today: day2, now: now))
        XCTAssertEqual(engine.taskPool().map(\.chain.id), [chainID])
        XCTAssertTrue(engine.getDayTodo(date: day1).traces.isEmpty)
    }

    func testTaskTitleRenameAppliesOnlyToEditablePoolCurrentAndFutureTasks() throws {
        let engine = NoonmarkEngine()
        let poolChainID = try engine.createPoolTask(title: "任务池旧标题", now: now)

        try engine.renameTaskTitle(chainID: poolChainID, title: "任务池新标题", today: day1, now: now)
        XCTAssertEqual(engine.taskPool().first?.definition.title, "任务池新标题")

        let currentTraceID = try engine.scheduleFromPool(chainID: poolChainID, date: day1, today: day1, now: now)
        try engine.renameTaskTitle(chainID: poolChainID, title: "今日新标题", today: day1, now: now)
        let currentTrace = try XCTUnwrap(engine.traces[currentTraceID])
        XCTAssertEqual(currentTrace.status, .pending)
        XCTAssertEqual(engine.definitions[currentTrace.definitionID]?.title, "今日新标题")
        XCTAssertTrue(engine.traces.values.allSatisfy { $0.status != .changed })

        let futureChainID = try engine.createPoolTask(title: "未来旧标题", now: now)
        let futureTraceID = try engine.scheduleFromPool(chainID: futureChainID, date: day2, today: day1, now: now)
        try engine.renameTaskTitle(chainID: futureChainID, title: "未来新标题", today: day1, now: now)
        let futureTrace = try XCTUnwrap(engine.traces[futureTraceID])
        XCTAssertEqual(futureTrace.status, .pending)
        XCTAssertEqual(engine.definitions[futureTrace.definitionID]?.title, "未来新标题")
    }

    func testTaskTitleRenameRejectsCompletedAndUnfinishedFacts() throws {
        let engine = NoonmarkEngine()
        let completedChainID = try engine.createPoolTask(title: "完成旧标题", now: now)
        let completedTraceID = try engine.scheduleFromPool(chainID: completedChainID, date: day1, today: day1, now: now)
        try engine.markCompleted(traceID: completedTraceID, today: day1, now: now)

        XCTAssertThrowsError(
            try engine.renameTaskTitle(chainID: completedChainID, title: "完成新标题", today: day1, now: now)
        )

        let unfinishedChainID = try engine.createPoolTask(title: "未完成旧标题", now: now)
        _ = try engine.scheduleFromPool(chainID: unfinishedChainID, date: day1, today: day1, now: now)
        try engine.settleDays(upTo: day2, now: now)

        XCTAssertThrowsError(
            try engine.renameTaskTitle(chainID: unfinishedChainID, title: "未完成新标题", today: day2, now: now)
        )
    }

    func testTaskTitleRenameVersionsCurrentContinuationWithoutRewritingHistory() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "历史标题", now: now)
        let historicalTraceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: day1,
            today: day1,
            now: now
        )
        try engine.settleDays(upTo: day2, now: now)
        let currentTraceID = try engine.continueTrace(
            traceID: historicalTraceID,
            targetDate: day2,
            today: day2,
            now: now
        )

        try engine.renameTaskTitle(
            chainID: chainID,
            title: "当前\n标题",
            today: day2,
            now: now.addingTimeInterval(1)
        )

        let historicalTrace = try XCTUnwrap(engine.traces[historicalTraceID])
        let currentTrace = try XCTUnwrap(engine.traces[currentTraceID])
        XCTAssertEqual(engine.definitions[historicalTrace.definitionID]?.title, "历史标题")
        XCTAssertEqual(engine.definitions[currentTrace.definitionID]?.title, "当前\n标题")
    }

    func testReturnedPoolNotesKeepStableOwnershipAcrossRenameAndReschedule() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "重命名前",
            initialNoteBody: "初始附言",
            now: now
        )
        let originalNoteID = try XCTUnwrap(
            engine.chains[chainID]?.activeNoteEntries.first?.id
        )
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: day1,
            today: day1,
            now: now
        )
        try engine.returnToPool(
            traceID: traceID,
            today: day1,
            now: now.addingTimeInterval(1)
        )
        let deletedNoteID = try engine.appendPoolNote(
            chainID: chainID,
            body: "待删除附言",
            now: now.addingTimeInterval(2)
        )
        try engine.editPoolNote(
            chainID: chainID,
            noteID: originalNoteID,
            body: "编辑后附言",
            now: now.addingTimeInterval(3)
        )
        try engine.deletePoolNote(
            chainID: chainID,
            noteID: deletedNoteID,
            now: now.addingTimeInterval(4)
        )
        let notesBeforeRename = try XCTUnwrap(engine.chains[chainID]?.noteEntries)

        try engine.renameTaskTitle(
            chainID: chainID,
            title: "重命名后",
            today: day1,
            now: now.addingTimeInterval(5)
        )

        XCTAssertEqual(engine.chains[chainID]?.noteEntries, notesBeforeRename)
        XCTAssertEqual(engine.taskPool().first?.definition.title, "重命名后")
        let rescheduledID = try engine.scheduleFromPool(
            chainID: chainID,
            date: day2,
            today: day1,
            now: now.addingTimeInterval(6)
        )
        XCTAssertEqual(
            engine.traces[rescheduledID]?.activeNoteEntries.map(\.body),
            ["编辑后附言"]
        )
        XCTAssertTrue(
            engine.chains[chainID]?.noteEntries.first {
                $0.id == deletedNoteID
            }?.isDeleted == true
        )
    }

    func testTaskPoolRemovalDeletesUnscheduledAndPreservesReturnedHistory() throws {
        let engine = NoonmarkEngine()
        let unscheduledChainID = try engine.createPoolTask(title: "未排期删除", now: now)

        try engine.removeTaskFromPool(chainID: unscheduledChainID, now: now)
        XCTAssertNil(engine.chains[unscheduledChainID])
        XCTAssertTrue(engine.definitions.values.allSatisfy { $0.chainID != unscheduledChainID })

        let returnedChainID = try engine.createPoolTask(title: "回池删除", now: now)
        let returnedTraceID = try engine.scheduleFromPool(chainID: returnedChainID, date: day1, today: day1, now: now)
        try engine.returnToPool(traceID: returnedTraceID, today: day1, now: now)

        try engine.removeTaskFromPool(chainID: returnedChainID, now: now)
        XCTAssertEqual(engine.traces[returnedTraceID]?.status, .returnedToPool)
        XCTAssertEqual(engine.chains[returnedChainID]?.state, .abandoned)
        XCTAssertFalse(engine.taskPool().contains { $0.chain.id == returnedChainID })
    }

    func testCurrentCompletionCanBeUndoneButHistoryCannot() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "完成测试", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)

        try engine.markCompleted(traceID: traceID, today: day1, now: now)
        XCTAssertEqual(engine.traces[traceID]?.status, .completed)

        try engine.undoCompleted(traceID: traceID, today: day1, now: now)
        XCTAssertEqual(engine.traces[traceID]?.status, .pending)

        try engine.markCompleted(traceID: traceID, today: day1, now: now)
        XCTAssertThrowsError(try engine.undoCompleted(traceID: traceID, today: day2, now: now))
    }

    func testSettlingPastDayTurnsPendingIntoUnfinishedAndLocksDay() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "跨日未完成", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)

        try engine.settleDays(upTo: day2, now: now)

        XCTAssertEqual(engine.traces[traceID]?.status, .unfinished)
        XCTAssertNotNil(engine.days[day1]?.lockedAt)
        XCTAssertEqual(engine.unfinishedPool().count, 1)
        XCTAssertEqual(engine.unfinishedPool().first?.unfinishedTraces.map(\.id), [traceID])
    }

    func testContinuationKeepsHistoryAndBlocksDuplicateActiveTrace() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "延续测试", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)
        try engine.settleDays(upTo: day2, now: now)

        let continuedID = try engine.continueTrace(traceID: traceID, targetDate: day2, today: day2, now: now)

        XCTAssertEqual(engine.traces[traceID]?.status, .continued)
        XCTAssertEqual(engine.traces[continuedID]?.status, .pending)
        XCTAssertEqual(engine.traces[continuedID]?.continuationSeq, 1)
        XCTAssertEqual(engine.traces[continuedID]?.continuedFromTraceID, traceID)

        let poolItem = try XCTUnwrap(engine.unfinishedPool().first)
        XCTAssertEqual(poolItem.unfinishedTraces.map(\.id), [traceID])
        XCTAssertEqual(poolItem.activeTrace?.id, continuedID)
        XCTAssertTrue(poolItem.isContinuedPending)

        XCTAssertThrowsError(try engine.continueTrace(traceID: traceID, targetDate: day3, today: day2, now: now))
    }

    func testCurrentPendingContinuationDoesNotEnterUnfinishedPool() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "主动延续当前任务", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)

        let continuedID = try engine.continueTrace(traceID: traceID, targetDate: day2, today: day1, now: now)

        XCTAssertEqual(engine.traces[traceID]?.status, .continued)
        XCTAssertNil(engine.traces[traceID]?.settledAt)
        XCTAssertEqual(engine.traces[continuedID]?.status, .pending)
        XCTAssertTrue(engine.unfinishedPool().isEmpty)
    }

    func testCompletedContinuationRemovesChainFromUnfinishedPoolAndShowsTrajectory() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "完成后移出未完成池", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)
        try engine.settleDays(upTo: day2, now: now)
        let day2TraceID = try engine.continueTrace(traceID: traceID, targetDate: day2, today: day2, now: now)
        try engine.settleDays(upTo: day3, now: now)
        let completedTraceID = try engine.continueTrace(traceID: day2TraceID, targetDate: day3, today: day3, now: now)

        try engine.markCompleted(traceID: completedTraceID, today: day3, now: now)

        XCTAssertTrue(engine.unfinishedPool().isEmpty)
        let completedItem = try XCTUnwrap(engine.completedPool().first)
        XCTAssertEqual(completedItem.trace.id, completedTraceID)
        XCTAssertEqual(completedItem.trajectory.startDate, day1)
        XCTAssertEqual(completedItem.trajectory.continuedDates, [day2, day3])
        XCTAssertEqual(completedItem.trajectory.completedDate, day3)
        XCTAssertEqual(completedItem.trajectory.traces.map(\.id), [traceID, day2TraceID, completedTraceID])
    }

    func testChangingCurrentTracePreservesOldAndCreatesNewDefinitionInSameDay() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "写调研", now: now)
        let oldTraceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)

        let newTraceID = try engine.changeTrace(
            traceID: oldTraceID,
            newTitle: "写调研并输出架构",
            today: day1,
            now: now
        )

        XCTAssertEqual(engine.traces[oldTraceID]?.status, .changed)
        XCTAssertEqual(engine.traces[oldTraceID]?.changedToTraceID, newTraceID)
        XCTAssertEqual(engine.traces[newTraceID]?.status, .pending)
        XCTAssertNotEqual(engine.traces[newTraceID]?.chainID, chainID)
        XCTAssertEqual(engine.getDayTodo(date: day1).traces.count, 2)

        let newDefinitionID = try XCTUnwrap(engine.traces[newTraceID]?.definitionID)
        XCTAssertEqual(engine.definitions[newDefinitionID]?.title, "写调研并输出架构")
        XCTAssertEqual(engine.definitions[newDefinitionID]?.sequence, 1)
    }

    func testChangingNonfinalTraceAppendsWithoutCollidingWithExistingPriorityFacts() throws {
        let engine = NoonmarkEngine()
        let changedChainID = try engine.createPoolTask(title: "需要变更", now: now)
        let middleChainID = try engine.createPoolTask(title: "中间任务", now: now)
        let lastChainID = try engine.createPoolTask(title: "最后任务", now: now)
        let changedTraceID = try engine.scheduleFromPool(
            chainID: changedChainID,
            date: day1,
            today: day1,
            now: now
        )
        let middleTraceID = try engine.scheduleFromPool(
            chainID: middleChainID,
            date: day1,
            today: day1,
            now: now
        )
        let lastTraceID = try engine.scheduleFromPool(
            chainID: lastChainID,
            date: day1,
            today: day1,
            now: now
        )
        let middleFact = try XCTUnwrap(engine.traces[middleTraceID])
        let lastFact = try XCTUnwrap(engine.traces[lastTraceID])

        let replacementTraceID = try engine.changeTrace(
            traceID: changedTraceID,
            newTitle: "变更后的任务",
            today: day1,
            now: now.addingTimeInterval(1)
        )

        XCTAssertEqual(engine.traces[changedTraceID]?.priority, 1)
        XCTAssertEqual(engine.traces[middleTraceID], middleFact)
        XCTAssertEqual(engine.traces[lastTraceID], lastFact)
        XCTAssertEqual(engine.traces[replacementTraceID]?.priority, 4)
        XCTAssertEqual(
            engine.getDayTodo(date: day1).traces.map(\.priority),
            [1, 2, 3, 4]
        )
    }

    func testCurrentReturnToPoolLeavesTraceAndMakesChainSchedulableAgain() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "回池测试", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)

        try engine.returnToPool(traceID: traceID, today: day1, now: now)

        XCTAssertEqual(engine.traces[traceID]?.status, .returnedToPool)
        XCTAssertEqual(engine.taskPool().map(\.chain.id), [chainID])

        let rescheduledID = try engine.scheduleFromPool(chainID: chainID, date: day2, today: day1, now: now)
        XCTAssertEqual(engine.traces[rescheduledID]?.status, .pending)
        XCTAssertTrue(engine.taskPool().isEmpty)
    }

    func testFuturePlanCanMoveAndReturnToPoolButCannotComplete() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "未来计划", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day3, today: day1, now: now)

        XCTAssertEqual(engine.futurePlans(today: day1).map(\.trace.id), [traceID])
        XCTAssertThrowsError(try engine.markCompleted(traceID: traceID, today: day1, now: now))

        try engine.rescheduleFuturePlan(traceID: traceID, targetDate: day2, today: day1, now: now)
        XCTAssertEqual(engine.traces[traceID]?.date, day2)
        XCTAssertNotNil(engine.days[day2])

        _ = try engine.addSubtask(traceID: traceID, title: "未来计划子任务", now: now)

        try engine.returnToPool(traceID: traceID, today: day1, now: now)
        XCTAssertNil(engine.traces[traceID])
        XCTAssertTrue(engine.subtasks.isEmpty)
        XCTAssertEqual(engine.taskPool().map(\.chain.id), [chainID])
    }

    func testContinuationCopiesOnlyOpenSubtasks() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "子任务延续", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)
        let doneSubtaskID = try engine.addSubtask(traceID: traceID, title: "已完成子任务", now: now)
        _ = try engine.addSubtask(traceID: traceID, title: "未完成子任务", now: now)
        try engine.completeSubtask(doneSubtaskID, today: day1, now: now)
        try engine.settleDays(upTo: day2, now: now)

        let continuedID = try engine.continueTrace(traceID: traceID, targetDate: day2, today: day2, now: now)
        let copied = engine.subtasks.values.filter { $0.traceID == continuedID }

        XCTAssertEqual(copied.map(\.title), ["未完成子任务"])
    }

    func testCurrentDayCompletedSubtaskCanBeUndone() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "当天子任务撤回", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)
        let subtaskID = try engine.addSubtask(traceID: traceID, title: "先完成再撤回", now: now)

        try engine.completeSubtask(subtaskID, today: day1, now: now)
        XCTAssertEqual(engine.subtasks[subtaskID]?.status, .completed)
        XCTAssertNotNil(engine.subtasks[subtaskID]?.completedAt)

        try engine.undoCompletedSubtask(subtaskID, today: day1)

        XCTAssertEqual(engine.subtasks[subtaskID]?.status, .pending)
        XCTAssertNil(engine.subtasks[subtaskID]?.completedAt)
        XCTAssertEqual(engine.subtaskProgress(for: traceID).pending, 1)
    }

    func testHistoricalCompletedSubtaskCannotBeUndone() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "历史子任务锁定", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)
        let subtaskID = try engine.addSubtask(traceID: traceID, title: "历史完成项", now: now)

        try engine.completeSubtask(subtaskID, today: day1, now: now)

        XCTAssertThrowsError(try engine.undoCompletedSubtask(subtaskID, today: day2))
        XCTAssertEqual(engine.subtasks[subtaskID]?.status, .completed)
        XCTAssertNotNil(engine.subtasks[subtaskID]?.completedAt)
    }

    func testParentTraceCannotCompleteWithOpenSubtasksAndShowsPartialProgress() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "大任务", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)
        let completedSubtaskID = try engine.addSubtask(traceID: traceID, title: "已做部分", now: now)
        let openSubtaskID = try engine.addSubtask(traceID: traceID, title: "未做部分", now: now)

        try engine.completeSubtask(completedSubtaskID, today: day1, now: now)

        let progress = engine.subtaskProgress(for: traceID)
        XCTAssertEqual(progress.total, 2)
        XCTAssertEqual(progress.completed, 1)
        XCTAssertEqual(progress.pending, 1)
        XCTAssertTrue(progress.isPartiallyCompleted)
        XCTAssertThrowsError(try engine.markCompleted(traceID: traceID, today: day1, now: now))

        try engine.abandonSubtask(openSubtaskID, today: day1, now: now)
        try engine.markCompleted(traceID: traceID, today: day1, now: now)

        XCTAssertEqual(engine.traces[traceID]?.status, .completed)
    }

    func testCompletedPoolShowsSubtaskTrajectoriesAcrossDays() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "跨日大任务", now: now)
        let day1TraceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)
        let designSubtaskID = try engine.addSubtask(traceID: day1TraceID, title: "设计登录态", now: now)
        let ssoSubtaskID = try engine.addSubtask(traceID: day1TraceID, title: "接入 SSO", now: now)

        try engine.completeSubtask(designSubtaskID, today: day1, now: now)
        try engine.settleDays(upTo: day2, now: now)
        let day2TraceID = try engine.continueTrace(traceID: day1TraceID, targetDate: day2, today: day2, now: now)
        let copiedSSO = try XCTUnwrap(engine.subtasks.values.first { $0.traceID == day2TraceID })

        try engine.completeSubtask(copiedSSO.id, today: day2, now: now)
        try engine.markCompleted(traceID: day2TraceID, today: day2, now: now)

        XCTAssertEqual(engine.subtasks[ssoSubtaskID]?.status, .continued)
        XCTAssertEqual(copiedSSO.lineageID, engine.subtasks[ssoSubtaskID]?.lineageID)
        XCTAssertEqual(copiedSSO.continuedFromSubtaskID, ssoSubtaskID)

        let completedItem = try XCTUnwrap(engine.completedPool().first)
        let subtaskTrajectories = completedItem.trajectory.subtaskTrajectories
        let designTrajectory = try XCTUnwrap(subtaskTrajectories.first { $0.title == "设计登录态" })
        let ssoTrajectory = try XCTUnwrap(subtaskTrajectories.first { $0.title == "接入 SSO" })

        XCTAssertEqual(designTrajectory.startDate, day1)
        XCTAssertEqual(designTrajectory.continuedDates, [])
        XCTAssertEqual(designTrajectory.completedDate, day1)
        XCTAssertEqual(ssoTrajectory.startDate, day1)
        XCTAssertEqual(ssoTrajectory.continuedDates, [day2])
        XCTAssertEqual(ssoTrajectory.completedDate, day2)
        XCTAssertEqual(ssoTrajectory.records.map(\.date), [day1, day2])
    }

    func testCompletedSubtaskRecordsExposeCurrentCompletedPoolProjection() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "审阅 onboarding 三屏文案", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)
        let subtaskID = try engine.addSubtask(traceID: traceID, title: "首屏标题与副标题", difficulty: .medium, now: now)

        try engine.completeSubtask(subtaskID, today: day1, now: now)

        let record = try XCTUnwrap(engine.completedSubtaskRecords().first)
        XCTAssertEqual(record.date, day1)
        XCTAssertEqual(record.subtask.id, subtaskID)
        XCTAssertEqual(record.subtask.difficulty, .medium)
        XCTAssertEqual(record.parentTrace.id, traceID)
        XCTAssertEqual(record.parentDefinition.title, "审阅 onboarding 三屏文案")
    }

    func testAbandonedChainStaysInUnfinishedPoolAndCanBeReenabledInPlace() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "暂停但不删除的任务", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)
        let subtaskID = try engine.addSubtask(traceID: traceID, title: "保留开放子任务", now: now)

        try engine.abandonChain(from: traceID, now: now)

        let abandonedItem = try XCTUnwrap(engine.unfinishedPool().first)
        XCTAssertEqual(abandonedItem.chain.id, chainID)
        XCTAssertEqual(abandonedItem.chain.state, .abandoned)
        XCTAssertEqual(abandonedItem.unfinishedTraces.map(\.status), [.abandoned])

        let reenabledTraceID = try engine.reactivateAbandonedChain(
            from: traceID,
            today: day2,
            now: now
        )

        XCTAssertEqual(engine.chains[chainID]?.state, .active)
        XCTAssertEqual(reenabledTraceID, traceID)
        XCTAssertEqual(engine.traces[traceID]?.status, .unfinished)
        XCTAssertNil(engine.traces[traceID]?.continuedFromTraceID)
        XCTAssertEqual(engine.traces.count, 1)
        XCTAssertEqual(engine.subtasks[subtaskID]?.status, .pending)
        XCTAssertNil(engine.unfinishedPool().first?.activeTrace)
        XCTAssertEqual(engine.unfinishedPool().first?.unfinishedTraces.map(\.id), [traceID])
    }

    func testTraceDescriptionAndNoteAreEditableOnlyBeforeHistoryLocks() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "整理 OKR",
            descriptionText: "汇总目标",
            initialNoteBody: "等数据看板",
            now: now
        )
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)

        XCTAssertEqual(engine.traces[traceID]?.descriptionText, "汇总目标")
        let noteID = try XCTUnwrap(engine.traces[traceID]?.activeNoteEntries.first?.id)
        XCTAssertEqual(engine.traces[traceID]?.activeNoteEntries.map(\.body), ["等数据看板"])

        try engine.updateTraceText(
            traceID: traceID,
            descriptionText: "收敛成 3 个 O",
            today: day1,
            now: now
        )
        try engine.editTraceNote(
            traceID: traceID,
            noteID: noteID,
            body: "下午确认 KR",
            today: day1,
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(engine.traces[traceID]?.descriptionText, "收敛成 3 个 O")
        XCTAssertEqual(engine.traces[traceID]?.activeNoteEntries.map(\.body), ["下午确认 KR"])
        XCTAssertEqual(engine.definitions[engine.traces[traceID]!.definitionID]?.descriptionText, "汇总目标")

        try engine.settleDays(upTo: day2, now: now)
        XCTAssertThrowsError(
            try engine.updateTraceText(traceID: traceID, descriptionText: "历史改写", today: day2)
        )
        XCTAssertThrowsError(
            try engine.deleteTraceNote(
                traceID: traceID,
                noteID: noteID,
                today: day2,
                now: now.addingTimeInterval(2)
            )
        )
    }

    func testTraceNoteCanBeEditedWithoutChangingEntryIdentity() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "整理 OKR",
            initialNoteBody: "等数据看板",
            now: now
        )
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: day1,
            today: day1,
            now: now
        )
        let original = try XCTUnwrap(engine.traces[traceID]?.noteEntries.first)
        let editedAt = now.addingTimeInterval(60)

        try engine.editTraceNote(
            traceID: traceID,
            noteID: original.id,
            body: "下午确认 KR",
            today: day1,
            now: editedAt
        )

        let edited = try XCTUnwrap(engine.traces[traceID]?.noteEntries.first)
        XCTAssertEqual(edited.id, original.id)
        XCTAssertEqual(edited.body, "下午确认 KR")
        XCTAssertEqual(edited.createdAt, original.createdAt)
        XCTAssertEqual(edited.updatedAt, editedAt)
    }

    func testDeletingOneTraceNotePreservesOtherEntriesAndCreatesATombstone() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "整理 OKR",
            initialNoteBody: "等数据看板",
            now: now
        )
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: day1,
            today: day1,
            now: now
        )
        let firstID = try XCTUnwrap(engine.traces[traceID]?.activeNoteEntries.first?.id)
        let secondID = try engine.appendTraceNote(
            traceID: traceID,
            body: "确认 KR 口径",
            today: day1,
            now: now.addingTimeInterval(30)
        )
        let deletedAt = now.addingTimeInterval(60)

        try engine.deleteTraceNote(
            traceID: traceID,
            noteID: firstID,
            today: day1,
            now: deletedAt
        )
        XCTAssertThrowsError(
            try engine.editTraceNote(
                traceID: traceID,
                noteID: firstID,
                body: "不允许复活",
                today: day1,
                now: deletedAt.addingTimeInterval(1)
            )
        )

        let trace = try XCTUnwrap(engine.traces[traceID])
        XCTAssertEqual(trace.activeNoteEntries.map(\.id), [secondID])
        XCTAssertEqual(trace.activeNoteEntries.map(\.body), ["确认 KR 口径"])
        let tombstone = try XCTUnwrap(trace.noteEntries.first(where: { $0.id == firstID }))
        XCTAssertEqual(tombstone.body, "")
        XCTAssertEqual(tombstone.deletedAt, deletedAt)
        XCTAssertEqual(tombstone.updatedAt, deletedAt)
    }

    func testPoolNotesCanBeAppendedEditedAndDeletedByStableIdentity() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "整理任务池",
            initialNoteBody: "先确认范围",
            now: now
        )
        let originalID = try XCTUnwrap(engine.taskPool().first?.chain.activeNoteEntries.first?.id)
        let secondID = try engine.appendPoolNote(
            chainID: chainID,
            body: "再安排日期",
            now: now.addingTimeInterval(30)
        )

        try engine.editPoolNote(
            chainID: chainID,
            noteID: originalID,
            body: "先确认最终范围",
            now: now.addingTimeInterval(60)
        )
        try engine.deletePoolNote(
            chainID: chainID,
            noteID: secondID,
            now: now.addingTimeInterval(90)
        )

        let chain = try XCTUnwrap(engine.taskPool().first?.chain)
        XCTAssertEqual(chain.activeNoteEntries.map(\.id), [originalID])
        XCTAssertEqual(chain.activeNoteEntries.map(\.body), ["先确认最终范围"])
        XCTAssertEqual(chain.noteEntries.first(where: { $0.id == secondID })?.body, "")
        XCTAssertEqual(
            chain.noteEntries.first(where: { $0.id == secondID })?.deletedAt,
            now.addingTimeInterval(90)
        )
        XCTAssertEqual(chain.updatedAt, now)
    }

    func testTaskChainEncodingMatchesCurrentStructuredNoteOwnership() throws {
        let engine = NoonmarkEngine()
        _ = try engine.createPoolTask(
            title: "整理任务池",
            initialNoteBody: "先确认范围",
            now: now
        )
        let chain = try XCTUnwrap(engine.taskPool().first?.chain)
        let definition = try XCTUnwrap(engine.taskPool().first?.definition)

        let data = try JSONEncoder().encode(chain)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(
            Set(object.keys),
            ["id", "state", "noteEntries", "createdAt", "updatedAt"]
        )
        let definitionObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(definition)
            ) as? [String: Any]
        )
        XCTAssertEqual(
            Set(definitionObject.keys),
            [
                "id", "chainID", "sequence", "title", "plannedSubtasks",
                "createdAt", "contentUpdatedAt"
            ]
        )
    }

    func testSnapshotRejectsDuplicateNoteIdentityWithinOneOwner() throws {
        let engine = NoonmarkEngine()
        _ = try engine.createPoolTask(
            title: "整理任务池",
            initialNoteBody: "先确认范围",
            now: now
        )
        var snapshot = engine.snapshot()
        let note = try XCTUnwrap(snapshot.chains.first?.noteEntries.first)
        snapshot.chains[0].noteEntries.append(note)

        XCTAssertThrowsError(try NoonmarkEngine(snapshot: snapshot)) { error in
            XCTAssertEqual(
                error as? NoonmarkError,
                .invalidInput("task chain contains duplicate task note identities")
            )
        }
    }

    func testSnapshotUndoIsReclockedAsANewForwardContentMutation() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "撤销前标题", now: now)
        let undoSnapshot = engine.snapshot()
        try engine.updatePoolTask(
            chainID: chainID,
            title: "撤销前的较新标题",
            now: now.addingTimeInterval(10)
        )

        let candidate = try NoonmarkEngine(snapshot: undoSnapshot)
        try candidate.prepareSnapshotUndo(
            replacing: engine.snapshot(),
            now: now.addingTimeInterval(20)
        )
        let restored = try XCTUnwrap(candidate.snapshot().definitions.first)

        XCTAssertEqual(restored.title, "撤销前标题")
        XCTAssertEqual(restored.contentUpdatedAt, now.addingTimeInterval(20))
    }

    func testContentClockIgnoresNoOpAndRejectsBackwardsMutation() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "保持标题",
            descriptionText: "保持描述",
            now: now
        )

        try engine.updatePoolTask(
            chainID: chainID,
            title: "保持标题",
            descriptionText: "保持描述",
            now: now.addingTimeInterval(20)
        )
        XCTAssertEqual(
            engine.taskPool().first?.definition.contentUpdatedAt,
            now
        )

        XCTAssertThrowsError(
            try engine.updatePoolTask(
                chainID: chainID,
                title: "倒退写入",
                descriptionText: "保持描述",
                now: now.addingTimeInterval(-1)
            )
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkError,
                .invalidInput("content mutation time cannot move backwards")
            )
        }
        XCTAssertEqual(engine.taskPool().first?.definition.title, "保持标题")
        XCTAssertEqual(engine.taskPool().first?.definition.contentUpdatedAt, now)
    }

    func testDaySettlementFailsAtomicallyWhenItsClockWouldMoveBackwards() throws {
        let engine = NoonmarkEngine()
        let createdAt = now.addingTimeInterval(10)
        let chainID = try engine.createPoolTask(title: "等待结算", now: createdAt)
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: day1,
            today: day1,
            now: createdAt
        )

        XCTAssertThrowsError(
            try engine.settleDays(upTo: day2, now: now)
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkError,
                .invalidInput("day settlement time cannot move backwards")
            )
        }
        XCTAssertEqual(engine.traces[traceID]?.status, .pending)
        XCTAssertNil(engine.traces[traceID]?.settledAt)
        XCTAssertNil(engine.days[day1]?.lockedAt)
    }

    func testSnapshotUndoCarriesStructuredNoteHistoryForward() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "附言撤销边界",
            initialNoteBody: "初始附言",
            now: now
        )
        let unsafeUndoSnapshot = engine.snapshot()
        _ = try engine.appendPoolNote(
            chainID: chainID,
            body: "后来附言",
            now: now.addingTimeInterval(10)
        )
        let candidate = try NoonmarkEngine(snapshot: unsafeUndoSnapshot)

        try candidate.prepareSnapshotUndo(
            replacing: engine.snapshot(),
            now: now.addingTimeInterval(20)
        )

        XCTAssertEqual(
            candidate.chains[chainID]?.activeNoteEntries.map(\.body),
            ["初始附言", "后来附言"]
        )
    }

    func testTaskNoteEntryDecodeRejectsAnUnnormalizedActiveBody() throws {
        let note = try TaskNoteEntry(body: "有效附言", now: now)
        let encoded = try JSONEncoder().encode(note)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["body"] = "  未规范化附言  "
        let malformed = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(TaskNoteEntry.self, from: malformed))
    }

    func testTaskNoteEntryDecodeRejectsInvalidVersionTimeAndTombstone() throws {
        let note = try TaskNoteEntry(body: "有效附言", now: now)
        let encoded = try JSONEncoder().encode(note)
        let validObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        var backwardsTime = validObject
        backwardsTime["updatedAt"] = now.timeIntervalSinceReferenceDate - 1
        let backwardsTimeData = try JSONSerialization.data(withJSONObject: backwardsTime)
        XCTAssertThrowsError(try JSONDecoder().decode(TaskNoteEntry.self, from: backwardsTimeData))

        var invalidTombstone = validObject
        invalidTombstone["deletedAt"] = now.timeIntervalSinceReferenceDate
        let invalidTombstoneData = try JSONSerialization.data(withJSONObject: invalidTombstone)
        XCTAssertThrowsError(try JSONDecoder().decode(TaskNoteEntry.self, from: invalidTombstoneData))
    }

    func testTaskNoteEntryTombstoneRoundTripsThroughTheRestoreSeam() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "持久化墓碑",
            initialNoteBody: "删除前",
            now: now
        )
        let noteID = try XCTUnwrap(
            engine.taskPool().first?.chain.activeNoteEntries.first?.id
        )
        try engine.deletePoolNote(
            chainID: chainID,
            noteID: noteID,
            now: now.addingTimeInterval(1)
        )
        let tombstone = try XCTUnwrap(
            engine.taskPool().first?.chain.noteEntries.first
        )

        let restored = try JSONDecoder().decode(
            TaskNoteEntry.self,
            from: JSONEncoder().encode(tombstone)
        )

        XCTAssertEqual(restored, tombstone)
    }

    func testTaskNoteEntryValidatorReportsDuplicateIdentity() throws {
        let note = try TaskNoteEntry(body: "有效附言", now: now)

        XCTAssertEqual(
            TaskNoteEntryValidator.firstIssue(in: [note, note]),
            .duplicateIdentity
        )
    }

    func testNoteMutationRejectsTimeBeforeTheEntryVersion() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "整理任务池",
            initialNoteBody: "先确认范围",
            now: now
        )
        let noteID = try XCTUnwrap(engine.taskPool().first?.chain.activeNoteEntries.first?.id)

        XCTAssertThrowsError(
            try engine.editPoolNote(
                chainID: chainID,
                noteID: noteID,
                body: "倒序修改",
                now: now.addingTimeInterval(-1)
            )
        )
        XCTAssertEqual(
            engine.taskPool().first?.chain.activeNoteEntries.map(\.body),
            ["先确认范围"]
        )
    }

    func testAppendingNoteRejectsNonfiniteOrOwnerPredatingTime() throws {
        let poolEngine = NoonmarkEngine()
        let poolChainID = try poolEngine.createPoolTask(
            title: "任务池附言时间",
            now: now
        )

        XCTAssertThrowsError(
            try poolEngine.appendPoolNote(
                chainID: poolChainID,
                body: "倒序附言",
                now: now.addingTimeInterval(-1)
            )
        )
        XCTAssertThrowsError(
            try poolEngine.appendPoolNote(
                chainID: poolChainID,
                body: "无限时间附言",
                now: Date(timeIntervalSinceReferenceDate: .infinity)
            )
        )
        XCTAssertTrue(poolEngine.taskPool().first?.chain.noteEntries.isEmpty == true)

        let traceEngine = NoonmarkEngine()
        let traceChainID = try traceEngine.createPoolTask(title: "轨迹附言时间", now: now)
        let traceID = try traceEngine.scheduleFromPool(
            chainID: traceChainID,
            date: day1,
            today: day1,
            now: now
        )
        XCTAssertThrowsError(
            try traceEngine.appendTraceNote(
                traceID: traceID,
                body: "早于轨迹的附言",
                today: day1,
                now: now.addingTimeInterval(-1)
            )
        )
        XCTAssertTrue(traceEngine.traces[traceID]?.noteEntries.isEmpty == true)
    }

    func testPoolPlannedSubtasksAreCopiedWhenScheduled() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "规划发布任务", now: now)
        let outlineID = try engine.addPlannedSubtask(
            chainID: chainID,
            title: "写发布大纲",
            difficulty: .medium,
            now: now
        )
        _ = try engine.addPlannedSubtask(
            chainID: chainID,
            title: "核对截图",
            difficulty: .hard,
            now: now
        )
        try engine.updatePlannedSubtaskDifficulty(
            chainID: chainID,
            plannedSubtaskID: outlineID,
            difficulty: .simple,
            now: now
        )

        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)
        let subtasks = engine.subtasks.values
            .filter { $0.traceID == traceID }
            .sorted { $0.position < $1.position }

        XCTAssertEqual(subtasks.map(\.title), ["写发布大纲", "核对截图"])
        XCTAssertEqual(subtasks.map(\.difficulty), [.simple, .hard])
        XCTAssertThrowsError(
            try engine.addPlannedSubtask(chainID: chainID, title: "排期后不能改规划", now: now)
        )
    }

    func testManualProgressCarriesForwardAndCannotRegressAfterContinuation() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "整理 Q3 OKR 草案", now: now)
        let day1TraceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)

        try engine.setManualProgress(traceID: day1TraceID, percent: 35, today: day1, now: now)
        try engine.settleDays(upTo: day2, now: now)
        let day2TraceID = try engine.continueTrace(traceID: day1TraceID, targetDate: day2, today: day2, now: now)

        XCTAssertEqual(engine.traceProgress(for: day2TraceID).floorPercent, 35)
        XCTAssertEqual(engine.traceProgress(for: day2TraceID).percent, 35)

        try engine.setManualProgress(traceID: day2TraceID, percent: 10, today: day2, now: now)
        XCTAssertEqual(engine.traceProgress(for: day2TraceID).percent, 35)

        try engine.setManualProgress(traceID: day2TraceID, percent: 60, today: day2, now: now)
        XCTAssertEqual(engine.traceProgress(for: day2TraceID).percent, 60)
    }

    func testWeightedSubtaskProgressUsesDifficultyAndBlocksManualProgress() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "制作发布会主视觉", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)
        let simpleID = try engine.addSubtask(traceID: traceID, title: "收集视觉参考", difficulty: .simple, now: now)
        _ = try engine.addSubtask(traceID: traceID, title: "出 3 版草图", difficulty: .hard, now: now)

        XCTAssertThrowsError(try engine.setManualProgress(traceID: traceID, percent: 50, today: day1))

        try engine.completeSubtask(simpleID, today: day1, now: now)

        let progress = engine.traceProgress(for: traceID)
        XCTAssertEqual(progress.mode, .weightedSubtasks)
        XCTAssertEqual(progress.completedWeight, 1)
        XCTAssertEqual(progress.totalWeight, 4)
        XCTAssertEqual(progress.percent, 25)
    }

    func testSubtaskDifficultyCanOnlyChangeOnCurrentPendingParentTrace() throws {
        let engine = NoonmarkEngine()
        let currentChainID = try engine.createPoolTask(title: "今天调整难度", now: now)
        let currentTraceID = try engine.scheduleFromPool(chainID: currentChainID, date: day1, today: day1, now: now)
        let currentSubtaskID = try engine.addSubtask(traceID: currentTraceID, title: "今天待调整", now: now)

        try engine.updateSubtaskDifficulty(currentSubtaskID, difficulty: .hard, today: day1)
        XCTAssertEqual(engine.subtasks[currentSubtaskID]?.difficulty, .hard)

        let historicalChainID = try engine.createPoolTask(title: "历史难度锁定", now: now)
        let historicalTraceID = try engine.scheduleFromPool(chainID: historicalChainID, date: day1, today: day1, now: now)
        let historicalSubtaskID = try engine.addSubtask(traceID: historicalTraceID, title: "历史不可调整", now: now)

        XCTAssertThrowsError(try engine.updateSubtaskDifficulty(historicalSubtaskID, difficulty: .medium, today: day2))
        XCTAssertEqual(engine.subtasks[historicalSubtaskID]?.difficulty, .simple)

        let completedParentChainID = try engine.createPoolTask(title: "父任务完成后锁定", now: now)
        let completedParentTraceID = try engine.scheduleFromPool(
            chainID: completedParentChainID,
            date: day1,
            today: day1,
            now: now
        )
        let completedParentSubtaskID = try engine.addSubtask(
            traceID: completedParentTraceID,
            title: "父任务完成后不可调整",
            now: now
        )

        try engine.completeSubtask(completedParentSubtaskID, today: day1, now: now)
        try engine.markCompleted(traceID: completedParentTraceID, today: day1, now: now)

        XCTAssertThrowsError(
            try engine.updateSubtaskDifficulty(completedParentSubtaskID, difficulty: .medium, today: day1)
        )
        XCTAssertEqual(engine.subtasks[completedParentSubtaskID]?.difficulty, .simple)
    }

    func testCalendarSummaryCalculatesCurrentHeatProjection() throws {
        let engine = NoonmarkEngine()
        let first = try engine.createPoolTask(title: "完成项", now: now)
        let second = try engine.createPoolTask(title: "待办项", now: now)
        let doneTrace = try engine.scheduleFromPool(chainID: first, date: day1, today: day1, now: now)
        _ = try engine.scheduleFromPool(chainID: second, date: day1, today: day1, now: now)

        try engine.markCompleted(traceID: doneTrace, today: day1, now: now)

        let summary = engine.calendarSummary(for: day1)
        XCTAssertEqual(summary.total, 2)
        XCTAssertEqual(summary.completed, 1)
        XCTAssertEqual(summary.pending, 1)
        XCTAssertEqual(summary.heatLevel, 1)
    }

    func testSettingsPreferencesExposeCurrentDefaultsAndSyncOptions() throws {
        let engine = NoonmarkEngine()

        XCTAssertEqual(engine.preferences.theme, .coolGray)
        XCTAssertEqual(engine.preferences.language, .chinese)
        XCTAssertEqual(engine.preferences.dataMode, .localFirst)
        XCTAssertEqual(engine.preferences.backupPolicy, ScheduledBackupPolicy())
        XCTAssertEqual(engine.preferences.localFirstSyncPolicy.endpoint, .iCloud)
        XCTAssertEqual(engine.preferences.localFirstSyncPolicy.snapshotRetention.indexRetentionDays, 180)
        XCTAssertEqual(engine.syncEndpointOptions().map(\.kind), [.customEndpoint, .iCloud, .s3, .webDAV, .localFolder])
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: engine.syncEndpointOptions().map { ($0.kind, $0.availability) }),
            [
                .customEndpoint: .planned,
                .iCloud: .available,
                .s3: .planned,
                .webDAV: .planned,
                .localFolder: .available
            ]
        )

        engine.updateTheme(.warmPaper)
        engine.updateLanguage(.english)
        engine.updateDataMode(.onlineFirst)
        engine.updateBackupPolicy(ScheduledBackupPolicy(frequency: .daily, destination: .s3))
        engine.updateLocalFirstSyncPolicy(
            LocalFirstCloudSyncPolicy(
                endpoint: .s3,
                mode: .automatic,
                intervalSeconds: 60,
                snapshotRetention: SyncSnapshotRetentionPolicy(indexRetentionDays: 90, retentionIndexesDaily: 3)
            )
        )

        XCTAssertEqual(engine.preferences.theme, .warmPaper)
        XCTAssertEqual(engine.preferences.language, .english)
        XCTAssertEqual(engine.preferences.dataMode, .onlineFirst)
        XCTAssertEqual(engine.preferences.backupPolicy.frequency, .daily)
        XCTAssertEqual(engine.preferences.backupPolicy.destination, .s3)
        XCTAssertEqual(engine.preferences.localFirstSyncPolicy.endpoint, .s3)
        XCTAssertEqual(engine.preferences.localFirstSyncPolicy.mode, .automatic)
        XCTAssertEqual(engine.preferences.localFirstSyncPolicy.snapshotRetention.retentionIndexesDaily, 3)

        engine.updateDataMode(.localFirst)
        XCTAssertEqual(engine.preferences.backupPolicy, ScheduledBackupPolicy())
    }

    func testSnapshotCodableRoundTripsForDataPackage() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "导出导入数据包",
            descriptionText: "验证 JSON 数据包能恢复核心状态。",
            initialNoteBody: "第一期手动数据交换。",
            now: now
        )
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)
        _ = try engine.addSubtask(traceID: traceID, title: "覆盖 snapshot Codable", difficulty: .medium, now: now)
        engine.updateDailyReview(
            date: day1,
            summary: "导出前状态完整。",
            unfinishedReason: "无。",
            tomorrowNote: "导入后继续验证。",
            now: now
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(engine.snapshot())

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try NoonmarkEngine(snapshot: decoder.decode(NoonmarkSnapshot.self, from: data))

        XCTAssertEqual(restored.snapshot(), engine.snapshot())
    }

    func testTaskTitlesPreserveSoftAndMarkdownHardLineBreaks() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "  第一行\n第二行  \r\n第三行  ",
            now: now
        )

        XCTAssertEqual(engine.taskPool().first?.definition.title, "第一行\n第二行  \n第三行")

        try engine.renameTaskTitle(
            chainID: chainID,
            title: "更新\n\n后的标题",
            today: day1,
            now: now
        )
        XCTAssertEqual(engine.taskPool().first?.definition.title, "更新\n\n后的标题")
    }

    func testParentCompletionReportsTypedErrorWhileSubtasksRemainOpen() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "父任务", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)
        _ = try engine.addSubtask(traceID: traceID, title: "未完成子任务", now: now)

        XCTAssertThrowsError(try engine.markCompleted(traceID: traceID, today: day1, now: now)) { error in
            XCTAssertEqual(error as? NoonmarkError, .openSubtasksPreventCompletion)
            XCTAssertEqual(error.localizedDescription, "还有未完成子任务，完成全部子任务后才能完成父任务")
        }
        XCTAssertEqual(engine.traces[traceID]?.status, .pending)
    }

    func testLockedDayCannotBeReopenedWhenTheObservedNaturalDayMovesBackward() throws {
        let engine = NoonmarkEngine()
        let completedChainID = try engine.createPoolTask(title: "已完成", now: now)
        let completedTraceID = try engine.scheduleFromPool(
            chainID: completedChainID,
            date: day1,
            today: day1,
            now: now
        )
        try engine.markCompleted(
            traceID: completedTraceID,
            today: day1,
            now: now.addingTimeInterval(1)
        )
        try engine.settleDays(upTo: day2, now: now.addingTimeInterval(2))

        XCTAssertThrowsError(
            try engine.undoCompleted(
                traceID: completedTraceID,
                today: day1,
                now: now.addingTimeInterval(3)
            )
        )
        XCTAssertThrowsError(
            try engine.updatePriority(
                traceID: completedTraceID,
                newPriority: 9,
                today: day1,
                now: now.addingTimeInterval(3)
            )
        )

        let poolChainID = try engine.createPoolTask(
            title: "不能塞回已锁日",
            now: now.addingTimeInterval(3)
        )
        XCTAssertThrowsError(
            try engine.scheduleFromPool(
                chainID: poolChainID,
                date: day1,
                today: day1,
                now: now.addingTimeInterval(4)
            )
        ) { error in
            XCTAssertEqual(error as? NoonmarkError, .immutableHistory)
        }
        XCTAssertEqual(engine.traces[completedTraceID]?.status, .completed)
        XCTAssertEqual(engine.traces[completedTraceID]?.priority, 1)
        XCTAssertTrue(engine.taskPool().contains { $0.chain.id == poolChainID })
    }

    func testDayTraceReorderProducesContiguousStablePriorities() throws {
        let engine = NoonmarkEngine()
        let firstChain = try engine.createPoolTask(title: "第一项", now: now)
        let secondChain = try engine.createPoolTask(title: "第二项", now: now)
        let thirdChain = try engine.createPoolTask(title: "第三项", now: now)
        let first = try engine.scheduleFromPool(
            chainID: firstChain,
            date: day1,
            today: day1,
            now: now
        )
        let second = try engine.scheduleFromPool(
            chainID: secondChain,
            date: day1,
            today: day1,
            now: now
        )
        let third = try engine.scheduleFromPool(
            chainID: thirdChain,
            date: day1,
            today: day1,
            now: now
        )

        try engine.reorderDayTrace(
            third,
            before: first,
            today: day1,
            now: now.addingTimeInterval(1)
        )

        XCTAssertEqual(
            engine.getDayTodo(date: day1).traces.map(\.id),
            [third, first, second]
        )
        XCTAssertEqual(
            engine.getDayTodo(date: day1).traces.map(\.priority),
            [1, 2, 3]
        )
    }

    func testPendingDayTraceReorderPreservesTerminalPriorityFact() throws {
        let engine = NoonmarkEngine()
        let firstChain = try engine.createPoolTask(title: "第一项", now: now)
        let completedChain = try engine.createPoolTask(title: "完成项", now: now)
        let thirdChain = try engine.createPoolTask(title: "第三项", now: now)
        let first = try engine.scheduleFromPool(
            chainID: firstChain,
            date: day1,
            today: day1,
            now: now
        )
        let completed = try engine.scheduleFromPool(
            chainID: completedChain,
            date: day1,
            today: day1,
            now: now
        )
        let third = try engine.scheduleFromPool(
            chainID: thirdChain,
            date: day1,
            today: day1,
            now: now
        )
        try engine.markCompleted(
            traceID: completed,
            today: day1,
            now: now.addingTimeInterval(1)
        )
        let completedFact = try XCTUnwrap(engine.traces[completed])

        try engine.reorderDayTrace(
            third,
            before: first,
            today: day1,
            now: now.addingTimeInterval(2)
        )

        XCTAssertEqual(
            engine.getDayTodo(date: day1).traces.map(\.id),
            [third, completed, first]
        )
        XCTAssertEqual(
            engine.getDayTodo(date: day1).traces.map(\.priority),
            [1, 2, 3]
        )
        XCTAssertEqual(engine.traces[completed], completedFact)

        try engine.updatePriority(
            traceID: first,
            newPriority: 1,
            today: day1,
            now: now.addingTimeInterval(3)
        )

        XCTAssertEqual(
            engine.getDayTodo(date: day1).traces.map(\.id),
            [first, completed, third]
        )
        XCTAssertEqual(
            engine.getDayTodo(date: day1).traces.map(\.priority),
            [1, 2, 3]
        )
        XCTAssertEqual(engine.traces[completed], completedFact)
    }

    func testDayTracePriorityMutationRejectsTerminalSourceAndTargetAtomically() throws {
        let engine = NoonmarkEngine()
        let completedChain = try engine.createPoolTask(title: "完成项", now: now)
        let pendingChain = try engine.createPoolTask(title: "待完成项", now: now)
        let completed = try engine.scheduleFromPool(
            chainID: completedChain,
            date: day1,
            today: day1,
            now: now
        )
        let pending = try engine.scheduleFromPool(
            chainID: pendingChain,
            date: day1,
            today: day1,
            now: now
        )
        try engine.markCompleted(
            traceID: completed,
            today: day1,
            now: now.addingTimeInterval(1)
        )
        let snapshot = engine.snapshot()

        XCTAssertThrowsError(
            try engine.updatePriority(
                traceID: completed,
                newPriority: 9,
                today: day1,
                now: now.addingTimeInterval(2)
            )
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkError,
                .invalidTransition("only pending day traces can change priority")
            )
        }
        XCTAssertEqual(engine.snapshot(), snapshot)

        XCTAssertThrowsError(
            try engine.reorderDayTrace(
                completed,
                before: pending,
                today: day1,
                now: now.addingTimeInterval(2)
            )
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkError,
                .invalidTransition("only pending day traces can change priority")
            )
        }
        XCTAssertEqual(engine.snapshot(), snapshot)

        XCTAssertThrowsError(
            try engine.reorderDayTrace(
                pending,
                before: completed,
                today: day1,
                now: now.addingTimeInterval(2)
            )
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkError,
                .invalidTransition("priority targets must be pending day traces")
            )
        }
        XCTAssertEqual(engine.snapshot(), snapshot)
    }

    func testDayTracePriorityUpdateMovesWithinExistingPendingSlots() throws {
        let engine = NoonmarkEngine()
        let firstChain = try engine.createPoolTask(title: "第一项", now: now)
        let secondChain = try engine.createPoolTask(title: "第二项", now: now)
        let thirdChain = try engine.createPoolTask(title: "第三项", now: now)
        let first = try engine.scheduleFromPool(
            chainID: firstChain,
            date: day1,
            today: day1,
            now: now
        )
        let second = try engine.scheduleFromPool(
            chainID: secondChain,
            date: day1,
            today: day1,
            now: now
        )
        let third = try engine.scheduleFromPool(
            chainID: thirdChain,
            date: day1,
            today: day1,
            now: now
        )

        try engine.updatePriority(
            traceID: first,
            newPriority: 3,
            today: day1,
            now: now.addingTimeInterval(1)
        )

        XCTAssertEqual(
            engine.getDayTodo(date: day1).traces.map(\.id),
            [second, third, first]
        )
        XCTAssertEqual(
            engine.getDayTodo(date: day1).traces.map(\.priority),
            [1, 2, 3]
        )

        let snapshot = engine.snapshot()
        XCTAssertThrowsError(
            try engine.updatePriority(
                traceID: first,
                newPriority: 9,
                today: day1,
                now: now.addingTimeInterval(2)
            )
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkError,
                .invalidInput("priority must reference an existing pending day-trace slot")
            )
        }
        XCTAssertEqual(engine.snapshot(), snapshot)
    }

    func testDayTraceReorderRejectsCrossDateAndLockedHistoryAtomically() throws {
        let engine = NoonmarkEngine()
        let firstChain = try engine.createPoolTask(title: "第一天", now: now)
        let secondChain = try engine.createPoolTask(title: "第二天", now: now)
        let first = try engine.scheduleFromPool(
            chainID: firstChain,
            date: day1,
            today: day1,
            now: now
        )
        let second = try engine.scheduleFromPool(
            chainID: secondChain,
            date: day2,
            today: day1,
            now: now
        )
        let snapshot = engine.snapshot()

        XCTAssertThrowsError(
            try engine.reorderDayTrace(
                first,
                before: second,
                today: day1,
                now: now.addingTimeInterval(1)
            )
        )
        XCTAssertEqual(engine.snapshot(), snapshot)

        try engine.settleDays(upTo: day2, now: now.addingTimeInterval(2))
        let settledSnapshot = engine.snapshot()
        XCTAssertThrowsError(
            try engine.reorderDayTrace(
                first,
                before: nil,
                today: day1,
                now: now.addingTimeInterval(3)
            )
        )
        XCTAssertEqual(engine.snapshot(), settledSnapshot)
    }

    func testLockedAbandonedTraceCannotBecomePendingWhenNaturalDayMovesBackward() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "已废弃", now: now)
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: day1,
            today: day1,
            now: now
        )
        try engine.abandonChain(from: traceID, now: now.addingTimeInterval(1))
        try engine.settleDays(upTo: day2, now: now.addingTimeInterval(2))

        _ = try engine.reactivateAbandonedChain(
            from: traceID,
            today: day1,
            now: now.addingTimeInterval(3)
        )

        XCTAssertEqual(engine.traces[traceID]?.status, .unfinished)
        XCTAssertNotNil(engine.traces[traceID]?.settledAt)
        XCTAssertEqual(engine.chains[chainID]?.state, .active)
        XCTAssertNotNil(engine.days[day1]?.lockedAt)
    }

    func testLockedUnfinishedTraceCanStillContinueToAnUnlockedTarget() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "仍可延续", now: now)
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: day1,
            today: day1,
            now: now
        )
        try engine.settleDays(upTo: day2, now: now.addingTimeInterval(1))

        let continuedID = try engine.continueTrace(
            traceID: traceID,
            targetDate: day2,
            today: day1,
            now: now.addingTimeInterval(2)
        )

        XCTAssertEqual(engine.traces[traceID]?.status, .continued)
        XCTAssertEqual(engine.traces[continuedID]?.date, day2)
        XCTAssertEqual(engine.traces[continuedID]?.status, .pending)
    }
}
