import NoonmarkCore
import NoonmarkMacRuntime
import NoonmarkStorage
import NoonmarkSync

struct AppCopy {
    let language: AppLanguage

    var appName: String {
        switch language {
        case .chinese: "晷迹"
        case .english: "Noonmark"
        }
    }

    var editMenu: String { language == .chinese ? "编辑" : "Edit" }
    var viewMenu: String { language == .chinese ? "显示" : "View" }
    var quitApp: String { language == .chinese ? "退出晷迹" : "Quit Noonmark" }
    var undo: String { language == .chinese ? "撤销" : "Undo" }
    var redo: String { language == .chinese ? "重做" : "Redo" }
    var cut: String { language == .chinese ? "剪切" : "Cut" }
    var copy: String { language == .chinese ? "复制" : "Copy" }
    var paste: String { language == .chinese ? "粘贴" : "Paste" }
    var delete: String { language == .chinese ? "删除" : "Delete" }
    var selectAll: String { language == .chinese ? "全选" : "Select All" }
    var retry: String { language == .chinese ? "重试" : "Retry" }
    var automaticClassificationWorking: String {
        language == .chinese ? "智能归类中…" : "Organizing…"
    }

    var automaticClassificationWaitingForConfiguration: String {
        language == .chinese ? "等待配置 AI" : "Waiting for AI setup"
    }

    var automaticClassificationWaitingForDecision: String {
        language == .chinese ? "等待你开始" : "Waiting for you to start"
    }

    var automaticClassificationProviderPaused: String {
        language == .chinese ? "智能归类已暂停 · 重试" : "Organizing paused · Retry"
    }

    var automaticClassificationFailed: String {
        language == .chinese ? "归类失败 · 重试" : "Couldn’t organize · Retry"
    }

    func automaticClassificationStatusAccessibilityLabel(
        _ status: String,
        taskTitle: String
    ) -> String {
        let taskTitle = displayTaskTitle(taskTitle)
        return switch language {
        case .chinese: "任务“\(taskTitle)”：\(status)"
        case .english: "Task “\(taskTitle)”: \(status)"
        }
    }

    var naturalDayBlockedTitle: String {
        language == .chinese
            ? "日期切换尚未安全完成，编辑已暂停"
            : "The day change is not safely applied; editing is paused"
    }

    var planGroup: String { language == .chinese ? "计划" : "Plan" }
    var traceGroup: String { language == .chinese ? "轨迹" : "Trace" }
    var navDay: String { "Day Todo" }
    var navPool: String { language == .chinese ? "任务池" : "Task Pool" }
    var navFuture: String { language == .chinese ? "未来计划" : "Upcoming" }
    var navUnfinished: String { language == .chinese ? "未完成" : "Unfinished" }
    var navCompleted: String { language == .chinese ? "已完成" : "Completed" }
    var navCalendar: String { language == .chinese ? "日历" : "Calendar" }
    var navZhulong: String { language == .chinese ? "烛龙" : "Zhulong" }
    var navSettings: String { language == .chinese ? "设置" : "Settings" }
    var expandSidebar: String { language == .chinese ? "展开左侧栏" : "Show navigation sidebar" }
    var collapseSidebar: String {
        language == .chinese ? "收起左侧栏为图标列" : "Collapse navigation to icons"
    }

