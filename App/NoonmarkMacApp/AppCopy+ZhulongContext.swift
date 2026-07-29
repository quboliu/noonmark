import NoonmarkMacRuntime

extension AppCopy {
    // MARK: - Inline task draft

    var zhulongTaskDraftTitle: String {
        language == .chinese ? "任务草稿" : "Task draft"
    }

    var zhulongTaskDraftCommittedStatus: String {
        language == .chinese ? "已提交" : "Committed"
    }

    var zhulongTaskDraftUpdatingStatus: String {
        language == .chinese ? "烛龙正在更新" : "Zhulong is updating"
    }

    var zhulongTaskDraftEditableStatus: String {
        language == .chinese ? "可直接编辑" : "Editable"
    }

    func zhulongTaskDraftTaskCount(_ count: Int) -> String {
        language == .chinese ? "\(count) 个任务" : "\(count) tasks"
    }

    var addZhulongTaskDraftTask: String {
        language == .chinese ? "增加任务" : "Add task"
    }

    var zhulongTaskDraftRevisionHint: String {
        language == .chinese
            ? "继续对话可以调整方案；说“提交”也会执行当前可见版本。"
            : "Keep chatting to revise, or say “commit” to apply this visible version."
    }

    var commitZhulongTaskDraft: String {
        language == .chinese ? "提交任务" : "Commit tasks"
    }

    var zhulongTaskDraftAppliedNotice: String {
        language == .chinese
            ? "这些任务已经写入对应的任务池、Day Todo 或未来计划。"
            : "These tasks were written to their selected destinations."
    }

    var zhulongTaskDraftUpdatingNotice: String {
        language == .chinese
            ? "当前可见版本已保存；烛龙返回修订前暂不可编辑。"
            : "This visible version is saved and locked until Zhulong returns the revision."
    }

    var zhulongTaskTitlePlaceholder: String {
        language == .chinese ? "任务标题" : "Task title"
    }

    var zhulongTaskDescriptionPlaceholder: String {
        language == .chinese
            ? "补充目标或完成标准（可选）"
            : "Goal or completion criteria (optional)"
    }

    var zhulongTaskNotePlaceholder: String {
        language == .chinese ? "附言（可选）" : "Note (optional)"
    }

    var zhulongTaskPoolDestination: String {
        language == .chinese ? "任务池" : "Task Pool"
    }

    var zhulongTaskTodayDestination: String {
        language == .chinese ? "今天" : "Today"
    }

    var zhulongTaskFutureDestination: String {
        language == .chinese ? "未来日期" : "Future"
    }

    var addZhulongSubtask: String {
        language == .chinese ? "增加子任务" : "Add subtask"
    }

    var zhulongSubtaskPlaceholder: String {
        language == .chinese ? "子任务" : "Subtask"
    }

    var zhulongSimpleDifficultyAbbreviation: String {
        language == .chinese ? "简" : "S"
    }

    var zhulongMediumDifficultyAbbreviation: String {
        language == .chinese ? "中" : "M"
    }

    var zhulongHardDifficultyAbbreviation: String {
        language == .chinese ? "难" : "H"
    }

    // MARK: - Context rails

    var unscheduled: String { language == .chinese ? "未排期" : "Unscheduled" }
    var plannedTasks: String { language == .chinese ? "计划任务" : "Planned tasks" }
    var coveredDates: String { language == .chinese ? "覆盖日期" : "Dates covered" }
    var continuedTasks: String { language == .chinese ? "延续任务" : "Continued tasks" }
    var taskChains: String { language == .chinese ? "任务链" : "Task chains" }
    var missedOccurrences: String { language == .chinese ? "未完成次" : "Missed times" }
    var completedTasks: String { language == .chinese ? "完成任务" : "Completed tasks" }
    var poolStatisticsTitle: String {
        language == .chinese ? "任务池统计" : "Task Pool statistics"
    }

    var poolStatisticsSubtitle: String {
        language == .chinese
            ? "当前任务池的本地事实，不依赖 Provider。"
            : "Local facts from the current Task Pool, independent of any Provider."
    }

