import AppKit
import SuntraceAI
import SuntraceCore
import SuntraceStorage
import SuntraceSync
import SwiftUI
import UniformTypeIdentifiers

@main
@MainActor
final class SuntraceMacApp: NSObject, NSApplicationDelegate {
    private static var retainedDelegate: SuntraceMacApp?
    private var window: NSWindow?
    private let store = SuntraceStore()

    static func main() {
        let app = NSApplication.shared
        let delegate = SuntraceMacApp()
        if CommandLine.arguments.contains("--e2e-enable-zhulong") {
            delegate.store.zhulongProviderDraft.enabled = true
        }
        if CommandLine.arguments.contains("--e2e-reset-selection") {
            delegate.store.resetLaunchSelection()
        }
        if CommandLine.arguments.contains("--page"), let index = CommandLine.arguments.firstIndex(of: "--page") {
            let valueIndex = CommandLine.arguments.index(after: index)
            let pageName = CommandLine.arguments.indices.contains(valueIndex) ? CommandLine.arguments[valueIndex] : ""
            if let page = SuntraceStore.Page(commandLineValue: pageName) {
                delegate.store.page = page
            }
        }
        retainedDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        store.ensureVisiblePage()
        openMainWindow()
        runLaunchAutomationIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.persist()
    }

    func openMainWindow() {
        guard window == nil else {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = SuntraceRootView()
            .environmentObject(store)
            .frame(minWidth: 1180, minHeight: 760)
            .preferredColorScheme(.light)

        let window = SuntraceWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = store.windowTitle
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 1180, height: 760)
        window.contentMinSize = NSSize(width: 1180, height: 760)
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.center()
        window.contentView = NSHostingView(rootView: root)
        self.window = window

        DispatchQueue.main.async {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(title: "晷迹", action: nil, keyEquivalent: "")
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        mainMenu.addItem(appItem)
        mainMenu.addItem(editItem)

        let appMenu = NSMenu(title: "晷迹")
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "退出晷迹", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        let undoItem = editMenu.addItem(withTitle: "撤销", action: #selector(undoAction(_:)), keyEquivalent: "z")
        undoItem.target = self
        NSApp.mainMenu = mainMenu
    }

    @objc private func undoAction(_ sender: Any?) {
        store.undo()
    }

    private func runLaunchAutomationIfNeeded() {
        guard let automation = LaunchAutomation.fromCommandLine() else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [store, automation] in
            automation.run(on: store)
        }
    }
}

private struct LaunchAutomation {
    var actions: [@MainActor (SuntraceStore) -> Void]
    var quitsAfterAutomation: Bool

    @MainActor
    static func fromCommandLine() -> LaunchAutomation? {
        var actions: [@MainActor (SuntraceStore) -> Void] = []
        let quickTaskTitle = SuntraceStore.commandLineValue(after: "--e2e-add-quick-task")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let quickTaskTitle, quickTaskTitle.isEmpty == false {
            actions.append { store in
                store.page = .day
                store.selectedDate = store.today
                store.quickText = quickTaskTitle
                store.addQuickTask()
            }
        }

        let zhulongTaskName = SuntraceStore.commandLineValue(after: "--e2e-generate-zhulong-draft")
        if let zhulongTaskName, let task = ZhulongTask(rawValue: zhulongTaskName) {
            let applyFirstOperation = CommandLine.arguments.contains("--e2e-apply-first-zhulong-operation")
            actions.append { store in
                store.page = .zhulong
                store.zhulongProviderDraft.enabled = true
                store.generateZhulongDraft(task: task)
                guard applyFirstOperation else { return }
                guard let draft = store.zhulongDrafts.first else { return }
                guard draft.proposedOperations.isEmpty == false else { return }
                store.applyZhulongOperation(draftID: draft.id, operationIndex: 0)
            }
        }

        append(ProviderE2EAutomation.fromCommandLine(), to: &actions)
        append(WorkflowE2EAutomation.fromCommandLine(), to: &actions)
        append(LifecycleE2EAutomation.fromCommandLine(), to: &actions)
        append(DataPackageE2EAutomation.fromCommandLine(), to: &actions)
        append(ReviewE2EAutomation.fromCommandLine(), to: &actions)
        append(ReviewZhulongEntryE2EAutomation.fromCommandLine(), to: &actions)
        append(ContextMenuActionsE2EAutomation.fromCommandLine(), to: &actions)
        append(UndoE2EAutomation.fromCommandLine(), to: &actions)
        append(DateStripE2EAutomation.fromCommandLine(), to: &actions)
        append(KeyboardDateNavigationE2EAutomation.fromCommandLine(), to: &actions)
        append(ZhulongNavigationE2EAutomation.fromCommandLine(), to: &actions)
        append(SubtaskMutationE2EAutomation.fromCommandLine(), to: &actions)
        append(SummarySidebarE2EAutomation.fromCommandLine(), to: &actions)
        append(WindowResizeE2EAutomation.fromCommandLine(), to: &actions)
        append(LaunchSelectionE2EAutomation.fromCommandLine(), to: &actions)

        if CommandLine.arguments.contains("--e2e-expand-first-subtask-trace") {
            actions.append { store in
                store.page = .day
                store.selectedDate = store.today
                if let trace = store.engine.getDayTodo(date: store.today).traces.first(where: { store.subtasks(for: $0.id).isEmpty == false }) {
                    store.selectTrace(trace.id)
                    store.expandedTraceIDs.insert(trace.id)
                }
            }
        }

        guard actions.isEmpty == false else { return nil }
        return LaunchAutomation(
            actions: actions,
            quitsAfterAutomation: CommandLine.arguments.contains("--e2e-quit-after-automation")
        )
    }

    @MainActor
    func run(on store: SuntraceStore) {
        actions.forEach { $0(store) }

        if quitsAfterAutomation {
            store.persist()
            NSApp.terminate(nil)
        }
    }

    @MainActor
    private static func append(
        _ automation: (some LaunchAutomationRunnable)?,
        to actions: inout [@MainActor (SuntraceStore) -> Void]
    ) {
        guard let automation else { return }
        actions.append { store in
            automation.run(on: store)
        }
    }
}

private protocol LaunchAutomationRunnable {
    @MainActor
    func run(on store: SuntraceStore)
}

private struct LaunchSelectionE2EAutomation: LaunchAutomationRunnable {
    var selectionName: String

    @MainActor
    static func fromCommandLine() -> LaunchSelectionE2EAutomation? {
        guard let selectionName = SuntraceStore.commandLineValue(after: "--select"),
              ["first", "manual", "changed"].contains(selectionName)
        else {
            return nil
        }
        return LaunchSelectionE2EAutomation(selectionName: selectionName)
    }

    func run(on store: SuntraceStore) {
        store.selectItemForLaunch(selectionName)
    }
}

private struct ReviewE2EAutomation: LaunchAutomationRunnable {
    var summary: String

    @MainActor
    static func fromCommandLine() -> ReviewE2EAutomation? {
        guard CommandLine.arguments.contains("--e2e-update-review") else { return nil }
        return ReviewE2EAutomation(
            summary: SuntraceStore.commandLineValue(after: "--e2e-review-summary") ?? "E2E 自动保存反馈"
        )
    }

    @MainActor
    func run(on store: SuntraceStore) {
        store.page = .day
        store.selectedDate = store.today
        store.updateReview(summary: summary)
    }
}

private struct ReviewZhulongEntryE2EAutomation: LaunchAutomationRunnable {
    var resultURL: URL?

    @MainActor
    static func fromCommandLine() -> ReviewZhulongEntryE2EAutomation? {
        guard CommandLine.arguments.contains("--e2e-review-zhulong-entry") else { return nil }
        let resultURL = SuntraceStore.commandLineValue(after: "--e2e-review-zhulong-result-url")
            .map { URL(fileURLWithPath: $0) }
        return ReviewZhulongEntryE2EAutomation(resultURL: resultURL)
    }

    @MainActor
    func run(on store: SuntraceStore) {
        store.page = .day
        store.selectedDate = store.today
        store.zhulongProviderDraft.enabled = true
        store.requestZhulongDailyReviewFromReviewRail()

        guard store.page == .zhulong,
              store.selectedZhulongDraft?.kind == .dailyReview
        else {
            try? writeResult("failed")
            return
        }

        try? writeResult("ok")
    }

