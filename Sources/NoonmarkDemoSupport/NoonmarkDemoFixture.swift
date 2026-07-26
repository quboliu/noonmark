import Foundation
@_spi(ClassificationUserDecision) import NoonmarkCore

public struct NoonmarkDemoFixture {
    public let anchorDate: LocalDate
    public let storyDates: [LocalDate]
    public let engine: NoonmarkEngine
    public let report: NoonmarkDemoCoverageReport

    public static func make(
        anchorDate: LocalDate
    ) throws -> NoonmarkDemoFixture {
        let storyDates = try DemoCalendar.storyDates(
            endingAt: anchorDate,
            count: 10
        )
        let engine = NoonmarkEngine()
        var story = DemoStory(
            engine: engine,
            dates: storyDates
        )
        try story.replay()
        let report = NoonmarkDemoCoverageReport(
            engine: engine,
            storyDates: storyDates,
            anchorDate: anchorDate
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

public struct NoonmarkDemoCoverageReport: Codable, Equatable, Sendable {
    public let storyDates: [String]
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
    public let taskCycleSeriesCount: Int
    public let taskCycleOccurrenceCount: Int
    public let classifiedTaskCycleSeriesCount: Int
    public let taskCycleSeriesWithPlannedSubtasksCount: Int
    public let taskCyclePlanRevisionCount: Int
    public let openParentWithCompletedChildrenCount: Int
    public let completedParentWithCompletedChildrenCount: Int

    public var missingRequirements: [String] {
        var missing: [String] = []
        require(storyDates.count == 10, "十个连续使用日", into: &missing)
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
                traceStatusCounts[status.rawValue, default: 0] > 0,
                "任务轨迹状态 \(status.rawValue)",
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
                subtaskStatusCounts[status.rawValue, default: 0] > 0,
                "子任务状态 \(status.rawValue)",
                into: &missing
            )
        }
        require(pinnedTraceCount >= 2, "至少两项置顶队列", into: &missing)
        require(
            withdrawableDeferralCount > 0,
            "当天可撤回延期",
            into: &missing
        )
        require(reviewedDayCount >= 6, "至少六天复盘记录", into: &missing)
        require(categoryCount >= 4, "至少四个彩色分组", into: &missing)
        require(labelCount >= 4, "至少四个彩色标签", into: &missing)
        require(classifiedTaskCount >= 8, "跨页面分类任务", into: &missing)
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
        require(taskWithNotesCount >= 3, "跨状态任务附言", into: &missing)
        require(
            taskWithDescriptionCount >= 6,
            "跨页面任务描述",
            into: &missing
        )
        require(taskCycleSeriesCount > 0, "周期系列非空", into: &missing)
        require(
            classifiedTaskCycleSeriesCount > 0,
            "重复任务父项包含分组与标签",
            into: &missing
        )
        require(
            taskCycleSeriesWithPlannedSubtasksCount > 0,
            "重复任务父项包含规划子任务",
            into: &missing
        )
        require(
            taskCyclePlanRevisionCount > taskCycleSeriesCount,
            "重复任务包含向前生效的规则修订",
            into: &missing
        )
        require(
            taskCycleOccurrenceCount >= 10,
            "周期系列覆盖完整十天轨迹",
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
        return missing
    }

    public var isComplete: Bool {
        missingRequirements.isEmpty
    }

    init(
        engine: NoonmarkEngine,
        storyDates: [LocalDate],
        anchorDate: LocalDate
    ) {
        let snapshot = engine.snapshot()
        self.storyDates = storyDates.map(\.description)
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

private struct DemoStory {
    let engine: NoonmarkEngine
    let dates: [LocalDate]
    private let clock: DemoClock

    init(engine: NoonmarkEngine, dates: [LocalDate]) {
        self.engine = engine
        self.dates = dates
        clock = DemoClock()
    }

    mutating func replay() throws {
        let taskIDs = try createTaskPool()
        let cycleSeriesID = try createCycleSeries()
        try replayFirstFiveDays(taskIDs)
        try replayLastFiveDays(taskIDs)
        try addTodayAndFutureState(taskIDs)
        _ = try engine.reviseTaskCycleSeries(
            seriesID: cycleSeriesID,
            schedule: .daily,
            endCondition: .onDate(
                try DemoCalendar.offset(dates[9], by: 3)
            ),
            today: dates[9],
            now: time(on: dates[9], hour: 14, minute: 50)
        )
        try addReviews()
        try engine.snapshot().validateIntegrity()
    }

    private func createCycleSeries() throws -> TaskCycleSeriesID {
        let plannedSubtask = PlannedSubtask(
            title: "记录完成、遗漏与下一步",
            position: 1,
            now: time(on: dates[0], hour: 6, minute: 44)
        )
        let seriesID = try engine.createTaskCycleSeries(
            title: "每日产品复盘",
            descriptionText: "每天用十分钟记录完成、遗漏与下一步。",
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
            now: time(on: dates[0], hour: 6, minute: 47)
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
            minute: 48
        )
        try classify(
            anchorChainID,
            category: ("复盘", "#E0851B"),
            labels: [("发布", "#E0851B")],
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
        return seriesID
    }

    private mutating func createTaskPool() throws -> DemoTaskIDs {
        let createdAt = time(on: dates[0], hour: 6)
        func create(
            _ title: String,
            description: String,
            note: String? = nil
        ) throws -> TaskChainID {
            try engine.createPoolTask(
                title: title,
                descriptionText: description,
                initialNoteBody: note,
                now: clock.next(from: createdAt)
            )
        }

        let taskIDs = try DemoTaskIDs(
            researchBrief: create(
                "整理用户研究简报",
                description: "把十次访谈洞察整理成可讨论的研究简报。",
                note: "先写结论，再补证据。"
            ),
            interviewFollowUp: create(
                "跟进访谈行动项",
                description: "逐项确认访谈后的负责人和截止日期。"
            ),
            onboardingDraft: create(
                "重写 onboarding 引导",
                description: "将宽泛目标改成可以当天交付的文案稿。"
            ),
            expense: create(
                "整理差旅报销",
                description: "核对票据并补齐报销说明。"
            ),
            deprecatedExperiment: create(
                "验证旧版增长实验",
                description: "这项实验已被新方向取代。"
            ),
            restoredPlan: create(
                "恢复发布前检查清单",
                description: "演示废弃后重新启用的任务链。"
            ),
            deferredDelivery: create(
                "交付首页交互稿",
                description: "完成首页交互稿并同步设计说明。",
                note: "交付前用真实窗口尺寸走查。"
            ),
            subtaskStudy: create(
                "完成可用性走查",
                description: "按完整用户路径记录问题和改进项。"
            ),
            unfinishedHandoff: create(
                "整理跨团队交接材料",
                description: "汇总仍待确认的接口和负责人。"
            ),
            pinnedFocus: create(
                "修复登录阻断问题",
                description: "今天的第一优先级，完成后才能继续验收。"
            ),
            pinnedReview: create(
                "审阅发布说明",
                description: "今天的第二优先级，确认范围与已知限制。"
            ),
            todayDeferral: create(
                "等待法务确认隐私文案",
                description: "今天主动延期到明天，仍允许撤回。"
            ),
            todayCompleted: create(
                "完成晨间同步",
                description: "记录当天目标和风险。"
            ),
            todayActive: create(
                "完善设置页交互",
                description: "检查滑动方向、分组视图和空标题表现。",
                note: "验证触控板和键盘两条路径。"
            ),
            plannedPool: create(
                "规划发布后复盘",
                description: "尚未排期，先在任务池拆解复盘步骤。",
                note: "收齐数据后再排进 Day Todo。"
            ),
            emptyTitlePool: create(
                "临时标题",
                description: "空标题任务用于体验 No title 占位。"
            ),
            futureWorkshop: create(
                "主持路线图工作坊",
                description: "准备两小时路线图工作坊。"
            ),
            rescheduledFuture: create(
                "提交采购申请",
                description: "未来计划改期样例。"
            ),
            futureReturned: create(
                "预订季度会议室",
                description: "先排到未来，再主动回到任务池。"
            )
        )

        try classify(
            taskIDs.researchBrief,
            category: ("研究", "#7C5CFF"),
            labels: [("访谈", "#2A6FDB"), ("洞察", "#0E9488")]
        )
        try classify(
            taskIDs.interviewFollowUp,
            category: ("研究", "#7C5CFF"),
            labels: [("访谈", "#2A6FDB")]
        )
        try classify(
            taskIDs.onboardingDraft,
            category: ("产品", "#2A6FDB"),
            labels: [("文案", "#D1477A")]
        )
        try classify(
            taskIDs.deferredDelivery,
            category: ("设计", "#D1477A"),
            labels: [("交付", "#E0851B")]
        )
        try classify(
            taskIDs.subtaskStudy,
            category: ("研究", "#7C5CFF"),
            labels: [("走查", "#0E9488")]
        )
        try classify(
            taskIDs.pinnedFocus,
            category: ("工程", "#0E9488"),
            labels: [("阻断", "#D1477A")]
        )
        try classify(
            taskIDs.pinnedReview,
            category: ("产品", "#2A6FDB"),
            labels: [("发布", "#E0851B")]
        )
        try classify(
            taskIDs.todayActive,
            category: ("工程", "#0E9488"),
            labels: [("体验", "#7C5CFF")]
        )
        try classify(
            taskIDs.todayCompleted,
            category: ("工程", "#0E9488"),
            labels: [("同步", "#2A6FDB")]
        )
        try classify(
            taskIDs.unfinishedHandoff,
            category: ("协作", "#E0851B"),
            labels: [("交接", "#2A6FDB")]
        )
        try classify(
            taskIDs.plannedPool,
            category: ("复盘", "#E0851B"),
            labels: [("发布", "#E0851B")]
        )
        try classify(
            taskIDs.futureWorkshop,
            category: ("产品", "#2A6FDB"),
            labels: [("路线图", "#7C5CFF")]
        )

        try engine.addPlannedSubtask(
            chainID: taskIDs.plannedPool,
            title: "汇总十天任务轨迹",
            difficulty: .simple,
            now: clock.next(from: createdAt)
        )
        try engine.addPlannedSubtask(
            chainID: taskIDs.plannedPool,
            title: "归纳延期与未完成原因",
            difficulty: .medium,
            now: clock.next(from: createdAt)
        )
        try engine.addPlannedSubtask(
            chainID: taskIDs.plannedPool,
            title: "形成下一轮改进计划",
            difficulty: .hard,
            now: clock.next(from: createdAt)
        )
        try engine.updatePoolTask(
            chainID: taskIDs.emptyTitlePool,
            title: "",
            descriptionText: "空标题任务用于体验 No title 占位。",
            now: clock.next(from: createdAt)
        )
        return taskIDs
    }

    private mutating func replayFirstFiveDays(
        _ ids: DemoTaskIDs
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
        try completeCycleOccurrence(on: dates[0], hour: 18)

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
            newTitle: "交付 onboarding 三屏文案",
            newDescriptionText: "产出可直接评审的三屏文案。",
            today: dates[2],
            now: time(on: dates[2], hour: 10)
        )
        try engine.markCompleted(
            traceID: rewritten,
            today: dates[2],
            now: time(on: dates[2], hour: 17)
        )
        try completeCycleOccurrence(on: dates[2], hour: 18)

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
        try completeCycleOccurrence(on: dates[4], hour: 18)
    }

    private mutating func replayLastFiveDays(
        _ ids: DemoTaskIDs
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
            title: "复现关键路径",
            difficulty: .simple,
            now: time(on: dates[6], hour: 9)
        )
        _ = try engine.addSubtask(
            traceID: study,
            title: "记录交互问题",
            difficulty: .medium,
            now: time(on: dates[6], hour: 9, minute: 1)
        )
        let obsolete = try engine.addSubtask(
            traceID: study,
            title: "检查已移除入口",
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
        try completeCycleOccurrence(on: dates[6], hour: 18)

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
        try completeCycleOccurrence(on: dates[8], hour: 18)

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
                title: "同步当天目标",
                now: time(on: dates[9], hour: 7, minute: 1)
            ),
            engine.addSubtask(
                traceID: completed,
                title: "确认关键风险",
                now: time(on: dates[9], hour: 7, minute: 2)
            ),
            engine.addSubtask(
                traceID: completed,
                title: "记录下一步",
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
            title: "检查全局输入光标",
            difficulty: .simple,
            now: time(on: dates[9], hour: 10, minute: 1)
        )
        _ = try engine.addSubtask(
            traceID: active,
            title: "验证左右滑动方向",
            difficulty: .medium,
            now: time(on: dates[9], hour: 10, minute: 2)
        )
        _ = try engine.addSubtask(
            traceID: active,
            title: "检查分组颜色与置顶排序",
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

    private func addReviews() throws {
        for (index, date) in dates.dropLast().enumerated() {
            engine.updateDailyReview(
                date: date,
                summary: "第 \(index + 1) 天：完成了计划中的关键推进，并保留真实任务轨迹。",
                unfinishedReason: index.isMultiple(of: 2)
                    ? "临时沟通压缩了深度工作时间。"
                    : "依赖信息到达较晚。",
                tomorrowNote: "明天先处理最重要的一项，再打开消息。",
                now: time(on: dates[9], hour: 14, minute: index)
            )
        }
        engine.updateDailyReview(
            date: dates[9],
            summary: "今天仍在进行：置顶任务、主动延期和未来排期都可继续体验。",
            unfinishedReason: "",
            tomorrowNote: "体验烛龙规划与日终复盘。",
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
        on date: LocalDate,
        hour: Int
    ) throws {
        guard let chainID = engine.chains.values.first(where: {
            $0.cycleMembership?.occurrenceDate == date
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
        calendar.timeZone = TimeZone(secondsFromGMT: -4 * 60 * 60)
            ?? .current
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
