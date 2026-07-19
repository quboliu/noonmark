import Foundation
import NoonmarkCore

private struct LocalizedAppCopy {
    let chinese: String
    let english: String

    func resolved(for language: AppLanguage) -> String {
        switch language {
        case .chinese:
            chinese
        case .english:
            english
        }
    }
}

extension AppCopy {
    private static let traceStatusCopyByStatus: [TraceStatus: LocalizedAppCopy] = [
        .pending: .init(chinese: "待完成", english: "Pending"),
        .completed: .init(chinese: "已完成", english: "Completed"),
        .unfinished: .init(chinese: "未完成", english: "Unfinished"),
        .continued: .init(chinese: "已延续", english: "Continued"),
        .changed: .init(chinese: "已变更", english: "Changed"),
        .returnedToPool: .init(chinese: "已回池", english: "Returned to pool"),
        .abandoned: .init(chinese: "已废弃", english: "Dropped")
    ]

    private static let detailRailHintCopyByPage: [String: LocalizedAppCopy] = [
        NoonmarkStore.Page.pool.rawValue: .init(
            chinese: "选中任务查看详情与排期操作。",
            english: "Select a task to view details and scheduling actions."
        ),
        NoonmarkStore.Page.future.rawValue: .init(
            chinese: "选中计划查看详情，可改期或回池。",
            english: "Select a plan to view details, reschedule it, or return it to the pool."
        ),
        NoonmarkStore.Page.unfinished.rawValue: .init(
            chinese: "选中任务链查看未完成明细。",
            english: "Select a task chain to inspect its unfinished trails."
        ),
        NoonmarkStore.Page.completed.rawValue: .init(
            chinese: "选中记录可跳转当天或复制为新任务。",
            english: "Select a record to open its day or copy it as a new task."
        ),
        NoonmarkStore.Page.zhulong.rawValue: .init(
            chinese: "选择或继续烛龙会话后，在这里查看授权范围、证据和待确认 Todo diff。",
            english: "Select or continue a Zhulong session to inspect scope, evidence, and pending Todo diffs."
        )
    ]

    // MARK: - Task details

    var untitledTask: String { language == .chinese ? "未命名任务" : "Untitled task" }
    var ungrouped: String { language == .chinese ? "未分组" : "Ungrouped" }
    var changedToPrefix: String { language == .chinese ? "被变更为：" : "Changed to:" }
    var returnedToPoolOnDay: String { language == .chinese ? "当天已回池" : "Returned to pool that day" }
    var viewDetails: String { language == .chinese ? "查看详情" : "View details" }
    var abandoned: String { language == .chinese ? "已废弃" : "Dropped" }
    var detailExpanded: String { language == .chinese ? "▾ 明细" : "▾ Details" }
    var detailCollapsed: String { language == .chinese ? "▸ 明细" : "▸ Details" }
    var subtask: String { language == .chinese ? "子任务" : "Subtask" }
    var belongsToTaskPrefix: String { language == .chinese ? "属于" : "Part of" }
    var currentLocation: String { language == .chinese ? "当前所在" : "Current" }
    var firstEntry: String { language == .chinese ? "首次进入" : "First entry" }
    var taskTitlePlaceholder: String { language == .chinese ? "任务标题" : "Task title" }
    var taskDescriptionPlaceholder: String {
        language == .chinese
            ? "补充这个任务的背景、目标或范围…"
            : "Add background, goals, or scope for this task…"
    }

    var planDescriptionPlaceholder: String {
        language == .chinese
            ? "补充这个计划的背景、目标或范围…"
            : "Add background, goals, or scope for this plan…"
    }

    var missingTaskDescription: String { language == .chinese ? "未填写描述" : "No description" }
    var taskDetailsTitle: String { language == .chinese ? "任务详情" : "Task Details" }
    var taskTrailTitle: String { language == .chinese ? "任务轨迹" : "Task Trail" }
    var subtasksTitle: String { language == .chinese ? "子任务" : "Subtasks" }
    var noSubtasks: String { language == .chinese ? "暂无子任务" : "No subtasks" }
    var addSubtaskPlaceholder: String {
        language == .chinese ? "添加子任务，回车确认" : "Add a subtask; press Return"
    }