    private func writeResult(_ result: String) throws {
        guard let resultURL else { return }
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

private struct ContextMenuActionsE2EAutomation: LaunchAutomationRunnable {
    var resultURL: URL?

    @MainActor
    static func fromCommandLine() -> ContextMenuActionsE2EAutomation? {
        guard CommandLine.arguments.contains("--e2e-context-menu-actions") else { return nil }
        let resultURL = SuntraceStore.commandLineValue(after: "--e2e-context-menu-result-url")
            .map { URL(fileURLWithPath: $0) }
        return ContextMenuActionsE2EAutomation(resultURL: resultURL)
    }

    @MainActor
    func run(on store: SuntraceStore) {
        do {
            store.engine = SuntraceEngine()
            let today = store.today
            let past = SuntraceStore.offset(today, by: -1)
            let future = SuntraceStore.offset(today, by: 1)

            let currentID = try makeTrace(title: "E2E 当前待完成", date: today, today: today, store: store)
            try assertActions(
                store.contextMenuActions(for: try trace(currentID, in: store)),
                [.markComplete, .continueTo, .changeToNewTask, .returnToPool, .abandonChain],
                "current pending"
            )

            let currentWithSubtasksID = try makeTrace(title: "E2E 当前带子任务", date: today, today: today, store: store)
            _ = try store.engine.addSubtask(traceID: currentWithSubtasksID, title: "子任务")
            try assertActions(
                store.contextMenuActions(for: try trace(currentWithSubtasksID, in: store)),
                [.continueTo, .changeToNewTask, .returnToPool, .abandonChain],
                "current pending with subtasks"
            )

            let completedID = try makeTrace(title: "E2E 当前已完成", date: today, today: today, store: store)
            try store.engine.markCompleted(traceID: completedID, today: today)
            try assertActions(
                store.contextMenuActions(for: try trace(completedID, in: store)),
                [.undoComplete],
                "current completed"
            )

            let historicalUnfinishedID = try makeTrace(title: "E2E 历史未完成", date: past, today: past, store: store)
            store.engine.settleDays(upTo: today)
            try assertActions(
                store.contextMenuActions(for: try trace(historicalUnfinishedID, in: store)),
                [.continueTo, .abandonChain],
                "historical unfinished"
            )

            let historicalCompletedID = try makeTrace(title: "E2E 历史已完成", date: past, today: past, store: store)
            try store.engine.markCompleted(traceID: historicalCompletedID, today: past)
            try assertActions(
                store.contextMenuActions(for: try trace(historicalCompletedID, in: store)),
                [.copyAsNewTask],
                "historical completed"
            )

            let futureID = try makeTrace(title: "E2E 未来待完成", date: future, today: today, store: store)
            try assertActions(
                store.contextMenuActions(for: try trace(futureID, in: store)),
                [.reschedule, .returnToPool],
                "future pending"
            )

            try writeResult("ok")
        } catch {
            try? writeResult("failed: \(error)")
        }
    }

    @MainActor
    private func makeTrace(title: String, date: LocalDate, today: LocalDate, store: SuntraceStore) throws -> DayTraceID {
        let chainID = try store.engine.createPoolTask(title: title)
        return try store.engine.scheduleFromPool(chainID: chainID, date: date, today: today)
    }

    @MainActor
    private func trace(_ id: DayTraceID, in store: SuntraceStore) throws -> DayTrace {
        guard let trace = store.engine.traces[id] else {
            throw ContextMenuActionsE2EAutomationError.missingTrace
        }
        return trace
    }

    private func assertActions(
        _ actual: [SuntraceStore.TraceContextAction],
        _ expected: [SuntraceStore.TraceContextAction],
        _ label: String
    ) throws {
        guard actual == expected else {
            throw ContextMenuActionsE2EAutomationError.actionMismatch(
                label: label,
                expected: expected.map(\.rawValue),
                actual: actual.map(\.rawValue)
            )
        }
    }

    private func writeResult(_ result: String) throws {
        guard let resultURL else { return }
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

private enum ContextMenuActionsE2EAutomationError: LocalizedError {
    case missingTrace
    case actionMismatch(label: String, expected: [String], actual: [String])

    var errorDescription: String? {
        switch self {
        case .missingTrace:
            return "missing trace"
        case let .actionMismatch(label, expected, actual):
            return "\(label) context actions mismatch: expected \(expected), got \(actual)"
        }
    }
}

private struct UndoE2EAutomation: LaunchAutomationRunnable {
    var resultURL: URL?

    @MainActor
    static func fromCommandLine() -> UndoE2EAutomation? {
        guard CommandLine.arguments.contains("--e2e-undo-workflow") else { return nil }
        let resultURL = SuntraceStore.commandLineValue(after: "--e2e-undo-result-url")
            .map { URL(fileURLWithPath: $0) }
        return UndoE2EAutomation(resultURL: resultURL)
    }

    @MainActor
    func run(on store: SuntraceStore) {
        do {
            try verifyPoolAddUndo(on: store)
            try verifyCurrentContinuationUndo(on: store)
            try verifyCurrentAbandonUndo(on: store)
            try verifyFutureRescheduleUndo(on: store)
            try verifyCopyAsNewTaskUndo(on: store)
            try verifyHistoricalAbandonIsNotUndoable(on: store)
            try writeResult("ok")
        } catch {
            try? writeResult("failed: \(error)")
        }
    }

    @MainActor
    private func reset(_ store: SuntraceStore) {
        store.engine = SuntraceEngine()
        store.page = .day
        store.selectedDate = store.today
        store.selectedCalendarDate = store.today
        store.clearSelection()
        store.clearUndoHistory()
    }

    @MainActor
    private func verifyPoolAddUndo(on store: SuntraceStore) throws {
        reset(store)
        store.poolText = "E2E 撤销任务池新增"
        store.addPoolTask()
        guard store.engine.taskPool().count == 1 else {
            throw UndoE2EAutomationError.failed("pool add did not create one task")
        }
        store.undo()
        guard store.engine.taskPool().isEmpty else {
            throw UndoE2EAutomationError.failed("pool add undo did not restore empty pool")
        }
    }

    @MainActor
    private func verifyCurrentContinuationUndo(on store: SuntraceStore) throws {
        reset(store)
        let traceID = try makeTrace(title: "E2E 撤销当前延续", date: store.today, today: store.today, store: store)
        let tomorrow = SuntraceStore.offset(store.today, by: 1)
        store.continueTrace(traceID, to: tomorrow)
        guard store.engine.traces.values.contains(where: { $0.date == tomorrow && $0.status == .pending }) else {
            throw UndoE2EAutomationError.failed("continuation did not create tomorrow trace")
        }
        store.undo()
        guard store.engine.traces.count == 1,
              store.engine.traces[traceID]?.status == .pending
        else {
            throw UndoE2EAutomationError.failed("current continuation undo did not restore source trace")
        }
    }

    @MainActor
    private func verifyCurrentAbandonUndo(on store: SuntraceStore) throws {
        reset(store)
        let traceID = try makeTrace(title: "E2E 撤销当前废弃", date: store.today, today: store.today, store: store)
        store.abandon(traceID)
        guard store.engine.traces[traceID]?.status == .abandoned else {
            throw UndoE2EAutomationError.failed("current abandon did not abandon trace")
        }
        store.undo()
        guard store.engine.traces[traceID]?.status == .pending else {
            throw UndoE2EAutomationError.failed("current abandon undo did not restore pending trace")
        }
    }

    @MainActor
    private func verifyFutureRescheduleUndo(on store: SuntraceStore) throws {
        reset(store)
        let tomorrow = SuntraceStore.offset(store.today, by: 1)
        let nextWeek = SuntraceStore.offset(store.today, by: 7)
        let traceID = try makeTrace(title: "E2E 撤销未来改期", date: tomorrow, today: store.today, store: store)
        store.reschedule(traceID, to: nextWeek)
        guard store.engine.traces[traceID]?.date == nextWeek else {
            throw UndoE2EAutomationError.failed("future reschedule did not change date")
        }
        store.undo()
        guard store.engine.traces[traceID]?.date == tomorrow else {
            throw UndoE2EAutomationError.failed("future reschedule undo did not restore original date")
        }
    }

    @MainActor
    private func verifyCopyAsNewTaskUndo(on store: SuntraceStore) throws {
        reset(store)
        let past = SuntraceStore.offset(store.today, by: -1)
        let traceID = try makeTrace(title: "E2E 撤销复制新任务", date: past, today: past, store: store)
        try store.engine.markCompleted(traceID: traceID, today: past)
        store.copyAsNewTask(traceID)
        guard store.engine.taskPool().count == 1 else {
            throw UndoE2EAutomationError.failed("copy as new task did not create pool task")
        }
        store.undo()
        guard store.engine.taskPool().isEmpty,
              store.engine.traces[traceID]?.status == .completed
        else {
            throw UndoE2EAutomationError.failed("copy as new task undo did not restore completed history")
        }
    }

    @MainActor
    private func verifyHistoricalAbandonIsNotUndoable(on store: SuntraceStore) throws {
        reset(store)
        let past = SuntraceStore.offset(store.today, by: -1)
        let traceID = try makeTrace(title: "E2E 历史废弃不可撤销", date: past, today: past, store: store)
        store.engine.settleDays(upTo: store.today)
        store.abandon(traceID)
        guard store.engine.traces[traceID]?.status == .abandoned else {
            throw UndoE2EAutomationError.failed("historical abandon did not abandon trace")
        }
        store.undo()
        guard store.engine.traces[traceID]?.status == .abandoned else {
            throw UndoE2EAutomationError.failed("historical abandon unexpectedly became undoable")
        }
    }

    @MainActor
    private func makeTrace(title: String, date: LocalDate, today: LocalDate, store: SuntraceStore) throws -> DayTraceID {
        let chainID = try store.engine.createPoolTask(title: title)
        return try store.engine.scheduleFromPool(chainID: chainID, date: date, today: today)
    }

    private func writeResult(_ result: String) throws {
        guard let resultURL else { return }
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

private enum UndoE2EAutomationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

private struct DateStripE2EAutomation: LaunchAutomationRunnable {
    var resultURL: URL?

    @MainActor
    static func fromCommandLine() -> DateStripE2EAutomation? {
        guard CommandLine.arguments.contains("--e2e-date-strip-selection") else { return nil }
        let resultURL = SuntraceStore.commandLineValue(after: "--e2e-date-strip-result-url")
            .map { URL(fileURLWithPath: $0) }
        return DateStripE2EAutomation(resultURL: resultURL)
    }

    @MainActor
    func run(on store: SuntraceStore) {
        do {
            store.page = .day
            store.selectedDate = store.today
            guard store.dateStripDates().count == 14,
                  store.selectedDateStripIndex == 6
            else {
                throw DateStripE2EAutomationError.failed("today index did not match 14-day strip")
            }

            store.selectedDate = SuntraceStore.offset(store.today, by: 1)
            guard store.selectedDateStripIndex == 7 else {
                throw DateStripE2EAutomationError.failed("next-day index did not move by one cell")
            }

            store.selectedDate = SuntraceStore.offset(store.today, by: -6)
            guard store.selectedDateStripIndex == 0 else {
                throw DateStripE2EAutomationError.failed("leading strip date did not map to first cell")
            }

            store.selectedDate = SuntraceStore.offset(store.today, by: 8)
            guard store.selectedDateStripIndex == nil else {
                throw DateStripE2EAutomationError.failed("out-of-strip date unexpectedly had a selection index")
            }

            try writeResult("ok")
        } catch {
            try? writeResult("failed: \(error)")
        }
    }

    private func writeResult(_ result: String) throws {
        guard let resultURL else { return }
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

private enum DateStripE2EAutomationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

private struct KeyboardDateNavigationE2EAutomation: LaunchAutomationRunnable {
    var resultURL: URL?

    @MainActor
    static func fromCommandLine() -> KeyboardDateNavigationE2EAutomation? {
        guard CommandLine.arguments.contains("--e2e-keyboard-date-navigation") else { return nil }
        let resultURL = SuntraceStore.commandLineValue(after: "--e2e-keyboard-date-result-url")
            .map { URL(fileURLWithPath: $0) }
        return KeyboardDateNavigationE2EAutomation(resultURL: resultURL)
    }

    @MainActor
    func run(on store: SuntraceStore) {
        do {
            try verifyDayTodoNavigation(on: store)
            try verifyCalendarNavigation(on: store)
            try writeResult("ok")
        } catch {
            try? writeResult("failed: \(error)")
        }
    }

    @MainActor
    private func verifyDayTodoNavigation(on store: SuntraceStore) throws {
        store.page = .day
        store.selectedDate = store.today
        store.moveSelectedDate(.right)
        try expect(store.selectedDate == SuntraceStore.offset(store.today, by: 1), "day right arrow did not move by one day")
        store.moveSelectedDate(.left)
        try expect(store.selectedDate == store.today, "day left arrow did not return to today")
        store.moveSelectedDate(.down)
        try expect(store.selectedDate == SuntraceStore.offset(store.today, by: 7), "day down arrow did not move by one week")
        store.moveSelectedDate(.up)
        try expect(store.selectedDate == store.today, "day up arrow did not return to today")
    }

    @MainActor
    private func verifyCalendarNavigation(on store: SuntraceStore) throws {
        store.page = .calendar
        store.selectedCalendarDate = store.today
        store.moveSelectedDate(.right)
        try expect(store.selectedCalendarDate == SuntraceStore.offset(store.today, by: 1), "calendar right arrow did not move by one day")
        store.moveSelectedDate(.left)
        try expect(store.selectedCalendarDate == store.today, "calendar left arrow did not return to today")
        store.moveSelectedDate(.down)
        try expect(store.selectedCalendarDate == SuntraceStore.offset(store.today, by: 7), "calendar down arrow did not move by one week")
        store.moveSelectedDate(.up)
        try expect(store.selectedCalendarDate == store.today, "calendar up arrow did not return to today")
    }

    private func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw KeyboardDateNavigationE2EAutomationError.failed(message) }
    }

    private func writeResult(_ result: String) throws {
        guard let resultURL else { return }
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

private enum KeyboardDateNavigationE2EAutomationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

private struct ZhulongNavigationE2EAutomation: LaunchAutomationRunnable {
    var resultURL: URL?

    @MainActor
    static func fromCommandLine() -> ZhulongNavigationE2EAutomation? {
        guard CommandLine.arguments.contains("--e2e-zhulong-navigation") else { return nil }
        let resultURL = SuntraceStore.commandLineValue(after: "--e2e-zhulong-navigation-result-url")
            .map { URL(fileURLWithPath: $0) }
        return ZhulongNavigationE2EAutomation(resultURL: resultURL)
    }

    @MainActor
    func run(on store: SuntraceStore) {
        do {
            store.zhulongProviderDraft.enabled = false
            store.ensureVisiblePage()
            try expect(store.visibleNavigationPages.contains(.zhulong) == false, "disabled zhulong remained visible")
            store.selectPage(.zhulong)
            try expect(store.page == .day, "disabled zhulong selection did not fall back to Day Todo")

            store.zhulongProviderDraft.enabled = true
            try expect(store.visibleNavigationPages.contains(.zhulong), "enabled zhulong was not visible")
            store.selectPage(.zhulong)
            try expect(store.page == .zhulong, "enabled zhulong selection did not open the page")

            store.zhulongProviderDraft.enabled = false
            store.ensureVisiblePage()
            try expect(store.visibleNavigationPages.contains(.zhulong) == false, "disabled zhulong remained visible after closing")
            try expect(store.page == .day, "closing zhulong while active did not move to Day Todo")

            try writeResult("ok")
        } catch {
            try? writeResult("failed: \(error.localizedDescription)")
        }
    }

    private func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ZhulongNavigationE2EAutomationError.failed(message) }
    }

    private func writeResult(_ result: String) throws {
        guard let resultURL else { return }
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

private enum ZhulongNavigationE2EAutomationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

private struct SubtaskMutationE2EAutomation: LaunchAutomationRunnable {
    var resultURL: URL?

    @MainActor
    static func fromCommandLine() -> SubtaskMutationE2EAutomation? {
        guard CommandLine.arguments.contains("--e2e-subtask-mutation") else { return nil }
        let resultURL = SuntraceStore.commandLineValue(after: "--e2e-subtask-mutation-result-url")
            .map { URL(fileURLWithPath: $0) }
        return SubtaskMutationE2EAutomation(resultURL: resultURL)
    }

    @MainActor
    func run(on store: SuntraceStore) {
        do {
            store.page = .day
            store.selectedDate = store.today
            guard let trace = store.engine.getDayTodo(date: store.today).traces.first(where: { store.subtasks(for: $0.id).contains { $0.status == .pending } }),
                  let subtask = store.subtasks(for: trace.id).first(where: { $0.status == .pending })
            else {
                throw SubtaskMutationE2EAutomationError.failed("missing current pending subtask")
            }

            store.selectTrace(trace.id)
            store.toggleSubtask(subtask.id)
            try expect(store.engine.subtasks[subtask.id]?.status == .completed, "subtask did not complete")
            try expect(store.engine.subtasks[subtask.id]?.completedAt != nil, "completedAt was not recorded")

            store.toggleSubtask(subtask.id)
            try expect(store.engine.subtasks[subtask.id]?.status == .pending, "subtask did not undo completion")
            try expect(store.engine.subtasks[subtask.id]?.completedAt == nil, "completedAt was not cleared")

            store.setSubtaskDifficulty(subtask.id, difficulty: .hard)
            try expect(store.engine.subtasks[subtask.id]?.difficulty == .hard, "subtask difficulty did not update")

            try writeResult("ok")
        } catch {
            try? writeResult("failed: \(error.localizedDescription)")
        }
    }

    private func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw SubtaskMutationE2EAutomationError.failed(message) }
    }

    private func writeResult(_ result: String) throws {
        guard let resultURL else { return }
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

private enum SubtaskMutationE2EAutomationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

private struct WindowResizeE2EAutomation: LaunchAutomationRunnable {
    var resultURL: URL?

    @MainActor
    static func fromCommandLine() -> WindowResizeE2EAutomation? {
        guard CommandLine.arguments.contains("--e2e-window-resize-probe") else { return nil }
        let resultURL = SuntraceStore.commandLineValue(after: "--e2e-window-resize-result-url")
            .map { URL(fileURLWithPath: $0) }
        return WindowResizeE2EAutomation(resultURL: resultURL)
    }

    @MainActor
    func run(on store: SuntraceStore) {
        do {
            guard let window = NSApp.windows.first(where: { $0 is SuntraceWindow }) else {
                throw WindowResizeE2EAutomationError.failed("missing SuntraceWindow")
            }
            guard window.styleMask.contains(.resizable) else {
                throw WindowResizeE2EAutomationError.failed("window was not resizable")
            }
            guard window.minSize.width >= 1180, window.minSize.height >= 760 else {
                throw WindowResizeE2EAutomationError.failed("window minSize was not preserved")
            }

            let originalFrame = window.frame
            let resizedFrame = NSRect(
                x: originalFrame.minX,
                y: originalFrame.maxY - 800,
                width: 1240,
                height: 800
            )
            window.setFrame(resizedFrame, display: true)
            guard Int(window.frame.width.rounded()) == 1240,
                  Int(window.frame.height.rounded()) == 800
            else {
                throw WindowResizeE2EAutomationError.failed("window frame did not resize")
            }

            window.zoom(nil)
            guard window.frame != resizedFrame else {
                throw WindowResizeE2EAutomationError.failed("window zoom did not change frame")
            }
            window.setFrame(originalFrame, display: true)

            try writeResult("ok")
        } catch {
            try? writeResult("failed: \(error.localizedDescription)")
        }
    }

    private func writeResult(_ result: String) throws {
        guard let resultURL else { return }
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

private enum WindowResizeE2EAutomationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

private struct SummarySidebarE2EAutomation: LaunchAutomationRunnable {
    var resultURL: URL?

    @MainActor
    static func fromCommandLine() -> SummarySidebarE2EAutomation? {
        guard CommandLine.arguments.contains("--e2e-summary-sidebar-probe") else { return nil }
        let resultURL = SuntraceStore.commandLineValue(after: "--e2e-summary-sidebar-result-url")
            .map { URL(fileURLWithPath: $0) }
        return SummarySidebarE2EAutomation(resultURL: resultURL)
    }

    @MainActor
    func run(on store: SuntraceStore) {
        do {
            store.page = .pool
            store.clearSelection()
            store.zhulongProviderDraft.enabled = false
            guard store.shouldShowDetailRail == false else {
                throw SummarySidebarE2EAutomationError.failed("pool rail stayed visible while zhulong was disabled")
            }

            store.zhulongProviderDraft.enabled = true
            for page in [SuntraceStore.Page.pool, .future, .unfinished, .completed] {
                store.page = page
                store.clearSelection()
                guard store.usesZhulongContextRail, store.shouldShowDetailRail else {
                    throw SummarySidebarE2EAutomationError.failed("\(page.rawValue) zhulong context rail was unavailable")
                }
            }

            store.zhulongProviderDraft.enabled = false
            store.page = .pool
            if let task = store.engine.taskPool().first {
                store.selectPool(task.chain.id)
            }
            guard store.hasActiveDetailSelection, store.shouldShowDetailRail else {
                throw SummarySidebarE2EAutomationError.failed("selection detail rail did not override zhulong gating")
            }

            store.page = .calendar
            store.selectedCalendarDate = store.today
            let insight = CalendarDayInsight.make(for: store.selectedCalendarDate, store: store)
            guard insight.hasEnhancedContent else {
                throw SummarySidebarE2EAutomationError.failed("calendar day insight was empty")
            }

            try writeResult("ok")
        } catch {
            try? writeResult("failed: \(error)")
        }
    }

    private func writeResult(_ result: String) throws {
        guard let resultURL else { return }
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

private enum SummarySidebarE2EAutomationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

private struct DataPackageE2EAutomation: LaunchAutomationRunnable {
    var exportURL: URL
    var resultURL: URL?

    @MainActor
    static func fromCommandLine() -> DataPackageE2EAutomation? {
        guard CommandLine.arguments.contains("--e2e-data-package-workflow"),
              let exportPath = SuntraceStore.commandLineValue(after: "--e2e-data-package-url")
        else {
            return nil
        }
        let resultURL = SuntraceStore.commandLineValue(after: "--e2e-data-package-result-url")
            .map { URL(fileURLWithPath: $0) }
        return DataPackageE2EAutomation(
            exportURL: URL(fileURLWithPath: exportPath),
            resultURL: resultURL
        )
    }

    @MainActor
    func run(on store: SuntraceStore) {
        do {
            let title = "E2E 数据包任务"
            let chainID = try store.engine.createPoolTask(title: title, descriptionText: "E2E 数据包导出导入路径。")
            _ = try store.engine.scheduleFromPool(chainID: chainID, date: store.today, today: store.today)
            store.updateReview(
                summary: "E2E 数据包导出前复盘。",
                reason: "验证 App 导入导出。",
                tomorrow: "导入后继续检查。"
            )

            try store.exportDataPackage(to: exportURL)

            store.engine = SuntraceEngine()
            try store.importDataPackage(from: exportURL)

            try writeResult("ok")
        } catch {
            try? writeResult("failed: \(error.localizedDescription)")
        }
    }

    private func writeResult(_ result: String) throws {
        guard let resultURL else { return }
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

private struct LifecycleE2EAutomation: LaunchAutomationRunnable {
    var resultURL: URL?

    @MainActor
    static func fromCommandLine() -> LifecycleE2EAutomation? {
        guard CommandLine.arguments.contains("--e2e-lifecycle-workflow") else { return nil }
        let resultURL = SuntraceStore.commandLineValue(after: "--e2e-lifecycle-result-url")
            .map { URL(fileURLWithPath: $0) }
        return LifecycleE2EAutomation(resultURL: resultURL)
    }

    @MainActor
    func run(on store: SuntraceStore) {
        do {
            try runChangeFlow(on: store)
            try runReturnToPoolFlow(on: store)
            try runAbandonFlow(on: store)
            try writeResult("ok")
        } catch {
            try? writeResult("failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func runChangeFlow(on store: SuntraceStore) throws {
        let oldTitle = "E2E 变更旧任务"
        let newTitle = "E2E 变更新任务"
        let chainID = try store.engine.createPoolTask(title: oldTitle, descriptionText: "E2E 变更路径。")
        let traceID = try store.engine.scheduleFromPool(chainID: chainID, date: store.today, today: store.today)
        store.selectTrace(traceID)
        store.changeText = newTitle
        store.changeSelectedTrace()
        guard let oldTrace = store.engine.traces[traceID] else {
            throw LifecycleE2EAutomationError.failed("changed source trace missing")
        }
        guard let target = store.changedTarget(for: oldTrace),
              target.definition.title == newTitle
        else {
            throw LifecycleE2EAutomationError.failed("changed target did not resolve to new task title")
        }
        store.openChangedTarget(from: oldTrace)
        guard store.selectedTraceID == target.trace.id,
              store.selectedDate == target.trace.date
        else {
            throw LifecycleE2EAutomationError.failed("changed target jump did not select new trace")
        }
    }

    @MainActor
    private func runReturnToPoolFlow(on store: SuntraceStore) throws {
        let chainID = try store.engine.createPoolTask(title: "E2E 回池任务", descriptionText: "E2E 回池路径。")
        let traceID = try store.engine.scheduleFromPool(chainID: chainID, date: store.today, today: store.today)
        store.returnToPool(traceID)
    }

    @MainActor
    private func runAbandonFlow(on store: SuntraceStore) throws {
        let chainID = try store.engine.createPoolTask(title: "E2E 废弃任务", descriptionText: "E2E 废弃路径。")
        let traceID = try store.engine.scheduleFromPool(chainID: chainID, date: store.today, today: store.today)
        let traceCount = store.engine.traces.count
        store.abandon(traceID)
        guard let item = store.engine.unfinishedPool().first(where: { $0.chain.id == chainID }),
              item.chain.state == .abandoned,
              item.unfinishedTraces.contains(where: { $0.id == traceID && $0.status == .abandoned })
        else {
            throw LifecycleE2EAutomationError.failed("abandoned chain did not remain visible in unfinished pool")
        }
        store.reactivateAbandonedChain(from: traceID)
        guard store.engine.chains[chainID]?.state == .active,
              store.engine.traces[traceID]?.status == .pending,
              store.engine.traces.count == traceCount
        else {
            throw LifecycleE2EAutomationError.failed("abandoned chain reactivation did not clear the abandoned marker in place")
        }
    }

    private func writeResult(_ result: String) throws {
        guard let resultURL else { return }
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

private enum LifecycleE2EAutomationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

private struct WorkflowE2EAutomation: LaunchAutomationRunnable {
    var title: String
    var resultURL: URL?

    @MainActor
    static func fromCommandLine() -> WorkflowE2EAutomation? {
        guard CommandLine.arguments.contains("--e2e-domain-workflow") else { return nil }
        let title = SuntraceStore.commandLineValue(after: "--e2e-workflow-title") ?? "E2E 排期延续复盘"
        let resultURL = SuntraceStore.commandLineValue(after: "--e2e-workflow-result-url")
            .map { URL(fileURLWithPath: $0) }
        return WorkflowE2EAutomation(title: title, resultURL: resultURL)
    }

    @MainActor
    func run(on store: SuntraceStore) {
        do {
            let tomorrow = SuntraceStore.offset(store.today, by: 1)

            store.page = .pool
            store.poolText = title
            store.addPoolTask()
            guard let chainID = store.selectedPoolChainID else {
                throw WorkflowE2EAutomationError.missing("pool chain")
            }

            store.schedulePoolTask(chainID, date: store.today)
            guard let todayTraceID = store.selectedTraceID else {
                throw WorkflowE2EAutomationError.missing("scheduled trace")
            }

            store.continueTrace(todayTraceID, to: tomorrow)
            guard store.selectedTraceID != todayTraceID else {
                throw WorkflowE2EAutomationError.missing("continued trace")
            }

            store.selectedDate = store.today
            store.updateReview(
                summary: "E2E 已完成排期、延续和复盘写入。",
                reason: "验证真实 App workflow 自动化。",
                tomorrow: "明天检查延续任务。"
            )

            try writeResult("ok")
        } catch {
            try? writeResult("failed: \(error.localizedDescription)")
        }
    }

    private func writeResult(_ result: String) throws {
        guard let resultURL else { return }
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

private enum WorkflowE2EAutomationError: LocalizedError {
    case missing(String)

    var errorDescription: String? {
        switch self {
        case let .missing(value):
            return "Workflow E2E missing: \(value)"
        }
    }
}

private struct ProviderE2EAutomation: LaunchAutomationRunnable {
    var expectedName: String
    var expectedBaseURL: String
    var expectedModel: String
    var expectedAPIKey: String
    var shouldConfigure: Bool
    var shouldVerify: Bool
    var resultURL: URL?

    @MainActor
    static func fromCommandLine() -> ProviderE2EAutomation? {
        let shouldConfigure = CommandLine.arguments.contains("--e2e-configure-provider")
        let shouldVerify = CommandLine.arguments.contains("--e2e-verify-provider")
        guard shouldConfigure || shouldVerify else { return nil }

        let expectedName = SuntraceStore.commandLineValue(after: "--e2e-provider-name") ?? ""
        let expectedBaseURL = SuntraceStore.commandLineValue(after: "--e2e-provider-base-url") ?? ""
        let expectedModel = SuntraceStore.commandLineValue(after: "--e2e-provider-model") ?? ""
        let expectedAPIKey = SuntraceStore.commandLineValue(after: "--e2e-provider-api-key") ?? ""
        let resultURL = SuntraceStore.commandLineValue(after: "--e2e-provider-result-url")
            .map { URL(fileURLWithPath: $0) }

        return ProviderE2EAutomation(
            expectedName: expectedName,
            expectedBaseURL: expectedBaseURL,
            expectedModel: expectedModel,
            expectedAPIKey: expectedAPIKey,
            shouldConfigure: shouldConfigure,
            shouldVerify: shouldVerify,
            resultURL: resultURL
        )
    }

    @MainActor
    func run(on store: SuntraceStore) {
        do {
            if shouldConfigure {
                try configureProvider(on: store)
            }
            if shouldVerify {
                try verifyProvider(on: store)
                store.zhulongProviderDraft = try ZhulongProviderSettingsStore.clear()
            }
            try writeResult("ok")
        } catch {
            if shouldVerify {
                store.zhulongProviderDraft = (try? ZhulongProviderSettingsStore.clear()) ?? ZhulongProviderDraft()
            }
            try? writeResult("failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func configureProvider(on store: SuntraceStore) throws {
        store.zhulongProviderDraft = try ZhulongProviderSettingsStore.clear()
        store.zhulongProviderDraft.displayName = expectedName
        store.zhulongProviderDraft.kind = .openAICompatible
        store.zhulongProviderDraft.baseURL = expectedBaseURL
        store.zhulongProviderDraft.model = expectedModel
        store.zhulongProviderDraft.apiKeyInput = expectedAPIKey
        store.zhulongProviderDraft.enabled = true
        store.zhulongProviderDraft = try ZhulongProviderSettingsStore.save(store.zhulongProviderDraft)
    }

    @MainActor
    private func verifyProvider(on store: SuntraceStore) throws {
        let draft = store.zhulongProviderDraft
        guard draft.displayName == expectedName else {
            throw ProviderE2EAutomationError.mismatch("displayName")
        }
        guard draft.normalizedBaseURL?.absoluteString == URL(string: expectedBaseURL)?.absoluteString else {
            throw ProviderE2EAutomationError.mismatch("baseURL")
        }
        guard draft.model == expectedModel else {
            throw ProviderE2EAutomationError.mismatch("model")
        }
        guard draft.enabled else {
            throw ProviderE2EAutomationError.mismatch("enabled")
        }
        guard draft.hasStoredAPIKey else {
            throw ProviderE2EAutomationError.mismatch("hasStoredAPIKey")
        }
        guard try ZhulongProviderKeychain.readAPIKey() == expectedAPIKey else {
            throw ProviderE2EAutomationError.mismatch("apiKey")
        }
    }

    private func writeResult(_ result: String) throws {
        guard let resultURL else { return }
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

private enum ProviderE2EAutomationError: LocalizedError {
    case mismatch(String)

    var errorDescription: String? {
        switch self {
        case let .mismatch(field):
            return "Provider E2E mismatch: \(field)"
        }
    }
}

final class SuntraceWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    override var canBecomeMain: Bool { true }
}

@MainActor
final class SuntraceStore: ObservableObject {
    enum TraceContextAction: String, Equatable {
        case markComplete
        case undoComplete
        case continueTo
        case changeToNewTask
        case returnToPool
        case reschedule
        case copyAsNewTask
        case abandonChain
    }

    enum Page: String, CaseIterable, Identifiable {
        case day
        case pool
        case future
        case unfinished
        case completed
        case calendar
        case zhulong
        case settings

        var id: String { rawValue }

        var navigationSystemImage: String {
            switch self {
            case .day:
                return "clock"
            case .pool:
                return "tray"
            case .future:
                return "calendar.badge.clock"
            case .unfinished:
                return "exclamationmark.circle"
            case .completed:
                return "checkmark.seal"
            case .calendar:
                return "calendar"
            case .zhulong:
                return "sparkles"
            case .settings:
                return "gearshape"
            }
        }

        var navigationIconColor: Color {
            switch self {
            case .day:
                return Theme.navDay
            case .pool:
                return Theme.navPool
            case .future:
                return Theme.navFuture
            case .unfinished:
                return Theme.navUnfinished
            case .completed:
                return Theme.navCompleted
            case .calendar:
                return Theme.navCalendar
            case .zhulong:
                return Theme.navZhulong
            case .settings:
                return Theme.navSettings
            }
        }

        init?(commandLineValue: String) {
            switch commandLineValue {
            case "day", "dayTodo":
                self = .day
            case "pool", "taskPool":
                self = .pool
            case "future", "futurePlans":
                self = .future
            case "unfinished", "unfinishedPool":
                self = .unfinished
            case "completed", "completedPool":
                self = .completed
            case "calendar":
                self = .calendar
            case "zhulong", "ai":
                self = .zhulong
            case "settings":
                self = .settings
            default:
                return nil
            }
        }
    }

    enum DatePickerPurpose {
        case gotoDay
        case schedulePool(TaskChainID)
        case scheduleSelectedPool
        case continueTrace(DayTraceID)
        case reschedule(DayTraceID)

        var title: String {
            switch self {
            case .gotoDay:
                return "跳转到日期"
            case .schedulePool, .scheduleSelectedPool:
                return "排期到哪一天？"
            case .continueTrace:
                return "延续到哪一天？"
            case .reschedule:
                return "改到哪个未来日期？"
            }
        }

        var allowsPastDates: Bool {
            if case .gotoDay = self { return true }
            return false
        }

        var futureOnly: Bool {
            if case .reschedule = self { return true }
            return false
        }

        var rangeHint: String {
            switch self {
            case .gotoDay:
                return "可选范围：今天前 7 天到今天后 21 天。"
            case .schedulePool, .scheduleSelectedPool:
                return "任务池只能排期到今天或未来；当前可选今天到 21 天后。"
            case .continueTrace:
                return "延续只能选择今天或未来；当前可选今天到 21 天后。"
            case .reschedule:
                return "未来计划只能改到未来日期；当前可选明天到 21 天后。"
            }
        }
    }

    struct DateChoice: Identifiable {
        let id = UUID()
        let date: LocalDate
        let label: String
        let subtitle: String
    }

    @Published var engine = SuntraceEngine()
    @Published var page: Page = .day
    @Published var selectedDate = LocalDate("2026-07-05")
    @Published var selectedCalendarDate = LocalDate("2026-07-05")
    @Published var selectedTraceID: DayTraceID?
    @Published var selectedPoolChainID: TaskChainID?
    @Published var selectedUnfinishedChainID: TaskChainID?
    @Published var selectedCompletedTraceID: DayTraceID?
    @Published var selectedCompletedSubtaskID: SubtaskID?
    @Published var expandedTraceIDs: Set<DayTraceID> = []
    @Published var expandedUnfinishedChainIDs: Set<TaskChainID> = []
    @Published var quickText = ""
    @Published var poolText = ""
    @Published var showingPicker: DatePickerPurpose?
    @Published var showingFromPoolPicker = false
    @Published var showingChangeDialog = false
    @Published var changeText = ""
    @Published var detailSubtaskText = ""
    @Published var detailNoteText = ""
    @Published var toast: String?
    @Published var zhulongProviderDraft = ZhulongProviderSettingsStore.load()
    @Published var zhulongDrafts: [AISuggestionDraft] = []
    @Published var selectedZhulongDraftID: AISuggestionDraftID?
    @Published var appliedZhulongOperationKeys: Set<String> = []
    @Published var reviewAutosaveMessage: String?
    @Published var isLocalFirstSyncing = false
    @Published var localFirstSyncMessage: String?

    let today = LocalDate("2026-07-05")
    private let repository: SQLiteEngineRepository?
    private let databaseURL: URL?
    private let syncDeviceID: SyncDeviceID?
    private var toastTask: Task<Void, Never>?
    private var localFirstSyncAutomationTask: Task<Void, Never>?
    private var undoStack: [SuntraceSnapshot] = []

    init() {
        if CommandLine.arguments.contains("--ephemeral") {
            repository = nil
            databaseURL = nil
            syncDeviceID = nil
            seed()
        } else {
            let configuredDatabaseURL = Self.configuredDatabaseURL()
            databaseURL = configuredDatabaseURL
            repository = SQLiteEngineRepository(databaseURL: configuredDatabaseURL)
            syncDeviceID = Self.loadOrCreateSyncDeviceID(databaseURL: configuredDatabaseURL)
            loadOrSeed()
        }
        Theme.apply(engine.preferences.theme)
        restartLocalFirstSyncAutomation()
    }

    deinit {
        toastTask?.cancel()
        localFirstSyncAutomationTask?.cancel()
    }

    var isHistory: Bool {
        selectedDate < today
    }

    var isFuture: Bool {
        selectedDate > today
    }

    var selectedTrace: DayTrace? {
        guard let selectedTraceID else { return nil }
        return engine.traces[selectedTraceID]
    }

    var selectedDefinition: TaskDefinition? {
        guard let selectedTrace else { return nil }
        return engine.definitions[selectedTrace.definitionID]
    }

    var selectedPoolTask: PoolTask? {
        guard let selectedPoolChainID else { return nil }
        return engine.taskPool().first { $0.chain.id == selectedPoolChainID }
    }

    func currentDefinition(for chainID: TaskChainID) -> TaskDefinition? {
        engine.definitions.values.first {
            $0.chainID == chainID && $0.supersededAt == nil
        }
    }

    var selectedCompletedItem: CompletedPoolItem? {
        guard let selectedCompletedTraceID else { return nil }
        return engine.completedPool().first { $0.trace.id == selectedCompletedTraceID }
    }

    var selectedCompletedSubtaskRecord: CompletedSubtaskRecord? {
        guard let selectedCompletedSubtaskID else { return nil }
        return engine.completedSubtaskRecords().first { $0.subtask.id == selectedCompletedSubtaskID }
    }

    var selectedUnfinishedItem: UnfinishedPoolItem? {
        guard let selectedUnfinishedChainID else { return nil }
        return engine.unfinishedPool().first { $0.chain.id == selectedUnfinishedChainID }
    }

    var selectedZhulongDraft: AISuggestionDraft? {
        guard let selectedZhulongDraftID else { return zhulongDrafts.first }
        return zhulongDrafts.first { $0.id == selectedZhulongDraftID }
    }

    var isZhulongEnabled: Bool {
        zhulongProviderDraft.enabled
    }

    var hasActiveDetailSelection: Bool {
        if selectedPoolTask != nil || selectedUnfinishedItem != nil || selectedCompletedItem != nil || selectedCompletedSubtaskRecord != nil {
            return true
        }
        return selectedTrace != nil && selectedDefinition != nil
    }

    var usesZhulongContextRail: Bool {
        isZhulongEnabled
            && hasActiveDetailSelection == false
            && [.pool, .future, .unfinished, .completed].contains(page)
    }

    var shouldShowDetailRail: Bool {
        guard page != .calendar && page != .settings else { return false }
        if page == .zhulong || hasActiveDetailSelection {
            return true
        }
        if page == .day {
            return true
        }
        return usesZhulongContextRail
    }

    var visibleNavigationPages: [Page] {
        var pages: [Page] = [.day, .pool, .future, .unfinished, .completed, .calendar]
        if isZhulongEnabled {
            pages.append(.zhulong)
        }
        pages.append(.settings)
        return pages
    }

    var copy: AppCopy {
        AppCopy(language: engine.preferences.language)
    }

    var windowTitle: String {
        switch page {
        case .day:
            return "\(copy.appName) · \(copy.navDay) — \(Self.displayDate(selectedDate))"
        case .calendar:
            return "\(copy.appName) · \(copy.navCalendar) — \(Self.displayDate(selectedCalendarDate))"
        default:
            return "\(copy.appName) · \(windowPageTitle)"
        }
    }

    private var windowPageTitle: String {
        switch page {
        case .day:
            return copy.navDay
        case .pool:
            return copy.navPool
        case .future:
            return copy.navFuture
        case .unfinished:
            return copy.navUnfinished
        case .completed:
            return copy.navCompleted
        case .calendar:
            return copy.navCalendar
        case .zhulong:
            return copy.navZhulong
        case .settings:
            return copy.navSettings
        }
    }

    func navigationLabel(for page: Page) -> String {
        switch page {
        case .day:
            return copy.navDay
        case .pool:
            return copy.navPool
        case .future:
            return copy.navFuture
        case .unfinished:
            return copy.navUnfinished
        case .completed:
            return copy.navCompleted
        case .calendar:
            return copy.navCalendar
        case .zhulong:
            return copy.navZhulong
        case .settings:
            return copy.navSettings
        }
    }

    func navigationCount(for page: Page) -> Int {
        switch page {
        case .day:
            return engine.getDayTodo(date: today).traces.filter { $0.status == .pending }.count
        case .pool:
            return engine.taskPool().count
        case .future:
            return engine.futurePlans(today: today).count
        case .unfinished:
            return engine.unfinishedPool().count
        case .completed:
            return engine.completedPool().count + engine.completedSubtaskRecords().count
        case .calendar, .zhulong, .settings:
            return 0
        }
    }

    func definition(for trace: DayTrace) -> TaskDefinition? {
        engine.definitions[trace.definitionID]
    }

    func subtasks(for traceID: DayTraceID) -> [Subtask] {
        engine.subtasks.values
            .filter { $0.traceID == traceID }
            .sorted { $0.position < $1.position }
    }

    func contextMenuActions(for trace: DayTrace) -> [TraceContextAction] {
        if trace.date == today, trace.status == .pending {
            var actions: [TraceContextAction] = []
            if chainHasSubtasks(trace.chainID) == false {
                actions.append(.markComplete)
            }
            actions.append(contentsOf: [.continueTo, .changeToNewTask, .returnToPool, .abandonChain])
            return actions
        }

        if trace.date == today, trace.status == .completed {
            return chainHasSubtasks(trace.chainID) ? [] : [.undoComplete]
        }

        let canContinueHistoricalUnfinished = trace.date < today
            && trace.status == .unfinished
            && chainIsActive(trace.chainID)
            && activeTrace(for: trace.chainID) == nil
        if canContinueHistoricalUnfinished {
            return [.continueTo, .abandonChain]
        }

        if trace.date < today, trace.status == .completed {
            return [.copyAsNewTask]
        }

        if trace.date > today, trace.status == .pending {
            return [.reschedule, .returnToPool]
        }

        return []
    }

    private func chainHasSubtasks(_ chainID: TaskChainID) -> Bool {
        let traceIDs = Set(engine.traces.values.filter { $0.chainID == chainID }.map(\.id))
        return engine.subtasks.values.contains { traceIDs.contains($0.traceID) }
    }

    private func chainIsActive(_ chainID: TaskChainID) -> Bool {
        engine.chains[chainID]?.state == .active
    }

    private func activeTrace(for chainID: TaskChainID) -> DayTrace? {
        engine.traces.values.first { $0.chainID == chainID && $0.status == .pending }
    }

    func dateChoices(allowPast: Bool = false, futureOnly: Bool = false) -> [DateChoice] {
        (-7...21).compactMap { offset in
            let date = Self.offset(today, by: offset)
            if futureOnly, date <= today { return nil }
            if allowPast == false, date < today { return nil }
            return DateChoice(date: date, label: Self.displayDate(date), subtitle: Self.weekday(date))
        }
    }

    func dateStripDates() -> [LocalDate] {
        (-6...7).map { Self.offset(today, by: $0) }
    }

    var selectedDateStripIndex: Int? {
        dateStripDates().firstIndex(of: selectedDate)
    }

    func moveSelectedDate(_ direction: MoveCommandDirection) {
        guard showingPicker == nil,
              showingFromPoolPicker == false,
              showingChangeDialog == false
        else {
            return
        }

        let days: Int
        switch direction {
        case .left:
            days = -1
        case .right:
            days = 1
        case .up:
            days = -7
        case .down:
            days = 7
        @unknown default:
            return
        }

        switch page {
        case .day:
            selectedDate = Self.offset(selectedDate, by: days)
        case .calendar:
            selectedCalendarDate = Self.offset(selectedCalendarDate, by: days)
        case .pool, .future, .unfinished, .completed, .zhulong, .settings:
            return
        }
    }

    func continuationDurationDays(for trace: DayTrace) -> Int {
        let chainDates = engine.traces.values
            .filter { $0.chainID == trace.chainID }
            .map(\.date)
        guard let startDate = chainDates.min() else { return 1 }
        let days = Calendar.current.dateComponents(
            [.day],
            from: Self.gregorianDate(startDate),
            to: Self.gregorianDate(trace.date)
        ).day ?? 0
        return max(1, days + 1)
    }

    func selectPage(_ next: Page) {
        page = visiblePage(for: next)
        clearSelection()
    }

    func ensureVisiblePage(preferredFallback: Page = .day) {
        let next = visiblePage(for: page, preferredFallback: preferredFallback)
        guard next != page else { return }
        page = next
        clearSelection()
    }

    private func visiblePage(for requested: Page, preferredFallback: Page = .day) -> Page {
        guard requested != .zhulong || isZhulongEnabled else {
            return preferredFallback == .zhulong ? .day : preferredFallback
        }
        return requested
    }

    func selectTrace(_ traceID: DayTraceID) {
        selectedTraceID = traceID
        selectedPoolChainID = nil
        selectedUnfinishedChainID = nil
        selectedCompletedTraceID = nil
        selectedCompletedSubtaskID = nil
        detailSubtaskText = ""
    }

    func changedTarget(for trace: DayTrace) -> (trace: DayTrace, definition: TaskDefinition)? {
        guard let targetTraceID = trace.changedToTraceID,
              let targetTrace = engine.traces[targetTraceID],
              let targetDefinition = engine.definitions[targetTrace.definitionID]
        else {
            return nil
        }
        return (targetTrace, targetDefinition)
    }

    func openChangedTarget(from trace: DayTrace) {
        guard let target = changedTarget(for: trace) else { return }
        page = .day
        selectedDate = target.trace.date
        selectedCalendarDate = target.trace.date
        selectTrace(target.trace.id)
    }

    func selectPool(_ chainID: TaskChainID) {
        selectedPoolChainID = chainID
        selectedTraceID = nil
        selectedUnfinishedChainID = nil
        selectedCompletedTraceID = nil
        selectedCompletedSubtaskID = nil
        detailSubtaskText = ""
    }

    func tag(for tagID: TaskTagID) -> TaskTag? {
        engine.preferences.taskTags.first { $0.id == tagID }
    }

    func tags(for chain: TaskChain) -> [(assignment: TaskTagAssignment, tag: TaskTag)] {
        chain.tagAssignments.compactMap { assignment in
            tag(for: assignment.tagID).map { (assignment, $0) }
        }
        .sorted { $0.assignment.slot < $1.assignment.slot }
    }

    func tags(for chainID: TaskChainID) -> [(assignment: TaskTagAssignment, tag: TaskTag)] {
        guard let chain = engine.chains[chainID] else { return [] }
        return tags(for: chain)
    }

    func primaryTagName(for chain: TaskChain) -> String {
        guard let tagID = chain.primaryTagID, let tag = tag(for: tagID) else {
            return "未标记"
        }
        return tag.name
    }

    func appendInlineTag(chainID: TaskChainID, name: String) {
        guard let chain = engine.chains[chainID] else { return }
        guard let slot = TaskTagSlot.allCases.first(where: { slot in
            chain.tagAssignments.contains { $0.slot == slot } == false
        }) else {
            showToast("最多 3 个 Tag")
            return
        }
        assignTagByNameOrCreate(chainID: chainID, slot: slot, name: name)
    }

    func removeInlineTag(chainID: TaskChainID, slot: TaskTagSlot) {
        guard let chain = engine.chains[chainID] else { return }
        let remainingTagIDs = chain.tagAssignments
            .filter { $0.slot != slot }
            .sorted { $0.slot < $1.slot }
            .map(\.tagID)
        do {
            objectWillChange.send()
            for slot in TaskTagSlot.allCases {
                try engine.setTaskTagAssignment(chainID: chainID, slot: slot, tagID: nil)
            }
            for (index, tagID) in remainingTagIDs.prefix(TaskTagSlot.allCases.count).enumerated() {
                try engine.setTaskTagAssignment(chainID: chainID, slot: TaskTagSlot.allCases[index], tagID: tagID)
            }
            persist()
            showToast("任务 Tag 已更新")
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func inlineTagSuggestions(for chain: TaskChain, query: String) -> [TaskTag] {
        let assignedTagIDs = Set(chain.tagAssignments.map(\.tagID))
        return orderedActiveTagSuggestions(query: query, excluding: assignedTagIDs)
    }

    func newTaskTagSuggestions(for draft: String) -> [TaskTag] {
        let tagNames = Set(parsedTaskDraft(draft).tagNames.map { $0.lowercased() })
        let excludedTagIDs = Set(engine.activeTaskTags().filter { tagNames.contains($0.name.lowercased()) }.map(\.id))
        return orderedActiveTagSuggestions(query: lastHashQuery(in: draft), excluding: excludedTagIDs)
    }

    func primaryNewTaskSuggestionCount(for draft: String) -> Int {
        let primaryTagIDs = Set(engine.taskTagsCommonlyUsed(in: .tagI).map(\.id))
        return newTaskTagSuggestions(for: draft).prefix { primaryTagIDs.contains($0.id) }.count
    }

    func shouldShowNewTaskTagSuggestions(for draft: String) -> Bool {
        draft.contains("#") && lastHashQuery(in: draft) != nil && newTaskTagSuggestions(for: draft).isEmpty == false
    }

    func completeLastHashToken(in draft: String, with tagName: String) -> String {
        guard let hashIndex = draft.lastIndex(of: "#") else {
            return "\(draft) #\(tagName)"
        }
        let prefix = draft[..<hashIndex]
        return "\(prefix)#\(tagName) "
    }

    private func orderedActiveTagSuggestions(query: String?, excluding excludedTagIDs: Set<TaskTagID>) -> [TaskTag] {
        let primaryTags = engine.taskTagsCommonlyUsed(in: .tagI)
        let primaryTagIDs = Set(primaryTags.map(\.id))
        let orderedTags = primaryTags + engine.activeTaskTags().filter { primaryTagIDs.contains($0.id) == false }
        let normalizedQuery = query?.trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespacesAndNewlines)) ?? ""
        return orderedTags.filter { tag in
            guard excludedTagIDs.contains(tag.id) == false else { return false }
            guard normalizedQuery.isEmpty == false else { return true }
            return tag.name.localizedStandardContains(normalizedQuery)
        }
    }

    func primaryInlineSuggestionCount(for chain: TaskChain, query: String) -> Int {
        let primaryTagIDs = Set(engine.taskTagsCommonlyUsed(in: .tagI).map(\.id))
        return inlineTagSuggestions(for: chain, query: query).prefix { primaryTagIDs.contains($0.id) }.count
    }

    private func assignTagByNameOrCreate(chainID: TaskChainID, slot: TaskTagSlot, name: String) {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard normalizedName.isEmpty == false else { return }
        do {
            objectWillChange.send()
            let tagID = try tagIDByNameOrCreate(name: normalizedName, slot: slot)
            try engine.setTaskTagAssignment(chainID: chainID, slot: slot, tagID: tagID)
            persist()
            showToast("任务 Tag 已更新")
        } catch {
            showToast(error.localizedDescription)
        }
    }

    private func applyTaskDraftTags(chainID: TaskChainID, tagNames: [String]) throws {
        for (index, tagName) in tagNames.prefix(TaskTagSlot.allCases.count).enumerated() {
            let slot = TaskTagSlot.allCases[index]
            let tagID = try tagIDByNameOrCreate(name: tagName, slot: slot)
            try engine.setTaskTagAssignment(chainID: chainID, slot: slot, tagID: tagID)
        }
    }

    private func tagIDByNameOrCreate(name: String, slot: TaskTagSlot) throws -> TaskTagID {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard normalizedName.isEmpty == false else {
            throw SuntraceError.invalidInput("tag name cannot be empty")
        }
        if let existing = engine.activeTaskTags().first(where: {
            $0.name.caseInsensitiveCompare(normalizedName) == .orderedSame
        }) {
            return existing.id
        }
        return try engine.createTaskTag(
            name: normalizedName,
            colorHex: defaultTagColorHex(for: slot)
        )
    }

    private func defaultTagColorHex(for slot: TaskTagSlot) -> String {
        switch slot {
        case .tagI:
            return "#2A6FDB"
        case .tagII:
            return "#0E9488"
        case .tagIII:
            return "#7C5CFF"
        }
    }

    func commonlyUsedTags(in slot: TaskTagSlot) -> [TaskTag] {
        engine.taskTagsCommonlyUsed(in: slot)
    }

    func otherActiveTags(for slot: TaskTagSlot) -> [TaskTag] {
        let commonIDs = Set(commonlyUsedTags(in: slot).map(\.id))
        return engine.activeTaskTags().filter { commonIDs.contains($0.id) == false }
    }

    func selectUnfinished(_ chainID: TaskChainID) {
        selectedUnfinishedChainID = chainID
        selectedTraceID = nil
        selectedPoolChainID = nil
        selectedCompletedTraceID = nil
        selectedCompletedSubtaskID = nil
        detailSubtaskText = ""
    }

    func selectCompleted(_ traceID: DayTraceID) {
        selectedCompletedTraceID = traceID
        selectedCompletedSubtaskID = nil
        selectedTraceID = traceID
        selectedPoolChainID = nil
        selectedUnfinishedChainID = nil
        detailSubtaskText = ""
    }

    func selectCompletedSubtask(_ subtaskID: SubtaskID) {
        selectedCompletedSubtaskID = subtaskID
        selectedCompletedTraceID = nil
        detailSubtaskText = ""
        if let record = selectedCompletedSubtaskRecord {
            selectedTraceID = record.parentTrace.id
        }
    }

    func selectItemForLaunch(_ selectionName: String) {
        switch page {
        case .day:
            selectLaunchDayItem(selectionName)
        case .future:
            selectLaunchFutureItem()
        case .pool:
            selectLaunchPoolItem()
        case .unfinished:
            selectLaunchUnfinishedItem()
        case .completed:
            selectLaunchCompletedItem()
        case .calendar, .zhulong, .settings:
            break
        }
    }

    private func selectLaunchDayItem(_ selectionName: String) {
        let latestChangedTrace = engine.traces.values
            .filter { $0.status == .changed && $0.changedToTraceID != nil }
            .sorted { $0.date > $1.date }
            .first
        if selectionName == "changed", let changedTrace = latestChangedTrace {
            selectedDate = changedTrace.date
            selectTrace(changedTrace.id)
            return
        }

        let traces = engine.getDayTodo(date: selectedDate).traces
        let trace = selectionName == "manual"
            ? traces.first { subtasks(for: $0.id).isEmpty && $0.status == .pending }
            : traces.first
        if let trace {
            selectTrace(trace.id)
        }
    }

    private func selectLaunchFutureItem() {
        if let trace = engine.futurePlans(today: today).first?.trace {
            selectTrace(trace.id)
        }
    }

    private func selectLaunchPoolItem() {
        if let task = engine.taskPool().first {
            selectPool(task.chain.id)
        }
    }

    private func selectLaunchUnfinishedItem() {
        if let item = engine.unfinishedPool().first {
            selectUnfinished(item.chain.id)
        }
    }

    private func selectLaunchCompletedItem() {
        if let item = engine.completedPool().first {
            selectCompleted(item.trace.id)
        }
    }

    func clearSelection() {
        selectedTraceID = nil
        selectedPoolChainID = nil
        selectedUnfinishedChainID = nil
        selectedCompletedTraceID = nil
        selectedCompletedSubtaskID = nil
        detailSubtaskText = ""
        detailNoteText = ""
    }

    func resetLaunchSelection() {
        selectedDate = today
        selectedCalendarDate = today
        clearSelection()
    }

    func addQuickTask() {
        let draft = parsedTaskDraft(quickText)
        guard draft.title.isEmpty == false else { return }
        do {
            pushUndoSnapshotIfAllowed(on: selectedDate)
            let chainID = try engine.createPoolTask(title: draft.title, descriptionText: "快速记录自 Day Todo。", now: Date())
            try applyTaskDraftTags(chainID: chainID, tagNames: draft.tagNames)
            _ = try engine.scheduleFromPool(chainID: chainID, date: selectedDate, today: today)
            quickText = ""
            persist()
            showToast("已添加「\(draft.title)」")
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func addPoolTask() {
        let draft = parsedTaskDraft(poolText)
        guard draft.title.isEmpty == false else { return }
        do {
            pushUndoSnapshot()
            let chainID = try engine.createPoolTask(title: draft.title, descriptionText: "任务池中的待排期任务。", note: "可以排期到今天、明天或指定日期。")
            try applyTaskDraftTags(chainID: chainID, tagNames: draft.tagNames)
            selectedPoolChainID = chainID
            poolText = ""
            persist()
            showToast("已加入任务池")
        } catch {
            showToast(error.localizedDescription)
        }
    }

    private func parsedTaskDraft(_ rawText: String) -> (title: String, tagNames: [String]) {
        let raw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.isEmpty == false else { return ("", []) }
        let pattern = #"#([^\s#]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (raw, [])
        }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        let matches = regex.matches(in: raw, range: range)
        let tagNames = matches.compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: raw) else { return nil }
            let tagName = String(raw[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            return tagName.isEmpty ? nil : tagName
        }
        let title = regex.stringByReplacingMatches(
            in: raw,
            range: range,
            withTemplate: " "
        )
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
        return (title, tagNames)
    }

    private func lastHashQuery(in text: String) -> String? {
        guard let hashIndex = text.lastIndex(of: "#") else { return nil }
        let tail = text[text.index(after: hashIndex)...]
        return tail.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
    }

    func schedulePoolTask(_ chainID: TaskChainID, date: LocalDate) {
        guard date >= today else {
            showToast("任务池不能排期到过去日期")
            return
        }
        do {
            pushUndoSnapshotIfAllowed(on: date)
            let traceID = try engine.scheduleFromPool(chainID: chainID, date: date, today: today)
            selectedDate = date
            page = .day
            selectTrace(traceID)
            persist()
            showToast("已排期到 \(Self.displayDate(date))")
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func toggleComplete(_ traceID: DayTraceID) {
        guard let trace = engine.traces[traceID] else { return }
        do {
            pushUndoSnapshotIfAllowed(on: trace.date)
            if trace.status == .completed {
                try engine.undoCompleted(traceID: traceID, today: today)
                persist()
                showToast("已撤销完成")
            } else {
                try engine.markCompleted(traceID: traceID, today: today)
                persist()
                showToast("已完成")
            }
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func toggleSubtask(_ subtaskID: SubtaskID) {
        guard let subtask = engine.subtasks[subtaskID] else { return }
        guard let trace = engine.traces[subtask.traceID] else { return }
        guard canMutateSubtask(subtask) else {
            showToast(subtaskMutationUnavailableMessage(for: trace))
            return
        }
        do {
            if subtask.status == .pending {
                pushUndoSnapshotIfAllowed(on: trace.date)
                try engine.completeSubtask(subtaskID, today: today)
                persist()
                showToast("子任务已完成")
            } else if subtask.status == .completed {
                pushUndoSnapshotIfAllowed(on: trace.date)
                try engine.undoCompletedSubtask(subtaskID, today: today)
                persist()
                showToast("子任务已撤回")
            } else {
                showToast("只有待完成或已完成子任务可切换")
            }
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func canMutateSubtask(_ subtask: Subtask) -> Bool {
        guard let trace = engine.traces[subtask.traceID] else { return false }
        return trace.date == today && trace.status == .pending
    }

    private func subtaskMutationUnavailableMessage(for trace: DayTrace) -> String {
        if trace.date < today {
            return "历史子任务不可改写"
        }
        if trace.date > today {
            return "未来子任务到当天前不可改写"
        }
        return "父任务不是待完成状态，子任务不可改写"
    }

    func cycleSubtaskDifficulty(_ subtaskID: SubtaskID) {
        guard let current = engine.subtasks[subtaskID]?.difficulty else { return }
        let next: SubtaskDifficulty = switch current {
        case .simple: .medium
        case .medium: .hard
        case .hard: .simple
        }
        setSubtaskDifficulty(subtaskID, difficulty: next)
    }

    func setSubtaskDifficulty(_ subtaskID: SubtaskID, difficulty: SubtaskDifficulty) {
        guard let subtask = engine.subtasks[subtaskID] else { return }
        guard let trace = engine.traces[subtask.traceID] else { return }
        guard canMutateSubtask(subtask) else {
            showToast(subtaskMutationUnavailableMessage(for: trace))
            return
        }
        do {
            pushUndoSnapshotIfAllowed(on: trace.date)
            try engine.updateSubtaskDifficulty(subtaskID, difficulty: difficulty, today: today)
            persist()
            showToast("子任务难度已更新")
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func continueTrace(_ traceID: DayTraceID, to date: LocalDate) {
        do {
            if let trace = engine.traces[traceID] {
                pushUndoSnapshotIfAllowed(on: trace.date)
            }
            let nextID = try engine.continueTrace(traceID: traceID, targetDate: date, today: today)
            selectedDate = date
            page = .day
            selectTrace(nextID)
            persist()
            showToast("已延续到 \(Self.displayDate(date))")
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func returnToPool(_ traceID: DayTraceID) {
        do {
            if let trace = engine.traces[traceID] {
                pushUndoSnapshotIfAllowed(on: trace.date)
            }
            try engine.returnToPool(traceID: traceID, today: today)
            page = .pool
            clearSelection()
            persist()
            showToast("已回池，轨迹保留在当天")
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func abandon(_ traceID: DayTraceID) {
        do {
            if let trace = engine.traces[traceID] {
                pushUndoSnapshotIfAllowed(on: trace.date)
            }
            try engine.abandonChain(from: traceID)
            persist()
            showToast("任务链已废弃")
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func reactivateAbandonedChain(from traceID: DayTraceID) {
        do {
            pushUndoSnapshot()
            _ = try engine.reactivateAbandonedChain(from: traceID, today: today)
            persist()
            showToast("已取消废弃")
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func copyAsNewTask(_ traceID: DayTraceID) {
        do {
            pushUndoSnapshot()
            _ = try engine.copyAsNewTask(from: traceID, target: .taskPool, today: today)
            page = .pool
            persist()
            showToast("已复制为新任务，放入任务池")
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func reschedule(_ traceID: DayTraceID, to date: LocalDate) {
        do {
            if let trace = engine.traces[traceID] {
                pushUndoSnapshotIfAllowed(on: trace.date)
            }
            try engine.rescheduleFuturePlan(traceID: traceID, targetDate: date, today: today)
            selectedDate = date
            persist()
            showToast("已改期到 \(Self.displayDate(date))")
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func changeSelectedTrace() {
        guard let selectedTraceID else { return }
        let title = changeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.isEmpty == false else { return }
        do {
            if let trace = engine.traces[selectedTraceID] {
                pushUndoSnapshotIfAllowed(on: trace.date)
            }
            let newID = try engine.changeTrace(traceID: selectedTraceID, newTitle: title, today: today)
            showingChangeDialog = false
            changeText = ""
            selectTrace(newID)
            persist()
            showToast("已变更，新任务已加入当天")
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func movePriority(_ traceID: DayTraceID, delta: Int) {
        guard let trace = engine.traces[traceID] else { return }
        do {
            pushUndoSnapshotIfAllowed(on: trace.date)
            try engine.updatePriority(traceID: traceID, newPriority: max(1, trace.priority + delta), today: today)
            persist()
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func updateReview(summary: String? = nil, reason: String? = nil, tomorrow: String? = nil) {
        let existing = engine.days[selectedDate]
        engine.updateDailyReview(
            date: selectedDate,
            summary: summary ?? existing?.reviewSummary,
            unfinishedReason: reason ?? existing?.reviewUnfinishedReason,
            tomorrowNote: tomorrow ?? existing?.reviewTomorrowNote
        )
        persist()
        reviewAutosaveMessage = "已自动保存"
    }

    func updateTraceText(traceID: DayTraceID, descriptionText: String? = nil, note: String? = nil) {
        guard let trace = engine.traces[traceID] else { return }
        do {
            pushUndoSnapshotIfAllowed(on: trace.date)
            try engine.updateTraceText(
                traceID: traceID,
                descriptionText: descriptionText ?? trace.descriptionText,
                note: note ?? trace.note,
                today: today
            )
            objectWillChange.send()
            persist()
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func updatePoolTaskText(chainID: TaskChainID, descriptionText: String? = nil, note: String? = nil) {
        guard let definition = currentDefinition(for: chainID) else { return }
        do {
            objectWillChange.send()
            try engine.updatePoolTask(
                chainID: chainID,
                title: definition.title,
                descriptionText: descriptionText ?? definition.descriptionText,
                note: note ?? definition.note
            )
            persist()
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func appendTraceNote(traceID: DayTraceID) {
        let body = detailNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.isEmpty == false, let trace = engine.traces[traceID] else { return }
        let nextNote = DetailNoteEntryStorage.appending(body, to: trace.note)
        updateTraceText(traceID: traceID, note: nextNote)
        detailNoteText = ""
    }

    func appendPoolNote(chainID: TaskChainID) {
        let body = detailNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.isEmpty == false, let definition = currentDefinition(for: chainID) else { return }
        let nextNote = DetailNoteEntryStorage.appending(body, to: definition.note)
        updatePoolTaskText(chainID: chainID, note: nextNote)
        detailNoteText = ""
    }

    func setManualProgress(traceID: DayTraceID, percent: Double) {
        do {
            if let trace = engine.traces[traceID] {
                pushUndoSnapshotIfAllowed(on: trace.date)
            }
            try engine.setManualProgress(traceID: traceID, percent: Int(percent.rounded()), today: today)
            objectWillChange.send()
            persist()
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func addDetailSubtask(traceID: DayTraceID) {
        let title = detailSubtaskText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.isEmpty == false else { return }
        do {
            if let trace = engine.traces[traceID] {
                pushUndoSnapshotIfAllowed(on: trace.date)
            }
            _ = try engine.addSubtask(traceID: traceID, title: title)
            detailSubtaskText = ""
            objectWillChange.send()
            persist()
            showToast("已添加子任务")
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func addPoolPlannedSubtask(chainID: TaskChainID) {
        let title = detailSubtaskText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.isEmpty == false else { return }
        do {
            objectWillChange.send()
            _ = try engine.addPlannedSubtask(chainID: chainID, title: title)
            detailSubtaskText = ""
            persist()
            showToast("已添加子任务")
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func removePoolPlannedSubtask(chainID: TaskChainID, plannedSubtaskID: PlannedSubtaskID) {
        do {
            objectWillChange.send()
            try engine.removePlannedSubtask(chainID: chainID, plannedSubtaskID: plannedSubtaskID)
            persist()
            showToast("已更新子任务")
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func setPoolPlannedSubtaskDifficulty(
        chainID: TaskChainID,
        plannedSubtaskID: PlannedSubtaskID,
        difficulty: SubtaskDifficulty
    ) {
        do {
            objectWillChange.send()
            try engine.updatePlannedSubtaskDifficulty(
                chainID: chainID,
                plannedSubtaskID: plannedSubtaskID,
                difficulty: difficulty
            )
            persist()
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func setTheme(_ theme: AppTheme) {
        objectWillChange.send()
        engine.updateTheme(theme)
        Theme.apply(theme)
        persist()
    }

    func setLanguage(_ language: AppLanguage) {
        objectWillChange.send()
        engine.updateLanguage(language)
        persist()
    }

    func setSettingsPoemEnabled(_ enabled: Bool) {
        objectWillChange.send()
        var policy = engine.preferences.settingsPoemDisplayPolicy
        policy.enabled = enabled
        engine.updateSettingsPoemDisplayPolicy(policy)
        persist()
    }

    func setSettingsPoemText(_ text: String) {
        objectWillChange.send()
        var policy = engine.preferences.settingsPoemDisplayPolicy
        policy.text = text
        engine.updateSettingsPoemDisplayPolicy(policy)
        persist()
    }

    func resetSettingsPoemText() {
        objectWillChange.send()
        var policy = engine.preferences.settingsPoemDisplayPolicy
        policy.text = SettingsPoemDisplayPolicy.defaultText
        engine.updateSettingsPoemDisplayPolicy(policy)
        persist()
        showToast(copy.settingsPoemResetToast)
    }

    func setDataMode(_ dataMode: AppDataMode) {
        objectWillChange.send()
        engine.updateDataMode(dataMode)
        persist()
        restartLocalFirstSyncAutomation()
        showToast(copy.dataModeChangedToast(for: dataMode))
    }

    func setBackupFrequency(_ frequency: ScheduledBackupFrequency) {
        objectWillChange.send()
        var policy = engine.preferences.backupPolicy
        policy.frequency = frequency
        engine.updateBackupPolicy(policy)
        persist()
        showToast(copy.backupPolicyChangedToast)
    }

    func setBackupDestination(_ destination: BackupDestinationKind) {
        objectWillChange.send()
        var policy = engine.preferences.backupPolicy
        policy.destination = destination
        engine.updateBackupPolicy(policy)
        persist()
        showToast(copy.backupPolicyChangedToast)
    }

    func setLocalFirstSyncEndpoint(_ endpoint: CloudSyncEndpointKind) {
        objectWillChange.send()
        var policy = engine.preferences.localFirstSyncPolicy
        policy.endpoint = endpoint
        policy.enabled = endpoint == .iCloud || endpoint == .localFolder
        engine.updateLocalFirstSyncPolicy(policy)
        persist()
        restartLocalFirstSyncAutomation()
        showToast(copy.localFirstSyncChangedToast)
    }

    func setLocalFirstSyncMode(_ mode: CloudSyncMode) {
        objectWillChange.send()
        var policy = engine.preferences.localFirstSyncPolicy
        policy.mode = mode
        engine.updateLocalFirstSyncPolicy(policy)
        persist()
        restartLocalFirstSyncAutomation()
        showToast(copy.localFirstSyncChangedToast)
    }

    func syncLocalFolderNow() {
        runLocalFolderSync(showToastOnSuccess: true)
    }

    private func runLocalFolderSync(showToastOnSuccess: Bool) {
        guard engine.preferences.dataMode == .localFirst,
              supportsRunnableLocalFirstSync(engine.preferences.localFirstSyncPolicy.endpoint)
        else {
            showToast(copy.localFirstSyncUnavailableToast)
            return
        }
        guard isLocalFirstSyncing == false else { return }
        guard let databaseURL else {
            showToast("临时模式不支持本地文件夹同步")
            return
        }

        persist()
        isLocalFirstSyncing = true
        localFirstSyncMessage = "同步中…"
        let endpoint = engine.preferences.localFirstSyncPolicy.endpoint
        Task { [databaseURL, endpoint] in
            do {
                let coordinator = SQLiteLocalFirstSyncCoordinator(
                    databaseURL: databaseURL,
                    transport: try Self.localFirstSyncTransport(for: endpoint)
                )
                let result = try await coordinator.sync()
                let loaded = try SQLiteEngineRepository(databaseURL: databaseURL).load()
                await MainActor.run {
                    engine = loaded
                    Theme.apply(engine.preferences.theme)
                    normalizeSelection()
                    isLocalFirstSyncing = false
                    localFirstSyncMessage = copy.localFirstSyncResult(result)
                    if showToastOnSuccess {
                        showToast(copy.localFirstSyncResult(result))
                    }
                }
            } catch {
                await MainActor.run {
                    isLocalFirstSyncing = false
                    localFirstSyncMessage = "同步失败：\(error.localizedDescription)"
                    showToast("同步失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func supportsRunnableLocalFirstSync(_ endpoint: CloudSyncEndpointKind) -> Bool {
        endpoint == .iCloud || endpoint == .localFolder
    }

    private static func localFirstSyncTransport(for endpoint: CloudSyncEndpointKind) throws -> any SyncRecordTransport {
        switch endpoint {
        case .iCloud:
            return try ICloudDriveSyncTransport()
        case .localFolder:
            return LocalFolderSyncTransport(rootURL: configuredSyncFolderURL())
        case .s3, .webDAV:
            throw ICloudDriveSyncTransportError.unavailable
        }
    }

    private func restartLocalFirstSyncAutomation() {
        localFirstSyncAutomationTask?.cancel()
        localFirstSyncAutomationTask = nil
        let policy = engine.preferences.localFirstSyncPolicy
        guard databaseURL != nil,
              engine.preferences.dataMode == .localFirst,
              policy.enabled,
              supportsRunnableLocalFirstSync(policy.endpoint),
              policy.mode == .automatic
        else { return }

        let intervalNanoseconds = UInt64(policy.intervalSeconds) * 1_000_000_000
        localFirstSyncAutomationTask = Task { [weak self] in
            while Task.isCancelled == false {
                do {
                    try await Task.sleep(nanoseconds: intervalNanoseconds)
                } catch {
                    return
                }
                if Task.isCancelled { return }
                await MainActor.run {
                    self?.runLocalFolderSync(showToastOnSuccess: false)
                }
            }
        }
    }

    func exportDataPackage() {
        let panel = NSSavePanel()
        panel.title = "导出晷迹数据"
        panel.nameFieldStringValue = "noonmark-backup-\(today.description).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try exportDataPackage(to: url)
            showToast("已导出 \(url.lastPathComponent)")
        } catch {
            showToast("导出失败：\(error.localizedDescription)")
        }
    }

    func importDataPackage() {
        let panel = NSOpenPanel()
        panel.title = "导入晷迹数据"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try importDataPackage(from: url)
            showToast("已导入 \(url.lastPathComponent)")
        } catch {
            showToast("导入失败：\(error.localizedDescription)")
        }
    }

    func exportDataPackage(to url: URL) throws {
        try SuntraceDataPackage.write(engine.snapshot(), to: url)
    }

    func importDataPackage(from url: URL) throws {
        let snapshot = try SuntraceDataPackage.read(from: url)

        pushUndoSnapshot()
        engine = SuntraceEngine(snapshot: snapshot)
        Theme.apply(engine.preferences.theme)
        selectedDate = today
        selectedCalendarDate = today
        clearSelection()
        persist()
    }

    func saveZhulongProvider() {
        do {
            zhulongProviderDraft = try ZhulongProviderSettingsStore.save(zhulongProviderDraft)
            if zhulongProviderDraft.enabled == false {
                ensureVisiblePage()
            }
            showToast("Provider 配置已保存")
        } catch {
            showToast("Provider 保存失败：\(error.localizedDescription)")
        }
    }

    func clearZhulongProvider() {
        do {
            zhulongProviderDraft = try ZhulongProviderSettingsStore.clear()
            ensureVisiblePage(preferredFallback: .settings)
            showToast("Provider 配置已清空")
        } catch {
            showToast("Provider 清空失败：\(error.localizedDescription)")
        }
    }

    func testZhulongProvider() {
        Task { @MainActor in
            await testZhulongProviderHealth()
        }
    }

    private func testZhulongProviderHealth() async {
        do {
            let config = try ZhulongProviderSettingsStore.makeConfig(from: zhulongProviderDraft)
            guard config.enabled else {
                showToast("Provider 已关闭，未发起连接测试")
                return
            }
            guard config.kind == .openAICompatible else {
                showToast("Provider 配置完整；该类型的远程健康检查尚未接入")
                return
            }

            let provider = OpenAICompatibleProvider(
                config: config,
                apiKeyResolver: { ref in
                    guard ref == ZhulongProviderKeychain.keyRef else { return nil }
                    return try ZhulongProviderKeychain.readAPIKey()
                }
            )
            let health = await provider.healthCheck()
            switch health.status {
            case .healthy:
                showToast("Provider 连接成功")
            case .unavailable:
                showToast("Provider 连接失败：\(health.message ?? "未知错误")")
            case .unconfigured:
                showToast("Provider 尚未启用")
            }
        } catch {
            showToast("Provider 配置无效：\(error.localizedDescription)")
        }
    }

    func generateZhulongDraft(task: ZhulongTask) {
        guard zhulongProviderDraft.enabled else {
            showToast("烛龙已在设置中关闭")
            return
        }
        let scope = zhulongScope(for: task)
        guard scope.isEmpty == false else {
            showToast("授权范围为空，无法生成建议草稿")
            return
        }

        let report = LocalInsightAnalyzer().analyze(scope)
        let draft = AISuggestionDraft(
            kind: task.suggestionKind,
            createdAt: Date(),
            sourceScope: scope,
            localReport: report,
            summary: zhulongSummary(for: task, report: report),
            proposedOperations: zhulongOperations(for: task),
            confidence: zhulongConfidence(for: task)
        )

        zhulongDrafts.insert(draft, at: 0)
        selectedZhulongDraftID = draft.id
        showToast("已生成建议草稿，等待用户确认")
    }

    func requestZhulongDailyReviewFromReviewRail() {
        page = .zhulong
        generateZhulongDraft(task: .dailyReview)
    }

    func applyZhulongOperation(draftID: AISuggestionDraftID, operationIndex: Int) {
        guard let draft = zhulongDrafts.first(where: { $0.id == draftID }),
              draft.proposedOperations.indices.contains(operationIndex)
        else {
            showToast("建议操作不存在")
            return
        }

        let key = zhulongOperationKey(draftID: draftID, operationIndex: operationIndex)
        guard appliedZhulongOperationKeys.contains(key) == false else {
            showToast("这条建议已应用")
            return
        }

        do {
            let result = try AISuggestionDraftApplier().applyConfirmed(
                draft.proposedOperations[operationIndex],
                to: engine,
                today: today
            )
            appliedZhulongOperationKeys.insert(key)
            normalizeSelection()
            persist()
            showToast(result.message)
        } catch {
            showToast("应用建议失败：\(error.localizedDescription)")
        }
    }

    func zhulongOperationKey(draftID: AISuggestionDraftID, operationIndex: Int) -> String {
        "\(draftID.description)-\(operationIndex)"
    }

    private func zhulongScope(for task: ZhulongTask) -> AIScopeSnapshot {
        switch task {
        case .dailyReview, .habitInsight, .taskDecomposition:
            return AIScopeSnapshot.day(date: today, from: engine, isCurrentDay: true)
        case .scheduling:
            let day = AIScopeSnapshot.day(date: today, from: engine, isCurrentDay: true)
            let pools = AIScopeSnapshot.pools(from: engine, includeTaskPool: true, includeUnfinishedPool: true, includeCompletedPool: false)
            return AIScopeSnapshot.combined([day, pools])
        case .labelClassification, .theoryAnalysis:
            let day = AIScopeSnapshot.day(date: today, from: engine, isCurrentDay: true)
            let pools = AIScopeSnapshot.pools(from: engine, includeTaskPool: true, includeUnfinishedPool: true, includeCompletedPool: true)
            return AIScopeSnapshot.combined([day, pools])
        }
    }

    private func zhulongSummary(for task: ZhulongTask, report: LocalInsightReport) -> String {
        let facts = report.facts.isEmpty ? "当前范围暂无明显风险信号。" : report.facts.joined(separator: " ")
        switch task {
        case .dailyReview:
            return "事实：\(facts) 建议：先补一段复盘草稿，区分事实、原因和明日注意。"
        case .habitInsight:
            return "事实：\(facts) 推断：当前只作为时间窗口内的假设，不写入用户身份。"
        case .taskDecomposition:
            return "事实：\(facts) 建议：为当前待完成任务补充一个可验收子任务，先收敛边界。"
        case .scheduling:
            return "事实：\(facts) 建议：优先把任务池中的一项排到明天，避免继续堆积。"
        case .labelClassification:
            return "事实：\(facts) 建议：先预览 label 候选；核心 label 模型落库前不自动写入。"
        case .theoryAnalysis:
            return "事实：\(facts) 建议：理论只能作为镜头，最终仍回到你的日轨迹证据。"
        }
    }

    private func zhulongOperations(for task: ZhulongTask) -> [AIProposedOperation] {
        switch task {
        case .dailyReview:
            let stats = engine.dailyReviewStats(date: today)
            return [
                .updateDailyReview(
                    date: today,
                    summary: "今日共 \(stats.total) 项任务，完成 \(stats.completed) 项，未完成 \(stats.unfinished) 项。",
                    unfinishedReason: stats.unfinished > 0 ? "先记录真实阻塞，再决定延续、废弃或拆解。" : nil,
                    tomorrowNote: "明天优先保留一个最小可完成承诺。"
                )
            ]
        case .taskDecomposition:
            guard let trace = selectedTrace ?? engine.getDayTodo(date: today).traces.first(where: { $0.status == .pending }) else {
                return []
            }
            return [.addSubtask(traceID: trace.id, title: "补充验收标准", difficulty: .medium)]
        case .scheduling:
            if let task = engine.taskPool().first {
                return [.scheduleFromPool(chainID: task.chain.id, targetDate: Self.offset(today, by: 1))]
            }
            if let item = engine.unfinishedPool().first, item.activeTrace == nil, let trace = item.unfinishedTraces.last {
                return [.continueTrace(traceID: trace.id, targetDate: Self.offset(today, by: 1))]
            }
            return []
        case .habitInsight, .labelClassification, .theoryAnalysis:
            return []
        }
    }

    private func zhulongConfidence(for task: ZhulongTask) -> Double {
        switch task {
        case .dailyReview, .scheduling:
            return 0.74
        case .taskDecomposition:
            return 0.68
        case .habitInsight, .labelClassification, .theoryAnalysis:
            return 0.56
        }
    }

    func performDateChoice(_ date: LocalDate) {
        guard let showingPicker else { return }
        switch showingPicker {
        case .gotoDay:
            selectedDate = date
            selectedCalendarDate = date
            page = .day
        case let .schedulePool(chainID):
            schedulePoolTask(chainID, date: date)
        case .scheduleSelectedPool:
            if let selectedPoolChainID {
                schedulePoolTask(selectedPoolChainID, date: date)
            }
        case let .continueTrace(traceID):
            continueTrace(traceID, to: date)
        case let .reschedule(traceID):
            reschedule(traceID, to: date)
        }
        self.showingPicker = nil
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else {
            showToast("没有可撤销的操作")
            return
        }
        engine = SuntraceEngine(snapshot: snapshot)
        Theme.apply(engine.preferences.theme)
        normalizeSelection()
        persist()
        showToast("已撤销")
    }

    func clearUndoHistory() {
        undoStack.removeAll()
    }

    func showToast(_ message: String) {
        toastTask?.cancel()
        toast = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            await MainActor.run {
                self?.toast = nil
            }
        }
    }

    static func offset(_ date: LocalDate, by days: Int) -> LocalDate {
        var components = DateComponents()
        components.year = date.year
        components.month = date.month
        components.day = date.day
        let base = Calendar(identifier: .gregorian).date(from: components) ?? Date()
        let next = Calendar(identifier: .gregorian).date(byAdding: .day, value: days, to: base) ?? base
        let result = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: next)
        return LocalDate(year: result.year ?? date.year, month: result.month ?? date.month, day: result.day ?? date.day)
    }

    static func displayDate(_ date: LocalDate) -> String {
        "\(date.month)月\(date.day)日"
    }

    static func displayFullDate(_ date: LocalDate) -> String {
        "\(date.year)年\(displayDate(date))"
    }

    static func displayTime(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func weekday(_ date: LocalDate) -> String {
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        var components = DateComponents()
        components.year = date.year
        components.month = date.month
        components.day = date.day
        let d = Calendar(identifier: .gregorian).date(from: components) ?? Date()
        let index = Calendar(identifier: .gregorian).component(.weekday, from: d) - 1
        return names[max(0, min(index, names.count - 1))]
    }

    static func gregorianDate(_ date: LocalDate) -> Date {
        var components = DateComponents()
        components.year = date.year
        components.month = date.month
        components.day = date.day
        return Calendar(identifier: .gregorian).date(from: components) ?? Date()
    }

    static func daysInMonth(year: Int, month: Int) -> Int {
        let date = gregorianDate(LocalDate(year: year, month: month, day: 1))
        return Calendar(identifier: .gregorian).range(of: .day, in: .month, for: date)?.count ?? 30
    }

    static func mondayLeadBlankCount(year: Int, month: Int) -> Int {
        let first = gregorianDate(LocalDate(year: year, month: month, day: 1))
        let weekday = Calendar(identifier: .gregorian).component(.weekday, from: first)
        return (weekday + 5) % 7
    }

    static func shiftedMonth(from date: LocalDate, by delta: Int) -> LocalDate {
        let first = gregorianDate(LocalDate(year: date.year, month: date.month, day: 1))
        let shifted = Calendar(identifier: .gregorian).date(byAdding: .month, value: delta, to: first) ?? first
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: shifted)
        return LocalDate(year: components.year ?? date.year, month: components.month ?? date.month, day: 1)
    }

    static func configuredDatabaseURL() -> URL {
        if let path = commandLineValue(after: "--data-url"), path.isEmpty == false {
            return URL(fileURLWithPath: path)
        }
        return defaultDatabaseURL()
    }

    static func defaultDatabaseURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("noonmark", isDirectory: true)
            .appendingPathComponent("Noonmark.sqlite")
    }

    static func configuredSyncFolderURL() -> URL {
        if let path = commandLineValue(after: "--sync-folder-url"), path.isEmpty == false {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("noonmark", isDirectory: true)
            .appendingPathComponent("sync-repository", isDirectory: true)
    }

    static func configuredLocalFirstSyncEndpointURL(for endpoint: CloudSyncEndpointKind) -> URL? {
        switch endpoint {
        case .iCloud:
            return try? ICloudDriveSyncTransport.defaultRootURL()
        case .localFolder:
            return configuredSyncFolderURL()
        case .s3, .webDAV:
            return nil
        }
    }

    static func loadOrCreateSyncDeviceID(databaseURL: URL) -> SyncDeviceID {
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        do {
            if let identity = try syncRepository.loadDeviceIdentity() {
                return identity.deviceID
            }
            let identity = SyncDeviceIdentity(
                displayName: Host.current().localizedName,
                createdAt: Date()
            )
            try syncRepository.saveDeviceIdentity(identity)
            return identity.deviceID
        } catch {
            NSLog("Suntrace sync identity load failed: %@", String(describing: error))
            return SyncDeviceID()
        }
    }

    static func commandLineValue(after flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag) else { return nil }
        let valueIndex = CommandLine.arguments.index(after: index)
        guard CommandLine.arguments.indices.contains(valueIndex) else { return nil }
        return CommandLine.arguments[valueIndex]
    }

    func loadOrSeed() {
        guard let repository else {
            seed()
            return
        }

        do {
            let loaded = try repository.load()
            let snapshot = loaded.snapshot()
            if snapshot.days.isEmpty && snapshot.chains.isEmpty && snapshot.traces.isEmpty {
                engine = loaded
                Theme.apply(engine.preferences.theme)
                persist()
            } else {
                engine = loaded
                Theme.apply(engine.preferences.theme)
            }
        } catch {
            engine = SuntraceEngine()
            Theme.apply(engine.preferences.theme)
            NSLog("Suntrace persistence load failed: %@", String(describing: error))
            toast = "无法读取本地数据库，已使用空白数据：\(error.localizedDescription)"
        }
    }

    func persist() {
        guard let repository else { return }

        do {
            if let syncDeviceID {
                try repository.save(engine.snapshot(), recordingChangesFor: syncDeviceID)
            } else {
                try repository.save(engine)
            }
        } catch {
            NSLog("Suntrace persistence save failed: %@", String(describing: error))
            showToast("保存失败：\(error.localizedDescription)")
        }
    }

    private func pushUndoSnapshotIfAllowed(on date: LocalDate) {
        guard date >= today else { return }
        pushUndoSnapshot()
    }

    private func pushUndoSnapshot() {
        undoStack.append(engine.snapshot())
        if undoStack.count > 20 {
            undoStack.removeFirst(undoStack.count - 20)
        }
    }

    private func normalizeSelection() {
        if let selectedTraceID, engine.traces[selectedTraceID] == nil {
            self.selectedTraceID = nil
        }
        if let selectedPoolChainID, engine.chains[selectedPoolChainID] == nil {
            self.selectedPoolChainID = nil
        }
        if let selectedUnfinishedChainID, engine.chains[selectedUnfinishedChainID] == nil {
            self.selectedUnfinishedChainID = nil
        }
        if let selectedCompletedTraceID, engine.traces[selectedCompletedTraceID] == nil {
            self.selectedCompletedTraceID = nil
        }
        if let selectedCompletedSubtaskID, engine.subtasks[selectedCompletedSubtaskID] == nil {
            self.selectedCompletedSubtaskID = nil
        }
    }

    private func seed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var seedClock = 0
        func seedNow() -> Date {
            defer { seedClock += 1 }
            return now.addingTimeInterval(TimeInterval(seedClock))
        }
        func eventTime(_ date: LocalDate, hour: Int, minute: Int) -> Date {
            var components = DateComponents()
            components.year = date.year
            components.month = date.month
            components.day = date.day
            components.hour = hour
            components.minute = minute
            return Calendar(identifier: .gregorian).date(from: components) ?? now
        }
        let day0 = LocalDate("2026-07-01")
        let dayMinus3 = LocalDate("2026-07-02")
        let day1 = LocalDate("2026-07-03")
        let day2 = LocalDate("2026-07-04")
        let day3 = today
        let day4 = LocalDate("2026-07-06")
        let day5 = LocalDate("2026-07-07")

        do {
            let engineeringTag = try engine.createTaskTag(name: "工程", colorHex: "#2A6FDB", now: seedNow())
            let reviewTag = try engine.createTaskTag(name: "复盘", colorHex: "#0E9488", now: seedNow())
            let lifeTag = try engine.createTaskTag(name: "生活", colorHex: "#D1477A", now: seedNow())

            let okr = try engine.createPoolTask(
                title: "整理 Q3 OKR 草案",
                descriptionText: "汇总三条产品线负责人给的季度目标，收敛成不超过 3 个 O、每个 O 配 3 个可量化 KR。",
                note: "[2026-07-05 14:20] 等数据组下午的留存看板再定第 2 个 KR 的口径。",
                now: seedNow()
            )
            try engine.setTaskTagAssignment(chainID: okr, slot: .tagI, tagID: reviewTag, now: seedNow())
            let okrDay0 = try engine.scheduleFromPool(chainID: okr, date: day0, today: day0, now: now)

            let launchScript = try engine.createPoolTask(title: "给发布会准备演示脚本", descriptionText: "准备发布会现场演示脚本。", now: seedNow())
            _ = try engine.scheduleFromPool(chainID: launchScript, date: dayMinus3, today: dayMinus3, now: now)
            let physical = try engine.createPoolTask(title: "预约年度体检", descriptionText: "预约年度体检时间。", now: seedNow())
            try engine.setTaskTagAssignment(chainID: physical, slot: .tagI, tagID: lifeTag, now: seedNow())
            let physicalTrace = try engine.scheduleFromPool(chainID: physical, date: dayMinus3, today: dayMinus3, now: now)
            try engine.returnToPool(traceID: physicalTrace, today: dayMinus3, now: now)
            let wireframe = try engine.createPoolTask(title: "画首页线框图", descriptionText: "日历完成样例任务。", now: seedNow())
            let wireframeTrace = try engine.scheduleFromPool(chainID: wireframe, date: dayMinus3, today: dayMinus3, now: now)
            try engine.markCompleted(traceID: wireframeTrace, today: dayMinus3, now: eventTime(dayMinus3, hour: 16, minute: 30))
            let repository = try engine.createPoolTask(title: "搭建项目仓库与 CI", descriptionText: "日历完成样例任务。", now: seedNow())
            let repositoryTrace = try engine.scheduleFromPool(chainID: repository, date: day0, today: day0, now: now)
            try engine.markCompleted(traceID: repositoryTrace, today: day0, now: eventTime(day0, hour: 9, minute: 10))
            let rust = try engine.createPoolTask(title: "学习 Rust 基础语法", descriptionText: "废弃样例任务。", now: seedNow())
            let rustTrace = try engine.scheduleFromPool(chainID: rust, date: day0, today: day0, now: now)
            try engine.abandonChain(from: rustTrace, now: now)

            engine.settleDays(upTo: day1, now: now)
            let okrDay1 = try engine.continueTrace(traceID: okrDay0, targetDate: day1, today: day1, now: now)
            let okrToday = try engine.continueTrace(traceID: okrDay1, targetDate: day3, today: day1, now: now)
            try engine.setManualProgress(traceID: okrToday, percent: 30, today: day3)

            let contract = try engine.createPoolTask(title: "回复设计合同邮件", descriptionText: "确认合同条款并回复对方。", now: seedNow())
            let contractTrace = try engine.scheduleFromPool(chainID: contract, date: day1, today: day1, now: now)
            try engine.markCompleted(traceID: contractTrace, today: day1, now: eventTime(day1, hour: 11, minute: 20))

            let iconExport = try engine.createPoolTask(title: "修复图标导出脚本", descriptionText: "修复图标资源导出脚本。", now: seedNow())
            try engine.setTaskTagAssignment(chainID: iconExport, slot: .tagI, tagID: engineeringTag, now: seedNow())
            let iconDay2 = try engine.scheduleFromPool(chainID: iconExport, date: day2, today: day2, now: now)
            try engine.setManualProgress(traceID: iconDay2, percent: 45, today: day2)
            let iconToday = try engine.continueTrace(traceID: iconDay2, targetDate: day3, today: day2, now: now)
            try engine.setManualProgress(traceID: iconToday, percent: 45, today: day3)

            let weeklyReport = try engine.createPoolTask(title: "写本周周报", descriptionText: "整理本周进展和风险。", now: seedNow())
            try engine.setTaskTagAssignment(chainID: weeklyReport, slot: .tagI, tagID: reviewTag, now: seedNow())
            let weeklyDay1 = try engine.scheduleFromPool(chainID: weeklyReport, date: day1, today: day1, now: now)
            let weeklyDay2 = try engine.continueTrace(traceID: weeklyDay1, targetDate: day2, today: day1, now: now)
            try engine.markCompleted(traceID: weeklyDay2, today: day2, now: eventTime(day2, hour: 17, minute: 45))

            let pricing = try engine.createPoolTask(title: "调研竞品定价", descriptionText: "旧任务范围过大，需要变更为可交付对比表。", now: seedNow())
            let pricingTrace = try engine.scheduleFromPool(chainID: pricing, date: day2, today: day2, now: now)
            _ = try engine.changeTrace(traceID: pricingTrace, newTitle: "输出竞品定价对比表", today: day2, now: seedNow())

            let visual = try engine.createPoolTask(title: "制作发布会主视觉", descriptionText: "推进发布会主视觉定稿。", now: seedNow())
            try engine.setTaskTagAssignment(chainID: visual, slot: .tagI, tagID: engineeringTag, now: seedNow())
            let visualDay1 = try engine.scheduleFromPool(chainID: visual, date: day1, today: day1, now: now)
            let visualReference = try engine.addSubtask(traceID: visualDay1, title: "收集视觉参考", difficulty: .simple, now: now)
            _ = try engine.addSubtask(traceID: visualDay1, title: "出 3 版草图", difficulty: .hard, now: now)
            try engine.completeSubtask(visualReference, today: day1, now: eventTime(day1, hour: 15, minute: 20))
            let visualDay2 = try engine.continueTrace(traceID: visualDay1, targetDate: day2, today: day1, now: now)
            if let draftSubtask = engine.subtasks.values.first(where: { $0.traceID == visualDay2 && $0.title == "出 3 版草图" }) {
                try engine.completeSubtask(draftSubtask.id, today: day2, now: eventTime(day2, hour: 15, minute: 45))
            }
            _ = try engine.addSubtask(traceID: visualDay2, title: "定稿并交付", difficulty: .medium, now: now)
            let visualToday = try engine.continueTrace(traceID: visualDay2, targetDate: day3, today: day2, now: now)
            if engine.subtasks.values.contains(where: { $0.traceID == visualToday }) == false {
                _ = try engine.addSubtask(traceID: visualToday, title: "定稿并交付", difficulty: .medium, now: now)
            }

            let onboarding = try engine.createPoolTask(title: "审阅 onboarding 三屏文案", descriptionText: "审阅 onboarding 三屏文案。", now: seedNow())
            try engine.setTaskTagAssignment(chainID: onboarding, slot: .tagI, tagID: reviewTag, now: seedNow())
            let onboardingTrace = try engine.scheduleFromPool(chainID: onboarding, date: day3, today: day3, now: now)
            let headline = try engine.addSubtask(traceID: onboardingTrace, title: "首屏标题与副标题", difficulty: .simple, now: now)
            _ = try engine.addSubtask(traceID: onboardingTrace, title: "通知权限请求文案", difficulty: .medium, now: now)
            try engine.completeSubtask(headline, today: day3, now: eventTime(day3, hour: 9, minute: 0))

            let running = try engine.createPoolTask(title: "晨跑 5 公里", descriptionText: "完成晨跑。", now: seedNow())
            try engine.setTaskTagAssignment(chainID: running, slot: .tagI, tagID: lifeTag, now: seedNow())
            let runningTrace = try engine.scheduleFromPool(chainID: running, date: day3, today: day3, now: now)
            try engine.markCompleted(traceID: runningTrace, today: day3, now: eventTime(day3, hour: 7, minute: 36))

            let downloads = try engine.createPoolTask(title: "清理下载文件夹", descriptionText: "清理下载文件夹。", now: seedNow())
            try engine.setTaskTagAssignment(chainID: downloads, slot: .tagI, tagID: lifeTag, now: seedNow())
            _ = try engine.scheduleFromPool(chainID: downloads, date: day3, today: day3, now: now)

            let reading = try engine.createPoolTask(title: "读《卡片笔记写作法》第三章", descriptionText: "任务池样例任务。", now: seedNow())
            try engine.setTaskTagAssignment(chainID: reading, slot: .tagI, tagID: reviewTag, now: seedNow())
            let animationAPI = try engine.createPoolTask(title: "调研 SwiftUI 动画 API", descriptionText: "任务池样例任务。", now: seedNow())
            try engine.setTaskTagAssignment(chainID: animationAPI, slot: .tagI, tagID: engineeringTag, now: seedNow())
            try engine.setTaskTagAssignment(chainID: animationAPI, slot: .tagII, tagID: reviewTag, now: seedNow())

            let standup = try engine.createPoolTask(title: "准备周一站会要点", descriptionText: "未来计划样例任务。", now: seedNow())
            try engine.setTaskTagAssignment(chainID: standup, slot: .tagI, tagID: reviewTag, now: seedNow())
            _ = try engine.scheduleFromPool(chainID: standup, date: day4, today: day3, now: now)
            let invoice = try engine.createPoolTask(title: "整理六月发票报销", descriptionText: "未来计划样例任务。", now: seedNow())
            try engine.setTaskTagAssignment(chainID: invoice, slot: .tagI, tagID: lifeTag, now: seedNow())
            _ = try engine.scheduleFromPool(chainID: invoice, date: day5, today: day3, now: now)
            let dinner = try engine.createPoolTask(title: "预订团队聚餐餐厅", descriptionText: "未来计划样例任务。", now: seedNow())
            try engine.setTaskTagAssignment(chainID: dinner, slot: .tagI, tagID: lifeTag, now: seedNow())
            _ = try engine.scheduleFromPool(chainID: dinner, date: day4, today: day3, now: now)

            engine.settleDays(upTo: day3, now: now)

            engine.updateDailyReview(
                date: day1,
                summary: "合同邮件处理完毕；OKR 草案低估了工作量，明天优先。",
                unfinishedReason: "OKR 依赖的数据下午才拿到，被会议切碎。",
                tomorrowNote: "上午先做 OKR，别先开邮箱。"
            )
            engine.updateDailyReview(
                date: day2,
                summary: "周报和图标脚本推进顺利；竞品调研范围太大，拆成了对比表任务。",
                unfinishedReason: "竞品对比表低估了整理时间。",
                tomorrowNote: "对比表先列框架再填数据。"
            )
            engine.updateDailyReview(
                date: day3,
                summary: "",
                unfinishedReason: "",
                tomorrowNote: ""
            )
        } catch {
            assertionFailure("Seed data failed: \(error)")
        }
    }
}

struct SuntraceRootView: View {
    @EnvironmentObject private var store: SuntraceStore

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                Sidebar()
                MainSurface()
            }
            .background(Theme.background)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                WindowBoundaryStroke(cornerRadius: 12)
            )
            .ignoresSafeArea()

            if let toast = store.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.background)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Theme.text1))
                        .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 30)
                }
            }
        }
        .sheet(item: Binding(
            get: { store.showingPicker.map(PickerSheetState.init(purpose:)) },
            set: { if $0 == nil { store.showingPicker = nil } }
        )) { state in
            DatePickerSheet(state: state)
                .environmentObject(store)
        }
        .sheet(isPresented: $store.showingFromPoolPicker) {
            FromPoolSheet()
                .environmentObject(store)
        }
        .sheet(isPresented: $store.showingChangeDialog) {
            ChangeTaskSheet()
                .environmentObject(store)
        }
        .onMoveCommand { direction in
            store.moveSelectedDate(direction)
        }
        .onAppear(perform: syncNativeWindowTitle)
        .onChange(of: store.windowTitle) { _, _ in
            syncNativeWindowTitle()
        }
        .onChange(of: store.isZhulongEnabled) { _, _ in
            store.ensureVisiblePage()
        }
    }

    private func syncNativeWindowTitle() {
        NSApp.windows.first { $0 is SuntraceWindow }?.title = store.windowTitle
    }
}

struct PickerSheetState: Identifiable {
    let id = UUID()
    let purpose: SuntraceStore.DatePickerPurpose
}

struct AppCopy {
    let language: AppLanguage

    var appName: String {
        switch language {
        case .chinese: "晷迹"
        case .english: "Noonmark"
        }
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
    var today: String { language == .chinese ? "今天" : "Today" }
    var chooseDate: String { language == .chinese ? "选日期" : "Choose date" }
    var openDay: String { language == .chinese ? "查看当天 →" : "Open day →" }
    var copyAsNewTask: String { language == .chinese ? "复制为新任务" : "Copy as new task" }
    var reschedule: String { language == .chinese ? "改期…" : "Reschedule…" }
    var returnToPool: String { language == .chinese ? "回池" : "Back to pool" }
    var scheduleToday: String { language == .chinese ? "排期到今天" : "Schedule today" }
    var scheduleTomorrow: String { language == .chinese ? "排期到明天" : "Schedule tomorrow" }
    var schedulePickDate: String { language == .chinese ? "选日期…" : "Pick date…" }
    var continueTo: String { language == .chinese ? "延续到…" : "Continue to…" }
    var abandonChain: String { language == .chinese ? "废弃任务链" : "Drop chain" }
    var markComplete: String { language == .chinese ? "标记完成" : "Mark complete" }
    var undoComplete: String { language == .chinese ? "撤销完成" : "Undo complete" }
    var changeToNewTask: String { language == .chinese ? "变更为新任务…" : "Change to new task…" }
    var returnToPoolWithTrace: String { language == .chinese ? "回到任务池（留下轨迹）" : "Back to pool, keep trace" }
    var schedulePickSpecificDate: String { language == .chinese ? "排期到指定日期…" : "Schedule to date…" }
    var openCurrentPending: String { language == .chinese ? "跳转到当前待完成" : "Open current pending" }
    var copyParentAsNewTask: String { language == .chinese ? "复制父任务为新任务" : "Copy parent as new task" }
    var copyParentTask: String { language == .chinese ? "复制父任务" : "Copy parent task" }

    var lockedDayNotice: String {
        language == .chinese
            ? "历史日已锁定：任务事实不可改写，可补写复盘。未完成任务可延续或废弃。"
            : "This day is locked: task facts cannot be rewritten. You can still write the review, continue unfinished tasks, or drop them."
    }

    var futureDayNotice: String {
        language == .chinese
            ? "未来日：可排期与调整顺序，不能提前完成或生成复盘。"
            : "Future day: schedule and reorder only. Completion and review are not available yet."
    }

    var emptyDay: String { language == .chinese ? "这一天没有留下任务。" : "No tasks were left on this day." }
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
        language == .chinese ? "按任务链去重的未完成轨迹。延续它，或明确废弃。" : "Unfinished trails deduped by task chain. Continue them or drop them explicitly."
    }

    var emptyUnfinished: String { language == .chinese ? "没有待处理的未完成任务。" : "Nothing unfinished to handle." }
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
    var settingsPoemTitle: String { language == .chinese ? "设置页诗文" : "Settings poem" }
    var settingsPoemDisplay: String { language == .chinese ? "右侧展示诗文" : "Show poem on the right" }
    var settingsPoemEditorTitle: String { language == .chinese ? "诗文内容" : "Poem text" }
    var resetSettingsPoem: String { language == .chinese ? "恢复默认《苦昼短》" : "Restore default" }
    var settingsPoemResetToast: String { language == .chinese ? "已恢复默认诗文" : "Default poem restored" }

    var dataSectionTitle: String { language == .chinese ? "数据" : "Data" }
    var dataSectionSubtitle: String {
        language == .chinese ? "导出和导入本机数据包。" : "Export and import local data packages."
    }

    var exportJSON: String { language == .chinese ? "导出数据 (JSON)" : "Export JSON" }
    var importData: String { language == .chinese ? "导入数据…" : "Import…" }
    var todayTraceMetric: String { language == .chinese ? "今日轨迹" : "Today" }
    var taskPoolMetric: String { navPool }
    var unfinishedMetric: String { navUnfinished }
    var completedMetric: String { navCompleted }
    var syncTitle: String { language == .chinese ? "同步" : "Sync" }
    var syncSubtitle: String {
        language == .chinese
            ? "本地优先使用云端点同步仓库；在线优先才允许旁路定时备份。"
            : "Local-first uses a cloud sync endpoint; only online-first allows scheduled backup."
    }

    var planned: String { language == .chinese ? "规划中" : "Planned" }
    var available: String { language == .chinese ? "可用" : "Available" }
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
    var syncSnapshotPolicyTitle: String { language == .chinese ? "快照保留" : "Snapshot retention" }
    var syncConflictCopyTitle: String { language == .chinese ? "冲突副本" : "Conflict copy" }
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
            ? "iCloud Drive 端点已接入：远端逻辑位置如下，本机路径是系统同步镜像。"
            : "The iCloud Drive endpoint is active: the logical cloud location is below; the local path is the system-synced mirror."
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
            ? "参考思源：本机仍是事实源；同步前生成快照索引，远端只保存同步仓库对象。iCloud 和本地文件夹端点已可用，S3/WebDAV 继续按同一仓库协议接入。"
            : "Following SiYuan: local data remains primary; sync creates snapshot indexes before exchanging repository objects. iCloud and local folder endpoints are available; S3/WebDAV will use the same repository protocol."
    }

    var scheduledBackupTitle: String { language == .chinese ? "定时备份" : "Scheduled backup" }
    var backupDestinationTitle: String { language == .chinese ? "备份目标" : "Backup destination" }
    var backupOff: String { language == .chinese ? "关闭" : "Off" }
    var backupDaily: String { language == .chinese ? "每日" : "Daily" }
    var backupWeekly: String { language == .chinese ? "每周" : "Weekly" }
    var backupICloudDrive: String { language == .chinese ? "iCloud" : "iCloud" }
    var backupS3: String { language == .chinese ? "S3" : "S3" }
    var backupBoundary: String {
        language == .chinese
            ? "在线优先可定时导出本地可恢复数据包到 iCloud 或 S3；这不是双向同步。"
            : "Online-first can export restorable local packages to iCloud or S3 on a schedule; this is not bidirectional sync."
    }

    var providerTitle: String { language == .chinese ? "烛龙配置" : "Zhulong Configuration" }
    var providerSubtitle: String {
        language == .chinese ? "烛龙是可选 sidecar；普通清单不依赖 Provider。" : "Zhulong is optional; normal lists do not depend on a Provider."
    }

    var zhulongSubtitle: String {
        language == .chinese
            ? "可选 sidecar：复盘分析、任务拆解、排期建议和 label 分类建议。"
            : "Optional sidecar for reviews, decomposition, scheduling, and label suggestions."
    }

    var analyzeTodayWithZhulong: String {
        language == .chinese ? "让烛龙分析今日" : "Analyze today"
    }

    var providerConfigured: String { language == .chinese ? "Provider 已配置" : "Provider configured" }
    var providerIncomplete: String { language == .chinese ? "配置不完整" : "Incomplete" }
    var providerDisabled: String { language == .chinese ? "烛龙未启用" : "Zhulong disabled" }
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
    var backupPolicyChangedToast: String { language == .chinese ? "备份策略已更新" : "Backup policy updated" }
    var localFirstSyncChangedToast: String { language == .chinese ? "本地优先同步设置已更新" : "Local-first sync settings updated" }

    func localFirstSyncResult(_ result: SQLiteLocalFirstSyncResult) -> String {
        switch language {
        case .chinese:
            "同步完成：上传 \(result.upload.uploadedCount) 条，下载合并 \(result.download.appliedCount) 条，冲突 \(result.download.conflictCount) 条"
        case .english:
            "Sync complete: uploaded \(result.upload.uploadedCount), merged \(result.download.appliedCount), conflicts \(result.download.conflictCount)"
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
                "创建、排期、变更、延续、废弃或 label 写入都必须由用户确认。",
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
        case (.chinese, .iCloud): "使用 iCloud 作为同步仓库端点"
        case (.chinese, .s3): "使用兼容 S3 的对象存储"
        case (.chinese, .webDAV): "使用兼容 WebDAV 的远端目录"
        case (.chinese, .localFolder): "使用自管目录或局域网共享"
        case (.english, .customEndpoint): "Connect your own server"
        case (.english, .iCloud): "Use iCloud as the sync repository endpoint"
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

    func backupFrequencyTitle(for frequency: ScheduledBackupFrequency) -> String {
        switch frequency {
        case .off: backupOff
        case .daily: backupDaily
        case .weekly: backupWeekly
        }
    }

    func backupDestinationTitle(for destination: BackupDestinationKind) -> String {
        switch destination {
        case .iCloudDrive: backupICloudDrive
        case .s3: backupS3
        }
    }
}

private struct WindowBoundaryStroke: View {
    var cornerRadius: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Theme.windowBoundary, lineWidth: 1.35)
            RoundedRectangle(cornerRadius: cornerRadius - 0.7, style: .continuous)
                .inset(by: 1)
                .stroke(.white.opacity(0.78), lineWidth: 0.7)
        }
        .allowsHitTesting(false)
    }
}

enum Theme {
    struct Palette {
        let desk: Color
        let background: Color
        let panel: Color
        let panel2: Color
        let line: Color
        let line2: Color
        let windowBoundary: Color
        let text1: Color
        let text2: Color
        let text3: Color
        let chip: Color
        let sidebar: Color
        let controlFill: Color
        let listRowHover: Color
    }

    private nonisolated(unsafe) static var activeTheme: AppTheme = .coolGray

    static func apply(_ theme: AppTheme) {
        activeTheme = theme
    }

    static func hex(_ value: Int) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    static var palette: Palette {
        switch activeTheme {
        case .coolGray:
            return Palette(
                desk: Color(red: 0.925, green: 0.928, blue: 0.936),
                background: Color(red: 0.994, green: 0.993, blue: 0.991),
                panel: .white,
                panel2: Color(red: 0.984, green: 0.984, blue: 0.987),
                line: Color(red: 0.90, green: 0.902, blue: 0.914),
                line2: Color(red: 0.80, green: 0.805, blue: 0.835),
                windowBoundary: Color(red: 0.69, green: 0.704, blue: 0.735),
                text1: Color(red: 0.11, green: 0.11, blue: 0.12),
                text2: Color(red: 0.42, green: 0.42, blue: 0.46),
                text3: Color(red: 0.63, green: 0.63, blue: 0.67),
                chip: Color(red: 0.951, green: 0.951, blue: 0.958),
                sidebar: Color(red: 0.982, green: 0.981, blue: 0.978),
                controlFill: Color(red: 0.996, green: 0.996, blue: 0.997),
                listRowHover: Color(red: 0.977, green: 0.979, blue: 0.984)
            )
        case .warmPaper:
            return Palette(
                desk: Color(red: 0.93, green: 0.914, blue: 0.882),
                background: Color(red: 0.997, green: 0.992, blue: 0.982),
                panel: Color(red: 1.0, green: 0.998, blue: 0.992),
                panel2: Color(red: 0.990, green: 0.982, blue: 0.964),
                line: Color(red: 0.90, green: 0.872, blue: 0.824),
                line2: Color(red: 0.78, green: 0.724, blue: 0.646),
                windowBoundary: Color(red: 0.67, green: 0.61, blue: 0.52),
                text1: Color(red: 0.13, green: 0.105, blue: 0.085),
                text2: Color(red: 0.44, green: 0.385, blue: 0.32),
                text3: Color(red: 0.64, green: 0.58, blue: 0.50),
                chip: Color(red: 0.957, green: 0.946, blue: 0.925),
                sidebar: Color(red: 0.989, green: 0.979, blue: 0.957),
                controlFill: Color(red: 1.0, green: 0.997, blue: 0.989),
                listRowHover: Color(red: 0.989, green: 0.981, blue: 0.966)
            )
        }
    }

    static var desk: Color { palette.desk }
    static var background: Color { palette.background }
    static var panel: Color { palette.panel }
    static var panel2: Color { palette.panel2 }
    static var line: Color { palette.line }
    static var line2: Color { palette.line2 }
    static var windowBoundary: Color { palette.windowBoundary }
    static var text1: Color { palette.text1 }
    static var text2: Color { palette.text2 }
    static var text3: Color { palette.text3 }
    static var chip: Color { palette.chip }
    static var sidebar: Color { palette.sidebar }
    static var controlFill: Color { palette.controlFill }
    static var listRowHover: Color { palette.listRowHover }
    static let accent = Color(red: 0.16, green: 0.38, blue: 0.78)
    static let accentSoft = Color(red: 0.93, green: 0.955, blue: 1.0)
    static let ok = Color(red: 0.08, green: 0.55, blue: 0.38)
    static let okSoft = Color(red: 0.91, green: 0.98, blue: 0.95)
    static let warn = Color(red: 0.706, green: 0.302, blue: 0.204)
    static let warnSoft = Color(red: 1.0, green: 0.937, blue: 0.922)
    static let noteBackground = Color(red: 1.0, green: 0.984, blue: 0.937)
    static let navDay = hex(0x2A6FDB)
    static let navPool = hex(0x0E9488)
    static let navFuture = hex(0x7C5CFF)
    static let navUnfinished = hex(0xE0851B)
    static let navCompleted = hex(0x1F8A5B)
    static let navCalendar = hex(0xD1477A)
    static let navZhulong = hex(0x7C5CFF)
    static let navSettings = hex(0x64748B)
}

struct TrafficLightDots: View {
    var body: some View {
        HStack(spacing: 9) {
            trafficLight(
                color: Color(red: 1, green: 0.451, blue: 0.416),
                accessibilityLabel: "关闭窗口",
                action: closeWindow
            )
            trafficLight(
                color: Color(red: 0.996, green: 0.737, blue: 0.18),
                accessibilityLabel: "最小化窗口",
                action: minimizeWindow
            )
            trafficLight(
                color: Color(red: 0.098, green: 0.765, blue: 0.188),
                accessibilityLabel: "缩放窗口",
                action: zoomWindow
            )
        }
        .frame(height: 14)
    }

    private func trafficLight(
        color: Color,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .overlay(Circle().stroke(.black.opacity(0.1), lineWidth: 0.5))
                .frame(width: 14, height: 14)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func closeWindow() {
        currentWindow?.close()
    }

    private func minimizeWindow() {
        currentWindow?.miniaturize(nil)
    }

    private func zoomWindow() {
        currentWindow?.zoom(nil)
    }

    private var currentWindow: NSWindow? {
        NSApp.keyWindow ?? NSApp.windows.first { $0 is SuntraceWindow }
    }
}

struct Sidebar: View {
    @EnvironmentObject private var store: SuntraceStore

    var planPages: [SuntraceStore.Page] {
        [.day, .pool, .future]
    }

    var tracePages: [SuntraceStore.Page] {
        [.unfinished, .completed, .calendar, .zhulong]
            .filter { store.visibleNavigationPages.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TrafficLightDots()
                .padding(.horizontal, 18)
                .padding(.bottom, 24)

            HStack(spacing: 9) {
                ClockLogo()
                Text(store.copy.appName)
                    .font(.system(size: 16, weight: .bold))
                    .tracking(0.2)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 16)

            NavGroupTitle(store.copy.planGroup)
            ForEach(planPages) { page in
                NavItem(page: page, label: store.navigationLabel(for: page), count: store.navigationCount(for: page))
            }

            NavGroupTitle(store.copy.traceGroup)
                .padding(.top, 12)
            ForEach(tracePages) { page in
                NavItem(page: page, label: store.navigationLabel(for: page), count: store.navigationCount(for: page))
            }

            Spacer()
            NavItem(page: .settings, label: store.copy.navSettings, count: 0)
        }
        .frame(width: 222)
        .padding(.top, 16)
        .padding(.bottom, 10)
        .background(Theme.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.line.opacity(0.55)).frame(width: 1)
        }
    }
}

struct ClockLogo: View {
    var body: some View {
        ZStack {
            Circle().stroke(Theme.accent, lineWidth: 1.5)
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 1.5, height: 7)
                .offset(y: -3)
            Circle().fill(Theme.accent).frame(width: 4, height: 4)
        }
        .frame(width: 22, height: 22)
    }
}

struct NavGroupTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
            Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.text3)
            .tracking(0.4)
            .padding(.horizontal, 18)
            .padding(.bottom, 4)
    }
}

struct NavItem: View {
    @EnvironmentObject private var store: SuntraceStore
    let page: SuntraceStore.Page
    let label: String
    let count: Int

    var active: Bool { store.page == page }

    var body: some View {
        Button {
            store.selectPage(page)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: page.navigationSystemImage)
                    .font(.system(size: 14.5, weight: .medium))
                    .frame(width: 19)
                    .foregroundStyle(page.navigationIconColor)
                Text(label)
                    .font(.system(size: 13.5, weight: active ? .semibold : .medium))
                    .foregroundStyle(active ? Theme.text1 : Theme.text2)
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: active ? .semibold : .regular))
                        .foregroundStyle(Theme.text2)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 19, minHeight: 17)
                        .background(Capsule().fill(active ? Theme.panel.opacity(0.8) : Theme.chip))
                }
            }
            .frame(height: 33)
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .hoverSurface(
                active: active,
                cornerRadius: 8,
                idleFill: .clear,
                hoverFill: Theme.panel.opacity(0.72),
                activeFill: page.navigationIconColor.opacity(0.11),
                idleStroke: .clear,
                hoverStroke: Theme.line.opacity(0.45),
                activeStroke: .clear
            )
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 99)
                    .fill(active ? page.navigationIconColor : .clear)
                    .frame(width: 2.5, height: 16)
                    .padding(.leading, 3)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
    }
}

struct MainSurface: View {
    @EnvironmentObject private var store: SuntraceStore

    var body: some View {
        HStack(spacing: 0) {
            Group {
                switch store.page {
                case .day:
                    DayTodoPage()
                case .pool:
                    TaskPoolPage()
                case .future:
                    FuturePlansPage()
                case .unfinished:
                    UnfinishedPoolPage()
                case .completed:
                    CompletedPoolPage()
                case .calendar:
                    CalendarPage()
                case .zhulong:
                    ZhulongPage()
                case .settings:
                    SettingsPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if store.shouldShowDetailRail {
                DetailRail()
                    .frame(width: 300)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Theme.line.opacity(0.58)).frame(width: 1)
                    }
            }
        }
        .background(Theme.panel)
    }
}

struct TaskSelectionClearingScrollView<Content: View>: View {
    @EnvironmentObject private var store: SuntraceStore
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Theme.panel)
                        .contentShape(Rectangle())
                        .onTapGesture { store.clearSelection() }
                    content
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: proxy.size.height,
                    alignment: .topLeading
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct DayTodoPage: View {
    @EnvironmentObject private var store: SuntraceStore

    var traces: [DayTrace] {
        store.engine.getDayTodo(date: store.selectedDate).traces
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DayTodoHeader(dayBadge: dayBadge, badgeColor: badgeColor)

            DateStrip()
                .padding(.horizontal, 24)
                .padding(.bottom, 10)

            if store.isHistory {
                Notice(text: store.copy.lockedDayNotice, tone: .locked)
                    .padding(.horizontal, 24)
            } else if store.isFuture {
                Notice(text: store.copy.futureDayNotice, tone: .future)
                    .padding(.horizontal, 24)
            }

            TaskSelectionClearingScrollView {
                VStack(spacing: 0) {
                    if store.isHistory == false {
                        DayQuickAdd()
                            .padding(.bottom, 12)
                    }

                    LazyVStack(spacing: 0) {
                        ForEach(traces, id: \.id) { trace in
                            TaskRow(trace: trace)
                        }

                        if traces.isEmpty {
                            EmptyState(kind: .dayTodo, text: store.copy.emptyDay)
                                .padding(.top, 40)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, store.isHistory ? 12 : 14)
                .padding(.bottom, 20)
            }
        }
    }

    private var dayBadge: String {
        if store.selectedDate == store.today { return "今日" }
        if store.isHistory { return "历史已锁定" }
        return "未来"
    }

    private var badgeColor: Color {
        if store.selectedDate == store.today { return Theme.accent }
        if store.isHistory { return Theme.text2 }
        return Theme.accent
    }
}

struct DayTodoHeader: View {
    @EnvironmentObject private var store: SuntraceStore
    let dayBadge: String
    let badgeColor: Color

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(SuntraceStore.displayFullDate(store.selectedDate))
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(Theme.text1)
                .monospacedDigit()
                .lineLimit(1)
            Text(SuntraceStore.weekday(store.selectedDate))
                .font(.system(size: 12))
                .foregroundStyle(Theme.text3)
                .lineLimit(1)
            DayStateBadge(text: dayBadge, color: badgeColor, filled: store.selectedDate == store.today)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                HeaderButton("‹") { store.selectedDate = SuntraceStore.offset(store.selectedDate, by: -1) }
                HeaderButton(store.copy.today) { store.selectedDate = store.today }
                HeaderButton("›") { store.selectedDate = SuntraceStore.offset(store.selectedDate, by: 1) }
                HeaderButton(store.copy.chooseDate) { store.showingPicker = .gotoDay }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
    }
}

struct DayStateBadge: View {
    let text: String
    let color: Color
    let filled: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(filled ? .white : color)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(filled ? color : color.opacity(0.12)))
    }
}

struct DayQuickAdd: View {
    @EnvironmentObject private var store: SuntraceStore

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            NewTaskInlineField(
                placeholder: store.isFuture ? "为这一天排期任务，回车确认" : "添加今日任务，回车确认",
                text: $store.quickText
            ) {
                store.addQuickTask()
            }
            HeaderButton(store.copy.scheduleFromPool) { store.showingFromPoolPicker = true }
        }
    }
}

struct NewTaskInlineField: View {
    @EnvironmentObject private var store: SuntraceStore
    let placeholder: String
    @Binding var text: String
    let onSubmit: () -> Void

    var suggestions: [TaskTag] {
        store.newTaskTagSuggestions(for: text)
    }

    var primarySuggestionCount: Int {
        store.primaryNewTaskSuggestionCount(for: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.controlFill))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line.opacity(0.72)))
                .onSubmit(onSubmit)

            if store.shouldShowNewTaskTagSuggestions(for: text) {
                VStack(spacing: 0) {
                    ForEach(Array(suggestions.prefix(6).enumerated()), id: \.element.id) { index, tag in
                        if index == primarySuggestionCount, primarySuggestionCount > 0 {
                            Rectangle()
                                .fill(Theme.line)
                                .frame(height: 1)
                                .padding(.vertical, 2)
                        }
                        Button {
                            text = store.completeLastHashToken(in: text, with: tag.name)
                        } label: {
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(tag.color)
                                    .frame(width: 7, height: 7)
                                Text("#\(tag.name)")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(Theme.text1)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 9)
                            .frame(height: 28)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line.opacity(0.72)))
                .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
            }
        }
        .layoutPriority(1)
    }
}

struct DateStrip: View {
    @EnvironmentObject private var store: SuntraceStore

    var dates: [LocalDate] { store.dateStripDates() }

    var body: some View {
        ZStack(alignment: .topLeading) {
            DateStripSelectionPill(selectedIndex: store.selectedDateStripIndex, cellCount: dates.count)
                .frame(height: 52)
                .clipped()

            HStack(spacing: 0) {
                ForEach(dates, id: \.self) { date in
                    let selected = date == store.selectedDate
                    let today = date == store.today
                    let count = store.engine.getDayTodo(date: date).traces.count
                    Button {
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.74)) {
                            store.selectedDate = date
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Text(SuntraceStore.weekday(date).replacingOccurrences(of: "周", with: ""))
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(Theme.text3)
                            Text("\(date.day)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(selected ? .white : today ? Theme.accent : Theme.text1)
                                .frame(width: 24, height: 24)
                                .overlay(Circle().stroke(today && !selected ? Theme.accent : .clear, lineWidth: 1.5))
                            Circle()
                                .fill(count > 0 ? (selected ? .white.opacity(0.9) : Theme.accent) : .clear)
                                .frame(width: 4, height: 4)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line.opacity(0.62)).frame(height: 1)
        }
    }
}

struct DateStripSelectionPill: View {
    let selectedIndex: Int?
    let cellCount: Int

    var body: some View {
        GeometryReader { proxy in
            if let selectedIndex, cellCount > 0 {
                let cellWidth = proxy.size.width / CGFloat(cellCount)
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 24, height: 24)
                    .shadow(color: Theme.accent.opacity(0.34), radius: 6, x: 0, y: 2)
                    .offset(
                        x: cellWidth * CGFloat(selectedIndex) + (cellWidth - 24) / 2,
                        y: 17
                    )
                    .animation(.spring(response: 0.24, dampingFraction: 0.74), value: selectedIndex)
            }
        }
        .allowsHitTesting(false)
    }
}

struct TaskRow: View {
    @EnvironmentObject private var store: SuntraceStore
    let trace: DayTrace

    var definition: TaskDefinition? { store.definition(for: trace) }
    var progress: TraceProgress { store.engine.traceProgress(for: trace.id) }
    var subtasks: [Subtask] { store.subtasks(for: trace.id) }
    var selected: Bool { store.selectedTraceID == trace.id }
    var expanded: Bool { store.expandedTraceIDs.contains(trace.id) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Button {
                    store.toggleComplete(trace.id)
                } label: {
                    StatusGlyph(status: trace.status)
                }
                .buttonStyle(.plain)
                .disabled(trace.status != .pending && trace.status != .completed)

                VStack(alignment: .leading, spacing: 0) {
                    Text(definition?.title ?? "未命名任务")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(trace.status.uiStyle.titleColor)
                        .strikethrough(trace.status.uiStyle.strikethrough)

                    TaskTagStrip(tags: store.tags(for: trace.chainID))

                    if showsProgress {
                        HStack(spacing: 6) {
                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Theme.chip)
                                    Capsule()
                                        .fill(progress.percent == 100 ? Theme.ok : Theme.accent)
                                        .frame(width: proxy.size.width * CGFloat(progress.percent) / 100)
                                }
                            }
                            .frame(width: 150, height: 4)
                            Text("\(progress.percent)%")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(progress.percent == 100 ? Theme.ok : Theme.accent)
                        }
                        .padding(.top, 5)
                    }

                    if metaText.isEmpty == false {
                        Text(metaText)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.text3)
                            .padding(.top, 2)
                    }

                    if let changedTarget = store.changedTarget(for: trace) {
                        ChangedTargetButton(
                            title: changedTarget.definition.title,
                            compact: true
                        ) {
                            store.openChangedTarget(from: trace)
                        }
                        .padding(.top, 3)
                    }
                }

                Spacer()

                if subtasks.isEmpty == false {
                    Button {
                        if expanded {
                            store.expandedTraceIDs.remove(trace.id)
                        } else {
                            store.expandedTraceIDs.insert(trace.id)
                        }
                    } label: {
                        SubtaskDisclosureLabel(count: subtasks.count, expanded: expanded)
                    }
                    .buttonStyle(.plain)
                }

                StatusChip(status: trace.status)

                if canReorder {
                    PriorityStepper(
                        canMoveUp: canMoveUp,
                        canMoveDown: canMoveDown,
                        moveUp: { store.movePriority(trace.id, delta: -1) },
                        moveDown: { store.movePriority(trace.id, delta: 1) }
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            if expanded {
                VStack(spacing: 6) {
                    ForEach(subtasks, id: \.id) { subtask in
                        SubtaskRow(subtask: subtask)
                    }
                }
                .padding(.top, 1)
                .padding(.leading, 40)
                .padding(.trailing, 12)
                .padding(.bottom, 10)
            }
        }
        .listRowSurface(selected: selected, tint: Theme.accent, separatorLeadingInset: 44)
        .contentShape(Rectangle())
        .onTapGesture { store.selectTrace(trace.id) }
        .contextMenu {
            TaskContextMenu(trace: trace)
        }
    }

    var metaText: String {
        var parts: [String] = []
        if trace.continuationSeq > 0 {
            parts.append("第 \(trace.continuationSeq) 次延续 · 持续 \(store.continuationDurationDays(for: trace)) 天")
        }
        if trace.status == .returnedToPool { parts.append("当天已回池") }
        return parts.joined(separator: " · ")
    }

    var showsProgress: Bool {
        guard progress.percent > 0, progress.percent < 100 else { return false }
        switch trace.status {
        case .pending, .continued, .unfinished:
            return true
        case .completed, .changed, .returnedToPool, .abandoned:
            return false
        }
    }

    var canReorder: Bool {
        trace.status == .pending && (store.selectedDate == store.today || store.selectedDate > store.today)
    }

    var canMoveUp: Bool {
        canReorder && trace.priority > (reorderablePriorities.min() ?? 1)
    }

    var canMoveDown: Bool {
        guard let maxPriority = reorderablePriorities.max() else { return false }
        return canReorder && trace.priority < maxPriority
    }

    var reorderablePriorities: [Int] {
        store.engine.getDayTodo(date: trace.date).traces
            .filter { $0.status == .pending }
            .map(\.priority)
    }
}

struct SubtaskDisclosureLabel: View {
    let count: Int
    let expanded: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .rotationEffect(.degrees(expanded ? 90 : 0))
            Text("\(count) 子任务")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(Capsule().fill(Theme.accentSoft))
        .contentShape(Capsule())
    }
}

struct ChangedTargetButton: View {
    let title: String
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text("被变更为：")
                    .foregroundStyle(Theme.text3)
                Text(title)
                    .lineLimit(1)
                Image(systemName: "arrow.right")
                    .font(.system(size: compact ? 8.5 : 9.5, weight: .bold))
            }
            .font(.system(size: compact ? 10.5 : 11, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, compact ? 0 : 7)
            .frame(height: compact ? nil : 22)
            .background {
                if !compact {
                    Capsule().fill(Theme.accentSoft)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct SubtaskRow: View {
    @EnvironmentObject private var store: SuntraceStore
    let subtask: Subtask

    var canMutate: Bool {
        store.canMutateSubtask(subtask)
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                store.toggleSubtask(subtask.id)
            } label: {
                RoundedRectangle(cornerRadius: 5)
                    .fill(subtask.status == .completed ? Theme.ok : Theme.panel)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(subtask.status == .completed ? Theme.ok : Theme.line2, lineWidth: 1.5))
                    .overlay(Text(subtask.status == .completed ? "✓" : "").font(.system(size: 9)).foregroundStyle(.white))
                    .frame(width: 15, height: 15)
            }
            .buttonStyle(.plain)

            Text(subtask.title)
                .font(.system(size: 12))
                .foregroundStyle(subtask.status == .completed ? Theme.text3 : Theme.text1)
                .strikethrough(subtask.status == .completed)

            Spacer()

            if subtask.completedAt != nil && canMutate == false {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.text3)
            }

            Menu {
                ForEach(SubtaskDifficulty.allCases, id: \.self) { difficulty in
                    Button {
                        store.setSubtaskDifficulty(subtask.id, difficulty: difficulty)
                    } label: {
                        Label(
                            difficultyMenuTitle(difficulty),
                            systemImage: difficulty == subtask.difficulty ? "checkmark.circle.fill" : "circle"
                        )
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 9, weight: .semibold))
                    Text(subtask.difficulty.label)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(subtask.difficulty == .hard ? Theme.warn : Theme.text2)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(subtask.difficulty == .hard ? Theme.warnSoft : Theme.chip))
                .overlay(Capsule().stroke(Theme.line2))
            }
            .buttonStyle(.plain)
            .help(canMutate ? "修改子任务难度" : "当前子任务不可改写")
        }
    }

    private func difficultyMenuTitle(_ difficulty: SubtaskDifficulty) -> String {
        switch difficulty {
        case .simple:
            return "简单"
        case .medium:
            return "中等"
        case .hard:
            return "困难"
        }
    }
}

struct TaskContextMenu: View {
    @EnvironmentObject private var store: SuntraceStore
    let trace: DayTrace
    var actions: [SuntraceStore.TraceContextAction] { store.contextMenuActions(for: trace) }

    var body: some View {
        ForEach(actions, id: \.self) { action in
            switch action {
            case .markComplete:
                Button(store.copy.markComplete) { store.toggleComplete(trace.id) }
            case .undoComplete:
                Button(store.copy.undoComplete) { store.toggleComplete(trace.id) }
            case .continueTo:
                Button(store.copy.continueTo) { store.showingPicker = .continueTrace(trace.id) }
            case .changeToNewTask:
                Button(store.copy.changeToNewTask) {
                    store.selectTrace(trace.id)
                    store.changeText = store.definition(for: trace)?.title ?? ""
                    store.showingChangeDialog = true
                }
            case .returnToPool:
                Button(store.copy.returnToPoolWithTrace) { store.returnToPool(trace.id) }
            case .reschedule:
                Button(store.copy.reschedule) { store.showingPicker = .reschedule(trace.id) }
            case .copyAsNewTask:
                Button(store.copy.copyAsNewTask) { store.copyAsNewTask(trace.id) }
            case .abandonChain:
                Button(store.copy.abandonChain, role: .destructive) { store.abandon(trace.id) }
            }
        }
    }
}

struct TaskPoolPage: View {
    @EnvironmentObject private var store: SuntraceStore

    var tasks: [PoolTask] { store.engine.taskPool() }
    var groups: [PoolTaskGroup] {
        Dictionary(grouping: tasks, by: { store.primaryTagName(for: $0.chain) })
            .map { PoolTaskGroup(title: $0.key, tasks: $0.value.sorted { $0.definition.createdAt < $1.definition.createdAt }) }
            .sorted {
                if $0.title == "未标记" { return false }
                if $1.title == "未标记" { return true }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
    }

    var shouldShowGroups: Bool {
        groups.count > 1 || groups.contains { $0.title != "未标记" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                PageHeader(title: store.copy.navPool, subtitle: store.copy.poolSubtitle)
                Spacer()
            }
            TaskSelectionClearingScrollView {
                VStack(spacing: 0) {
                    PoolQuickAdd()
                        .padding(.bottom, 12)

                    LazyVStack(spacing: 0) {
                        if shouldShowGroups {
                            ForEach(groups) { group in
                                VStack(alignment: .leading, spacing: 0) {
                                    HStack(spacing: 8) {
                                        Text(group.title)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(Theme.text2)
                                        Text("\(group.tasks.count)")
                                            .font(.system(size: 10.5, weight: .semibold))
                                            .foregroundStyle(Theme.text3)
                                            .padding(.horizontal, 6)
                                            .frame(height: 18)
                                            .background(Capsule().fill(Theme.chip))
                                        Spacer()
                                    }
                                    .padding(.top, 12)
                                    .padding(.bottom, 4)
                                    ForEach(group.tasks, id: \.chain.id) { task in
                                        PoolTaskRow(task: task)
                                    }
                                }
                            }
                        } else {
                            ForEach(tasks, id: \.chain.id) { task in
                                PoolTaskRow(task: task)
                            }
                        }
                        if tasks.isEmpty {
                            EmptyState(kind: .taskPool, text: store.copy.emptyPool)
                                .padding(.top, 40)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
        }
    }
}

struct PoolTaskGroup: Identifiable {
    let title: String
    let tasks: [PoolTask]

    var id: String { title }
}

struct PoolQuickAdd: View {
    @EnvironmentObject private var store: SuntraceStore

    var body: some View {
        NewTaskInlineField(
            placeholder: "新建任务到任务池，回车确认",
            text: $store.poolText
        ) {
            store.addPoolTask()
        }
    }
}

struct PoolTaskRow: View {
    @EnvironmentObject private var store: SuntraceStore
    let task: PoolTask

    var body: some View {
        let selected = store.selectedPoolChainID == task.chain.id
        HStack(spacing: 10) {
            PoolTaskPlaceholderGlyph()
            Text(task.definition.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text1)
                .lineLimit(1)
            ForEach(store.tags(for: task.chain), id: \.assignment.id) { tagged in
                TaskTagChip(tag: tagged.tag, slot: tagged.assignment.slot)
            }
            Spacer()
            SmallActionButton(store.copy.scheduleToday, tone: .accent) { store.schedulePoolTask(task.chain.id, date: store.today) }
            SmallActionButton(store.copy.scheduleTomorrow) { store.schedulePoolTask(task.chain.id, date: SuntraceStore.offset(store.today, by: 1)) }
            SmallActionButton(store.copy.schedulePickDate) { store.showingPicker = .schedulePool(task.chain.id) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .listRowSurface(selected: selected, tint: Theme.navPool, separatorLeadingInset: 40)
        .onTapGesture { store.selectPool(task.chain.id) }
    }
}

struct TaskTagStrip: View {
    let tags: [(assignment: TaskTagAssignment, tag: TaskTag)]

    var body: some View {
        if tags.isEmpty == false {
            HStack(spacing: 6) {
                ForEach(tags, id: \.assignment.id) { tagged in
                    TaskTagChip(tag: tagged.tag, slot: tagged.assignment.slot)
                }
            }
            .padding(.top, 4)
        }
    }
}

struct TaskTagChip: View {
    let tag: TaskTag
    let slot: TaskTagSlot

    var body: some View {
        let active = tag.status == .active
        HStack(spacing: 5) {
            Circle()
                .fill(active ? tag.color : Theme.text3)
                .frame(width: 6, height: 6)
            Text("#\(tag.name)")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(active ? Theme.text2 : Theme.text3)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(active ? tag.color.opacity(0.10) : Theme.chip))
        .overlay(Capsule().stroke(active ? tag.color.opacity(0.24) : Theme.line))
    }
}

private extension TaskTagSlot {
    var shortTitle: String {
        switch self {
        case .tagI:
            return "I"
        case .tagII:
            return "II"
        case .tagIII:
            return "III"
        }
    }
}

private extension TaskTag {
    var color: Color {
        let raw = colorHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard raw.count == 6, let value = Int(raw, radix: 16) else {
            return Theme.navPool
        }
        return Theme.hex(value)
    }
}

struct PoolTaskPlaceholderGlyph: View {
    var body: some View {
        Circle()
            .stroke(Theme.line2, style: StrokeStyle(lineWidth: 1.5, dash: [2.4, 2]))
            .frame(width: 18, height: 18)
    }
}

struct FuturePlansPage: View {
    @EnvironmentObject private var store: SuntraceStore
    var plans: [FuturePlanItem] { store.engine.futurePlans(today: store.today) }
    var grouped: [(LocalDate, [FuturePlanItem])] {
        Dictionary(grouping: plans) { $0.trace.date }
            .map { ($0.key, $0.value.sorted { $0.trace.priority < $1.trace.priority }) }
            .sorted { $0.0 < $1.0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: store.copy.navFuture, subtitle: store.copy.futureSubtitle)
            TaskSelectionClearingScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(grouped, id: \.0) { date, items in
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 10) {
                                Text("\(SuntraceStore.displayDate(date)) · \(SuntraceStore.weekday(date))")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.text1)
                                    .monospacedDigit()
                                Button(store.copy.openDay) {
                                    store.selectedDate = date
                                    store.page = .day
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.accent)
                            }
                            .padding(.bottom, 4)
                            ForEach(items, id: \.trace.id) { item in
                                FuturePlanRow(item: item)
                            }
                        }
                    }
                    if plans.isEmpty {
                        EmptyState(kind: .futurePlans, text: store.copy.emptyFuture)
                            .padding(.top, 40)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
        }
    }
}

struct FuturePlanRow: View {
    @EnvironmentObject private var store: SuntraceStore
    let item: FuturePlanItem

    var body: some View {
        let selected = store.selectedTraceID == item.trace.id
        HStack(spacing: 10) {
            PlanningGlyph(systemName: "calendar.badge.clock", color: Theme.navFuture)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.definition.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                    .lineLimit(1)
                TaskTagStrip(tags: store.tags(for: item.trace.chainID))
            }
            Spacer()
            StatusChip(status: item.trace.status, scale: .compact)
            PriorityStepper(
                canMoveUp: canMoveUp,
                canMoveDown: canMoveDown,
                moveUp: { store.movePriority(item.trace.id, delta: -1) },
                moveDown: { store.movePriority(item.trace.id, delta: 1) }
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .listRowSurface(selected: selected, tint: Theme.navFuture, separatorLeadingInset: 40)
        .onTapGesture { store.selectTrace(item.trace.id) }
        .contextMenu {
            Button("查看详情") { store.selectTrace(item.trace.id) }
            Button("改期…") { store.showingPicker = .reschedule(item.trace.id) }
            Button("回到任务池") { store.returnToPool(item.trace.id) }
        }
    }

    var canMoveUp: Bool {
        item.trace.priority > (futurePriorities.min() ?? 1)
    }

    var canMoveDown: Bool {
        guard let maxPriority = futurePriorities.max() else { return false }
        return item.trace.priority < maxPriority
    }

    var futurePriorities: [Int] {
        store.engine.getDayTodo(date: item.trace.date).traces
            .filter { $0.status == .pending && $0.date > store.today }
            .map(\.priority)
    }
}

struct PlanningGlyph: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 20, height: 20)
            .background(Circle().fill(color.opacity(0.12)))
    }
}

struct PlanMetaPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

struct UnfinishedPoolPage: View {
    @EnvironmentObject private var store: SuntraceStore
    var items: [UnfinishedPoolItem] { store.engine.unfinishedPool() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: store.copy.navUnfinished, subtitle: store.copy.unfinishedSubtitle)
            TaskSelectionClearingScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items, id: \.chain.id) { item in
                        UnfinishedRow(item: item)
                    }
                    if items.isEmpty {
                        EmptyState(kind: .unfinishedPool, text: store.copy.emptyUnfinished)
                            .padding(.top, 40)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
        }
    }
}

private extension UnfinishedPoolItem {
    var latestUnfinishedTrace: DayTrace? {
        unfinishedTraces.last
    }

    var isAbandoned: Bool {
        chain.state == .abandoned || latestUnfinishedTrace?.status == .abandoned
    }

    var continuationCount: Int {
        let activeTraces = activeTrace.map { [$0] } ?? []
        let chainTraces = unfinishedTraces + activeTraces
        let latestSequence = chainTraces.map(\.continuationSeq).max() ?? 1
        return max(0, latestSequence - 1)
    }
}

struct UnfinishedRow: View {
    @EnvironmentObject private var store: SuntraceStore
    let item: UnfinishedPoolItem

    var expanded: Bool { store.expandedUnfinishedChainIDs.contains(item.chain.id) }
    private var activeDateLabel: String {
        guard let active = item.activeTrace else { return "" }
        return active.date == store.today ? "今天" : SuntraceStore.displayDate(active.date)
    }

    var body: some View {
        let selected = store.selectedUnfinishedChainID == item.chain.id
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                StatusGlyph(status: item.isAbandoned ? .abandoned : .unfinished)
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.definition.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(item.isAbandoned ? Theme.text2 : Theme.text1)
                        .lineLimit(1)
                    TaskTagStrip(tags: store.tags(for: item.chain))
                }
                Spacer()
                if item.activeTrace == nil, let source = item.unfinishedTraces.last {
                    HStack(spacing: 8) {
                        if item.isAbandoned {
                            SmallActionButton("重新启用", tone: .accent) { store.reactivateAbandonedChain(from: source.id) }
                        } else {
                            SmallActionButton(store.copy.continueTo, tone: .accent) { store.showingPicker = .continueTrace(source.id) }
                            SmallActionButton(store.copy.abandonChain, tone: .warn) { store.abandon(source.id) }
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Text(item.isAbandoned ? "已废弃" : store.copy.unfinishedMissedCount(item.unfinishedTraces.count))
                    .font(.system(size: 11))
                    .foregroundStyle(item.isAbandoned ? Theme.text2 : Theme.warn)
                    .monospacedDigit()
                UnfinishedMetaSeparator()
                Text(store.copy.unfinishedContinuationCount(item.continuationCount))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
                    .monospacedDigit()
                if let latestUnfinished = item.latestUnfinishedTrace {
                    UnfinishedMetaSeparator()
                    Text(store.copy.lastMissedDate(SuntraceStore.displayDate(latestUnfinished.date)))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text3)
                        .monospacedDigit()
                }
                if let active = item.activeTrace {
                    Button("已延续到 \(activeDateLabel)，当前待完成 跳转 →") {
                        store.selectedDate = active.date
                        store.page = .day
                        store.selectTrace(active.id)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Theme.accentSoft))
                }
                Spacer()
                Button(expanded ? "▾ 明细" : "▸ 明细") {
                    if expanded {
                        store.expandedUnfinishedChainIDs.remove(item.chain.id)
                    } else {
                        store.expandedUnfinishedChainIDs.insert(item.chain.id)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Theme.text2)
            }
            .padding(.leading, 28)
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(item.unfinishedTraces, id: \.id) { trace in
                        UnfinishedInlineTrace(trace: trace)
                    }
                }
                .padding(.leading, 30)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .listRowSurface(selected: selected, tint: Theme.accent, separatorLeadingInset: 40)
        .onTapGesture { store.selectUnfinished(item.chain.id) }
    }
}

struct UnfinishedMetaSeparator: View {
    var body: some View {
        Text("·")
            .font(.system(size: 11))
            .foregroundStyle(Theme.text3)
    }
}

struct UnfinishedInlineTrace: View {
    let trace: DayTrace

    var body: some View {
        HStack(spacing: 8) {
            StatusGlyph(status: trace.status)
            Text(SuntraceStore.displayDate(trace.date))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.text2)
                .frame(width: 74, alignment: .leading)
            Text(statusLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(statusColor)
            Text("第 \(trace.continuationSeq) 次延续")
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
            Spacer()
        }
    }

    var statusLabel: String {
        switch trace.status {
        case .continued:
            return "已延续"
        case .abandoned:
            return "已废弃"
        default:
            return "未完成"
        }
    }

    var statusColor: Color {
        switch trace.status {
        case .continued, .abandoned:
            return Theme.text2
        default:
            return Theme.warn
        }
    }
}

struct CompletedPoolPage: View {
    @EnvironmentObject private var store: SuntraceStore
    var items: [CompletedPoolItem] { store.engine.completedPool() }
    var subtaskRecords: [CompletedSubtaskRecord] { store.engine.completedSubtaskRecords() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: store.copy.navCompleted, subtitle: store.copy.completedSubtitle)
            TaskSelectionClearingScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(groupedDates, id: \.self) { date in
                        let dayItems = items.filter { $0.trace.date == date }
                        let daySubtasks = subtaskRecords.filter { $0.date == date }
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 8) {
                                Text(groupTitle(for: date))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.text1)
                                    .monospacedDigit()
                            }
                            .padding(.top, 2)
                            .padding(.bottom, 4)

                            ForEach(dayItems, id: \.trace.id) { item in
                                CompletedRow(item: item)
                            }
                            ForEach(daySubtasks, id: \.subtask.id) { record in
                                CompletedSubtaskRow(record: record)
                            }
                        }
                    }
                    if items.isEmpty && subtaskRecords.isEmpty {
                        EmptyState(kind: .completedPool, text: store.copy.emptyCompleted)
                            .padding(.top, 40)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
        }
    }

    var groupedDates: [LocalDate] {
        Array(Set(items.map { $0.trace.date } + subtaskRecords.map(\.date))).sorted(by: >)
    }

    func groupTitle(for date: LocalDate) -> String {
        let suffix = date == store.today ? " · 今天" : ""
        return "\(SuntraceStore.displayDate(date)) \(SuntraceStore.weekday(date))\(suffix)"
    }
}

struct CompletedRow: View {
    @EnvironmentObject private var store: SuntraceStore
    let item: CompletedPoolItem

    var body: some View {
        let isSelected = store.selectedCompletedTraceID == item.trace.id
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                StatusGlyph(status: .completed)
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.definition.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    TaskTagStrip(tags: store.tags(for: item.trace.chainID))
                }
                Spacer()
                CompletionTimeText(time: SuntraceStore.displayTime(item.trace.completedAt))
            }
            HStack(alignment: .center, spacing: 8) {
                CompletedTrajectoryNodes(nodes: item.trajectory.traces.map(CompletedTrajectoryNode.init(trace:)))
                    .padding(.leading, 28)
                Spacer()
                SmallActionButton(store.copy.openDay) {
                    store.selectedDate = item.trace.date
                    store.page = .day
                    store.selectTrace(item.trace.id)
                }
                SmallActionButton(store.copy.copyAsNewTask) { store.copyAsNewTask(item.trace.id) }
            }
        }
        .frame(minHeight: 52, alignment: .center)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .listRowSurface(selected: isSelected, tint: Theme.accent, separatorLeadingInset: 40)
        .onTapGesture { store.selectCompleted(item.trace.id) }
    }
}

struct CompletedSubtaskRow: View {
    @EnvironmentObject private var store: SuntraceStore
    let record: CompletedSubtaskRecord

    var body: some View {
        let isSelected = store.selectedCompletedSubtaskID == record.subtask.id
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                StatusGlyph(status: .completed)
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.subtask.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text("属于「\(record.parentDefinition.title)」")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                    TaskTagStrip(tags: store.tags(for: record.parentTrace.chainID))
                }
                Spacer()
                CompletionKindPill(text: "子任务", color: Theme.accent)
            }
            HStack(alignment: .center, spacing: 8) {
                CompletedTrajectoryNodes(nodes: [CompletedTrajectoryNode(subtask: record.subtask, date: record.date)])
                    .padding(.leading, 28)
                Spacer()
                SmallActionButton(store.copy.openDay) {
                    store.selectedDate = record.date
                    store.page = .day
                    store.selectTrace(record.parentTrace.id)
                }
                SmallActionButton(store.copy.copyAsNewTask) { store.copyAsNewTask(record.parentTrace.id) }
            }
        }
        .frame(minHeight: 66, alignment: .center)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .listRowSurface(selected: isSelected, tint: Theme.accent, separatorLeadingInset: 40)
        .onTapGesture { store.selectCompletedSubtask(record.subtask.id) }
    }
}

struct CompletionKindPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

struct CompletionTimeText: View {
    let time: String?

    var body: some View {
        if let time {
            Text(time)
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
                .monospacedDigit()
        }
    }
}

struct CompletedTrajectoryNode: Identifiable {
    let id: String
    let date: LocalDate
    let glyph: String
    let foreground: Color
    let background: Color

    init(trace: DayTrace) {
        id = trace.id.rawValue.uuidString
        date = trace.date
        glyph = trace.status.uiStyle.glyph.isEmpty ? "•" : trace.status.uiStyle.glyph
        foreground = trace.status == .completed ? .white : trace.status.uiStyle.glyphForeground
        background = trace.status == .completed ? Theme.ok : trace.status.uiStyle.glyphBackground
    }

    init(subtask: Subtask, date: LocalDate) {
        id = subtask.id.rawValue.uuidString
        self.date = date
        glyph = "✓"
        foreground = .white
        background = Theme.ok
    }
}

struct CompletedTrajectoryNodes: View {
    let nodes: [CompletedTrajectoryNode]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                if index > 0 {
                    Rectangle()
                        .fill(Theme.line2)
                        .frame(width: 14, height: 1.5)
                }
                HStack(spacing: 4) {
                    Text(node.glyph)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(node.foreground)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(node.background))
                    Text(SuntraceStore.displayDate(node.date))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.text3)
                        .monospacedDigit()
                }
                .padding(.trailing, 2)
            }
        }
    }
}

struct CalendarPage: View {
    @EnvironmentObject private var store: SuntraceStore

    var calendarCells: [CalendarCellModel] {
        let year = store.selectedCalendarDate.year
        let month = store.selectedCalendarDate.month
        let lead = SuntraceStore.mondayLeadBlankCount(year: year, month: month)
        let dayCount = SuntraceStore.daysInMonth(year: year, month: month)
        var cells = (0..<lead).map { CalendarCellModel.blank(id: "blank-\($0)") }
        cells += (1...dayCount).map { day in
            .date(LocalDate(year: year, month: month, day: day))
        }
        return cells
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text(verbatim: "\(store.selectedCalendarDate.year)年 \(store.selectedCalendarDate.month) 月")
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(Theme.text1)
                        .monospacedDigit()
                    Spacer()
                    HeaderButton("‹") {
                        store.selectedCalendarDate = SuntraceStore.shiftedMonth(from: store.selectedCalendarDate, by: -1)
                    }
                    HeaderButton(store.copy.today) { store.selectedCalendarDate = store.today }
                    HeaderButton("›") {
                        store.selectedCalendarDate = SuntraceStore.shiftedMonth(from: store.selectedCalendarDate, by: 1)
                    }
                }

                Text(store.copy.calendarSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
                    .padding(.top, 4)

                HStack {
                    ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) {
                        Text($0)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.text3)
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 6)
                    }
                }
                .padding(.top, 14)

                GeometryReader { proxy in
                    let rows = max(5, Int(ceil(Double(calendarCells.count) / 7.0)))
                    let rowHeight = max(88, (proxy.size.height - CGFloat(rows - 1) * 6) / CGFloat(rows))
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7),
                        spacing: 6
                    ) {
                        ForEach(calendarCells) { cell in
                            switch cell.kind {
                            case .blank:
                                Color.clear
                                    .frame(height: rowHeight)
                            case let .date(date):
                                CalendarCell(date: date, height: rowHeight)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .padding(.top, 14)
            }
            .padding(.top, 16)
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
            CalendarDetailPanel()
                .frame(width: 264)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Theme.line.opacity(0.58)).frame(width: 1)
                }
        }
    }
}

struct CalendarCellModel: Identifiable {
    enum Kind {
        case blank
        case date(LocalDate)
    }

    let id: String
    let kind: Kind

    static func blank(id: String) -> CalendarCellModel {
        CalendarCellModel(id: id, kind: .blank)
    }

    static func date(_ date: LocalDate) -> CalendarCellModel {
        CalendarCellModel(id: date.description, kind: .date(date))
    }
}

struct CalendarCell: View {
    @EnvironmentObject private var store: SuntraceStore
    let date: LocalDate
    let height: CGFloat

    var summary: CalendarDaySummary { store.engine.calendarSummary(for: date) }
    var traces: [DayTrace] {
        store.engine.getDayTodo(date: date).traces.sorted { $0.priority < $1.priority }
    }

    var selected: Bool { store.selectedCalendarDate == date }

    var isToday: Bool { date == store.today }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(verbatim: "\(date.day)")
                    .font(.system(size: 12.5, weight: isToday || selected ? .bold : .medium))
                    .foregroundStyle(selected ? Theme.accent : traces.isEmpty ? Theme.text3 : Theme.text1)
                    .monospacedDigit()
                    .lineLimit(1)
                if isToday {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 4, height: 4)
                }
                Spacer()
                if summary.total > 0 {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(heatColor)
                        .frame(width: 10, height: 10)
                }
            }

            VStack(alignment: .leading, spacing: 1.5) {
                ForEach(traces.prefix(6), id: \.id) { trace in
                    HStack(spacing: 3) {
                        Circle()
                            .fill(dotColor(for: trace.status))
                            .frame(width: 4, height: 4)
                            .fixedSize()
                        Text(store.definition(for: trace)?.title ?? "")
                            .font(.system(size: 9.5))
                            .foregroundStyle(titleColor(for: trace.status))
                            .strikethrough(trace.status == .completed || trace.status == .abandoned)
                            .lineLimit(1)
                    }
                    .frame(height: 12, alignment: .leading)
                }
                if traces.count > 6 {
                    Text("+\(traces.count - 6)")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.text3)
                        .padding(.leading, 7)
                }
            }
            .padding(.top, 3)

