import Foundation
@_spi(ClassificationUserDecision) import NoonmarkCore

public struct NoonmarkDemoFixture {
    public let anchorDate: LocalDate
    public let storyDates: [LocalDate]
    public let engine: NoonmarkEngine
    public let report: NoonmarkDemoCoverageReport

    public static func make(
        anchorDate: LocalDate,
        language: AppLanguage = .chinese
    ) throws -> NoonmarkDemoFixture {
        let text = DemoStoryText.forLanguage(language)
        let storyDates = try DemoCalendar.storyDates(
            endingAt: anchorDate,
            count: 365
        )
        guard let foregroundStartDate = storyDates.suffix(10).first else {
            throw NoonmarkDemoFixtureError.invalidDateRange
        }
        let engine = NoonmarkEngine()
        var history = AnnualDemoHistory(
            engine: engine,
            dates: Array(storyDates.dropLast(10)),
            foregroundStartDate: foregroundStartDate,
            anchorDate: anchorDate,
            text: text
        )
        let historyResult = try history.replay()
        var story = DemoStory(
            engine: engine,
            dates: Array(storyDates.suffix(10)),
            text: text
        )
        let ideaStoryFacts = try story.replay()
        let report = NoonmarkDemoCoverageReport(
            engine: engine,
            storyDates: storyDates,
            anchorDate: anchorDate,
            repeatedFeatureCounts: historyResult.featureCounts,
            featureReplayDates: historyResult.featureReplayDates,
            restoredIdeaCount: ideaStoryFacts.restoredIdeaCount
        )
        guard report.isComplete else {
            throw NoonmarkDemoFixtureError.incompleteCoverage(
                report.missingRequirements
            )
        }
        return NoonmarkDemoFixture(
            anchorDate: anchorDate,
            storyDates: storyDates,
            engine: engine,
            report: report
        )
    }
}

public enum NoonmarkDemoFixtureError: Error, Equatable {
    case invalidDateRange
    case incompleteCoverage([String])
}

public struct NoonmarkDemoTaskCycleLifecycleCounts: Codable, Equatable,
    Sendable
{
    public let active: Int
    public let upcoming: Int
    public let ended: Int
    public let stopped: Int

    public init(
        active: Int,
        upcoming: Int,
        ended: Int,
        stopped: Int
    ) {
        self.active = active
        self.upcoming = upcoming
        self.ended = ended
        self.stopped = stopped
    }
}

public struct NoonmarkDemoRepeatedFeatureCounts: Codable, Equatable,
    Sendable
{
    public fileprivate(set) var poolTaskCreation = 0
    public fileprivate(set) var poolTaskTextEditing = 0
    public fileprivate(set) var taskTitleEditing = 0
    public fileprivate(set) var taskDescriptionEditing = 0
    public fileprivate(set) var noteLifecycle = 0
    public fileprivate(set) var plannedSubtaskEditing = 0
    public fileprivate(set) var scheduling = 0
    public fileprivate(set) var priorityReordering = 0
    public fileprivate(set) var pinLifecycle = 0
    public fileprivate(set) var manualProgressEditing = 0
    public fileprivate(set) var taskCompletion = 0
    public fileprivate(set) var taskCompletionUndo = 0
    public fileprivate(set) var unfinishedContinuation = 0
    public fileprivate(set) var deferral = 0
    public fileprivate(set) var deferralWithdrawal = 0
    public fileprivate(set) var taskChange = 0
    public fileprivate(set) var returnToPool = 0
    public fileprivate(set) var abandonment = 0
    public fileprivate(set) var reactivation = 0
    public fileprivate(set) var copying = 0
    public fileprivate(set) var futureRescheduling = 0
    public fileprivate(set) var subtaskCreation = 0
    public fileprivate(set) var subtaskTextEditing = 0
    public fileprivate(set) var subtaskDifficultyEditing = 0
    public fileprivate(set) var subtaskCompletion = 0
    public fileprivate(set) var subtaskCompletionUndo = 0
    public fileprivate(set) var subtaskAbandonment = 0
    public fileprivate(set) var subtaskDeletion = 0
    public fileprivate(set) var classification = 0

    public var minimumUsageCount: Int {
        [
            poolTaskCreation,
            poolTaskTextEditing,
            taskTitleEditing,
            taskDescriptionEditing,
            noteLifecycle,
            plannedSubtaskEditing,
            scheduling,
            priorityReordering,
            pinLifecycle,
            manualProgressEditing,
            taskCompletion,
            taskCompletionUndo,
            unfinishedContinuation,
            deferral,
            deferralWithdrawal,
            taskChange,
            returnToPool,
            abandonment,
            reactivation,
            copying,
            futureRescheduling,
            subtaskCreation,
            subtaskTextEditing,
            subtaskDifficultyEditing,
            subtaskCompletion,
            subtaskCompletionUndo,
            subtaskAbandonment,
            subtaskDeletion,
            classification
        ].min() ?? 0
    }
}

public struct NoonmarkDemoCoverageReport: Codable, Equatable, Sendable {
    public let fixtureProfile: String
    public let storyDates: [String]
    public let storyDayCount: Int
    public let storyDateGapCount: Int
    public let storyDuplicateDateCount: Int
    public let storyDayWithOrdinaryTraceCount: Int
    public let featureReplayDates: [String]
    public let featureReplayDayCount: Int
    public let featureReplayCoveredQuarterCount: Int
    public let minimumRepeatedFeatureUsageCount: Int
    public let repeatedFeatureCounts: NoonmarkDemoRepeatedFeatureCounts
    public let dayTodoCount: Int
    public let taskPoolCount: Int
    public let futurePlanCount: Int
    public let unfinishedCount: Int
    public let completedCount: Int
    public let traceStatusCounts: [String: Int]
    public let subtaskStatusCounts: [String: Int]
    public let pinnedTraceCount: Int
    public let withdrawableDeferralCount: Int
    public let reviewedDayCount: Int
    public let categoryCount: Int
    public let labelCount: Int
    public let classifiedTaskCount: Int
    public let deletableCategoryBoundaryCount: Int
    public let poolTaskWithPlannedSubtasksCount: Int
    public let taskWithNotesCount: Int
    public let taskWithDescriptionCount: Int
    public let taskWithCollapsibleTrailCount: Int
    public let continuableUnfinishedTaskCount: Int
    public let taskCycleSeriesCount: Int
    public let taskCycleOccurrenceCount: Int
    public let classifiedTaskCycleSeriesCount: Int
    public let taskCycleSeriesWithPlannedSubtasksCount: Int
    public let taskCyclePlanRevisionCount: Int
    public let taskCycleSkippedOccurrenceCount: Int
    public let taskCycleRescheduledOccurrenceCount: Int
    public let unstartedTaskCycleSeriesCount: Int
    public let taskCycleLifecycleCounts:
        NoonmarkDemoTaskCycleLifecycleCounts
    public let visibleRecurringFutureOccurrenceCount: Int
    public let recurringCollectionLeakCount: Int
    public let openParentWithCompletedChildrenCount: Int
    public let completedParentWithCompletedChildrenCount: Int
    public let ideaCount: Int
    public let ideaDayCount: Int
    public let ideaReviewCandidateCount: Int
    public let labeledIdeaCount: Int
    public let categorizedIdeaCount: Int
    public let editedIdeaCount: Int
    public let tombstonedIdeaCount: Int
    public let ideaTimelineTombstoneLeakCount: Int
    public let stickyNoteCount: Int
    public let restoredIdeaCount: Int