    var poolTaskTotalMetric: String {
        language == .chinese ? "任务总量" : "Tasks"
    }

    var poolCategoryTotalMetric: String {
        language == .chinese ? "池内分组" : "Groups used"
    }

    var poolLabelTotalMetric: String {
        language == .chinese ? "池内标签" : "Labels used"
    }

    var poolContextualTaskMetric: String {
        language == .chinese ? "有说明" : "With context"
    }

    var poolReturnedTaskMetric: String {
        language == .chinese ? "重新回池" : "Returned"
    }

    var poolAnalysisTitle: String {
        language == .chinese ? "烛龙分析" : "Zhulong analysis"
    }

    var poolAnalysisSubtitle: String {
        language == .chinese
            ? "基于任务内容与已授权轨迹，生成可审查的判断。"
            : "Generate reviewable findings from task content and authorized trails."
    }

    var poolAnalysisIntent: String {
        language == .chinese
            ? "分析当前任务池，指出需要澄清、拆分或安排的任务"
            : "Analyze the current Task Pool for tasks that need clarification, decomposition, or scheduling"
    }

    var analyzeTaskPool: String {
        language == .chinese ? "分析任务池" : "Analyze Task Pool"
    }

    var poolAnalysisGenerating: String {
        language == .chinese ? "正在分析任务池……" : "Analyzing the Task Pool…"
    }

    var poolAnalysisOutdated: String {
        language == .chinese
            ? "任务池已变化，这份分析基于较早内容。"
            : "The Task Pool has changed since this analysis."
    }

    var poolAnalysisNoFindings: String {
        language == .chinese
            ? "当前授权资料不足以形成可靠发现。"
            : "The authorized context does not support a reliable finding yet."
    }

    var poolAnalysisFailed: String {
        language == .chinese
            ? "本次分析没有完成，统计区不受影响。"
            : "This analysis did not finish. Statistics remain available."
    }

    var refreshTaskPoolAnalysis: String {
        language == .chinese ? "重新分析" : "Analyze again"
    }

    var retryTaskPoolAnalysis: String {
        language == .chinese ? "重试分析" : "Retry analysis"
    }

    var viewTaskPoolAnalysisSession: String {
        language == .chinese ? "查看会话" : "View session"
    }

    func poolAnalysisEvidence(_ titles: [String?]) -> String {
        let separator = language == .chinese ? "、" : ", "
        let joined = titles.map {
            $0 ?? untitledTask
        }.joined(separator: separator)
        return language == .chinese
            ? "证据：\(joined)"
            : "Evidence: \(joined)"
    }

    func poolAnalysisConfidence(
        _ confidence: TaskPoolAnalysisConfidence,
        uncertainty: String
    ) -> String {
        let confidenceText = switch (language, confidence) {
        case (.chinese, .low): "低"
        case (.chinese, .medium): "中"
        case (.chinese, .high): "高"
        case (.english, .low): "Low"
        case (.english, .medium): "Medium"
        case (.english, .high): "High"
        }
        return language == .chinese
            ? "置信度：\(confidenceText) · 不确定性：\(uncertainty)"
            : "Confidence: \(confidenceText) · Uncertainty: \(uncertainty)"
    }

    var futureReschedulingTitle: String { language == .chinese ? "未来改期" : "Upcoming rescheduling" }
    var futureReschedulingSubtitle: String {
        language == .chinese
            ? "未来计划的密度、延续链和改期判断统一留在烛龙，不再占一个常驻说明栏。"
            : "Let Zhulong review future load, continuations, and rescheduling without a permanent explanatory panel."
    }

    var futureReschedulingIntent: String {
        language == .chinese ? "检查未来安排并调整承诺" : "Review upcoming plans and adjust commitments"
    }

    var unfinishedHandlingTitle: String { language == .chinese ? "未完成处理" : "Handle unfinished work" }
    var unfinishedHandlingSubtitle: String {
        language == .chinese
            ? "是否该延续、拆小还是废弃，统一交给烛龙草稿，不再在这里做静态推断。"
            : "Use a Zhulong draft to decide whether to continue, narrow, or drop work instead of showing static guesses here."
    }