            Spacer()
        }
        .padding(.top, 5)
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
        .frame(height: height, alignment: .top)
        .hoverSurface(
            active: selected,
            cornerRadius: 9,
            idleFill: Theme.panel,
            hoverFill: Theme.panel2,
            activeFill: Theme.accentSoft,
            idleStroke: isToday ? Theme.accent : Theme.line,
            hoverStroke: isToday ? Theme.accent : Theme.line2,
            activeStroke: Theme.accent
        )
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onTapGesture { store.selectedCalendarDate = date }
    }

    var heatColor: Color {
        switch summary.heatLevel {
        case 0: Color(red: 0.90, green: 0.97, blue: 0.94)
        case 1: Color(red: 0.80, green: 0.93, blue: 0.86)
        case 2: Color(red: 0.62, green: 0.84, blue: 0.72)
        case 3: Color(red: 0.38, green: 0.72, blue: 0.58)
        default: Color(red: 0.16, green: 0.58, blue: 0.43)
        }
    }

    func dotColor(for status: TraceStatus) -> Color {
        status.uiStyle.dotColor
    }

    func titleColor(for status: TraceStatus) -> Color {
        status.uiStyle.titleColor
    }
}

struct CalendarDayInsight {
    let stats: DailyReviewStats
    let completionRate: Int
    let continuationSummary: String
    let changeSummary: String
    let riskSummary: String

