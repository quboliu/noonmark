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
        case (.chinese, .future):
            "\(track.futurePlanCount) 天待计划 · \(track.completedCount) 天已完成"
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