    var expandDetailRail: String { language == .chinese ? "展开右侧栏" : "Show detail sidebar" }
    var collapseDetailRail: String { language == .chinese ? "收起右侧栏" : "Hide detail sidebar" }
    var today: String { language == .chinese ? "今天" : "Today" }
    var chooseDate: String { language == .chinese ? "选日期" : "Choose date" }
    var openDay: String { language == .chinese ? "查看当天 →" : "Open day →" }
    var copyAsNewTask: String { language == .chinese ? "复制为新任务" : "Copy as new task" }
    var reschedule: String { language == .chinese ? "改期…" : "Reschedule…" }
    var returnToPool: String { language == .chinese ? "回池" : "Back to pool" }
    var scheduleToday: String { language == .chinese ? "排期到今天" : "Schedule today" }
    var scheduleTomorrow: String { language == .chinese ? "排期到明天" : "Schedule tomorrow" }
    var continueTo: String { language == .chinese ? "延续到…" : "Continue to…" }
    var deferTo: String { language == .chinese ? "延期到…" : "Defer to…" }
    var withdrawDeferral: String { language == .chinese ? "撤回延期" : "Withdraw deferral" }
    var pinToTop: String { language == .chinese ? "置顶" : "Pin to top" }
    var unpin: String { language == .chinese ? "取消置顶" : "Unpin" }
    var abandonChain: String { language == .chinese ? "废弃任务链" : "Drop chain" }
    var markComplete: String { language == .chinese ? "标记完成" : "Mark complete" }
    var undoComplete: String { language == .chinese ? "撤销完成" : "Undo complete" }
    var changeToNewTask: String { language == .chinese ? "变更为新任务…" : "Change to new task…" }
    var returnToPoolWithTrace: String { language == .chinese ? "回到任务池（留下轨迹）" : "Back to pool, keep trace" }
    var chooseScheduleDate: String { language == .chinese ? "选择日期…" : "Choose date…" }
    var deleteTask: String { language == .chinese ? "删除任务" : "Delete task" }
    var reactivateChain: String { language == .chinese ? "重新启用" : "Reactivate" }
    var openCurrentPending: String { language == .chinese ? "跳转到当前待完成" : "Open current pending" }
    var copyParentAsNewTask: String { language == .chinese ? "复制父任务为新任务" : "Copy parent as new task" }
    var copyParentTask: String { language == .chinese ? "复制父任务" : "Copy parent task" }
    var noteSectionTitle: String { language == .chinese ? "附言" : "Notes" }
    var noteComposerPlaceholder: String {
        language == .chinese ? "追加附言，回车确认" : "Add a note, press Return"
    }

    var noteActionsAccessibilityLabel: String {
        language == .chinese ? "附言操作" : "Note actions"
    }

    var editNoteAction: String { language == .chinese ? "编辑附言" : "Edit note" }
    var deleteNoteAction: String { language == .chinese ? "删除附言" : "Delete note" }
    var editNotePlaceholder: String { language == .chinese ? "编辑附言…" : "Edit note…" }
    var cancel: String { language == .chinese ? "取消" : "Cancel" }
    var noteDeletedToast: String { language == .chinese ? "已删除附言" : "Note deleted" }

    var lockedDayNotice: String {
        language == .chinese
            ? "历史日已锁定：任务事实不可改写，可补写复盘。未完成任务可延续或废弃。"
            : "This day is locked: task facts cannot be rewritten. You can still write the review, continue unfinished tasks, or drop them."
    }

    var futureDayNotice: String {
        language == .chinese
            ? "未来日：可排期、置顶和选择查看方式，不能提前完成或生成复盘。"
            : "Future day: schedule, pin, and change the view. Completion and review are not available yet."
    }

    var emptyDay: String { language == .chinese ? "这一天没有留下任务。" : "No tasks on this day." }
    var scheduleFromPool: String { language == .chinese ? "从任务池排期…" : "Schedule from pool…" }
    var poolSubtitle: String {
        language == .chinese ? "尚未安排日期的任务。排期后会出现在对应的 Day Todo。" : "Unscheduled tasks. Schedule one and it appears on the matching Day Todo."
    }

    var emptyPool: String { language == .chinese ? "任务池是空的。" : "Task Pool is empty." }
    var futureSubtitle: String {
        language == .chinese ? "已排到未来日期的计划草稿，可改期或回到任务池。" : "Draft plans scheduled for future dates. Reschedule them or return them to the pool."
    }

