import NoonmarkCore

/// 年度演示故事的用户可见文案表。
///
/// 同一套三百六十五天故事结构通过 `.chinese`（默认）与 `.english`
/// 两个实例渲染；带插值的文案以 closure 属性表达。
/// `NoonmarkDemoCoverageReport` 的诊断消息不是用户可见文案，保持中文。
public struct DemoStoryText: Sendable {
    public var categories: DemoStoryCategories
    public var labels: DemoStoryLabels
    public var annual: DemoStoryAnnualText
    public var story: DemoStoryCopy

    public static func forLanguage(_ language: AppLanguage) -> DemoStoryText {
        switch language {
        case .chinese:
            .chinese
        case .english:
            .english
        }
    }
}

/// 演示故事使用的分组名；颜色与语言无关，保留在调用点。
public struct DemoStoryCategories: Sendable {
    public var research: String
    public var product: String
    public var engineering: String
    public var collaboration: String
    public var design: String
    public var review: String
}

/// 演示故事使用的标签名；颜色与语言无关，保留在调用点。
public struct DemoStoryLabels: Sendable {
    public var insight: String
    public var release: String
    public var experience: String
    public var handoff: String
    public var interview: String
    public var copy: String
    public var delivery: String
    public var walkthrough: String
    public var blocker: String
    public var sync: String
    public var roadmap: String
}

/// 演示任务池里单个任务的标题、说明与可选初始附言。
public struct DemoStoryTaskCopy: Sendable {
    public var title: String
    public var taskDescription: String
    public var note: String?
}

/// 年度历史（前三百五十五天）重放使用的文案。
public struct DemoStoryAnnualText: Sendable {
    public var cyclePlannedSubtaskTitle: String
    public var annualWeekdaysTitle: String
    public var annualWeekdaysDescription: String
    public var annualWeeklyTitle: String
    public var annualWeeklyDescription: String
    public var upcomingWeekdaysTitle: String
    public var upcomingWeekdaysDescription: String
    public var upcomingAlternateDayTitle: String
    public var upcomingAlternateDayDescription: String
    public var endedDailyTitle: String
    public var endedDailyDescription: String
    public var endedWeeklyTitle: String
    public var endedWeeklyDescription: String
    public var stoppedWeekdaysTitle: String
    public var stoppedWeekdaysDescription: String
    public var stoppedWeeklyTitle: String
    public var stoppedWeeklyDescription: String
    public var monthlyOrganizeInputsTitle: @Sendable (Int) -> String
    public var monthlyCompletePrioritiesTitle: @Sendable (Int) -> String
    public var monthlyCarryOverTitle: @Sendable (Int) -> String
    public var monthlyNarrowScopeTitle: @Sendable (Int) -> String
    public var monthlyDeferDependenciesTitle: @Sendable (Int) -> String
    public var monthlyReworkScheduleTitle: @Sendable (Int) -> String
    public var monthlyStopStaleTitle: @Sendable (Int) -> String
    public var monthlyResumePlanTitle: @Sendable (Int) -> String
    public var monthlyBreakDownStepsTitle: @Sendable (Int) -> String
    public var monthlyAdjustFuturePlansTitle: @Sendable (Int) -> String
    public var monthlyDeliverPrioritiesTitle: @Sendable (Int) -> String
    public var monthlyDeliverNarrowedTitle: @Sendable (Int) -> String
    public var monthlyDeliverNarrowedDescription: String
    public var monthlySavedDescription: @Sendable (Int) -> String
    public var monthlyTaskDescription: @Sendable (Int) -> String
    public var monthlyInitialNote: @Sendable (Int) -> String
    public var poolEditFullTitle: @Sendable (Int) -> String
    public var poolEditDescription: String
    public var poolNoteDraft: String
    public var poolNoteEdited: String
    public var poolPlannedOrganizeTitle: String
    public var poolPlannedRemoveDuplicatesTitle: String
    public var poolPlannedOrganizeReviewedTitle: String
    public var traceNoteDraft: @Sendable (Int) -> String
    public var traceNoteEdited: @Sendable (Int) -> String
    public var subtaskCompletionTitle: @Sendable (Int) -> String
    public var subtaskAdjustmentTitle: @Sendable (Int) -> String
    public var subtaskDeletionTitle: @Sendable (Int) -> String
    public var subtaskCrossDayTitle: @Sendable (Int) -> String
    public var subtaskAdjustedTitle: @Sendable (Int) -> String
    public var dailyTaskTitle: @Sendable (Int) -> String
    public var dailyTaskDescription: @Sendable (Int) -> String
    public var dailyInitialNote: String
    public var dailyReviewSummary: @Sendable (Int) -> String
    public var dailyUnfinishedDependencyReason: String
    public var dailyUnfinishedPriorityReason: String
    public var dailyTomorrowNote: String
    public var deferralWithdrawalTitle: @Sendable (Int) -> String
    public var deferralWithdrawalDescription: String
    public var deferralWithdrawalNote: String
    public var deferralWithdrawalSubtaskTitle: @Sendable (Int) -> String
}