    var hasEnhancedContent: Bool {
        stats.total >= 0
            && completionRate >= 0
            && continuationSummary.isEmpty == false
            && changeSummary.isEmpty == false
            && riskSummary.isEmpty == false
    }

    @MainActor
    static func make(for date: LocalDate, store: SuntraceStore) -> CalendarDayInsight {
        let traces = store.engine.getDayTodo(date: date).traces
        let stats = store.engine.dailyReviewStats(date: date)
        let completionRate = stats.total == 0 ? 0 : Int((Double(stats.completed) / Double(stats.total) * 100).rounded())
        let continuedBySeq = traces.filter { $0.continuationSeq > 0 }.count
        let continuationCount = max(stats.continued, continuedBySeq)
        let changedTargets = traces.filter { $0.changedToTraceID != nil }.count
        let pending = max(
            0,
            stats.total
                - stats.completed
                - stats.unfinished
                - stats.continued
                - stats.changed
                - stats.returnedToPool
                - stats.abandoned
        )

        let continuationSummary = if continuationCount == 0 {
            "当天没有延续链条。"
        } else {
            "\(continuationCount) 项涉及延续，需要关注持续天数和目标是否仍有效。"
        }

        let changeSummary = if stats.changed + changedTargets == 0 {
            "当天没有任务变更记录。"
        } else {
            "\(stats.changed + changedTargets) 项发生变更，原任务和目标任务都保留轨迹。"
        }

        let riskSummary = if date < store.today, stats.unfinished + stats.abandoned > 0 {
            "历史日有 \(stats.unfinished + stats.abandoned) 项未闭环或废弃，适合补写原因。"
        } else if date >= store.today, pending >= 4 {
            "待完成任务偏多，建议先排序或拆到其他日期。"
        } else if date > store.today, stats.total == 0 {
            "未来日暂无计划，可保持空白或从任务池排期。"
        } else if stats.total == 0 {
            "当天没有任务记录。"
        } else {
            "当天风险可控，重点看未完成和延续项。"
        }

        return CalendarDayInsight(
            stats: stats,
            completionRate: completionRate,
            continuationSummary: continuationSummary,
            changeSummary: changeSummary,
            riskSummary: riskSummary
        )
    }
}