    public var missingRequirements: [String] {
        var missing: [String] = []
        require(
            fixtureProfile == "annual-v1",
            "年度 fixture profile",
            into: &missing
        )
        require(storyDates.count == 365, "三百六十五个连续使用日", into: &missing)
        require(storyDayCount == 365, "年度日期计数", into: &missing)
        require(storyDateGapCount == 0, "年度日期连续无缺口", into: &missing)
        require(
            storyDuplicateDateCount == 0,
            "年度日期没有重复",
            into: &missing
        )
        require(
            storyDayWithOrdinaryTraceCount == 365,
            "全年每天都有普通任务轨迹",
            into: &missing
        )
        require(
            featureReplayDayCount == 12,
            "十二个分布式功能重放日",
            into: &missing
        )
        require(
            featureReplayCoveredQuarterCount == 4,
            "功能重放覆盖四个季度",
            into: &missing
        )
        require(
            repeatedFeatureCounts.minimumUsageCount >= 12,
            "普通任务能力各至少重放十二次",
            into: &missing
        )
        require(
            minimumRepeatedFeatureUsageCount >= 12,
            "可序列化最低功能重放次数",
            into: &missing
        )
        require(dayTodoCount > 0, "Day Todo 非空", into: &missing)
        require(taskPoolCount > 0, "任务池非空", into: &missing)
        require(futurePlanCount > 0, "未来计划非空", into: &missing)
        require(unfinishedCount > 0, "未完成池非空", into: &missing)
        require(completedCount > 0, "已完成池非空", into: &missing)
        for status in [
            TraceStatus.pending,
            .completed,
            .unfinished,
            .deferred,
            .changed,
            .returnedToPool,
            .abandoned
        ] {
            require(
                traceStatusCounts[status.rawValue, default: 0] >= 12,
                "任务轨迹状态 \(status.rawValue) 至少十二项",
                into: &missing
            )
        }
        for status in [
            SubtaskStatus.pending,
            .completed,
            .unfinished,
            .abandoned
        ] {
            require(
                subtaskStatusCounts[status.rawValue, default: 0] >= 12,
                "子任务状态 \(status.rawValue) 至少十二项",
                into: &missing
            )
        }
        require(pinnedTraceCount >= 2, "至少两项置顶队列", into: &missing)
        require(
            withdrawableDeferralCount > 0,
            "当天可撤回延期",
            into: &missing
        )
        require(reviewedDayCount == 365, "全年每日复盘记录", into: &missing)
        require(categoryCount >= 4, "至少四个彩色分组", into: &missing)
        require(labelCount >= 4, "至少四个彩色标签", into: &missing)
        require(classifiedTaskCount >= 120, "全年跨页面分类任务", into: &missing)
        require(
            deletableCategoryBoundaryCount > 0,
            "同时具有当前与历史引用的可删除分组",
            into: &missing
        )
        require(
            poolTaskWithPlannedSubtasksCount > 0,
            "含规划子任务的任务池任务",
            into: &missing
        )
        require(taskWithNotesCount >= 365, "全年跨状态任务附言", into: &missing)
        require(
            taskWithDescriptionCount >= 365,
            "全年跨页面任务描述",
            into: &missing
        )
        require(
            taskWithCollapsibleTrailCount >= 12,
            "至少十二条可收起多事件轨迹的普通任务",
            into: &missing
        )
        require(
            continuableUnfinishedTaskCount > 0,
            "可在未完成页原地延续的任务",
            into: &missing
        )
        require(
            taskCycleSeriesCount == 12,
            "十二条重复计划父项",
            into: &missing
        )
        require(
            taskCycleOccurrenceCount >= 500,
            "至少五百个重复计划日实例",
            into: &missing
        )
        require(
            classifiedTaskCycleSeriesCount >= 2,
            "多条重复任务父项包含分组与标签",
            into: &missing
        )
        require(
            taskCycleSeriesWithPlannedSubtasksCount >= 10,
            "至少十条重复任务父项包含规划子任务",
            into: &missing
        )
        require(
            taskCyclePlanRevisionCount >= 8,
            "至少八条重复计划修订事实",
            into: &missing
        )
        require(
            taskCycleSkippedOccurrenceCount >= 3,
            "至少三次重复实例跳过",
            into: &missing
        )
        require(
            taskCycleRescheduledOccurrenceCount >= 3,
            "至少三次重复实例改期",
            into: &missing
        )
        require(
            unstartedTaskCycleSeriesCount >= 3,
            "至少三条尚未开始的重复任务可调整开始日期",
            into: &missing
        )
        require(
            taskCycleLifecycleCounts
                == NoonmarkDemoTaskCycleLifecycleCounts(
                    active: 3,
                    upcoming: 3,
                    ended: 3,
                    stopped: 3
                ),
            "重复计划四态各三条",
            into: &missing
        )
        require(
            visibleRecurringFutureOccurrenceCount == 16,
            "未来计划展示窗口内的十六个重复日实例",
            into: &missing
        )
        require(
            recurringCollectionLeakCount == 0,
            "重复实例不外溢到任务池、未完成或已完成",
            into: &missing
        )
        require(
            openParentWithCompletedChildrenCount > 0,
            "父任务未完成时只展示已完成子任务",
            into: &missing
        )
        require(
            completedParentWithCompletedChildrenCount > 0,
            "父任务完成后的简洁子任务层级",
            into: &missing
        )
        require(ideaCount >= 6, "飞光时间线至少六条", into: &missing)
        require(ideaDayCount >= 3, "飞光跨多个自然日", into: &missing)
        require(
            ideaReviewCandidateCount > 0,
            "至少一条可进入回看的旧飞光",
            into: &missing
        )
        require(labeledIdeaCount > 0, "带标签的飞光", into: &missing)
        require(categorizedIdeaCount > 0, "带分组的飞光", into: &missing)
        require(editedIdeaCount > 0, "编辑过的飞光", into: &missing)
        require(
            tombstonedIdeaCount > 0,
            "删除后的飞光墓碑仍在状态中",
            into: &missing
        )
        require(
            ideaTimelineTombstoneLeakCount == 0,
            "飞光时间线不包含墓碑",
            into: &missing
        )
        require(stickyNoteCount >= 3, "至少三条 Sticky Note", into: &missing)
        require(
            restoredIdeaCount > 0,
            "至少一条经底层兼容命令重建的飞光",
            into: &missing
        )
        return missing
    }

    public var isComplete: Bool {
        missingRequirements.isEmpty
    }

    init(
        engine: NoonmarkEngine,
        storyDates: [LocalDate],
        anchorDate: LocalDate,
        repeatedFeatureCounts: NoonmarkDemoRepeatedFeatureCounts,
        featureReplayDates: [LocalDate],
        restoredIdeaCount: Int
    ) {
        let snapshot = engine.snapshot()
        fixtureProfile = "annual-v1"
        self.storyDates = storyDates.map(\.description)
        storyDayCount = storyDates.count
        storyDateGapCount = zip(
            storyDates,
            storyDates.dropFirst()
        ).count { current, next in
            (try? DemoCalendar.offset(current, by: 1)) != next
        }
        storyDuplicateDateCount =
            storyDates.count - Set(storyDates).count
        let storyDateSet = Set(storyDates)
        let ordinaryTraceDates: [LocalDate] =
            snapshot.traces.compactMap { trace in
                guard trace.formsDayHistory,
                      storyDateSet.contains(trace.date),
                      engine.chains[trace.chainID]?
                      .cycleMembership == nil
                else {
                    return nil
                }
                return trace.date
            }
        storyDayWithOrdinaryTraceCount =
            Set(ordinaryTraceDates).count
        self.featureReplayDates =
            featureReplayDates.map(\.description)
        featureReplayDayCount = Set(featureReplayDates).count
        featureReplayCoveredQuarterCount = Set(
            featureReplayDates.map {
                "\($0.year)-Q\((($0.month - 1) / 3) + 1)"
            }
        ).count
        minimumRepeatedFeatureUsageCount =
            repeatedFeatureCounts.minimumUsageCount
        self.repeatedFeatureCounts = repeatedFeatureCounts
        dayTodoCount = engine.getDayTodo(date: anchorDate).traces.count
        taskPoolCount = engine.taskPool().count
        futurePlanCount = engine.futurePlans(today: anchorDate).count
        unfinishedCount = engine.unfinishedPool().count
        completedCount = engine.completedPool().count
        traceStatusCounts = Dictionary(
            grouping: snapshot.traces,
            by: { $0.status.rawValue }
        ).mapValues(\.count)
        subtaskStatusCounts = Dictionary(
            grouping: snapshot.subtasks.filter(\.isUserPresentable),
            by: { $0.status.rawValue }
        ).mapValues(\.count)
        pinnedTraceCount = snapshot.traces.filter {
            $0.date == anchorDate
                && $0.status == .pending
                && $0.pinOrder != nil
        }.count
        withdrawableDeferralCount = snapshot.traces.filter {
            engine.canWithdrawDeferral(
                sourceTraceID: $0.id,
                today: anchorDate
            )
        }.count
        reviewedDayCount = snapshot.days.filter {
            $0.reviewSummary?.isEmpty == false
        }.count
        categoryCount = snapshot.classifications.categories.count
        labelCount = snapshot.classifications.labels.count
        classifiedTaskCount = snapshot.classifications.currentByChainID
            .values
            .filter {
                $0.category != nil || $0.labels.isEmpty == false
            }.count
        if let projection = try? engine.classification(.catalog),
           case let .catalog(catalog) = projection
        {
            deletableCategoryBoundaryCount = catalog.categories.count {
                $0.lifecycle == .active
                    && $0.currentUsageCount > 0
                    && $0.historicalUsageCount > 0
            }
        } else {
            deletableCategoryBoundaryCount = 0
        }
        poolTaskWithPlannedSubtasksCount = engine.taskPool().filter {
            $0.definition.plannedSubtasks.isEmpty == false
        }.count
        taskWithNotesCount = snapshot.chains.filter {
            $0.activeNoteEntries.isEmpty == false
        }.count
        taskWithDescriptionCount = snapshot.definitions.filter {
            $0.descriptionText?.isEmpty == false
        }.count
        taskWithCollapsibleTrailCount = snapshot.chains.count {
            $0.cycleMembership == nil
                && ((try? engine.taskTrail(chainID: $0.id).count) ?? 0)
                >= 3
        }
        continuableUnfinishedTaskCount = engine.unfinishedPool().count {
            $0.actionPlan.contains {
                if case .continueTrace = $0 {
                    return true
                }
                return false
            }
        }
        let cycleMemberships = snapshot.chains.compactMap(\.cycleMembership)
        taskCycleSeriesCount = snapshot.taskCycleSeries.count
        taskCycleOccurrenceCount = cycleMemberships.count
        classifiedTaskCycleSeriesCount =
            snapshot.taskCycleSeries.count {
                $0.categoryID != nil || $0.labelIDs.isEmpty == false
            }
        taskCycleSeriesWithPlannedSubtasksCount =
            snapshot.taskCycleSeries.count {
                $0.plannedSubtasks.isEmpty == false
            }
        taskCyclePlanRevisionCount = snapshot.taskCycleSeries.reduce(0) {
            $0 + $1.planRevisions.count
        }
        let cycleTracks = engine.taskCycleTracks(today: anchorDate)
        taskCycleSkippedOccurrenceCount = cycleTracks.reduce(0) {
            count, track in
            count + track.days.count { $0.state == .skipped }
        }
        taskCycleRescheduledOccurrenceCount =
            snapshot.chains.count { chain in
                guard let membership = chain.cycleMembership,
                      let trace = snapshot.traces.first(where: {
                          $0.chainID == chain.id
                              && $0.formsDayHistory
                      })
                else {
                    return false
                }
                return trace.date != membership.occurrenceDate
            }
        unstartedTaskCycleSeriesCount = snapshot.taskCycleSeries.count {
            engine.canReviseTaskCycleStartDate(
                seriesID: $0.id,
                today: anchorDate
            )
        }
        var activeCycleCount = 0
        var upcomingCycleCount = 0
        var endedCycleCount = 0
        var stoppedCycleCount = 0
        for track in cycleTracks {
            switch track.lifecycle {
            case .active:
                activeCycleCount += 1
            case .upcoming:
                upcomingCycleCount += 1
            case .ended:
                endedCycleCount += 1
            case .stopped:
                stoppedCycleCount += 1
            }
        }
        taskCycleLifecycleCounts =
            NoonmarkDemoTaskCycleLifecycleCounts(
                active: activeCycleCount,
                upcoming: upcomingCycleCount,
                ended: endedCycleCount,
                stopped: stoppedCycleCount
            )
        visibleRecurringFutureOccurrenceCount = engine
            .visibleFuturePlans(
                today: anchorDate,
                recurringVisibilityDays: 15
            )
            .count {
                engine.chains[$0.trace.chainID]?
                    .cycleMembership != nil
            }
        let recurringCalendarLeakCount = Set(
            snapshot.traces.map(\.date)
        ).reduce(into: 0) { count, date in
            count += engine.calendarTraces(for: date).count {
                engine.isRecurringTaskChain($0.chainID)
            }
        }
        recurringCollectionLeakCount =
            engine.taskPool().count {
                $0.chain.cycleMembership != nil
            }
            + engine.unfinishedPool().count {
                $0.chain.cycleMembership != nil
            }
            + engine.completedPool().count {
                engine.chains[$0.trace.chainID]?
                    .cycleMembership != nil
            }
            + recurringCalendarLeakCount
        let ordinaryCompletedHierarchies =
            engine.completedTaskHierarchies().filter {
                $0.chain.cycleMembership == nil
            }
        openParentWithCompletedChildrenCount =
            ordinaryCompletedHierarchies.count {
                $0.parentCompletion == nil
                    && $0.completedChildren.isEmpty == false
            }
        completedParentWithCompletedChildrenCount =
            ordinaryCompletedHierarchies.count {
                $0.parentCompletion != nil
                    && $0.completedChildren.isEmpty == false
            }
        let ideaTimeline = engine.ideaCollection(
            .recent,
            today: anchorDate
        ).ideas
        ideaCount = ideaTimeline.count
        ideaDayCount = Set(ideaTimeline.compactMap {
            DemoCalendar.localDate(of: $0.createdAt)
        }).count
        ideaReviewCandidateCount = engine.ideaCollection(
            .review(seed: 0, count: 5, excludingRecentDays: 7),
            today: anchorDate
        ).ideas.count
        labeledIdeaCount = ideaTimeline.count {
            $0.labelIDs.isEmpty == false
        }
        categorizedIdeaCount = ideaTimeline.count {
            $0.categoryID != nil
        }
        editedIdeaCount = ideaTimeline.count {
            $0.updatedAt > $0.createdAt
        }
        tombstonedIdeaCount = snapshot.ideas.count { $0.isDeleted }
        ideaTimelineTombstoneLeakCount = ideaTimeline.count { $0.isDeleted }
        stickyNoteCount = engine.pinnedIdeas().count
        self.restoredIdeaCount = restoredIdeaCount
    }

