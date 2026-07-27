@testable import NoonmarkCore
import XCTest

final class TaskCycleSeriesTests: XCTestCase {
    private let monday = LocalDate("2026-07-20")
    private let tuesday = LocalDate("2026-07-21")
    private let wednesday = LocalDate("2026-07-22")
    private let thursday = LocalDate("2026-07-23")
    private let friday = LocalDate("2026-07-24")
    private let saturday = LocalDate("2026-07-25")
    private let sunday = LocalDate("2026-07-26")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCreatingDailySeriesMaterializesIndependentTaskChains() throws {
        let engine = NoonmarkEngine()

        let seriesID = try engine.createTaskCycleSeries(
            title: "每日站立伸展",
            startDate: monday,
            endDate: friday,
            schedule: .daily,
            today: monday,
            now: now
        )

        let members = engine.chains.values
            .filter { $0.cycleMembership?.seriesID == seriesID }
            .sorted {
                $0.cycleMembership!.occurrenceDate
                    < $1.cycleMembership!.occurrenceDate
            }

        XCTAssertEqual(members.count, 5)
        XCTAssertEqual(Set(members.map(\.id)).count, 5)
        let series = try XCTUnwrap(engine.taskCycleSeries[seriesID])
        XCTAssertEqual(series.title, "每日站立伸展")
        XCTAssertEqual(series.startDate, monday)
        XCTAssertEqual(series.endDate, friday)
        XCTAssertEqual(series.schedule, .daily)
        XCTAssertTrue(series.cancellationFacts.isEmpty)
        XCTAssertEqual(
            members.compactMap(\.cycleMembership?.occurrenceDate),
            [monday, tuesday, wednesday, thursday, friday]
        )
        XCTAssertTrue(members.allSatisfy { member in
            engine.traces.values.filter { $0.chainID == member.id }.count == 1
        })
        XCTAssertEqual(engine.getDayTodo(date: monday).traces.count, 1)
        XCTAssertEqual(engine.futurePlans(today: monday).count, 4)
        XCTAssertNoThrow(try engine.snapshot().validateIntegrity())
    }

    func testVisibleFuturePlansLimitsOnlyRecurringOccurrences() throws {
        let engine = NoonmarkEngine()
        _ = try engine.createTaskCycleSeries(
            title: "每日复盘",
            startDate: tuesday,
            endDate: LocalDate("2026-08-20"),
            schedule: .daily,
            today: monday,
            now: now
        )
        let ordinaryChainID = try engine.createPoolTask(
            title: "远期普通任务",
            now: now.addingTimeInterval(1)
        )
        let ordinaryTraceID = try engine.scheduleFromPool(
            chainID: ordinaryChainID,
            date: LocalDate("2026-09-01"),
            today: monday,
            now: now.addingTimeInterval(2)
        )

        let sevenDays = engine.visibleFuturePlans(
            today: monday,
            recurringVisibilityDays: 7
        )
        let fifteenDays = engine.visibleFuturePlans(
            today: monday,
            recurringVisibilityDays: 15
        )
        let thirtyDays = engine.visibleFuturePlans(
            today: monday,
            recurringVisibilityDays: 30
        )

        XCTAssertEqual(
            sevenDays.count {
                engine.chains[$0.trace.chainID]?.cycleMembership != nil
            },
            7
        )
        XCTAssertEqual(
            fifteenDays.count {
                engine.chains[$0.trace.chainID]?.cycleMembership != nil
            },
            15
        )
        XCTAssertEqual(
            thirtyDays.count {
                engine.chains[$0.trace.chainID]?.cycleMembership != nil
            },
            30
        )
        XCTAssertTrue(
            sevenDays.contains {
                $0.trace.id == ordinaryTraceID
            }
        )
        XCTAssertEqual(
            engine.visibleFuturePlans(
                today: monday,
                recurringVisibilityDays: 0
            ).map(\.trace.id),
            [ordinaryTraceID]
        )
    }

    func testRecurringOccurrencesStayOutOfGenericLifecyclePools() throws {
        let engine = NoonmarkEngine()
        let seriesID = try engine.createTaskCycleSeries(
            title: "每日复盘",
            startDate: monday,
            endDate: wednesday,
            schedule: .daily,
            today: monday,
            now: now
        )
        let mondayTrace = try trace(
            in: engine,
            seriesID: seriesID,
            occurrenceDate: monday
        )
        try engine.markCompleted(
            traceID: mondayTrace.id,
            today: monday,
            now: now.addingTimeInterval(1)
        )
        try engine.settleDays(
            upTo: wednesday,
            now: now.addingTimeInterval(2)
        )

        XCTAssertTrue(engine.taskPool().isEmpty)
        XCTAssertTrue(engine.unfinishedPool().isEmpty)
        XCTAssertTrue(engine.completedPool().isEmpty)
        XCTAssertTrue(engine.completedTaskHierarchies().isEmpty)
        XCTAssertEqual(
            engine.getDayTodo(date: monday).traces.map(\.id),
            [mondayTrace.id]
        )
        let track = try XCTUnwrap(
            engine.taskCycleTracks(today: wednesday).first {
                $0.id == seriesID
            }
        )
        XCTAssertEqual(track.completedCount, 1)
        XCTAssertEqual(track.unfinishedCount, 1)
    }

    func testCalendarExcludesRecurringOccurrencesWhileDayTodoKeepsThem() throws {
        let engine = NoonmarkEngine()
        let ordinaryChainID = try engine.createPoolTask(
            title: "普通今日任务",
            now: now
        )
        let ordinaryTraceID = try engine.scheduleFromPool(
            chainID: ordinaryChainID,
            date: monday,
            today: monday,
            now: now.addingTimeInterval(1)
        )
        let seriesID = try engine.createTaskCycleSeries(
            title: "每日复盘",
            startDate: monday,
            endDate: monday,
            schedule: .daily,
            today: monday,
            now: now.addingTimeInterval(2)
        )
        let recurringTrace = try trace(
            in: engine,
            seriesID: seriesID,
            occurrenceDate: monday
        )

        XCTAssertEqual(
            Set(engine.getDayTodo(date: monday).traces.map(\.id)),
            [ordinaryTraceID, recurringTrace.id]
        )
        XCTAssertEqual(
            engine.calendarTraces(for: monday).map(\.id),
            [ordinaryTraceID]
        )
        XCTAssertEqual(engine.dailyReviewStats(date: monday).total, 2)
        XCTAssertEqual(engine.calendarReviewStats(date: monday).total, 1)
        XCTAssertEqual(engine.calendarSummary(for: monday).total, 1)
    }

    func testRecurringOccurrenceCannotReturnToTaskPool() throws {
        let engine = NoonmarkEngine()
        let seriesID = try engine.createTaskCycleSeries(
            title: "每日复盘",
            startDate: tuesday,
            endDate: tuesday,
            schedule: .daily,
            today: monday,
            now: now
        )
        let occurrence = try trace(
            in: engine,
            seriesID: seriesID,
            occurrenceDate: tuesday
        )
        let before = engine.snapshot()

        XCTAssertThrowsError(
            try engine.returnToPool(
                traceID: occurrence.id,
                today: monday,
                now: now.addingTimeInterval(1)
            )
        )
        XCTAssertEqual(engine.snapshot(), before)
        XCTAssertTrue(engine.taskPool().isEmpty)
    }