/// 前景十天故事重放使用的文案。
public struct DemoStoryCopy: Sendable {
    public var cyclePlannedSubtaskTitle: String
    public var dailyReviewSeriesTitle: String
    public var dailyReviewSeriesDescription: String
    public var morningReviewSeriesTitle: String
    public var morningReviewSeriesDescription: String
    public var pausedWeeklySeriesTitle: String
    public var pausedWeeklySeriesDescription: String
    public var upcomingReviewSeriesTitle: String
    public var upcomingReviewSeriesDescription: String
    public var upcomingReviewPlannedSubtaskTitle: String
    public var researchBrief: DemoStoryTaskCopy
    public var interviewFollowUp: DemoStoryTaskCopy
    public var onboardingDraft: DemoStoryTaskCopy
    public var expense: DemoStoryTaskCopy
    public var deprecatedExperiment: DemoStoryTaskCopy
    public var restoredPlan: DemoStoryTaskCopy
    public var deferredDelivery: DemoStoryTaskCopy
    public var subtaskStudy: DemoStoryTaskCopy
    public var unfinishedHandoff: DemoStoryTaskCopy
    public var pinnedFocus: DemoStoryTaskCopy
    public var pinnedReview: DemoStoryTaskCopy
    public var todayDeferral: DemoStoryTaskCopy
    public var todayCompleted: DemoStoryTaskCopy
    public var todayActive: DemoStoryTaskCopy
    public var plannedPool: DemoStoryTaskCopy
    public var emptyTitlePool: DemoStoryTaskCopy
    public var futureWorkshop: DemoStoryTaskCopy
    public var rescheduledFuture: DemoStoryTaskCopy
    public var futureReturned: DemoStoryTaskCopy
    public var onboardingRewrittenTitle: String
    public var onboardingRewrittenDescription: String
    public var plannedPoolSubtaskSummarize: String
    public var plannedPoolSubtaskGroupReasons: String
    public var plannedPoolSubtaskImprovementPlan: String
    public var studySubtaskReproduce: String
    public var studySubtaskRecordIssues: String
    public var studySubtaskRemovedEntry: String
    public var syncSubtaskGoals: String
    public var syncSubtaskRisks: String
    public var syncSubtaskNextSteps: String
    public var activeSubtaskCursor: String
    public var activeSubtaskSwipe: String
    public var activeSubtaskGroupColors: String
    public var ideaOnboardingConfusion: String
    public var ideaExpenseBatching: String
    public var ideaHoverFeedback: String
    public var ideaHoverFeedbackEdited: String
    public var ideaStaleExperiment: String
    public var ideaWalkthroughSurprise: String
    public var ideaDataCaliber: String
    public var ideaHandoffTemplate: String
    public var ideaReleaseWorkarounds: String
    public var ideaStickyAttention: String
    public var ideaDataCaliberRestored: String
    public var reviewSummary: @Sendable (Int) -> String
    public var reviewUnfinishedMeetingReason: String
    public var reviewUnfinishedDependencyReason: String
    public var reviewTomorrowNote: String
    public var finalReviewSummary: String
    public var finalReviewTomorrowNote: String
}