    private func require(
        _ condition: Bool,
        _ name: String,
        into missing: inout [String]
    ) {
        if condition == false {
            missing.append(name)
        }
    }
}

private struct AnnualDemoHistoryResult {
    let featureCounts: NoonmarkDemoRepeatedFeatureCounts
    let featureReplayDates: [LocalDate]
}

private struct AnnualDemoHistory {
    let engine: NoonmarkEngine
    let dates: [LocalDate]
    let foregroundStartDate: LocalDate
    let anchorDate: LocalDate
    let text: DemoStoryText
    private let clock = DemoClock()
    private var counts = NoonmarkDemoRepeatedFeatureCounts()

    init(
        engine: NoonmarkEngine,
        dates: [LocalDate],
        foregroundStartDate: LocalDate,
        anchorDate: LocalDate,
        text: DemoStoryText
    ) {
        self.engine = engine
        self.dates = dates
        self.foregroundStartDate = foregroundStartDate
        self.anchorDate = anchorDate
        self.text = text
    }

    mutating func replay() throws -> AnnualDemoHistoryResult {
        guard dates.count == 355 else {
            throw NoonmarkDemoFixtureError.incompleteCoverage([
                "年度历史必须包含前置三百五十五天"
            ])
        }
        try createAnnualCycleSeries()
        var nextDailyIndex = 0
        for cycleIndex in 0 ..< 12 {
            let cycleStartIndex = cycleIndex * 29
            while nextDailyIndex < cycleStartIndex {
                try replayDailyBaseline(at: nextDailyIndex)
                nextDailyIndex += 1
            }
            try replayMonthlyFeatureCycle(
                number: cycleIndex + 1,
                startingAt: cycleStartIndex
            )
            nextDailyIndex = cycleStartIndex + 4
        }
        while nextDailyIndex < dates.count {
            try replayDailyBaseline(at: nextDailyIndex)
            nextDailyIndex += 1
        }
        try engine.settleDays(
            upTo: foregroundStartDate,
            now: event(
                on: foregroundStartDate,
                hour: 0,
                minute: 1
            )
        )
        try exerciseAnchorDayDeferralWithdrawals()
        let snapshot = engine.snapshot()
        try snapshot.validateIntegrity()
        return AnnualDemoHistoryResult(
            featureCounts: counts,
            featureReplayDates: (0 ..< 12).map {
                dates[$0 * 29]
            }
        )
    }

    private mutating func createAnnualCycleSeries() throws {
        let startDate = dates[0]
        let annualEnd: TaskCycleEndCondition = .durationDays(366)
        let plannedSubtask = PlannedSubtask(
            title: text.annual.cyclePlannedSubtaskTitle,
            position: 1,
            now: event(on: startDate, hour: 5)
        )
        let activeWeekdays = try engine.createTaskCycleSeries(
            title: text.annual.annualWeekdaysTitle,
            descriptionText: text.annual.annualWeekdaysDescription,
            plannedSubtasks: [plannedSubtask],
            startDate: startDate,
            schedule: .weekdays,
            endCondition: annualEnd,
            today: startDate,
            now: event(on: startDate, hour: 5, minute: 1)
        )
        let activeWeekly = try engine.createTaskCycleSeries(
            title: text.annual.annualWeeklyTitle,
            descriptionText: text.annual.annualWeeklyDescription,
            plannedSubtasks: [plannedSubtask],
            startDate: startDate,
            schedule: .everyDays(7),
            endCondition: annualEnd,
            today: startDate,
            now: event(on: startDate, hour: 5, minute: 2)
        )

        let upcomingStartOne = try DemoCalendar.offset(
            anchorDate,
            by: 20
        )
        let upcomingStartTwo = try DemoCalendar.offset(
            anchorDate,
            by: 25
        )
        _ = try engine.createTaskCycleSeries(
            title: text.annual.upcomingWeekdaysTitle,
            descriptionText: text.annual.upcomingWeekdaysDescription,
            plannedSubtasks: [plannedSubtask],
            startDate: upcomingStartOne,
            schedule: .weekdays,
            endCondition: .durationDays(30),
            today: startDate,
            now: event(on: startDate, hour: 5, minute: 3)
        )
        _ = try engine.createTaskCycleSeries(
            title: text.annual.upcomingAlternateDayTitle,
            descriptionText: text.annual.upcomingAlternateDayDescription,
            plannedSubtasks: [plannedSubtask],
            startDate: upcomingStartTwo,
            schedule: .everyDays(2),
            endCondition: .completionTarget(
                count: 12,
                latestDate: try DemoCalendar.offset(
                    upcomingStartTwo,
                    by: 29
                )
            ),
            today: startDate,
            now: event(on: startDate, hour: 5, minute: 4)
        )

        _ = try engine.createTaskCycleSeries(
            title: text.annual.endedDailyTitle,
            descriptionText: text.annual.endedDailyDescription,
            plannedSubtasks: [plannedSubtask],
            startDate: startDate,
            schedule: .daily,
            endCondition: .durationDays(30),
            today: startDate,
            now: event(on: startDate, hour: 5, minute: 5)
        )
        _ = try engine.createTaskCycleSeries(
            title: text.annual.endedWeeklyTitle,
            descriptionText: text.annual.endedWeeklyDescription,
            plannedSubtasks: [plannedSubtask],
            startDate: startDate,
            schedule: .everyDays(7),
            endCondition: .onDate(
                try DemoCalendar.offset(startDate, by: 29)
            ),
            today: startDate,
            now: event(on: startDate, hour: 5, minute: 6)
        )

        let stoppedWeekdays = try engine.createTaskCycleSeries(
            title: text.annual.stoppedWeekdaysTitle,
            descriptionText: text.annual.stoppedWeekdaysDescription,
            plannedSubtasks: [plannedSubtask],
            startDate: startDate,
            schedule: .weekdays,
            endCondition: annualEnd,
            today: startDate,
            now: event(on: startDate, hour: 5, minute: 7)
        )
        let stoppedWeekly = try engine.createTaskCycleSeries(
            title: text.annual.stoppedWeeklyTitle,
            descriptionText: text.annual.stoppedWeeklyDescription,
            plannedSubtasks: [plannedSubtask],
            startDate: startDate,
            schedule: .everyDays(7),
            endCondition: annualEnd,
            today: startDate,
            now: event(on: startDate, hour: 5, minute: 8)
        )
        _ = try engine.stopTaskCycleSeries(
            seriesID: stoppedWeekdays,
            today: startDate,
            now: event(on: startDate, hour: 5, minute: 9)
        )
        _ = try engine.stopTaskCycleSeries(
            seriesID: stoppedWeekly,
            today: startDate,
            now: event(on: startDate, hour: 5, minute: 10)
        )

        _ = try engine.reviseTaskCycleSeries(
            seriesID: activeWeekdays,
            schedule: .everyDays(2),
            endCondition: annualEnd,
            today: startDate,
            now: event(on: startDate, hour: 5, minute: 11)
        )
        _ = try engine.reviseTaskCycleSeries(
            seriesID: activeWeekdays,
            schedule: .weekdays,
            endCondition: annualEnd,
            today: startDate,
            now: event(on: startDate, hour: 5, minute: 12)
        )
        _ = try engine.reviseTaskCycleSeries(
            seriesID: activeWeekly,
            schedule: .everyDays(6),
            endCondition: annualEnd,
            today: startDate,
            now: event(on: startDate, hour: 5, minute: 13)
        )

        try exerciseCycleOccurrenceExceptions(
            seriesID: activeWeekdays,
            today: startDate,
            now: event(on: startDate, hour: 5, minute: 14)
        )
        try exerciseCycleOccurrenceExceptions(
            seriesID: activeWeekly,
            today: startDate,
            now: event(on: startDate, hour: 5, minute: 15)
        )
    }

    private mutating func exerciseCycleOccurrenceExceptions(
        seriesID: TaskCycleSeriesID,
        today: LocalDate,
        now: Date
    ) throws {
        let members = engine.chains.values.compactMap {
            chain -> (chain: TaskChain, trace: DayTrace)? in
            guard chain.cycleMembership?.seriesID == seriesID,
                  (chain.cycleMembership?.occurrenceDate ?? today)
                  > today,
                  let trace = engine.traces.values.first(where: {
                      $0.chainID == chain.id
                          && $0.status == .pending
                          && $0.date > today
                  })
            else {
                return nil
            }
            return (chain, trace)
        }
            .sorted {
                $0.chain.cycleMembership!.occurrenceDate
                    < $1.chain.cycleMembership!.occurrenceDate
            }
        guard members.count >= 2,
              let skippedDate =
              members[0].chain.cycleMembership?.occurrenceDate,
              let movedDate =
              members[1].chain.cycleMembership?.occurrenceDate
        else {
            throw NoonmarkDemoFixtureError.incompleteCoverage([
                "年度重复计划例外操作"
            ])
        }
        try engine.skipTaskCycleOccurrence(
            seriesID: seriesID,
            occurrenceDate: skippedDate,
            today: today,
            now: now
        )
        try engine.rescheduleFuturePlan(
            traceID: members[1].trace.id,
            targetDate: try DemoCalendar.offset(movedDate, by: 1),
            today: today,
            now: now.addingTimeInterval(0.001)
        )
    }

