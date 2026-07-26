import NoonmarkCore

private let chineseTaskCycleStateNames: [TaskCycleTrackDayState: String] = [
    .notScheduled: "非计划日",
    .pendingPast: "待结算",
    .pendingToday: "今天待完成",
    .planned: "未来计划",
    .completed: "已完成",
    .unfinished: "未完成",
    .deferred: "已延期",
    .changed: "已变更",
    .returnedToPool: "已回池",
    .skipped: "已跳过",
    .abandoned: "已废弃"
]

private let englishTaskCycleStateNames: [TaskCycleTrackDayState: String] = [
    .notScheduled: "Not scheduled",
    .pendingPast: "Awaiting settlement",
    .pendingToday: "Pending today",
    .planned: "Planned",
    .completed: "Completed",
    .unfinished: "Unfinished",
    .deferred: "Deferred",
    .changed: "Changed",
    .returnedToPool: "Returned to pool",
    .skipped: "Skipped",
    .abandoned: "Abandoned"
]

extension AppCopy {
    var recurringTasks: String {
        language == .chinese ? "重复任务" : "Recurring tasks"
    }

    var newRecurringTask: String {
        language == .chinese ? "新建重复任务…" : "New Recurring Task…"
    }

    var convertToRecurringTask: String {
        language == .chinese
            ? "转为重复任务…"
            : "Convert to Recurring Task…"
    }

    var recurringSlashCommand: String {
        language == .chinese ? "/重复" : "/repeat"
    }

    var recurringSlashCommandDescription: String {
        language == .chinese
            ? "创建重复任务"
            : "Create a recurring task"
    }

    var recurringTaskTitle: String {
        language == .chinese ? "任务名称" : "Task name"
    }

    var recurringTaskSchedule: String {
        language == .chinese ? "重复方式" : "Schedule"
    }

    var recurringTaskStartDate: String {
        language == .chinese ? "开始日期" : "Start date"
    }

    var recurringTaskEndDate: String {
        language == .chinese ? "结束日期" : "End date"
    }

    var createRecurringTask: String {
        language == .chinese ? "创建" : "Create"
    }

    var confirmRecurringTaskConversion: String {
        language == .chinese ? "转为重复任务" : "Convert"
    }

    var cancelRecurringTaskCreation: String {
        language == .chinese ? "取消" : "Cancel"
    }

    var recurringTaskTrack: String {
        language == .chinese ? "轨迹" : "Track"
    }

    var skipRecurringOccurrence: String {
        language == .chinese ? "跳过本次" : "Skip this occurrence"
    }

    var stopRecurringTask: String {
        language == .chinese ? "停止重复…" : "Stop repeating…"
    }

    var stopRecurringTaskConfirmation: String {
        language == .chinese
            ? "今天和历史记录会保留，只取消今天之后仍待执行的实例。"
            : "Today and history remain; only pending occurrences after today are cancelled."
    }

    var taskCycleCreated: String {
        language == .chinese ? "重复任务已创建。" : "Recurring task created."
    }

    var taskConvertedToCycle: String {
        language == .chinese
            ? "任务已转为重复任务。"
            : "Task converted to a recurring task."
    }

    var taskCycleOccurrenceSkipped: String {
        language == .chinese ? "本次已跳过。" : "Occurrence skipped."
    }

    var taskCategoryDeletedFromToday: String {
        language == .chinese
            ? "分组已删除；今天和未来的任务已转为未分组。"
            : "Group deleted; current and future tasks are now ungrouped."
    }

    func taskCycleStopped(_ count: Int) -> String {
        language == .chinese
            ? "已停止重复，取消 \(count) 个未来实例。"
            : "Repeating stopped; \(count) future occurrence\(count == 1 ? "" : "s") cancelled."
    }

    func taskCycleOccurrencePreview(_ count: Int) -> String {
        language == .chinese
            ? "将创建 \(count) 个计划日"
            : "\(count) scheduled occurrence\(count == 1 ? "" : "s") will be created"
    }

    func taskCycleDayMarker(_ schedule: TaskCycleSchedule) -> String {
        language == .chinese
            ? "重复 · \(taskCycleSchedule(schedule))"
            : "Recurring · \(taskCycleSchedule(schedule))"
    }

    var taskCollectionView: String { language == .chinese ? "视图" : "View" }
    var taskCollectionOrganization: String { language == .chinese ? "组织方式" : "Organization" }
    var taskCollectionFlat: String { language == .chinese ? "不分组" : "Flat" }
    var taskCollectionGrouped: String { language == .chinese ? "按分组" : "Group by category" }
    var taskCollectionSortKey: String { language == .chinese ? "排序依据" : "Sort by" }
    var taskCollectionSortTime: String { language == .chinese ? "时间" : "Time" }
    var taskCollectionSortTitle: String { language == .chinese ? "首字母" : "Title" }
    var taskCollectionDirection: String { language == .chinese ? "排序方向" : "Direction" }
    var taskCollectionAscending: String { language == .chinese ? "升序" : "Ascending" }
    var taskCollectionDescending: String { language == .chinese ? "降序" : "Descending" }

    func taskCycleSchedule(_ schedule: TaskCycleSchedule) -> String {
        switch (language, schedule) {
        case (.chinese, .daily): "每天"
        case (.chinese, .weekdays): "工作日"
        case (.english, .daily): "Daily"
        case (.english, .weekdays): "Weekdays"
        }
    }

    func taskCycleSummary(
        _ track: TaskCycleTrack,
        collection: TaskCycleCollection
    ) -> String {
        switch (language, collection) {
        case (.chinese, .pool):
            "\(track.scheduledCount) 个计划日 · \(track.completedCount) 天已完成"
        case (.chinese, .future):
            "\(track.futurePlanCount) 个未来计划 · \(track.completedCount) 天已完成"
        case (.chinese, .unfinished):
            "\(track.unfinishedCount) 天未完成 · \(track.completedCount) 天已完成"
        case (.chinese, .completed):
            "\(track.completedCount) 天已完成 · 共 \(track.scheduledCount) 个计划日"
        case (.english, .future):
            "\(track.futurePlanCount) planned · \(track.completedCount) completed"
        case (.english, .unfinished):
            "\(track.unfinishedCount) unfinished · \(track.completedCount) completed"
        case (.english, .completed):
            "\(track.completedCount) completed · \(track.scheduledCount) scheduled days"
        case (.english, .pool):
            "\(track.scheduledCount) scheduled · \(track.completedCount) completed"
        }
    }

    func taskCycleState(_ state: TaskCycleTrackDayState) -> String {
        let names = language == .chinese
            ? chineseTaskCycleStateNames
            : englishTaskCycleStateNames
        return names[state] ?? state.rawValue
    }

    func taskCycleFutureTarget(_ date: String) -> String {
        language == .chinese ? "目标 \(date)" : "Target \(date)"
    }
}
