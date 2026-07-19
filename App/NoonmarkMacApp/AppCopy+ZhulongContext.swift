extension AppCopy {
    // MARK: - Context rails

    var unscheduled: String { language == .chinese ? "未排期" : "Unscheduled" }
    var hasDescription: String { language == .chinese ? "有说明" : "With details" }
    var plannedTasks: String { language == .chinese ? "计划任务" : "Planned tasks" }
    var coveredDates: String { language == .chinese ? "覆盖日期" : "Dates covered" }
    var continuedTasks: String { language == .chinese ? "延续任务" : "Continued tasks" }
    var taskChains: String { language == .chinese ? "任务链" : "Task chains" }
    var missedOccurrences: String { language == .chinese ? "未完成次" : "Missed times" }
    var completedTasks: String { language == .chinese ? "完成任务" : "Completed tasks" }
    var poolSchedulingTitle: String { language == .chinese ? "任务池排期" : "Task Pool scheduling" }
    var poolSchedulingSubtitle: String {
        language == .chinese
            ? "先用本地统计检查任务池完整度与组织状态，再决定下一步排期。"
            : "Use local signals to review Task Pool readiness and organization before scheduling."
    }

    var poolSchedulingIntent: String {
        language == .chinese ? "给任务池重新排期" : "Reschedule the Task Pool"
    }

    func poolOldestSignal(_ date: String?) -> String {
        guard let date else {
            return language == .chinese ? "任务池目前为空。" : "The Task Pool is currently empty."
        }
        return language == .chinese
            ? "最早进入任务池：\(date)。"
            : "Oldest Task Pool entry: \(date)."
    }

    func poolOrganizationSignal(unclassifiedCount: Int) -> String {
        guard unclassifiedCount > 0 else {
            return language == .chinese
                ? "所有任务都已有主要分组。"
                : "Every task has a primary group."
        }
        return language == .chinese
            ? "\(unclassifiedCount) 项任务尚未分组。"
            : "\(unclassifiedCount) task\(unclassifiedCount == 1 ? " is" : "s are") not grouped."
    }

    func poolDetailsRecommendation(needsDetailCount: Int) -> String {
        guard needsDetailCount > 0 else {
            return language == .chinese
                ? "现有任务已具备说明、附言或子任务，可直接评估排期。"
                : "Existing tasks have enough detail, notes, or subtasks to assess for scheduling."
        }
        return language == .chinese
            ? "先为 \(needsDetailCount) 项缺少上下文的任务补充目标或范围。"
            : "Add a goal or scope to \(needsDetailCount) task\(needsDetailCount == 1 ? "" : "s") that lack context."
    }

    func poolPlanningRecommendation(plannedCount: Int, totalCount: Int) -> String {
        guard totalCount > 0 else {
            return language == .chinese
                ? "有新承诺时先加入任务池，再选择合适日期。"
                : "Add new commitments to the Task Pool before choosing a date."
        }
        guard plannedCount > 0 else {
            return language == .chinese
                ? "复杂任务可先拆成可验证子任务，再进入 Day Todo。"
                : "Split complex work into verifiable subtasks before moving it into Day Todo."
        }
        return language == .chinese
            ? "\(plannedCount) 项任务已有子任务计划，优先检查最早进入池中的项目。"
            : "\(plannedCount) task\(plannedCount == 1 ? " has" : "s have") a subtask plan; review the oldest entries first."
    }

    var poolZhulongNote: String {
        language == .chinese
            ? "开启烛龙后，可结合历史节奏生成范围明确的排期草稿。"
            : "Enable Zhulong to draft a scoped schedule using past working rhythm."
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
}
