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
        XCTAssertEqual(engine.traces[newTraceID]?.chainID, chainID)
        XCTAssertEqual(engine.getDayTodo(date: day1).traces.count, 2)

        let newDefinitionID = try XCTUnwrap(engine.traces[newTraceID]?.definitionID)
        XCTAssertEqual(engine.definitions[newDefinitionID]?.title, "写调研并输出架构")
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
        try engine.completeSubtask(doneSubtaskID, now: now)
        engine.settleDays(upTo: day2, now: now)

        let continuedID = try engine.continueTrace(traceID: traceID, targetDate: day2, today: day2, now: now)
        let copied = engine.subtasks.values.filter { $0.traceID == continuedID }

        XCTAssertEqual(copied.map(\.title), ["未完成子任务"])
    }
}