    var emptyFuture: String { language == .chinese ? "还没有未来计划。" : "No upcoming plans yet." }
    var unfinishedSubtitle: String {
        language == .chinese
            ? "按任务链去重的未完成轨迹。延续它，或明确废弃。"
            : "Each unfinished task appears once, grouped by task chain. Continue it or mark it abandoned."
    }

    var emptyUnfinished: String { language == .chinese ? "没有待处理的未完成任务。" : "No unfinished tasks." }
    func unfinishedMissedCount(_ count: Int) -> String {
        switch language {
        case .chinese: "\(count) 次未完成"
        case .english: count == 1 ? "1 missed" : "\(count) missed"
        }
    }

    func unfinishedContinuationCount(_ count: Int) -> String {
        switch language {
        case .chinese: "\(count) 次延续"
        case .english: count == 1 ? "1 continued" : "\(count) continued"
        }
    }

    func lastMissedDate(_ dateLabel: String) -> String {
        switch language {
        case .chinese: "最近未完成 · \(dateLabel)"
        case .english: "Last missed · \(dateLabel)"
        }
    }

    var completedSubtitle: String {
        language == .chinese ? "按完成记录逐条展示，并附带每条的任务轨迹。" : "Completed records with their task trajectories."
    }

    var emptyCompleted: String { language == .chinese ? "还没有完成记录。" : "No completed records yet." }
    var calendarSubtitle: String {
        language == .chinese ? "整月轨迹总览。点选任一天，右侧查看当天详情。" : "A whole-month trace overview. Pick any day to inspect it on the right."
    }

    var settingsSubtitle: String {
        language == .chinese
            ? "偏好、数据包、本地优先云同步和烛龙配置的统一入口。"
            : "Preferences, data packages, local-first cloud sync, and Zhulong configuration in one place."
    }

    var preferencesTitle: String { language == .chinese ? "偏好" : "Preferences" }
    var preferencesSubtitle: String {
        language == .chinese ? "影响本机显示，不改变任务事实。" : "Affects local display only; task facts stay unchanged."
    }

    var appearanceTitle: String { language == .chinese ? "外观" : "Appearance" }
    var coolGray: String { language == .chinese ? "冷灰" : "Cool gray" }
    var warmPaper: String { language == .chinese ? "微暖纸感" : "Warm paper" }
    var languageTitle: String { language == .chinese ? "语言" : "Language" }
    var swipeDirectionTitle: String {
        language == .chinese ? "页面滑动方向" : "Page swipe direction"
    }

    var bookSwipeDirection: String {
        language == .chinese ? "翻书方向" : "Book direction"
    }

    var reversedSwipeDirection: String {
        language == .chinese ? "反向" : "Reversed"
    }

    var swipeDirectionExplanation: String {
        language == .chinese
            ? "同时用于 Day Todo 与日历；翻书方向为左滑到下一天或下个月。"
            : "Applies to Day Todo and Calendar; Book direction swipes left to the next day or month."
    }

    var settingsPoemTitle: String { language == .chinese ? "关于页诗文" : "Poem" }
    var settingsPoemDisplay: String {
        language == .chinese ? "在“关于晷迹”中展示诗文" : "Show poem in About Noonmark"
    }

    var settingsPoemEditorTitle: String { language == .chinese ? "诗文内容" : "Poem text" }
    var resetSettingsPoem: String { language == .chinese ? "恢复默认《苦昼短》" : "Restore default" }
    var settingsPoemResetToast: String { language == .chinese ? "已恢复默认诗文" : "Default poem restored" }

    var dataSectionTitle: String { language == .chinese ? "数据" : "Data" }
    var dataSectionSubtitle: String {
        language == .chinese
            ? "导出经过校验的恢复包，或事务性导入。"
            : "Export verified recovery packages or import transactionally."
    }