    private mutating func replayMonthlyFeatureCycle(
        number: Int,
        startingAt startIndex: Int
    ) throws {
        guard dates.indices.contains(startIndex + 3) else {
            throw NoonmarkDemoFixtureError.invalidDateRange
        }
        let day0 = dates[startIndex]
        let day1 = dates[startIndex + 1]
        let day2 = dates[startIndex + 2]
        let day3 = dates[startIndex + 3]

        try engine.settleDays(
            upTo: day0,
            now: event(on: day0, hour: 0, minute: 1)
        )

        let poolDraft = try createTask(
            text.annual.monthlyOrganizeInputsTitle(number),
            number: number
        )
        let completedTask = try createTask(
            text.annual.monthlyCompletePrioritiesTitle(number),
            number: number
        )
        let unfinishedTask = try createTask(
            text.annual.monthlyCarryOverTitle(number),
            number: number
        )
        let changedTask = try createTask(
            text.annual.monthlyNarrowScopeTitle(number),
            number: number
        )
        let deferredTask = try createTask(
            text.annual.monthlyDeferDependenciesTitle(number),
            number: number
        )
        let returnedTask = try createTask(
            text.annual.monthlyReworkScheduleTitle(number),
            number: number
        )
        let abandonedTask = try createTask(
            text.annual.monthlyStopStaleTitle(number),
            number: number
        )
        let reactivatedTask = try createTask(
            text.annual.monthlyResumePlanTitle(number),
            number: number
        )
        let subtaskTask = try createTask(
            text.annual.monthlyBreakDownStepsTitle(number),
            number: number
        )
        let futureTask = try createTask(
            text.annual.monthlyAdjustFuturePlansTitle(number),
            number: number
        )

        try exercisePoolEditing(
            chainID: poolDraft,
            number: number,
            date: day0
        )
        try classify(
            poolDraft,
            number: number,
            date: day0
        )

        let completedTrace = try schedule(
            completedTask,
            date: day0,
            today: day0
        )
        try engine.saveTaskTitleInput(
            chainID: completedTask,
            title: text.annual.monthlyDeliverPrioritiesTitle(number),
            today: day0,
            now: event(on: day0, hour: 8, minute: 1)
        )
        counts.taskTitleEditing += 1
        try engine.updateTraceText(
            traceID: completedTrace,
            descriptionText: text.annual.monthlySavedDescription(number),
            today: day0,
            now: event(on: day0, hour: 8, minute: 2)
        )
        counts.taskDescriptionEditing += 1
        try exerciseTraceNotes(
            traceID: completedTrace,
            number: number,
            date: day0
        )

        let unfinishedTrace = try schedule(
            unfinishedTask,
            date: day0,
            today: day0
        )
        try engine.setManualProgress(
            traceID: unfinishedTrace,
            percent: 40,
            today: day0,
            now: event(on: day0, hour: 8, minute: 10)
        )
        counts.manualProgressEditing += 1
        try engine.pinDayTrace(
            unfinishedTrace,
            today: day0,
            now: event(on: day0, hour: 8, minute: 11)
        )
        try engine.unpinDayTrace(
            unfinishedTrace,
            today: day0,
            now: event(on: day0, hour: 8, minute: 12)
        )
        counts.pinLifecycle += 1

        let changedTrace = try schedule(
            changedTask,
            date: day0,
            today: day0
        )
        try engine.reorderDayTrace(
            changedTrace,
            before: unfinishedTrace,
            today: day0,
            now: event(on: day0, hour: 8, minute: 13)
        )
        counts.priorityReordering += 1
        let changedReplacement = try engine.changeTrace(
            traceID: changedTrace,
            newTitle: text.annual.monthlyDeliverNarrowedTitle(number),
            newDescriptionText: text.annual.monthlyDeliverNarrowedDescription,
            today: day0,
            now: event(on: day0, hour: 9)
        )
        counts.taskChange += 1
        try complete(
            changedReplacement,
            today: day0,
            date: day0,
            hour: 16
        )

        let deferredTrace = try schedule(
            deferredTask,
            date: day0,
            today: day0
        )
        let deferredTarget = try engine.deferCurrentTrace(
            traceID: deferredTrace,
            targetDate: day1,
            today: day0,
            now: event(on: day0, hour: 17)
        )
        counts.deferral += 1

        let returnedTrace = try schedule(
            returnedTask,
            date: day0,
            today: day0
        )
        try engine.returnToPool(
            traceID: returnedTrace,
            today: day0,
            now: event(on: day0, hour: 17, minute: 4)
        )
        counts.returnToPool += 1

        let abandonedTrace = try schedule(
            abandonedTask,
            date: day0,
            today: day0
        )
        try engine.abandonChain(
            from: abandonedTrace,
            now: event(on: day0, hour: 17, minute: 5)
        )
        counts.abandonment += 1

        let reactivatedTrace = try schedule(
            reactivatedTask,
            date: day0,
            today: day0
        )
        try engine.abandonChain(
            from: reactivatedTrace,
            now: event(on: day0, hour: 17, minute: 6)
        )
        counts.abandonment += 1
        _ = try engine.reactivateAbandonedChain(
            from: reactivatedTrace,
            today: day0,
            now: event(on: day0, hour: 17, minute: 7)
        )
        counts.reactivation += 1
        try complete(
            reactivatedTrace,
            today: day0,
            date: day0,
            hour: 17,
            minute: 8
        )

        let subtaskTrace = try schedule(
            subtaskTask,
            date: day0,
            today: day0
        )
        try exerciseSubtasks(
            traceID: subtaskTrace,
            number: number,
            date: day0
        )

        let futureTrace = try schedule(
            futureTask,
            date: day2,
            today: day0
        )
        try engine.rescheduleFuturePlan(
            traceID: futureTrace,
            targetDate: day3,
            today: day0,
            now: event(on: day0, hour: 17, minute: 20)
        )
        counts.futureRescheduling += 1

        try complete(
            completedTrace,
            today: day0,
            date: day0,
            hour: 18
        )
        try engine.undoCompleted(
            traceID: completedTrace,
            today: day0,
            now: event(on: day0, hour: 18, minute: 1)
        )
        counts.taskCompletionUndo += 1
        try complete(
            completedTrace,
            today: day0,
            date: day0,
            hour: 18,
            minute: 2
        )
        let copiedChainID = try engine.copyAsNewTask(
            from: completedTrace,
            target: .date(day1),
            today: day0,
            now: event(on: day0, hour: 18, minute: 3)
        )
        counts.copying += 1

        try addDailyBaselineAndReview(
            at: startIndex,
            date: day0
        )
        try engine.settleDays(
            upTo: day1,
            now: event(on: day1, hour: 0, minute: 1)
        )
        let continuedTrace = try engine.continueUnfinishedTrace(
            traceID: unfinishedTrace,
            targetDate: day1,
            today: day1,
            now: event(on: day1, hour: 8)
        )
        counts.unfinishedContinuation += 1
        try complete(
            continuedTrace,
            today: day1,
            date: day1,
            hour: 16
        )

        let continuedSubtaskTrace = try engine.continueUnfinishedTrace(
            traceID: subtaskTrace,
            targetDate: day1,
            today: day1,
            now: event(on: day1, hour: 8, minute: 1)
        )
        counts.unfinishedContinuation += 1
        for subtask in engine.subtasks.values
            .filter({
                $0.traceID == continuedSubtaskTrace
                    && $0.status == .pending
            })
        {
            try engine.completeSubtask(
                subtask.id,
                today: day1,
                now: event(on: day1, hour: 15)
            )
            counts.subtaskCompletion += 1
        }
        try complete(
            continuedSubtaskTrace,
            today: day1,
            date: day1,
            hour: 16,
            minute: 1
        )
        try complete(
            deferredTarget,
            today: day1,
            date: day1,
            hour: 16,
            minute: 2
        )
        guard let copiedTrace = engine.traces.values.first(where: {
            $0.chainID == copiedChainID && $0.date == day1
        }) else {
            throw NoonmarkDemoFixtureError.incompleteCoverage([
                "年度复制任务日轨迹"
            ])
        }
        try complete(
            copiedTrace.id,
            today: day1,
            date: day1,
            hour: 16,
            minute: 3
        )

        try addDailyBaselineAndReview(
            at: startIndex + 1,
            date: day1
        )
        try replayDailyBaseline(at: startIndex + 2)
        try engine.settleDays(
            upTo: day3,
            now: event(on: day3, hour: 0, minute: 1)
        )
        try complete(
            futureTrace,
            today: day3,
            date: day3,
            hour: 16
        )
        try addDailyBaselineAndReview(
            at: startIndex + 3,
            date: day3
        )
    }

    private mutating func createTask(
        _ title: String,
        number: Int
    ) throws -> TaskChainID {
        let chainID = try engine.createPoolTask(
            title: title,
            descriptionText: text.annual.monthlyTaskDescription(number),
            initialNoteBody: text.annual.monthlyInitialNote(number),
            now: event(on: dates[(number - 1) * 29], hour: 6)
        )
        counts.poolTaskCreation += 1
        return chainID
    }

    private mutating func exercisePoolEditing(
        chainID: TaskChainID,
        number: Int,
        date: LocalDate
    ) throws {
        try engine.updatePoolTask(
            chainID: chainID,
            title: text.annual.poolEditFullTitle(number),
            descriptionText: text.annual.poolEditDescription,
            now: event(on: date, hour: 6, minute: 10)
        )
        counts.poolTaskTextEditing += 1

        let noteID = try engine.appendPoolNote(
            chainID: chainID,
            body: text.annual.poolNoteDraft,
            now: event(on: date, hour: 6, minute: 11)
        )
        try engine.editPoolNote(
            chainID: chainID,
            noteID: noteID,
            body: text.annual.poolNoteEdited,
            now: event(on: date, hour: 6, minute: 12)
        )
        try engine.deletePoolNote(
            chainID: chainID,
            noteID: noteID,
            now: event(on: date, hour: 6, minute: 13)
        )
        counts.noteLifecycle += 1

        let retained = try engine.addPlannedSubtask(
            chainID: chainID,
            title: text.annual.poolPlannedOrganizeTitle,
            now: event(on: date, hour: 6, minute: 14)
        )
        let removable = try engine.addPlannedSubtask(
            chainID: chainID,
            title: text.annual.poolPlannedRemoveDuplicatesTitle,
            now: event(on: date, hour: 6, minute: 15)
        )
        try engine.updatePlannedSubtaskTitle(
            chainID: chainID,
            plannedSubtaskID: retained,
            title: text.annual.poolPlannedOrganizeReviewedTitle,
            now: event(on: date, hour: 6, minute: 16)
        )
        try engine.updatePlannedSubtaskDifficulty(
            chainID: chainID,
            plannedSubtaskID: retained,
            difficulty: .hard,
            now: event(on: date, hour: 6, minute: 17)
        )
        try engine.removePlannedSubtask(
            chainID: chainID,
            plannedSubtaskID: removable,
            now: event(on: date, hour: 6, minute: 18)
        )
        counts.plannedSubtaskEditing += 1
    }