struct CalendarDayInsightPanel: View {
    let insight: CalendarDayInsight

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("当天分析")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .tracking(0.6)
                Spacer()
                Text("\(insight.completionRate)% 完成")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(insight.completionRate == 100 && insight.stats.total > 0 ? Theme.ok : Theme.accent)
                    .monospacedDigit()
            }

            ReviewStatsCard(stats: insight.stats)

            VStack(alignment: .leading, spacing: 7) {
                CalendarInsightRow(label: "延续", text: insight.continuationSummary)
                CalendarInsightRow(label: "变更", text: insight.changeSummary)
                CalendarInsightRow(label: "风险", text: insight.riskSummary)
            }
        }
    }
}

struct CalendarInsightRow: View {
    let label: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .frame(width: 28, alignment: .leading)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text2)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct CalendarDetailPanel: View {
    @EnvironmentObject private var store: SuntraceStore
    var traces: [DayTrace] {
        store.engine.getDayTodo(date: store.selectedCalendarDate).traces.sorted { $0.priority < $1.priority }
    }

    var insight: CalendarDayInsight {
        CalendarDayInsight.make(for: store.selectedCalendarDate, store: store)
    }

    var dayKind: (text: String, background: Color, foreground: Color) {
        if store.selectedCalendarDate == store.today {
            return ("今天", Theme.accent, .white)
        }
        if store.selectedCalendarDate < store.today {
            return ("历史", Theme.chip, Theme.text2)
        }
        return ("未来", Theme.accentSoft, Theme.accent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "\(store.selectedCalendarDate.year)年\(SuntraceStore.displayDate(store.selectedCalendarDate))")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.text1)
                        .monospacedDigit()
                    Text(SuntraceStore.weekday(store.selectedCalendarDate))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text3)
                }

                HStack(spacing: 8) {
                    Text(dayKind.text)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(dayKind.foreground)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(dayKind.background))
                    Text("\(traces.count) 项任务")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text3)
                        .monospacedDigit()
                }
                .padding(.top, 7)

                Button("在 Day Todo 打开这一天 →") {
                    store.selectedDate = store.selectedCalendarDate
                    store.page = .day
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.accent)
                .padding(.top, 9)
            }
            .padding(.top, 16)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line.opacity(0.62)).frame(height: 1)
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    CalendarDayInsightPanel(insight: insight)
                        .padding(.bottom, 2)

                    ForEach(traces, id: \.id) { trace in
                        CalendarDetailRow(trace: trace)
                    }
                    if traces.isEmpty {
                        EmptyState(kind: .calendar, text: store.copy.emptyDay)
                            .padding(.vertical, 36)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .background(Theme.panel)
    }
}