    var exportJSON: String { language == .chinese ? "导出数据 (JSON)" : "Export JSON" }
    var importData: String { language == .chinese ? "导入数据…" : "Import…" }
    var importPanelTitle: String { language == .chinese ? "选择晷迹数据包" : "Choose a Noonmark data package" }
    var importConfirmationTitle: String { language == .chinese ? "替换当前所有数据？" : "Replace all current data?" }
    var importConfirmationMessage: String {
        language == .chinese
            ? "导入会以所选数据包整体替换当前任务、轨迹、复盘与偏好。此操作不能撤销。"
            : "Importing replaces all current tasks, trails, reviews, and preferences with the selected package. This cannot be undone."
    }

    var importVerifiedPackage: String { language == .chinese ? "已校验数据包" : "Verified package" }
    var importDays: String { language == .chinese ? "日期" : "Days" }
    var importTasks: String { language == .chinese ? "任务" : "Tasks" }
    var importTraces: String { language == .chinese ? "轨迹" : "Trails" }
    var importSubtasks: String { language == .chinese ? "子任务" : "Subtasks" }
    var confirmImport: String { language == .chinese ? "替换并导入" : "Replace & Import" }
    func importSucceeded(_ fileName: String) -> String {
        language == .chinese ? "已导入 \(fileName)" : "Imported \(fileName)"
    }

    var todayTraceMetric: String { language == .chinese ? "今日轨迹" : "Today" }
    var taskPoolMetric: String { navPool }
    var unfinishedMetric: String { navUnfinished }
    var completedMetric: String { navCompleted }
    var syncTitle: String { language == .chinese ? "同步" : "Sync" }
    var syncSubtitle: String {
        language == .chinese
            ? "本地优先可显式启用记录同步；在线优先的定时备份仍在规划中。"
            : "Local-first can enable record sync; online-first scheduled backup is still planned."
    }

    var planned: String { language == .chinese ? "规划中" : "Planned" }
    var available: String { language == .chinese ? "可用" : "Available" }
    var unavailable: String { language == .chinese ? "不可用" : "Unavailable" }
    var dataModeTitle: String { language == .chinese ? "数据模式" : "Data mode" }
    var localFirstMode: String { language == .chinese ? "本地优先" : "Local-first" }
    var onlineFirstMode: String { language == .chinese ? "在线优先" : "Online-first" }
    var dataModeBoundary: String {
        language == .chinese
            ? "两种主数据模式互斥。本地优先的 iCloud、S3 或 WebDAV 是同步端点，不是定时备份目标。"
            : "The primary modes are exclusive. In local-first mode, iCloud, S3, or WebDAV is a sync endpoint, not a scheduled backup destination."
    }

    var localFirstSyncTitle: String { language == .chinese ? "本地优先云同步" : "Local-first cloud sync" }
    var syncEndpointTitle: String { language == .chinese ? "同步端点" : "Sync endpoint" }
    var syncModeTitle: String { language == .chinese ? "同步触发" : "Sync trigger" }
    var syncManualMode: String { language == .chinese ? "手动" : "Manual" }
    var syncAutomaticMode: String { language == .chinese ? "自动" : "Automatic" }
    var localFirstSyncEnabled: String { language == .chinese ? "启用同步" : "Enable sync" }
    var localFirstSyncDisabled: String { language == .chinese ? "同步已关闭" : "Sync is off" }
    var syncAutomaticIntervalTitle: String { language == .chinese ? "自动间隔" : "Automatic interval" }
    func syncAutomaticInterval(_ seconds: Int) -> String {
        if seconds < 60 {
            return language == .chinese ? "每 \(seconds) 秒" : "Every \(seconds) sec"
        }
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        guard remainingSeconds > 0 else {
            return language == .chinese ? "每 \(minutes) 分钟" : "Every \(minutes) min"
        }
        return language == .chinese
            ? "每 \(minutes) 分 \(remainingSeconds) 秒"
            : "Every \(minutes) min \(remainingSeconds) sec"
    }