    private mutating func exerciseTraceNotes(
        traceID: DayTraceID,
        number: Int,
        date: LocalDate
    ) throws {
        let noteID = try engine.appendTraceNote(
            traceID: traceID,
            body: text.annual.traceNoteDraft(number),
            today: date,
            now: event(on: date, hour: 8, minute: 3)
        )
        try engine.editTraceNote(
            traceID: traceID,
            noteID: noteID,
            body: text.annual.traceNoteEdited(number),
            today: date,
            now: event(on: date, hour: 8, minute: 4)
        )
        try engine.deleteTraceNote(
            traceID: traceID,
            noteID: noteID,
            today: date,
            now: event(on: date, hour: 8, minute: 5)
        )
        counts.noteLifecycle += 1
    }

    private mutating func exerciseSubtasks(
        traceID: DayTraceID,
        number: Int,
        date: LocalDate
    ) throws {
        let completed = try engine.addSubtask(
            traceID: traceID,
            title: text.annual.subtaskCompletionTitle(number),
            now: event(on: date, hour: 10)
        )
        let abandoned = try engine.addSubtask(
            traceID: traceID,
            title: text.annual.subtaskAdjustmentTitle(number),
            now: event(on: date, hour: 10, minute: 1)
        )
        let deleted = try engine.addSubtask(
            traceID: traceID,
            title: text.annual.subtaskDeletionTitle(number),
            now: event(on: date, hour: 10, minute: 2)
        )
        _ = try engine.addSubtask(
            traceID: traceID,
            title: text.annual.subtaskCrossDayTitle(number),
            now: event(on: date, hour: 10, minute: 3)
        )
        counts.subtaskCreation += 4

        try engine.updateSubtaskTitle(
            abandoned,
            title: text.annual.subtaskAdjustedTitle(number),
            today: date,
            now: event(on: date, hour: 10, minute: 4)
        )
        counts.subtaskTextEditing += 1
        try engine.updateSubtaskDifficulty(
            abandoned,
            difficulty: .hard,
            today: date,
            now: event(on: date, hour: 10, minute: 5)
        )
        counts.subtaskDifficultyEditing += 1

        try engine.completeSubtask(
            completed,
            today: date,
            now: event(on: date, hour: 11)
        )
        counts.subtaskCompletion += 1
        try engine.undoCompletedSubtask(
            completed,
            today: date,
            now: event(on: date, hour: 11, minute: 1)
        )
        counts.subtaskCompletionUndo += 1
        try engine.completeSubtask(
            completed,
            today: date,
            now: event(on: date, hour: 11, minute: 2)
        )
        counts.subtaskCompletion += 1
        try engine.abandonSubtask(
            abandoned,
            today: date,
            now: event(on: date, hour: 11, minute: 3)
        )
        counts.subtaskAbandonment += 1
        try engine.deleteSubtask(
            deleted,
            today: date,
            now: event(on: date, hour: 11, minute: 4)
        )
        counts.subtaskDeletion += 1
    }

    private mutating func schedule(
        _ chainID: TaskChainID,
        date: LocalDate,
        today: LocalDate
    ) throws -> DayTraceID {
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: date,
            today: today,
            now: event(on: today, hour: 8)
        )
        counts.scheduling += 1
        return traceID
    }

    private mutating func complete(
        _ traceID: DayTraceID,
        today: LocalDate,
        date: LocalDate,
        hour: Int,
        minute: Int = 0
    ) throws {
        try engine.markCompleted(
            traceID: traceID,
            today: today,
            now: event(on: date, hour: hour, minute: minute)
        )
        counts.taskCompletion += 1
    }

    private mutating func classify(
        _ chainID: TaskChainID,
        number: Int,
        date: LocalDate
    ) throws {
        let categories = [
            (text.categories.research, "#7C5CFF"),
            (text.categories.product, "#2A6FDB"),
            (text.categories.engineering, "#0E9488"),
            (text.categories.collaboration, "#E0851B")
        ]
        let labels = [
            (text.labels.insight, "#0E9488"),
            (text.labels.release, "#E0851B"),
            (text.labels.experience, "#7C5CFF"),
            (text.labels.handoff, "#2A6FDB")
        ]
        let category = categories[(number - 1) % categories.count]
        let label = labels[(number - 1) % labels.count]
        let now = event(on: date, hour: 6, minute: 30)
        let interactionID = UUID()
        let plan = try engine.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .new(
                        name: category.0,
                        colorHex: category.1
                    ),
                    labels: [
                        .new(name: label.0, colorHex: label.1)
                    ]
                )
            ),
            source: .userDirect,
            interactionID: interactionID,
            now: now
        )
        _ = try engine.commitClassification(
            plan,
            confirmation: .confirmedByUser(
                confirming: plan,
                decisionID: interactionID
            ),
            now: now
        )
        counts.classification += 1
    }

    private mutating func replayDailyBaseline(
        at index: Int
    ) throws {
        let date = dates[index]
        try engine.settleDays(
            upTo: date,
            now: event(on: date, hour: 0, minute: 1)
        )
        try addDailyBaselineAndReview(at: index, date: date)
    }

    private mutating func addDailyBaselineAndReview(
        at index: Int,
        date: LocalDate
    ) throws {
        let chainID = try engine.createPoolTask(
            title: text.annual.dailyTaskTitle(index + 1),
            descriptionText: text.annual.dailyTaskDescription(index + 1),
            initialNoteBody: text.annual.dailyInitialNote,
            now: event(on: date, hour: 7)
        )
        counts.poolTaskCreation += 1
        if index.isMultiple(of: 3) {
            try classify(
                chainID,
                number: (index % 12) + 1,
                date: date
            )
        }
        let traceID = try schedule(
            chainID,
            date: date,
            today: date
        )
        try complete(
            traceID,
            today: date,
            date: date,
            hour: 18
        )
        engine.updateDailyReview(
            date: date,
            summary: text.annual.dailyReviewSummary(index + 1),
            unfinishedReason: index.isMultiple(of: 3)
                ? text.annual.dailyUnfinishedDependencyReason
                : text.annual.dailyUnfinishedPriorityReason,
            tomorrowNote: text.annual.dailyTomorrowNote,
            now: event(on: date, hour: 22)
        )
    }

    private mutating func exerciseAnchorDayDeferralWithdrawals()
        throws
    {
        let tomorrow = try DemoCalendar.offset(anchorDate, by: 1)
        for number in 1 ... 12 {
            let chainID = try engine.createPoolTask(
                title: text.annual.deferralWithdrawalTitle(number),
                descriptionText: text.annual.deferralWithdrawalDescription,
                initialNoteBody: text.annual.deferralWithdrawalNote,
                now: event(on: anchorDate, hour: 6, minute: number)
            )
            counts.poolTaskCreation += 1
            let traceID = try schedule(
                chainID,
                date: anchorDate,
                today: anchorDate
            )
            _ = try engine.addSubtask(
                traceID: traceID,
                title: text.annual.deferralWithdrawalSubtaskTitle(number),
                now: event(
                    on: anchorDate,
                    hour: 6,
                    minute: 12 + number
                )
            )
            counts.subtaskCreation += 1
            _ = try engine.deferCurrentTrace(
                traceID: traceID,
                targetDate: tomorrow,
                today: anchorDate,
                now: event(
                    on: anchorDate,
                    hour: 6,
                    minute: 15 + number
                )
            )
            counts.deferral += 1
            try engine.withdrawDeferral(
                sourceTraceID: traceID,
                today: anchorDate,
                now: event(
                    on: anchorDate,
                    hour: 6,
                    minute: 30 + number
                )
            )
            counts.deferralWithdrawal += 1
        }
    }

    private mutating func event(
        on date: LocalDate,
        hour: Int,
        minute: Int = 0
    ) -> Date {
        clock.next(
            from: DemoCalendar.timestamp(
                date,
                hour: hour,
                minute: minute
            )
        )
    }
}

private struct DemoStory {
    let engine: NoonmarkEngine
    let dates: [LocalDate]
    let text: DemoStoryText
    private let clock: DemoClock

    init(engine: NoonmarkEngine, dates: [LocalDate], text: DemoStoryText) {
        self.engine = engine
        self.dates = dates
        self.text = text
        clock = DemoClock()
    }

    mutating func replay() throws -> DemoStoryIdeaFacts {
        let taskIDs = try createTaskPool()
        let cycleSeriesIDs = try createCycleSeries()
        try replayFirstFiveDays(
            taskIDs,
            cycleSeriesID: cycleSeriesIDs.active
        )
        try replayLastFiveDays(
            taskIDs,
            cycleSeriesID: cycleSeriesIDs.active
        )
        try addTodayAndFutureState(taskIDs)
        let ideaFacts = try addIdeaCapture()
        _ = try engine.stopTaskCycleSeries(
            seriesID: cycleSeriesIDs.stoppable,
            today: dates[9],
            now: time(on: dates[9], hour: 14, minute: 45)
        )
        _ = try engine.reviseTaskCycleSeries(
            seriesID: cycleSeriesIDs.active,
            schedule: .daily,
            endCondition: .onDate(
                try DemoCalendar.offset(dates[9], by: 3)
            ),
            today: dates[9],
            now: time(on: dates[9], hour: 14, minute: 50)
        )
        try addReviews()
        try engine.snapshot().validateIntegrity()
        return ideaFacts
    }