struct CalendarDetailRow: View {
    @EnvironmentObject private var store: SuntraceStore
    let trace: DayTrace

    var body: some View {
        HStack(spacing: 9) {
            StatusGlyph(status: trace.status, scale: .compact)

            VStack(alignment: .leading, spacing: 1) {
                Text(store.definition(for: trace)?.title ?? "")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(titleColor)
                    .strikethrough(trace.status == .completed || trace.status == .abandoned)
                    .lineLimit(1)
                if metaText.isEmpty == false {
                    Text(metaText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                }
                if let changedTarget = store.changedTarget(for: trace) {
                    ChangedTargetButton(
                        title: changedTarget.definition.title,
                        compact: true
                    ) {
                        store.openChangedTarget(from: trace)
                    }
                }
            }

            Spacer()
            StatusChip(status: trace.status, scale: .compact)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .listRowSurface(selected: false, tint: Theme.accent, cornerRadius: 7, separatorLeadingInset: 36)
    }

    var titleColor: Color {
        trace.status.uiStyle.titleColor
    }

    var metaText: String {
        var parts: [String] = []
        if trace.continuationSeq > 0 {
            parts.append("第 \(trace.continuationSeq) 次延续 · 持续 \(store.continuationDurationDays(for: trace)) 天")
        }
        return parts.joined(separator: " · ")
    }
}

struct SettingsPage: View {
    @EnvironmentObject private var store: SuntraceStore
    @State private var selectedPane: SettingsPane = .general

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: store.copy.navSettings, subtitle: store.copy.settingsSubtitle)
            ScrollView {
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 16) {
                        SettingsPaneToolbar(selectedPane: $selectedPane)
                        SettingsPaneContent(pane: selectedPane)
                            .frame(maxWidth: 740, alignment: .topLeading)
                    }
                    .frame(maxWidth: 780, alignment: .topLeading)
                    if store.engine.preferences.settingsPoemDisplayPolicy.enabled {
                        SettingsPoemAside(text: store.engine.preferences.settingsPoemDisplayPolicy.text)
                            .frame(width: 310)
                            .padding(.top, 44)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
            }
        }
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case data
    case sync
    case zhulong
    case privacy

    var id: String { rawValue }

    func title(copy: AppCopy) -> String {
        switch self {
        case .general: copy.preferencesTitle
        case .data: copy.dataSectionTitle
        case .sync: copy.syncTitle
        case .zhulong: copy.providerTitle
        case .privacy: copy.privacyTitle
        }
    }

    var systemImage: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .data: "square.and.arrow.up.on.square"
        case .sync: "arrow.triangle.2.circlepath"
        case .zhulong: "sparkles"
        case .privacy: "lock.shield"
        }
    }
}

struct SettingsPaneToolbar: View {
    @EnvironmentObject private var store: SuntraceStore
    @Binding var selectedPane: SettingsPane

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(SettingsPane.allCases) { pane in
                    Button {
                        selectedPane = pane
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: pane.systemImage)
                                .font(.system(size: 12, weight: .semibold))
                            Text(pane.title(copy: store.copy))
                                .font(.system(size: 12, weight: selectedPane == pane ? .semibold : .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(selectedPane == pane ? Theme.accent : Theme.text2)
                        .padding(.horizontal, 11)
                        .frame(height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(selectedPane == pane ? Theme.accentSoft.opacity(0.72) : Theme.controlFill)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(selectedPane == pane ? Theme.accent.opacity(0.28) : Theme.line.opacity(0.72))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct SettingsPaneContent: View {
    let pane: SettingsPane

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch pane {
            case .general:
                SettingsPreferenceCard()
            case .data:
                SettingsDataCard()
            case .sync:
                SettingsSyncCard()
            case .zhulong:
                SettingsProviderOverviewCard()
            case .privacy:
                SettingsPrivacyCard()
            }
        }
    }
}

struct SettingsPreferenceCard: View {
    @EnvironmentObject private var store: SuntraceStore

    private var poemTextBinding: Binding<String> {
        Binding(
            get: { store.engine.preferences.settingsPoemDisplayPolicy.text },
            set: { store.setSettingsPoemText($0) }
        )
    }

    private var poemEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.engine.preferences.settingsPoemDisplayPolicy.enabled },
            set: { store.setSettingsPoemEnabled($0) }
        )
    }

    var body: some View {
        SettingsCard(
            systemImage: "slider.horizontal.3",
            title: store.copy.preferencesTitle,
            subtitle: store.copy.preferencesSubtitle
        ) {
            VStack(alignment: .leading, spacing: 16) {
                SettingSection(title: store.copy.appearanceTitle) {
                    SegmentedPair(
                        left: store.copy.coolGray,
                        right: store.copy.warmPaper,
                        leftSelected: store.engine.preferences.theme == .coolGray,
                        leftAction: { store.setTheme(.coolGray) },
                        rightAction: { store.setTheme(.warmPaper) }
                    )
                }
                SettingSection(title: store.copy.languageTitle) {
                    SegmentedPair(
                        left: "中文",
                        right: "English",
                        leftSelected: store.engine.preferences.language == .chinese,
                        leftAction: { store.setLanguage(.chinese) },
                        rightAction: { store.setLanguage(.english) }
                    )
                }
                SettingSection(title: store.copy.settingsPoemTitle) {
                    Toggle(store.copy.settingsPoemDisplay, isOn: poemEnabledBinding)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12.5, weight: .medium))
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(store.copy.settingsPoemEditorTitle)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.text3)
                            Spacer()
                            SmallActionButton(store.copy.resetSettingsPoem) {
                                store.resetSettingsPoemText()
                            }
                        }
                        TextEditor(text: poemTextBinding)
                            .font(.custom("Songti SC", size: 13))
                            .lineSpacing(5)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(minHeight: 150)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel2))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                    }
                }
            }
        }
    }
}

struct SettingsPoemAside: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("苦昼短")
                .font(.custom("Songti SC", size: 18).weight(.semibold))
                .foregroundStyle(Theme.text1.opacity(0.72))
            Text(text)
                .font(.custom("Songti SC", size: 15))
                .lineSpacing(9)
                .foregroundStyle(Theme.text2.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.panel.opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.line.opacity(0.55))
        )
    }
}

struct SettingsDataCard: View {
    @EnvironmentObject private var store: SuntraceStore

    var body: some View {
        SettingsCard(
            systemImage: "square.and.arrow.up.on.square",
            title: store.copy.dataSectionTitle,
            subtitle: store.copy.dataSectionSubtitle
        ) {
            HStack(spacing: 8) {
                SmallActionButton(store.copy.exportJSON, tone: .accent) { store.exportDataPackage() }
                SmallActionButton(store.copy.importData) { store.importDataPackage() }
            }
        }
    }
}

struct SettingsSyncCard: View {
    @EnvironmentObject private var store: SuntraceStore

    var body: some View {
        SettingsCard(systemImage: "arrow.triangle.2.circlepath", title: store.copy.syncTitle, subtitle: store.copy.syncSubtitle) {
            VStack(alignment: .leading, spacing: 16) {
                SettingSection(title: store.copy.dataModeTitle) {
                    SegmentedPair(
                        left: store.copy.localFirstMode,
                        right: store.copy.onlineFirstMode,
                        leftSelected: store.engine.preferences.dataMode == .localFirst,
                        leftAction: { store.setDataMode(.localFirst) },
                        rightAction: { store.setDataMode(.onlineFirst) }
                    )
                    Text(store.copy.dataModeBoundary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if store.engine.preferences.dataMode == .localFirst {
                    LocalFirstCloudSyncCard()
                } else {
                    ScheduledBackupCard()
                }
            }
        }
    }
}

struct LocalFirstCloudSyncCard: View {
    @EnvironmentObject private var store: SuntraceStore

    var policy: LocalFirstCloudSyncPolicy {
        store.engine.preferences.localFirstSyncPolicy
    }

    var body: some View {
        SettingSection(title: store.copy.localFirstSyncTitle) {
            VStack(alignment: .leading, spacing: 10) {
                SettingSection(title: store.copy.syncEndpointTitle) {
                    SegmentedOptionRow(
                        options: CloudSyncEndpointKind.allCases,
                        selected: policy.endpoint,
                        title: store.copy.cloudSyncEndpointTitle(for:),
                        action: store.setLocalFirstSyncEndpoint
                    )
                }
                SettingSection(title: store.copy.syncModeTitle) {
                    SegmentedPair(
                        left: store.copy.syncManualMode,
                        right: store.copy.syncAutomaticMode,
                        leftSelected: policy.mode == .manual,
                        leftAction: { store.setLocalFirstSyncMode(.manual) },
                        rightAction: { store.setLocalFirstSyncMode(.automatic) }
                    )
                }
                VStack(alignment: .leading, spacing: 6) {
                    SettingsInfoRow(
                        label: store.copy.syncSnapshotPolicyTitle,
                        value: "\(policy.snapshotRetention.indexRetentionDays) 天 / 每日 \(policy.snapshotRetention.retentionIndexesDaily) 个"
                    )
                    SettingsInfoRow(
                        label: store.copy.syncConflictCopyTitle,
                        value: policy.generateConflictCopy ? "开启" : "关闭",
                        last: true
                    )
                }
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                if policy.endpoint == .iCloud || policy.endpoint == .localFolder {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            SmallActionButton(
                                store.isLocalFirstSyncing ? store.copy.syncing : store.copy.syncNow,
                                tone: .accent
                            ) {
                                store.syncLocalFolderNow()
                            }
                            .disabled(store.isLocalFirstSyncing)
                            Text(policy.endpoint == .iCloud ? store.copy.iCloudSyncReady : store.copy.localFolderSyncReady)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.text3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let endpointURL = SuntraceStore.configuredLocalFirstSyncEndpointURL(for: policy.endpoint) {
                            if policy.endpoint == .iCloud {
                                SettingsInfoRow(
                                    label: store.copy.iCloudDriveLocationTitle,
                                    value: store.copy.iCloudDriveLogicalLocation
                                )
                                SettingsInfoRow(
                                    label: store.copy.localCachePathTitle,
                                    value: endpointURL.path,
                                    last: store.localFirstSyncMessage == nil
                                )
                            } else {
                                SettingsInfoRow(
                                    label: store.copy.syncFolderPathTitle,
                                    value: endpointURL.path,
                                    last: store.localFirstSyncMessage == nil
                                )
                            }
                        } else {
                            SettingsInfoRow(
                                label: policy.endpoint == .iCloud ? store.copy.iCloudDriveLocationTitle : store.copy.syncFolderPathTitle,
                                value: "iCloud Drive 不可用",
                                last: store.localFirstSyncMessage == nil
                            )
                        }
                        if let message = store.localFirstSyncMessage {
                            Text(message)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                } else {
                    Notice(text: store.copy.remoteEndpointPlanned, tone: .locked)
                }
                Text(store.copy.localFirstSyncBoundary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ScheduledBackupCard: View {
    @EnvironmentObject private var store: SuntraceStore

    var body: some View {
        SettingSection(title: store.copy.scheduledBackupTitle) {
            VStack(alignment: .leading, spacing: 10) {
                SegmentedOptionRow(
                    options: ScheduledBackupFrequency.allCases,
                    selected: store.engine.preferences.backupPolicy.frequency,
                    title: store.copy.backupFrequencyTitle(for:),
                    action: store.setBackupFrequency
                )
                SettingSection(title: store.copy.backupDestinationTitle) {
                    SegmentedPair(
                        left: store.copy.backupDestinationTitle(for: .iCloudDrive),
                        right: store.copy.backupDestinationTitle(for: .s3),
                        leftSelected: store.engine.preferences.backupPolicy.destination == .iCloudDrive,
                        leftAction: { store.setBackupDestination(.iCloudDrive) },
                        rightAction: { store.setBackupDestination(.s3) }
                    )
                }
                Text(store.copy.backupBoundary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SyncOptionsCard: View {
    @EnvironmentObject private var store: SuntraceStore

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.engine.syncEndpointOptions().enumerated()), id: \.element.kind) { index, option in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.copy.syncTitle(for: option.kind))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.text1)
                        Text(store.copy.syncDescription(for: option.kind))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.text3)
                    }
                    Spacer()
                    StatusPill(
                        text: store.copy.syncAvailabilityTitle(for: option.availability),
                        color: option.availability == .available ? Theme.ok : Theme.text3
                    )
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

                if index < store.engine.syncEndpointOptions().count - 1 {
                    Rectangle()
                        .fill(Theme.line)
                        .frame(height: 1)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
    }
}

struct SettingsProviderOverviewCard: View {
    @EnvironmentObject private var store: SuntraceStore

    var status: (text: String, color: Color) {
        if store.zhulongProviderDraft.isConfigured {
            return (store.copy.providerConfigured, Theme.ok)
        }
        if store.zhulongProviderDraft.enabled {
            return (store.copy.providerIncomplete, Theme.warn)
        }
        return (store.copy.providerDisabled, Theme.text3)
    }

    var body: some View {
        SettingsCard(
            systemImage: "sparkles",
            title: store.copy.providerTitle,
            subtitle: store.copy.providerSubtitle
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Toggle("启用烛龙", isOn: $store.zhulongProviderDraft.enabled)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12.5, weight: .medium))
                    StatusPill(text: status.text, color: status.color)
                    Spacer()
                }

                SettingSection(title: store.copy.providerType) {
                    ZhulongProviderKindPicker(selection: $store.zhulongProviderDraft.kind)
                }

                SettingsFormRows {
                    ZhulongProviderTextField(label: store.copy.providerName, text: $store.zhulongProviderDraft.displayName, placeholder: store.copy.customProvider)
                    ZhulongProviderTextField(label: "Base URL", text: $store.zhulongProviderDraft.baseURL, placeholder: "https://api.example.com/v1")
                    ZhulongProviderTextField(label: store.copy.providerModel, text: $store.zhulongProviderDraft.model, placeholder: "gpt-4.1-mini / llama3.1")
                    ZhulongProviderSecureField(
                        label: "API Key",
                        text: $store.zhulongProviderDraft.apiKeyInput,
                        placeholder: store.zhulongProviderDraft.hasStoredAPIKey ? "Keychain 中已有凭证，留空则保留" : "只保存到 Keychain"
                    )
                }

                HStack(spacing: 8) {
                    Image(systemName: store.zhulongProviderDraft.hasStoredAPIKey ? "key.fill" : "key")
                        .foregroundStyle(store.zhulongProviderDraft.hasStoredAPIKey ? Theme.ok : Theme.text3)
                    Text(store.zhulongProviderDraft.statusMessage)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel2))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))

                HStack(spacing: 8) {
                    SmallActionButton(store.copy.save, tone: .accent) { store.saveZhulongProvider() }
                    SmallActionButton(store.copy.testConnection) { store.testZhulongProvider() }
                    SmallActionButton(store.copy.clear, tone: .warn) { store.clearZhulongProvider() }
                    Spacer()
                }
            }
        }
    }
}

struct SettingsFormRows<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
    }
}

struct SettingsPrivacyCard: View {
    @EnvironmentObject private var store: SuntraceStore

    var body: some View {
        SettingsCard(systemImage: "lock.shield", title: store.copy.privacyTitle, subtitle: store.copy.privacySubtitle) {
            VStack(alignment: .leading, spacing: 8) {
                SettingsBoundaryRow(color: Theme.accent, text: store.copy.privacyRows[0])
                SettingsBoundaryRow(color: Theme.warn, text: store.copy.privacyRows[1])
                SettingsBoundaryRow(color: Theme.ok, text: store.copy.privacyRows[2])
                SettingsBoundaryRow(color: Theme.text3, text: store.copy.privacyRows[3])
            }
        }
    }
}

struct SettingsCard<Content: View>: View {
    let systemImage: String
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.navSettings)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.chip))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(2)
                }
                Spacer()
            }
            content
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
    }
}

struct SettingsMetricPill: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.text2)
            Spacer()
            Text(value)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
    }
}

struct SettingsInfoRow: View {
    let label: String
    let value: String
    var last = false

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .frame(width: 62, alignment: .leading)
            Text(value)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.text2)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .frame(height: 30)
        .overlay(alignment: .bottom) {
            if last == false {
                Rectangle().fill(Theme.line).frame(height: 1)
            }
        }
    }
}

struct SettingsBoundaryRow: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .padding(.top, 5)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2)
                .lineSpacing(3)
            Spacer(minLength: 0)
        }
    }
}

struct ZhulongPage: View {
    @EnvironmentObject private var store: SuntraceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: store.copy.navZhulong, subtitle: store.copy.zhulongSubtitle)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ZhulongWorkbenchCard()
                    ZhulongScopeCard()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("建议入口")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.text3)
                            .tracking(0.6)
                        ForEach(zhulongCapabilities, id: \.title) { capability in
                            ZhulongCapabilityRow(capability: capability)
                        }
                    }

                    ZhulongDraftsCard()
                }
                .padding(20)
            }
        }
    }

    var zhulongCapabilities: [ZhulongCapability] {
        [
            ZhulongCapability(task: .dailyReview, title: "复盘分析", scope: "当前 Day Todo + 每日复盘", evidence: "\(store.engine.dailyReviewStats(date: store.today).total) 项今日任务"),
            ZhulongCapability(task: .taskDecomposition, title: "任务拆解", scope: "用户选中的任务链", evidence: "生成子任务草稿，用户确认后添加"),
            ZhulongCapability(task: .scheduling, title: "排期建议", scope: "任务池 + 未来计划 + 未完成池", evidence: "\(store.engine.taskPool().count) 项未排期任务"),
            ZhulongCapability(task: .labelClassification, title: "Tag 建议", scope: "任务标题、状态和轨迹摘要", evidence: "只建议已有活跃 Tag，不自动写入")
        ]
    }
}

struct ZhulongWorkbenchCard: View {
    @EnvironmentObject private var store: SuntraceStore

    var status: (text: String, color: Color) {
        if store.zhulongProviderDraft.isConfigured {
            return ("可生成草稿", Theme.accent)
        }
        return ("待配置", Theme.warn)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("工作区")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                    Text("Provider 和《苦昼短》都留在设置；这里只处理草稿生成、筛选和确认。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.text2)
                }
                Spacer()
                StatusPill(text: status.text, color: status.color)
                SmallActionButton(store.copy.navSettings) {
                    store.page = .settings
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ZhulongScopeChip(
                    title: "Provider",
                    value: store.zhulongProviderDraft.isConfigured ? store.zhulongProviderDraft.normalizedDisplayName : "未配置"
                )
                ZhulongScopeChip(
                    title: "Model",
                    value: store.zhulongProviderDraft.isConfigured ? store.zhulongProviderDraft.normalizedModel : "未配置"
                )
                ZhulongScopeChip(title: "草稿", value: "\(store.zhulongDrafts.count) 条")
                ZhulongScopeChip(title: "已应用", value: "\(store.appliedZhulongOperationKeys.count) 条")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
    }
}

struct ZhulongProviderKindPicker: View {
    @Binding var selection: AIProviderKind

    var body: some View {
        HStack(spacing: 6) {
            ForEach([AIProviderKind.openAICompatible, .localModel, .customHTTP], id: \.self) { kind in
                Button {
                    selection = kind
                } label: {
                    Text(label(for: kind))
                        .font(.system(size: 11.5, weight: selection == kind ? .semibold : .medium))
                        .foregroundStyle(selection == kind ? Theme.accent : Theme.text2)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(selection == kind ? Theme.accentSoft : Theme.panel))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(selection == kind ? Theme.accent : Theme.line))
                }
                .buttonStyle(.plain)
            }
        }
    }

    func label(for kind: AIProviderKind) -> String {
        switch kind {
        case .openAICompatible:
            return "OpenAI-compatible"
        case .localModel:
            return "本地模型"
        case .customHTTP:
            return "自定义 HTTP"
        case .mock:
            return "Mock"
        }
    }
}

struct ZhulongProviderTextField: View {
    let label: String
    @Binding var text: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text3)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
        }
    }
}

struct ZhulongProviderSecureField: View {
    let label: String
    @Binding var text: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text3)
            SecureField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
        }
    }
}

struct ZhulongProviderField: View {
    let label: String
    let value: String
    var last = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.text3)
                .frame(width: 74, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2)
            Spacer()
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            if last == false {
                Rectangle().fill(Theme.line).frame(height: 1)
            }
        }
    }
}

struct ZhulongScopeCard: View {
    @EnvironmentObject private var store: SuntraceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("当前可见范围")
                .font(.system(size: 13, weight: .semibold))
            Text("这里只显示会进入草稿分析的当前范围。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2)
                .lineSpacing(3)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ZhulongScopeChip(title: "当前 Day Todo", value: "\(store.engine.getDayTodo(date: store.today).traces.count) 项")
                ZhulongScopeChip(title: "任务池", value: "\(store.engine.taskPool().count) 项")
                ZhulongScopeChip(title: "未完成池", value: "\(store.engine.unfinishedPool().count) 条链")
                ZhulongScopeChip(title: "已完成池", value: "\(store.engine.completedPool().count) 条记录")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
    }
}

struct ZhulongScopeChip: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.text2)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
    }
}

struct ZhulongCapability {
    let task: ZhulongTask
    let title: String
    let scope: String
    let evidence: String
}

struct ZhulongCapabilityRow: View {
    @EnvironmentObject private var store: SuntraceStore
    let capability: ZhulongCapability

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(capability.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                    Spacer(minLength: 12)
                    Text(capability.evidence)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text2)
                        .lineLimit(1)
                }
                Text(capability.scope)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
            }
            SmallActionButton("生成", tone: .accent) { store.generateZhulongDraft(task: capability.task) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
    }
}

struct ZhulongDraftsCard: View {
    @EnvironmentObject private var store: SuntraceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("草稿收件箱")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                StatusPill(text: "\(store.zhulongDrafts.count) 条", color: Theme.accent)
            }

            if store.zhulongDrafts.isEmpty {
                Text("还没有草稿。从上方入口生成后，右侧会显示证据和待确认操作。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(store.zhulongDrafts.enumerated()), id: \.element.id) { index, draft in
                        ZhulongDraftListRow(draft: draft)
                        if index < store.zhulongDrafts.count - 1 {
                            Rectangle()
                                .fill(Theme.line)
                                .frame(height: 1)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel2))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
    }
}

struct ZhulongDraftListRow: View {
    @EnvironmentObject private var store: SuntraceStore
    let draft: AISuggestionDraft

    var selected: Bool {
        if let selectedZhulongDraftID = store.selectedZhulongDraftID {
            return selectedZhulongDraftID == draft.id
        }
        return store.zhulongDrafts.first?.id == draft.id
    }

    var body: some View {
        Button {
            store.selectedZhulongDraftID = draft.id
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    StatusPill(text: zhulongKindLabel(draft.kind), color: Theme.accent)
                    if let confidence = draft.confidence {
                        Text("置信度 \(Int((confidence * 100).rounded()))%")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.text3)
                    }
                    Spacer()
                    Text(SuntraceStore.displayTime(draft.createdAt) ?? "")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.text3)
                }

                Text(draft.summary)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.text1)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    ZhulongMetaPill(title: "证据", value: "\(draft.localReport.facts.count)")
                    ZhulongMetaPill(title: "操作", value: "\(draft.proposedOperations.count)")
                    Spacer()
                    if selected {
                        Text("当前")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(4)
        .hoverSurface(
            active: selected,
            cornerRadius: 8,
            idleFill: .clear,
            hoverFill: Theme.panel,
            activeFill: Theme.accentSoft.opacity(0.55),
            idleStroke: .clear,
            hoverStroke: Theme.line,
            activeStroke: Theme.accent.opacity(0.18),
            activeLineWidth: 1
        )
    }
}

struct ZhulongMetaPill: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.text3)
            Text(value)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.text2)
                .monospacedDigit()
        }
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Capsule().fill(Theme.chip))
        .overlay(Capsule().stroke(Theme.line))
    }
}

func zhulongKindLabel(_ kind: AISuggestionKind) -> String {
    switch kind {
    case .dailyReview:
        return "复盘分析"
    case .habitInsight:
        return "习惯画像"
    case .taskDecomposition:
        return "任务拆解"
    case .scheduling:
        return "排期建议"
    case .labelClassification:
        return "Tag 建议"
    case .theoryAnalysis:
        return "理论参照"
    }
}

func zhulongOperationLabel(_ operation: AIProposedOperation) -> String {
    switch operation {
    case let .createPoolTask(title, _, _):
        return "创建任务池任务：\(title)"
    case let .addSubtask(_, title, difficulty):
        return "添加子任务：\(title)（\(difficulty.label)）"
    case let .scheduleFromPool(_, targetDate):
        return "从任务池排期到 \(targetDate)"
    case let .continueTrace(_, targetDate):
        return "延续到 \(targetDate)"
    case .abandonChain:
        return "废弃任务链"
    case let .assignLabel(_, label):
        return "写入 Tag I：\(label)"
    case let .updateDailyReview(date, _, _, _):
        return "更新 \(date) 的每日复盘"
    }
}

struct ZhulongOperationRow: View {
    @EnvironmentObject private var store: SuntraceStore
    let draft: AISuggestionDraft
    let operationIndex: Int
    let operation: AIProposedOperation

    var isApplied: Bool {
        store.appliedZhulongOperationKeys.contains(store.zhulongOperationKey(draftID: draft.id, operationIndex: operationIndex))
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isApplied ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isApplied ? Theme.ok : Theme.text3)
            Text(zhulongOperationLabel(operation))
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text2)
            Spacer()
            SmallActionButton(isApplied ? "已应用" : "确认应用", tone: isApplied ? .normal : .accent) {
                store.applyZhulongOperation(draftID: draft.id, operationIndex: operationIndex)
            }
            .disabled(isApplied)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
    }
}

struct ZhulongRail: View {
    @EnvironmentObject private var store: SuntraceStore

    var body: some View {
        if let draft = store.selectedZhulongDraft {
            ZhulongDraftInspector(draft: draft)
        } else {
            ZhulongEmptyRail()
        }
    }
}

struct ZhulongDraftInspector: View {
    let draft: AISuggestionDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("当前草稿")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .tracking(0.8)
                Spacer()
                Text(SuntraceStore.displayTime(draft.createdAt) ?? "")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    StatusPill(text: zhulongKindLabel(draft.kind), color: Theme.accent)
                    if let confidence = draft.confidence {
                        Text("置信度 \(Int((confidence * 100).rounded()))%")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.text3)
                    }
                }
                Text(draft.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text2)
                    .lineSpacing(4)
            }

            if draft.localReport.facts.isEmpty == false {
                DetailSection("证据") {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(draft.localReport.facts.prefix(5).enumerated()), id: \.offset) { _, fact in
                            HStack(alignment: .top, spacing: 7) {
                                Circle()
                                    .fill(Theme.accent)
                                    .frame(width: 4, height: 4)
                                    .padding(.top, 6)
                                Text(fact)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Theme.text2)
                                    .lineSpacing(3)
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel2))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                }
            }

            DetailSection("待确认操作") {
                VStack(alignment: .leading, spacing: 6) {
                    if draft.proposedOperations.isEmpty {
                        Text("这条草稿只提供分析，不包含写入操作。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.text3)
                    } else {
                        ForEach(Array(draft.proposedOperations.enumerated()), id: \.offset) { index, operation in
                            ZhulongOperationRow(draft: draft, operationIndex: index, operation: operation)
                        }
                    }
                }
            }

            DetailSection("写入护栏") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("不自动改写历史日。")
                    Text("不发送数据库文件、内部 ID 或 Keychain 值。")
                    Text("普通清单仍可以独立使用。")
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
            }
        }
    }
}

struct ZhulongEmptyRail: View {
    @EnvironmentObject private var store: SuntraceStore

    var status: (text: String, color: Color) {
        if store.zhulongProviderDraft.isConfigured {
            return ("可生成草稿", Theme.accent)
        }
        return ("待配置", Theme.warn)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("草稿检视")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .tracking(0.8)
                Spacer()
                StatusPill(text: status.text, color: status.color)
            }

            Text(store.zhulongProviderDraft.isConfigured
                ? "从左侧入口生成草稿，右侧会在这里显示证据和待确认操作。"
                : "Provider 还没配完整。先去设置补齐，再在这里生成草稿。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2)
                .lineSpacing(3)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ZhulongScopeChip(
                    title: "Provider",
                    value: store.zhulongProviderDraft.isConfigured ? store.zhulongProviderDraft.normalizedDisplayName : "未配置"
                )
                ZhulongScopeChip(
                    title: "Model",
                    value: store.zhulongProviderDraft.isConfigured ? store.zhulongProviderDraft.normalizedModel : "未配置"
                )
                ZhulongScopeChip(title: "草稿", value: "\(store.zhulongDrafts.count) 条")
                ZhulongScopeChip(title: "已应用", value: "\(store.appliedZhulongOperationKeys.count) 条")
            }

            if store.zhulongProviderDraft.isConfigured == false {
                SmallActionButton(store.copy.navSettings, tone: .accent) {
                    store.page = .settings
                }
            }

            DetailSection("写入护栏") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("不自动改写历史日。")
                    Text("不发送数据库文件、内部 ID 或 Keychain 值。")
                    Text("Provider 失败不影响普通清单。")
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
            }
        }
    }
}

struct ZhulongContextModel {
    struct Stat: Identifiable {
        let id = UUID()
        let title: String
        let value: String
    }

    let title: String
    let subtitle: String
    let stats: [Stat]
    let recentDraft: AISuggestionDraft?

    @MainActor
    static func make(for page: SuntraceStore.Page, store: SuntraceStore) -> ZhulongContextModel? {
        switch page {
        case .pool:
            let tasks = store.engine.taskPool()
            let contextCount = tasks.filter {
                ($0.definition.descriptionText ?? "").isEmpty == false || ($0.definition.note ?? "").isEmpty == false
            }.count
            let untaggedCount = tasks.filter { $0.chain.primaryTagID == nil }.count
            return ZhulongContextModel(
                title: "任务池排期",
                subtitle: "任务池不再单独给本地汇总解释；只把当前队列交给烛龙统一生成排期草稿。",
                stats: [
                    Stat(title: "未排期", value: "\(tasks.count) 项"),
                    Stat(title: "有说明", value: "\(contextCount) 项"),
                    Stat(title: "未标记", value: "\(untaggedCount) 项")
                ],
                recentDraft: store.zhulongDrafts.first { $0.kind == .scheduling }
            )
        case .future:
            let plans = store.engine.futurePlans(today: store.today)
            let coveredDates = Set(plans.map(\.trace.date)).count
            let continued = plans.filter { $0.trace.continuationSeq > 0 }.count
            return ZhulongContextModel(
                title: "未来改期",
                subtitle: "未来计划的密度、延续链和改期判断统一留在烛龙，不再占一个常驻说明栏。",
                stats: [
                    Stat(title: "计划任务", value: "\(plans.count) 项"),
                    Stat(title: "覆盖日期", value: "\(coveredDates) 天"),
                    Stat(title: "延续任务", value: "\(continued) 项")
                ],
                recentDraft: store.zhulongDrafts.first { $0.kind == .scheduling }
            )
        case .unfinished:
            let items = store.engine.unfinishedPool()
            let missed = items.reduce(0) { $0 + $1.unfinishedTraces.count }
            let active = items.filter { $0.activeTrace != nil }.count
            return ZhulongContextModel(
                title: "未完成处理",
                subtitle: "是否该延续、拆小还是废弃，统一交给烛龙草稿，不再在这里做静态推断。",
                stats: [
                    Stat(title: "任务链", value: "\(items.count) 条"),
                    Stat(title: "未完成次", value: "\(missed) 次"),
                    Stat(title: "已延续", value: "\(active) 条")
                ],
                recentDraft: store.zhulongDrafts.first { $0.kind == .scheduling }
            )
        case .completed:
            let completed = store.engine.completedPool()
            let subtaskRecords = store.engine.completedSubtaskRecords()
            let coveredDates = Set(completed.map(\.trace.date) + subtaskRecords.map(\.date)).count
            return ZhulongContextModel(
                title: "完成复看",
                subtitle: "完成记录只作为证据输入烛龙，不再在这里堆本地解释文案。",
                stats: [
                    Stat(title: "完成任务", value: "\(completed.count) 项"),
                    Stat(title: "子任务", value: "\(subtaskRecords.count) 条"),
                    Stat(title: "覆盖日期", value: "\(coveredDates) 天")
                ],
                recentDraft: store.zhulongDrafts.first { draft in
                    draft.kind == .habitInsight || draft.kind == .theoryAnalysis || draft.kind == .labelClassification
                }
            )
        case .day, .calendar, .zhulong, .settings:
            return nil
        }
    }
}

struct ZhulongContextRail: View {
    @EnvironmentObject private var store: SuntraceStore
    let model: ZhulongContextModel

    var statusText: String {
        store.zhulongProviderDraft.isConfigured ? "已启用" : "待配置"
    }

    var entryTitle: String {
        model.recentDraft == nil ? "进入烛龙" : "查看最近草稿"
    }

    var entrySubtitle: String {
        if store.zhulongProviderDraft.isConfigured == false {
            return "当前只打开入口。完成 Provider 配置后，再在烛龙页生成草稿。"
        }
        if let recentDraft = model.recentDraft {
            return "\(zhulongKindLabel(recentDraft.kind)) · \(recentDraft.summary)"
        }
        return "在烛龙页统一生成草稿、查看证据并逐条确认写入。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("烛龙")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .tracking(0.8)
                Spacer()
                StatusPill(text: statusText, color: store.zhulongProviderDraft.isConfigured ? Theme.accent : Theme.text3)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(model.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Text(model.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text2)
                    .lineSpacing(3)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(model.stats) { stat in
                    ZhulongScopeChip(title: stat.title, value: stat.value)
                }
            }

            Button(action: openZhulongDestination) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entryTitle)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Theme.text1)
                        Text(entrySubtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.text3)
                            .lineLimit(3)
                    }
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel2))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
            }
            .buttonStyle(.plain)
        }
    }

    private func openZhulongDestination() {
        if store.zhulongProviderDraft.isConfigured == false {
            store.page = .settings
            return
        }
        if let recentDraft = model.recentDraft {
            store.selectedZhulongDraftID = recentDraft.id
        }
        store.page = .zhulong
    }
}