    func testRecurringOccurrenceCannotUseCurrentDayDraftDeletion() throws {
        let engine = NoonmarkEngine()
        let seriesID = try engine.createTaskCycleSeries(
            title: "每日复盘",
            startDate: monday,
            endDate: monday,
            schedule: .daily,
            today: monday,
            now: now
        )
        let occurrence = try trace(
            in: engine,
            seriesID: seriesID,
            occurrenceDate: monday
        )
        let before = engine.snapshot()

        XCTAssertFalse(
            engine.canDeleteNewCurrentDayTask(
                traceID: occurrence.id,
                today: monday
            )
        )
        XCTAssertThrowsError(
            try engine.deleteNewCurrentDayTask(
                traceID: occurrence.id,
                today: monday,
                now: now.addingTimeInterval(1)
            )
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkError,
                .invalidTransition(
                    "recurring occurrences must be managed from recurring plans"
                )
            )
        }
        XCTAssertEqual(engine.snapshot(), before)
    }

    func testEveryTwoDaysScheduleIsAnchoredToTheSeriesStart() throws {
        let engine = NoonmarkEngine()

        let seriesID = try engine.createTaskCycleSeries(
            title: "隔天整理",
            startDate: monday,
            endDate: sunday,
            schedule: .everyDays(2),
            today: monday,
            now: now
        )

        XCTAssertEqual(
            engine.chains.values.compactMap { chain in
                guard chain.cycleMembership?.seriesID == seriesID else {
                    return nil
                }
                return chain.cycleMembership?.occurrenceDate
            }.sorted(),
            [monday, wednesday, friday, sunday]
        )
    }

    func testDurationEndConditionMaterializesThatManyCalendarDays() throws {
        let engine = NoonmarkEngine()

        let seriesID = try engine.createTaskCycleSeries(
            title: "三天复盘",
            startDate: monday,
            schedule: .daily,
            endCondition: .durationDays(3),
            today: monday,
            now: now
        )

        let series = try XCTUnwrap(engine.taskCycleSeries[seriesID])
        XCTAssertEqual(series.endCondition, .durationDays(3))
        XCTAssertEqual(series.endDate, wednesday)
        XCTAssertEqual(
            engine.taskCycleTracks(today: monday)
                .first { $0.id == seriesID }?.days.map(\.date),
            [monday, tuesday, wednesday]
        )
    }

    func testUnstartedPlanCanReviseItsStartDateWithoutRewritingEarlierPlanFacts() throws {
        let engine = NoonmarkEngine()
        let seriesID = try engine.createTaskCycleSeries(
            title: "尚未开始的周期",
            startDate: tuesday,
            schedule: .daily,
            endCondition: .durationDays(3),
            today: monday,
            now: now
        )

        XCTAssertTrue(
            engine.canReviseTaskCycleStartDate(
                seriesID: seriesID,
                today: monday
            )
        )

        let outcome = try engine.reviseTaskCycleSeries(
            seriesID: seriesID,
            startDate: wednesday,
            schedule: .everyDays(2),
            endCondition: .durationDays(3),
            today: monday,
            now: now.addingTimeInterval(1)
        )

        let series = try XCTUnwrap(engine.taskCycleSeries[seriesID])
        XCTAssertEqual(series.startDate, wednesday)
        XCTAssertEqual(series.endDate, friday)
        XCTAssertEqual(outcome.effectiveFrom, wednesday)
        XCTAssertEqual(outcome.cancelledOccurrenceCount, 2)
        XCTAssertEqual(outcome.createdOccurrenceCount, 1)
        XCTAssertEqual(
            series.planRevisions.map(\.endConditionAnchorDate),
            [tuesday, wednesday]
        )
        XCTAssertEqual(
            engine.taskCycleTracks(today: monday)
                .first { $0.id == seriesID }?.days.map(\.state),
            [.skipped, .planned, .skipped, .planned]
        )
        XCTAssertNoThrow(try engine.snapshot().validateIntegrity())
    }

    func testStartedPlanRejectsAStartDateRevision() throws {
        let engine = NoonmarkEngine()
        let seriesID = try engine.createTaskCycleSeries(
            title: "已经开始的周期",
            startDate: monday,
            schedule: .daily,
            endCondition: .durationDays(3),
            today: monday,
            now: now
        )

        XCTAssertFalse(
            engine.canReviseTaskCycleStartDate(
                seriesID: seriesID,
                today: monday
            )
        )
        XCTAssertThrowsError(
            try engine.reviseTaskCycleSeries(
                seriesID: seriesID,
                startDate: tuesday,
                schedule: .daily,
                endCondition: .durationDays(3),
                today: monday,
                now: now.addingTimeInterval(1)
            )
        )
        XCTAssertEqual(
            engine.taskCycleSeries[seriesID]?.startDate,
            monday
        )
        XCTAssertNoThrow(try engine.snapshot().validateIntegrity())
    }

    func testPlanRevisionReplacesOnlyFutureScheduleFromTomorrow() throws {
        let engine = NoonmarkEngine()
        let seriesID = try engine.createTaskCycleSeries(
            title: "调整频率",
            startDate: monday,
            endDate: sunday,
            schedule: .daily,
            today: monday,
            now: now
        )
        try engine.settleDays(
            upTo: wednesday,
            now: now.addingTimeInterval(1)
        )

        let outcome = try engine.reviseTaskCycleSeries(
            seriesID: seriesID,
            schedule: .everyDays(2),
            endCondition: .onDate(sunday),
            today: wednesday,
            now: now.addingTimeInterval(2)
        )

        XCTAssertEqual(outcome.effectiveFrom, thursday)
        XCTAssertEqual(outcome.cancelledOccurrenceCount, 2)
        XCTAssertEqual(outcome.createdOccurrenceCount, 0)
        let series = try XCTUnwrap(engine.taskCycleSeries[seriesID])
        XCTAssertEqual(series.planRevisions.count, 2)
        XCTAssertEqual(series.schedule, .everyDays(2))
        XCTAssertEqual(
            engine.taskCycleTracks(today: wednesday)
                .first { $0.id == seriesID }?.days.map(\.state),
            [
                .unfinished,
                .unfinished,
                .pendingToday,
                .planned,
                .skipped,
                .planned,
                .skipped
            ]
        )
        XCTAssertNoThrow(try engine.snapshot().validateIntegrity())
    }

    func testCompletionTargetStopsOnlyAfterCompletedDaysAreLocked() throws {
        let engine = NoonmarkEngine()
        let seriesID = try engine.createTaskCycleSeries(
            title: "完成两次即结束",
            startDate: monday,
            schedule: .daily,
            endCondition: .completionTarget(
                count: 2,
                latestDate: friday
            ),
            today: monday,
            now: now
        )
        let mondayTrace = try trace(
            in: engine,
            seriesID: seriesID,
            occurrenceDate: monday
        )
        try engine.markCompleted(
            traceID: mondayTrace.id,
            today: monday,
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(
            try engine.reconcileTaskCycleSeries(
                today: monday,
                now: now.addingTimeInterval(2)
            ).cancelledOccurrenceCount,
            0
        )

        try engine.settleDays(
            upTo: tuesday,
            now: now.addingTimeInterval(3)
        )
        let tuesdayTrace = try trace(
            in: engine,
            seriesID: seriesID,
            occurrenceDate: tuesday
        )
        try engine.markCompleted(
            traceID: tuesdayTrace.id,
            today: tuesday,
            now: now.addingTimeInterval(4)
        )
        XCTAssertEqual(
            try engine.reconcileTaskCycleSeries(
                today: tuesday,
                now: now.addingTimeInterval(5)
            ).cancelledOccurrenceCount,
            0
        )

        try engine.settleDays(
            upTo: wednesday,
            now: now.addingTimeInterval(6)
        )
        let outcome = try engine.reconcileTaskCycleSeries(
            today: wednesday,
            now: now.addingTimeInterval(7)
        )

        XCTAssertEqual(outcome.cancelledOccurrenceCount, 3)
        XCTAssertEqual(
            engine.taskCycleSeries[seriesID]?.stoppedAfterDate,
            tuesday
        )
        let track = try XCTUnwrap(
            engine.taskCycleTracks(today: wednesday)
                .first { $0.id == seriesID }
        )
        XCTAssertEqual(
            track.days.map(\.state),
            [.completed, .completed, .skipped, .skipped, .skipped]
        )
        XCTAssertEqual(
            track.lifecycle,
            .ended(endDate: tuesday)
        )
    }

    func testTemplateContentEditPreservesHistoryAndUpdatesEditableOccurrences() throws {
        let engine = NoonmarkEngine()
        let originalSubtask = PlannedSubtask(
            title: "旧步骤",
            position: 1,
            now: now
        )
        let seriesID = try engine.createTaskCycleSeries(
            title: "原任务",
            descriptionText: "旧说明",
            plannedSubtasks: [originalSubtask],
            startDate: monday,
            schedule: .daily,
            endCondition: .durationDays(3),
            today: monday,
            now: now
        )
        let mondayTrace = try trace(
            in: engine,
            seriesID: seriesID,
            occurrenceDate: monday
        )
        let mondaySubtask = try XCTUnwrap(
            engine.subtasks.values.first {
                $0.traceID == mondayTrace.id && $0.status == .pending
            }
        )
        try engine.completeSubtask(
            mondaySubtask.id,
            today: monday,
            now: now.addingTimeInterval(0.5)
        )
        try engine.markCompleted(
            traceID: mondayTrace.id,
            today: monday,
            now: now.addingTimeInterval(1)
        )
        try engine.settleDays(
            upTo: tuesday,
            now: now.addingTimeInterval(2)
        )
        let newSubtask = PlannedSubtask(
            title: "新步骤",
            position: 1,
            now: now.addingTimeInterval(3)
        )

        try engine.updateTaskCycleTemplateContent(
            seriesID: seriesID,
            title: "新任务",
            descriptionText: "新说明",
            plannedSubtasks: [newSubtask],
            today: tuesday,
            now: now.addingTimeInterval(3)
        )

        let series = try XCTUnwrap(engine.taskCycleSeries[seriesID])
        XCTAssertEqual(series.title, "新任务")
        XCTAssertEqual(series.descriptionText, "新说明")
        XCTAssertEqual(series.plannedSubtasks.map(\.title), ["新步骤"])
        let historicalDefinition = try XCTUnwrap(
            engine.definitions[mondayTrace.definitionID]
        )
        XCTAssertEqual(historicalDefinition.title, "原任务")
        XCTAssertEqual(
            historicalDefinition.plannedSubtasks.map(\.title),
            ["旧步骤"]
        )
        for date in [tuesday, wednesday] {
            let editableTrace = try trace(
                in: engine,
                seriesID: seriesID,
                occurrenceDate: date
            )
            let definition = try XCTUnwrap(
                engine.definitions[editableTrace.definitionID]
            )
            XCTAssertEqual(definition.title, "新任务")
            XCTAssertEqual(definition.descriptionText, "新说明")
            XCTAssertEqual(
                definition.plannedSubtasks.map(\.title),
                ["新步骤"]
            )
        }
        let tuesdayTrace = try trace(
            in: engine,
            seriesID: seriesID,
            occurrenceDate: tuesday
        )
        XCTAssertEqual(
            engine.subtasks.values
                .filter {
                    $0.traceID == tuesdayTrace.id
                        && $0.isUserPresentable
                }
                .map(\.title),
            ["新步骤"]
        )
        let wednesdayTrace = try trace(
            in: engine,
            seriesID: seriesID,
            occurrenceDate: wednesday
        )
        XCTAssertEqual(
            engine.subtasks.values
                .filter {
                    $0.traceID == wednesdayTrace.id
                        && $0.isUserPresentable
                }
                .map(\.title),
            ["新步骤"]
        )
        XCTAssertNoThrow(try engine.snapshot().validateIntegrity())
    }

    func testDeletingCategoryUngroupsRecurringParentAndFutureOccurrencesWithoutRewritingHistory() throws {
        let engine = NoonmarkEngine()
        let seriesID = try engine.createTaskCycleSeries(
            title: "每日发布复盘",
            startDate: monday,
            endDate: wednesday,
            schedule: .daily,
            today: monday,
            now: now
        )
        let members = engine.chains.values
            .filter { $0.cycleMembership?.seriesID == seriesID }
            .sorted {
                $0.cycleMembership!.occurrenceDate
                    < $1.cycleMembership!.occurrenceDate
            }
        let anchorChainID = try XCTUnwrap(members.first?.id)
        let interactionID = UUID()
        let plan = try engine.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: anchorChainID,
                    category: .new(
                        name: "工作",
                        colorHex: "#2A6FDB"
                    ),
                    labels: [
                        .new(name: "复盘", colorHex: "#0E9488")
                    ]
                )
            ),
            source: .userDirect,
            interactionID: interactionID,
            now: now.addingTimeInterval(1)
        )
        _ = try engine.commitClassification(
            plan,
            confirmation: .user(decisionID: interactionID),
            now: now.addingTimeInterval(1)
        )
        let anchorClassification = try XCTUnwrap(
            engine.snapshot().classifications
                .currentByChainID[anchorChainID]
        )
        let categoryID = try XCTUnwrap(
            anchorClassification.categoryID
        )
        try engine.setTaskCycleTemplateClassification(
            seriesID: seriesID,
            categoryID: categoryID,
            labelIDs: anchorClassification.labelIDs,
            now: now.addingTimeInterval(1)
        )
        for member in members.dropFirst() {
            _ = try engine.inheritCurrentClassification(
                from: anchorChainID,
                to: member.id,
                now: now.addingTimeInterval(1)
            )
        }
        try engine.settleDays(
            upTo: tuesday,
            now: now.addingTimeInterval(2)
        )
        let mondayTrace = try trace(
            in: engine,
            seriesID: seriesID,
            occurrenceDate: monday
        )

        _ = try engine.deleteTaskCategoryFromToday(
            categoryID,
            today: tuesday,
            decisionID: UUID(),
            now: now.addingTimeInterval(3)
        )

        let parent = try engine.taskCycleTemplateClassification(
            seriesID: seriesID
        )
        XCTAssertNil(parent.category)
        XCTAssertEqual(parent.labels.map(\.name), ["复盘"])
        for member in members.dropFirst() {
            guard case let .task(classification) = try engine
                .classification(.task(member.id))
            else {
                return XCTFail("预期重复实例当前分类")
            }
            XCTAssertNil(classification.category)
            XCTAssertEqual(classification.labels.map(\.name), ["复盘"])
        }
        guard case let .history(history) = try engine
            .classification(.history(mondayTrace.id))
        else {
            return XCTFail("预期重复实例历史分类")
        }
        XCTAssertEqual(history.category?.name, "工作")
        XCTAssertEqual(history.labels.map(\.name), ["复盘"])
        XCTAssertNoThrow(try engine.snapshot().validateIntegrity())
    }

    func testPlanRevisionCanReintroduceAnOccurrenceItPreviouslyRemoved() throws {
        let engine = NoonmarkEngine()
        let seriesID = try engine.createTaskCycleSeries(
            title: "恢复频率",
            startDate: monday,
            schedule: .daily,
            endCondition: .durationDays(5),
            today: monday,
            now: now
        )
        _ = try engine.reviseTaskCycleSeries(
            seriesID: seriesID,
            schedule: .everyDays(2),
            endCondition: .durationDays(5),
            today: monday,
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(
            engine.taskCycleTracks(today: monday)
                .first { $0.id == seriesID }?.days[2].state,
            .skipped
        )

        let outcome = try engine.reviseTaskCycleSeries(
            seriesID: seriesID,
            schedule: .daily,
            endCondition: .durationDays(5),
            today: tuesday,
            now: now.addingTimeInterval(2)
        )

        XCTAssertEqual(outcome.createdOccurrenceCount, 2)
        XCTAssertEqual(
            engine.taskCycleTracks(today: tuesday)
                .first { $0.id == seriesID }?.days.map(\.state),
            [.pendingPast, .pendingToday, .planned, .planned, .planned]
        )
        XCTAssertNoThrow(try engine.snapshot().validateIntegrity())
    }

    func testPlanRevisionClassificationBoundariesEndAtFinalSnapshotAfterReactivation() throws {
        let engine = NoonmarkEngine()
        let seriesID = try engine.createTaskCycleSeries(
            title: "恢复并延长频率",
            startDate: monday,
            schedule: .daily,
            endCondition: .durationDays(5),
            today: monday,
            now: now
        )
        let members = engine.chains.values
            .filter { $0.cycleMembership?.seriesID == seriesID }
            .sorted {
                $0.cycleMembership!.occurrenceDate
                    < $1.cycleMembership!.occurrenceDate
            }
        let anchorChainID = try XCTUnwrap(members.first?.id)
        let interactionID = UUID()
        let plan = try engine.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: anchorChainID,
                    category: .new(
                        name: "习惯",
                        colorHex: "#2A6FDB"
                    ),
                    labels: []
                )
            ),
            source: .userDirect,
            interactionID: interactionID,
            now: now.addingTimeInterval(1)
        )
        _ = try engine.commitClassification(
            plan,
            confirmation: .user(decisionID: interactionID),
            now: now.addingTimeInterval(1)
        )
        let classification = try XCTUnwrap(
            engine.snapshot().classifications
                .currentByChainID[anchorChainID]
        )
        try engine.setTaskCycleTemplateClassification(
            seriesID: seriesID,
            categoryID: classification.categoryID,
            labelIDs: classification.labelIDs,
            now: now.addingTimeInterval(1)
        )
        for member in members.dropFirst() {
            _ = try engine.inheritCurrentClassification(
                from: anchorChainID,
                to: member.id,
                now: now.addingTimeInterval(1)
            )
        }
        _ = try engine.reviseTaskCycleSeries(
            seriesID: seriesID,
            schedule: .everyDays(2),
            endCondition: .durationDays(5),
            today: monday,
            now: now.addingTimeInterval(2)
        )

        let outcome = try engine.reviseTaskCycleSeries(
            seriesID: seriesID,
            schedule: .daily,
            endCondition: .durationDays(7),
            today: tuesday,
            now: now.addingTimeInterval(3)
        )

        XCTAssertEqual(outcome.createdOccurrenceCount, 4)
        XCTAssertFalse(outcome.classificationCommitBoundaries.isEmpty)
        XCTAssertEqual(
            outcome.classificationCommitBoundaries.last,
            engine.snapshot()
        )
        XCTAssertNoThrow(try engine.snapshot().validateIntegrity())
    }

    func testConvertingPoolTaskAdoptsItsChainAsFirstOccurrence() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "既有晨跑",
            descriptionText: "保留原任务说明",
            initialNoteBody: "保留原任务附言",
            now: now
        )
        _ = try engine.addPlannedSubtask(
            chainID: chainID,
            title: "保留原规划子任务",
            now: now
        )
        let originalChain = try XCTUnwrap(engine.chains[chainID])
        let originalDefinition = try XCTUnwrap(
            engine.taskPool().first {
                $0.chain.id == chainID
            }?.definition
        )

        let seriesID = try engine.convertTaskToCycleSeries(
            chainID: chainID,
            startDate: monday,
            endDate: wednesday,
            schedule: .daily,
            today: monday,
            now: now.addingTimeInterval(1)
        )

        XCTAssertEqual(
            engine.chains[chainID]?.cycleMembership,
            TaskCycleMembership(
                seriesID: seriesID,
                occurrenceDate: monday
            )
        )
        XCTAssertEqual(
            engine.chains[chainID]?.noteEntries,
            originalChain.noteEntries
        )
        XCTAssertFalse(
            engine.taskPool().contains { $0.chain.id == chainID }
        )
        let mondayTrace = try XCTUnwrap(
            engine.traces.values.first {
                $0.chainID == chainID && $0.date == monday
            }
        )
        XCTAssertEqual(mondayTrace.status, .pending)
        let members = engine.chains.values.filter {
            $0.cycleMembership?.seriesID == seriesID
        }
        XCTAssertEqual(members.count, 3)
        XCTAssertEqual(
            Set(members.compactMap(\.cycleMembership?.occurrenceDate)),
            Set([monday, tuesday, wednesday])
        )
        let memberDefinitions = members.compactMap { member in
            engine.definitions.values.first {
                $0.chainID == member.id && $0.supersededAt == nil
            }
        }
        XCTAssertEqual(memberDefinitions.count, 3)
        XCTAssertTrue(memberDefinitions.allSatisfy {
            $0.title == originalDefinition.title
                && $0.descriptionText
                == originalDefinition.descriptionText
                && $0.plannedSubtasks.map(\.title)
                == ["保留原规划子任务"]
                && $0.plannedSubtasks.map(\.lineageID)
                == originalDefinition.plannedSubtasks
                    .map(\.lineageID)
        })
        XCTAssertNoThrow(try engine.snapshot().validateIntegrity())
    }

    func testConvertingScheduledTaskKeepsItsExistingTraceAsFirstOccurrence() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "既有今日计划",
            now: now
        )
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: monday,
            today: monday,
            now: now
        )

        let seriesID = try engine.convertTaskToCycleSeries(
            chainID: chainID,
            startDate: monday,
            endDate: wednesday,
            schedule: .daily,
            today: monday,
            now: now.addingTimeInterval(1)
        )

        XCTAssertEqual(
            engine.traces[traceID]?.status,
            .pending
        )
        XCTAssertEqual(
            engine.traces[traceID]?.date,
            monday
        )
        XCTAssertEqual(
            engine.chains[chainID]?.cycleMembership,
            TaskCycleMembership(
                seriesID: seriesID,
                occurrenceDate: monday
            )
        )
        XCTAssertEqual(
            engine.chains.values.count {
                $0.cycleMembership?.seriesID == seriesID
            },
            3
        )
        XCTAssertNoThrow(try engine.snapshot().validateIntegrity())
    }

    func testSkippingOneFutureOccurrencePreservesSeriesAndOtherDates() throws {
        let engine = NoonmarkEngine()
        let seriesID = try engine.createTaskCycleSeries(
            title: "每日复盘",
            startDate: monday,
            endDate: wednesday,
            schedule: .daily,
            today: monday,
            now: now
        )

        try engine.skipTaskCycleOccurrence(
            seriesID: seriesID,
            occurrenceDate: tuesday,
            today: monday,
            now: now.addingTimeInterval(1)
        )

        let tuesdayTrace = try trace(
            in: engine,
            seriesID: seriesID,
            occurrenceDate: tuesday
        )
        let wednesdayTrace = try trace(
            in: engine,
            seriesID: seriesID,
            occurrenceDate: wednesday
        )
        XCTAssertEqual(tuesdayTrace.status, .cancelledDraft)
        XCTAssertEqual(tuesdayTrace.draftCancelledOn, monday)
        XCTAssertEqual(wednesdayTrace.status, .pending)
        let series = try XCTUnwrap(engine.taskCycleSeries[seriesID])
        XCTAssertTrue(series.isOccurrenceSkipped(tuesday))
        XCTAssertFalse(series.isOccurrenceSkipped(wednesday))
        XCTAssertFalse(
            engine.taskPool().contains {
                $0.chain.cycleMembership?.seriesID == seriesID
            }
        )
        let track = try XCTUnwrap(
            engine.taskCycleTracks(today: monday).first { $0.id == seriesID }
        )
        XCTAssertEqual(
            track.days.map(\.state),
            [.pendingToday, .skipped, .planned]
        )
        XCTAssertNoThrow(try engine.snapshot().validateIntegrity())
    }

    func testStoppingSeriesCancelsOnlyFuturePendingOccurrences() throws {
        let engine = NoonmarkEngine()
        let seriesID = try engine.createTaskCycleSeries(
            title: "每日复盘",
            startDate: monday,
            endDate: friday,
            schedule: .daily,
            today: monday,
            now: now
        )
        let mondayTrace = try trace(
            in: engine,
            seriesID: seriesID,
            occurrenceDate: monday
        )
        try engine.markCompleted(
            traceID: mondayTrace.id,
            today: monday,
            now: now.addingTimeInterval(1)
        )
        try engine.settleDays(
            upTo: wednesday,
            now: now.addingTimeInterval(2)
        )

        let stoppedCount = try engine.stopTaskCycleSeries(
            seriesID: seriesID,
            today: wednesday,
            now: now.addingTimeInterval(3)
        )

        XCTAssertEqual(stoppedCount, 2)
        let series = try XCTUnwrap(engine.taskCycleSeries[seriesID])
        XCTAssertEqual(series.stoppedAfterDate, wednesday)
        let track = try XCTUnwrap(
            engine.taskCycleTracks(today: wednesday).first {
                $0.id == seriesID
            }
        )
        XCTAssertEqual(
            track.days.map(\.state),
            [.completed, .unfinished, .pendingToday, .skipped, .skipped]
        )
        XCTAssertEqual(track.completedCount, 1)
        XCTAssertEqual(track.unfinishedCount, 1)
        XCTAssertEqual(
            track.lifecycle,
            .stopped(stopDate: wednesday)
        )
        XCTAssertTrue(engine.taskPool().isEmpty)
        XCTAssertTrue(engine.unfinishedPool().isEmpty)
        XCTAssertTrue(engine.completedPool().isEmpty)
        XCTAssertNoThrow(try engine.snapshot().validateIntegrity())
    }

    func testPoolProjectionHidesSeriesWhenOnlyTodayRemains() throws {
        let engine = NoonmarkEngine()
        let seriesID = try engine.createTaskCycleSeries(
            title: "仅今天一次",
            startDate: monday,
            endDate: monday,
            schedule: .daily,
            today: monday,
            now: now
        )

        let track = try XCTUnwrap(
            engine.taskCycleTracks(today: monday).first {
                $0.id == seriesID
            }
        )

        XCTAssertEqual(track.id, seriesID)
        XCTAssertTrue(engine.taskPool().isEmpty)
    }

    func testPoolProjectionHidesSeriesWithOnlyFutureObligations() throws {
        let engine = NoonmarkEngine()
        let seriesID = try engine.createTaskCycleSeries(
            title: "尚未开始的重复计划",
            startDate: tuesday,
            endDate: wednesday,
            schedule: .daily,
            today: monday,
            now: now
        )

        let track = try XCTUnwrap(
            engine.taskCycleTracks(today: monday).first {
                $0.id == seriesID
            }
        )

        XCTAssertEqual(track.futurePlanCount, 2)
        XCTAssertEqual(track.pooledOccurrenceCount, 0)
        XCTAssertEqual(
            engine.visibleFuturePlans(
                today: monday,
                recurringVisibilityDays: 7
            ).count,
            2
        )
        XCTAssertEqual(
            engine.taskCycleTracks(today: monday).map(\.id),
            [seriesID]
        )
        XCTAssertTrue(engine.taskPool().isEmpty)
    }

    func testPoolProjectionHidesNaturallyEndedHistoricalSeries() throws {
        let engine = NoonmarkEngine()
        let seriesID = try engine.createTaskCycleSeries(
            title: "已经结束",
            startDate: monday,
            endDate: monday,
            schedule: .daily,
            today: monday,
            now: now
        )
        let mondayTrace = try trace(
            in: engine,
            seriesID: seriesID,
            occurrenceDate: monday
        )
        try engine.markCompleted(
            traceID: mondayTrace.id,
            today: monday,
            now: now.addingTimeInterval(1)
        )

        let track = try XCTUnwrap(
            engine.taskCycleTracks(today: tuesday).first {
                $0.id == seriesID
            }
        )

        XCTAssertEqual(track.id, seriesID)
        XCTAssertTrue(engine.taskPool().isEmpty)
        XCTAssertEqual(track.completedCount, 1)
        XCTAssertTrue(engine.completedPool().isEmpty)
    }

    func testTrackLifecycleDistinguishesUpcomingActiveAndEndedSeries() throws {
        let engine = NoonmarkEngine()
        let endedID = try engine.createTaskCycleSeries(
            title: "已经结束",
            startDate: monday,
            endDate: monday,
            schedule: .daily,
            today: monday,
            now: now
        )
        let activeID = try engine.createTaskCycleSeries(
            title: "正在进行",
            startDate: monday,
            endDate: friday,
            schedule: .daily,
            today: monday,
            now: now.addingTimeInterval(1)
        )
        let upcomingID = try engine.createTaskCycleSeries(
            title: "即将开始",
            startDate: wednesday,
            endDate: friday,
            schedule: .daily,
            today: monday,
            now: now.addingTimeInterval(2)
        )

        XCTAssertEqual(
            engine.taskCycleTracks(today: monday)
                .first { $0.id == endedID }?.lifecycle,
            .active(nextDate: nil)
        )

        let tracks = Dictionary(
            uniqueKeysWithValues: engine.taskCycleTracks(today: tuesday)
                .map { ($0.id, $0) }
        )

        XCTAssertEqual(
            tracks[endedID]?.lifecycle,
            .ended(endDate: monday)
        )
        XCTAssertEqual(
            tracks[activeID]?.lifecycle,
            .active(nextDate: wednesday)
        )
        XCTAssertEqual(
            tracks[upcomingID]?.lifecycle,
            .upcoming(startDate: wednesday)
        )
    }

    func testTracksSortActiveThenUpcomingThenEndedThenStopped() throws {
        let engine = NoonmarkEngine()
        let endedID = try engine.createTaskCycleSeries(
            title: "已经结束",
            startDate: monday,
            endDate: monday,
            schedule: .daily,
            today: monday,
            now: now
        )
        let activeID = try engine.createTaskCycleSeries(
            title: "正在进行",
            startDate: tuesday,
            endDate: friday,
            schedule: .daily,
            today: tuesday,
            now: now.addingTimeInterval(1)
        )
        let upcomingID = try engine.createTaskCycleSeries(
            title: "即将开始",
            startDate: wednesday,
            endDate: friday,
            schedule: .daily,
            today: tuesday,
            now: now.addingTimeInterval(2)
        )
        let stoppedID = try engine.createTaskCycleSeries(
            title: "已经停止",
            startDate: monday,
            endDate: friday,
            schedule: .daily,
            today: monday,
            now: now.addingTimeInterval(3)
        )
        _ = try engine.stopTaskCycleSeries(
            seriesID: stoppedID,
            today: tuesday,
            now: now.addingTimeInterval(4)
        )

        XCTAssertEqual(
            engine.taskCycleTracks(today: tuesday).map(\.id),
            [activeID, upcomingID, endedID, stoppedID]
        )
    }

    func testSkipRejectsTodayAndHistoricalOccurrence() throws {
        let engine = NoonmarkEngine()
        let seriesID = try engine.createTaskCycleSeries(
            title: "每日复盘",
            startDate: monday,
            endDate: tuesday,
            schedule: .daily,
            today: monday,
            now: now
        )

        XCTAssertThrowsError(
            try engine.skipTaskCycleOccurrence(
                seriesID: seriesID,
                occurrenceDate: monday,
                today: monday,
                now: now.addingTimeInterval(1)
            )
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkError,
                .invalidTransition(
                    "only a future pending task cycle occurrence can be skipped"
                )
            )
        }
    }

    func testStoppingSeriesPreservesTodayOccurrenceDeferredIntoFuture() throws {
        let engine = NoonmarkEngine()
        let seriesID = try engine.createTaskCycleSeries(
            title: "每日复盘",
            startDate: monday,
            endDate: wednesday,
            schedule: .daily,
            today: monday,
            now: now
        )
        let mondayTrace = try trace(
            in: engine,
            seriesID: seriesID,
            occurrenceDate: monday
        )
        let deferredTraceID = try engine.deferCurrentTrace(
            traceID: mondayTrace.id,
            targetDate: friday,
            today: monday,
            now: now.addingTimeInterval(1)
        )

        XCTAssertThrowsError(
            try engine.skipTaskCycleOccurrence(
                seriesID: seriesID,
                occurrenceDate: monday,
                today: monday,
                now: now.addingTimeInterval(2)
            )
        )

        let stoppedCount = try engine.stopTaskCycleSeries(
            seriesID: seriesID,
            today: monday,
            now: now.addingTimeInterval(3)
        )

        XCTAssertEqual(stoppedCount, 2)
        XCTAssertEqual(engine.traces[deferredTraceID]?.status, .pending)
        XCTAssertEqual(engine.traces[deferredTraceID]?.date, friday)
        let track = try XCTUnwrap(
            engine.taskCycleTracks(today: monday).first {
                $0.id == seriesID
            }
        )
        XCTAssertEqual(track.days.map(\.state), [.deferred, .skipped, .skipped])
        XCTAssertEqual(
            track.days.first?.futurePlanTarget?.traceID,
            deferredTraceID
        )
        XCTAssertEqual(
            engine.visibleFuturePlans(
                today: monday,
                recurringVisibilityDays: 7
            ).map(\.trace.id),
            [deferredTraceID]
        )
        XCTAssertNoThrow(try engine.snapshot().validateIntegrity())
    }

    func testSnapshotRejectsMissingSeriesParent() throws {
        let engine = NoonmarkEngine()
        _ = try engine.createTaskCycleSeries(
            title: "每日复盘",
            startDate: monday,
            endDate: tuesday,
            schedule: .daily,
            today: monday,
            now: now
        )
        var snapshot = engine.snapshot()
        snapshot.taskCycleSeries.removeAll()

        XCTAssertThrowsError(try snapshot.validateIntegrity())
    }

    func testWeekdaySeriesTrackShowsEveryCalendarDayIncludingOffScheduleDays() throws {
        let engine = NoonmarkEngine()

        let seriesID = try engine.createTaskCycleSeries(
            title: "工作日收件箱清理",
            startDate: monday,
            endDate: sunday,
            schedule: .weekdays,
            today: monday,
            now: now
        )

        let track = try XCTUnwrap(
            engine.taskCycleTracks(today: monday).first {
                $0.id == seriesID
            }
        )

        XCTAssertEqual(track.days.map(\.date), [
            monday,
            tuesday,
            wednesday,
            thursday,
            friday,
            saturday,
            sunday
        ])
        XCTAssertEqual(
            track.days.map(\.state),
            [
                .pendingToday,
                .planned,
                .planned,
                .planned,
                .planned,
                .notScheduled,
                .notScheduled
            ]
        )
        XCTAssertEqual(track.scheduledCount, 5)
        XCTAssertEqual(track.days.count, 7)
    }

    func testOneFullTrackKeepsAllStatesInsideRecurringPlans() throws {
        let engine = NoonmarkEngine()
        let seriesID = try engine.createTaskCycleSeries(
            title: "每日复盘",
            startDate: monday,
            endDate: friday,
            schedule: .daily,
            today: monday,
            now: now
        )
        let mondayTrace = try trace(
            in: engine,
            seriesID: seriesID,
            occurrenceDate: monday
        )
        try engine.markCompleted(
            traceID: mondayTrace.id,
            today: monday,
            now: now.addingTimeInterval(1)
        )
        try engine.settleDays(
            upTo: wednesday,
            now: now.addingTimeInterval(2)
        )

        let track = try XCTUnwrap(
            engine.taskCycleTracks(today: wednesday).first {
                $0.id == seriesID
            }
        )

        XCTAssertEqual(
            track.days.map(\.state),
            [.completed, .unfinished, .pendingToday, .planned, .planned]
        )
        XCTAssertEqual(track.completedCount, 1)
        XCTAssertEqual(track.unfinishedCount, 1)
        XCTAssertEqual(track.plannedCount, 2)
        let completedDay = try XCTUnwrap(
            track.days.first { $0.date == monday }
        )
        XCTAssertEqual(
            completedDay.navigationTarget?.traceID,
            mondayTrace.id
        )
        XCTAssertTrue(engine.unfinishedPool().isEmpty)
        XCTAssertTrue(engine.completedPool().isEmpty)
    }

    func testReschedulingFutureOccurrenceKeepsCycleMembershipValid() throws {
        let engine = NoonmarkEngine()
        let seriesID = try engine.createTaskCycleSeries(
            title: "每日复盘",
            startDate: monday,
            endDate: friday,
            schedule: .daily,
            today: monday,
            now: now
        )
        let tuesdayTrace = try trace(
            in: engine,
            seriesID: seriesID,
            occurrenceDate: tuesday
        )

        try engine.rescheduleFuturePlan(
            traceID: tuesdayTrace.id,
            targetDate: sunday,
            today: monday,
            now: now.addingTimeInterval(1)
        )

        XCTAssertEqual(engine.traces[tuesdayTrace.id]?.date, sunday)
        XCTAssertNoThrow(try engine.snapshot().validateIntegrity())
        let track = try XCTUnwrap(
            engine.taskCycleTracks(today: monday).first {
                $0.id == seriesID
            }
        )
        let tuesdayDay = try XCTUnwrap(
            track.days.first { $0.date == tuesday }
        )
        XCTAssertEqual(tuesdayDay.state, .planned)
        XCTAssertEqual(
            tuesdayDay.occurrenceTarget,
            TaskCycleTraceTarget(
                traceID: tuesdayTrace.id,
                date: sunday,
                state: .planned
            )
        )
        XCTAssertEqual(
            tuesdayDay.futurePlanTarget,
            tuesdayDay.occurrenceTarget
        )
        XCTAssertEqual(
            engine.visibleFuturePlans(
                today: monday,
                recurringVisibilityDays: 7
            ).first {
                $0.trace.id == tuesdayTrace.id
            }?.trace.date,
            sunday
        )
    }

    func testSkippingRescheduledOccurrenceShowsSkippedSlotWithoutNavigation() throws {
        let engine = NoonmarkEngine()
        let seriesID = try engine.createTaskCycleSeries(
            title: "每日复盘",
            startDate: monday,
            endDate: wednesday,
            schedule: .daily,
            today: monday,
            now: now
        )
        let tuesdayTrace = try trace(
            in: engine,
            seriesID: seriesID,
            occurrenceDate: tuesday
        )
        try engine.rescheduleFuturePlan(
            traceID: tuesdayTrace.id,
            targetDate: friday,
            today: monday,
            now: now.addingTimeInterval(1)
        )

        try engine.skipTaskCycleOccurrence(
            seriesID: seriesID,
            occurrenceDate: tuesday,
            today: monday,
            now: now.addingTimeInterval(2)
        )

        let track = try XCTUnwrap(
            engine.taskCycleTracks(today: monday).first {
                $0.id == seriesID
            }
        )
        let tuesdayDay = try XCTUnwrap(
            track.days.first { $0.date == tuesday }
        )
        XCTAssertEqual(tuesdayDay.state, .skipped)
        XCTAssertNil(tuesdayDay.futurePlanTarget)
        XCTAssertNil(tuesdayDay.navigationTarget)
        XCTAssertNoThrow(try engine.snapshot().validateIntegrity())
    }

    func testSkipFailureDoesNotPartiallyCancelOccurrence() throws {
        let engine = try engineWithAdvancedSeriesClock()
        let seriesID = try XCTUnwrap(engine.taskCycleSeries.keys.first)
        let before = engine.snapshot()

        XCTAssertThrowsError(
            try engine.skipTaskCycleOccurrence(
                seriesID: seriesID,
                occurrenceDate: tuesday,
                today: monday,
                now: now.addingTimeInterval(10)
            )
        )

        XCTAssertEqual(engine.snapshot(), before)
        XCTAssertNoThrow(try engine.snapshot().validateIntegrity())
    }

    func testStopFailureDoesNotPartiallyCancelAnyOccurrence() throws {
        let engine = try engineWithAdvancedSeriesClock()
        let seriesID = try XCTUnwrap(engine.taskCycleSeries.keys.first)
        let before = engine.snapshot()

        XCTAssertThrowsError(
            try engine.stopTaskCycleSeries(
                seriesID: seriesID,
                today: monday,
                now: now.addingTimeInterval(10)
            )
        )

        XCTAssertEqual(engine.snapshot(), before)
        XCTAssertNoThrow(try engine.snapshot().validateIntegrity())
    }

    func testDeferringTheFinalOccurrenceKeepsItsFutureTargetVisible() throws {
        let engine = NoonmarkEngine()
        let seriesID = try engine.createTaskCycleSeries(
            title: "每日复盘",
            startDate: monday,
            endDate: monday,
            schedule: .daily,
            today: monday,
            now: now
        )
        let mondayTrace = try trace(
            in: engine,
            seriesID: seriesID,
            occurrenceDate: monday
        )

        let futureTraceID = try engine.deferCurrentTrace(
            traceID: mondayTrace.id,
            targetDate: tuesday,
            today: monday,
            now: now.addingTimeInterval(1)
        )

        let track = try XCTUnwrap(
            engine.taskCycleTracks(today: monday).first {
                $0.id == seriesID
            }
        )
        XCTAssertEqual(track.days.map(\.state), [.deferred])
        XCTAssertEqual(track.futurePlanCount, 1)
        XCTAssertEqual(
            track.days.first?.futurePlanTarget,
            TaskCycleTraceTarget(
                traceID: futureTraceID,
                date: tuesday,
                state: .planned
            )
        )
        XCTAssertEqual(
            track.days.first?.state,
            .deferred
        )
        XCTAssertEqual(
            track.days.first?.navigationTarget?.traceID,
            mondayTrace.id
        )
        XCTAssertEqual(
            engine.visibleFuturePlans(
                today: monday,
                recurringVisibilityDays: 7
            ).map(\.trace.id),
            [futureTraceID]
        )
    }

    func testCompletedDeferredTargetKeepsTheOccurrenceVisible() throws {
        let engine = NoonmarkEngine()
        let seriesID = try engine.createTaskCycleSeries(
            title: "每日复盘",
            startDate: monday,
            endDate: monday,
            schedule: .daily,
            today: monday,
            now: now
        )
        let mondayTrace = try trace(
            in: engine,
            seriesID: seriesID,
            occurrenceDate: monday
        )
        let futureTraceID = try engine.deferCurrentTrace(
            traceID: mondayTrace.id,
            targetDate: tuesday,
            today: monday,
            now: now.addingTimeInterval(1)
        )

        try engine.markCompleted(
            traceID: futureTraceID,
            today: tuesday,
            now: now.addingTimeInterval(2)
        )

        let track = try XCTUnwrap(
            engine.taskCycleTracks(today: tuesday).first {
                $0.id == seriesID
            }
        )
        XCTAssertEqual(
            track.days.first?.completedTarget,
            TaskCycleTraceTarget(
                traceID: futureTraceID,
                date: tuesday,
                state: .completed
            )
        )
        XCTAssertEqual(
            track.days.first?.navigationTarget?.traceID,
            mondayTrace.id
        )
        XCTAssertTrue(engine.completedPool().isEmpty)
    }

    func testUnfinishedDeferredTargetKeepsTheOccurrenceVisible() throws {
        let engine = NoonmarkEngine()
        let seriesID = try engine.createTaskCycleSeries(
            title: "每日复盘",
            startDate: monday,
            endDate: monday,
            schedule: .daily,
            today: monday,
            now: now
        )
        let mondayTrace = try trace(
            in: engine,
            seriesID: seriesID,
            occurrenceDate: monday
        )
        _ = try engine.deferCurrentTrace(
            traceID: mondayTrace.id,
            targetDate: tuesday,
            today: monday,
            now: now.addingTimeInterval(1)
        )

        try engine.settleDays(
            upTo: wednesday,
            now: now.addingTimeInterval(2)
        )

        let track = try XCTUnwrap(
            engine.taskCycleTracks(today: wednesday).first {
                $0.id == seriesID
            }
        )
        let unfinishedTarget = try XCTUnwrap(
            track.days.first?.unfinishedTarget
        )
        XCTAssertEqual(unfinishedTarget.date, tuesday)
        XCTAssertEqual(unfinishedTarget.state, .unfinished)
        XCTAssertEqual(
            track.days.first?.navigationTarget?.traceID,
            mondayTrace.id
        )
        XCTAssertTrue(engine.unfinishedPool().isEmpty)
    }

    func testCompletedContinuationRemovesTheOccurrenceFromUnfinished() throws {
        let engine = NoonmarkEngine()
        let seriesID = try engine.createTaskCycleSeries(
            title: "每日复盘",
            startDate: monday,
            endDate: monday,
            schedule: .daily,
            today: monday,
            now: now
        )
        let mondayTrace = try trace(
            in: engine,
            seriesID: seriesID,
            occurrenceDate: monday
        )
        try engine.settleDays(
            upTo: tuesday,
            now: now.addingTimeInterval(1)
        )
        let continuedTraceID = try engine.continueUnfinishedTrace(
            traceID: mondayTrace.id,
            targetDate: tuesday,
            today: tuesday,
            now: now.addingTimeInterval(2)
        )
        try engine.markCompleted(
            traceID: continuedTraceID,
            today: tuesday,
            now: now.addingTimeInterval(3)
        )

        let track = try XCTUnwrap(
            engine.taskCycleTracks(today: tuesday).first {
                $0.id == seriesID
            }
        )

        XCTAssertEqual(track.completedCount, 1)
        XCTAssertEqual(track.unfinishedCount, 0)
        XCTAssertNil(track.days.first?.unfinishedTarget)
        XCTAssertTrue(engine.unfinishedPool().isEmpty)
        XCTAssertTrue(engine.completedPool().isEmpty)
    }

    func testSnapshotRejectsInvalidSeriesScheduleAndDuplicateOccurrences() throws {
        let engine = NoonmarkEngine()
        let seriesID = try engine.createTaskCycleSeries(
            title: "每日阅读",
            startDate: monday,
            endDate: friday,
            schedule: .daily,
            today: monday,
            now: now
        )
        var snapshot = engine.snapshot()
        let indexes = snapshot.chains.indices.filter {
            snapshot.chains[$0].cycleMembership?.seriesID == seriesID
        }
        XCTAssertGreaterThanOrEqual(indexes.count, 2)

        var divergent = snapshot
        let seriesIndex = try XCTUnwrap(
            divergent.taskCycleSeries.firstIndex { $0.id == seriesID }
        )
        divergent.taskCycleSeries[seriesIndex] = TaskCycleSeries(
            id: seriesID,
            title: "每日阅读",
            startDate: tuesday,
            endDate: friday,
            schedule: .daily,
            createdAt: now
        )
        XCTAssertThrowsError(try divergent.validateIntegrity())

        let duplicateDate = try XCTUnwrap(
            snapshot.chains[indexes[0]].cycleMembership?.occurrenceDate
        )
        snapshot.chains[indexes[1]].cycleMembership = TaskCycleMembership(
            seriesID: seriesID,
            occurrenceDate: duplicateDate
        )
        XCTAssertThrowsError(try snapshot.validateIntegrity())
    }

    func testSeriesCreationRejectsAnUnboundedMaterializationWindow() {
        let engine = NoonmarkEngine()

        XCTAssertThrowsError(
            try engine.createTaskCycleSeries(
                title: "过长周期",
                startDate: monday,
                endDate: LocalDate("2027-07-21"),
                schedule: .daily,
                today: monday,
                now: now
            )
        )
        XCTAssertTrue(engine.chains.isEmpty)
        XCTAssertTrue(engine.traces.isEmpty)
    }

    func testSnapshotRejectsAnUnboundedSeriesBeforeCheckingOccurrences() throws {
        let engine = NoonmarkEngine()
        let seriesID = try engine.createTaskCycleSeries(
            title: "导入的过长周期",
            startDate: monday,
            endDate: monday,
            schedule: .daily,
            today: monday,
            now: now
        )
        var snapshot = engine.snapshot()
        let seriesIndex = try XCTUnwrap(
            snapshot.taskCycleSeries.firstIndex {
                $0.id == seriesID
            }
        )
        snapshot.taskCycleSeries[seriesIndex] = TaskCycleSeries(
            id: seriesID,
            title: "导入的过长周期",
            startDate: monday,
            endDate: LocalDate("2028-07-20"),
            schedule: .daily,
            createdAt: now
        )

        XCTAssertThrowsError(try snapshot.validateIntegrity()) { error in
            XCTAssertEqual(
                error as? NoonmarkError,
                .invalidInput(
                    "task cycle cannot materialize more than 366 calendar days"
                )
            )
        }
    }

    func testSnapshotRejectsCycleMembershipWithoutAnyTrace() throws {
        let engine = NoonmarkEngine()
        let seriesID = try engine.createTaskCycleSeries(
            title: "缺失实例",
            startDate: monday,
            endDate: tuesday,
            schedule: .daily,
            today: monday,
            now: now
        )
        var snapshot = engine.snapshot()
        let missingChainID = try XCTUnwrap(
            snapshot.chains.first {
                $0.cycleMembership?.seriesID == seriesID
                    && $0.cycleMembership?.occurrenceDate == monday
            }?.id
        )
        snapshot.traces.removeAll { $0.chainID == missingChainID }

        XCTAssertThrowsError(try snapshot.validateIntegrity())
    }

    func testSnapshotRejectsAMissingScheduledOccurrence() throws {
        let engine = NoonmarkEngine()
        let seriesID = try engine.createTaskCycleSeries(
            title: "缺失实例",
            startDate: monday,
            endDate: tuesday,
            schedule: .daily,
            today: monday,
            now: now
        )
        var snapshot = engine.snapshot()
        let missingChainID = try XCTUnwrap(
            snapshot.chains.first {
                $0.cycleMembership?.seriesID == seriesID
                    && $0.cycleMembership?.occurrenceDate == monday
            }?.id
        )
        snapshot.chains.removeAll { $0.id == missingChainID }
        snapshot.definitions.removeAll { $0.chainID == missingChainID }
        snapshot.traces.removeAll { $0.chainID == missingChainID }

        XCTAssertThrowsError(try snapshot.validateIntegrity())
    }

    private func trace(
        in engine: NoonmarkEngine,
        seriesID: TaskCycleSeriesID,
        occurrenceDate: LocalDate
    ) throws -> DayTrace {
        let chainID = try XCTUnwrap(
            engine.chains.values.first {
                $0.cycleMembership?.seriesID == seriesID
                    && $0.cycleMembership?.occurrenceDate == occurrenceDate
            }?.id
        )
        return try XCTUnwrap(
            engine.traces.values.first { $0.chainID == chainID }
        )
    }

    private func engineWithAdvancedSeriesClock() throws -> NoonmarkEngine {
        let source = NoonmarkEngine()
        let seriesID = try source.createTaskCycleSeries(
            title: "远端更新后的每日复盘",
            startDate: tuesday,
            endDate: wednesday,
            schedule: .daily,
            today: monday,
            now: now
        )
        var snapshot = source.snapshot()
        let index = try XCTUnwrap(
            snapshot.taskCycleSeries.firstIndex {
                $0.id == seriesID
            }
        )
        let series = snapshot.taskCycleSeries[index]
        snapshot.taskCycleSeries[index] = TaskCycleSeries(
            id: series.id,
            title: series.title,
            descriptionText: series.descriptionText,
            startDate: series.startDate,
            endDate: series.endDate,
            schedule: series.schedule,
            cancellationFacts: series.cancellationFacts,
            createdAt: series.createdAt,
            updatedAt: now.addingTimeInterval(20)
        )
        return try NoonmarkEngine(snapshot: snapshot)
    }
}
