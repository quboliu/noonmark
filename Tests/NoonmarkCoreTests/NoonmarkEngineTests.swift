@testable import NoonmarkCore
import XCTest

final class NoonmarkEngineTests: XCTestCase {
    private let day1 = LocalDate("2026-07-05")
    private let day2 = LocalDate("2026-07-06")
    private let day3 = LocalDate("2026-07-07")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testNextMutationDateUsesReferenceAfterEveryPersistedClock() throws {
        let engine = NoonmarkEngine()
        _ = try engine.createPoolTask(title: "逻辑时钟基线", now: now)
        let reference = now.addingTimeInterval(10)

        XCTAssertEqual(
            try engine.nextMutationDate(reference: reference),
            reference
        )
    }

    func testNextMutationDateAdvancesPastPersistedClockWhenReferenceDoesNot() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "逻辑时钟前沿", now: now)
        let noteAt = now.addingTimeInterval(20)
        _ = try engine.appendPoolNote(
            chainID: chainID,
            body: "未来写入",
            now: noteAt
        )

        let next = try engine.nextMutationDate(
            reference: now.addingTimeInterval(10)
        )

        XCTAssertGreaterThan(next, noteAt)
        XCTAssertEqual(
            next.timeIntervalSinceReferenceDate,
            noteAt.timeIntervalSinceReferenceDate.nextUp
        )
    }

    func testNextMutationDateRejectsNonFiniteReference() throws {
        let engine = NoonmarkEngine()

        XCTAssertThrowsError(
            try engine.nextMutationDate(
                reference: Date(timeIntervalSinceReferenceDate: .infinity)
            )
        )
    }

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

        let currentDefinitionID = currentTrace.definitionID
        let definitionCount = engine.definitions.count
        try engine.saveTaskTitleInput(
            chainID: chainID,
            title: "再次修改当前标题",
            today: day2,
            now: now.addingTimeInterval(2)
        )

        XCTAssertEqual(engine.definitions[historicalTrace.definitionID]?.title, "历史标题")
        XCTAssertEqual(engine.traces[currentTraceID]?.definitionID, currentDefinitionID)
        XCTAssertEqual(engine.definitions[currentDefinitionID]?.title, "再次修改当前标题")
        XCTAssertEqual(engine.definitions.count, definitionCount)
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

    func testTaskPoolRemovalHidesUnscheduledFactsAndPreservesReturnedHistory() throws {
        let engine = NoonmarkEngine()
        let unscheduledChainID = try engine.createPoolTask(title: "未排期删除", now: now)
        let unscheduledDefinitionID = try XCTUnwrap(
            engine.taskPool().first {
                $0.chain.id == unscheduledChainID
            }?.definition.id
        )

        let unscheduledOutcome = try engine.removeTaskFromPool(
            chainID: unscheduledChainID,
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(unscheduledOutcome, .deleted)
        XCTAssertEqual(engine.chains[unscheduledChainID]?.state, .abandoned)
        XCTAssertEqual(
            engine.definitions[unscheduledDefinitionID]?.chainID,
            unscheduledChainID
        )
        XCTAssertFalse(
            engine.taskPool().contains { $0.chain.id == unscheduledChainID }
        )
        XCTAssertNoThrow(try engine.snapshot().validateIntegrity())

        let returnedChainID = try engine.createPoolTask(title: "回池删除", now: now)
        let returnedTraceID = try engine.scheduleFromPool(chainID: returnedChainID, date: day1, today: day1, now: now)
        try engine.returnToPool(traceID: returnedTraceID, today: day1, now: now)

        try engine.removeTaskFromPool(chainID: returnedChainID, now: now)
        XCTAssertEqual(engine.traces[returnedTraceID]?.status, .returnedToPool)
        XCTAssertEqual(engine.chains[returnedChainID]?.state, .abandoned)
        XCTAssertFalse(engine.taskPool().contains { $0.chain.id == returnedChainID })
    }

    func testDeletingNewCurrentDayTaskLeavesOnlyAnInternalCancellationFact() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "今日临时任务", now: now)
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: day1,
            today: day1,
            now: now
        )
        let deletedAt = now.addingTimeInterval(1)

        try engine.deleteNewCurrentDayTask(
            traceID: traceID,
            today: day1,
            now: deletedAt
        )

        let trace = try XCTUnwrap(engine.traces[traceID])
        XCTAssertEqual(trace.status, .cancelledDraft)
        XCTAssertEqual(trace.settledAt, deletedAt)
        XCTAssertNotNil(trace.draftCancellationID)
        XCTAssertEqual(trace.draftCancelledOn, day1)
        XCTAssertEqual(engine.chains[chainID]?.state, .abandoned)
        XCTAssertFalse(engine.getDayTodo(date: day1).traces.contains { $0.id == traceID })
        XCTAssertFalse(engine.taskPool().contains { $0.chain.id == chainID })
        XCTAssertFalse(engine.unfinishedPool().contains { $0.chain.id == chainID })
        XCTAssertNoThrow(try engine.snapshot().validateIntegrity())
        XCTAssertEqual(
            try NoonmarkEngine(snapshot: engine.snapshot()).snapshot(),
            engine.snapshot()
        )
    }

    func testDeletingNewCurrentDayTaskRejectsCompletedAndContinuedTasks() throws {
        let engine = NoonmarkEngine()
        let completedChainID = try engine.createPoolTask(title: "已完成任务", now: now)
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

        XCTAssertThrowsError(
            try engine.deleteNewCurrentDayTask(
                traceID: completedTraceID,
                today: day1,
                now: now.addingTimeInterval(2)
            )
        )

        let continuedChainID = try engine.createPoolTask(
            title: "已有历史的延续任务",
            now: now
        )
        let sourceTraceID = try engine.scheduleFromPool(
            chainID: continuedChainID,
            date: day1,
            today: day1,
            now: now
        )
        try engine.settleDays(upTo: day2, now: now.addingTimeInterval(1))
        let continuedTraceID = try engine.continueTrace(
            traceID: sourceTraceID,
            targetDate: day2,
            today: day2,
            now: now.addingTimeInterval(2)
        )

        XCTAssertThrowsError(
            try engine.deleteNewCurrentDayTask(
                traceID: continuedTraceID,
                today: day2,
                now: now.addingTimeInterval(3)
            )
        )
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
        XCTAssertEqual(engine.getDayTodo(date: day1).traces.map(\.id), [newTraceID])
        XCTAssertEqual(
            try engine.taskTrail(chainID: chainID).map(\.kind),
            [.createdInPool, .scheduled, .changed]
        )

        let newDefinitionID = try XCTUnwrap(engine.traces[newTraceID]?.definitionID)
        XCTAssertEqual(engine.definitions[newDefinitionID]?.title, "写调研并输出架构")
        XCTAssertEqual(engine.definitions[newDefinitionID]?.sequence, 1)
    }

    func testChangingCurrentTraceCarriesEditableContextAndOpenSubtasks() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "旧承诺",
            descriptionText: "原始描述",
            initialNoteBody: "原始附言",
            now: now
        )
        let oldTraceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: day1,
            today: day1,
            now: now.addingTimeInterval(1)
        )
        _ = try engine.addSubtask(
            traceID: oldTraceID,
            title: "继续处理",
            difficulty: .hard,
            now: now.addingTimeInterval(2)
        )
        let completedID = try engine.addSubtask(
            traceID: oldTraceID,
            title: "已经处理",
            now: now.addingTimeInterval(3)
        )
        try engine.completeSubtask(
            completedID,
            today: day1,
            now: now.addingTimeInterval(4)
        )
        try engine.updateTraceText(
            traceID: oldTraceID,
            descriptionText: "当天最新描述",
            today: day1,
            now: now.addingTimeInterval(5)
        )
        _ = try engine.appendTraceNote(
            traceID: oldTraceID,
            body: "当天新增附言",
            today: day1,
            now: now.addingTimeInterval(6)
        )

        let newTraceID = try engine.changeTrace(
            traceID: oldTraceID,
            newTitle: "新承诺",
            today: day1,
            now: now.addingTimeInterval(7)
        )

        let newTrace = try XCTUnwrap(engine.traces[newTraceID])
        XCTAssertEqual(newTrace.descriptionText, "当天最新描述")
        XCTAssertEqual(newTrace.activeNoteEntries.map(\.body), ["原始附言", "当天新增附言"])
        XCTAssertEqual(
            engine.subtasks.values
                .filter { $0.traceID == newTraceID }
                .map(\.title),
            ["继续处理"]
        )
        XCTAssertEqual(engine.subtasks[completedID]?.status, .completed)

        let sourceTrail = try engine.taskTrail(chainID: chainID)
        XCTAssertEqual(sourceTrail.last?.relatedTraceID, newTraceID)
        let targetTrail = try engine.taskTrail(chainID: newTrace.chainID)
        XCTAssertEqual(targetTrail.first?.kind, .createdFromChange)
        XCTAssertEqual(targetTrail.first?.relatedTraceID, oldTraceID)
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
            [2, 3, 4]
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

    func testReturningAndReschedulingOnCurrentDayProjectsOnlyTheReplacementTrace() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "同日回池再排期", now: now)
        let returnedTraceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: day1,
            today: day1,
            now: now
        )

        try engine.returnToPool(
            traceID: returnedTraceID,
            today: day1,
            now: now.addingTimeInterval(1)
        )
        let replacementTraceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: day1,
            today: day1,
            now: now.addingTimeInterval(2)
        )

        XCTAssertEqual(engine.traces[returnedTraceID]?.status, .returnedToPool)
        XCTAssertEqual(engine.traces[replacementTraceID]?.status, .pending)
        XCTAssertEqual(
            engine.getDayTodo(date: day1).traces.map(\.id),
            [replacementTraceID]
        )
    }

    func testReturnToPoolMaterializesLatestEditableContentAndOpenSubtasks() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "回池保留内容",
            descriptionText: "最初描述",
            initialNoteBody: "最初附言",
            now: now
        )
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: day1,
            today: day1,
            now: now.addingTimeInterval(1)
        )
        let openSubtaskID = try engine.addSubtask(
            traceID: traceID,
            title: "仍需处理",
            difficulty: .hard,
            now: now.addingTimeInterval(2)
        )
        let completedSubtaskID = try engine.addSubtask(
            traceID: traceID,
            title: "已经完成",
            now: now.addingTimeInterval(3)
        )
        try engine.completeSubtask(
            completedSubtaskID,
            today: day1,
            now: now.addingTimeInterval(4)
        )
        try engine.updateTraceText(
            traceID: traceID,
            descriptionText: "当天最新描述",
            today: day1,
            now: now.addingTimeInterval(5)
        )
        _ = try engine.appendTraceNote(
            traceID: traceID,
            body: "当天新增附言",
            today: day1,
            now: now.addingTimeInterval(6)
        )

        try engine.returnToPool(
            traceID: traceID,
            today: day1,
            now: now.addingTimeInterval(7)
        )

        let returnedTask = try XCTUnwrap(engine.taskPool().first)
        XCTAssertEqual(returnedTask.definition.descriptionText, "当天最新描述")
        XCTAssertEqual(
            returnedTask.chain.activeNoteEntries.map(\.body),
            ["最初附言", "当天新增附言"]
        )
        XCTAssertEqual(returnedTask.definition.plannedSubtasks.map(\.title), ["仍需处理"])
        XCTAssertEqual(
            returnedTask.definition.plannedSubtasks.map(\.lineageID),
            [engine.subtasks[openSubtaskID]?.lineageID]
        )

        let plannedID = try XCTUnwrap(returnedTask.definition.plannedSubtasks.first?.id)
        try engine.updatePlannedSubtaskTitle(
            chainID: chainID,
            plannedSubtaskID: plannedID,
            title: "回池后可修改",
            now: now.addingTimeInterval(8)
        )
        _ = try engine.addPlannedSubtask(
            chainID: chainID,
            title: "回池后可新增",
            now: now.addingTimeInterval(9)
        )

        let replacementTraceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: day2,
            today: day1,
            now: now.addingTimeInterval(10)
        )
        XCTAssertEqual(
            engine.subtasks.values
                .filter { $0.traceID == replacementTraceID }
                .sorted { $0.position < $1.position }
                .map(\.title),
            ["回池后可修改", "回池后可新增"]
        )
        XCTAssertEqual(engine.traces[traceID]?.status, .returnedToPool)
        XCTAssertEqual(engine.subtasks[completedSubtaskID]?.status, .completed)
    }

    func testTaskTrailProjectsCreationSchedulingReturnAndReschedulingAtExactInstants() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "任务轨迹", now: now)
        let returnedTraceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: day1,
            today: day1,
            now: now.addingTimeInterval(1)
        )
        try engine.returnToPool(
            traceID: returnedTraceID,
            today: day1,
            now: now.addingTimeInterval(2)
        )
        let replacementTraceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: day1,
            today: day1,
            now: now.addingTimeInterval(3)
        )

        let trail = try engine.taskTrail(chainID: chainID)
        XCTAssertEqual(
            trail.map(\.kind),
            [.createdInPool, .scheduled, .returnedToPool, .scheduled]
        )
        XCTAssertEqual(
            trail.map(\.occurredAt),
            [
                now,
                now.addingTimeInterval(1),
                now.addingTimeInterval(2),
                now.addingTimeInterval(3)
            ]
        )
        XCTAssertEqual(
            trail.map(\.traceID),
            [nil, returnedTraceID, returnedTraceID, replacementTraceID]
        )
    }

    func testTaskTrailShowsAnUnscheduledTaskPoolCreation() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "尚未排期", now: now)

        let trail = try engine.taskTrail(chainID: chainID)
        XCTAssertEqual(trail.map(\.kind), [.createdInPool])
        XCTAssertEqual(trail.map(\.occurredAt), [now])
    }

    func testTaskTrailLinksBothSidesOfAnExplicitTaskChange() throws {
        let engine = NoonmarkEngine()
        let sourceChainID = try engine.createPoolTask(title: "旧任务", now: now)
        let sourceTraceID = try engine.scheduleFromPool(
            chainID: sourceChainID,
            date: day1,
            today: day1,
            now: now.addingTimeInterval(1)
        )
        let replacementTraceID = try engine.changeTrace(
            traceID: sourceTraceID,
            newTitle: "新任务",
            today: day1,
            now: now.addingTimeInterval(2)
        )
        let replacementChainID = try XCTUnwrap(engine.traces[replacementTraceID]?.chainID)

        let sourceTrail = try engine.taskTrail(chainID: sourceChainID)
        XCTAssertEqual(sourceTrail.map(\.kind), [.createdInPool, .scheduled, .changed])
        XCTAssertEqual(sourceTrail.last?.relatedTraceID, replacementTraceID)

        let replacementTrail = try engine.taskTrail(chainID: replacementChainID)
        XCTAssertEqual(replacementTrail.map(\.kind), [.createdFromChange, .scheduled])
        XCTAssertEqual(replacementTrail.first?.relatedTraceID, sourceTraceID)
    }

    func testMovementSourcesDoNotInflateDayTodoReviewOrCalendarCounts() throws {
        let engine = NoonmarkEngine()
        let returnedChainID = try engine.createPoolTask(title: "回池再排期", now: now)
        let returnedTraceID = try engine.scheduleFromPool(
            chainID: returnedChainID,
            date: day1,
            today: day1,
            now: now
        )
        try engine.returnToPool(
            traceID: returnedTraceID,
            today: day1,
            now: now.addingTimeInterval(1)
        )
        let rescheduledTraceID = try engine.scheduleFromPool(
            chainID: returnedChainID,
            date: day1,
            today: day1,
            now: now.addingTimeInterval(2)
        )

        let changedChainID = try engine.createPoolTask(
            title: "旧任务",
            now: now.addingTimeInterval(3)
        )
        let changedTraceID = try engine.scheduleFromPool(
            chainID: changedChainID,
            date: day1,
            today: day1,
            now: now.addingTimeInterval(3)
        )
        let replacementTraceID = try engine.changeTrace(
            traceID: changedTraceID,
            newTitle: "新任务",
            today: day1,
            now: now.addingTimeInterval(4)
        )

        XCTAssertTrue(engine.traces[returnedTraceID]?.formsDayHistory == true)
        XCTAssertTrue(engine.traces[changedTraceID]?.formsDayHistory == true)
        XCTAssertEqual(
            Set(engine.getDayTodo(date: day1).traces.map(\.id)),
            Set([rescheduledTraceID, replacementTraceID])
        )

        let review = engine.dailyReviewStats(date: day1)
        XCTAssertEqual(review.total, 2)
        XCTAssertEqual(review.returnedToPool, 0)
        XCTAssertEqual(review.changed, 0)

        let calendar = engine.calendarSummary(for: day1)
        XCTAssertEqual(calendar.total, 2)
        XCTAssertEqual(calendar.pending, 2)
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
        XCTAssertEqual(engine.traces[traceID]?.status, .cancelledDraft)
        XCTAssertEqual(engine.traces[traceID]?.settledAt, now)
        XCTAssertNotNil(engine.traces[traceID]?.draftCancellationID)
        XCTAssertEqual(engine.traces[traceID]?.draftCancelledOn, day1)
        XCTAssertEqual(engine.subtasks.values.filter { $0.traceID == traceID }.count, 1)
        XCTAssertTrue(engine.getDayTodo(date: day2).traces.isEmpty)
        XCTAssertTrue(engine.futurePlans(today: day1).isEmpty)
        XCTAssertEqual(engine.taskPool().map(\.chain.id), [chainID])
        XCTAssertNoThrow(try engine.snapshot().validateIntegrity())

        try engine.updatePoolTask(
            chainID: chainID,
            title: "回池后仍可编辑",
            now: now.addingTimeInterval(1)
        )
        let rescheduledID = try engine.scheduleFromPool(
            chainID: chainID,
            date: day2,
            today: day1,
            now: now.addingTimeInterval(2)
        )
        XCTAssertEqual(engine.traces[rescheduledID]?.status, .pending)
        XCTAssertEqual(
            engine.getDayTodo(date: day2).traces.map(\.id),
            [rescheduledID]
        )
    }

    func testCancelledFutureDraftStaysOutOfEveryCompletedHistoryProjection() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "先取消再完成", now: now)
        let cancelledTraceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: day3,
            today: day1,
            now: now
        )
        let cancelledSubtaskID = try engine.addSubtask(
            traceID: cancelledTraceID,
            title: "不得进入完成轨迹的草稿子任务",
            now: now.addingTimeInterval(1)
        )
        try engine.returnToPool(
            traceID: cancelledTraceID,
            today: day1,
            now: now.addingTimeInterval(2)
        )

        let completedTraceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: day1,
            today: day1,
            now: now.addingTimeInterval(3)
        )
        let carriedSubtaskID = try XCTUnwrap(
            engine.subtasks.values.first(where: {
                $0.traceID == completedTraceID
                    && $0.lineageID
                    == engine.subtasks[cancelledSubtaskID]?.lineageID
            })?.id
        )
        let completedSubtaskID = try engine.addSubtask(
            traceID: completedTraceID,
            title: "真实完成子任务",
            now: now.addingTimeInterval(4)
        )
        try engine.completeSubtask(
            carriedSubtaskID,
            today: day1,
            now: now.addingTimeInterval(5)
        )
        try engine.completeSubtask(
            completedSubtaskID,
            today: day1,
            now: now.addingTimeInterval(6)
        )
        try engine.markCompleted(
            traceID: completedTraceID,
            today: day1,
            now: now.addingTimeInterval(7)
        )

        let presentableStatuses: [TraceStatus] = [
            .pending,
            .completed,
            .unfinished,
            .continued,
            .changed,
            .returnedToPool,
            .abandoned
        ]
        XCTAssertFalse(TraceStatus.cancelledDraft.formsDayHistory)
        XCTAssertFalse(TraceStatus.cancelledDraft.isUserPresentable)
        XCTAssertTrue(presentableStatuses.allSatisfy(\.isUserPresentable))
        XCTAssertEqual(engine.calendarSummary(for: day3).total, 0)
        XCTAssertEqual(engine.calendarSummary(for: day3).heatLevel, 0)
        XCTAssertEqual(engine.dailyReviewStats(date: day3).total, 0)

        let completedItem = try XCTUnwrap(engine.completedPool().first)
        XCTAssertEqual(completedItem.trace.id, completedTraceID)
        XCTAssertEqual(completedItem.trajectory.startDate, day1)
        XCTAssertEqual(completedItem.trajectory.traces.map(\.id), [completedTraceID])
        XCTAssertEqual(
            completedItem.trajectory.subtaskTrajectories
                .flatMap(\.records)
                .map(\.subtask.id),
            [carriedSubtaskID, completedSubtaskID]
        )
        XCTAssertFalse(
            completedItem.trajectory.subtaskTrajectories
                .flatMap(\.records)
                .contains { $0.subtask.id == cancelledSubtaskID }
        )
        XCTAssertEqual(
            engine.completedSubtaskRecords().map(\.subtask.id),
            [carriedSubtaskID, completedSubtaskID]
        )
    }

    func testCancelledFutureDraftIntegrityFailsClosedForForgedFacts() throws {
        let engine = NoonmarkEngine()
        let firstChainID = try engine.createPoolTask(
            title: "第一项未来草稿",
            now: now
        )
        let firstTraceID = try engine.scheduleFromPool(
            chainID: firstChainID,
            date: day2,
            today: day1,
            now: now
        )
        let firstSubtaskID = try engine.addSubtask(
            traceID: firstTraceID,
            title: "不可伪造成历史的子任务",
            now: now
        )
        try engine.returnToPool(
            traceID: firstTraceID,
            today: day1,
            now: now
        )

        let secondChainID = try engine.createPoolTask(
            title: "第二项未来草稿",
            now: now
        )
        let secondTraceID = try engine.scheduleFromPool(
            chainID: secondChainID,
            date: day3,
            today: day1,
            now: now
        )
        try engine.returnToPool(
            traceID: secondTraceID,
            today: day1,
            now: now
        )

        var missingWitness = engine.snapshot()
        missingWitness.traces[
            try XCTUnwrap(missingWitness.traces.firstIndex { $0.id == firstTraceID })
        ].draftCancellationID = nil
        XCTAssertThrowsError(try missingWitness.validateIntegrity())

        var invalidCancellationDate = engine.snapshot()
        invalidCancellationDate.traces[
            try XCTUnwrap(invalidCancellationDate.traces.firstIndex { $0.id == firstTraceID })
        ].draftCancelledOn = day3
        XCTAssertThrowsError(try invalidCancellationDate.validateIntegrity())

        var duplicateWitness = engine.snapshot()
        let firstCancellationID = try XCTUnwrap(
            duplicateWitness.traces.first { $0.id == firstTraceID }?
                .draftCancellationID
        )
        duplicateWitness.traces[
            try XCTUnwrap(duplicateWitness.traces.firstIndex { $0.id == secondTraceID })
        ].draftCancellationID = firstCancellationID
        XCTAssertThrowsError(try duplicateWitness.validateIntegrity())

        var historicalChild = engine.snapshot()
        let subtaskIndex = try XCTUnwrap(
            historicalChild.subtasks.firstIndex { $0.id == firstSubtaskID }
        )
        historicalChild.subtasks[subtaskIndex].status = .completed
        historicalChild.subtasks[subtaskIndex].completedAt = now
        XCTAssertThrowsError(try historicalChild.validateIntegrity())
    }

    func testContinuationCopiesOnlyOpenSubtasks() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "子任务延续", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)
        let doneSubtaskID = try engine.addSubtask(traceID: traceID, title: "已完成子任务", now: now)
        let openSubtaskID = try engine.addSubtask(
            traceID: traceID,
            title: "未完成子任务",
            now: now
        )
        let completedAt = now.addingTimeInterval(1)
        let settledAt = now.addingTimeInterval(2)
        let continuedAt = now.addingTimeInterval(3)
        try engine.completeSubtask(
            doneSubtaskID,
            today: day1,
            now: completedAt
        )
        try engine.settleDays(upTo: day2, now: settledAt)

        XCTAssertEqual(engine.subtasks[openSubtaskID]?.status, .unfinished)
        XCTAssertEqual(engine.subtasks[openSubtaskID]?.updatedAt, settledAt)

        let continuedID = try engine.continueTrace(
            traceID: traceID,
            targetDate: day2,
            today: day2,
            now: continuedAt
        )
        let copied = engine.subtasks.values.filter { $0.traceID == continuedID }

        XCTAssertEqual(copied.map(\.title), ["未完成子任务"])
        XCTAssertEqual(engine.subtasks[openSubtaskID]?.status, .continued)
        XCTAssertEqual(engine.subtasks[openSubtaskID]?.updatedAt, continuedAt)
        XCTAssertEqual(copied.map(\.updatedAt), [continuedAt])
    }

    func testContinuationRejectsSameDayAndNonFrontierSources() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "延续前沿", now: now)
        let day1TraceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: day1,
            today: day1,
            now: now
        )

        XCTAssertThrowsError(
            try engine.continueTrace(
                traceID: day1TraceID,
                targetDate: day1,
                today: day1,
                now: now.addingTimeInterval(1)
            )
        )

        try engine.settleDays(upTo: day2, now: now.addingTimeInterval(2))
        let day2TraceID = try engine.continueTrace(
            traceID: day1TraceID,
            targetDate: day2,
            today: day2,
            now: now.addingTimeInterval(3)
        )
        try engine.settleDays(upTo: day3, now: now.addingTimeInterval(4))

        XCTAssertThrowsError(
            try engine.continueTrace(
                traceID: day1TraceID,
                targetDate: day3,
                today: day3,
                now: now.addingTimeInterval(5)
            )
        )
        XCTAssertEqual(engine.traces[day2TraceID]?.status, .unfinished)
        XCTAssertFalse(engine.traces.values.contains {
            $0.chainID == chainID && $0.status == .pending
        })
    }

    func testCurrentDaySubtaskCanBeRenamedAndDeletedWithoutErasingFact() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "编辑子任务", now: now)
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: day1,
            today: day1,
            now: now
        )
        let firstID = try engine.addSubtask(
            traceID: traceID,
            title: "需要改名",
            now: now.addingTimeInterval(1)
        )
        let secondID = try engine.addSubtask(
            traceID: traceID,
            title: "保留项目",
            now: now.addingTimeInterval(2)
        )

        try engine.updateSubtaskTitle(
            firstID,
            title: "改名后",
            today: day1,
            now: now.addingTimeInterval(3)
        )
        try engine.deleteSubtask(
            firstID,
            today: day1,
            now: now.addingTimeInterval(4)
        )

        XCTAssertEqual(engine.subtasks[firstID]?.title, "改名后")
        XCTAssertEqual(engine.subtasks[firstID]?.status, .cancelledDraft)
        XCTAssertNotNil(engine.subtasks[firstID]?.draftCancellationID)
        XCTAssertEqual(
            engine.subtasks.values
                .filter { $0.traceID == traceID && $0.isUserPresentable }
                .map(\.id),
            [secondID]
        )
        XCTAssertNoThrow(try engine.snapshot().validateIntegrity())
    }

    func testCurrentDayCompletedSubtaskCanBeUndone() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "当天子任务撤回", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)
        let subtaskID = try engine.addSubtask(traceID: traceID, title: "先完成再撤回", now: now)
        let completedAt = now.addingTimeInterval(1)
        let undoneAt = now.addingTimeInterval(2)

        try engine.completeSubtask(
            subtaskID,
            today: day1,
            now: completedAt
        )
        XCTAssertEqual(engine.subtasks[subtaskID]?.status, .completed)
        XCTAssertEqual(engine.subtasks[subtaskID]?.completedAt, completedAt)
        XCTAssertEqual(engine.subtasks[subtaskID]?.updatedAt, completedAt)

        try engine.undoCompletedSubtask(
            subtaskID,
            today: day1,
            now: undoneAt
        )

        XCTAssertEqual(engine.subtasks[subtaskID]?.status, .pending)
        XCTAssertNil(engine.subtasks[subtaskID]?.completedAt)
        XCTAssertEqual(engine.subtasks[subtaskID]?.updatedAt, undoneAt)
        XCTAssertEqual(engine.subtaskProgress(for: traceID).pending, 1)
        XCTAssertEqual(
            try engine.nextMutationDate(reference: now)
                .timeIntervalSinceReferenceDate,
            undoneAt.timeIntervalSinceReferenceDate.nextUp
        )
    }

    func testHistoricalCompletedSubtaskCannotBeUndone() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "历史子任务锁定", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)
        let subtaskID = try engine.addSubtask(traceID: traceID, title: "历史完成项", now: now)

        try engine.completeSubtask(subtaskID, today: day1, now: now)

        XCTAssertThrowsError(
            try engine.undoCompletedSubtask(
                subtaskID,
                today: day2,
                now: now.addingTimeInterval(1)
            )
        )
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

    func testAbandoningContinuedChainTargetsItsActiveTraceAndReactivatesInPlace() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "延续后决定废弃",
            now: now
        )
        let historicalTraceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: day1,
            today: day1,
            now: now
        )
        try engine.settleDays(
            upTo: day2,
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(
            engine.unfinishedPool().first?.actionPlan,
            [
                .continueTrace(historicalTraceID),
                .abandonChain(historicalTraceID)
            ]
        )
        let activeTraceID = try engine.continueTrace(
            traceID: historicalTraceID,
            targetDate: day2,
            today: day2,
            now: now.addingTimeInterval(2)
        )
        XCTAssertEqual(
            engine.unfinishedPool().first?.actionPlan,
            [.abandonChain(activeTraceID)]
        )

        try engine.abandonChain(
            from: historicalTraceID,
            now: now.addingTimeInterval(3)
        )

        XCTAssertEqual(engine.chains[chainID]?.state, .abandoned)
        XCTAssertEqual(engine.traces[historicalTraceID]?.status, .continued)
        XCTAssertEqual(engine.traces[activeTraceID]?.status, .abandoned)
        XCTAssertNil(engine.unfinishedPool().first?.activeTrace)
        XCTAssertEqual(
            engine.unfinishedPool().first?.unfinishedTraces.map(\.id),
            [historicalTraceID, activeTraceID]
        )
        XCTAssertEqual(
            engine.unfinishedPool().first?.actionPlan,
            [.reactivateChain(activeTraceID)]
        )

        let reactivatedTraceID = try engine.reactivateAbandonedChain(
            from: activeTraceID,
            today: day2,
            now: now.addingTimeInterval(4)
        )

        XCTAssertEqual(reactivatedTraceID, activeTraceID)
        XCTAssertEqual(engine.chains[chainID]?.state, .active)
        XCTAssertEqual(engine.traces[historicalTraceID]?.status, .continued)
        XCTAssertEqual(engine.traces[activeTraceID]?.status, .pending)
        XCTAssertEqual(engine.traces.count, 2)
        XCTAssertEqual(engine.unfinishedPool().first?.activeTrace?.id, activeTraceID)
        XCTAssertEqual(
            engine.unfinishedPool().first?.actionPlan,
            [.abandonChain(activeTraceID)]
        )
    }

    func testTraceDescriptionPreservesWhitespaceDuringCharacterLevelInput() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "即时描述", now: now)
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: day1,
            today: day1,
            now: now.addingTimeInterval(1)
        )

        try engine.updateTraceText(
            traceID: traceID,
            descriptionText: "first",
            today: day1,
            now: now.addingTimeInterval(2)
        )
        try engine.updateTraceText(
            traceID: traceID,
            descriptionText: "first ",
            today: day1,
            now: now.addingTimeInterval(3)
        )
        XCTAssertEqual(engine.traces[traceID]?.descriptionText, "first ")

        try engine.updateTraceText(
            traceID: traceID,
            descriptionText: "first second  \nthird",
            today: day1,
            now: now.addingTimeInterval(4)
        )
        XCTAssertEqual(engine.traces[traceID]?.descriptionText, "first second  \nthird")

        try engine.updateTraceText(
            traceID: traceID,
            descriptionText: " \n\t",
            today: day1,
            now: now.addingTimeInterval(5)
        )
        XCTAssertNil(engine.traces[traceID]?.descriptionText)
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

    func testSnapshotRejectsDuplicateDictionaryIdentitiesBeforeConstruction() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "拒绝重复快照身份",
            now: now
        )
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: day1,
            today: day1,
            now: now
        )
        _ = try engine.addSubtask(
            traceID: traceID,
            title: "重复子任务身份",
            now: now
        )
        let baseline = engine.snapshot()

        var duplicateDayDate = baseline
        duplicateDayDate.days.append(try XCTUnwrap(baseline.days.first))

        var duplicateDayID = baseline
        var sameIdentityOnAnotherDate = try XCTUnwrap(baseline.days.first)
        sameIdentityOnAnotherDate.date = day2
        duplicateDayID.days.append(sameIdentityOnAnotherDate)

        var duplicateDefinitionID = baseline
        duplicateDefinitionID.definitions.append(
            try XCTUnwrap(baseline.definitions.first)
        )

        var duplicateSubtaskID = baseline
        duplicateSubtaskID.subtasks.append(
            try XCTUnwrap(baseline.subtasks.first)
        )

        let cases: [(NoonmarkSnapshot, String)] = [
            (
                duplicateDayDate,
                "snapshot contains duplicate Day Todo dates"
            ),
            (
                duplicateDayID,
                "snapshot contains duplicate Day Todo identities"
            ),
            (
                duplicateDefinitionID,
                "snapshot contains duplicate task definition identities"
            ),
            (
                duplicateSubtaskID,
                "snapshot contains duplicate subtask identities"
            )
        ]
        for (snapshot, expectedMessage) in cases {
            XCTAssertThrowsError(try snapshot.validateIntegrity()) { error in
                XCTAssertEqual(
                    error as? NoonmarkError,
                    .invalidInput(expectedMessage)
                )
            }
            XCTAssertThrowsError(try NoonmarkEngine(snapshot: snapshot))
        }
    }

    func testSnapshotRejectsInvalidDayTodoContentClocks() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "校验 Day clock", now: now)
        _ = try engine.scheduleFromPool(
            chainID: chainID,
            date: day1,
            today: day1,
            now: now
        )
        let baseline = engine.snapshot()

        var nonFinite = baseline
        nonFinite.days[0].createdAt = Date(
            timeIntervalSinceReferenceDate: .nan
        )

        var backwards = baseline
        backwards.days[0].updatedAt = now.addingTimeInterval(-1)

        var uncoveredLock = baseline
        uncoveredLock.days[0].lockedAt = now.addingTimeInterval(1)

        for snapshot in [nonFinite, backwards, uncoveredLock] {
            XCTAssertThrowsError(try snapshot.validateIntegrity()) { error in
                XCTAssertEqual(
                    error as? NoonmarkError,
                    .invalidInput("Day Todo contains an invalid content clock")
                )
            }
        }
    }

    func testSnapshotRejectsInvalidPlannedSubtaskFactsWithinDefinition() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "校验计划子任务",
            now: now
        )
        _ = try engine.addPlannedSubtask(
            chainID: chainID,
            title: "第一项",
            now: now.addingTimeInterval(1)
        )
        _ = try engine.addPlannedSubtask(
            chainID: chainID,
            title: "第二项",
            now: now.addingTimeInterval(2)
        )
        let baseline = engine.snapshot()
        let definitionIndex = try XCTUnwrap(
            baseline.definitions.firstIndex { $0.chainID == chainID }
        )

        var nonFiniteClock = baseline
        nonFiniteClock.definitions[definitionIndex]
            .plannedSubtasks[0].createdAt = Date(
                timeIntervalSinceReferenceDate: .nan
            )

        var beforeChainClock = baseline
        beforeChainClock.definitions[definitionIndex]
            .plannedSubtasks[0].createdAt = now.addingTimeInterval(-1)

        var afterDefinitionClock = baseline
        afterDefinitionClock.definitions[definitionIndex]
            .plannedSubtasks[0].createdAt = now.addingTimeInterval(3)

        var duplicateIdentity = baseline
        duplicateIdentity.definitions[definitionIndex]
            .plannedSubtasks[1].id = duplicateIdentity
            .definitions[definitionIndex].plannedSubtasks[0].id

        var duplicateLineage = baseline
        duplicateLineage.definitions[definitionIndex]
            .plannedSubtasks[1].lineageID = duplicateLineage
            .definitions[definitionIndex].plannedSubtasks[0].lineageID

        var duplicatePosition = baseline
        duplicatePosition.definitions[definitionIndex]
            .plannedSubtasks[1].position = 1

        var noncontiguousPosition = baseline
        noncontiguousPosition.definitions[definitionIndex]
            .plannedSubtasks[1].position = 3

        for snapshot in [
            nonFiniteClock,
            beforeChainClock,
            afterDefinitionClock,
            duplicateIdentity,
            duplicateLineage,
            duplicatePosition,
            noncontiguousPosition
        ] {
            XCTAssertThrowsError(try snapshot.validateIntegrity()) { error in
                XCTAssertEqual(
                    error as? NoonmarkError,
                    .invalidInput(
                        "task definition contains invalid planned subtask facts"
                    )
                )
            }
        }
    }

    func testSnapshotAcceptsPlannedSubtaskFactsCarriedIntoRenamedDefinition() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "保留计划子任务身份",
            now: now
        )
        let plannedSubtaskID = try engine.addPlannedSubtask(
            chainID: chainID,
            title: "跨定义版本保留的计划子任务",
            now: now.addingTimeInterval(1)
        )
        _ = try engine.scheduleFromPool(
            chainID: chainID,
            date: day1,
            today: day1,
            now: now.addingTimeInterval(2)
        )
        try engine.renameTaskTitle(
            chainID: chainID,
            title: "保留计划子任务身份（已改名）",
            today: day1,
            now: now.addingTimeInterval(3)
        )

        let snapshot = engine.snapshot()
        let currentDefinition = try XCTUnwrap(
            snapshot.definitions.first {
                $0.chainID == chainID && $0.supersededAt == nil
            }
        )
        let carriedFact = try XCTUnwrap(
            currentDefinition.plannedSubtasks.first {
                $0.id == plannedSubtaskID
            }
        )

        XCTAssertEqual(
            carriedFact.createdAt.timeIntervalSinceReferenceDate.bitPattern,
            now.addingTimeInterval(1)
                .timeIntervalSinceReferenceDate.bitPattern
        )
        XCTAssertNoThrow(try snapshot.validateIntegrity())
    }

    func testSnapshotValidatesEverySubtaskStatusAndContentClockCombination() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "校验子任务状态矩阵",
            now: now
        )
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: day1,
            today: day1,
            now: now
        )
        _ = try engine.addSubtask(
            traceID: traceID,
            title: "状态矩阵",
            now: now
        )
        let baseline = engine.snapshot()
        let terminalAt = now.addingTimeInterval(1)

        func snapshot(
            status: SubtaskStatus,
            completedAt: Date?,
            settledAt: Date?
        ) -> NoonmarkSnapshot {
            var candidate = baseline
            candidate.subtasks[0].status = status
            candidate.subtasks[0].updatedAt = terminalAt
            candidate.subtasks[0].completedAt = completedAt
            candidate.subtasks[0].settledAt = settledAt
            return candidate
        }

        var validCancelledDraft = snapshot(
            status: .cancelledDraft,
            completedAt: nil,
            settledAt: terminalAt
        )
        validCancelledDraft.subtasks[0].draftCancellationID = UUID()

        let validSnapshots = [
            snapshot(
                status: .pending,
                completedAt: nil,
                settledAt: nil
            ),
            snapshot(
                status: .completed,
                completedAt: terminalAt,
                settledAt: nil
            ),
            snapshot(
                status: .unfinished,
                completedAt: nil,
                settledAt: terminalAt
            ),
            snapshot(
                status: .continued,
                completedAt: nil,
                settledAt: terminalAt
            ),
            snapshot(
                status: .abandoned,
                completedAt: nil,
                settledAt: terminalAt
            ),
            validCancelledDraft
        ]
        for candidate in validSnapshots {
            XCTAssertNoThrow(try candidate.subtasks[0].validateIntegrity())
        }

        var backwardsClock = validSnapshots[0]
        backwardsClock.subtasks[0].updatedAt = now.addingTimeInterval(-1)

        var nonFiniteClock = validSnapshots[0]
        nonFiniteClock.subtasks[0].updatedAt = Date(
            timeIntervalSinceReferenceDate: .nan
        )

        var uncoveredTerminal = validSnapshots[1]
        uncoveredTerminal.subtasks[0].updatedAt = now

        let invalidSnapshots = [
            snapshot(
                status: .pending,
                completedAt: terminalAt,
                settledAt: nil
            ),
            snapshot(
                status: .completed,
                completedAt: nil,
                settledAt: nil
            ),
            snapshot(
                status: .completed,
                completedAt: terminalAt,
                settledAt: terminalAt
            ),
            snapshot(
                status: .unfinished,
                completedAt: nil,
                settledAt: nil
            ),
            snapshot(
                status: .continued,
                completedAt: terminalAt,
                settledAt: terminalAt
            ),
            snapshot(
                status: .abandoned,
                completedAt: terminalAt,
                settledAt: terminalAt
            ),
            snapshot(
                status: .cancelledDraft,
                completedAt: nil,
                settledAt: terminalAt
            ),
            snapshot(
                status: .cancelledDraft,
                completedAt: terminalAt,
                settledAt: terminalAt
            ),
            backwardsClock,
            nonFiniteClock,
            uncoveredTerminal
        ]
        for candidate in invalidSnapshots {
            XCTAssertThrowsError(try candidate.subtasks[0].validateIntegrity()) { error in
                XCTAssertEqual(
                    error as? NoonmarkError,
                    .invalidInput("subtask contains invalid status or clock facts")
                )
            }
        }
    }

    func testSnapshotRejectsBrokenParentReferencesAndSubtaskTopology() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "校验关系完整性",
            now: now
        )
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: day1,
            today: day1,
            now: now
        )
        _ = try engine.addSubtask(
            traceID: traceID,
            title: "第一项",
            now: now
        )
        _ = try engine.addSubtask(
            traceID: traceID,
            title: "第二项",
            now: now
        )
        let baseline = engine.snapshot()

        var missingDefinitionChain = baseline
        missingDefinitionChain.definitions[0].chainID = TaskChainID()

        var missingSupersedingDefinition = baseline
        missingSupersedingDefinition.definitions[0]
            .supersededByDefinitionID = TaskDefinitionID()

        var missingTraceDefinition = baseline
        missingTraceDefinition.traces[0].definitionID = TaskDefinitionID()

        var missingContinuedFromTrace = baseline
        missingContinuedFromTrace.traces[0].continuedFromTraceID = DayTraceID()

        var missingTraceDay = baseline
        missingTraceDay.traces[0].date = day2

        var missingSubtaskTrace = baseline
        missingSubtaskTrace.subtasks[0].traceID = DayTraceID()

        for candidate in [
            missingDefinitionChain,
            missingSupersedingDefinition,
            missingTraceDefinition,
            missingTraceDay,
            missingSubtaskTrace
        ] {
            XCTAssertThrowsError(try candidate.validateIntegrity()) { error in
                XCTAssertEqual(
                    error as? NoonmarkError,
                    .invalidInput("snapshot contains invalid parent references")
                )
            }
        }

        XCTAssertThrowsError(
            try missingContinuedFromTrace.validateIntegrity()
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkError,
                .invalidInput("snapshot contains invalid day trace topology")
            )
        }

        var duplicateLineage = baseline
        duplicateLineage.subtasks[1].lineageID =
            duplicateLineage.subtasks[0].lineageID

        var duplicatePosition = baseline
        duplicatePosition.subtasks[1].position =
            duplicatePosition.subtasks[0].position

        var missingContinuationSource = baseline
        missingContinuationSource.subtasks[0].continuedFromSubtaskID =
            SubtaskID()

        for candidate in [
            duplicateLineage,
            duplicatePosition,
            missingContinuationSource
        ] {
            XCTAssertThrowsError(try candidate.validateIntegrity()) { error in
                XCTAssertEqual(
                    error as? NoonmarkError,
                    .invalidInput("snapshot contains invalid subtask topology")
                )
            }
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

    func testSnapshotUndoReclocksRestoredSubtaskMutation() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "撤销子任务难度", now: now)
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: day1,
            today: day1,
            now: now
        )
        let subtaskID = try engine.addSubtask(
            traceID: traceID,
            title: "恢复简单难度",
            difficulty: .simple,
            now: now
        )
        let undoSnapshot = engine.snapshot()
        try engine.updateSubtaskDifficulty(
            subtaskID,
            difficulty: .hard,
            today: day1,
            now: now.addingTimeInterval(10)
        )

        let candidate = try NoonmarkEngine(snapshot: undoSnapshot)
        try candidate.prepareSnapshotUndo(
            replacing: engine.snapshot(),
            now: now.addingTimeInterval(20)
        )

        XCTAssertEqual(candidate.subtasks[subtaskID]?.difficulty, .simple)
        XCTAssertEqual(
            candidate.subtasks[subtaskID]?.updatedAt,
            now.addingTimeInterval(20)
        )
    }

    func testSnapshotRedoOfAbandonmentForwardsTheWholeTraceBoundary() throws {
        let engine = NoonmarkEngine()
        let abandonedChainID = try engine.createPoolTask(
            title: "撤销后再次放弃",
            now: now
        )
        let abandonedTraceID = try engine.scheduleFromPool(
            chainID: abandonedChainID,
            date: day1,
            today: day1,
            now: now.addingTimeInterval(1)
        )
        let unaffectedChainID = try engine.createPoolTask(
            title: "不受放弃撤销影响",
            now: now.addingTimeInterval(1)
        )
        let unaffectedTraceID = try engine.scheduleFromPool(
            chainID: unaffectedChainID,
            date: day1,
            today: day1,
            now: now.addingTimeInterval(1)
        )
        let active = engine.snapshot()
        let unaffectedBefore = try XCTUnwrap(engine.traces[unaffectedTraceID])
        try engine.abandonChain(
            from: abandonedTraceID,
            now: now.addingTimeInterval(2)
        )
        let abandoned = engine.snapshot()

        let undone = try NoonmarkEngine(snapshot: active)
        try undone.prepareSnapshotUndo(
            replacing: abandoned,
            now: now.addingTimeInterval(3)
        )
        let redone = try NoonmarkEngine(snapshot: abandoned)
        try redone.prepareSnapshotUndo(
            replacing: undone.snapshot(),
            now: now.addingTimeInterval(4)
        )

        let redoneChain = try XCTUnwrap(redone.chains[abandonedChainID])
        let redoneTrace = try XCTUnwrap(redone.traces[abandonedTraceID])
        XCTAssertEqual(redoneChain.state, .abandoned)
        XCTAssertEqual(redoneTrace.status, .abandoned)
        XCTAssertEqual(redoneTrace.contentUpdatedAt, redoneChain.updatedAt)
        XCTAssertEqual(redoneTrace.settledAt, redoneChain.updatedAt)
        XCTAssertEqual(redone.traces[unaffectedTraceID], unaffectedBefore)
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
        let difficultyUpdatedAt = now.addingTimeInterval(1)

        try engine.updateSubtaskDifficulty(
            currentSubtaskID,
            difficulty: .hard,
            today: day1,
            now: difficultyUpdatedAt
        )
        XCTAssertEqual(engine.subtasks[currentSubtaskID]?.difficulty, .hard)
        XCTAssertEqual(
            engine.subtasks[currentSubtaskID]?.updatedAt,
            difficultyUpdatedAt
        )

        let historicalChainID = try engine.createPoolTask(title: "历史难度锁定", now: now)
        let historicalTraceID = try engine.scheduleFromPool(chainID: historicalChainID, date: day1, today: day1, now: now)
        let historicalSubtaskID = try engine.addSubtask(traceID: historicalTraceID, title: "历史不可调整", now: now)

        XCTAssertThrowsError(
            try engine.updateSubtaskDifficulty(
                historicalSubtaskID,
                difficulty: .medium,
                today: day2,
                now: now.addingTimeInterval(1)
            )
        )
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
            try engine.updateSubtaskDifficulty(
                completedParentSubtaskID,
                difficulty: .medium,
                today: day1,
                now: now.addingTimeInterval(1)
            )
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
        let themeUpdatedAt = now.addingTimeInterval(1)
        let languageUpdatedAt = now.addingTimeInterval(2)

        XCTAssertEqual(engine.preferences.theme, .coolGray)
        XCTAssertEqual(engine.preferences.language, .chinese)
        XCTAssertEqual(
            engine.preferences.themeLanguageUpdatedAt,
            Date(timeIntervalSince1970: 0)
        )
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

        try engine.updateTheme(.warmPaper, now: themeUpdatedAt)
        XCTAssertEqual(
            engine.preferences.themeLanguageUpdatedAt,
            themeUpdatedAt
        )
        try engine.updateLanguage(.english, now: languageUpdatedAt)
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
        XCTAssertEqual(
            engine.preferences.themeLanguageUpdatedAt,
            languageUpdatedAt
        )
        XCTAssertEqual(engine.preferences.dataMode, .onlineFirst)
        XCTAssertEqual(engine.preferences.backupPolicy.frequency, .daily)
        XCTAssertEqual(engine.preferences.backupPolicy.destination, .s3)
        XCTAssertEqual(engine.preferences.localFirstSyncPolicy.endpoint, .s3)
        XCTAssertEqual(engine.preferences.localFirstSyncPolicy.mode, .automatic)
        XCTAssertEqual(engine.preferences.localFirstSyncPolicy.snapshotRetention.retentionIndexesDaily, 3)

        engine.updateDataMode(.localFirst)
        XCTAssertEqual(engine.preferences.backupPolicy, ScheduledBackupPolicy())
    }

    func testThemeLanguageClockRejectsInvalidOrNonAdvancingMutationsAndIgnoresLocalSettings() throws {
        let engine = NoonmarkEngine()
        let changedAt = now.addingTimeInterval(1)

        try engine.updateTheme(
            .coolGray,
            now: Date(timeIntervalSinceReferenceDate: .nan)
        )
        XCTAssertEqual(
            engine.preferences.themeLanguageUpdatedAt,
            Date(timeIntervalSince1970: 0)
        )

        try engine.updateTheme(.warmPaper, now: changedAt)
        XCTAssertThrowsError(
            try engine.updateLanguage(.english, now: changedAt)
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkError,
                .invalidInput("theme and language mutation time must advance")
            )
        }
        XCTAssertThrowsError(
            try engine.updateLanguage(
                .english,
                now: Date(timeIntervalSinceReferenceDate: .infinity)
            )
        )

        engine.updateDataMode(.onlineFirst)
        engine.updateBackupPolicy(
            ScheduledBackupPolicy(frequency: .weekly, destination: .s3)
        )
        engine.updateLocalFirstSyncPolicy(
            LocalFirstCloudSyncPolicy(
                enabled: true,
                endpoint: .localFolder,
                mode: .automatic
            )
        )
        engine.updateSettingsPoemDisplayPolicy(
            SettingsPoemDisplayPolicy(enabled: false, text: "只留在本机")
        )

        XCTAssertEqual(engine.preferences.theme, .warmPaper)
        XCTAssertEqual(engine.preferences.language, .chinese)
        XCTAssertEqual(engine.preferences.themeLanguageUpdatedAt, changedAt)
    }

    func testSyncedThemeLanguageApplicationPreservesDeviceLocalPreferences() throws {
        let localClock = now.addingTimeInterval(10)
        let remoteClock = now.addingTimeInterval(20)
        let local = AppPreferences(
            theme: .coolGray,
            language: .chinese,
            themeLanguageUpdatedAt: localClock,
            dataMode: .onlineFirst,
            backupPolicy: ScheduledBackupPolicy(
                frequency: .weekly,
                destination: .s3
            ),
            localFirstSyncPolicy: LocalFirstCloudSyncPolicy(
                enabled: true,
                endpoint: .localFolder,
                mode: .automatic,
                intervalSeconds: 90
            ),
            settingsPoemDisplayPolicy: SettingsPoemDisplayPolicy(
                enabled: false,
                text: "设备专属诗文"
            )
        )

        let applied = try local.applyingSyncedThemeLanguage(
            theme: .warmPaper,
            language: .english,
            updatedAt: remoteClock,
            writerID: "remote-preferences"
        )

        XCTAssertEqual(applied.theme, .warmPaper)
        XCTAssertEqual(applied.language, .english)
        XCTAssertEqual(applied.themeLanguageUpdatedAt, remoteClock)
        XCTAssertEqual(applied.dataMode, local.dataMode)
        XCTAssertEqual(applied.backupPolicy, local.backupPolicy)
        XCTAssertEqual(
            applied.localFirstSyncPolicy,
            local.localFirstSyncPolicy
        )
        XCTAssertEqual(
            applied.settingsPoemDisplayPolicy,
            local.settingsPoemDisplayPolicy
        )
        XCTAssertEqual(applied.syncEndpointOptions, local.syncEndpointOptions)

        XCTAssertThrowsError(
            try local.applyingSyncedThemeLanguage(
                theme: .warmPaper,
                language: .english,
                updatedAt: localClock.addingTimeInterval(-1),
                writerID: "remote-preferences"
            )
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkError,
                .invalidInput(
                    "synced theme and language clock cannot move backwards"
                )
            )
        }
    }

    func testThemeLanguageVersionOrderUsesRawWriterIdentity() {
        let clock = now.addingTimeInterval(30)

        XCTAssertEqual(
            AppPreferences.themeLanguageVersionOrder(
                clock: clock,
                writerID: "mac-a",
                comparedToClock: clock,
                writerID: " mac-a"
            ),
            .orderedDescending
        )

        let engine = NoonmarkEngine()
        XCTAssertNoThrow(
            try engine.updateTheme(
                .warmPaper,
                writerID: " mac-a",
                now: clock
            )
        )
        XCTAssertEqual(
            engine.preferences.themeLanguageWriterID,
            " mac-a"
        )
    }

    func testSnapshotCodableRoundTripsWithCallerProvidedExactDateStrategy() throws {
        let exactNow = Date(timeIntervalSinceReferenceDate: 805_912_493.447_825)
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "导出导入数据包",
            descriptionText: "验证 JSON 数据包能恢复核心状态。",
            initialNoteBody: "第一期手动数据交换。",
            now: exactNow
        )
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: day1,
            today: day1,
            now: exactNow.addingTimeInterval(1.000_173)
        )
        _ = try engine.addSubtask(
            traceID: traceID,
            title: "覆盖 snapshot Codable",
            difficulty: .medium,
            now: exactNow.addingTimeInterval(2.000_347)
        )
        engine.updateDailyReview(
            date: day1,
            summary: "导出前状态完整。",
            unfinishedReason: "无。",
            tomorrowNote: "导入后继续验证。",
            now: exactNow.addingTimeInterval(3.000_521)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSinceReferenceDate.bitPattern)
        }
        let data = try encoder.encode(engine.snapshot())

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            return Date(
                timeIntervalSinceReferenceDate: Double(
                    bitPattern: try container.decode(UInt64.self)
                )
            )
        }
        let restored = try NoonmarkEngine(snapshot: decoder.decode(NoonmarkSnapshot.self, from: data))

        XCTAssertEqual(restored.snapshot(), engine.snapshot())
        XCTAssertEqual(
            restored.chains[chainID]?.createdAt.timeIntervalSinceReferenceDate.bitPattern,
            exactNow.timeIntervalSinceReferenceDate.bitPattern
        )
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

    func testCompletionCapabilityUsesCurrentTraceStateAndSubtaskProgress() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "完成能力", now: now)
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: day1,
            today: day1,
            now: now
        )

        XCTAssertEqual(
            try engine.completionCapability(for: traceID, today: day1),
            .available(.complete)
        )

        let completedSubtaskID = try engine.addSubtask(
            traceID: traceID,
            title: "已完成子任务",
            now: now
        )
        let abandonedSubtaskID = try engine.addSubtask(
            traceID: traceID,
            title: "已废弃子任务",
            now: now
        )
        try engine.completeSubtask(
            completedSubtaskID,
            today: day1,
            now: now
        )

        XCTAssertEqual(
            try engine.completionCapability(for: traceID, today: day1),
            .unavailable(.openSubtasks)
        )

        let abandonedAt = now.addingTimeInterval(1)
        try engine.abandonSubtask(
            abandonedSubtaskID,
            today: day1,
            now: abandonedAt
        )
        XCTAssertEqual(
            engine.subtasks[abandonedSubtaskID]?.updatedAt,
            abandonedAt
        )
        XCTAssertEqual(
            engine.subtasks[abandonedSubtaskID]?.settledAt,
            abandonedAt
        )
        XCTAssertEqual(
            try engine.completionCapability(for: traceID, today: day1),
            .available(.complete)
        )

        try engine.markCompleted(
            traceID: traceID,
            today: day1,
            now: now.addingTimeInterval(2)
        )
        XCTAssertEqual(
            try engine.completionCapability(for: traceID, today: day1),
            .available(.undo)
        )

        try engine.undoCompleted(
            traceID: traceID,
            today: day1,
            now: now.addingTimeInterval(3)
        )
        XCTAssertEqual(engine.subtasks[completedSubtaskID]?.status, .completed)
        XCTAssertEqual(engine.subtasks[abandonedSubtaskID]?.status, .abandoned)
    }

    func testCompletionCapabilityRejectsWrongDateLockedDayAndUnsupportedStatus() throws {
        let engine = NoonmarkEngine()
        let historicalChainID = try engine.createPoolTask(
            title: "历史能力",
            now: now
        )
        let historicalTraceID = try engine.scheduleFromPool(
            chainID: historicalChainID,
            date: day1,
            today: day1,
            now: now
        )
        let futureChainID = try engine.createPoolTask(
            title: "未来能力",
            now: now
        )
        let futureTraceID = try engine.scheduleFromPool(
            chainID: futureChainID,
            date: day3,
            today: day2,
            now: now
        )
        let returnedChainID = try engine.createPoolTask(
            title: "回池能力",
            now: now
        )
        let returnedTraceID = try engine.scheduleFromPool(
            chainID: returnedChainID,
            date: day2,
            today: day2,
            now: now
        )
        try engine.returnToPool(
            traceID: returnedTraceID,
            today: day2,
            now: now
        )

        XCTAssertEqual(
            try engine.completionCapability(
                for: historicalTraceID,
                today: day2
            ),
            .unavailable(.historicalDay)
        )
        XCTAssertEqual(
            try engine.completionCapability(for: futureTraceID, today: day2),
            .unavailable(.futureDay)
        )
        XCTAssertEqual(
            try engine.completionCapability(for: returnedTraceID, today: day2),
            .unavailable(.unsupportedStatus(.returnedToPool))
        )

        try engine.settleDays(upTo: day2, now: now)
        XCTAssertEqual(
            try engine.completionCapability(
                for: historicalTraceID,
                today: day2
            ),
            .unavailable(.lockedDay)
        )
        XCTAssertThrowsError(
            try engine.completionCapability(
                for: DayTraceID(),
                today: day2
            )
        ) { error in
            XCTAssertEqual(error as? NoonmarkError, .notFound("day trace"))
        }
    }

    func testCurrentTraceCanCompleteWhenOnlyHistoricalChainTraceHasSubtasks() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "跨日完成能力",
            now: now
        )
        let firstTraceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: day1,
            today: day1,
            now: now
        )
        let historicalSubtaskID = try engine.addSubtask(
            traceID: firstTraceID,
            title: "历史子任务",
            now: now
        )
        try engine.completeSubtask(
            historicalSubtaskID,
            today: day1,
            now: now
        )
        let currentTraceID = try engine.continueTrace(
            traceID: firstTraceID,
            targetDate: day2,
            today: day1,
            now: now
        )

        XCTAssertTrue(
            engine.subtasks.values.contains {
                $0.traceID == firstTraceID
            }
        )
        XCTAssertTrue(
            engine.subtasks.values.allSatisfy {
                $0.traceID != currentTraceID
            }
        )
        XCTAssertEqual(
            try engine.completionCapability(
                for: currentTraceID,
                today: day2
            ),
            .available(.complete)
        )
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
