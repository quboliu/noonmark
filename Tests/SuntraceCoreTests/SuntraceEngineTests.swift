import XCTest
@testable import SuntraceCore

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

        try engine.returnToPool(traceID: traceID, today: day1, now: now)
        XCTAssertNil(engine.traces[traceID])
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
        XCTAssertEqual(engine.syncEndpointOptions().map(\.kind), [.customEndpoint, .iCloud])
        XCTAssertTrue(engine.syncEndpointOptions().allSatisfy { $0.availability == .planned })

        engine.updateTheme(.warmPaper)
        engine.updateLanguage(.english)

        XCTAssertEqual(engine.preferences.theme, .warmPaper)
        XCTAssertEqual(engine.preferences.language, .english)
    }
}