    var syncNow: String { language == .chinese ? "立即同步" : "Sync now" }
    var syncing: String { language == .chinese ? "同步中" : "Syncing" }
    var syncFolderPathTitle: String { language == .chinese ? "同步文件夹" : "Sync folder" }
    var iCloudDriveLocationTitle: String { language == .chinese ? "iCloud Drive 位置" : "iCloud Drive location" }
    var localCachePathTitle: String { language == .chinese ? "本机缓存路径" : "Local cache path" }
    var iCloudDriveLogicalLocation: String {
        "iCloud Drive/\(ICloudDriveSyncTransport.defaultRepositoryName)"
    }

    var localFolderSyncReady: String {
        language == .chinese
            ? "本地文件夹端点已接入：会上传本机变更、下载远端记录并在仓库生成快照索引。"
            : "The local folder endpoint is active: it uploads local changes, downloads remote records, and writes snapshot indexes."
    }

    var iCloudSyncReady: String {
        language == .chinese
            ? "同步仓库已写入 iCloud Drive 本机镜像；云端上传由系统完成，可能存在短暂延迟。"
            : "The repository is written to the local iCloud Drive mirror; system upload may be briefly delayed."
    }

    var cloudKitSyncReady: String {
        language == .chinese
            ? "同步记录通过 CloudKit private database 交换；系统调度可能带来短暂延迟。"
            : "Records sync through the CloudKit private database; system scheduling may introduce a short delay."
    }

    var cloudKitContainerTitle: String {
        language == .chinese ? "CloudKit container" : "CloudKit container"
    }

    var cloudKitZoneTitle: String {
        language == .chinese ? "CloudKit zone" : "CloudKit zone"
    }

    var remoteEndpointPlanned: String {
        language == .chinese
            ? "该端点还在接入中；本地优先模式下它会作为同步仓库端点，不会出现定时备份。"
            : "This endpoint is still being connected; in local-first mode it will be a sync repository endpoint, not scheduled backup."
    }

    func syncAvailabilityTitle(for availability: SyncEndpointAvailability) -> String {
        switch availability {
        case .available:
            return available
        case .planned:
            return planned
        }
    }

    var localFirstSyncUnavailableToast: String {
        language == .chinese
            ? "当前只有 iCloud 和本地文件夹端点可以立即同步"
            : "Only iCloud and local folder endpoints can sync now"
    }

    var localFirstSyncBoundary: String {
        language == .chinese
            ? "本机 SQLite 仍是事实源；同步只交换经过校验的记录，并保留等待、失败与冲突状态。S3/WebDAV 尚未接入。"
            : "Local SQLite remains authoritative. Sync exchanges validated records and retains waiting, failure, and conflict state. S3/WebDAV are not connected yet."
    }

    var scheduledBackupTitle: String { language == .chinese ? "定时备份" : "Scheduled backup" }
    var backupBoundary: String {
        language == .chinese
            ? "定时自动导出尚未接入。当前请在“数据”页手动导出经过校验的 JSON 恢复包。"
            : "Scheduled export is not connected yet. Use Data to manually export a verified JSON recovery package."
    }

    var providerTitle: String { language == .chinese ? "烛龙与自动化" : "Zhulong and Automation" }
    var providerSubtitle: String {
        language == .chinese
            ? "页面、对话权限、自动分组与标签、Provider 分别独立控制；普通清单不依赖它们。"
            : "The page, conversation permissions, automatic groups and labels, and Provider are independent; normal lists depend on none of them."
    }

    var zhulongSubtitle: String {
        language == .chinese
            ? "可选 sidecar：复盘分析、任务拆解、排期建议和分组与标签整理。"
            : "Optional sidecar for reviews, decomposition, scheduling, and classification."
    }

    var analyzeTodayWithZhulong: String {
        language == .chinese ? "让烛龙分析今日" : "Analyze today"
    }