struct SidebarAnalysisMetric: Identifiable {
    enum Tone {
        case accent
        case ok
        case warn
        case neutral

        var color: Color {
            switch self {
            case .accent:
                return Theme.accent
            case .ok:
                return Theme.ok
            case .warn:
                return Theme.warn
            case .neutral:
                return Theme.text2
            }
        }

        var background: Color {
            switch self {
            case .accent:
                return Theme.accentSoft
            case .ok:
                return Theme.okSoft
            case .warn:
                return Theme.warnSoft
            case .neutral:
                return Theme.chip
            }
        }
    }

    let id = UUID()
    let label: String
    let value: String
    let tone: Tone
}

struct SidebarAnalysisModel {
    let title: String
    let subtitle: String
    let metrics: [SidebarAnalysisMetric]
    let signals: [String]
    let recommendations: [String]
    let zhulongNote: String

    @MainActor
    static func make(for page: SuntraceStore.Page, store: SuntraceStore) -> SidebarAnalysisModel? {
        switch page {
        case .future:
            let plans = store.engine.futurePlans(today: store.today)
            let dates = Set(plans.map(\.trace.date))
            let continuationCount = plans.filter { $0.trace.continuationSeq > 0 }.count
            let maxDayLoad = Dictionary(grouping: plans, by: { $0.trace.date }).values.map(\.count).max() ?? 0
            return SidebarAnalysisModel(
                title: "未来计划分析",
                subtitle: "按日期观察未来任务负载与延续压力。",
                metrics: [
                    SidebarAnalysisMetric(label: "计划任务", value: "\(plans.count)", tone: .accent),
                    SidebarAnalysisMetric(label: "覆盖日期", value: "\(dates.count)", tone: .neutral),
                    SidebarAnalysisMetric(label: "延续任务", value: "\(continuationCount)", tone: continuationCount > 0 ? .warn : .ok)
                ],
                signals: [
                    plans.first.map { "最近计划：\(SuntraceStore.displayDate($0.trace.date)) · \($0.definition.title)" } ?? "未来计划为空。",
                    maxDayLoad >= 4 ? "存在单日计划较密集，可能需要提前拆分。" : "单日计划密度目前可控。"
                ],
                recommendations: [
                    plans.isEmpty ? "无需维护未来计划；保持今天列表清晰即可。" : "优先检查最近日期，避免未来任务堆到同一天。",
                    continuationCount > 0 ? "延续任务已进入未来计划，建议在目标日前确认范围是否仍有效。" : "暂无延续压力，可以按新任务优先级排序。"
                ],
                zhulongNote: "开启烛龙后，可结合历史完成节奏给出更精细的改期建议。"
            )
        case .unfinished:
            let items = store.engine.unfinishedPool()
            let missed = items.reduce(0) { $0 + $1.unfinishedTraces.count }
            let active = items.filter { $0.activeTrace != nil }.count
            let repeated = items.filter { $0.unfinishedTraces.count >= 2 }.count
            return SidebarAnalysisModel(
                title: "未完成风险",
                subtitle: "按任务链汇总历史未完成与当前延续状态。",
                metrics: [
                    SidebarAnalysisMetric(label: "任务链", value: "\(items.count)", tone: items.isEmpty ? .ok : .warn),
                    SidebarAnalysisMetric(label: "未完成次", value: "\(missed)", tone: missed == 0 ? .ok : .warn),
                    SidebarAnalysisMetric(label: "已延续", value: "\(active)", tone: .accent)
                ],
                signals: [
                    repeated > 0 ? "\(repeated) 条任务链重复未完成，存在范围或优先级问题。" : "没有重复未完成链。",
                    active > 0 ? "\(active) 条任务链已有当前待完成轨迹，避免重复延续。" : "暂无已延续到当前或未来的未完成链。"
                ],
                recommendations: [
                    items.isEmpty ? "未完成池为空，保持每日收尾即可。" : "优先处理最近未完成且尚未延续的任务链。",
                    repeated > 0 ? "重复未完成任务应先缩小目标，必要时废弃不再有效的链。" : "对单次未完成任务，直接延续或明确废弃。"
                ],
                zhulongNote: "开启烛龙后，可让模型结合复盘文本判断未完成原因。"
            )
        case .completed:
            let completed = store.engine.completedPool()
            let subtaskRecords = store.engine.completedSubtaskRecords()
            let dates = Set(completed.map(\.trace.date) + subtaskRecords.map(\.date))
            let continuedCompletions = completed.filter { $0.trace.continuationSeq > 0 }.count
            return SidebarAnalysisModel(
                title: "完成轨迹",
                subtitle: "汇总完成记录、子任务完成和跨日轨迹。",
                metrics: [
                    SidebarAnalysisMetric(label: "完成任务", value: "\(completed.count)", tone: .ok),
                    SidebarAnalysisMetric(label: "子任务", value: "\(subtaskRecords.count)", tone: .accent),
                    SidebarAnalysisMetric(label: "覆盖日期", value: "\(dates.count)", tone: .neutral)
                ],
                signals: [
                    completed.first.map { "最近完成：\(SuntraceStore.displayDate($0.trace.date)) · \($0.definition.title)" } ?? "暂无完成记录。",
                    continuedCompletions > 0 ? "\(continuedCompletions) 条完成记录经历过延续。" : "完成记录多为当日闭环。"
                ],
                recommendations: [
                    completed.isEmpty && subtaskRecords.isEmpty ? "暂无完成数据；先从 Day Todo 完成一项任务。" : "复盘最近完成记录，提取可复制的推进方式。",
                    subtaskRecords.isEmpty == false ? "子任务完成已单独记录，可用来判断复杂任务的真实推进。" : "复杂任务可拆子任务，让完成记录更细。"
                ],
                zhulongNote: "开启烛龙后，可从完成轨迹中总结节奏和可复用模式。"
            )
        case .pool, .day, .calendar, .zhulong, .settings:
            return nil
        }
    }
}

struct PoolSummaryModel {
    struct Group: Identifiable {
        let id: String
        let title: String
        let color: Color
        var count: Int
        let leadTitle: String
    }

    let orderedTasks: [PoolTask]
    let contextCount: Int
    let plannedCount: Int
    let needsDetailCount: Int
    let untaggedCount: Int
    let groups: [Group]

    var totalCount: Int { orderedTasks.count }
    var oldestCreatedAt: Date? { orderedTasks.first?.definition.createdAt }

    @MainActor
    static func make(store: SuntraceStore) -> PoolSummaryModel {
        let orderedTasks = store.engine.taskPool()
            .sorted { $0.definition.createdAt < $1.definition.createdAt }
        let contextCount = orderedTasks.filter {
            ($0.definition.descriptionText ?? "").isEmpty == false || ($0.definition.note ?? "").isEmpty == false
        }.count
        let plannedCount = orderedTasks.filter { $0.definition.plannedSubtasks.isEmpty == false }.count
        let needsDetailCount = orderedTasks.filter {
            ($0.definition.descriptionText ?? "").isEmpty &&
                ($0.definition.note ?? "").isEmpty &&
                $0.definition.plannedSubtasks.isEmpty
        }.count
        let untaggedCount = orderedTasks.filter { $0.chain.primaryTagID == nil }.count

        var groups: [Group] = []
        var groupIndexes: [String: Int] = [:]
        for task in orderedTasks {
            let primaryTag = store.tags(for: task.chain).first { $0.assignment.slot == .tagI }?.tag
            let id = primaryTag?.id.description ?? "untagged"
            if let index = groupIndexes[id] {
                groups[index].count += 1
            } else {
                groupIndexes[id] = groups.count
                groups.append(
                    Group(
                        id: id,
                        title: primaryTag?.name ?? "未标记",
                        color: primaryTag?.color ?? Theme.text3,
                        count: 1,
                        leadTitle: task.definition.title
                    )
                )
            }
        }

        return PoolSummaryModel(
            orderedTasks: orderedTasks,
            contextCount: contextCount,
            plannedCount: plannedCount,
            needsDetailCount: needsDetailCount,
            untaggedCount: untaggedCount,
            groups: groups
        )
    }
}

struct PoolSummaryRail: View {
    @EnvironmentObject private var store: SuntraceStore

    var model: PoolSummaryModel {
        PoolSummaryModel.make(store: store)
    }

    var focusTasks: [PoolTask] {
        Array(model.orderedTasks.prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PoolSummaryOverviewCard(model: model)

            if model.totalCount > 0 {
                DetailSection("分组") {
                    PoolSummaryGroupsPanel(groups: model.groups, totalCount: model.totalCount)
                }

                DetailSection("前 \(focusTasks.count) 条") {
                    PoolSummaryQueuePanel(tasks: focusTasks)
                }
            }
        }
    }
}

enum PoolSummaryFormatter {
    private static let createdAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    static func createdAtLabel(_ date: Date) -> String {
        createdAtFormatter.string(from: date)
    }
}

struct PoolSummaryOverviewCard: View {
    let model: PoolSummaryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("任务池")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .tracking(0.8)

            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text("\(model.totalCount)")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(Theme.navPool)
                    .monospacedDigit()
                Text("未排期")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text2)
            }

            Text(model.oldestCreatedAt.map { "最早入池 \(PoolSummaryFormatter.createdAtLabel($0))" } ?? "现在是空的。")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text2)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                PoolSummaryMetric(label: "有说明", value: model.contextCount, color: Theme.navPool)
                PoolSummaryMetric(label: "已拆分", value: model.plannedCount, color: Theme.accent)
                PoolSummaryMetric(label: "待补充", value: model.needsDetailCount, color: Theme.warn)
                PoolSummaryMetric(label: "未标记", value: model.untaggedCount, color: Theme.text3)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel2))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.navPool.opacity(0.16)))
    }
}

struct PoolSummaryMetric: View {
    let label: String
    let value: Int
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.text3)
            Text("\(value)")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(value == 0 ? Theme.text3 : color)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PoolSummaryGroupsPanel: View {
    let groups: [PoolSummaryModel.Group]
    let totalCount: Int

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                PoolSummaryGroupRow(group: group, totalCount: totalCount)
                if index < groups.count - 1 {
                    Rectangle()
                        .fill(Theme.line)
                        .frame(height: 1)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel2))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
    }
}

struct PoolSummaryGroupRow: View {
    let group: PoolSummaryModel.Group
    let totalCount: Int

    var ratio: CGFloat {
        guard totalCount > 0 else { return 0 }
        return CGFloat(group.count) / CGFloat(totalCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Circle()
                    .fill(group.color)
                    .frame(width: 7, height: 7)
                Text(group.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text1)
                    .lineLimit(1)
                Spacer()
                Text("\(group.count) 项")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text2)
                    .monospacedDigit()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.panel)
                    Capsule()
                        .fill(group.color.opacity(0.82))
                        .frame(width: max(8, proxy.size.width * ratio))
                }
            }
            .frame(height: 5)

            Text(group.leadTitle)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.text3)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }
}

struct PoolSummaryQueuePanel: View {
    let tasks: [PoolTask]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(tasks.enumerated()), id: \.element.chain.id) { index, task in
                PoolSummaryQueueRow(task: task)
                if index < tasks.count - 1 {
                    Rectangle()
                        .fill(Theme.line)
                        .frame(height: 1)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel2))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
    }
}

struct PoolSummaryQueueRow: View {
    @EnvironmentObject private var store: SuntraceStore
    let task: PoolTask

    var meta: String {
        let hasDescription = (task.definition.descriptionText ?? "").isEmpty == false
        let hasNote = (task.definition.note ?? "").isEmpty == false
        let plannedSubtaskCount = task.definition.plannedSubtasks.count
        var parts = ["\(PoolSummaryFormatter.createdAtLabel(task.definition.createdAt)) 入池"]
        if task.chain.primaryTagID == nil {
            parts.append("未标记")
        }
        if hasDescription == false && hasNote == false {
            parts.append("缺说明")
        }
        if plannedSubtaskCount > 0 {
            parts.append("\(plannedSubtaskCount) 子任务")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button { store.selectPool(task.chain.id) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(task.definition.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.text1)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                TaskTagStrip(tags: store.tags(for: task.chain))

                Text(meta)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(4)
        .hoverSurface(
            cornerRadius: 8,
            idleFill: .clear,
            hoverFill: Theme.panel,
            idleStroke: .clear,
            hoverStroke: Theme.line
        )
    }
}

struct SidebarAnalysisRail: View {
    let model: SidebarAnalysisModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .tracking(0.8)
                Text(model.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text2)
                    .lineSpacing(3)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(model.metrics) { metric in
                    SidebarMetricTile(metric: metric)
                }
            }

            SidebarTextBlock(title: "本地信号", rows: model.signals)
            SidebarTextBlock(title: "算法建议", rows: model.recommendations)
            ZhulongAnalysisHint(text: model.zhulongNote)
        }
    }
}

struct SidebarMetricTile: View {
    let metric: SidebarAnalysisMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(metric.label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.text3)
            Text(metric.value)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(metric.tone.color)
                .monospacedDigit()
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(metric.tone.background.opacity(0.72)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
    }
}

struct SidebarTextBlock: View {
    let title: String
    let rows: [String]

    var body: some View {
        DetailSection(title) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 7) {
                        Circle()
                            .fill(Theme.accent)
                            .frame(width: 4, height: 4)
                            .padding(.top, 6)
                        Text(row)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.text2)
                            .lineSpacing(3)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel2))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
        }
    }
}

struct ZhulongAnalysisHint: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 18, height: 18)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text3)
                .lineSpacing(3)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accentSoft.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent.opacity(0.16)))
    }
}

struct DetailRail: View {
    @EnvironmentObject private var store: SuntraceStore

    var zhulongContextModel: ZhulongContextModel? {
        guard store.usesZhulongContextRail else { return nil }
        return ZhulongContextModel.make(for: store.page, store: store)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let trace = store.selectedTrace, let definition = store.selectedDefinition {
                    if store.page == .completed, let record = store.selectedCompletedSubtaskRecord {
                        CompletedSubtaskDetail(record: record)
                    } else if store.page == .completed, let item = store.selectedCompletedItem {
                        CompletedRecordDetail(item: item)
                    } else if store.page == .future {
                        FuturePlanDetail(trace: trace, definition: definition)
                    } else {
                        TaskDetail(trace: trace, definition: definition)
                    }
                } else if let task = store.selectedPoolTask {
                    PoolDetail(task: task)
                } else if let item = store.selectedUnfinishedItem {
                    UnfinishedDetail(item: item)
                } else if store.page == .zhulong {
                    ZhulongRail()
                } else if store.page == .day {
                    ReviewRail()
                } else if let model = zhulongContextModel {
                    ZhulongContextRail(model: model)
                } else {
                    RailHint(text: hint)
                        .padding(.top, 40)
                }
            }
            .padding(16)
        }
        .background(Theme.panel)
    }

    var hint: String {
        switch store.page {
        case .pool: "选中任务查看详情与排期操作。"
        case .future: "选中计划查看详情，可改期或回池。"
        case .unfinished: "选中任务链查看未完成明细。"
        case .completed: "选中记录可跳转当天或复制为新任务。"
        case .zhulong: "选择建议草稿后在这里查看证据和待执行操作。"
        default: ""
        }
    }
}

struct RailHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.text3)
            .multilineTextAlignment(.center)
            .lineSpacing(4)
            .padding(.horizontal, 4)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
    }
}

struct DetailHeader<Trailing: View>: View {
    let title: String
    let onClose: () -> Void
    @ViewBuilder let trailing: Trailing

    init(
        _ title: String,
        onClose: @escaping () -> Void,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.onClose = onClose
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .tracking(0.8)
            Spacer()
            trailing
            IconButton(systemName: "xmark", action: onClose)
        }
    }
}

extension DetailHeader where Trailing == EmptyView {
    init(_ title: String, onClose: @escaping () -> Void) {
        self.init(title, onClose: onClose) {
            EmptyView()
        }
    }
}

struct IconButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text3)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.clear))
    }
}

struct IconMenuButton<Content: View>: View {
    @ViewBuilder let menuContent: Content

    var body: some View {
        Menu {
            menuContent
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .foregroundStyle(Theme.text3)
    }
}

struct DetailTitleRow<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text1)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
                .padding(.top, 1)
                .frame(minWidth: 24, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension DetailTitleRow where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title) {
            EmptyView()
        }
    }
}

struct DetailDescriptionBlock: View {
    @Binding var text: String
    let placeholder: String
    let editable: Bool

    var body: some View {
        EditableDetailText(
            text: $text,
            placeholder: placeholder,
            editable: editable,
            warm: false,
            fallback: "未填写描述"
        )
    }
}

struct CompletedRecordDetail: View {
    @EnvironmentObject private var store: SuntraceStore
    let item: CompletedPoolItem

    var editableText: Bool { item.trace.date >= store.today }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DetailHeader("任务详情", onClose: { store.clearSelection() }, trailing: {
                IconMenuButton(menuContent: {
                    Button(store.copy.openDay) { openDay() }
                    Button(store.copy.copyAsNewTask) { store.copyAsNewTask(item.trace.id) }
                })
            })
            DetailTitleRow(item.definition.title)

            DetailDescriptionBlock(
                text: Binding(
                    get: { item.trace.descriptionText ?? item.definition.descriptionText ?? "" },
                    set: { store.updateTraceText(traceID: item.trace.id, descriptionText: $0) }
                ),
                placeholder: "补充这个任务的背景、目标或范围…",
                editable: editableText
            )

            HStack(spacing: 8) {
                StatusChip(status: .completed)
                Text("\(SuntraceStore.displayDate(item.trace.date)) \(SuntraceStore.weekday(item.trace.date))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
            }

            DetailProgressSection(
                traceID: item.trace.id,
                progress: store.engine.traceProgress(for: item.trace.id),
                editable: false
            )

            TraceTimelineSection(trace: item.trace)

            DetailNotesSection(
                traceID: item.trace.id,
                noteText: item.trace.note ?? item.definition.note,
                editable: editableText,
                placeholder: "追加附言，回车确认"
            )
        }
    }

    private func openDay() {
        store.selectedDate = item.trace.date
        store.page = .day
        store.selectTrace(item.trace.id)
    }
}

struct TraceTimelineSection: View {
    @EnvironmentObject private var store: SuntraceStore
    let trace: DayTrace

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("任务轨迹")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .tracking(0.6)
                Spacer()
                Text(summaryText)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text2)
                    .monospacedDigit()
                    .lineLimit(1)
                TraceEndBadge(text: endLabel, color: endColor)
            }

            Timeline(trace: trace)
        }
    }

    var summaryText: String {
        if continuationCount > 0 {
            return "持续 \(durationDays) 天 · 延续 \(continuationCount) 次"
        }
        return "持续 \(durationDays) 天"
    }

    var durationDays: Int {
        let calendar = Calendar(identifier: .gregorian)
        guard let first = chainTraces.first else { return 1 }
        guard let last = chainTraces.last else { return 1 }
        let start = localGregorianDate(from: first.date)
        let end = localGregorianDate(from: last.date)
        return (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
    }

    var continuationCount: Int {
        chainTraces.map(\.continuationSeq).max() ?? 0
    }

    var endLabel: String {
        switch endStatus {
        case .completed:
            return "完成"
        case .abandoned:
            return "已废弃"
        case .returnedToPool:
            return "已回池"
        default:
            return "进行中"
        }
    }

    var endColor: Color {
        switch endStatus {
        case .completed:
            return Theme.ok
        case .abandoned, .returnedToPool:
            return Theme.text3
        default:
            return Theme.accent
        }
    }

    var endStatus: TraceStatus {
        chainTraces.last?.status ?? trace.status
    }

    var chainTraces: [DayTrace] {
        store.engine.traces.values
            .filter { $0.chainID == trace.chainID }
            .sorted { $0.date < $1.date }
    }
}

struct TraceEndBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Capsule().fill(Theme.chip))
    }
}

struct CompletedSubtaskDetail: View {
    @EnvironmentObject private var store: SuntraceStore
    let record: CompletedSubtaskRecord

    var completedAt: String { SuntraceStore.displayTime(record.subtask.completedAt) ?? "未记录" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DetailHeader("子任务完成记录", onClose: { store.clearSelection() }, trailing: {
                IconMenuButton(menuContent: {
                    Button(store.copy.openDay) { openDay() }
                    Button(store.copy.copyParentAsNewTask) { store.copyAsNewTask(record.parentTrace.id) }
                })
            })
            DetailTitleRow(record.subtask.title)

            HStack(spacing: 8) {
                CompletionKindPill(text: "子任务", color: Theme.accent)
                Text("\(SuntraceStore.displayDate(record.date)) \(SuntraceStore.weekday(record.date))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
            }

            CompletionSummaryCard(items: [
                CompletionSummaryItem(label: "父任务", value: record.parentDefinition.title, color: Theme.text2),
                CompletionSummaryItem(label: "难度", value: record.subtask.difficulty.label, color: record.subtask.difficulty == .hard ? Theme.warn : Theme.text2),
                CompletionSummaryItem(label: "完成", value: SuntraceStore.displayDate(record.date), color: Theme.ok),
                CompletionSummaryItem(label: "时间", value: completedAt, color: Theme.text2)
            ])

            Notice(text: "子任务完成事实独立展示，父任务轨迹仍保留在当天。", tone: .locked)

            DetailSection("父任务") {
                VStack(alignment: .leading, spacing: 7) {
                    Text(record.parentDefinition.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                        .lineLimit(2)
                    Text(record.parentDefinition.descriptionText ?? "未填写描述")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(3)
                    SmallActionButton(store.copy.openDay, tone: .accent) { openDay() }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel2))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
            }

            DetailSection("完成节点") {
                CompletedTrajectoryPanel(nodes: [CompletedTrajectoryNode(subtask: record.subtask, date: record.date)])
            }

            HStack(spacing: 8) {
                SmallActionButton(store.copy.openDay, tone: .accent) { openDay() }
                SmallActionButton(store.copy.copyParentTask) { store.copyAsNewTask(record.parentTrace.id) }
            }
        }
    }

    private func openDay() {
        store.selectedDate = record.date
        store.page = .day
        store.selectTrace(record.parentTrace.id)
    }
}

struct CompletionSummaryItem {
    let label: String
    let value: String
    let color: Color
}

struct CompletionSummaryCard: View {
    let items: [CompletionSummaryItem]

    var body: some View {
        VStack(spacing: 7) {
            ForEach(items, id: \.label) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.label)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                        .frame(width: 38, alignment: .leading)
                    Text(item.value)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(item.color)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.okSoft.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
    }
}

struct CompletedTrajectoryPanel: View {
    let nodes: [CompletedTrajectoryNode]

    var body: some View {
        CompletedTrajectoryNodes(nodes: nodes)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel2))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
    }
}

struct TaskDetail: View {
    @EnvironmentObject private var store: SuntraceStore
    let trace: DayTrace
    let definition: TaskDefinition

    var progress: TraceProgress { store.engine.traceProgress(for: trace.id) }
    var subtasks: [Subtask] { store.subtasks(for: trace.id) }
    var canEditText: Bool { trace.status == .pending && trace.date >= store.today }
    var canEditManualProgress: Bool { trace.status == .pending && trace.date == store.today && subtasks.isEmpty }
    var canAddSubtask: Bool { trace.status == .pending && trace.date >= store.today }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DetailHeader("任务详情", onClose: { store.clearSelection() }, trailing: {
                IconMenuButton(menuContent: {
                    TaskContextMenu(trace: trace)
                })
            })
            DetailTitleRow(definition.title)

            DetailDescriptionBlock(
                text: Binding(
                    get: { trace.descriptionText ?? definition.descriptionText ?? "" },
                    set: { store.updateTraceText(traceID: trace.id, descriptionText: $0) }
                ),
                placeholder: "补充这个任务的背景、目标或范围…",
                editable: canEditText
            )

            HStack {
                StatusChip(status: trace.status)
                Text("\(SuntraceStore.displayDate(trace.date)) \(SuntraceStore.weekday(trace.date))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
            }
            TraceContextCard(trace: trace)
            if trace.date < store.today {
                Notice(text: "历史只读：任务事实不可改写。", tone: .locked)
            }
            DetailProgressSection(
                traceID: trace.id,
                progress: progress,
                editable: canEditManualProgress
            )
            DetailSection("子任务") {
                VStack(spacing: 6) {
                    ForEach(subtasks, id: \.id) { subtask in
                        SubtaskRow(subtask: subtask)
                    }
                    if subtasks.isEmpty && !canAddSubtask {
                        Text("暂无子任务")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text3)
                    }
                    if canAddSubtask {
                        TextField("添加子任务，回车确认", text: $store.detailSubtaskText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                            .onSubmit { store.addDetailSubtask(traceID: trace.id) }
                    }
                }
            }
            DetailSection("任务轨迹") {
                Timeline(trace: trace)
            }
            DetailNotesSection(
                traceID: trace.id,
                noteText: trace.note ?? definition.note,
                editable: canEditText,
                placeholder: "追加附言，回车确认"
            )
        }
    }
}

struct DetailProgressSection: View {
    let traceID: DayTraceID
    let progress: TraceProgress
    let editable: Bool

    var body: some View {
        if editable {
            DetailSection("完成进度") {
                DetailProgressControl(
                    traceID: traceID,
                    progress: progress,
                    editable: editable,
                    showsPercent: true
                )
            }
        } else {
            VStack(alignment: .leading, spacing: 7) {
                DetailProgressHeader(progress: progress)
                DetailProgressControl(
                    traceID: traceID,
                    progress: progress,
                    editable: editable,
                    showsPercent: false
                )
            }
        }
    }
}

struct DetailProgressHeader: View {
    let progress: TraceProgress

    var body: some View {
        HStack(spacing: 8) {
            Text("完成进度")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .tracking(0.6)
            Spacer()
            DetailProgressPercent(progress: progress)
        }
    }
}

struct DetailProgressPercent: View {
    let progress: TraceProgress

    var body: some View {
        Text("\(progress.percent)%")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(progress.percent == 100 ? Theme.ok : Theme.accent)
            .monospacedDigit()
    }
}

struct DetailProgressControl: View {
    @EnvironmentObject private var store: SuntraceStore
    let traceID: DayTraceID
    let progress: TraceProgress
    let editable: Bool
    let showsPercent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if showsPercent {
                HStack {
                    Spacer()
                    DetailProgressPercent(progress: progress)
                }
            }
            if editable {
                ManualProgressSlider(
                    percent: progress.percent,
                    floorPercent: progress.floorPercent
                ) { percent in
                    store.setManualProgress(traceID: traceID, percent: Double(percent))
                }
                if progress.floorPercent > 0 {
                    Text("下限 \(progress.floorPercent)% · 延续后的进度不能回退")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.text3)
                }
            } else {
                StaticProgressBar(percent: progress.percent)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(progress.mode == .weightedSubtasks ? "按子任务自动计算的完成进度" : "手动完成进度")
        .accessibilityValue("\(progress.percent)%")
    }
}

struct ManualProgressSlider: View {
    let percent: Int
    let floorPercent: Int
    let onChange: (Int) -> Void

    var normalizedPercent: CGFloat {
        CGFloat(clampedPercent) / 100
    }

    var clampedPercent: Int {
        min(max(percent, floorPercent), 100)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.chip)
                    .frame(height: 6)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: width * normalizedPercent, height: 6)
                ForEach(Array(stride(from: 0, through: 100, by: 5)), id: \.self) { mark in
                    Rectangle()
                        .fill(mark <= clampedPercent ? Theme.accent.opacity(0.32) : Theme.line2)
                        .frame(width: 1, height: 9)
                        .offset(x: min(width - 1, width * CGFloat(mark) / 100))
                }
                Circle()
                    .fill(Theme.panel)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Theme.accent, lineWidth: 1.8))
                    .shadow(color: Theme.accent.opacity(0.16), radius: 3, y: 1)
                    .offset(x: max(0, min(width - 12, width * normalizedPercent - 6)))
            }
            .frame(height: 22)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onChange(snappedPercent(for: value.location.x, width: width))
                    }
            )
        }
        .frame(height: 22)
        .accessibilityElement()
        .accessibilityLabel("手动完成进度")
        .accessibilityValue("\(clampedPercent)%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                onChange(adjustedPercent(by: 5))
            case .decrement:
                onChange(adjustedPercent(by: -5))
            @unknown default:
                break
            }
        }
    }

    private func snappedPercent(for x: CGFloat, width: CGFloat) -> Int {
        let rawPercent = Int((min(max(x / width, 0), 1) * 100).rounded())
        let snapped = Int((Double(rawPercent) / 5).rounded()) * 5
        return min(max(snapped, floorPercent), 100)
    }

    private func adjustedPercent(by delta: Int) -> Int {
        min(max(clampedPercent + delta, floorPercent), 100)
    }
}

struct StaticProgressBar: View {
    let percent: Int

    var normalizedPercent: CGFloat {
        CGFloat(min(max(percent, 0), 100)) / 100
    }

    var fillColor: Color {
        percent >= 100 ? Theme.ok : Theme.accent
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.chip)
                Capsule()
                    .fill(fillColor)
                    .frame(width: proxy.size.width * normalizedPercent)
            }
        }
        .frame(height: 6)
    }
}

struct EditableDetailText: View {
    @Binding var text: String
    let placeholder: String
    let editable: Bool
    let warm: Bool
    let fallback: String

    var body: some View {
        if editable {
            TextEditor(text: normalizedBinding)
                .font(.system(size: 12))
                .italic(warm)
                .foregroundStyle(warm ? Theme.text2 : Theme.text1)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .frame(height: 66)
                .background(RoundedRectangle(cornerRadius: 7).fill(warm ? Theme.noteBackground : Theme.panel2))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                .overlay(alignment: .topLeading) {
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(placeholder)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text3)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .allowsHitTesting(false)
                    }
                }
        } else {
            Text(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : text)
                .font(.system(size: 12))
                .italic(warm)
                .foregroundStyle(warm ? Theme.text2 : Theme.text2)
                .lineSpacing(3)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(warm ? Theme.noteBackground : Theme.panel2))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
        }
    }

    private var normalizedBinding: Binding<String> {
        Binding(
            get: { text },
            set: { text = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : $0 }
        )
    }
}

struct DetailNoteEntry: Identifiable {
    let id: Int
    let timestamp: String
    let body: String
}

enum DetailNoteEntryStorage {
    private static let linePrefix = "["
    private static let lineSeparator = "] "

    static func entries(from noteText: String?) -> [DetailNoteEntry] {
        let lines = (noteText ?? "")
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }

        return lines.enumerated().map { index, line in
            guard line.hasPrefix(linePrefix),
                  let separatorRange = line.range(of: lineSeparator)
            else {
                return DetailNoteEntry(id: index, timestamp: "已有附言", body: line)
            }
            let timestamp = String(line[line.index(after: line.startIndex)..<separatorRange.lowerBound])
            let body = String(line[separatorRange.upperBound...])
            return DetailNoteEntry(id: index, timestamp: timestamp, body: body)
        }
    }

    static func appending(_ body: String, to noteText: String?) -> String {
        let timestamp = noteTimestampFormatter.string(from: Date())
        let line = "[\(timestamp)] \(body)"
        let existing = noteText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return existing.isEmpty ? line : "\(existing)\n\(line)"
    }

    private static let noteTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_SG")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

struct DetailNotesSection: View {
    @EnvironmentObject private var store: SuntraceStore
    let traceID: DayTraceID
    let noteText: String?
    let editable: Bool
    let placeholder: String

    var entries: [DetailNoteEntry] {
        DetailNoteEntryStorage.entries(from: noteText)
    }

    var body: some View {
        if entries.isEmpty == false || editable {
            DetailSection("附言") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(entries) { entry in
                        DetailNoteEntryRow(entry: entry)
                    }

                    if editable {
                        TextField(placeholder, text: $store.detailNoteText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text1)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.noteBackground))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                            .onSubmit { store.appendTraceNote(traceID: traceID) }
                    }
                }
            }
        }
    }
}

struct DetailNoteEntryRow: View {
    let entry: DetailNoteEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(entry.timestamp)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.text3)
                .monospacedDigit()
            Text(entry.body)
                .font(.system(size: 12))
                .italic()
                .foregroundStyle(Theme.text2)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.noteBackground))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
    }
}

struct TraceContextCard: View {
    @EnvironmentObject private var store: SuntraceStore
    let trace: DayTrace

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(continuationText)
            Text("·")
                .foregroundStyle(Theme.text3)
            Text("持续 \(durationDays) 天")
            if let changedTarget = store.changedTarget(for: trace) {
                Text("·")
                    .foregroundStyle(Theme.text3)
                ChangedTargetButton(title: changedTarget.definition.title) {
                    store.openChangedTarget(from: trace)
                }
            }
            if trace.status == .returnedToPool {
                Text("·")
                    .foregroundStyle(Theme.text3)
                Text("当天已回池")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.text2)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel2))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
    }

    var continuationText: String {
        trace.continuationSeq > 0 ? "第 \(trace.continuationSeq) 次延续" : "首次进入"
    }

    var durationDays: Int {
        let traces = store.engine.traces.values
            .filter { $0.chainID == trace.chainID && $0.date <= trace.date }
            .sorted { $0.date < $1.date }
        guard let first = traces.first else { return 1 }
        let calendar = Calendar(identifier: .gregorian)
        let start = localGregorianDate(from: first.date)
        let end = localGregorianDate(from: trace.date)
        return max(1, (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1)
    }
}

struct Timeline: View {
    @EnvironmentObject private var store: SuntraceStore
    let trace: DayTrace