    var classificationAndLabelsTitle: String {
        language == .chinese ? "分组与标签" : "Group & Tags"
    }

    var statusTitle: String { language == .chinese ? "状态" : "Status" }
    var completionProgressTitle: String { language == .chinese ? "完成进度" : "Progress" }
    var weightedProgressAccessibilityLabel: String {
        language == .chinese ? "按子任务自动计算的完成进度" : "Progress calculated from subtasks"
    }

    var manualProgressAccessibilityLabel: String {
        language == .chinese ? "手动完成进度" : "Manual progress"
    }

    var historicalReadOnlyNotice: String {
        language == .chinese
            ? "历史只读：任务事实不可改写。"
            : "History is read-only; task facts cannot be changed."
    }

    func progressFloorNotice(_ percent: Int) -> String {
        language == .chinese
            ? "下限 (percent)% · 延续后的进度不能回退"
            : "Minimum (percent)% · progress cannot move backward after continuation"
    }

    func taskAccessibilityLabel(_ title: String) -> String {
        language == .chinese ? "任务「\(title)」" : "Task “\(title)”"
    }

    func subtaskCount(_ count: Int) -> String {
        switch language {
        case .chinese: "\(count) 子任务"
        case .english: count == 1 ? "1 subtask" : "\(count) subtasks"
        }
    }

    func taskCount(_ count: Int) -> String {
        switch language {
        case .chinese: "\(count) 项任务"
        case .english: count == 1 ? "1 task" : "\(count) tasks"
        }
    }

    func dayCount(_ count: Int) -> String {
        switch language {
        case .chinese: "\(count) 天"
        case .english: count == 1 ? "1 day" : "\(count) days"
        }
    }

    func occurrenceCount(_ count: Int) -> String {
        switch language {
        case .chinese: "\(count) 次"
        case .english: count == 1 ? "1 time" : "\(count) times"
        }
    }

    func continuationOrdinal(_ sequence: Int) -> String {
        language == .chinese
            ? "第 \(sequence) 次延续"
            : "Continuation \(sequence)"
    }

    func continuationDuration(sequence: Int, days: Int) -> String {
        switch language {
        case .chinese:
            "第 \(sequence) 次延续 · 持续 \(days) 天"
        case .english:
            "Continuation \(sequence) · \(days) day\(days == 1 ? "" : "s")"
        }
    }

    func duration(_ days: Int) -> String {
        switch language {
        case .chinese: "持续 \(days) 天"
        case .english: "\(days) day\(days == 1 ? "" : "s")"
        }
    }

    func durationWithContinuations(days: Int, count: Int) -> String {
        switch language {
        case .chinese: "持续 \(days) 天 · 延续 \(count) 次"
        case .english:
            "\(days) day\(days == 1 ? "" : "s") · \(count) continuation\(count == 1 ? "" : "s")"
        }
    }

    func dateCellAccessibilityLabel(
        date: String,
        weekday: String,
        taskCount: Int,
        isToday: Bool,
        isSelected: Bool
    ) -> String {
        let state: [String] = switch language {
        case .chinese:
            [isToday ? "今天" : nil, isSelected ? "已选择" : nil].compactMap { $0 }
        case .english:
            [isToday ? "Today" : nil, isSelected ? "Selected" : nil].compactMap { $0 }
        }
        let tasks = switch language {
        case .chinese: "\(taskCount) 项任务"
        case .english: taskCount == 1 ? "1 task" : "\(taskCount) tasks"
        }
        return ([date, weekday, tasks] + state).joined(separator: ", ")
    }

    func continuedToCurrent(_ dateLabel: String) -> String {
        language == .chinese
            ? "已延续到 \(dateLabel)，当前待完成 跳转 →"
            : "Continued to \(dateLabel); open current task →"
    }

    func continuedToLink(_ dateLabel: String) -> String {
        language == .chinese ? "已延续到 \(dateLabel) →" : "Continued to \(dateLabel) →"
    }

    func belongsToTask(_ title: String) -> String {
        language == .chinese ? "属于「\(title)」" : "Part of “\(title)”"
    }