public extension DemoStoryText {
    /// 中文文案：逐字来自既有年度演示 fixture。
    static let chinese = DemoStoryText(
        categories: DemoStoryCategories(
            research: "研究",
            product: "产品",
            engineering: "工程",
            collaboration: "协作",
            design: "设计",
            review: "复盘"
        ),
        labels: DemoStoryLabels(
            insight: "洞察",
            release: "发布",
            experience: "体验",
            handoff: "交接",
            interview: "访谈",
            copy: "文案",
            delivery: "交付",
            walkthrough: "走查",
            blocker: "阻断",
            sync: "同步",
            roadmap: "路线图"
        ),
        annual: DemoStoryAnnualText(
            cyclePlannedSubtaskTitle: "记录本次执行结果",
            annualWeekdaysTitle: "年度工作日整理",
            annualWeekdaysDescription: "跨越一整年的工作日重复计划。",
            annualWeeklyTitle: "年度每周回顾",
            annualWeeklyDescription: "跨越一整年的每周重复计划。",
            upcomingWeekdaysTitle: "下月工作日复盘",
            upcomingWeekdaysDescription: "尚未开始的工作日重复计划。",
            upcomingAlternateDayTitle: "下月隔日训练",
            upcomingAlternateDayDescription: "尚未开始的隔日重复计划。",
            endedDailyTitle: "首月每日整理",
            endedDailyDescription: "已经自然结束的每日重复计划。",
            endedWeeklyTitle: "首月每周盘点",
            endedWeeklyDescription: "已经自然结束的每周重复计划。",
            stoppedWeekdaysTitle: "停止年度工作日记录",
            stoppedWeekdaysDescription: "提前停止并保留历史的工作日计划。",
            stoppedWeeklyTitle: "停止年度周报",
            stoppedWeeklyDescription: "提前停止并保留历史的每周计划。",
            monthlyOrganizeInputsTitle: { "年度第 \($0) 轮：整理月度输入" },
            monthlyCompletePrioritiesTitle: { "年度第 \($0) 轮：完成重点事项" },
            monthlyCarryOverTitle: { "年度第 \($0) 轮：延续未完成事项" },
            monthlyNarrowScopeTitle: { "年度第 \($0) 轮：收窄任务范围" },
            monthlyDeferDependenciesTitle: { "年度第 \($0) 轮：延期依赖事项" },
            monthlyReworkScheduleTitle: { "年度第 \($0) 轮：重新整理排期" },
            monthlyStopStaleTitle: { "年度第 \($0) 轮：停止失效尝试" },
            monthlyResumePlanTitle: { "年度第 \($0) 轮：恢复有效计划" },
            monthlyBreakDownStepsTitle: { "年度第 \($0) 轮：拆解交付步骤" },
            monthlyAdjustFuturePlansTitle: { "年度第 \($0) 轮：调整未来计划" },
            monthlyDeliverPrioritiesTitle: { "年度第 \($0) 轮：交付重点事项" },
            monthlyDeliverNarrowedTitle: { "年度第 \($0) 轮：交付收窄后的结果" },
            monthlyDeliverNarrowedDescription: "保留旧任务轨迹，并完成范围明确的新任务。",
            monthlySavedDescription: { "第 \($0) 轮在一年负载下保存的任务说明。" },
            monthlyTaskDescription: { "一年演示第 \($0) 轮的真实任务说明。" },
            monthlyInitialNote: { "第 \($0) 轮初始附言。" },
            poolEditFullTitle: { "年度第 \($0) 轮：整理完整月度输入" },
            poolEditDescription: "修改后的任务池说明覆盖标题与说明保存。",
            poolNoteDraft: "待编辑的月度附言。",
            poolNoteEdited: "已经编辑的月度附言。",
            poolPlannedOrganizeTitle: "整理本月输入",
            poolPlannedRemoveDuplicatesTitle: "移除重复步骤",
            poolPlannedOrganizeReviewedTitle: "整理并核对本月输入",
            traceNoteDraft: { "第 \($0) 轮待编辑的执行附言。" },
            traceNoteEdited: { "第 \($0) 轮已经编辑的执行附言。" },
            subtaskCompletionTitle: { "第 \($0) 轮完成步骤" },
            subtaskAdjustmentTitle: { "第 \($0) 轮调整步骤" },
            subtaskDeletionTitle: { "第 \($0) 轮删除步骤" },
            subtaskCrossDayTitle: { "第 \($0) 轮跨日步骤" },
            subtaskAdjustedTitle: { "第 \($0) 轮已经调整的步骤" },
            dailyTaskTitle: { "年度第 \($0) 天：完成日常推进" },
            dailyTaskDescription: { "连续一年中第 \($0) 天的真实任务记录。" },
            dailyInitialNote: "当天先完成首要事项。",
            dailyReviewSummary: { "年度第 \($0) 天：完成了一项可核对的推进。" },
            dailyUnfinishedDependencyReason: "依赖确认压缩了原定时间。",
            dailyUnfinishedPriorityReason: "为更重要的交付主动调整了顺序。",
            dailyTomorrowNote: "明天先完成首要任务，再处理新增输入。",
            deferralWithdrawalTitle: { "年度撤回延期样例 \($0)" },
            deferralWithdrawalDescription: "在今天撤回一次延期并继续保留为待办。",
            deferralWithdrawalNote: "用于验证撤回延期不会丢失内容。",
            deferralWithdrawalSubtaskTitle: { "撤回延期后继续处理的步骤 \($0)" }
        ),
        story: DemoStoryCopy(
            cyclePlannedSubtaskTitle: "记录完成、遗漏与下一步",
            dailyReviewSeriesTitle: "每日产品复盘",
            dailyReviewSeriesDescription: "每天用十分钟记录完成、遗漏与下一步。",
            morningReviewSeriesTitle: "完成首次晨间回顾",
            morningReviewSeriesDescription: "已按计划完成的一次性重复计划，用于查看历史终态。",
            pausedWeeklySeriesTitle: "暂停周报打磨",
            pausedWeeklySeriesDescription: "提前停止但保留历史与当天事实的重复计划。",
            upcomingReviewSeriesTitle: "准备下周工作回顾",
            upcomingReviewSeriesDescription: "尚未开始，可在父任务详情中调整开始日期。",
            upcomingReviewPlannedSubtaskTitle: "整理本周输入",
            researchBrief: DemoStoryTaskCopy(
                title: "整理用户研究简报",
                taskDescription: "把十次访谈洞察整理成可讨论的研究简报。",
                note: "先写结论，再补证据。"
            ),
            interviewFollowUp: DemoStoryTaskCopy(
                title: "跟进访谈行动项",
                taskDescription: "逐项确认访谈后的负责人和截止日期。",
                note: nil
            ),
            onboardingDraft: DemoStoryTaskCopy(
                title: "重写 onboarding 引导",
                taskDescription: "将宽泛目标改成可以当天交付的文案稿。",
                note: nil
            ),
            expense: DemoStoryTaskCopy(
                title: "整理差旅报销",
                taskDescription: "核对票据并补齐报销说明。",
                note: nil
            ),
            deprecatedExperiment: DemoStoryTaskCopy(
                title: "验证旧版增长实验",
                taskDescription: "这项实验已被新方向取代。",
                note: nil
            ),
            restoredPlan: DemoStoryTaskCopy(
                title: "恢复发布前检查清单",
                taskDescription: "演示废弃后重新启用的任务链。",
                note: nil
            ),
            deferredDelivery: DemoStoryTaskCopy(
                title: "交付首页交互稿",
                taskDescription: "完成首页交互稿并同步设计说明。",
                note: "交付前用真实窗口尺寸走查。"
            ),
            subtaskStudy: DemoStoryTaskCopy(
                title: "完成可用性走查",
                taskDescription: "按完整用户路径记录问题和改进项。",
                note: nil
            ),
            unfinishedHandoff: DemoStoryTaskCopy(
                title: "整理跨团队交接材料",
                taskDescription: "汇总仍待确认的接口和负责人。",
                note: nil
            ),
            pinnedFocus: DemoStoryTaskCopy(
                title: "修复登录阻断问题",
                taskDescription: "今天的第一优先级，完成后才能继续验收。",
                note: nil
            ),
            pinnedReview: DemoStoryTaskCopy(
                title: "审阅发布说明",
                taskDescription: "今天的第二优先级，确认范围与已知限制。",
                note: nil
            ),
            todayDeferral: DemoStoryTaskCopy(
                title: "等待法务确认隐私文案",
                taskDescription: "今天主动延期到明天，仍允许撤回。",
                note: nil
            ),
            todayCompleted: DemoStoryTaskCopy(
                title: "完成晨间同步",
                taskDescription: "记录当天目标和风险。",
                note: nil
            ),
            todayActive: DemoStoryTaskCopy(
                title: "完善设置页交互",
                taskDescription: "检查滑动方向、分组视图和空标题表现。",
                note: "验证触控板和键盘两条路径。"
            ),
            plannedPool: DemoStoryTaskCopy(
                title: "规划发布后复盘",
                taskDescription: "尚未排期，先在任务池拆解复盘步骤。",
                note: "收齐数据后再排进 Day Todo。"
            ),
            emptyTitlePool: DemoStoryTaskCopy(
                title: "临时标题",
                taskDescription: "空标题任务用于体验 No title 占位。",
                note: nil
            ),
            futureWorkshop: DemoStoryTaskCopy(
                title: "主持路线图工作坊",
                taskDescription: "准备两小时路线图工作坊。",
                note: nil
            ),
            rescheduledFuture: DemoStoryTaskCopy(
                title: "提交采购申请",
                taskDescription: "未来计划改期样例。",
                note: nil
            ),
            futureReturned: DemoStoryTaskCopy(
                title: "预订季度会议室",
                taskDescription: "先排到未来，再主动回到任务池。",
                note: nil
            ),
            onboardingRewrittenTitle: "交付 onboarding 三屏文案",
            onboardingRewrittenDescription: "产出可直接评审的三屏文案。",
            plannedPoolSubtaskSummarize: "汇总十天任务轨迹",
            plannedPoolSubtaskGroupReasons: "归纳延期与未完成原因",
            plannedPoolSubtaskImprovementPlan: "形成下一轮改进计划",
            studySubtaskReproduce: "复现关键路径",
            studySubtaskRecordIssues: "记录交互问题",
            studySubtaskRemovedEntry: "检查已移除入口",
            syncSubtaskGoals: "同步当天目标",
            syncSubtaskRisks: "确认关键风险",
            syncSubtaskNextSteps: "记录下一步",
            activeSubtaskCursor: "检查全局输入光标",
            activeSubtaskSwipe: "验证左右滑动方向",
            activeSubtaskGroupColors: "检查分组颜色与置顶排序",
            ideaOnboardingConfusion: "访谈里好几个人提到 onboarding 第一屏不知道先点哪里，先记下来，走查时验证。",
            ideaExpenseBatching: "差旅报销能不能攒到月底批量处理？每次都打断半个下午。",
            ideaHoverFeedback: "首页交互稿的悬停反馈有点保守，交付前再想想。",
            ideaHoverFeedbackEdited: "首页交互稿的悬停反馈有点保守；和设计对齐后决定保留大字号方案，交付稿里注明。",
            ideaStaleExperiment: "旧增长实验的原始数据要不要归档？明天问数据组。",
            ideaWalkthroughSurprise: "可用性走查的意外发现：空标题占位比想象中更容易误触，值得单独跟进。",
            ideaDataCaliber: "周报数据口径的注释要不要单独维护？下周对齐前别再改模板。",
            ideaHandoffTemplate: "交接材料里的接口清单可以抽成模板，下个项目直接复用。",
            ideaReleaseWorkarounds: "审阅发布说明时想到：已知限制应该附上临时绕过方法，减少支持成本。",
            ideaStickyAttention: "连续用了十天，Sticky Note 比长清单更能压住注意力，写进复盘。",
            ideaDataCaliberRestored: "数据口径注释确认由周报模板统一维护，恢复这条留作月底跟进提醒。",
            reviewSummary: { "第 \($0) 天：完成了计划中的关键推进，并保留真实任务轨迹。" },
            reviewUnfinishedMeetingReason: "临时沟通压缩了深度工作时间。",
            reviewUnfinishedDependencyReason: "依赖信息到达较晚。",
            reviewTomorrowNote: "明天先处理最重要的一项，再打开消息。",
            finalReviewSummary: "今天仍在进行：置顶任务、主动延期和未来排期都可继续体验。",
            finalReviewTomorrowNote: "体验烛龙规划与日终复盘。"
        )
    )