    private func createCycleSeries() throws -> DemoCycleSeriesIDs {
        let plannedSubtask = PlannedSubtask(
            title: text.story.cyclePlannedSubtaskTitle,
            position: 1,
            now: time(on: dates[0], hour: 6, minute: 44)
        )
        let seriesID = try engine.createTaskCycleSeries(
            title: text.story.dailyReviewSeriesTitle,
            descriptionText: text.story.dailyReviewSeriesDescription,
            plannedSubtasks: [plannedSubtask],
            startDate: dates[0],
            endDate: try DemoCalendar.offset(dates[9], by: 3),
            schedule: .daily,
            today: dates[0],
            now: time(on: dates[0], hour: 6, minute: 45)
        )
        let movedOccurrenceDate = try DemoCalendar.offset(
            dates[9],
            by: 3
        )
        guard let movedChain = engine.chains.values.first(where: {
            $0.cycleMembership?.seriesID == seriesID
                && $0.cycleMembership?.occurrenceDate
                == movedOccurrenceDate
        }), let movedTrace = engine.traces.values.first(where: {
            $0.chainID == movedChain.id
        }) else {
            throw NoonmarkDemoFixtureError.incompleteCoverage([
                "周期系列重新排期实例"
            ])
        }
        try engine.rescheduleFuturePlan(
            traceID: movedTrace.id,
            targetDate: try DemoCalendar.offset(dates[9], by: 4),
            today: dates[0],
            now: time(on: dates[0], hour: 6, minute: 46)
        )
        try engine.skipTaskCycleOccurrence(
            seriesID: seriesID,
            occurrenceDate: try DemoCalendar.offset(dates[9], by: 2),
            today: dates[0],
            now: time(on: dates[0], hour: 6, minute: 48)
        )
        let memberChainIDs = engine.chains.values
            .filter {
                $0.cycleMembership?.seriesID == seriesID
            }
            .sorted {
                $0.cycleMembership!.occurrenceDate
                    < $1.cycleMembership!.occurrenceDate
            }
            .map(\.id)
        guard let anchorChainID = memberChainIDs.first else {
            throw NoonmarkDemoFixtureError.incompleteCoverage([
                "重复任务父项"
            ])
        }
        let classificationTime = time(
            on: dates[0],
            hour: 6,
            minute: 49
        )
        try classify(
            anchorChainID,
            category: (text.categories.review, "#E0851B"),
            labels: [(text.labels.release, "#E0851B")],
            at: classificationTime
        )
        guard let classification = engine.snapshot().classifications
            .currentByChainID[anchorChainID]
        else {
            throw NoonmarkDemoFixtureError.incompleteCoverage([
                "重复任务父项分类"
            ])
        }
        try engine.setTaskCycleTemplateClassification(
            seriesID: seriesID,
            categoryID: classification.categoryID,
            labelIDs: classification.labelIDs,
            now: classificationTime
        )
        for chainID in memberChainIDs.dropFirst() {
            _ = try engine.inheritCurrentClassification(
                from: anchorChainID,
                to: chainID,
                now: classificationTime
            )
        }
        try createUnstartedCycleSeries(
            categoryID: classification.categoryID,
            labelIDs: classification.labelIDs
        )
        _ = try createEndedCycleSeries()
        let stoppableSeriesID = try createStoppableCycleSeries()
        return DemoCycleSeriesIDs(
            active: seriesID,
            stoppable: stoppableSeriesID
        )
    }

    private func createEndedCycleSeries() throws -> TaskCycleSeriesID {
        let createdAt = time(
            on: dates[0],
            hour: 6,
            minute: 51
        )
        let seriesID = try engine.createTaskCycleSeries(
            title: text.story.morningReviewSeriesTitle,
            descriptionText: text.story.morningReviewSeriesDescription,
            startDate: dates[0],
            endDate: dates[0],
            schedule: .daily,
            today: dates[0],
            now: createdAt
        )
        guard let chain = engine.chains.values.first(where: {
            $0.cycleMembership?.seriesID == seriesID
        }), let trace = engine.traces.values.first(where: {
            $0.chainID == chain.id && $0.date == dates[0]
        }) else {
            throw NoonmarkDemoFixtureError.incompleteCoverage([
                "已结束重复计划实例"
            ])
        }
        try engine.markCompleted(
            traceID: trace.id,
            today: dates[0],
            now: time(on: dates[0], hour: 6, minute: 52)
        )
        return seriesID
    }

    private func createStoppableCycleSeries() throws -> TaskCycleSeriesID {
        try engine.createTaskCycleSeries(
            title: text.story.pausedWeeklySeriesTitle,
            descriptionText: text.story.pausedWeeklySeriesDescription,
            startDate: dates[0],
            endDate: try DemoCalendar.offset(dates[9], by: 3),
            schedule: .daily,
            today: dates[0],
            now: time(on: dates[0], hour: 6, minute: 53)
        )
    }

    private func createUnstartedCycleSeries(
        categoryID: TaskCategoryID?,
        labelIDs: Set<TaskLabelID>
    ) throws {
        let startDate = try DemoCalendar.offset(dates[9], by: 2)
        let createdAt = time(
            on: dates[0],
            hour: 6,
            minute: 50
        )
        let seriesID = try engine.createTaskCycleSeries(
            title: text.story.upcomingReviewSeriesTitle,
            descriptionText: text.story.upcomingReviewSeriesDescription,
            plannedSubtasks: [
                PlannedSubtask(
                    title: text.story.upcomingReviewPlannedSubtaskTitle,
                    position: 1,
                    now: createdAt
                )
            ],
            startDate: startDate,
            schedule: .daily,
            endCondition: .durationDays(30),
            today: dates[0],
            now: createdAt
        )
        try engine.setTaskCycleTemplateClassification(
            seriesID: seriesID,
            categoryID: categoryID,
            labelIDs: labelIDs,
            now: createdAt
        )
        let memberChainIDs = engine.chains.values
            .filter {
                $0.cycleMembership?.seriesID == seriesID
            }
            .sorted {
                $0.cycleMembership!.occurrenceDate
                    < $1.cycleMembership!.occurrenceDate
            }
            .map(\.id)
        guard let anchorChainID = memberChainIDs.first else {
            throw NoonmarkDemoFixtureError.incompleteCoverage([
                "尚未开始的重复任务"
            ])
        }
        if categoryID != nil || labelIDs.isEmpty == false {
            let interactionID = UUID()
            let plan = try engine.prepareClassification(
                .setCurrent(
                    TaskClassificationDraft(
                        chainID: anchorChainID,
                        category: categoryID.map(
                            TaskCategoryChoice.existing
                        ),
                        labels: labelIDs
                            .sorted {
                                $0.description < $1.description
                            }
                            .map(TaskLabelChoice.existing)
                    )
                ),
                source: .userDirect,
                interactionID: interactionID,
                now: createdAt
            )
            _ = try engine.commitClassification(
                plan,
                confirmation: .confirmedByUser(
                    confirming: plan,
                    decisionID: interactionID
                ),
                now: createdAt
            )
            for chainID in memberChainIDs.dropFirst() {
                _ = try engine.inheritCurrentClassification(
                    from: anchorChainID,
                    to: chainID,
                    now: createdAt
                )
            }
        }
    }

    private mutating func createTaskPool() throws -> DemoTaskIDs {
        let createdAt = time(on: dates[0], hour: 6)
        func create(
            _ copy: DemoStoryTaskCopy
        ) throws -> TaskChainID {
            try engine.createPoolTask(
                title: copy.title,
                descriptionText: copy.taskDescription,
                initialNoteBody: copy.note,
                now: clock.next(from: createdAt)
            )
        }

        let taskIDs = try DemoTaskIDs(
            researchBrief: create(text.story.researchBrief),
            interviewFollowUp: create(text.story.interviewFollowUp),
            onboardingDraft: create(text.story.onboardingDraft),
            expense: create(text.story.expense),
            deprecatedExperiment: create(text.story.deprecatedExperiment),
            restoredPlan: create(text.story.restoredPlan),
            deferredDelivery: create(text.story.deferredDelivery),
            subtaskStudy: create(text.story.subtaskStudy),
            unfinishedHandoff: create(text.story.unfinishedHandoff),
            pinnedFocus: create(text.story.pinnedFocus),
            pinnedReview: create(text.story.pinnedReview),
            todayDeferral: create(text.story.todayDeferral),
            todayCompleted: create(text.story.todayCompleted),
            todayActive: create(text.story.todayActive),
            plannedPool: create(text.story.plannedPool),
            emptyTitlePool: create(text.story.emptyTitlePool),
            futureWorkshop: create(text.story.futureWorkshop),
            rescheduledFuture: create(text.story.rescheduledFuture),
            futureReturned: create(text.story.futureReturned)
        )

        try classify(
            taskIDs.researchBrief,
            category: (text.categories.research, "#7C5CFF"),
            labels: [
                (text.labels.interview, "#2A6FDB"),
                (text.labels.insight, "#0E9488")
            ]
        )
        try classify(
            taskIDs.interviewFollowUp,
            category: (text.categories.research, "#7C5CFF"),
            labels: [(text.labels.interview, "#2A6FDB")]
        )
        try classify(
            taskIDs.onboardingDraft,
            category: (text.categories.product, "#2A6FDB"),
            labels: [(text.labels.copy, "#D1477A")]
        )
        try classify(
            taskIDs.deferredDelivery,
            category: (text.categories.design, "#D1477A"),
            labels: [(text.labels.delivery, "#E0851B")]
        )
        try classify(
            taskIDs.subtaskStudy,
            category: (text.categories.research, "#7C5CFF"),
            labels: [(text.labels.walkthrough, "#0E9488")]
        )
        try classify(
            taskIDs.pinnedFocus,
            category: (text.categories.engineering, "#0E9488"),
            labels: [(text.labels.blocker, "#D1477A")]
        )
        try classify(
            taskIDs.pinnedReview,
            category: (text.categories.product, "#2A6FDB"),
            labels: [(text.labels.release, "#E0851B")]
        )
        try classify(
            taskIDs.todayActive,
            category: (text.categories.engineering, "#0E9488"),
            labels: [(text.labels.experience, "#7C5CFF")]
        )
        try classify(
            taskIDs.todayCompleted,
            category: (text.categories.engineering, "#0E9488"),
            labels: [(text.labels.sync, "#2A6FDB")]
        )
        try classify(
            taskIDs.unfinishedHandoff,
            category: (text.categories.collaboration, "#E0851B"),
            labels: [(text.labels.handoff, "#2A6FDB")]
        )
        try classify(
            taskIDs.plannedPool,
            category: (text.categories.review, "#E0851B"),
            labels: [(text.labels.release, "#E0851B")]
        )
        try classify(
            taskIDs.futureWorkshop,
            category: (text.categories.product, "#2A6FDB"),
            labels: [(text.labels.roadmap, "#7C5CFF")]
        )

        try engine.addPlannedSubtask(
            chainID: taskIDs.plannedPool,
            title: text.story.plannedPoolSubtaskSummarize,
            difficulty: .simple,
            now: clock.next(from: createdAt)
        )
        try engine.addPlannedSubtask(
            chainID: taskIDs.plannedPool,
            title: text.story.plannedPoolSubtaskGroupReasons,
            difficulty: .medium,
            now: clock.next(from: createdAt)
        )
        try engine.addPlannedSubtask(
            chainID: taskIDs.plannedPool,
            title: text.story.plannedPoolSubtaskImprovementPlan,
            difficulty: .hard,
            now: clock.next(from: createdAt)
        )
        try engine.updatePoolTask(
            chainID: taskIDs.emptyTitlePool,
            title: "",
            descriptionText: text.story.emptyTitlePool.taskDescription,
            now: clock.next(from: createdAt)
        )
        return taskIDs
    }

