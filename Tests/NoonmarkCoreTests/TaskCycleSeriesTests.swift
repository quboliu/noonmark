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
        XCTAssertTrue(track.appears(in: .pool))
        XCTAssertFalse(track.appears(in: .future))
        XCTAssertTrue(track.appears(in: .unfinished))
        XCTAssertTrue(track.appears(in: .completed))
        XCTAssertNoThrow(try engine.snapshot().validateIntegrity())
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
        XCTAssertTrue(track.appears(in: .future))
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

    func testOneFullTrackIsSharedAcrossFutureUnfinishedAndCompletedSemantics() throws {
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
        XCTAssertTrue(track.appears(in: .future))
        XCTAssertTrue(track.appears(in: .unfinished))
        XCTAssertTrue(track.appears(in: .completed))
        XCTAssertEqual(track.completedCount, 1)
        XCTAssertEqual(track.unfinishedCount, 1)
        XCTAssertEqual(track.plannedCount, 2)
        let completedDay = try XCTUnwrap(
            track.days.first { $0.date == monday }
        )
        XCTAssertEqual(
            completedDay.navigationTarget(in: .future)?.traceID,
            mondayTrace.id
        )
        for collection in [
            TaskCycleCollection.future,
            .unfinished,
            .completed
        ] {
            let projectedTrack = try XCTUnwrap(
                engine.taskCycleTracks(
                    today: wednesday,
                    collection: collection
                ).first { $0.id == seriesID }
            )
            XCTAssertEqual(projectedTrack.days, track.days)
        }
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
        XCTAssertTrue(track.appears(in: .future))
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
        XCTAssertNil(tuesdayDay.navigationTarget(in: .pool))
        XCTAssertNil(tuesdayDay.navigationTarget(in: .future))
        XCTAssertNoThrow(try engine.snapshot().validateIntegrity())
    }

    func testReturningFutureOccurrenceToPoolDoesNotClaimItWasSkipped() throws {
        let engine = NoonmarkEngine()
        let seriesID = try engine.createTaskCycleSeries(
            title: "每日复盘",
            startDate: tuesday,
            endDate: tuesday,
            schedule: .daily,
            today: monday,
            now: now
        )
        let tuesdayTrace = try trace(
            in: engine,
            seriesID: seriesID,
            occurrenceDate: tuesday
        )

        try engine.returnToPool(
            traceID: tuesdayTrace.id,
            today: monday,
            now: now.addingTimeInterval(1)
        )

        let series = try XCTUnwrap(engine.taskCycleSeries[seriesID])
        let track = try XCTUnwrap(
            engine.taskCycleTracks(today: monday).first {
                $0.id == seriesID
            }
        )
        let day = try XCTUnwrap(track.days.first)
        XCTAssertFalse(series.isOccurrenceSkipped(tuesday))
        XCTAssertEqual(day.state, .returnedToPool)
        XCTAssertNil(day.navigationTarget(in: .pool))
        XCTAssertTrue(track.appears(in: .pool))
        XCTAssertNoThrow(try engine.snapshot().validateIntegrity())
    }

    func testReturnedOccurrenceCanBeRescheduledAndTrackFollowsItsActiveTrace() throws {
        let engine = NoonmarkEngine()
        let seriesID = try engine.createTaskCycleSeries(
            title: "每日复盘",
            startDate: tuesday,
            endDate: tuesday,
            schedule: .daily,
            today: monday,
            now: now
        )
        let originalTrace = try trace(
            in: engine,
            seriesID: seriesID,
            occurrenceDate: tuesday
        )
        try engine.returnToPool(
            traceID: originalTrace.id,
            today: monday,
            now: now.addingTimeInterval(1)
        )
        let rescheduledTraceID = try engine.scheduleFromPool(
            chainID: originalTrace.chainID,
            date: monday,
            today: monday,
            now: now.addingTimeInterval(2)
        )

        let track = try XCTUnwrap(
            engine.taskCycleTracks(today: monday).first {
                $0.id == seriesID
            }
        )
        let day = try XCTUnwrap(track.days.first)
        XCTAssertEqual(day.state, .pendingToday)
        XCTAssertEqual(
            day.navigationTarget(in: .pool),
            TaskCycleTraceTarget(
                traceID: rescheduledTraceID,
                date: monday,
                state: .pendingToday
            )
        )
        XCTAssertFalse(
            engine.taskPool().contains {
                $0.chain.id == originalTrace.chainID
            }
        )
    }

    func testStoppingSeriesPreservesFutureOccurrenceAlreadyReturnedToPool() throws {
        let engine = NoonmarkEngine()
        let seriesID = try engine.createTaskCycleSeries(
            title: "每日复盘",
            startDate: tuesday,
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
        try engine.returnToPool(
            traceID: tuesdayTrace.id,
            today: monday,
            now: now.addingTimeInterval(1)
        )

        let stoppedCount = try engine.stopTaskCycleSeries(
            seriesID: seriesID,
            today: monday,
            now: now.addingTimeInterval(2)
        )

        XCTAssertEqual(stoppedCount, 1)
        let series = try XCTUnwrap(engine.taskCycleSeries[seriesID])
        XCTAssertEqual(series.stoppedAfterDate, monday)
        XCTAssertFalse(series.isOccurrenceSkipped(tuesday))
        XCTAssertTrue(series.isOccurrenceSkipped(wednesday))
        let track = try XCTUnwrap(
            engine.taskCycleTracks(today: monday).first {
                $0.id == seriesID
            }
        )
        XCTAssertEqual(
            track.days.map(\.state),
            [.returnedToPool, .skipped]
        )
        XCTAssertTrue(track.appears(in: .pool))
        XCTAssertFalse(track.appears(in: .future))
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
        XCTAssertTrue(track.appears(in: .future))
        XCTAssertEqual(
            track.days.first?.presentationState(in: .future),
            .planned
        )
        XCTAssertEqual(
            track.days.first?.navigationTarget(in: .future),
            track.days.first?.futurePlanTarget
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
        XCTAssertTrue(track.appears(in: .completed))
        XCTAssertEqual(
            track.days.first?.completedTarget,
            TaskCycleTraceTarget(
                traceID: futureTraceID,
                date: tuesday,
                state: .completed
            )
        )
        XCTAssertEqual(
            track.days.first?.navigationTarget(in: .completed),
            track.days.first?.completedTarget
        )
        XCTAssertEqual(
            engine.taskCycleTracks(
                today: tuesday,
                collection: .completed
            ).map(\.id),
            [seriesID]
        )
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
        XCTAssertTrue(track.appears(in: .unfinished))
        let unfinishedTarget = try XCTUnwrap(
            track.days.first?.unfinishedTarget
        )
        XCTAssertEqual(unfinishedTarget.date, tuesday)
        XCTAssertEqual(unfinishedTarget.state, .unfinished)
        XCTAssertEqual(
            track.days.first?.navigationTarget(in: .unfinished),
            unfinishedTarget
        )
        XCTAssertEqual(
            engine.taskCycleTracks(
                today: wednesday,
                collection: .unfinished
            ).map(\.id),
            [seriesID]
        )
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

        XCTAssertTrue(track.appears(in: .completed))
        XCTAssertFalse(track.appears(in: .unfinished))
        XCTAssertEqual(track.completedCount, 1)
        XCTAssertEqual(track.unfinishedCount, 0)
        XCTAssertNil(track.days.first?.unfinishedTarget)
        XCTAssertEqual(
            engine.taskCycleTracks(
                today: tuesday,
                collection: .unfinished
            ).map(\.id),
            []
        )
        XCTAssertEqual(
            engine.taskCycleTracks(
                today: tuesday,
                collection: .completed
            ).map(\.id),
            [seriesID]
        )
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