    var providerConfigured: String { language == .chinese ? "Provider 已配置" : "Provider configured" }
    var providerIncomplete: String { language == .chinese ? "配置不完整" : "Incomplete" }
    var providerDisabled: String { language == .chinese ? "Provider 未启用" : "Provider disabled" }
    var keychainStored: String { language == .chinese ? "Keychain 有凭证" : "Keychain credential" }
    var keychainMissing: String { language == .chinese ? "未保存凭证" : "No credential" }
    var providerType: String { language == .chinese ? "类型" : "Type" }
    var providerName: String { language == .chinese ? "名称" : "Name" }
    var providerModel: String { language == .chinese ? "模型" : "Model" }
    var providerUnset: String { language == .chinese ? "未配置" : "Unset" }
    var customProvider: String { language == .chinese ? "自定义 Provider" : "Custom Provider" }
    var openZhulongConfig: String { language == .chinese ? "打开烛龙配置" : "Open Zhulong settings" }
    var save: String { language == .chinese ? "保存" : "Save" }
    var testConnection: String { language == .chinese ? "测试连接" : "Test" }
    var clear: String { language == .chinese ? "清空" : "Clear" }
    var zhulongPermissionCeilingTitle: String {
        language == .chinese ? "对话权限上限" : "Conversation permission ceiling"
    }

    var zhulongDataReadingPermission: String {
        language == .chinese ? "任务数据读取" : "Task data reading"
    }

    var zhulongRemoteSendingPermission: String {
        language == .chinese ? "远程发送" : "Remote sending"
    }

    var zhulongPermissionCeilingExplanation: String {
        language == .chinese
            ? "“每次询问”会确认新会话；允许或询问状态下，数据范围扩大或接收方实质变化会重新确认；禁止状态不会发送。Todo 写入始终需要单独提交。"
            : "Ask confirms new sessions. With Allow or Ask, expanded scope or a material recipient change requires confirmation; Deny sends nothing. Todo writes always require a separate commit."
    }

    func zhulongPermissionPolicyTitle(
        _ policy: ZhulongPermissionPolicy
    ) -> String {
        switch (language, policy) {
        case (.chinese, .allow): "允许"
        case (.chinese, .ask): "每次询问"
        case (.chinese, .deny): "禁止"
        case (.english, .allow): "Allow"
        case (.english, .ask): "Ask"
        case (.english, .deny): "Deny"
        }
    }

    var zhulongDataAccessDeniedToast: String {
        language == .chinese
            ? "烛龙数据访问已在设置中禁止"
            : "Zhulong data access is denied in Settings"
    }

    var localFirstSyncChangedToast: String { language == .chinese ? "本地优先同步设置已更新" : "Local-first sync settings updated" }

    func localFirstSyncResult(
        _ result: SQLiteLocalFirstSyncResult,
        unresolvedConflictCount: Int? = nil
    ) -> String {
        let conflictCount = unresolvedConflictCount ?? result.download.conflictCount
        let requiresAttention = result.upload.failedCount > 0
            || result.download.waitingCount > 0
            || conflictCount > 0
        return switch language {
        case .chinese:
            "\(requiresAttention ? "同步需处理" : "同步完成")：上传 \(result.upload.uploadedCount) 条，下载合并 \(result.download.appliedCount) 条，等待 \(result.download.waitingCount) 条，失败 \(result.upload.failedCount) 条，未解决冲突 \(conflictCount) 条"
        case .english:
            "\(requiresAttention ? "Sync needs attention" : "Sync complete"): uploaded \(result.upload.uploadedCount), merged \(result.download.appliedCount), waiting \(result.download.waitingCount), failed \(result.upload.failedCount), unresolved conflicts \(conflictCount)"
        }
    }