    var unfinishedHandlingIntent: String {
        language == .chinese ? "梳理未完成任务的下一步" : "Plan the next step for unfinished work"
    }

    var completionReviewTitle: String { language == .chinese ? "完成复看" : "Completion review" }
    var completionReviewSubtitle: String {
        language == .chinese
            ? "完成记录只作为证据输入烛龙，不再在这里堆本地解释文案。"
            : "Use completion records as evidence for Zhulong instead of stacking local explanations here."
    }

    var completionReviewIntent: String {
        language == .chinese ? "复看完成轨迹并提取可复用证据" : "Review completed trails and extract reusable evidence"
    }

    var providerEnabled: String { language == .chinese ? "Provider 已启用" : "Provider enabled" }
    var localMode: String { language == .chinese ? "本地模式" : "Local mode" }
    var handToZhulong: String { language == .chinese ? "交给烛龙" : "Ask Zhulong" }
    var continueRecentSession: String { language == .chinese ? "继续最近会话" : "Continue recent session" }
    var zhulongContextEntrySubtitle: String {
        language == .chinese
            ? "建立加密会话，先确认本次范围；没有 Provider 时仍可使用本地证据。"
            : "Start an encrypted session and confirm its scope first. Local evidence remains available without a Provider."
    }

    var futureAnalysisTitle: String { language == .chinese ? "未来计划分析" : "Upcoming plan analysis" }
    var futureAnalysisSubtitle: String {
        language == .chinese ? "按日期观察未来任务负载与延续压力。" : "Review upcoming load and continuation pressure by date."
    }

    func recentPlanSignal(date: String?, title: String?) -> String {
        guard let date, let title else {
            return language == .chinese ? "未来计划为空。" : "Upcoming plans are empty."
        }
        return language == .chinese
            ? "最近计划：\(date) · \(title)"
            : "Nearest plan: \(date) · \(title)"
    }

    func futureDensitySignal(isDense: Bool) -> String {
        switch (language, isDense) {
        case (.chinese, true): "存在单日计划较密集，可能需要提前拆分。"
        case (.chinese, false): "单日计划密度目前可控。"
        case (.english, true): "One day is densely planned and may need to be split early."
        case (.english, false): "Daily plan density is currently manageable."
        }
    }

    func futurePrimaryRecommendation(isEmpty: Bool) -> String {
        switch (language, isEmpty) {
        case (.chinese, true): "无需维护未来计划；保持 Day Todo 清晰即可。"
        case (.chinese, false): "优先检查最近日期，避免未来任务堆到同一天。"
        case (.english, true): "There are no upcoming plans to maintain; keep today's list clear."
        case (.english, false): "Review the nearest dates first so upcoming work does not pile onto one day."
        }
    }

    func futureContinuationRecommendation(hasContinuations: Bool) -> String {
        switch (language, hasContinuations) {
        case (.chinese, true): "延续任务已进入未来计划，建议在目标日前确认范围是否仍有效。"
        case (.chinese, false): "暂无延续压力，可以按优先级安排新任务。"
        case (.english, true): "Continued tasks are in the upcoming plan; confirm their scope before the target date."
        case (.english, false): "There is no continuation pressure; order new tasks by priority."
        }
    }

    var futureZhulongNote: String {
        language == .chinese
            ? "开启烛龙后，可结合历史完成节奏给出更精细的改期建议。"
            : "Enable Zhulong for more precise rescheduling suggestions based on past completion rhythm."
    }

    var unfinishedRiskTitle: String { language == .chinese ? "未完成风险" : "Unfinished risk" }
    var unfinishedRiskSubtitle: String {
        language == .chinese ? "按任务链汇总历史未完成与当前延续状态。" : "Summarize missed history and current continuations by task chain."
    }

    func repeatedUnfinishedSignal(_ count: Int) -> String {
        guard count > 0 else {
            return language == .chinese ? "没有重复未完成链。" : "No task chains were repeatedly unfinished."
        }
        return language == .chinese
            ? "\(count) 条任务链重复未完成，存在范围或优先级问题。"
            : "\(count) task chain\(count == 1 ? "" : "s") repeatedly missed, suggesting a scope or priority issue."
    }