    var body: some View {
        let chainTraces = store.engine.traces.values
            .filter { $0.chainID == trace.chainID }
            .sorted { $0.date < $1.date }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(chainTraces.enumerated()), id: \.element.id) { index, item in
                let isCurrent = item.id == trace.id
                let isLast = index == chainTraces.count - 1
                let nodeStyle = TimelineNodeStyle(status: item.status, isCurrent: isCurrent)
                HStack(alignment: .top, spacing: 8) {
                    VStack(spacing: 0) {
                        TimelineNodeGlyph(style: nodeStyle)
                        if !isLast {
                            Rectangle()
                                .fill(Theme.line2)
                                .frame(width: 1.5, height: 28)
                                .padding(.top, 1)
                        }
                    }
                    .frame(width: 14)
                    .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(nodeStyle.label)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(nodeStyle.labelColor)
                            if isCurrent {
                                TimelineCurrentBadge()
                            }
                            Spacer(minLength: 0)
                            Text("#\(item.continuationSeq + 1)")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.text3)
                                .monospacedDigit()
                        }
                        Text("\(SuntraceStore.displayDate(item.date)) \(SuntraceStore.weekday(item.date))")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.text3)
                        if let changedTarget = store.changedTarget(for: item) {
                            ChangedTargetButton(
                                title: changedTarget.definition.title,
                                compact: true
                            ) {
                                store.openChangedTarget(from: item)
                            }
                            .padding(.top, 2)
                        }
                    }
                    .padding(.top, 1)
                    .padding(.bottom, isLast ? 0 : 12)
                    .padding(.leading, 4)
                    .padding(.trailing, isCurrent ? 8 : 0)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isCurrent ? Theme.accentSoft : Color.clear)
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct TimelineNodeStyle {
    let label: String
    let glyph: String
    let labelColor: Color
    let glyphForeground: Color
    let glyphBackground: Color
    let glyphBorder: Color

    init(status: TraceStatus, isCurrent: Bool) {
        switch status {
        case .pending:
            label = status.uiStyle.label
            glyph = ""
            labelColor = Theme.accent
            glyphForeground = Theme.accent
            glyphBackground = Theme.panel
            glyphBorder = isCurrent ? Theme.accent : Theme.line2
        case .completed:
            label = status.uiStyle.label
            glyph = status.uiStyle.glyph
            labelColor = Theme.ok
            glyphForeground = .white
            glyphBackground = Theme.ok
            glyphBorder = .clear
        case .unfinished:
            label = status.uiStyle.label
            glyph = status.uiStyle.glyph
            labelColor = Theme.warn
            glyphForeground = Theme.warn
            glyphBackground = Theme.warnSoft
            glyphBorder = .clear
        case .continued:
            label = "未完成"
            glyph = TraceStatus.unfinished.uiStyle.glyph
            labelColor = Theme.warn
            glyphForeground = Theme.warn
            glyphBackground = Theme.warnSoft
            glyphBorder = .clear
        case .changed, .returnedToPool, .abandoned:
            label = status.uiStyle.label
            glyph = status.uiStyle.glyph
            labelColor = status.uiStyle.foreground
            glyphForeground = status.uiStyle.glyphForeground
            glyphBackground = status.uiStyle.glyphBackground
            glyphBorder = status.uiStyle.glyphBorder
        }
    }
}

struct TimelineNodeGlyph: View {
    let style: TimelineNodeStyle

    var body: some View {
        Text(style.glyph)
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(style.glyphForeground)
            .frame(width: 14, height: 14)
            .background(Circle().fill(style.glyphBackground))
            .overlay(Circle().stroke(style.glyphBorder, lineWidth: 1.5))
    }
}

struct TimelineCurrentBadge: View {
    var body: some View {
        Text("当前所在")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(Capsule().stroke(Theme.accent, lineWidth: 1))
    }
}

struct PoolDetail: View {
    @EnvironmentObject private var store: SuntraceStore
    let task: PoolTask

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DetailHeader("任务池", onClose: { store.clearSelection() })
            Text(task.definition.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text1)
            DetailDescriptionBlock(
                text: Binding(
                    get: { task.definition.descriptionText ?? "" },
                    set: { store.updatePoolTaskText(chainID: task.chain.id, descriptionText: $0) }
                ),
                placeholder: "补充这个任务的背景、目标或范围…",
                editable: true
            )
            HStack {
                StatusPill(text: "未排期", color: Theme.accent)
                Text("任务链仍在任务池")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
            }
            DetailSection("Tag") {
                TaskTagInlineEditor(chain: task.chain)
            }
            DetailSection("子任务") {
                PoolPlannedSubtasksSection(task: task)
            }
            DetailSection("状态") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("尚未进入任何 Day Todo。排期后会生成对应日期的日轨迹。")
                    Text(task.chain.state == .active ? "任务链状态：活跃" : "任务链状态：已关闭")
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
            }
            DetailSection("排期") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        SmallActionButton(store.copy.scheduleToday, tone: .accent) { store.schedulePoolTask(task.chain.id, date: store.today) }
                        SmallActionButton(store.copy.scheduleTomorrow) { store.schedulePoolTask(task.chain.id, date: SuntraceStore.offset(store.today, by: 1)) }
                    }
                    SmallActionButton(store.copy.schedulePickSpecificDate) { store.showingPicker = .schedulePool(task.chain.id) }
                }
            }
            PoolNotesSection(chainID: task.chain.id, noteText: task.definition.note)
        }
    }
}

struct PoolPlannedSubtasksSection: View {
    @EnvironmentObject private var store: SuntraceStore
    let task: PoolTask

    var plannedSubtasks: [PlannedSubtask] {
        task.definition.plannedSubtasks.sorted { $0.position < $1.position }
    }

    var body: some View {
        VStack(spacing: 6) {
            ForEach(plannedSubtasks) { plannedSubtask in
                PlannedSubtaskRow(chainID: task.chain.id, plannedSubtask: plannedSubtask)
            }
            TextField("添加子任务，回车确认", text: $store.detailSubtaskText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                .onSubmit { store.addPoolPlannedSubtask(chainID: task.chain.id) }
        }
    }
}

struct PlannedSubtaskRow: View {
    @EnvironmentObject private var store: SuntraceStore
    let chainID: TaskChainID
    let plannedSubtask: PlannedSubtask

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 5)
                .fill(Theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line2, lineWidth: 1.5))
                .frame(width: 15, height: 15)

            Text(plannedSubtask.title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text1)
                .lineLimit(1)

            Spacer()

            Menu {
                ForEach(SubtaskDifficulty.allCases, id: \.self) { difficulty in
                    Button {
                        store.setPoolPlannedSubtaskDifficulty(
                            chainID: chainID,
                            plannedSubtaskID: plannedSubtask.id,
                            difficulty: difficulty
                        )
                    } label: {
                        Label(
                            difficultyMenuTitle(difficulty),
                            systemImage: difficulty == plannedSubtask.difficulty ? "checkmark.circle.fill" : "circle"
                        )
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 9, weight: .semibold))
                    Text(plannedSubtask.difficulty.label)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(plannedSubtask.difficulty == .hard ? Theme.warn : Theme.text2)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(plannedSubtask.difficulty == .hard ? Theme.warnSoft : Theme.chip))
                .overlay(Capsule().stroke(Theme.line2))
            }
            .buttonStyle(.plain)

            Button {
                store.removePoolPlannedSubtask(chainID: chainID, plannedSubtaskID: plannedSubtask.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.text3)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
        }
    }

    private func difficultyMenuTitle(_ difficulty: SubtaskDifficulty) -> String {
        switch difficulty {
        case .simple:
            return "简单"
        case .medium:
            return "中等"
        case .hard:
            return "困难"
        }
    }
}

struct PoolNotesSection: View {
    @EnvironmentObject private var store: SuntraceStore
    let chainID: TaskChainID
    let noteText: String?

    var entries: [DetailNoteEntry] {
        DetailNoteEntryStorage.entries(from: noteText)
    }

    var body: some View {
        DetailSection("附言") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(entries) { entry in
                    DetailNoteEntryRow(entry: entry)
                }
                TextField("追加附言，回车确认", text: $store.detailNoteText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text1)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.noteBackground))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                    .onSubmit { store.appendPoolNote(chainID: chainID) }
            }
        }
    }
}

struct TaskTagInlineEditor: View {
    @EnvironmentObject private var store: SuntraceStore
    let chain: TaskChain
    @State private var draft = ""

    var tags: [(assignment: TaskTagAssignment, tag: TaskTag)] {
        store.tags(for: chain)
    }

    var normalizedQuery: String {
        let tail = draft.split(separator: "#", omittingEmptySubsequences: false).last.map(String.init) ?? draft
        return tail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var suggestions: [TaskTag] {
        store.inlineTagSuggestions(for: chain, query: normalizedQuery)
    }

    var primarySuggestionCount: Int {
        store.primaryInlineSuggestionCount(for: chain, query: normalizedQuery)
    }

    var showsSuggestions: Bool {
        draft.contains("#") && suggestions.isEmpty == false && tags.count < TaskTagSlot.allCases.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(tags, id: \.assignment.id) { item in
                    InlineTaskTagChip(tag: item.tag) {
                        store.removeInlineTag(chainID: chain.id, slot: item.assignment.slot)
                    }
                }
                if tags.count < TaskTagSlot.allCases.count {
                    TextField("#", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                        .lineLimit(1)
                        .onSubmit(commitDraft)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))

            if showsSuggestions {
                VStack(spacing: 0) {
                    ForEach(Array(suggestions.prefix(6).enumerated()), id: \.element.id) { index, tag in
                        if index == primarySuggestionCount, primarySuggestionCount > 0 {
                            Rectangle()
                                .fill(Theme.line)
                                .frame(height: 1)
                                .padding(.vertical, 2)
                        }
                        Button {
                            add(tag.name)
                        } label: {
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(tag.color)
                                    .frame(width: 7, height: 7)
                                Text("#\(tag.name)")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(Theme.text1)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 9)
                            .frame(height: 28)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
            }
        }
    }

    private func commitDraft() {
        let names = draft
            .split(separator: "#")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        if names.isEmpty {
            add(normalizedQuery)
        } else {
            names.forEach(add)
        }
    }

    private func add(_ name: String) {
        store.appendInlineTag(chainID: chain.id, name: name)
        draft = ""
    }
}

struct InlineTaskTagChip: View {
    let tag: TaskTag
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tag.status == .active ? tag.color : Theme.text3)
                .frame(width: 6, height: 6)
            Text("#\(tag.name)")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(tag.status == .active ? Theme.text1 : Theme.text3)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(Theme.text3)
                    .frame(width: 12, height: 12)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .frame(height: 22)
        .background(Capsule().fill(tag.status == .active ? tag.color.opacity(0.10) : Theme.chip))
        .overlay(Capsule().stroke(tag.status == .active ? tag.color.opacity(0.24) : Theme.line))
    }
}

struct FuturePlanDetail: View {
    @EnvironmentObject private var store: SuntraceStore
    let trace: DayTrace
    let definition: TaskDefinition

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DetailHeader("计划详情", onClose: { store.clearSelection() }, trailing: {
                IconMenuButton(menuContent: {
                    Button(store.copy.openDay) { openDay() }
                    Button(store.copy.reschedule) { store.showingPicker = .reschedule(trace.id) }
                    Button(store.copy.returnToPool) { store.returnToPool(trace.id) }
                })
            })
            DetailTitleRow(definition.title)

            DetailDescriptionBlock(
                text: Binding(
                    get: { trace.descriptionText ?? definition.descriptionText ?? "" },
                    set: { store.updateTraceText(traceID: trace.id, descriptionText: $0) }
                ),
                placeholder: "补充这个计划的背景、目标或范围…",
                editable: true
            )

            HStack(spacing: 8) {
                PlanMetaPill(text: "计划草稿", color: Theme.navFuture)
                Text("\(SuntraceStore.displayDate(trace.date)) \(SuntraceStore.weekday(trace.date))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
            }

            PlanSummaryCard(items: [
                PlanSummaryItem(label: "日期", value: SuntraceStore.displayDate(trace.date), color: Theme.navFuture),
                PlanSummaryItem(label: "优先级", value: "\(trace.priority)", color: Theme.text2),
                PlanSummaryItem(label: "状态", value: "未到期", color: Theme.text2)
            ])

            Notice(text: "未来计划可改期、排序或回池；到达当天前不能标记完成。", tone: .locked)

            DetailSection("计划操作") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        SmallActionButton(store.copy.openDay, tone: .accent) { openDay() }
                        SmallActionButton(store.copy.reschedule) { store.showingPicker = .reschedule(trace.id) }
                    }
                    SmallActionButton(store.copy.returnToPool) { store.returnToPool(trace.id) }
                }
            }

            DetailSection("任务轨迹") {
                Timeline(trace: trace)
            }

            DetailNotesSection(
                traceID: trace.id,
                noteText: trace.note ?? definition.note,
                editable: true,
                placeholder: "追加未来计划附言，回车确认"
            )
        }
    }

    private func openDay() {
        store.selectedDate = trace.date
        store.page = .day
        store.selectTrace(trace.id)
    }
}

struct PlanSummaryItem {
    let label: String
    let value: String
    let color: Color
}

struct PlanSummaryCard: View {
    let items: [PlanSummaryItem]

    var body: some View {
        VStack(spacing: 7) {
            ForEach(items, id: \.label) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.label)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                        .frame(width: 44, alignment: .leading)
                    Text(item.value)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(item.color)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.navFuture.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
    }
}

struct UnfinishedDetail: View {
    @EnvironmentObject private var store: SuntraceStore
    let item: UnfinishedPoolItem

    var latestUnfinished: DayTrace? { item.latestUnfinishedTrace }
    var detailTrace: DayTrace? { latestUnfinished ?? item.activeTrace }

    var body: some View {
        if let trace = detailTrace {
            VStack(alignment: .leading, spacing: 14) {
                DetailHeader("任务详情", onClose: { store.clearSelection() })
                DetailTitleRow(item.definition.title)

                DetailDescriptionBlock(
                    text: .constant(trace.descriptionText ?? item.definition.descriptionText ?? ""),
                    placeholder: "",
                    editable: false
                )

                HStack(spacing: 8) {
                    StatusChip(status: item.isAbandoned ? .abandoned : .unfinished)
                    Text("\(SuntraceStore.displayDate(trace.date)) \(SuntraceStore.weekday(trace.date))")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text3)
                }

                UnfinishedTraceContextCard(item: item, trace: trace)
                Notice(
                    text: item.isAbandoned
                        ? "任务链已废弃；历史事实保留，可重新启用并回到未完成状态。"
                        : "历史事实只读，不可删除或改写。",
                    tone: .locked
                )

                if item.isAbandoned {
                    SmallActionButton("重新启用", tone: .accent) { store.reactivateAbandonedChain(from: trace.id) }
                }

                DetailProgressSection(
                    traceID: trace.id,
                    progress: store.engine.traceProgress(for: trace.id),
                    editable: false
                )

                DetailSection("任务轨迹") {
                    Timeline(trace: trace)
                }

                DetailNotesSection(
                    traceID: trace.id,
                    noteText: trace.note ?? item.definition.note,
                    editable: false,
                    placeholder: "追加附言，回车确认"
                )
            }
        } else {
            RailHint(text: "没有需要处理的未完成轨迹。")
        }
    }
}

struct UnfinishedTraceContextCard: View {
    let item: UnfinishedPoolItem
    let trace: DayTrace

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("第 \(trace.continuationSeq) 次延续")
            Text("·")
                .foregroundStyle(Theme.text3)
            Text("持续 \(durationDays) 天")
            if let active = item.activeTrace {
                Text("·")
                    .foregroundStyle(Theme.text3)
                Text("已延续到 \(SuntraceStore.displayDate(active.date))")
                    .foregroundStyle(Theme.accent)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.text2)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.warnSoft.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
    }

    var durationDays: Int {
        let traces = (item.unfinishedTraces + [item.activeTrace].compactMap { $0 }).sorted { $0.date < $1.date }
        guard let first = traces.first else { return 1 }
        let calendar = Calendar(identifier: .gregorian)
        let start = localGregorianDate(from: first.date)
        let end = localGregorianDate(from: trace.date)
        return max(1, (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1)
    }
}

private func localGregorianDate(from localDate: LocalDate) -> Date {
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.year = localDate.year
    components.month = localDate.month
    components.day = localDate.day
    return components.date ?? Date(timeIntervalSince1970: 0)
}

struct ReviewRail: View {
    @EnvironmentObject private var store: SuntraceStore

    var day: Day? { store.engine.days[store.selectedDate] }
    var stats: DailyReviewStats { store.engine.dailyReviewStats(date: store.selectedDate) }
    var noReview: Bool { store.isFuture }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("每日复盘")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .tracking(0.8)
                if let message = store.reviewAutosaveMessage {
                    ReviewSavedIndicator(text: message)
                }
                Spacer()
                Text("\(SuntraceStore.displayDate(store.selectedDate)) \(SuntraceStore.weekday(store.selectedDate))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
            }
            if store.isHistory {
                Text("历史日复盘可随时补写")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)
            }
            if store.selectedDate == store.today {
                ZhulongReviewEntryButton()
            }
            if noReview {
                Text("未来日还没有复盘。到了这一天，复盘会在这里生成。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
            } else {
                ReviewStatsCard(stats: stats)
                ReviewEditor(
                    title: "今日总结",
                    placeholder: "今天整体推进如何？",
                    text: Binding(
                        get: { day?.reviewSummary ?? "" },
                        set: { store.updateReview(summary: $0) }
                    )
                )
                ReviewEditor(
                    title: "未完成原因",
                    placeholder: "哪些没完成，真实原因是什么？",
                    text: Binding(
                        get: { day?.reviewUnfinishedReason ?? "" },
                        set: { store.updateReview(reason: $0) }
                    )
                )
                ReviewEditor(
                    title: "明日注意事项",
                    placeholder: "明天开始前想提醒自己什么？",
                    text: Binding(
                        get: { day?.reviewTomorrowNote ?? "" },
                        set: { store.updateReview(tomorrow: $0) }
                    )
                )
            }
        }
    }
}

struct ReviewSavedIndicator: View {
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "checkmark")
                .font(.system(size: 8.5, weight: .bold))
            Text(text)
        }
        .font(.system(size: 10))
        .foregroundStyle(Theme.ok.opacity(0.9))
    }
}

struct ZhulongReviewEntryButton: View {
    @EnvironmentObject private var store: SuntraceStore

    var body: some View {
        Button {
            store.requestZhulongDailyReviewFromReviewRail()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                Text(store.copy.analyzeTodayWithZhulong)
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .hoverSurface(
                cornerRadius: 8,
                idleFill: Theme.accentSoft,
                hoverFill: Theme.accentSoft.opacity(0.72),
                idleStroke: Theme.accent.opacity(0.18),
                hoverStroke: Theme.accent.opacity(0.32)
            )
        }
        .buttonStyle(.plain)
    }
}

struct ReviewStatsCard: View {
    let stats: DailyReviewStats

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("总任务")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                Spacer()
                Text("\(stats.total)")
                    .font(.system(size: 22, weight: .semibold))
            }
            GeometryReader { proxy in
                HStack(spacing: 1.5) {
                    segment(stats.completed, total: stats.total, color: Theme.ok, width: proxy.size.width)
                    segment(pendingCount, total: stats.total, color: Theme.accent, width: proxy.size.width)
                    segment(stats.unfinished, total: stats.total, color: Theme.warn, width: proxy.size.width)
                }
            }
            .frame(height: 7)
            .clipShape(Capsule())
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 5) {
                legend("待完成", pendingCount, Theme.accent)
                legend("已完成", stats.completed, Theme.ok)
                legend("未完成", stats.unfinished, Theme.warn)
                legend("已延续", stats.continued, Theme.text2)
                legend("已变更", stats.changed, Theme.text2)
                legend("已回池", stats.returnedToPool, Theme.text2)
                legend("已废弃", stats.abandoned, Theme.text2)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel2))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
    }

    func segment(_ value: Int, total: Int, color: Color, width: CGFloat) -> some View {
        Rectangle()
            .fill(value == 0 ? Color.clear : color)
            .frame(width: total == 0 ? 0 : max(2, width * CGFloat(value) / CGFloat(total)))
    }

    var pendingCount: Int {
        max(
            0,
            stats.total
                - stats.completed
                - stats.unfinished
                - stats.continued
                - stats.changed
                - stats.returnedToPool
                - stats.abandoned
        )
    }

    func legend(_ label: String, _ value: Int, _ color: Color) -> some View {
        HStack {
            Circle().fill(value == 0 ? Theme.line2 : color).frame(width: 6, height: 6)
            Text(label)
            Spacer()
            Text("\(value)")
        }
        .font(.system(size: 11))
        .foregroundStyle(value == 0 ? Theme.text3 : Theme.text2)
    }
}

struct ReviewEditor: View {
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.text2)
            TextEditor(text: $text)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 76)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text3)
                            .padding(12)
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}

struct DatePickerSheet: View {
    @EnvironmentObject private var store: SuntraceStore
    let state: PickerSheetState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(state.purpose.title)
                .font(.system(size: 14, weight: .semibold))
            Text(state.purpose.rangeHint)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(store.dateChoices(allowPast: state.purpose.allowsPastDates, futureOnly: state.purpose.futureOnly)) { choice in
                        Button {
                            store.performDateChoice(choice.date)
                        } label: {
                            HStack {
                                Text(choice.label)
                                    .font(.system(size: 12.5))
                                Spacer()
                                Text(choice.subtitle)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.text3)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button("取消") { store.showingPicker = nil }
                .frame(maxWidth: .infinity)
        }
        .padding(14)
        .frame(width: 300, height: 440)
    }
}

struct FromPoolSheet: View {
    @EnvironmentObject private var store: SuntraceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("从任务池排期到这一天")
                .font(.system(size: 14, weight: .semibold))
            if store.selectedDate < store.today {
                Notice(text: "任务池不能排期到过去日期。请先切到今天或未来日期。", tone: .locked)
            } else {
                ForEach(store.engine.taskPool(), id: \.chain.id) { task in
                    Button {
                        store.schedulePoolTask(task.chain.id, date: store.selectedDate)
                        store.showingFromPoolPicker = false
                    } label: {
                        HStack {
                            Text(task.definition.title)
                            Spacer()
                            Text("排期")
                                .foregroundStyle(Theme.accent)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel))
                    }
                    .buttonStyle(.plain)
                }
                if store.engine.taskPool().isEmpty {
                    EmptyState(kind: .taskPool, text: "任务池是空的。")
                }
            }
            Button("取消") { store.showingFromPoolPicker = false }
                .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(width: 360)
    }
}

struct ChangeTaskSheet: View {
    @EnvironmentObject private var store: SuntraceStore

    var oldTitle: String {
        guard let trace = store.selectedTrace else { return "" }
        return store.definition(for: trace)?.title ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("变更为新任务")
                .font(.system(size: 14, weight: .semibold))
            Text("旧任务会保留在当天并标注已变更，新任务开启新的任务链。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2)
            Text(oldTitle)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text3)
                .strikethrough()
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
            TextField("新的任务标题", text: $store.changeText)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent))
            HStack {
                Spacer()
                Button("取消") { store.showingChangeDialog = false }
                Button("确认变更") { store.changeSelectedTrace() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}

struct SettingSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .tracking(0.6)
            content
        }
    }
}

struct SegmentedPair: View {
    let left: String
    let right: String
    let leftSelected: Bool
    let leftAction: () -> Void
    let rightAction: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            segment(left, selected: leftSelected, action: leftAction)
            segment(right, selected: !leftSelected, action: rightAction)
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.chip.opacity(0.82)))
    }

    func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.panel : .clear))
        }
        .buttonStyle(.plain)
    }
}

struct SegmentedOptionRow<Option: Hashable>: View {
    let options: [Option]
    let selected: Option
    let title: (Option) -> String
    let action: (Option) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                segment(option)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.chip.opacity(0.82)))
    }

    func segment(_ option: Option) -> some View {
        let isSelected = option == selected
        return Button {
            action(option)
        } label: {
            Text(title(option))
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(isSelected ? Theme.panel : .clear))
        }
        .buttonStyle(.plain)
    }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let badge: String?
    let badgeColor: Color
    let trailing: Trailing

    init(title: String, subtitle: String? = nil, badge: String? = nil, badgeColor: Color = Theme.accent, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.badge = badge
        self.badgeColor = badgeColor
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 21, weight: .bold))
                    if let badge {
                        StatusPill(text: badge, color: badgeColor)
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text3)
                }
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}

struct HeaderButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Theme.text2)
            .padding(.horizontal, title.count == 1 ? 8 : 10)
            .frame(height: 26)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
            .hoverSurface(
                cornerRadius: 7,
                idleFill: Theme.controlFill,
                hoverFill: Theme.listRowHover,
                idleStroke: Theme.line.opacity(0.72),
                hoverStroke: Theme.line2.opacity(0.72)
            )
    }
}

struct SmallActionButton: View {
    enum Tone { case normal, accent, warn }
    let title: String
    let tone: Tone
    let action: () -> Void

    init(_ title: String, tone: Tone = .normal, action: @escaping () -> Void) {
        self.title = title
        self.tone = tone
        self.action = action
    }

    var color: Color {
        switch tone {
        case .normal: Theme.text2
        case .accent: Theme.accent
        case .warn: Theme.warn
        }
    }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .fixedSize(horizontal: true, vertical: false)
            .hoverSurface(
                cornerRadius: 6,
                idleFill: Theme.controlFill,
                hoverFill: Theme.listRowHover,
                idleStroke: Theme.line.opacity(0.72),
                hoverStroke: Theme.line2.opacity(0.72)
            )
    }
}

struct HoverSurfaceModifier: ViewModifier {
    @State private var hovering = false

    let active: Bool
    let cornerRadius: CGFloat
    let idleFill: Color
    let hoverFill: Color
    let activeFill: Color
    let idleStroke: Color
    let hoverStroke: Color
    let activeStroke: Color
    let activeLineWidth: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(active ? activeFill : hovering ? hoverFill : idleFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(active ? activeStroke : hovering ? hoverStroke : idleStroke, lineWidth: active ? activeLineWidth : 1)
            )
            .onHover { hovering = $0 }
    }
}

struct ListRowSurfaceModifier: ViewModifier {
    let selected: Bool
    let tint: Color
    let cornerRadius: CGFloat
    let separatorLeadingInset: CGFloat

    func body(content: Content) -> some View {
        content
            .hoverSurface(
                active: selected,
                cornerRadius: cornerRadius,
                idleFill: Theme.panel,
                hoverFill: Theme.listRowHover,
                activeFill: tint.opacity(0.08),
                idleStroke: .clear,
                hoverStroke: .clear,
                activeStroke: .clear
            )
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Theme.line.opacity(selected ? 0 : 0.62))
                    .frame(height: 1)
                    .padding(.leading, separatorLeadingInset)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(selected ? tint.opacity(0.22) : .clear, lineWidth: 1)
            }
    }
}

extension View {
    func hoverSurface(
        active: Bool = false,
        cornerRadius: CGFloat,
        idleFill: Color,
        hoverFill: Color,
        activeFill: Color? = nil,
        idleStroke: Color,
        hoverStroke: Color,
        activeStroke: Color? = nil,
        activeLineWidth: CGFloat = 1
    ) -> some View {
        modifier(
            HoverSurfaceModifier(
                active: active,
                cornerRadius: cornerRadius,
                idleFill: idleFill,
                hoverFill: hoverFill,
                activeFill: activeFill ?? hoverFill,
                idleStroke: idleStroke,
                hoverStroke: hoverStroke,
                activeStroke: activeStroke ?? hoverStroke,
                activeLineWidth: activeLineWidth
            )
        )
    }

    func listRowSurface(
        selected: Bool,
        tint: Color,
        cornerRadius: CGFloat = 7,
        separatorLeadingInset: CGFloat = 0
    ) -> some View {
        modifier(
            ListRowSurfaceModifier(
                selected: selected,
                tint: tint,
                cornerRadius: cornerRadius,
                separatorLeadingInset: separatorLeadingInset
            )
        )
    }
}

struct PriorityStepper: View {
    let canMoveUp: Bool
    let canMoveDown: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void

    var body: some View {
        VStack(spacing: 1) {
            stepButton(
                systemName: "chevron.up",
                enabled: canMoveUp,
                accessibilityLabel: "优先级上移",
                action: moveUp
            )
            stepButton(
                systemName: "chevron.down",
                enabled: canMoveDown,
                accessibilityLabel: "优先级下移",
                action: moveDown
            )
        }
        .frame(width: 14, height: 24)
        .help("调整当日优先级")
    }

    func stepButton(systemName: String, enabled: Bool, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(enabled ? Theme.text2 : Theme.line2)
                .frame(width: 14, height: 11)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(enabled == false)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

struct TraceStatusStyle {
    let label: String
    let glyph: String
    let foreground: Color
    let softBackground: Color
    let glyphForeground: Color
    let glyphBackground: Color
    let glyphBorder: Color
    let dotColor: Color
    let titleColor: Color
    let strikethrough: Bool
}

extension TraceStatus {
    var uiStyle: TraceStatusStyle {
        switch self {
        case .pending:
            TraceStatusStyle(
                label: "待完成",
                glyph: "",
                foreground: Theme.accent,
                softBackground: Theme.accentSoft,
                glyphForeground: Theme.accent,
                glyphBackground: Theme.panel,
                glyphBorder: Theme.line2,
                dotColor: Theme.accent,
                titleColor: Theme.text1,
                strikethrough: false
            )
        case .completed:
            TraceStatusStyle(
                label: "已完成",
                glyph: "✓",
                foreground: Theme.ok,
                softBackground: Theme.okSoft,
                glyphForeground: .white,
                glyphBackground: Theme.ok,
                glyphBorder: .clear,
                dotColor: Theme.ok,
                titleColor: Theme.text3,
                strikethrough: true
            )
        case .unfinished:
            TraceStatusStyle(
                label: "未完成",
                glyph: "✕",
                foreground: Theme.warn,
                softBackground: Theme.warnSoft,
                glyphForeground: Theme.warn,
                glyphBackground: Theme.warnSoft,
                glyphBorder: .clear,
                dotColor: Theme.warn,
                titleColor: Theme.text2,
                strikethrough: false
            )
        case .continued:
            TraceStatusStyle(
                label: "已延续",
                glyph: "→",
                foreground: Theme.text2,
                softBackground: Theme.chip,
                glyphForeground: Theme.text2,
                glyphBackground: Theme.chip,
                glyphBorder: .clear,
                dotColor: Theme.text3,
                titleColor: Theme.text2,
                strikethrough: false
            )
        case .changed:
            TraceStatusStyle(
                label: "已变更",
                glyph: "⇄",
                foreground: Theme.text2,
                softBackground: Theme.chip,
                glyphForeground: Theme.text2,
                glyphBackground: Theme.chip,
                glyphBorder: .clear,
                dotColor: Theme.text3,
                titleColor: Theme.text2,
                strikethrough: false
            )
        case .returnedToPool:
            TraceStatusStyle(
                label: "已回池",
                glyph: "↩",
                foreground: Theme.text2,
                softBackground: Theme.chip,
                glyphForeground: Theme.text2,
                glyphBackground: Theme.chip,
                glyphBorder: .clear,
                dotColor: Theme.text3,
                titleColor: Theme.text2,
                strikethrough: false
            )
        case .abandoned:
            TraceStatusStyle(
                label: "已废弃",
                glyph: "—",
                foreground: Theme.text3,
                softBackground: Theme.chip,
                glyphForeground: Theme.text3,
                glyphBackground: Theme.chip,
                glyphBorder: .clear,
                dotColor: Theme.text3,
                titleColor: Theme.text3,
                strikethrough: true
            )
        }
    }
}

struct StatusGlyph: View {
    enum Scale { case standard, compact }

    let status: TraceStatus
    let scale: Scale
    var style: TraceStatusStyle { status.uiStyle }

    init(status: TraceStatus, scale: Scale = .standard) {
        self.status = status
        self.scale = scale
    }

    var body: some View {
        Text(style.glyph)
            .font(.system(size: scale == .compact ? 10 : 11, weight: .bold))
            .foregroundStyle(style.glyphForeground)
            .frame(width: scale == .compact ? 16 : 18, height: scale == .compact ? 16 : 18)
            .background(Circle().fill(style.glyphBackground))
            .overlay(Circle().stroke(style.glyphBorder, lineWidth: 1.5))
    }
}

struct StatusChip: View {
    enum Scale { case standard, compact }

    let status: TraceStatus
    let scale: Scale
    var style: TraceStatusStyle { status.uiStyle }

    init(status: TraceStatus, scale: Scale = .standard) {
        self.status = status
        self.scale = scale
    }

    var body: some View {
        HStack(spacing: scale == .compact ? 4 : 5) {
            Circle()
                .fill(style.dotColor)
                .frame(width: scale == .compact ? 4 : 5, height: scale == .compact ? 4 : 5)
            Text(style.label)
        }
        .font(.system(size: scale == .compact ? 10.5 : 11, weight: .medium))
        .foregroundStyle(style.foreground)
        .padding(.leading, scale == .compact ? 6 : 8)
        .padding(.trailing, scale == .compact ? 7 : 8)
        .padding(.vertical, 2)
        .background(Capsule().fill(style.softBackground))
    }
}

struct Notice: View {
    enum Tone { case locked, future }
    let text: String
    let tone: Tone

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: tone == .locked ? "lock.fill" : "calendar.badge.clock")
            Text(text)
        }
        .font(.system(size: 12))
        .foregroundStyle(tone == .locked ? Theme.text2 : Theme.accent)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(tone == .locked ? Theme.chip : Theme.accentSoft))
    }
}

enum EmptyStateKind {
    case dayTodo
    case taskPool
    case futurePlans
    case unfinishedPool
    case completedPool
    case calendar
}

struct EmptyState: View {
    let kind: EmptyStateKind
    let text: String

    var body: some View {
        VStack(spacing: 14) {
            EmptyStateIllustration()
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text3)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity)
    }
}

struct EmptyStateIllustration: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.line2, lineWidth: 1.5)
                .frame(width: 24, height: 24)
                .position(x: 32, y: 22)
            Path { path in
                path.move(to: CGPoint(x: 32, y: 22))
                path.addLine(to: CGPoint(x: 32, y: 13))
            }
            .stroke(Theme.line2, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            Circle()
                .fill(Theme.line2)
                .frame(width: 3, height: 3)
                .position(x: 32, y: 22)
            Path { path in
                path.move(to: CGPoint(x: 12, y: 40))
                path.addLine(to: CGPoint(x: 52, y: 40))
                path.move(to: CGPoint(x: 20, y: 44.5))
                path.addLine(to: CGPoint(x: 44, y: 44.5))
            }
            .stroke(Theme.line, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        .frame(width: 64, height: 48)
    }
}

struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .tracking(0.6)
            content
        }
    }
}
