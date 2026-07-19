import NoonmarkMacRuntime

extension AppCopy {
    var invalidDateSelection: String {
        language == .chinese
            ? "无法读取所选日期，请重新选择。"
            : "The selected date could not be read. Choose another date."
    }

    var movePriorityUp: String {
        language == .chinese ? "提高优先级" : "Move up"
    }

    var movePriorityDown: String {
        language == .chinese ? "降低优先级" : "Move down"
    }

    var adjustDayPriority: String {
        language == .chinese ? "调整当日优先级" : "Adjust today's priority"
    }

    var searchPlaceholder: String {
        language == .chinese
            ? "搜索任务、子任务、说明与附言"
            : "Search tasks, subtasks, descriptions, and notes"
    }

    var searchEmptyPrompt: String {
        language == .chinese
            ? "输入关键词以搜索全部晷迹"
            : "Enter a keyword to search all of Noonmark"
    }

    var searchNoResults: String {
        language == .chinese ? "没有匹配结果" : "No matches"
    }

    var searchNoResultsHint: String {
        language == .chinese ? "请尝试其他关键词。" : "Try a different keyword."
    }

    var searchTaskKind: String {
        language == .chinese ? "任务" : "Task"
    }

    var searchPoolTaskKind: String {
        language == .chinese ? "任务池" : "Task Pool"
    }

    var searchSubtaskKind: String {
        language == .chinese ? "子任务" : "Subtask"
    }

    func completedAccessibility(completed: Int, total: Int) -> String {
        switch language {
        case .chinese:
            "已完成 \(completed) 项，共 \(total) 项"
        case .english:
            "\(completed) of \(total) completed"
        }
    }

    var quickEntryTitle: String {
        language == .chinese ? "快速记录" : "Quick Entry"
    }

    var quickEntryPlaceholder: String {
        language == .chinese
            ? "输入今天要完成的任务，可附加 #标签"
            : "Add a task for today; #labels are supported"
    }

    var quickEntryTodayHint: String {
        language == .chinese
            ? "任务会加入今天的 Day Todo；当前浏览日期不会改变。"
            : "The task goes to today's Day Todo without changing the date you are viewing."
    }

    var addTask: String {
        language == .chinese ? "添加任务" : "Add Task"
    }

    var dismiss: String {
        language == .chinese ? "关闭" : "Dismiss"
    }

    var openSubtasksPreventCompletion: String {
        language == .chinese
            ? "仍有未完成子任务；请先完成所有子任务。"
            : "Open subtasks remain. Complete them before completing the parent task."
    }

    func selectedTaskCount(_ count: Int) -> String {
        switch language {
        case .chinese:
            "已选择 \(count) 项"
        case .english:
            count == 1 ? "1 item selected" : "\(count) items selected"
        }
    }

    var selectAllTasks: String {
        language == .chinese ? "全选任务" : "Select All Tasks"
    }

    var clearTaskSelection: String {
        language == .chinese ? "取消选择" : "Clear Selection"
    }

    var completeSelectedTasks: String {
        language == .chinese ? "完成所选" : "Complete Selected"
    }

    var scheduleSelectedToday: String {
        language == .chinese ? "排期到今天" : "Schedule for Today"
    }

    var returnSelectedToPool: String {
        language == .chinese ? "所选任务回池" : "Return Selected to Pool"
    }

    func completedSelectedTasksToast(_ count: Int) -> String {
        language == .chinese
            ? "已完成 \(count) 项任务"
            : "Completed \(count) task\(count == 1 ? "" : "s")"
    }

    func scheduledSelectedTasksToast(_ count: Int) -> String {
        language == .chinese
            ? "已将 \(count) 项任务排期到今天"
            : "Scheduled \(count) task\(count == 1 ? "" : "s") for today"
    }

    func returnedSelectedTasksToast(_ count: Int) -> String {
        language == .chinese
            ? "已将 \(count) 项任务移回任务池"
            : "Returned \(count) task\(count == 1 ? "" : "s") to the pool"
    }

