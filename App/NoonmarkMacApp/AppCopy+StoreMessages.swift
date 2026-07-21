import Foundation

extension AppCopy {
    var quickTaskOriginDescription: String {
        language == .chinese
            ? "快速记录自 Day Todo。"
            : "Quickly captured from Day Todo."
    }

    var unscheduledPoolTaskDescription: String {
        language == .chinese
            ? "任务池中的待排期任务。"
            : "An unscheduled task in the Task Pool."
    }

    var unscheduledPoolTaskInitialNote: String {
        language == .chinese
            ? "可以排期到今天、明天或指定日期。"
            : "Schedule it for today, tomorrow, or a specific date."
    }

    var zhulongDailyReviewIntent: String {
        language == .chinese
            ? "结束今天并形成下一次可信承诺"
            : "Close today and form the next credible commitment"
    }

    func taskAdded(_ title: String) -> String {
        language == .chinese ? "已添加「\(title)」" : "Added “\(title)”"
    }

    var poolTaskAdded: String {
        language == .chinese ? "已加入任务池" : "Added to the task pool"
    }

    var poolCannotScheduleInPast: String {
        language == .chinese
            ? "任务池不能排期到过去日期。"
            : "Pool tasks cannot be scheduled in the past."
    }

    func scheduledTo(_ date: String) -> String {
        language == .chinese ? "已排期到 \(date)" : "Scheduled for \(date)"
    }

    func taskCompletionChanged(completed: Bool) -> String {
        switch (language, completed) {
        case (.chinese, true): "已完成"
        case (.chinese, false): "已撤销完成"
        case (.english, true): "Completed"
        case (.english, false): "Completion undone"
        }
    }

    func subtaskCompletionChanged(completed: Bool) -> String {
        switch (language, completed) {
        case (.chinese, true): "子任务已完成"
        case (.chinese, false): "子任务已撤回"
        case (.english, true): "Subtask completed"
        case (.english, false): "Subtask completion undone"
        }
    }

    var historicalSubtaskUnavailable: String {
        language == .chinese
            ? "历史子任务不可改写。"
            : "Historical subtasks cannot be changed."
    }

    var futureSubtaskUnavailable: String {
        language == .chinese
            ? "未来子任务到当天前不可改写。"
            : "Future subtasks cannot be changed before their scheduled day."
    }

    var inactiveParentSubtaskUnavailable: String {
        language == .chinese
            ? "父任务不是待完成状态，子任务不可改写。"
            : "Subtasks cannot be changed while the parent task is not pending."
    }

    var subtaskDifficultyUpdated: String {
        language == .chinese ? "子任务难度已更新" : "Subtask difficulty updated"
    }

    func continuedTo(_ date: String) -> String {
        language == .chinese ? "已延续到 \(date)" : "Continued to \(date)"
    }

    var returnedToPool: String {
        language == .chinese
            ? "已回池；当天轨迹会永久保留。"
            : "Returned to the pool. The day trail remains in history."
    }

    var taskChainAbandoned: String {
        language == .chinese
            ? "任务链已废弃；可从未完成池重新启用。"
            : "Task chain abandoned. It can be reactivated from Unfinished."
    }

    var newCurrentDayTaskDeleted: String {
        language == .chinese ? "已删除当天新增任务" : "Deleted the task added today"
    }

    var taskChainReactivated: String {
        language == .chinese ? "已取消废弃" : "Task chain reactivated"
    }

    var copiedToPool: String {
        language == .chinese
            ? "已复制为新任务并放入任务池。"
            : "Copied as a new task in the pool."
    }

    func rescheduledTo(_ date: String) -> String {
        language == .chinese ? "已改期到 \(date)" : "Rescheduled to \(date)"
    }

    var traceChangedIrreversibly: String {
        language == .chinese
            ? "已变更；原轨迹已成为不可改写的历史。"
            : "Changed. The previous trail is now immutable history."
    }

    var reviewAutoSaved: String {
        language == .chinese ? "已自动保存" : "Saved automatically"
    }

    var taskTitleUpdated: String {
        language == .chinese ? "任务标题已更新" : "Task title updated"
    }

    func poolRemovalMessage(keptHistory: Bool) -> String {
        switch (language, keptHistory) {
        case (.chinese, false): "已从任务池删除"
        case (.chinese, true): "已移出任务池；分组、标签与任务历史已保留。"
        case (.english, false): "Deleted from the task pool"
        case (.english, true): "Removed from the pool; groups, tags, and task history were preserved."
        }
    }

    var subtaskAdded: String {
        language == .chinese ? "已添加子任务" : "Subtask added"
    }

    var subtaskUpdated: String {
        language == .chinese ? "已更新子任务" : "Subtask updated"
    }

    var ephemeralFolderSyncUnavailable: String {
        language == .chinese
            ? "临时模式不支持本地文件夹同步。"
            : "Local-folder sync is unavailable in ephemeral mode."
    }

    var syncingWithEllipsis: String {
        language == .chinese ? "同步中…" : "Syncing…"
    }

    func exportSucceeded(_ fileName: String) -> String {
        language == .chinese
            ? "已导出并校验 \(fileName)"
            : "Exported and verified \(fileName)"
    }

    var providerSettingsSaved: String {
        language == .chinese ? "Provider 配置已保存" : "Provider settings saved"
    }

    var providerSettingsCleared: String {
        language == .chinese ? "Provider 配置已清空" : "Provider settings cleared"
    }

    var providerTestDisabled: String {
        language == .chinese
            ? "Provider 已关闭，未发起连接测试。"
            : "The provider is disabled; no connection test was started."
    }

    var providerTestUnavailable: String {
        language == .chinese
            ? "配置已保存；该 Provider 类型暂不支持远程健康检查。"
            : "Settings are saved; remote health checks are not available for this provider type."
    }

    var providerConnectionSucceeded: String {
        language == .chinese ? "Provider 连接成功" : "Provider connected"
    }

    var providerConnectionFailed: String {
        language == .chinese
            ? "Provider 连接失败，请检查配置与网络。"
            : "Provider connection failed. Check its settings and your network."
    }

    var providerNotEnabled: String {
        language == .chinese ? "Provider 尚未启用" : "Provider is not enabled"
    }

    var todoDiffApplied: String {
        language == .chinese ? "已原子应用 Todo 修订" : "Todo revision applied atomically"
    }

    var confirmedReviewSaved: String {
        language == .chinese
            ? "已保存用户确认的每日复盘"
            : "Confirmed daily review saved"
    }

    var nothingToUndo: String {
        language == .chinese ? "没有可撤销的操作" : "Nothing to Undo"
    }

    var undoCompleted: String {
        language == .chinese ? "已撤销" : "Undone"
    }

    var nothingToRedo: String {
        language == .chinese ? "没有可重做的操作" : "Nothing to Redo"
    }

    var redoCompleted: String {
        language == .chinese ? "已重做" : "Redone"
    }
}