    /// 英文文案：与中文变体结构、数量、颜色完全一致的母语级翻译。
    static let english = DemoStoryText(
        categories: DemoStoryCategories(
            research: "Research",
            product: "Product",
            engineering: "Engineering",
            collaboration: "Collaboration",
            design: "Design",
            review: "Review"
        ),
        labels: DemoStoryLabels(
            insight: "Insights",
            release: "Release",
            experience: "Experience",
            handoff: "Handoff",
            interview: "Interviews",
            copy: "Copy",
            delivery: "Delivery",
            walkthrough: "Walkthrough",
            blocker: "Blocker",
            sync: "Sync",
            roadmap: "Roadmap"
        ),
        annual: DemoStoryAnnualText(
            cyclePlannedSubtaskTitle: "Log the outcome of this run",
            annualWeekdaysTitle: "Year-long weekday tidy-up",
            annualWeekdaysDescription: "A weekday recurring plan spanning the full year.",
            annualWeeklyTitle: "Year-long weekly review",
            annualWeeklyDescription: "A weekly recurring plan spanning the full year.",
            upcomingWeekdaysTitle: "Next month's weekday review",
            upcomingWeekdaysDescription: "A weekday recurring plan that has not started yet.",
            upcomingAlternateDayTitle: "Next month's alternate-day training",
            upcomingAlternateDayDescription: "An every-other-day recurring plan that has not started yet.",
            endedDailyTitle: "First-month daily tidy-up",
            endedDailyDescription: "A daily recurring plan that ended naturally.",
            endedWeeklyTitle: "First-month weekly inventory",
            endedWeeklyDescription: "A weekly recurring plan that ended naturally.",
            stoppedWeekdaysTitle: "Stopped year-long weekday log",
            stoppedWeekdaysDescription: "A weekday plan stopped early with history preserved.",
            stoppedWeeklyTitle: "Stopped year-long weekly report",
            stoppedWeeklyDescription: "A weekly plan stopped early with history preserved.",
            monthlyOrganizeInputsTitle: { "Round \($0): Organize monthly inputs" },
            monthlyCompletePrioritiesTitle: { "Round \($0): Complete the priorities" },
            monthlyCarryOverTitle: { "Round \($0): Carry over unfinished work" },
            monthlyNarrowScopeTitle: { "Round \($0): Narrow the task scope" },
            monthlyDeferDependenciesTitle: { "Round \($0): Defer dependent items" },
            monthlyReworkScheduleTitle: { "Round \($0): Rework the schedule" },
            monthlyStopStaleTitle: { "Round \($0): Stop obsolete attempts" },
            monthlyResumePlanTitle: { "Round \($0): Resume an effective plan" },
            monthlyBreakDownStepsTitle: { "Round \($0): Break down delivery steps" },
            monthlyAdjustFuturePlansTitle: { "Round \($0): Adjust future plans" },
            monthlyDeliverPrioritiesTitle: { "Round \($0): Deliver the priorities" },
            monthlyDeliverNarrowedTitle: { "Round \($0): Deliver the narrowed outcome" },
            monthlyDeliverNarrowedDescription: "Keep the old task trail and complete the new, clearly scoped task.",
            monthlySavedDescription: { "Task description saved under a year of load in round \($0)." },
            monthlyTaskDescription: { "A real task description for round \($0) of the year-long demo." },
            monthlyInitialNote: { "Initial note for round \($0)." },
            poolEditFullTitle: { "Round \($0): Organize the complete monthly inputs" },
            poolEditDescription: "The edited pool description covers title and description saving.",
            poolNoteDraft: "Monthly note pending edits.",
            poolNoteEdited: "Monthly note after editing.",
            poolPlannedOrganizeTitle: "Organize this month's inputs",
            poolPlannedRemoveDuplicatesTitle: "Remove duplicate steps",
            poolPlannedOrganizeReviewedTitle: "Organize and verify this month's inputs",
            traceNoteDraft: { "Execution note for round \($0), pending edits." },
            traceNoteEdited: { "Edited execution note for round \($0)." },
            subtaskCompletionTitle: { "Round \($0) completion step" },
            subtaskAdjustmentTitle: { "Round \($0) adjustment step" },
            subtaskDeletionTitle: { "Round \($0) deletion step" },
            subtaskCrossDayTitle: { "Round \($0) cross-day step" },
            subtaskAdjustedTitle: { "Round \($0) adjusted step" },
            dailyTaskTitle: { "Day \($0): Make daily progress" },
            dailyTaskDescription: { "A real task record for day \($0) of the consecutive year." },
            dailyInitialNote: "Finish the top priority first that day.",
            dailyReviewSummary: { "Day \($0): Completed a verifiable step forward." },
            dailyUnfinishedDependencyReason: "Waiting on dependency confirmation shrank the planned time.",
            dailyUnfinishedPriorityReason: "Proactively reordered work for a more important delivery.",
            dailyTomorrowNote: "Tomorrow: finish the top task first, then handle new inputs.",
            deferralWithdrawalTitle: { "Deferral withdrawal sample \($0)" },
            deferralWithdrawalDescription: "Withdraw a deferral today and keep the task as pending.",
            deferralWithdrawalNote: "Verifies that withdrawing a deferral loses no content.",
            deferralWithdrawalSubtaskTitle: { "Step \($0) to continue after withdrawing the deferral" }
        ),
        story: DemoStoryCopy(
            cyclePlannedSubtaskTitle: "Log what was done, missed, and next",
            dailyReviewSeriesTitle: "Daily product review",
            dailyReviewSeriesDescription: "Spend ten minutes each day logging what was done, missed, and next.",
            morningReviewSeriesTitle: "Complete the first morning review",
            morningReviewSeriesDescription: "A one-off recurring plan completed as scheduled, for viewing a finished end state.",
            pausedWeeklySeriesTitle: "Paused weekly report polish",
            pausedWeeklySeriesDescription: "A recurring plan stopped early while keeping history and today's facts.",
            upcomingReviewSeriesTitle: "Prepare next week's work review",
            upcomingReviewSeriesDescription: "Not started yet; adjust the start date in the parent task details.",
            upcomingReviewPlannedSubtaskTitle: "Organize this week's inputs",
            researchBrief: DemoStoryTaskCopy(
                title: "Organize the user research brief",
                taskDescription: "Turn insights from ten interviews into a brief ready for discussion.",
                note: "Write the conclusions first, then add evidence."
            ),
            interviewFollowUp: DemoStoryTaskCopy(
                title: "Follow up on interview action items",
                taskDescription: "Confirm the owner and due date for each post-interview item.",
                note: nil
            ),
            onboardingDraft: DemoStoryTaskCopy(
                title: "Rewrite the onboarding flow",
                taskDescription: "Turn broad goals into copy that can ship the same day.",
                note: nil
            ),
            expense: DemoStoryTaskCopy(
                title: "Organize travel expenses",
                taskDescription: "Check receipts and complete the expense notes.",
                note: nil
            ),
            deprecatedExperiment: DemoStoryTaskCopy(
                title: "Validate the legacy growth experiment",
                taskDescription: "This experiment has been superseded by a new direction.",
                note: nil
            ),
            restoredPlan: DemoStoryTaskCopy(
                title: "Restore the pre-release checklist",
                taskDescription: "Demonstrates a task chain reactivated after abandonment.",
                note: nil
            ),
            deferredDelivery: DemoStoryTaskCopy(
                title: "Deliver the homepage interaction draft",
                taskDescription: "Finish the homepage interaction draft and sync the design notes.",
                note: "Walk through it at real window sizes before delivery."
            ),
            subtaskStudy: DemoStoryTaskCopy(
                title: "Complete the usability walkthrough",
                taskDescription: "Record issues and improvements along the full user path.",
                note: nil
            ),
            unfinishedHandoff: DemoStoryTaskCopy(
                title: "Organize cross-team handoff materials",
                taskDescription: "Consolidate the interfaces and owners still awaiting confirmation.",
                note: nil
            ),
            pinnedFocus: DemoStoryTaskCopy(
                title: "Fix the login blocker",
                taskDescription: "Today's top priority; acceptance continues only after it is done.",
                note: nil
            ),
            pinnedReview: DemoStoryTaskCopy(
                title: "Review the release notes",
                taskDescription: "Today's second priority; confirm scope and known limitations.",
                note: nil
            ),
            todayDeferral: DemoStoryTaskCopy(
                title: "Wait for legal to confirm the privacy copy",
                taskDescription: "Deliberately deferred to tomorrow today; withdrawal is still allowed.",
                note: nil
            ),
            todayCompleted: DemoStoryTaskCopy(
                title: "Complete the morning sync",
                taskDescription: "Record the day's goals and risks.",
                note: nil
            ),
            todayActive: DemoStoryTaskCopy(
                title: "Polish the settings page interactions",
                taskDescription: "Check swipe directions, grouped views, and empty-title behavior.",
                note: "Verify both the trackpad and keyboard paths."
            ),
            plannedPool: DemoStoryTaskCopy(
                title: "Plan the post-release retrospective",
                taskDescription: "Not scheduled yet; break down the retrospective steps in the task pool first.",
                note: "Schedule it into Day Todo once the data is in."
            ),
            emptyTitlePool: DemoStoryTaskCopy(
                title: "Temporary title",
                taskDescription: "An empty-title task for experiencing the No title placeholder.",
                note: nil
            ),
            futureWorkshop: DemoStoryTaskCopy(
                title: "Host the roadmap workshop",
                taskDescription: "Prepare a two-hour roadmap workshop.",
                note: nil
            ),
            rescheduledFuture: DemoStoryTaskCopy(
                title: "Submit the procurement request",
                taskDescription: "A rescheduled future plan sample.",
                note: nil
            ),
            futureReturned: DemoStoryTaskCopy(
                title: "Book the quarterly meeting room",
                taskDescription: "Scheduled into the future first, then deliberately returned to the pool.",
                note: nil
            ),
            onboardingRewrittenTitle: "Deliver the three-screen onboarding copy",
            onboardingRewrittenDescription: "Produce three screens of copy ready for review.",
            plannedPoolSubtaskSummarize: "Summarize ten days of task trails",
            plannedPoolSubtaskGroupReasons: "Group the reasons for deferrals and unfinished work",
            plannedPoolSubtaskImprovementPlan: "Form the next improvement plan",
            studySubtaskReproduce: "Reproduce the critical path",
            studySubtaskRecordIssues: "Record interaction issues",
            studySubtaskRemovedEntry: "Check the removed entry point",
            syncSubtaskGoals: "Sync the day's goals",
            syncSubtaskRisks: "Confirm the key risks",
            syncSubtaskNextSteps: "Record the next steps",
            activeSubtaskCursor: "Check the global input cursor",
            activeSubtaskSwipe: "Verify left and right swipe directions",
            activeSubtaskGroupColors: "Check group colors and pinned ordering",
            ideaOnboardingConfusion: "Several interviewees didn't know where to tap first — verify in the walkthrough.",
            ideaExpenseBatching: "Can travel expenses batch at month-end? Each one eats half an afternoon.",
            ideaHoverFeedback: "Hover feedback in the homepage draft feels conservative; rethink before delivery.",
            ideaHoverFeedbackEdited: "Hover feedback felt conservative; design agreed to keep the large-type option.",
            ideaStaleExperiment: "Archive the raw data from the old growth experiment? Ask the data team tomorrow.",
            ideaWalkthroughSurprise: "Walkthrough surprise: the empty-title placeholder is easy to trigger by accident.",
            ideaDataCaliber: "Maintain the weekly report's data-caliber notes separately? Align next week.",
            ideaHandoffTemplate: "The interface list in the handoff materials could become a reusable template.",
            ideaReleaseWorkarounds: "Release notes thought: ship known limitations with temporary workarounds.",
            ideaStickyAttention: "Ten days in, Sticky Notes hold attention better than long lists — log it.",
            ideaDataCaliberRestored: "Data-caliber notes stay in the weekly template; restored as a month-end reminder.",
            reviewSummary: { "Day \($0): Made the planned key progress and kept a real task trail." },
            reviewUnfinishedMeetingReason: "Ad-hoc conversations cut into deep-work time.",
            reviewUnfinishedDependencyReason: "Dependency information arrived late.",
            reviewTomorrowNote: "Tomorrow: handle the most important item first, then open messages.",
            finalReviewSummary: "Today is still in progress: pinned tasks, deliberate deferrals, and future scheduling remain explorable.",
            finalReviewTomorrowNote: "Try Zhulong planning and the end-of-day review."
        )
    )
}