    var jumpToDateTitle: String {
        language == .chinese ? "跳转到日期" : "Go to Date"
    }

    var scheduleDateTitle: String {
        language == .chinese ? "排期到哪一天？" : "When should this be scheduled?"
    }

    var continueDateTitle: String {
        language == .chinese ? "延续到哪一天？" : "When should this continue?"
    }

    var rescheduleDateTitle: String {
        language == .chinese ? "改到哪个未来日期？" : "Choose a new future date"
    }

    var anyDateHint: String {
        language == .chinese
            ? "可选择任意有效日期。"
            : "Choose any valid date."
    }

    var todayOrFutureDateHint: String {
        language == .chinese
            ? "可选择今天或任意未来日期。"
            : "Choose today or any future date."
    }

    var futureDateHint: String {
        language == .chinese
            ? "请选择今天之后的任意未来日期。"
            : "Choose any date after today."
    }

    // MARK: - Workspace content

    var dayBadgeToday: String { language == .chinese ? "今日" : "Today" }
    var dayBadgeLocked: String { language == .chinese ? "历史已锁定" : "History locked" }
    var dayBadgeFuture: String { language == .chinese ? "未来" : "Future" }
    var previousDay: String { language == .chinese ? "前一天" : "Previous day" }
    var nextDay: String { language == .chinese ? "后一天" : "Next day" }
    var previousMonth: String { language == .chinese ? "上个月" : "Previous month" }
    var nextMonth: String { language == .chinese ? "下个月" : "Next month" }
    var dayQuickAddTodayPlaceholder: String {
        language == .chinese ? "添加今日任务，回车确认" : "Add a task for today; press Return"
    }

    var dayQuickAddFuturePlaceholder: String {
        language == .chinese ? "为这一天排期任务，回车确认" : "Schedule a task for this day; press Return"
    }

    var poolQuickAddPlaceholder: String {
        language == .chinese ? "新建任务到任务池，回车确认" : "Add a task to the pool; press Return"
    }

    // MARK: - Calendar

    var dayAnalysis: String { language == .chinese ? "当天分析" : "Day analysis" }
    var continuation: String { language == .chinese ? "延续" : "Continuations" }
    var change: String { language == .chinese ? "变更" : "Changes" }
    var risk: String { language == .chinese ? "风险" : "Risk" }
    var openDayTodo: String {
        language == .chinese ? "在 Day Todo 打开这一天 →" : "Open this day in Day Todo →"
    }

    func completionRate(_ percent: Int) -> String {
        language == .chinese ? "\(percent)% 完成" : "\(percent)% complete"
    }

    func calendarScopeLabel(isToday: Bool, isHistory: Bool) -> String {
        if isToday { return language == .chinese ? "今天" : "Today" }
        if isHistory { return language == .chinese ? "历史" : "History" }
        return language == .chinese ? "未来" : "Future"
    }

    func calendarContinuationSummary(_ count: Int) -> String {
        guard count > 0 else {
            return language == .chinese
                ? "当天没有延续链条。"
                : "No task chains were continued that day."
        }
        return language == .chinese
            ? "\(count) 项涉及延续，需要关注持续天数和目标是否仍有效。"
            : "\(count) task\(count == 1 ? "" : "s") involved continuations; review their duration and whether the goal still applies."
    }

    func calendarChangeSummary(_ count: Int) -> String {
        guard count > 0 else {
            return language == .chinese
                ? "当天没有任务变更记录。"
                : "No task changes were recorded that day."
        }
        return language == .chinese
            ? "\(count) 项发生变更，原任务和目标任务都保留轨迹。"
            : "\(count) task\(count == 1 ? "" : "s") changed; both the original and replacement trails remain."
    }

    func calendarRiskSummary(
        position: CalendarDayPosition,
        unresolved: Int,
        pending: Int,
        total: Int
    ) -> String {
        AppPresentation(language: language).calendarInsight.riskSummary(
            position: position,
            unresolved: unresolved,
            pending: pending,
            total: total
        )
    }
}