    func traceStatusLabel(_ status: TraceStatus) -> String {
        guard status.isUserPresentable else {
            preconditionFailure("Internal trace status cannot be presented")
        }
        guard let copy = Self.traceStatusCopyByStatus[status] else {
            preconditionFailure("Missing trace status copy for \(status)")
        }
        return copy.resolved(for: language)
    }

    func traceEndLabel(_ status: TraceStatus) -> String {
        guard status.isUserPresentable else {
            preconditionFailure("Internal trace status cannot be presented")
        }
        return switch (language, status) {
        case (.chinese, .completed): "完成"
        case (.chinese, .abandoned): "已废弃"
        case (.chinese, .returnedToPool): "已回池"
        case (.chinese, _): "进行中"
        case (.english, .completed): "Completed"
        case (.english, .abandoned): "Dropped"
        case (.english, .returnedToPool): "Returned to pool"
        case (.english, _): "In progress"
        }
    }

    func subtaskDifficulty(_ difficulty: SubtaskDifficulty, compact: Bool = false) -> String {
        switch (language, difficulty, compact) {
        case (.chinese, .simple, true): "简"
        case (.chinese, .medium, true): "中"
        case (.chinese, .hard, true): "难"
        case (.chinese, .simple, false): "简单"
        case (.chinese, .medium, false): "中等"
        case (.chinese, .hard, false): "困难"
        case (.english, .simple, _): "Easy"
        case (.english, .medium, _): "Medium"
        case (.english, .hard, _): "Hard"
        }
    }

    func subtaskDifficultyHelp(canMutate: Bool) -> String {
        switch (language, canMutate) {
        case (.chinese, true): "修改子任务难度"
        case (.chinese, false): "当前子任务不可改写"
        case (.english, true): "Change subtask difficulty"
        case (.english, false): "This subtask cannot be changed"
        }
    }

    // MARK: - Detail context

    var groupsSection: String { language == .chinese ? "分组" : "Groups" }
    func leadingRecordsSection(_ count: Int) -> String {
        language == .chinese ? "前 \(count) 条" : "First \(count)"
    }

    var poolEmptyNow: String { language == .chinese ? "现在是空的。" : "It is empty now." }
    func oldestPoolEntry(_ date: String) -> String {
        language == .chinese ? "最早入池 \(date)" : "Oldest entry \(date)"
    }

    var plannedSubtasksMetric: String { language == .chinese ? "已拆分" : "With subtasks" }
    var needsDetailsMetric: String { language == .chinese ? "待补充" : "Needs details" }
    var missingDescription: String { language == .chinese ? "缺说明" : "No details" }
    func enteredPool(_ date: String) -> String {
        language == .chinese ? "\(date) 入池" : "Added \(date)"
    }

    var localSignals: String { language == .chinese ? "本地信号" : "Local signals" }
    var algorithmSuggestions: String { language == .chinese ? "算法建议" : "Suggestions" }

