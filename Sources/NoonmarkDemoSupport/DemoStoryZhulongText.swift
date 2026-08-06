import NoonmarkCore

/// 年度演示烛龙会话的用户可见文案表。
///
/// 会话结构、授权边界与时间线与语言无关；`.chinese`（默认）逐字保留
/// 既有演示会话文案，`.english` 提供结构对等的母语级翻译。带插值的
/// 文案以 closure 属性表达。本表只承载字符串，不引用烛龙领域类型，
/// 因此不向 `NoonmarkDemoSupport` 引入新的模块依赖。
public struct DemoStoryZhulongText: Sendable {
    public var poolAnalysis: DemoStoryPoolAnalysisText
    public var submittedPlanning: DemoStorySubmittedPlanningText
    public var activePlanning: DemoStoryActivePlanningText
    public var insight: DemoStoryInsightText
    public var dailyReview: DemoStoryDailyReviewText
    public var payload: DemoStoryZhulongPayloadText

    public static func forLanguage(
        _ language: AppLanguage
    ) -> DemoStoryZhulongText {
        switch language {
        case .chinese:
            .chinese
        case .english:
            .english
        }
    }
}

/// 任务池分析会话的文案；证据标题取自引擎数据，不在本表。
public struct DemoStoryPoolAnalysisText: Sendable {
    public var evidenceFallbackReference: String
    public var findingConclusion: @Sendable (String) -> String
    public var findingUncertainty: String
    public var findingRecommendation: String
    public var primaryIntent: String
    public var systemPrompt: String
    public var responseContent: String
}

/// 已提交规划会话（发布演示计划）的文案。
public struct DemoStorySubmittedPlanningText: Sendable {
    public var primaryIntent: String
    public var prepareDemoTitle: String
    public var prepareDemoDescription: String
    public var prepareDemoNote: String
    public var subtaskDayTodoStatus: String
    public var subtaskFutureAndPool: String
    public var subtaskRecordFeedback: String
    public var feedbackTitle: String
    public var feedbackDescription: String
    public var retrospectiveTitle: String
    public var retrospectiveDescription: String
    public var prompt: String
    public var responseContent: String
    public var confirmedScopeSuffix: String
}

/// 进行中规划会话（PostgreSQL 索引学习）的文案。
public struct DemoStoryActivePlanningText: Sendable {
    public var primaryIntent: String
    public var title: String
    public var taskDescription: String
    public var note: String
    public var subtaskLeftmostPrefix: String
    public var subtaskCovering: String
    public var subtaskOrdering: String
    public var subtaskJoins: String
    public var subtaskExplain: String
    public var prompt: String
    public var responseContent: String
}

/// 习惯洞察会话的文案。
public struct DemoStoryInsightText: Sendable {
    public var primaryIntent: String
    public var prompt: String
    public var responseContent: String
}

/// 日终复盘会话的文案。
public struct DemoStoryDailyReviewText: Sendable {
    public var primaryIntent: String
    public var statementContent: String
    public var summary: String
    public var tomorrowNote: String
}

/// 烛龙 provider payload 的公共文案。
public struct DemoStoryZhulongPayloadText: Sendable {
    public var systemPrompt: String
    public var scopeContent: @Sendable (String) -> String
}

public extension DemoStoryZhulongText {
    /// 中文文案：逐字来自既有年度演示烛龙会话。
    static let chinese = DemoStoryZhulongText(
        poolAnalysis: DemoStoryPoolAnalysisText(
            evidenceFallbackReference: "该任务",
            findingConclusion: { "「\($0)」的完成边界仍可更具体。" },
            findingUncertainty: "当前判断只依据任务池里已有的标题、说明、附言与计划子任务。",
            findingRecommendation: "补充可观察的交付物或完成标准，再决定是否安排日期。",
            primaryIntent: "分析当前任务池，找出需要澄清或安排的任务。",
            systemPrompt: "这是晷迹交互式演示中的任务池分析。",
            responseContent: "我找到一项值得先明确完成边界的任务。"
        ),
        submittedPlanning: DemoStorySubmittedPlanningText(
            primaryIntent: "帮我规划发布演示，并把结果安排进今天、任务池和未来计划。",
            prepareDemoTitle: "准备发布演示",
            prepareDemoDescription: "按真实用户路径完成一次发布前演示。",
            prepareDemoNote: "先验证任务状态，再演示烛龙。",
            subtaskDayTodoStatus: "检查 Day Todo 状态",
            subtaskFutureAndPool: "检查未来计划与回池",
            subtaskRecordFeedback: "记录演示反馈",
            feedbackTitle: "整理演示反馈问题",
            feedbackDescription: "收集体验过程中发现的细节问题。",
            retrospectiveTitle: "安排发布后复盘会议",
            retrospectiveDescription: "在演示完成两天后集中复盘。",
            prompt: "形成可编辑的发布演示任务计划。",
            responseContent: "我先整理成三个去向明确的任务，你可以继续编辑。",
            confirmedScopeSuffix: "（已确认范围）"
        ),
        activePlanning: DemoStoryActivePlanningText(
            primaryIntent: "我想深入学习 PostgreSQL 的索引，我们一起规划一下。",
            title: "理解 PostgreSQL 索引策略",
            taskDescription: "从最左前缀、覆盖索引到 EXPLAIN/ANALYZE。",
            note: "完成后用一个真实查询验证。",
            subtaskLeftmostPrefix: "理解复合索引的最左前缀原则",
            subtaskCovering: "练习覆盖索引与 INCLUDE 列",
            subtaskOrdering: "验证 ORDER BY 与 NULLS 排序",
            subtaskJoins: "检查联合查询与子查询的索引使用",
            subtaskExplain: "用 EXPLAIN / ANALYZE 判断索引失效",
            prompt: "把 PostgreSQL 索引学习目标拆成可编辑任务。",
            responseContent: "我拆成一个主任务和五个循序渐进的子任务，提交前都可以修改。"
        ),
        insight: DemoStoryInsightText(
            primaryIntent: "复盘一下最近任务经常延期的模式。",
            prompt: "根据轨迹总结延期模式，不创建任务。",
            responseContent: "最近的延期主要发生在依赖未确认和任务范围过大的场景。建议把等待依赖与可独立推进的部分分开。"
        ),
        dailyReview: DemoStoryDailyReviewText(
            primaryIntent: "根据今天的真实任务轨迹做一次日终复盘。",
            statementContent: "今天已经完成演示准备；置顶任务、主动延期和进行中任务仍保留，明天先确认法务依赖。",
            summary: "今天完成了演示准备，并保留置顶、延期和进行中任务供继续体验。",
            tomorrowNote: "明天先确认法务依赖，再处理发布后的复盘安排。"
        ),
        payload: DemoStoryZhulongPayloadText(
            systemPrompt: "这是晷迹交互式演示中的历史烛龙会话。",
            scopeContent: { "演示范围 \($0) 已授权" }
        )
    )

