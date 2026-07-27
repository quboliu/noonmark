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

    var taskCycleEveryDaysMode: String {
        language == .chinese ? "按天" : "Day interval"
    }

    var taskCycleWeekdayMode: String {
        language == .chinese ? "按星期" : "Weekdays"
    }

    var taskCycleEndRule: String {
        language == .chinese ? "结束条件" : "End rule"
    }

    var taskCycleEndByDuration: String {
        language == .chinese ? "总天数" : "Duration"
    }

    var taskCycleEndByCompletion: String {
        language == .chinese ? "达成次数" : "Completion count"
    }

    var taskCycleEndByDate: String {
        language == .chinese ? "指定日期" : "Date"
    }

    var taskCycleLatestDate: String {
        language == .chinese ? "最晚截止" : "Latest date"
    }

    var taskCycleCompletionLockNotice: String {
        language == .chinese
            ? "完成日锁定后才计入达成次数；最晚截止用于防止无限生成。"
            : "A completion counts after its day is locked. The latest date prevents unbounded generation."
    }

    var taskCycleEditPlan: String {
        language == .chinese ? "修改重复设置…" : "Edit recurrence…"
    }

    var taskCycleSavePlan: String {
        language == .chinese ? "保存修改" : "Save changes"
    }

    var taskCyclePlanEffectiveNotice: String {
        language == .chinese
            ? "尚未开始且没有执行记录时可调整开始日期；开始后，频率和结束条件的修改从明天起生效，历史不会改写。"
            : "The start date can change before the series begins and before it has any execution history. After it starts, schedule and end-rule changes take effect tomorrow without rewriting history."
    }

    var taskCycleStoppedNotice: String {
        language == .chinese
            ? "该重复任务已提前结束。历史与今天仍然保留。"
            : "This recurring task ended early. History and today remain."
    }

    var taskCycleSettingsTitle: String {
        language == .chinese ? "重复设置" : "Recurrence"
    }

    var taskCycleTemplateTitle: String {
        language == .chinese ? "重复任务" : "Recurring task"
    }

    func taskCycleEveryDays(_ interval: Int) -> String {
        language == .chinese
            ? "每 \(interval) 天重复"
            : "Repeat every \(interval) day\(interval == 1 ? "" : "s")"
    }

    func taskCycleEveryWeeks(_ interval: Int) -> String {
        language == .chinese
            ? "每 \(interval) 周的所选日期"
            : "Selected days every \(interval) week\(interval == 1 ? "" : "s")"
    }

    func taskCycleDurationDays(_ days: Int) -> String {
        language == .chinese
            ? "从开始日起共 \(days) 天"
            : "\(days) calendar day\(days == 1 ? "" : "s") from start"
    }

    func taskCycleCompletionTarget(_ count: Int) -> String {
        language == .chinese
            ? "完成 \(count) 次后结束"
            : "End after \(count) completion\(count == 1 ? "" : "s")"
    }

    func taskCycleWeekday(_ weekday: TaskCycleWeekday) -> String {
        let chinese = ["日", "一", "二", "三", "四", "五", "六"]
        let english = ["S", "M", "T", "W", "T", "F", "S"]
        return (language == .chinese ? chinese : english)[
            weekday.rawValue - 1
        ]
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
        switch schedule {
        case let .everyDays(interval):
            if interval == 1 {
                return language == .chinese ? "每天" : "Daily"
            }
            return language == .chinese
                ? "每 \(interval) 天"
                : "Every \(interval) days"
        case let .selectedWeekdays(weekdays, everyWeeks):
            if schedule == .weekdays {
                return language == .chinese ? "工作日" : "Weekdays"
            }
            let dayCount = weekdays.count
            return language == .chinese
                ? "每 \(everyWeeks) 周 · \(dayCount) 天"
                : "Every \(everyWeeks) weeks · \(dayCount) days"
        }
    }

    func taskCycleEndCondition(
        _ condition: TaskCycleEndCondition,
        startDate: LocalDate
    ) -> String {
        switch condition {
        case let .durationDays(days):
            return taskCycleDurationDays(days)
        case let .completionTarget(count, latestDate):
            return language == .chinese
                ? "完成 \(count) 次，最晚 \(latestDate.description)"
                : "\(count) completions, by \(latestDate.description)"
        case let .onDate(date):
            return language == .chinese
                ? "截至 \(date.description)"
                : "Until \(date.description)"
        }
    }

    func taskCycleSummary(_ track: TaskCycleTrack) -> String {
        switch language {
        case .chinese:
            "\(track.scheduledCount) 个计划日 · \(track.futurePlanCount) 个未来"
        case .english:
            "\(track.scheduledCount) scheduled · \(track.futurePlanCount) upcoming"
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