    private mutating func replayFirstFiveDays(
        _ ids: DemoTaskIDs,
        cycleSeriesID: TaskCycleSeriesID
    ) throws {
        let research = try schedule(
            ids.researchBrief,
            on: dates[0],
            hour: 8
        )
        try engine.markCompleted(
            traceID: research,
            today: dates[0],
            now: time(on: dates[0], hour: 16)
        )
        _ = try schedule(
            ids.interviewFollowUp,
            on: dates[0],
            hour: 9
        )
        try completeCycleOccurrence(
            seriesID: cycleSeriesID,
            on: dates[0],
            hour: 18
        )

        try settle(atStartOf: dates[1])
        guard let interview = engine.snapshot().traces.first(where: {
            $0.chainID == ids.interviewFollowUp
                && $0.status == .unfinished
        }) else {
            throw NoonmarkDemoFixtureError.incompleteCoverage(
                ["访谈任务未进入未完成"]
            )
        }
        let continuedInterview = try engine.continueUnfinishedTrace(
            traceID: interview.id,
            targetDate: dates[1],
            today: dates[1],
            now: time(on: dates[1], hour: 8)
        )
        try engine.markCompleted(
            traceID: continuedInterview,
            today: dates[1],
            now: time(on: dates[1], hour: 15)
        )

        try settle(atStartOf: dates[2])
        let onboarding = try schedule(
            ids.onboardingDraft,
            on: dates[2],
            hour: 8
        )
        let rewritten = try engine.changeTrace(
            traceID: onboarding,
            newTitle: text.story.onboardingRewrittenTitle,
            newDescriptionText: text.story.onboardingRewrittenDescription,
            today: dates[2],
            now: time(on: dates[2], hour: 10)
        )
        try engine.markCompleted(
            traceID: rewritten,
            today: dates[2],
            now: time(on: dates[2], hour: 17)
        )
        try completeCycleOccurrence(
            seriesID: cycleSeriesID,
            on: dates[2],
            hour: 18
        )

        try settle(atStartOf: dates[3])
        let expense = try schedule(
            ids.expense,
            on: dates[3],
            hour: 9
        )
        try engine.returnToPool(
            traceID: expense,
            today: dates[3],
            now: time(on: dates[3], hour: 11)
        )

        try settle(atStartOf: dates[4])
        let deprecated = try schedule(
            ids.deprecatedExperiment,
            on: dates[4],
            hour: 8
        )
        try engine.abandonChain(
            from: deprecated,
            now: time(on: dates[4], hour: 9)
        )
        let restored = try schedule(
            ids.restoredPlan,
            on: dates[4],
            hour: 10
        )
        try engine.abandonChain(
            from: restored,
            now: time(on: dates[4], hour: 11)
        )
        _ = try engine.reactivateAbandonedChain(
            from: restored,
            today: dates[4],
            now: time(on: dates[4], hour: 12)
        )
        try engine.markCompleted(
            traceID: restored,
            today: dates[4],
            now: time(on: dates[4], hour: 16)
        )
        try completeCycleOccurrence(
            seriesID: cycleSeriesID,
            on: dates[4],
            hour: 18
        )
    }

    private mutating func replayLastFiveDays(
        _ ids: DemoTaskIDs,
        cycleSeriesID: TaskCycleSeriesID
    ) throws {
        try settle(atStartOf: dates[5])
        let delivery = try schedule(
            ids.deferredDelivery,
            on: dates[5],
            hour: 8
        )
        let deferredDelivery = try engine.deferCurrentTrace(
            traceID: delivery,
            targetDate: dates[6],
            today: dates[5],
            now: time(on: dates[5], hour: 17)
        )

        try settle(atStartOf: dates[6])
        try engine.markCompleted(
            traceID: deferredDelivery,
            today: dates[6],
            now: time(on: dates[6], hour: 16)
        )
        let study = try schedule(
            ids.subtaskStudy,
            on: dates[6],
            hour: 8
        )
        let reproduce = try engine.addSubtask(
            traceID: study,
            title: text.story.studySubtaskReproduce,
            difficulty: .simple,
            now: time(on: dates[6], hour: 9)
        )
        _ = try engine.addSubtask(
            traceID: study,
            title: text.story.studySubtaskRecordIssues,
            difficulty: .medium,
            now: time(on: dates[6], hour: 9, minute: 1)
        )
        let obsolete = try engine.addSubtask(
            traceID: study,
            title: text.story.studySubtaskRemovedEntry,
            difficulty: .hard,
            now: time(on: dates[6], hour: 9, minute: 2)
        )
        try engine.completeSubtask(
            reproduce,
            today: dates[6],
            now: time(on: dates[6], hour: 12)
        )
        try engine.abandonSubtask(
            obsolete,
            today: dates[6],
            now: time(on: dates[6], hour: 13)
        )
        try completeCycleOccurrence(
            seriesID: cycleSeriesID,
            on: dates[6],
            hour: 18
        )

        try settle(atStartOf: dates[7])
        let handoff = try schedule(
            ids.unfinishedHandoff,
            on: dates[7],
            hour: 9
        )
        try engine.setManualProgress(
            traceID: handoff,
            percent: 45,
            today: dates[7],
            now: time(on: dates[7], hour: 14)
        )

        try settle(atStartOf: dates[8])
        let copySource = try engine.copyAsNewTask(
            from: handoff,
            target: .date(dates[8]),
            today: dates[8],
            now: time(on: dates[8], hour: 9)
        )
        guard let copiedTrace = engine.snapshot().traces.first(where: {
            $0.chainID == copySource && $0.date == dates[8]
        }) else {
            throw NoonmarkDemoFixtureError.incompleteCoverage(
                ["复制任务未生成日轨迹"]
            )
        }
        try engine.markCompleted(
            traceID: copiedTrace.id,
            today: dates[8],
            now: time(on: dates[8], hour: 15)
        )
        try completeCycleOccurrence(
            seriesID: cycleSeriesID,
            on: dates[8],
            hour: 18
        )

        try settle(atStartOf: dates[9])
    }

    private mutating func addTodayAndFutureState(
        _ ids: DemoTaskIDs
    ) throws {
        let firstPinned = try schedule(
            ids.pinnedFocus,
            on: dates[9],
            hour: 8
        )
        let secondPinned = try schedule(
            ids.pinnedReview,
            on: dates[9],
            hour: 8,
            minute: 1
        )
        try engine.pinDayTrace(
            firstPinned,
            today: dates[9],
            now: time(on: dates[9], hour: 8, minute: 2)
        )
        try engine.pinDayTrace(
            secondPinned,
            today: dates[9],
            now: time(on: dates[9], hour: 8, minute: 3)
        )

        let deferralSource = try schedule(
            ids.todayDeferral,
            on: dates[9],
            hour: 9
        )
        _ = try engine.deferCurrentTrace(
            traceID: deferralSource,
            targetDate: try DemoCalendar.offset(dates[9], by: 1),
            today: dates[9],
            now: time(on: dates[9], hour: 9, minute: 30)
        )

        let completed = try schedule(
            ids.todayCompleted,
            on: dates[9],
            hour: 7
        )
        let completedChildren = try [
            engine.addSubtask(
                traceID: completed,
                title: text.story.syncSubtaskGoals,
                now: time(on: dates[9], hour: 7, minute: 1)
            ),
            engine.addSubtask(
                traceID: completed,
                title: text.story.syncSubtaskRisks,
                now: time(on: dates[9], hour: 7, minute: 2)
            ),
            engine.addSubtask(
                traceID: completed,
                title: text.story.syncSubtaskNextSteps,
                now: time(on: dates[9], hour: 7, minute: 3)
            )
        ]
        for (index, childID) in completedChildren.enumerated() {
            try engine.completeSubtask(
                childID,
                today: dates[9],
                now: time(
                    on: dates[9],
                    hour: 7,
                    minute: 10 + index
                )
            )
        }
        try engine.markCompleted(
            traceID: completed,
            today: dates[9],
            now: time(on: dates[9], hour: 7, minute: 30)
        )

        let active = try schedule(
            ids.todayActive,
            on: dates[9],
            hour: 10
        )
        let cursor = try engine.addSubtask(
            traceID: active,
            title: text.story.activeSubtaskCursor,
            difficulty: .simple,
            now: time(on: dates[9], hour: 10, minute: 1)
        )
        _ = try engine.addSubtask(
            traceID: active,
            title: text.story.activeSubtaskSwipe,
            difficulty: .medium,
            now: time(on: dates[9], hour: 10, minute: 2)
        )
        _ = try engine.addSubtask(
            traceID: active,
            title: text.story.activeSubtaskGroupColors,
            difficulty: .hard,
            now: time(on: dates[9], hour: 10, minute: 3)
        )
        try engine.completeSubtask(
            cursor,
            today: dates[9],
            now: time(on: dates[9], hour: 11)
        )

        _ = try engine.scheduleFromPool(
            chainID: ids.futureWorkshop,
            date: try DemoCalendar.offset(dates[9], by: 2),
            today: dates[9],
            now: time(on: dates[9], hour: 12)
        )
        let rescheduled = try engine.scheduleFromPool(
            chainID: ids.rescheduledFuture,
            date: try DemoCalendar.offset(dates[9], by: 3),
            today: dates[9],
            now: time(on: dates[9], hour: 12, minute: 1)
        )
        try engine.rescheduleFuturePlan(
            traceID: rescheduled,
            targetDate: try DemoCalendar.offset(dates[9], by: 4),
            today: dates[9],
            now: time(on: dates[9], hour: 12, minute: 2)
        )
        let returned = try engine.scheduleFromPool(
            chainID: ids.futureReturned,
            date: try DemoCalendar.offset(dates[9], by: 5),
            today: dates[9],
            now: time(on: dates[9], hour: 12, minute: 3)
        )
        try engine.returnToPool(
            traceID: returned,
            today: dates[9],
            now: time(on: dates[9], hour: 12, minute: 4)
        )
    }