    func poolCreatedAtLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .chinese ? "zh_Hans_SG" : "en_SG")
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }

    func noteTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .chinese ? "zh_Hans_SG" : "en_SG")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: - Detail rail and review

    var completedSubtaskRecordTitle: String {
        language == .chinese ? "子任务完成记录" : "Subtask Completion"
    }

    var notRecorded: String { language == .chinese ? "未记录" : "Not recorded" }
    var parentTaskTitle: String { language == .chinese ? "父任务" : "Parent task" }
    var difficultyTitle: String { language == .chinese ? "难度" : "Difficulty" }
    var completedTitle: String { language == .chinese ? "完成" : "Completed" }
    var timeTitle: String { language == .chinese ? "时间" : "Time" }
    var subtaskCompletionNotice: String {
        language == .chinese
            ? "子任务完成事实独立展示，父任务轨迹仍保留在当天。"
            : "The subtask completion is recorded separately; the parent trail remains on that day."
    }

    var completionNodeTitle: String { language == .chinese ? "完成节点" : "Completion" }
    var poolNoDayTodoNotice: String {
        language == .chinese
            ? "尚未进入任何 Day Todo。排期后会生成对应日期的日轨迹。"
            : "This task has not entered a Day Todo. Scheduling it creates a trail on that date."
    }

    var planDetailsTitle: String { language == .chinese ? "计划详情" : "Plan Details" }
    var planDraft: String { language == .chinese ? "计划草稿" : "Plan draft" }
    var dateTitle: String { language == .chinese ? "日期" : "Date" }
    var priorityTitle: String { language == .chinese ? "优先级" : "Priority" }
    var notDue: String { language == .chinese ? "未到期" : "Not due" }
    var futurePlanNotice: String {
        language == .chinese
            ? "未来计划可改期、调整优先级或回池；到达当天前不能标记完成。"
            : "Upcoming plans can be rescheduled, reordered, or returned to the pool; they cannot be completed early."
    }

    var abandonedChainHistoryNotice: String {
        language == .chinese
            ? "任务链已废弃；历史事实保留，可重新启用并回到未完成状态。"
            : "The task chain was dropped. Its history remains, and it can be reactivated as unfinished."
    }

    var historicalFactsReadOnlyNotice: String {
        language == .chinese
            ? "历史事实只读，不可删除或改写。"
            : "Historical facts are read-only and cannot be deleted or changed."
    }

    var noUnfinishedDetail: String {
        language == .chinese ? "没有需要处理的未完成轨迹。" : "No unfinished trails need attention."
    }

    var dailyReviewTitle: String { language == .chinese ? "每日复盘" : "Daily Review" }
    var historicalReviewHint: String {
        language == .chinese ? "历史日复盘可随时补写" : "Past-day reviews can be completed at any time"
    }

    var futureReviewHint: String {
        language == .chinese
            ? "未来日还没有复盘。到了这一天，复盘会在这里生成。"
            : "Upcoming days do not have reviews yet. One will appear here when the day arrives."
    }

    var todaySummaryTitle: String { language == .chinese ? "今日总结" : "Day summary" }
    var todaySummaryPlaceholder: String {
        language == .chinese ? "今天整体推进如何？" : "How did the day progress overall?"
    }

    var unfinishedReasonTitle: String { language == .chinese ? "未完成原因" : "Why work remained unfinished" }
    var unfinishedReasonPlaceholder: String {
        language == .chinese
            ? "哪些没完成，真实原因是什么？"
            : "What remained unfinished, and what was the real reason?"
    }

    var tomorrowNotesTitle: String { language == .chinese ? "明日注意事项" : "For tomorrow" }
    var tomorrowNotesPlaceholder: String {
        language == .chinese
            ? "明天开始前想提醒自己什么？"
            : "What should you remember before tomorrow begins?"
    }

    var totalTasksTitle: String { language == .chinese ? "总任务" : "Total tasks" }
    var scheduleFromPoolSheetTitle: String {
        language == .chinese ? "从任务池排期到这一天" : "Schedule from the Task Pool"
    }

    var cannotSchedulePoolToPastNotice: String {
        language == .chinese
            ? "任务池不能排期到过去日期。请先切到今天或未来日期。"
            : "Task Pool items cannot be scheduled in the past. Choose today or a future date."
    }

    var schedule: String { language == .chinese ? "排期" : "Schedule" }
    var changeTaskSheetTitle: String { language == .chinese ? "变更为新任务" : "Change to New Task" }
    var changeTaskSheetNotice: String {
        language == .chinese
            ? "旧任务会保留在当天并标注已变更，新任务开启新的任务链。"
            : "The original stays on that day as changed; the new task starts a separate chain."
    }

    var newTaskTitlePlaceholder: String { language == .chinese ? "新的任务标题" : "New task title" }
    var confirmChange: String { language == .chinese ? "确认变更" : "Confirm Change" }
    var historicalClassificationNotice: String {
        language == .chinese
            ? "显示这条任务轨迹形成时的分组与标签；历史事实不可改写。"
            : "Shows the group and tags captured with this trail; historical facts cannot be changed."
    }

    var noHistoricalClassification: String {
        language == .chinese
            ? "这条任务轨迹形成时未设置分组或标签。"
            : "No group or tags were set when this trail was created."
    }

    func detailRailHint(for page: NoonmarkStore.Page) -> String {
        Self.detailRailHintCopyByPage[page.rawValue]?.resolved(for: language) ?? ""
    }
}