    func activeContinuationSignal(_ count: Int) -> String {
        guard count > 0 else {
            return language == .chinese
                ? "暂无已延续到当前或未来的未完成链。"
                : "No unfinished chains have been continued to the present or future."
        }
        return language == .chinese
            ? "\(count) 条任务链已有当前待完成轨迹，避免重复延续。"
            : "\(count) task chain\(count == 1 ? " already has" : "s already have") a current pending trail; avoid continuing it again."
    }

    func unfinishedPrimaryRecommendation(isEmpty: Bool) -> String {
        switch (language, isEmpty) {
        case (.chinese, true): "未完成池为空，保持每日收尾即可。"
        case (.chinese, false): "优先处理最近未完成且尚未延续的任务链。"
        case (.english, true): "The unfinished pool is empty; keep closing each day."
        case (.english, false): "Handle the most recent unfinished chain that has not been continued."
        }
    }

    func repeatedUnfinishedRecommendation(hasRepeated: Bool) -> String {
        switch (language, hasRepeated) {
        case (.chinese, true): "重复未完成任务应先缩小目标，必要时废弃不再有效的链。"
        case (.chinese, false): "对单次未完成任务，直接延续或明确废弃。"
        case (.english, true): "Narrow repeatedly missed tasks first, and drop chains that no longer apply."
        case (.english, false): "Continue a one-time miss or explicitly drop it."
        }
    }

    var unfinishedZhulongNote: String {
        language == .chinese
            ? "开启烛龙后，可让模型结合复盘文本判断未完成原因。"
            : "Enable Zhulong to relate review text to the reasons work remained unfinished."
    }

    var completionTrailTitle: String { language == .chinese ? "完成轨迹" : "Completion trails" }
    var completionTrailSubtitle: String {
        language == .chinese ? "汇总完成记录、子任务完成和跨日轨迹。" : "Summarize completed tasks, subtasks, and cross-day trails."
    }

    func recentCompletionSignal(date: String?, title: String?) -> String {
        guard let date, let title else {
            return language == .chinese ? "暂无完成记录。" : "No completion records yet."
        }
        return language == .chinese
            ? "最近完成：\(date) · \(title)"
            : "Most recent completion: \(date) · \(title)"
    }

    func continuedCompletionSignal(_ count: Int) -> String {
        guard count > 0 else {
            return language == .chinese ? "完成记录多为当日闭环。" : "Most completed tasks closed on the same day."
        }
        return language == .chinese
            ? "\(count) 条完成记录经历过延续。"
            : "\(count) completion record\(count == 1 ? " involved" : "s involved") continuations."
    }

    func completionPrimaryRecommendation(isEmpty: Bool) -> String {
        switch (language, isEmpty) {
        case (.chinese, true): "暂无完成数据；先从 Day Todo 完成一项任务。"
        case (.chinese, false): "复盘最近完成记录，提取可复制的推进方式。"
        case (.english, true): "There is no completion data yet; finish one task in Day Todo."
        case (.english, false): "Review the latest completion and extract a repeatable way to make progress."
        }
    }

    func completedSubtaskRecommendation(hasSubtasks: Bool) -> String {
        switch (language, hasSubtasks) {
        case (.chinese, true): "子任务完成已单独记录，可用来判断复杂任务的真实推进。"
        case (.chinese, false): "复杂任务可拆子任务，让完成记录更细。"
        case (.english, true): "Subtask completions are recorded separately and show real progress on complex work."
        case (.english, false): "Split complex tasks into subtasks for more precise completion records."
        }
    }

    var completionZhulongNote: String {
        language == .chinese
            ? "开启烛龙后，可从完成轨迹中总结节奏和可复用模式。"
            : "Enable Zhulong to summarize rhythm and reusable patterns from completion trails."
    }

    // MARK: - Provider waiting

    var zhulongProviderWaitingHint: String {
        language == .chinese ? "烛龙正在回复" : "Zhulong is replying"
    }
}
