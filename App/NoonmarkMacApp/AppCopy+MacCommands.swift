import Foundation

extension AppCopy {
    var startupFailureTitle: String {
        language == .chinese ? "晷迹无法启动" : "Noonmark could not start"
    }

    var startupFailureMessage: String {
        language == .chinese
            ? "晷迹无法安全读取日期或本地数据。为避免覆盖现有内容，应用尚未启动。"
            : "Noonmark could not safely read the current date or local data. The app did not start, to avoid overwriting existing content."
    }

    var quit: String { language == .chinese ? "退出" : "Quit" }
    var exportDataPanelTitle: String {
        language == .chinese ? "导出晷迹数据" : "Export Noonmark Data"
    }

    func undoNamed(_ action: String) -> String {
        let normalized = action.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return undo }
        return language == .chinese
            ? "撤销“\(normalized)”"
            : "Undo \(normalized)"
    }

    func redoNamed(_ action: String) -> String {
        let normalized = action.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return redo }
        return language == .chinese
            ? "重做“\(normalized)”"
            : "Redo \(normalized)"
    }

    var taskChangeAction: String {
        language == .chinese ? "任务修改" : "Task Change"
    }

    var addTaskAction: String {
        language == .chinese ? "添加任务" : "Add Task"
    }

    var addPoolTaskAction: String {
        language == .chinese ? "添加任务池任务" : "Add Pool Task"
    }

    var scheduleTaskAction: String {
        language == .chinese ? "排期任务" : "Schedule Task"
    }

    var completeTaskAction: String {
        language == .chinese ? "完成任务" : "Complete Task"
    }

    var updateSubtaskAction: String {
        language == .chinese ? "修改子任务" : "Update Subtask"
    }

    var continueTaskAction: String {
        language == .chinese ? "延续任务" : "Continue Task"
    }

    var deferTaskAction: String {
        language == .chinese ? "延期任务" : "Defer Task"
    }

    var returnTaskToPoolAction: String {
        language == .chinese ? "任务回池" : "Return Task to Pool"
    }

    var deleteTaskAction: String {
        language == .chinese ? "删除任务" : "Delete Task"
    }

    var abandonTaskAction: String {
        language == .chinese ? "废弃任务链" : "Abandon Task Chain"
    }

    var reactivateTaskAction: String {
        language == .chinese ? "重新启用任务链" : "Reactivate Task Chain"
    }

    var rescheduleTaskAction: String {
        language == .chinese ? "改期任务" : "Reschedule Task"
    }

    var reorderTaskAction: String {
        language == .chinese ? "重排任务" : "Reorder Task"
    }

    var editTaskTextAction: String {
        language == .chinese ? "编辑任务描述" : "Edit Task Description"
    }

    var renameTaskAction: String {
        language == .chinese ? "重命名任务" : "Rename Task"
    }

    var updateProgressAction: String {
        language == .chinese ? "更新进度" : "Update Progress"
    }

    var addSubtaskAction: String {
        language == .chinese ? "添加子任务" : "Add Subtask"
    }

    var removeSubtaskAction: String {
        language == .chinese ? "移除子任务" : "Remove Subtask"
    }

    func completeTasksAction(_ count: Int) -> String {
        language == .chinese
            ? "完成 \(count) 项任务"
            : "Complete \(count) Task\(count == 1 ? "" : "s")"
    }

    func scheduleTasksAction(_ count: Int) -> String {
        language == .chinese
            ? "排期 \(count) 项任务"
            : "Schedule \(count) Task\(count == 1 ? "" : "s")"
    }

    func returnTasksToPoolAction(_ count: Int) -> String {
        language == .chinese
            ? "\(count) 项任务回池"
            : "Return \(count) Task\(count == 1 ? "" : "s") to Pool"
    }

    var copyTaskAction: String {
        language == .chinese ? "复制任务" : "Copy Task"
    }

    var addNoteAction: String {
        language == .chinese ? "添加附言" : "Add Note"
    }

    var editNoteMenuAction: String {
        language == .chinese ? "编辑附言" : "Edit Note"
    }

    var deleteNoteMenuAction: String {
        language == .chinese ? "删除附言" : "Delete Note"
    }

    var fileMenu: String { language == .chinese ? "文件" : "File" }
    var windowMenu: String { language == .chinese ? "窗口" : "Window" }
    var helpMenu: String { language == .chinese ? "帮助" : "Help" }
    var aboutApp: String {
        language == .chinese ? "关于晷迹" : "About Noonmark"
    }

    var settingsCommand: String {
        language == .chinese ? "设置…" : "Settings…"
    }

    var services: String { language == .chinese ? "服务" : "Services" }
    var hideApp: String {
        language == .chinese ? "隐藏晷迹" : "Hide Noonmark"
    }

    var hideOthers: String {
        language == .chinese ? "隐藏其他" : "Hide Others"
    }

    var showAll: String { language == .chinese ? "全部显示" : "Show All" }
    var quickEntryCommand: String {
        language == .chinese ? "快速记录…" : "Quick Entry…"
    }

    var searchCommand: String {
        language == .chinese ? "搜索晷迹…" : "Search Noonmark…"
    }

    var closeWindow: String {
        language == .chinese ? "关闭窗口" : "Close Window"
    }

    var findMenu: String { language == .chinese ? "查找" : "Find" }
    var find: String { language == .chinese ? "查找…" : "Find…" }
    var findNext: String {
        language == .chinese ? "查找下一个" : "Find Next"
    }

    var findPrevious: String {
        language == .chinese ? "查找上一个" : "Find Previous"
    }

    var spellingAndGrammar: String {
        language == .chinese ? "拼写与语法" : "Spelling and Grammar"
    }

    var showSpellingAndGrammar: String {
        language == .chinese ? "显示拼写与语法" : "Show Spelling and Grammar"
    }

    var checkSpelling: String {
        language == .chinese ? "立即检查文稿" : "Check Document Now"
    }

    var checkSpellingWhileTyping: String {
        language == .chinese ? "键入时检查拼写" : "Check Spelling While Typing"
    }

    var checkGrammarWithSpelling: String {
        language == .chinese ? "随拼写检查语法" : "Check Grammar With Spelling"
    }

    var correctSpellingAutomatically: String {
        language == .chinese ? "自动纠正拼写" : "Correct Spelling Automatically"
    }

    var minimize: String { language == .chinese ? "最小化" : "Minimize" }
    var zoom: String { language == .chinese ? "缩放" : "Zoom" }
    var enterFullScreen: String {
        language == .chinese ? "进入全屏幕" : "Enter Full Screen"
    }

    var bringAllToFront: String {
        language == .chinese ? "前置全部窗口" : "Bring All to Front"
    }

    var mainWindowCommand: String {
        language == .chinese ? "晷迹主窗口" : "Noonmark Main Window"
    }

    var noonmarkHelp: String {
        language == .chinese ? "晷迹使用帮助" : "Noonmark Help"
    }

    var helpQuickStartTitle: String {
        language == .chinese ? "从一条可信承诺开始" : "Start with one credible commitment"
    }

    var helpQuickStartBody: String {
        language == .chinese
            ? "用快速记录创建今天的任务；未完成的轨迹会保留到复盘，而不会被静默删除。"
            : "Use Quick Entry to create a task for today. Unfinished trails remain available for review instead of disappearing."
    }

    var helpShortcutsTitle: String {
        language == .chinese ? "常用快捷键" : "Keyboard shortcuts"
    }

    var helpDataTitle: String {
        language == .chinese ? "数据与隐私" : "Data and privacy"
    }

    var helpDataBody: String {
        language == .chinese
            ? "任务数据默认保存在本机。导入前会先验证数据包，并要求明确确认后才替换现有数据。"
            : "Task data stays local by default. Imports are verified first and replace current data only after explicit confirmation."
    }
}