    /// 英文文案：与中文变体结构、数量完全一致的母语级翻译。
    static let english = DemoStoryZhulongText(
        poolAnalysis: DemoStoryPoolAnalysisText(
            evidenceFallbackReference: "this task",
            findingConclusion: {
                "The completion boundary of \"\($0)\" could be more specific."
            },
            findingUncertainty: "This assessment relies only on the titles, descriptions, notes, and planned subtasks already in the task pool.",
            findingRecommendation: "Add an observable deliverable or completion criterion before deciding whether to schedule it.",
            primaryIntent: "Analyze my current task pool and surface tasks that need clarification or scheduling.",
            systemPrompt: "This is a task pool analysis in the Noonmark interactive demo.",
            responseContent: "I found one task whose completion boundary is worth clarifying first."
        ),
        submittedPlanning: DemoStorySubmittedPlanningText(
            primaryIntent: "Help me plan the release demo and schedule the results across today, the task pool, and future plans.",
            prepareDemoTitle: "Prepare the release demo",
            prepareDemoDescription: "Run a pre-release demo along the real user path.",
            prepareDemoNote: "Verify task states first, then demo Zhulong.",
            subtaskDayTodoStatus: "Check Day Todo status",
            subtaskFutureAndPool: "Check future plans and pool returns",
            subtaskRecordFeedback: "Record demo feedback",
            feedbackTitle: "Organize demo feedback issues",
            feedbackDescription: "Collect the detail issues spotted during the hands-on session.",
            retrospectiveTitle: "Schedule the post-release retrospective",
            retrospectiveDescription: "Hold a focused retrospective two days after the demo.",
            prompt: "Form an editable task plan for the release demo.",
            responseContent: "I've organized this into three tasks with clear destinations; you can keep editing.",
            confirmedScopeSuffix: " (scope confirmed)"
        ),
        activePlanning: DemoStoryActivePlanningText(
            primaryIntent: "I want to learn PostgreSQL indexing in depth — let's plan it together.",
            title: "Understand PostgreSQL indexing strategies",
            taskDescription: "From leftmost prefixes and covering indexes to EXPLAIN/ANALYZE.",
            note: "Validate with a real query once done.",
            subtaskLeftmostPrefix: "Understand the leftmost prefix rule for composite indexes",
            subtaskCovering: "Practice covering indexes and INCLUDE columns",
            subtaskOrdering: "Verify ORDER BY and NULLS ordering",
            subtaskJoins: "Check index usage in joins and subqueries",
            subtaskExplain: "Use EXPLAIN / ANALYZE to spot index misses",
            prompt: "Break the PostgreSQL indexing learning goal into editable tasks.",
            responseContent: "I've broken it into one parent task and five progressive subtasks, all editable before submission."
        ),
        insight: DemoStoryInsightText(
            primaryIntent: "Review the pattern behind my recent task deferrals.",
            prompt: "Summarize the deferral pattern from the trail without creating tasks.",
            responseContent: "Recent deferrals mostly come from unconfirmed dependencies and oversized scopes. Separate the parts waiting on dependencies from those you can move forward independently."
        ),
        dailyReview: DemoStoryDailyReviewText(
            primaryIntent: "Do an end-of-day review based on today's real task trail.",
            statementContent: "Demo prep is done today; the pinned task, the deliberate deferral, and the in-progress task remain — confirm the legal dependency first tomorrow.",
            summary: "Demo prep finished today, with the pinned, deferred, and in-progress tasks kept for further exploration.",
            tomorrowNote: "Tomorrow: confirm the legal dependency first, then handle the post-release retrospective."
        ),
        payload: DemoStoryZhulongPayloadText(
            systemPrompt: "This is a historical Zhulong session in the Noonmark interactive demo.",
            scopeContent: { "Demo scope \($0) authorized" }
        )
    )
}