    func dataModeChangedToast(for dataMode: AppDataMode) -> String {
        switch (language, dataMode) {
        case (.chinese, .localFirst): "已切换为本地优先"
        case (.chinese, .onlineFirst): "已切换为在线优先"
        case (.english, .localFirst): "Switched to local-first"
        case (.english, .onlineFirst): "Switched to online-first"
        }
    }

    var privacyTitle: String { language == .chinese ? "写入与隐私边界" : "Write & Privacy Boundaries" }
    var privacySubtitle: String {
        language == .chinese ? "Provider 请求和 AI 建议必须 fail-closed。" : "Provider requests and AI suggestions must fail closed."
    }

    var privacyRows: [String] {
        switch language {
        case .chinese:
            [
                "发送远程请求前必须展示授权范围。",
                "不发送数据库文件、内部 ID、Keychain 值或同步端点配置。",
                "创建、排期、变更、延续、废弃或标签写入都必须由用户确认。",
                "Provider 失败不影响 Day Todo、任务池、日历和数据包。"
            ]
        case .english:
            [
                "Show the authorized scope before each remote request.",
                "Never send database files, internal IDs, Keychain values, or sync endpoint config.",
                "Creates, schedules, changes, continuations, drops, and label writes require confirmation.",
                "Provider failures do not affect Day Todo, Task Pool, Calendar, or data packages."
            ]
        }
    }

    func itemCount(_ count: Int) -> String {
        switch language {
        case .chinese: "\(count) 项"
        case .english: count == 1 ? "1 item" : "\(count) items"
        }
    }

    func chainCount(_ count: Int) -> String {
        switch language {
        case .chinese: "\(count) 条链"
        case .english: count == 1 ? "1 chain" : "\(count) chains"
        }
    }

    func recordCount(_ count: Int) -> String {
        switch language {
        case .chinese: "\(count) 条记录"
        case .english: count == 1 ? "1 record" : "\(count) records"
        }
    }

    func syncTitle(for kind: SyncEndpointKind) -> String {
        switch (language, kind) {
        case (.chinese, .customEndpoint): "自定义同步端点"
        case (.chinese, .iCloud): "iCloud 云同步"
        case (.chinese, .s3): "S3 云同步"
        case (.chinese, .webDAV): "WebDAV 云同步"
        case (.chinese, .localFolder): "本地同步文件夹"
        case (.english, .customEndpoint): "Custom sync endpoint"
        case (.english, .iCloud): "iCloud sync"
        case (.english, .s3): "S3 sync"
        case (.english, .webDAV): "WebDAV sync"
        case (.english, .localFolder): "Local sync folder"
        }
    }

    func syncDescription(for kind: SyncEndpointKind) -> String {
        switch (language, kind) {
        case (.chinese, .customEndpoint): "连接自有服务端"
        case (.chinese, .iCloud): "使用 iCloud Drive 记录仓库"
        case (.chinese, .s3): "使用兼容 S3 的对象存储"
        case (.chinese, .webDAV): "使用兼容 WebDAV 的远端目录"
        case (.chinese, .localFolder): "使用自管目录或局域网共享"
        case (.english, .customEndpoint): "Connect your own server"
        case (.english, .iCloud): "Use an iCloud Drive record repository"
        case (.english, .s3): "Use S3-compatible object storage"
        case (.english, .webDAV): "Use a WebDAV-compatible remote directory"
        case (.english, .localFolder): "Use a managed folder or LAN share"
        }
    }

    func cloudSyncEndpointTitle(for kind: CloudSyncEndpointKind) -> String {
        switch (language, kind) {
        case (.chinese, .iCloud): "iCloud"
        case (.chinese, .s3): "S3"
        case (.chinese, .webDAV): "WebDAV"
        case (.chinese, .localFolder): "本地文件夹"
        case (.english, .iCloud): "iCloud"
        case (.english, .s3): "S3"
        case (.english, .webDAV): "WebDAV"
        case (.english, .localFolder): "Local folder"
        }
    }
}