    private func addIdeaCapture() throws -> DemoStoryIdeaFacts {
        let researchClassification = try ideaClassificationIDs(
            categoryName: text.categories.research,
            labelNames: [text.labels.interview, text.labels.insight]
        )
        let releaseIdea = try engine.appendIdea(
            body: text.story.ideaOnboardingConfusion,
            categoryID: researchClassification.categoryID,
            labelIDs: researchClassification.labelIDs,
            now: time(on: dates[0], hour: 21, minute: 5)
        )
        let expenseIdea = try engine.appendIdea(
            body: text.story.ideaExpenseBatching,
            now: time(on: dates[1], hour: 12, minute: 40)
        )
        let hoverIdea = try engine.appendIdea(
            body: text.story.ideaHoverFeedback,
            now: time(on: dates[3], hour: 16, minute: 20)
        )
        try engine.editIdea(
            id: hoverIdea.id,
            body: text.story.ideaHoverFeedbackEdited,
            now: time(on: dates[5], hour: 9, minute: 15)
        )
        let staleExperimentIdea = try engine.appendIdea(
            body: text.story.ideaStaleExperiment,
            now: time(on: dates[5], hour: 22, minute: 10)
        )
        try engine.deleteIdea(
            id: staleExperimentIdea.id,
            now: time(on: dates[6], hour: 8, minute: 30)
        )
        let walkthroughClassification = try ideaClassificationIDs(
            labelNames: [text.labels.walkthrough]
        )
        _ = try engine.appendIdea(
            body: text.story.ideaWalkthroughSurprise,
            labelIDs: walkthroughClassification.labelIDs,
            now: time(on: dates[6], hour: 19, minute: 45)
        )
        let dataCaliberIdea = try engine.appendIdea(
            body: text.story.ideaDataCaliber,
            now: time(on: dates[7], hour: 18, minute: 5)
        )
        let handoffIdea = try engine.appendIdea(
            body: text.story.ideaHandoffTemplate,
            now: time(on: dates[8], hour: 13, minute: 30)
        )
        let handoffClassification = try ideaClassificationIDs(
            categoryName: text.categories.collaboration,
            labelNames: [text.labels.handoff]
        )
        try engine.setIdeaClassification(
            id: handoffIdea.id,
            categoryID: handoffClassification.categoryID,
            labelIDs: handoffClassification.labelIDs,
            now: time(on: dates[8], hour: 14, minute: 5)
        )
        try engine.deleteIdea(
            id: dataCaliberIdea.id,
            now: time(on: dates[9], hour: 8, minute: 45)
        )
        let releaseClassification = try ideaClassificationIDs(
            labelNames: [text.labels.release]
        )
        _ = try engine.appendIdea(
            body: text.story.ideaReleaseWorkarounds,
            labelIDs: releaseClassification.labelIDs,
            now: time(on: dates[9], hour: 9, minute: 20)
        )
        let attentionIdea = try engine.appendIdea(
            body: text.story.ideaStickyAttention,
            now: time(on: dates[9], hour: 15, minute: 10)
        )
        try engine.pinIdea(
            id: expenseIdea.id,
            now: time(on: dates[9], hour: 15, minute: 20)
        )
        try engine.pinIdea(
            id: handoffIdea.id,
            now: time(on: dates[9], hour: 15, minute: 21)
        )
        try engine.pinIdea(
            id: attentionIdea.id,
            now: time(on: dates[9], hour: 15, minute: 22)
        )
        _ = releaseIdea
        try engine.restoreIdea(
            id: dataCaliberIdea.id,
            body: text.story.ideaDataCaliberRestored,
            now: time(on: dates[9], hour: 15, minute: 25)
        )
        return DemoStoryIdeaFacts(restoredIdeaCount: 1)
    }

    private func ideaClassificationIDs(
        categoryName: String? = nil,
        labelNames: [String] = []
    ) throws -> (categoryID: TaskCategoryID?, labelIDs: [TaskLabelID]) {
        let classifications = engine.snapshot().classifications
        var categoryID: TaskCategoryID?
        if let categoryName {
            guard let match = classifications.categories.first(where: {
                $0.value.name == categoryName
            }) else {
                throw NoonmarkDemoFixtureError.incompleteCoverage([
                    "飞光分组 \(categoryName)"
                ])
            }
            categoryID = match.key
        }
        let labelIDs = try labelNames.map { name in
            guard let match = classifications.labels.first(where: {
                $0.value.name == name
            }) else {
                throw NoonmarkDemoFixtureError.incompleteCoverage([
                    "飞光标签 \(name)"
                ])
            }
            return match.key
        }
        return (categoryID, labelIDs)
    }

    private func addReviews() throws {
        for (index, date) in dates.dropLast().enumerated() {
            engine.updateDailyReview(
                date: date,
                summary: text.story.reviewSummary(index + 1),
                unfinishedReason: index.isMultiple(of: 2)
                    ? text.story.reviewUnfinishedMeetingReason
                    : text.story.reviewUnfinishedDependencyReason,
                tomorrowNote: text.story.reviewTomorrowNote,
                now: time(on: dates[9], hour: 14, minute: index)
            )
        }
        engine.updateDailyReview(
            date: dates[9],
            summary: text.story.finalReviewSummary,
            unfinishedReason: "",
            tomorrowNote: text.story.finalReviewTomorrowNote,
            now: time(on: dates[9], hour: 15)
        )
    }

    private func classify(
        _ chainID: TaskChainID,
        category: (name: String, colorHex: String),
        labels: [(name: String, colorHex: String)],
        at explicitNow: Date? = nil
    ) throws {
        let interactionID = UUID()
        let now = explicitNow ?? clock.next(
            from: time(on: dates[0], hour: 6, minute: 30)
        )
        let plan = try engine.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .new(
                        name: category.name,
                        colorHex: category.colorHex
                    ),
                    labels: labels.map {
                        .new(name: $0.name, colorHex: $0.colorHex)
                    }
                )
            ),
            source: .userDirect,
            interactionID: interactionID,
            now: now
        )
        _ = try engine.commitClassification(
            plan,
            confirmation: .confirmedByUser(
                confirming: plan,
                decisionID: interactionID
            ),
            now: now
        )
    }

    private func schedule(
        _ chainID: TaskChainID,
        on date: LocalDate,
        hour: Int,
        minute: Int = 0
    ) throws -> DayTraceID {
        try engine.scheduleFromPool(
            chainID: chainID,
            date: date,
            today: date,
            now: time(on: date, hour: hour, minute: minute)
        )
    }

    private func settle(atStartOf date: LocalDate) throws {
        try engine.settleDays(
            upTo: date,
            now: time(on: date, hour: 0, minute: 1)
        )
    }

    private func completeCycleOccurrence(
        seriesID: TaskCycleSeriesID,
        on date: LocalDate,
        hour: Int
    ) throws {
        guard let chainID = engine.chains.values.first(where: {
            $0.cycleMembership?.seriesID == seriesID
                && $0.cycleMembership?.occurrenceDate == date
        })?.id,
            let trace = engine.traces.values.first(where: {
                $0.chainID == chainID && $0.date == date
            })
        else {
            throw NoonmarkDemoFixtureError.incompleteCoverage(
                ["周期实例 \(date.description) 缺失"]
            )
        }
        let occurrenceSubtasks = engine.subtasks.values
            .filter {
                $0.traceID == trace.id
                    && $0.status == .pending
            }
            .sorted {
                if $0.position != $1.position {
                    return $0.position < $1.position
                }
                return $0.id.description < $1.id.description
            }
        for subtask in occurrenceSubtasks {
            try engine.completeSubtask(
                subtask.id,
                today: date,
                now: time(on: date, hour: hour)
            )
        }
        try engine.markCompleted(
            traceID: trace.id,
            today: date,
            now: time(on: date, hour: hour, minute: 1)
        )
    }

    private func time(
        on date: LocalDate,
        hour: Int,
        minute: Int = 0
    ) -> Date {
        DemoCalendar.timestamp(
            date,
            hour: hour,
            minute: minute
        )
    }
}

private struct DemoStoryIdeaFacts {
    let restoredIdeaCount: Int
}

private struct DemoCycleSeriesIDs {
    let active: TaskCycleSeriesID
    let stoppable: TaskCycleSeriesID
}

private struct DemoTaskIDs {
    let researchBrief: TaskChainID
    let interviewFollowUp: TaskChainID
    let onboardingDraft: TaskChainID
    let expense: TaskChainID
    let deprecatedExperiment: TaskChainID
    let restoredPlan: TaskChainID
    let deferredDelivery: TaskChainID
    let subtaskStudy: TaskChainID
    let unfinishedHandoff: TaskChainID
    let pinnedFocus: TaskChainID
    let pinnedReview: TaskChainID
    let todayDeferral: TaskChainID
    let todayCompleted: TaskChainID
    let todayActive: TaskChainID
    let plannedPool: TaskChainID
    let emptyTitlePool: TaskChainID
    let futureWorkshop: TaskChainID
    let rescheduledFuture: TaskChainID
    let futureReturned: TaskChainID
}

private final class DemoClock {
    private var lastDate: Date = .distantPast

    func next(from lowerBound: Date) -> Date {
        let nextDate = max(
            lowerBound,
            lastDate.addingTimeInterval(0.001)
        )
        lastDate = nextDate
        return nextDate
    }
}

private enum DemoCalendar {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(
            identifier: "America/New_York"
        ) ?? .current
        return calendar
    }

    static func storyDates(
        endingAt anchorDate: LocalDate,
        count: Int
    ) throws -> [LocalDate] {
        guard count > 0 else {
            throw NoonmarkDemoFixtureError.invalidDateRange
        }
        return try (0 ..< count).map {
            try offset(anchorDate, by: $0 - (count - 1))
        }
    }

    static func offset(
        _ date: LocalDate,
        by days: Int
    ) throws -> LocalDate {
        let start = timestamp(date, hour: 12, minute: 0)
        guard let shifted = calendar.date(
            byAdding: .day,
            value: days,
            to: start
        ) else {
            throw NoonmarkDemoFixtureError.invalidDateRange
        }
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: shifted
        )
        guard let year = components.year,
              let month = components.month,
              let day = components.day
        else {
            throw NoonmarkDemoFixtureError.invalidDateRange
        }
        return LocalDate(year: year, month: month, day: day)
    }

    static func localDate(of timestamp: Date) -> LocalDate? {
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: timestamp
        )
        guard let year = components.year,
              let month = components.month,
              let day = components.day
        else {
            return nil
        }
        return LocalDate(year: year, month: month, day: day)
    }

    static func timestamp(
        _ date: LocalDate,
        hour: Int,
        minute: Int
    ) -> Date {
        let components = DateComponents(
            year: date.year,
            month: date.month,
            day: date.day,
            hour: hour,
            minute: minute
        )
        guard let timestamp = calendar.date(from: components) else {
            preconditionFailure("演示日期必须是有效的公历日期")
        }
        return timestamp
    }
}
