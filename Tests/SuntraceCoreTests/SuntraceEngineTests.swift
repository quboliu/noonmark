@testable import SuntraceCore
import XCTest

final class SuntraceEngineTests: XCTestCase {
    private let day1 = LocalDate("2026-07-05")
    private let day2 = LocalDate("2026-07-06")
    private let day3 = LocalDate("2026-07-07")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSchedulingFromPoolCreatesDayTraceAndRemovesFromTaskPool() throws {
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "  写一期规格  ", now: now)

        XCTAssertEqual(engine.taskPool().count, 1)

        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)

        XCTAssertTrue(engine.taskPool().isEmpty)
        XCTAssertEqual(engine.traces[traceID]?.status, .pending)
        XCTAssertEqual(engine.getDayTodo(date: day1).traces.map(\.id), [traceID])
    }

    func testSchedulingFromPoolCannotTargetPastDate() throws {
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "不能排期到过去", now: now)

        XCTAssertThrowsError(try engine.scheduleFromPool(chainID: chainID, date: day1, today: day2, now: now))
        XCTAssertEqual(engine.taskPool().map(\.chain.id), [chainID])
        XCTAssertTrue(engine.getDayTodo(date: day1).traces.isEmpty)
    }

    func testTaskTitleRenameAppliesOnlyToEditablePoolCurrentAndFutureTasks() throws {
        let engine = SuntraceEngine()
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
        let engine = SuntraceEngine()
        let completedChainID = try engine.createPoolTask(title: "完成旧标题", now: now)
        let completedTraceID = try engine.scheduleFromPool(chainID: completedChainID, date: day1, today: day1, now: now)
        try engine.markCompleted(traceID: completedTraceID, today: day1, now: now)

        XCTAssertThrowsError(
            try engine.renameTaskTitle(chainID: completedChainID, title: "完成新标题", today: day1, now: now)
        )

        let unfinishedChainID = try engine.createPoolTask(title: "未完成旧标题", now: now)
        _ = try engine.scheduleFromPool(chainID: unfinishedChainID, date: day1, today: day1, now: now)
        engine.settleDays(upTo: day2, now: now)

        XCTAssertThrowsError(
            try engine.renameTaskTitle(chainID: unfinishedChainID, title: "未完成新标题", today: day2, now: now)
        )
    }

    func testTaskTitleRenameVersionsCurrentContinuationWithoutRewritingHistory() throws {
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "历史标题", now: now)
        let historicalTraceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: day1,
            today: day1,
            now: now
        )
        engine.settleDays(upTo: day2, now: now)
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

    func testTaskPoolRemovalDeletesUnscheduledAndPreservesReturnedHistory() throws {
        let engine = SuntraceEngine()
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
        let engine = SuntraceEngine()
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
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "跨日未完成", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)

        engine.settleDays(upTo: day2, now: now)

        XCTAssertEqual(engine.traces[traceID]?.status, .unfinished)
        XCTAssertNotNil(engine.days[day1]?.lockedAt)
        XCTAssertEqual(engine.unfinishedPool().count, 1)
        XCTAssertEqual(engine.unfinishedPool().first?.unfinishedTraces.map(\.id), [traceID])
    }

    func testContinuationKeepsHistoryAndBlocksDuplicateActiveTrace() throws {
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "延续测试", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)
        engine.settleDays(upTo: day2, now: now)

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
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "主动延续当前任务", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)

        let continuedID = try engine.continueTrace(traceID: traceID, targetDate: day2, today: day1, now: now)

        XCTAssertEqual(engine.traces[traceID]?.status, .continued)
        XCTAssertNil(engine.traces[traceID]?.settledAt)
        XCTAssertEqual(engine.traces[continuedID]?.status, .pending)
        XCTAssertTrue(engine.unfinishedPool().isEmpty)
    }

    func testCompletedContinuationRemovesChainFromUnfinishedPoolAndShowsTrajectory() throws {
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "完成后移出未完成池", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)
        engine.settleDays(upTo: day2, now: now)
        let day2TraceID = try engine.continueTrace(traceID: traceID, targetDate: day2, today: day2, now: now)
        engine.settleDays(upTo: day3, now: now)
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
        let engine = SuntraceEngine()
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

    func testCurrentReturnToPoolLeavesTraceAndMakesChainSchedulableAgain() throws {
        let engine = SuntraceEngine()
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
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "未来计划", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day3, today: day1, now: now)

        XCTAssertEqual(engine.futurePlans(today: day1).map(\.trace.id), [traceID])
        XCTAssertThrowsError(try engine.markCompleted(traceID: traceID, today: day1, now: now))

        try engine.rescheduleFuturePlan(traceID: traceID, targetDate: day2, today: day1)
        XCTAssertEqual(engine.traces[traceID]?.date, day2)
        XCTAssertNotNil(engine.days[day2])

        _ = try engine.addSubtask(traceID: traceID, title: "未来计划子任务", now: now)

        try engine.returnToPool(traceID: traceID, today: day1, now: now)
        XCTAssertNil(engine.traces[traceID])
        XCTAssertTrue(engine.subtasks.isEmpty)
        XCTAssertEqual(engine.taskPool().map(\.chain.id), [chainID])
    }

    func testContinuationCopiesOnlyOpenSubtasks() throws {
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "子任务延续", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)
        let doneSubtaskID = try engine.addSubtask(traceID: traceID, title: "已完成子任务", now: now)
        _ = try engine.addSubtask(traceID: traceID, title: "未完成子任务", now: now)
        try engine.completeSubtask(doneSubtaskID, today: day1, now: now)
        engine.settleDays(upTo: day2, now: now)

        let continuedID = try engine.continueTrace(traceID: traceID, targetDate: day2, today: day2, now: now)
        let copied = engine.subtasks.values.filter { $0.traceID == continuedID }

        XCTAssertEqual(copied.map(\.title), ["未完成子任务"])
    }

    func testCurrentDayCompletedSubtaskCanBeUndone() throws {
        let engine = SuntraceEngine()
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
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "历史子任务锁定", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)
        let subtaskID = try engine.addSubtask(traceID: traceID, title: "历史完成项", now: now)

        try engine.completeSubtask(subtaskID, today: day1, now: now)

        XCTAssertThrowsError(try engine.undoCompletedSubtask(subtaskID, today: day2))
        XCTAssertEqual(engine.subtasks[subtaskID]?.status, .completed)
        XCTAssertNotNil(engine.subtasks[subtaskID]?.completedAt)
    }

    func testParentTraceCannotCompleteWithOpenSubtasksAndShowsPartialProgress() throws {
        let engine = SuntraceEngine()
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
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "跨日大任务", now: now)
        let day1TraceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)
        let designSubtaskID = try engine.addSubtask(traceID: day1TraceID, title: "设计登录态", now: now)
        let ssoSubtaskID = try engine.addSubtask(traceID: day1TraceID, title: "接入 SSO", now: now)

        try engine.completeSubtask(designSubtaskID, today: day1, now: now)
        engine.settleDays(upTo: day2, now: now)
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

    func testCompletedSubtaskRecordsExposePrototypeCompletedPoolItems() throws {
        let engine = SuntraceEngine()
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
        let engine = SuntraceEngine()
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
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(
            title: "整理 OKR",
            descriptionText: "汇总目标",
            note: "等数据看板",
            now: now
        )
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)

        XCTAssertEqual(engine.traces[traceID]?.descriptionText, "汇总目标")
        XCTAssertEqual(engine.traces[traceID]?.note, "等数据看板")

        try engine.updateTraceText(traceID: traceID, descriptionText: "收敛成 3 个 O", note: "下午确认 KR", today: day1)
        XCTAssertEqual(engine.traces[traceID]?.descriptionText, "收敛成 3 个 O")
        XCTAssertEqual(engine.definitions[engine.traces[traceID]!.definitionID]?.descriptionText, "汇总目标")

        engine.settleDays(upTo: day2, now: now)
        XCTAssertThrowsError(
            try engine.updateTraceText(traceID: traceID, descriptionText: "历史改写", note: nil, today: day2)
        )
    }

    func testPoolPlannedSubtasksAreCopiedWhenScheduled() throws {
        let engine = SuntraceEngine()
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
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "整理 Q3 OKR 草案", now: now)
        let day1TraceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)

        try engine.setManualProgress(traceID: day1TraceID, percent: 35, today: day1)
        engine.settleDays(upTo: day2, now: now)
        let day2TraceID = try engine.continueTrace(traceID: day1TraceID, targetDate: day2, today: day2, now: now)

        XCTAssertEqual(engine.traceProgress(for: day2TraceID).floorPercent, 35)
        XCTAssertEqual(engine.traceProgress(for: day2TraceID).percent, 35)

        try engine.setManualProgress(traceID: day2TraceID, percent: 10, today: day2)
        XCTAssertEqual(engine.traceProgress(for: day2TraceID).percent, 35)

        try engine.setManualProgress(traceID: day2TraceID, percent: 60, today: day2)
        XCTAssertEqual(engine.traceProgress(for: day2TraceID).percent, 60)
    }

    func testWeightedSubtaskProgressUsesDifficultyAndBlocksManualProgress() throws {
        let engine = SuntraceEngine()
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
        let engine = SuntraceEngine()
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

    func testCalendarSummaryMatchesPrototypeHeatNeeds() throws {
        let engine = SuntraceEngine()
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

    func testSettingsPreferencesMirrorPrototypeSettingsPanel() throws {
        let engine = SuntraceEngine()

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
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(
            title: "导出导入数据包",
            descriptionText: "验证 JSON 数据包能恢复核心状态。",
            note: "第一期手动数据交换。",
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
        let restored = try SuntraceEngine(snapshot: decoder.decode(SuntraceSnapshot.self, from: data))

        XCTAssertEqual(restored.snapshot(), engine.snapshot())
    }

    func testTaskTitlesPreserveSoftAndMarkdownHardLineBreaks() throws {
        let engine = SuntraceEngine()
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
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "父任务", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)
        _ = try engine.addSubtask(traceID: traceID, title: "未完成子任务", now: now)

        XCTAssertThrowsError(try engine.markCompleted(traceID: traceID, today: day1, now: now)) { error in
            XCTAssertEqual(error as? SuntraceError, .openSubtasksPreventCompletion)
            XCTAssertEqual(error.localizedDescription, "还有未完成子任务，完成全部子任务后才能完成父任务")
        }
        XCTAssertEqual(engine.traces[traceID]?.status, .pending)
    }
}
