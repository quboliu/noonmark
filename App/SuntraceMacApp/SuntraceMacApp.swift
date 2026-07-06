import AppKit
import SuntraceAI
import SuntraceCore
import SuntraceStorage
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
        if CommandLine.arguments.contains("--page"), let index = CommandLine.arguments.firstIndex(of: "--page") {
            let valueIndex = CommandLine.arguments.index(after: index)
            let pageName = CommandLine.arguments.indices.contains(valueIndex) ? CommandLine.arguments[valueIndex] : ""
            if let page = SuntraceStore.Page(commandLineValue: pageName) {
                delegate.store.page = page
            }
        }
        if CommandLine.arguments.contains("--select"), let index = CommandLine.arguments.firstIndex(of: "--select") {
            let valueIndex = CommandLine.arguments.index(after: index)
            let selectionName = CommandLine.arguments.indices.contains(valueIndex) ? CommandLine.arguments[valueIndex] : ""
            if selectionName == "first" || selectionName == "manual" {
                delegate.store.selectItemForLaunch(selectionName)
            }
        }
        retainedDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
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
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.title = "晷迹 · suntrace"
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.isMovableByWindowBackground = true
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
        let quickTaskTitle = SuntraceStore.commandLineValue(after: "--e2e-add-quick-task")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let zhulongTaskName = SuntraceStore.commandLineValue(after: "--e2e-generate-zhulong-draft")
        let providerAutomation = ProviderE2EAutomation.fromCommandLine()
        let workflowAutomation = WorkflowE2EAutomation.fromCommandLine()
        let lifecycleAutomation = LifecycleE2EAutomation.fromCommandLine()
        let dataPackageAutomation = DataPackageE2EAutomation.fromCommandLine()
        guard quickTaskTitle?.isEmpty == false
            || zhulongTaskName != nil
            || providerAutomation != nil
            || workflowAutomation != nil
            || lifecycleAutomation != nil
            || dataPackageAutomation != nil
        else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [store] in
            if let quickTaskTitle, quickTaskTitle.isEmpty == false {
                store.page = .day
                store.selectedDate = store.today
                store.quickText = quickTaskTitle
                store.addQuickTask()
            }

            if let zhulongTaskName, let task = ZhulongTask(rawValue: zhulongTaskName) {
                store.page = .zhulong
                store.generateZhulongDraft(task: task)
                if CommandLine.arguments.contains("--e2e-apply-first-zhulong-operation") {
                    if let draft = store.zhulongDrafts.first, draft.proposedOperations.isEmpty == false {
                        store.applyZhulongOperation(draftID: draft.id, operationIndex: 0)
                    }
                }
            }

            if let providerAutomation {
                providerAutomation.run(on: store)
            }

            if let workflowAutomation {
                workflowAutomation.run(on: store)
            }

            if let lifecycleAutomation {
                lifecycleAutomation.run(on: store)
            }

            if let dataPackageAutomation {
                dataPackageAutomation.run(on: store)
            }

            if CommandLine.arguments.contains("--e2e-quit-after-automation") {
                store.persist()
                NSApp.terminate(nil)
            }
        }
    }
}

private struct DataPackageE2EAutomation {
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

private struct LifecycleE2EAutomation {
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
        store.abandon(traceID)
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

private struct WorkflowE2EAutomation {
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

private struct ProviderE2EAutomation {
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
    @Published var toast: String?
    @Published var zhulongProviderDraft = ZhulongProviderSettingsStore.load()
    @Published var zhulongDrafts: [AISuggestionDraft] = []
    @Published var selectedZhulongDraftID: AISuggestionDraftID?
    @Published var appliedZhulongOperationKeys: Set<String> = []

    let today = LocalDate("2026-07-05")
    private let repository: SQLiteEngineRepository?
    private var toastTask: Task<Void, Never>?
    private var undoStack: [SuntraceSnapshot] = []

    init() {
        if CommandLine.arguments.contains("--ephemeral") {
            repository = nil
            seed()
        } else {
            repository = SQLiteEngineRepository(databaseURL: Self.configuredDatabaseURL())
            loadOrSeed()
        }
        Theme.apply(engine.preferences.theme)
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

    var copy: AppCopy {
        AppCopy(language: engine.preferences.language)
    }

    var windowTitle: String {
        "\(copy.appName) — \(Self.displayDate(selectedDate))"
    }

    func definition(for trace: DayTrace) -> TaskDefinition? {
        engine.definitions[trace.definitionID]
    }

    func subtasks(for traceID: DayTraceID) -> [Subtask] {
        engine.subtasks.values
            .filter { $0.traceID == traceID }
            .sorted { $0.position < $1.position }
    }

    func dateChoices(allowPast: Bool = false, futureOnly: Bool = false) -> [DateChoice] {
        (-7...21).compactMap { offset in
            let date = Self.offset(today, by: offset)
            if futureOnly, date <= today { return nil }
            if allowPast == false, date < today { return nil }
            return DateChoice(date: date, label: Self.displayDate(date), subtitle: Self.weekday(date))
        }
    }

    func selectPage(_ next: Page) {
        page = next
        clearSelection()
    }

    func selectTrace(_ traceID: DayTraceID) {
        selectedTraceID = traceID
        selectedPoolChainID = nil
        selectedUnfinishedChainID = nil
        selectedCompletedTraceID = nil
        selectedCompletedSubtaskID = nil
        detailSubtaskText = ""
    }

    func selectPool(_ chainID: TaskChainID) {
        selectedPoolChainID = chainID
        selectedTraceID = nil
        selectedUnfinishedChainID = nil
        selectedCompletedTraceID = nil
        selectedCompletedSubtaskID = nil
        detailSubtaskText = ""
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
    }

    func addQuickTask() {
        let title = quickText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.isEmpty == false else { return }
        do {
            pushUndoSnapshotIfAllowed(on: selectedDate)
            let chainID = try engine.createPoolTask(title: title, descriptionText: "快速记录自 Day Todo。", now: Date())
            _ = try engine.scheduleFromPool(chainID: chainID, date: selectedDate, today: today)
            quickText = ""
            persist()
            showToast("已添加「\(title)」")
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func addPoolTask() {
        let title = poolText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.isEmpty == false else { return }
        do {
            let chainID = try engine.createPoolTask(title: title, descriptionText: "任务池中的待排期任务。", note: "可以排期到今天、明天或指定日期。")
            selectedPoolChainID = chainID
            poolText = ""
            persist()
            showToast("已加入任务池")
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func schedulePoolTask(_ chainID: TaskChainID, date: LocalDate) {
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
        do {
            if subtask.status == .pending {
                pushUndoSnapshotIfAllowed(on: trace.date)
                try engine.completeSubtask(subtaskID, today: today)
                persist()
                showToast("子任务已完成")
            } else {
                showToast("历史子任务不可改写")
            }
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func cycleSubtaskDifficulty(_ subtaskID: SubtaskID) {
        guard let current = engine.subtasks[subtaskID]?.difficulty else { return }
        guard let trace = engine.subtasks[subtaskID].flatMap({ engine.traces[$0.traceID] }) else { return }
        let next: SubtaskDifficulty = switch current {
        case .simple: .medium
        case .medium: .hard
        case .hard: .simple
        }
        do {
            pushUndoSnapshotIfAllowed(on: trace.date)
            try engine.updateSubtaskDifficulty(subtaskID, difficulty: next, today: today)
            persist()
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func continueTrace(_ traceID: DayTraceID, to date: LocalDate) {
        do {
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
            try engine.abandonChain(from: traceID)
            persist()
            showToast("任务链已废弃")
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func copyAsNewTask(_ traceID: DayTraceID) {
        do {
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
    }

    func updateTraceText(traceID: DayTraceID, descriptionText: String? = nil, note: String? = nil) {
        guard let trace = engine.traces[traceID] else { return }
        do {
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

    func exportDataPackage() {
        let panel = NSSavePanel()
        panel.title = "导出晷迹数据"
        panel.nameFieldStringValue = "suntrace-backup-\(today.description).json"
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

        undoStack.append(engine.snapshot())
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
            showToast("Provider 配置已保存")
        } catch {
            showToast("Provider 保存失败：\(error.localizedDescription)")
        }
    }

    func clearZhulongProvider() {
        do {
            zhulongProviderDraft = try ZhulongProviderSettingsStore.clear()
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
            .appendingPathComponent("suntrace", isDirectory: true)
            .appendingPathComponent("Suntrace.sqlite")
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
            try repository.save(engine)
        } catch {
            NSLog("Suntrace persistence save failed: %@", String(describing: error))
            showToast("保存失败：\(error.localizedDescription)")
        }
    }

    private func pushUndoSnapshotIfAllowed(on date: LocalDate) {
        guard date >= today else { return }
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
            let okr = try engine.createPoolTask(
                title: "整理 Q3 OKR 草案",
                descriptionText: "汇总三条产品线负责人给的季度目标，收敛成不超过 3 个 O、每个 O 配 3 个可量化 KR。",
                note: "等数据组下午的留存看板再定第 2 个 KR 的口径。",
                now: seedNow()
            )
            let okrDay0 = try engine.scheduleFromPool(chainID: okr, date: day0, today: day0, now: now)

            let launchScript = try engine.createPoolTask(title: "给发布会准备演示脚本", descriptionText: "准备发布会现场演示脚本。", now: seedNow())
            _ = try engine.scheduleFromPool(chainID: launchScript, date: dayMinus3, today: dayMinus3, now: now)
            let physical = try engine.createPoolTask(title: "预约年度体检", descriptionText: "预约年度体检时间。", now: seedNow())
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
            let iconDay2 = try engine.scheduleFromPool(chainID: iconExport, date: day2, today: day2, now: now)
            try engine.setManualProgress(traceID: iconDay2, percent: 45, today: day2)
            let iconToday = try engine.continueTrace(traceID: iconDay2, targetDate: day3, today: day2, now: now)
            try engine.setManualProgress(traceID: iconToday, percent: 45, today: day3)

            let weeklyReport = try engine.createPoolTask(title: "写本周周报", descriptionText: "整理本周进展和风险。", now: seedNow())
            let weeklyDay1 = try engine.scheduleFromPool(chainID: weeklyReport, date: day1, today: day1, now: now)
            let weeklyDay2 = try engine.continueTrace(traceID: weeklyDay1, targetDate: day2, today: day1, now: now)
            try engine.markCompleted(traceID: weeklyDay2, today: day2, now: eventTime(day2, hour: 17, minute: 45))

            let pricing = try engine.createPoolTask(title: "调研竞品定价", descriptionText: "旧任务范围过大，需要变更为可交付对比表。", now: seedNow())
            let pricingTrace = try engine.scheduleFromPool(chainID: pricing, date: day2, today: day2, now: now)
            _ = try engine.changeTrace(traceID: pricingTrace, newTitle: "输出竞品定价对比表", today: day2, now: seedNow())

            let visual = try engine.createPoolTask(title: "制作发布会主视觉", descriptionText: "推进发布会主视觉定稿。", now: seedNow())
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
            let onboardingTrace = try engine.scheduleFromPool(chainID: onboarding, date: day3, today: day3, now: now)
            let headline = try engine.addSubtask(traceID: onboardingTrace, title: "首屏标题与副标题", difficulty: .simple, now: now)
            _ = try engine.addSubtask(traceID: onboardingTrace, title: "通知权限请求文案", difficulty: .medium, now: now)
            try engine.completeSubtask(headline, today: day3, now: eventTime(day3, hour: 9, minute: 0))

            let running = try engine.createPoolTask(title: "晨跑 5 公里", descriptionText: "完成晨跑。", now: seedNow())
            let runningTrace = try engine.scheduleFromPool(chainID: running, date: day3, today: day3, now: now)
            try engine.markCompleted(traceID: runningTrace, today: day3, now: eventTime(day3, hour: 7, minute: 36))

            let downloads = try engine.createPoolTask(title: "清理下载文件夹", descriptionText: "清理下载文件夹。", now: seedNow())
            _ = try engine.scheduleFromPool(chainID: downloads, date: day3, today: day3, now: now)

            _ = try engine.createPoolTask(title: "读《卡片笔记写作法》第三章", descriptionText: "任务池样例任务。", now: seedNow())
            _ = try engine.createPoolTask(title: "调研 SwiftUI 动画 API", descriptionText: "任务池样例任务。", now: seedNow())

            let standup = try engine.createPoolTask(title: "准备周一站会要点", descriptionText: "未来计划样例任务。", now: seedNow())
            _ = try engine.scheduleFromPool(chainID: standup, date: day4, today: day3, now: now)
            let invoice = try engine.createPoolTask(title: "整理六月发票报销", descriptionText: "未来计划样例任务。", now: seedNow())
            _ = try engine.scheduleFromPool(chainID: invoice, date: day5, today: day3, now: now)
            let dinner = try engine.createPoolTask(title: "预订团队聚餐餐厅", descriptionText: "未来计划样例任务。", now: seedNow())
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
            Theme.desk
                .ignoresSafeArea()

            VStack(spacing: 0) {
                WindowChrome()
                HStack(spacing: 0) {
                    Sidebar()
                    MainSurface()
                }
            }
            .background(Theme.background)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.black.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 34, x: 0, y: 24)
            .padding(18)

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
        case .english: "Suntrace"
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
    var completedSubtitle: String {
        language == .chinese ? "按完成记录逐条展示，并附带每条的任务轨迹。" : "Completed records with their task trajectories."
    }

    var emptyCompleted: String { language == .chinese ? "还没有完成记录。" : "No completed records yet." }
    var calendarSubtitle: String {
        language == .chinese ? "整月轨迹总览。点选任一天，右侧查看当天详情。" : "A whole-month trace overview. Pick any day to inspect it on the right."
    }

    var settingsSubtitle: String {
        language == .chinese
            ? "偏好、数据包、同步占位和烛龙 Provider 的统一入口。"
            : "Preferences, data packages, sync placeholders, and Zhulong Provider in one place."
    }

    var preferencesTitle: String { language == .chinese ? "偏好" : "Preferences" }
    var preferencesSubtitle: String {
        language == .chinese ? "影响本机显示，不改变任务事实。" : "Affects local display only; task facts stay unchanged."
    }

    var appearanceTitle: String { language == .chinese ? "外观" : "Appearance" }
    var coolGray: String { language == .chinese ? "冷灰" : "Cool gray" }
    var warmPaper: String { language == .chinese ? "微暖纸感" : "Warm paper" }
    var languageTitle: String { language == .chinese ? "语言" : "Language" }

    var dataPackageTitle: String { language == .chinese ? "数据包" : "Data Package" }
    var dataPackageSubtitle: String {
        language == .chinese
            ? "本地优先。导入前会校验重复键和断裂引用。"
            : "Local-first. Imports validate duplicate keys and broken references."
    }

    var exportJSON: String { language == .chinese ? "导出数据 (JSON)" : "Export JSON" }
    var importData: String { language == .chinese ? "导入数据…" : "Import…" }
    var todayTraceMetric: String { language == .chinese ? "今日轨迹" : "Today" }
    var taskPoolMetric: String { navPool }
    var unfinishedMetric: String { navUnfinished }
    var completedMetric: String { navCompleted }
    var syncTitle: String { language == .chinese ? "同步" : "Sync" }
    var planned: String { language == .chinese ? "规划中" : "Planned" }

    var providerTitle: String { language == .chinese ? "烛龙 Provider" : "Zhulong Provider" }
    var providerSubtitle: String {
        language == .chinese ? "AI 是可选 sidecar；普通清单不依赖 Provider。" : "AI is optional; normal lists do not depend on a Provider."
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
    var openZhulongConfig: String { language == .chinese ? "打开烛龙配置" : "Open Zhulong" }
    var save: String { language == .chinese ? "保存" : "Save" }
    var testConnection: String { language == .chinese ? "测试连接" : "Test" }
    var clear: String { language == .chinese ? "清空" : "Clear" }

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
        case (.english, .customEndpoint): "Custom sync endpoint"
        case (.english, .iCloud): "iCloud sync"
        }
    }

    func syncDescription(for kind: SyncEndpointKind) -> String {
        switch (language, kind) {
        case (.chinese, .customEndpoint): "连接自有服务端"
        case (.chinese, .iCloud): "原生云同步"
        case (.english, .customEndpoint): "Connect your own server"
        case (.english, .iCloud): "Native cloud sync"
        }
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
        let text1: Color
        let text2: Color
        let text3: Color
        let chip: Color
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
                desk: Color(red: 0.898, green: 0.902, blue: 0.914),
                background: Color(red: 0.962, green: 0.962, blue: 0.968),
                panel: .white,
                panel2: Color(red: 0.982, green: 0.982, blue: 0.987),
                line: Color(red: 0.91, green: 0.91, blue: 0.925),
                line2: Color(red: 0.82, green: 0.82, blue: 0.85),
                text1: Color(red: 0.11, green: 0.11, blue: 0.12),
                text2: Color(red: 0.42, green: 0.42, blue: 0.46),
                text3: Color(red: 0.63, green: 0.63, blue: 0.67),
                chip: Color(red: 0.946, green: 0.946, blue: 0.956)
            )
        case .warmPaper:
            return Palette(
                desk: Color(red: 0.925, green: 0.905, blue: 0.865),
                background: Color(red: 0.982, green: 0.969, blue: 0.942),
                panel: Color(red: 1.0, green: 0.995, blue: 0.978),
                panel2: Color(red: 0.988, green: 0.974, blue: 0.948),
                line: Color(red: 0.91, green: 0.878, blue: 0.82),
                line2: Color(red: 0.79, green: 0.725, blue: 0.64),
                text1: Color(red: 0.13, green: 0.105, blue: 0.085),
                text2: Color(red: 0.44, green: 0.385, blue: 0.32),
                text3: Color(red: 0.64, green: 0.58, blue: 0.50),
                chip: Color(red: 0.955, green: 0.936, blue: 0.902)
            )
        }
    }

    static var desk: Color { palette.desk }
    static var background: Color { palette.background }
    static var panel: Color { palette.panel }
    static var panel2: Color { palette.panel2 }
    static var line: Color { palette.line }
    static var line2: Color { palette.line2 }
    static var text1: Color { palette.text1 }
    static var text2: Color { palette.text2 }
    static var text3: Color { palette.text3 }
    static var chip: Color { palette.chip }
    static let accent = Color(red: 0.16, green: 0.38, blue: 0.78)
    static let accentSoft = Color(red: 0.93, green: 0.955, blue: 1.0)
    static let ok = Color(red: 0.08, green: 0.55, blue: 0.38)
    static let okSoft = Color(red: 0.91, green: 0.98, blue: 0.95)
    static let warn = Color(red: 0.82, green: 0.36, blue: 0.12)
    static let warnSoft = Color(red: 1.0, green: 0.945, blue: 0.9)
    static let navDay = hex(0x2A6FDB)
    static let navPool = hex(0x0E9488)
    static let navFuture = hex(0x7C5CFF)
    static let navUnfinished = hex(0xE0851B)
    static let navCompleted = hex(0x1F8A5B)
    static let navCalendar = hex(0xD1477A)
    static let navZhulong = hex(0x7C5CFF)
    static let navSettings = hex(0x64748B)
}

struct WindowChrome: View {
    @EnvironmentObject private var store: SuntraceStore

    var body: some View {
        HStack(spacing: 9) {
            trafficLight(color: Color(red: 1, green: 0.451, blue: 0.416))
            trafficLight(color: Color(red: 0.996, green: 0.737, blue: 0.18))
            trafficLight(color: Color(red: 0.098, green: 0.765, blue: 0.188))
            Spacer()
            Text(store.windowTitle)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.text2)
                .lineLimit(1)
            Spacer()
            Color.clear.frame(width: 60, height: 1)
        }
        .frame(height: 42)
        .padding(.horizontal, 14)
        .background(Theme.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }

    private func trafficLight(color: Color) -> some View {
        Circle()
            .fill(color)
            .overlay(Circle().stroke(.black.opacity(0.1), lineWidth: 0.5))
            .frame(width: 14, height: 14)
    }
}

struct Sidebar: View {
    @EnvironmentObject private var store: SuntraceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                ClockLogo()
                Text(store.copy.appName)
                    .font(.system(size: 16, weight: .bold))
                    .tracking(0.2)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 16)

            NavGroupTitle(store.copy.planGroup)
            NavItem(
                page: .day,
                label: store.copy.navDay,
                count: store.engine.getDayTodo(date: store.today).traces.filter { $0.status == .pending }.count
            )
            NavItem(page: .pool, label: store.copy.navPool, count: store.engine.taskPool().count)
            NavItem(
                page: .future,
                label: store.copy.navFuture,
                count: store.engine.futurePlans(today: store.today).count
            )

            NavGroupTitle(store.copy.traceGroup)
                .padding(.top, 12)
            NavItem(
                page: .unfinished,
                label: store.copy.navUnfinished,
                count: store.engine.unfinishedPool().count
            )
            NavItem(
                page: .completed,
                label: store.copy.navCompleted,
                count: store.engine.completedPool().count + store.engine.completedSubtaskRecords().count
            )
            NavItem(page: .calendar, label: store.copy.navCalendar, count: 0)

            Spacer()
            NavItem(page: .settings, label: store.copy.navSettings, count: 0)
        }
        .frame(width: 204)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(Theme.panel2)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.line).frame(width: 1)
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
            .tracking(0.8)
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
                    .foregroundStyle(active ? Theme.accent : Theme.text2)
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text2)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 19, minHeight: 17)
                        .background(Capsule().fill(Theme.chip))
                }
            }
            .frame(height: 32)
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .hoverSurface(
                active: active,
                cornerRadius: 7,
                idleFill: .clear,
                hoverFill: Theme.chip,
                activeFill: Theme.accentSoft,
                idleStroke: .clear,
                hoverStroke: Theme.line,
                activeStroke: .clear
            )
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 99)
                    .fill(active ? Theme.accent : .clear)
                    .frame(width: 2.5, height: 15)
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

            if store.page != .calendar && store.page != .settings {
                DetailRail()
                    .frame(width: 300)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Theme.line).frame(width: 1)
                    }
            }
        }
        .background(Theme.background)
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

            ScrollView {
                VStack(spacing: 0) {
                    if store.isHistory == false {
                        DayQuickAdd()
                            .padding(.bottom, 12)
                    }

                    LazyVStack(spacing: 6) {
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
        HStack(spacing: 8) {
            TextField(store.isFuture ? "为这一天排期任务，回车确认" : "添加今日任务，回车确认", text: $store.quickText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                .onSubmit { store.addQuickTask() }
            HeaderButton(store.copy.scheduleFromPool) { store.showingFromPoolPicker = true }
        }
    }
}

struct DateStrip: View {
    @EnvironmentObject private var store: SuntraceStore

    var dates: [LocalDate] {
        (-6...7).map { SuntraceStore.offset(store.today, by: $0) }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(dates, id: \.self) { date in
                let selected = date == store.selectedDate
                let today = date == store.today
                let count = store.engine.getDayTodo(date: date).traces.count
                Button {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.75)) {
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
                            .background(Circle().fill(selected ? Theme.accent : .clear))
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
        .padding(.top, 14)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
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
                }

                Spacer()

                if subtasks.isEmpty == false {
                    Button(expanded ? "▾" : "▸") {
                        if expanded {
                            store.expandedTraceIDs.remove(trace.id)
                        } else {
                            store.expandedTraceIDs.insert(trace.id)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
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
                .padding(.leading, 40)
                .padding(.trailing, 12)
                .padding(.bottom, 10)
            }
        }
        .hoverSurface(
            active: selected,
            cornerRadius: 8,
            idleFill: Theme.panel,
            hoverFill: Theme.panel2,
            activeFill: Theme.accentSoft,
            idleStroke: Theme.line,
            hoverStroke: Theme.line2,
            activeStroke: Theme.accent
        )
        .contentShape(Rectangle())
        .onTapGesture { store.selectTrace(trace.id) }
        .contextMenu {
            TaskContextMenu(trace: trace)
        }
    }

    var metaText: String {
        var parts: [String] = []
        if trace.continuationSeq > 0 { parts.append("第 \(trace.continuationSeq) 次延续") }
        if trace.changedToTraceID != nil { parts.append("被变更为新任务") }
        if trace.status == .returnedToPool { parts.append("当天已回池") }
        if progress.floorPercent > 0 { parts.append("进度下限 \(progress.floorPercent)%") }
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

struct SubtaskRow: View {
    @EnvironmentObject private var store: SuntraceStore
    let subtask: Subtask

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

            if subtask.completedAt != nil {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.text3)
            }

            Button(subtask.difficulty.label) {
                store.cycleSubtaskDifficulty(subtask.id)
            }
            .buttonStyle(.plain)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(subtask.difficulty == .hard ? Theme.warn : Theme.text2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(subtask.difficulty == .hard ? Theme.warnSoft : Theme.chip))
        }
    }
}

struct TaskContextMenu: View {
    @EnvironmentObject private var store: SuntraceStore
    let trace: DayTrace

    var body: some View {
        if trace.status == .pending {
            Button(store.copy.markComplete) { store.toggleComplete(trace.id) }
        }
        if trace.status == .completed {
            Button(store.copy.undoComplete) { store.toggleComplete(trace.id) }
        }
        Button(store.copy.continueTo) { store.showingPicker = .continueTrace(trace.id) }
        Button(store.copy.changeToNewTask) {
            store.selectTrace(trace.id)
            store.changeText = store.definition(for: trace)?.title ?? ""
            store.showingChangeDialog = true
        }
        Button(store.copy.returnToPoolWithTrace) { store.returnToPool(trace.id) }
        Button(store.copy.reschedule) { store.showingPicker = .reschedule(trace.id) }
        Button(store.copy.copyAsNewTask) { store.copyAsNewTask(trace.id) }
        Button(store.copy.abandonChain, role: .destructive) { store.abandon(trace.id) }
    }
}

struct TaskPoolPage: View {
    @EnvironmentObject private var store: SuntraceStore

    var tasks: [PoolTask] { store.engine.taskPool() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: store.copy.navPool, subtitle: store.copy.poolSubtitle)
            ScrollView {
                VStack(spacing: 0) {
                    PoolQuickAdd()
                        .padding(.bottom, 12)

                    LazyVStack(spacing: 8) {
                        ForEach(tasks, id: \.chain.id) { task in
                            PoolTaskRow(task: task)
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

struct PoolQuickAdd: View {
    @EnvironmentObject private var store: SuntraceStore

    var body: some View {
        TextField("新建任务到任务池，回车确认", text: $store.poolText)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
            .onSubmit { store.addPoolTask() }
    }
}

struct PoolTaskRow: View {
    @EnvironmentObject private var store: SuntraceStore
    let task: PoolTask

    var body: some View {
        let selected = store.selectedPoolChainID == task.chain.id
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                PlanningGlyph(systemName: "tray", color: Theme.navPool)
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.definition.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        PlanMetaPill(text: "待排期", color: Theme.navPool)
                        Text(task.definition.descriptionText ?? "尚未安排日期")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.text3)
                            .lineLimit(1)
                    }
                }
                Spacer()
                SmallActionButton(store.copy.scheduleToday, tone: .accent) { store.schedulePoolTask(task.chain.id, date: store.today) }
                SmallActionButton(store.copy.scheduleTomorrow) { store.schedulePoolTask(task.chain.id, date: SuntraceStore.offset(store.today, by: 1)) }
                SmallActionButton(store.copy.schedulePickDate) { store.showingPicker = .schedulePool(task.chain.id) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Theme.navPool.opacity(0.10) : Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Theme.navPool : Theme.line, lineWidth: selected ? 1.3 : 1))
        .onTapGesture { store.selectPool(task.chain.id) }
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(grouped, id: \.0) { date, items in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 8) {
                                Text("\(SuntraceStore.displayDate(date)) · \(SuntraceStore.weekday(date))")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.text1)
                                    .monospacedDigit()
                                Text(store.copy.itemCount(items.count))
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(Theme.navFuture)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Theme.navFuture.opacity(0.12)))
                                Spacer()
                                Button(store.copy.openDay) {
                                    store.selectedDate = date
                                    store.page = .day
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.accent)
                            }
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
            VStack(alignment: .leading, spacing: 4) {
                Text(item.definition.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    PlanMetaPill(text: "计划草稿", color: Theme.navFuture)
                    Text("当日优先级 \(item.trace.priority)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text3)
                }
            }
            Spacer()
            SmallActionButton(store.copy.reschedule) { store.showingPicker = .reschedule(item.trace.id) }
            SmallActionButton(store.copy.returnToPool) { store.returnToPool(item.trace.id) }
            PriorityStepper(
                canMoveUp: canMoveUp,
                canMoveDown: canMoveDown,
                moveUp: { store.movePriority(item.trace.id, delta: -1) },
                moveDown: { store.movePriority(item.trace.id, delta: 1) }
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .hoverSurface(
            active: selected,
            cornerRadius: 9,
            idleFill: Theme.panel,
            hoverFill: Theme.panel2,
            activeFill: Theme.navFuture.opacity(0.10),
            idleStroke: Theme.line,
            hoverStroke: Theme.line2,
            activeStroke: Theme.navFuture,
            activeLineWidth: 1.3
        )
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
            ScrollView {
                LazyVStack(spacing: 8) {
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

struct UnfinishedRow: View {
    @EnvironmentObject private var store: SuntraceStore
    let item: UnfinishedPoolItem

    var expanded: Bool { store.expandedUnfinishedChainIDs.contains(item.chain.id) }

    var body: some View {
        let selected = store.selectedUnfinishedChainID == item.chain.id
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                PlanningGlyph(systemName: "exclamationmark.circle", color: Theme.warn)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.definition.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        PlanMetaPill(text: "\(item.unfinishedTraces.count) 次未完成", color: Theme.warn)
                        Text("\(item.unfinishedTraces.last?.continuationSeq ?? 0) 次延续")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.text3)
                        Text("最近 \(SuntraceStore.displayDate(item.unfinishedTraces.last?.date ?? store.today))")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.text3)
                    }
                }
                Spacer()
                if item.activeTrace == nil, let source = item.unfinishedTraces.last {
                    SmallActionButton(store.copy.continueTo, tone: .accent) { store.showingPicker = .continueTrace(source.id) }
                    SmallActionButton(store.copy.abandonChain, tone: .warn) { store.abandon(source.id) }
                }
            }
            HStack(spacing: 8) {
                if let active = item.activeTrace {
                    Button("已延续到 \(SuntraceStore.displayDate(active.date))，当前待完成 跳转 →") {
                        store.selectedDate = active.date
                        store.page = .day
                        store.selectTrace(active.id)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
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
            .font(.system(size: 11))
            .foregroundStyle(Theme.text3)
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
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Theme.warnSoft.opacity(0.55) : Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Theme.warn : Theme.line, lineWidth: selected ? 1.3 : 1))
        .onTapGesture { store.selectUnfinished(item.chain.id) }
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
            Text(trace.status == .continued ? "已延续" : "未完成")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(trace.status == .continued ? Theme.text2 : Theme.warn)
            Text("第 \(trace.continuationSeq) 次延续")
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
            Spacer()
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(groupedDates, id: \.self) { date in
                        let dayItems = items.filter { $0.trace.date == date }
                        let daySubtasks = subtaskRecords.filter { $0.date == date }
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 8) {
                                Text(groupTitle(for: date))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.text1)
                                    .monospacedDigit()
                                Text(store.copy.recordCount(dayItems.count + daySubtasks.count))
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(Theme.ok)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Theme.okSoft))
                            }
                            .padding(.top, 2)

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
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.definition.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text("始于 \(SuntraceStore.displayDate(item.trajectory.startDate)) · 延续 \(item.trajectory.continuedDates.count) 天 · 完成于 \(SuntraceStore.displayDate(item.trajectory.completedDate))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                }
                Spacer()
                CompletionKindPill(text: "完成记录", color: Theme.ok)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(isSelected ? Theme.okSoft.opacity(0.78) : Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(isSelected ? Theme.ok : Theme.line, lineWidth: isSelected ? 1.3 : 1))
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
                }
                Spacer()
                CompletionKindPill(text: "子任务", color: Theme.accent)
                CompletionTimeText(time: SuntraceStore.displayTime(record.subtask.completedAt))
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
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(isSelected ? Theme.okSoft.opacity(0.78) : Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(isSelected ? Theme.ok : Theme.line, lineWidth: isSelected ? 1.3 : 1))
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
                    Rectangle().fill(Theme.line).frame(width: 1)
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

struct CalendarDetailPanel: View {
    @EnvironmentObject private var store: SuntraceStore
    var traces: [DayTrace] {
        store.engine.getDayTodo(date: store.selectedCalendarDate).traces.sorted { $0.priority < $1.priority }
    }

    var dayKind: (text: String, background: Color, foreground: Color) {
        if store.selectedCalendarDate == store.today {
            return ("今日", Theme.accent, .white)
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
                    Text(store.copy.itemCount(traces.count))
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
                Rectangle().fill(Theme.line).frame(height: 1)
            }

            ScrollView {
                LazyVStack(spacing: 6) {
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
                if trace.continuationSeq > 0 || trace.changedToTraceID != nil {
                    Text(metaText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                }
            }

            Spacer()
            StatusChip(status: trace.status, scale: .compact)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
    }

    var titleColor: Color {
        trace.status.uiStyle.titleColor
    }

    var metaText: String {
        var parts: [String] = []
        if trace.continuationSeq > 0 {
            parts.append("第 \(trace.continuationSeq) 次延续")
        }
        if trace.changedToTraceID != nil {
            parts.append("被变更为新任务")
        }
        return parts.joined(separator: " · ")
    }
}

struct SettingsPage: View {
    @EnvironmentObject private var store: SuntraceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: store.copy.navSettings, subtitle: store.copy.settingsSubtitle)
            ScrollView {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 14) {
                        SettingsPreferenceCard()
                        SettingsDataCard()
                        SettingSection(title: store.copy.syncTitle) {
                            SyncOptionsCard()
                        }
                    }
                    .frame(width: 440, alignment: .topLeading)

                    VStack(alignment: .leading, spacing: 14) {
                        SettingsProviderOverviewCard()
                        SettingsPrivacyCard()
                    }
                    .frame(width: 460, alignment: .topLeading)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }
}

struct SettingsPreferenceCard: View {
    @EnvironmentObject private var store: SuntraceStore

    var body: some View {
        SettingsCard(systemImage: "slider.horizontal.3", title: store.copy.preferencesTitle, subtitle: store.copy.preferencesSubtitle) {
            VStack(alignment: .leading, spacing: 14) {
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
            }
        }
    }
}

struct SettingsDataCard: View {
    @EnvironmentObject private var store: SuntraceStore

    var body: some View {
        SettingsCard(systemImage: "externaldrive", title: store.copy.dataPackageTitle, subtitle: store.copy.dataPackageSubtitle) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    SmallActionButton(store.copy.exportJSON, tone: .accent) { store.exportDataPackage() }
                    SmallActionButton(store.copy.importData) { store.importDataPackage() }
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    SettingsMetricPill(
                        title: store.copy.todayTraceMetric,
                        value: store.copy.itemCount(store.engine.getDayTodo(date: store.today).traces.count),
                        color: Theme.navDay
                    )
                    SettingsMetricPill(title: store.copy.taskPoolMetric, value: store.copy.itemCount(store.engine.taskPool().count), color: Theme.navPool)
                    SettingsMetricPill(title: store.copy.unfinishedMetric, value: store.copy.chainCount(store.engine.unfinishedPool().count), color: Theme.warn)
                    SettingsMetricPill(title: store.copy.completedMetric, value: store.copy.recordCount(store.engine.completedPool().count), color: Theme.ok)
                }
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
                    StatusPill(text: store.copy.planned, color: Theme.text3)
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
        SettingsCard(systemImage: "sparkles", title: store.copy.providerTitle, subtitle: store.copy.providerSubtitle) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    StatusPill(text: status.text, color: status.color)
                    Spacer()
                    StatusPill(
                        text: store.zhulongProviderDraft.hasStoredAPIKey ? store.copy.keychainStored : store.copy.keychainMissing,
                        color: store.zhulongProviderDraft.hasStoredAPIKey ? Theme.ok : Theme.text3
                    )
                }

                VStack(spacing: 0) {
                    SettingsInfoRow(label: store.copy.providerType, value: providerKindLabel(store.zhulongProviderDraft.kind))
                    SettingsInfoRow(label: store.copy.providerName, value: providerDisplayName)
                    SettingsInfoRow(label: "Base URL", value: store.zhulongProviderDraft.normalizedBaseURL?.absoluteString ?? store.copy.providerUnset)
                    SettingsInfoRow(label: store.copy.providerModel, value: store.zhulongProviderDraft.normalizedModel.isEmpty ? store.copy.providerUnset : store.zhulongProviderDraft.normalizedModel, last: true)
                }
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel2))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))

                Text(store.zhulongProviderDraft.statusMessage)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    SmallActionButton(store.copy.openZhulongConfig, tone: .accent) { store.page = .zhulong }
                    SmallActionButton(store.copy.save) { store.saveZhulongProvider() }
                    SmallActionButton(store.copy.testConnection) { store.testZhulongProvider() }
                    SmallActionButton(store.copy.clear, tone: .warn) { store.clearZhulongProvider() }
                }
            }
        }
    }

    var providerDisplayName: String {
        let trimmed = store.zhulongProviderDraft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? store.copy.customProvider : trimmed
    }

    func providerKindLabel(_ kind: AIProviderKind) -> String {
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
            PageHeader(title: "烛龙 AI", subtitle: "可选 sidecar：复盘分析、任务拆解、排期建议和 label 分类建议。")
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("衔烛龙，照苦昼短。")
                                .font(.system(size: 22, weight: .semibold))
                            Spacer()
                            StatusPill(
                                text: store.zhulongProviderDraft.isConfigured ? "Provider 已配置" : "Provider 未配置",
                                color: store.zhulongProviderDraft.isConfigured ? Theme.ok : Theme.warn
                            )
                        }
                        Text("AI 只生成建议草稿。任何创建、排期、变更、延续、废弃或 label 写入，都必须由用户确认后再走普通领域接口。")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.text2)
                            .lineSpacing(4)
                    }

                    ZhulongProviderCard()
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
                    ZhulongPoemCard()
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
            ZhulongCapability(task: .labelClassification, title: "Label 分类建议", scope: "任务标题、状态和轨迹摘要", evidence: "只生成候选 label，不自动写入")
        ]
    }
}

struct ZhulongProviderCard: View {
    @EnvironmentObject private var store: SuntraceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Provider 配置", systemImage: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Spacer()
                StatusPill(
                    text: store.zhulongProviderDraft.enabled ? "已启用" : "未启用",
                    color: store.zhulongProviderDraft.enabled ? Theme.ok : Theme.warn
                )
            }

            VStack(alignment: .leading, spacing: 10) {
                Toggle("启用 Provider", isOn: $store.zhulongProviderDraft.enabled)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12.5))

                ZhulongProviderKindPicker(selection: $store.zhulongProviderDraft.kind)
                ZhulongProviderTextField(label: "名称", text: $store.zhulongProviderDraft.displayName, placeholder: "自定义 Provider")
                ZhulongProviderTextField(label: "Base URL", text: $store.zhulongProviderDraft.baseURL, placeholder: "https://api.example.com/v1")
                ZhulongProviderTextField(label: "模型", text: $store.zhulongProviderDraft.model, placeholder: "gpt-4.1-mini / llama3.1")
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
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))

            HStack(spacing: 8) {
                SmallActionButton("保存 Provider", tone: .accent) { store.saveZhulongProvider() }
                SmallActionButton("测试连接") { store.testZhulongProvider() }
                SmallActionButton("清空") { store.clearZhulongProvider() }
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
            Text("发送前数据边界")
                .font(.system(size: 13, weight: .semibold))
            Text("每次远程请求前必须展示授权范围；不得发送数据库文件、内部 ID、Keychain 值或同步端点配置。")
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
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(Theme.accent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(capability.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(capability.scope)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text3)
            }
            Spacer()
            Text(capability.evidence)
                .font(.system(size: 11))
                .foregroundStyle(Theme.text2)
                .lineLimit(1)
            StatusPill(text: "建议草稿", color: Theme.accent)
            SmallActionButton("生成草稿") { store.generateZhulongDraft(task: capability.task) }
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
                Text("AI 建议草稿")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                StatusPill(text: "\(store.zhulongDrafts.count) 条", color: Theme.accent)
            }

            if store.zhulongDrafts.isEmpty {
                Text("从上方入口生成草稿后，在这里查看证据和待确认操作。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
            } else {
                ForEach(store.zhulongDrafts, id: \.id) { draft in
                    ZhulongDraftCard(draft: draft)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
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
        return "Label 建议"
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
        return "写入 Label：\(label)"
    case let .updateDailyReview(date, _, _, _):
        return "更新 \(date) 的每日复盘"
    }
}

struct ZhulongDraftCard: View {
    @EnvironmentObject private var store: SuntraceStore
    let draft: AISuggestionDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                StatusPill(text: zhulongKindLabel(draft.kind), color: Theme.accent)
                if let confidence = draft.confidence {
                    Text("置信度 \(Int((confidence * 100).rounded()))%")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text3)
                }
                Spacer()
            }

            Text(draft.summary)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text2)
                .lineSpacing(3)

            if draft.localReport.facts.isEmpty == false {
                VStack(alignment: .leading, spacing: 5) {
                    Text("证据")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                    ForEach(Array(draft.localReport.facts.prefix(3).enumerated()), id: \.offset) { _, fact in
                        Text("• \(fact)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.text3)
                    }
                }
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("待确认操作")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.text3)

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
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel2))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
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

struct ZhulongPoemCard: View {
    private let lines = [
        "飞光，飞光，劝尔一杯酒。",
        "吾不识青天高、黄地厚，",
        "唯见月寒日暖，来煎人寿。",
        "食熊则肥，食蛙则瘦。",
        "神君何在？太一安有？",
        "天东有若木，下置衔烛龙。",
        "吾将斩龙足、嚼龙肉，",
        "使之朝不得回、夜不得伏。",
        "自然老者不死、少者不哭。",
        "何为服黄金、吞白玉？",
        "谁似任公子，云中骑碧驴？"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("《苦昼短》意象")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("可展开阅读")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
            }
            Text(lines.joined(separator: "\n"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2)
                .lineSpacing(5)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
    }
}

struct ZhulongRail: View {
    private let lines = [
        "飞光，飞光，劝尔一杯酒。",
        "吾不识青天高、黄地厚，",
        "唯见月寒日暖，来煎人寿。",
        "天东有若木，下置衔烛龙。",
        "谁似任公子，云中骑碧驴？"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("烛龙边界")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .tracking(0.8)
            Text("照见轨迹，不替你抹改事实。")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text1)
            Text(lines.joined(separator: "\n"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2)
                .lineSpacing(5)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))

            DetailSection("权限模式") {
                VStack(alignment: .leading, spacing: 7) {
                    StatusPill(text: "建议模式", color: Theme.accent)
                    Text("当前只生成建议草稿；逐条确认和全权管家会在限定范围、次数和有效期内单独授权。")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text2)
                        .lineSpacing(3)
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

struct DetailRail: View {
    @EnvironmentObject private var store: SuntraceStore

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

struct CompletedRecordDetail: View {
    @EnvironmentObject private var store: SuntraceStore
    let item: CompletedPoolItem

    var subtasks: [Subtask] { store.subtasks(for: item.trace.id) }
    var completedAt: String { SuntraceStore.displayTime(item.trace.completedAt) ?? "未记录" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DetailHeader("完成记录", onClose: { store.clearSelection() }, trailing: {
                IconMenuButton(menuContent: {
                    Button(store.copy.openDay) { openDay() }
                    Button(store.copy.copyAsNewTask) { store.copyAsNewTask(item.trace.id) }
                })
            })

            Text(item.definition.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text1)
                .lineLimit(3)

            HStack(spacing: 8) {
                StatusChip(status: .completed)
                Text("\(SuntraceStore.displayDate(item.trace.date)) \(SuntraceStore.weekday(item.trace.date))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
            }

            CompletionSummaryCard(items: [
                CompletionSummaryItem(label: "开始", value: SuntraceStore.displayDate(item.trajectory.startDate), color: Theme.text2),
                CompletionSummaryItem(label: "延续", value: "\(item.trajectory.continuedDates.count) 天", color: Theme.text2),
                CompletionSummaryItem(label: "完成", value: SuntraceStore.displayDate(item.trajectory.completedDate), color: Theme.ok),
                CompletionSummaryItem(label: "时间", value: completedAt, color: Theme.text2)
            ])

            Notice(text: "已完成记录来自历史轨迹，只能回看或复制为新任务。", tone: .locked)

            DetailSection("任务轨迹") {
                CompletedTrajectoryPanel(nodes: item.trajectory.traces.map(CompletedTrajectoryNode.init(trace:)))
            }

            DetailSection("描述") {
                EditableDetailText(
                    text: .constant(item.trace.descriptionText ?? item.definition.descriptionText ?? ""),
                    placeholder: "",
                    editable: false,
                    warm: false,
                    fallback: "未填写描述"
                )
            }

            DetailSection("附言") {
                EditableDetailText(
                    text: .constant(item.trace.note ?? item.definition.note ?? ""),
                    placeholder: "",
                    editable: false,
                    warm: true,
                    fallback: "无附言"
                )
            }

            DetailSection("子任务快照") {
                VStack(spacing: 7) {
                    if subtasks.isEmpty {
                        Text("暂无子任务")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text3)
                    } else {
                        ForEach(subtasks, id: \.id) { subtask in
                            CompletedSubtaskMiniRow(subtask: subtask)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                SmallActionButton(store.copy.openDay, tone: .accent) { openDay() }
                SmallActionButton(store.copy.copyAsNewTask) { store.copyAsNewTask(item.trace.id) }
            }
        }
    }

    private func openDay() {
        store.selectedDate = item.trace.date
        store.page = .day
        store.selectTrace(item.trace.id)
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

            Text(record.subtask.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text1)
                .lineLimit(3)

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

struct CompletedSubtaskMiniRow: View {
    let subtask: Subtask

    var body: some View {
        HStack(spacing: 8) {
            StatusGlyph(status: subtask.status == .completed ? .completed : .pending)
            VStack(alignment: .leading, spacing: 1) {
                Text(subtask.title)
                    .font(.system(size: 12))
                    .foregroundStyle(subtask.status == .completed ? Theme.text3 : Theme.text1)
                    .strikethrough(subtask.status == .completed)
                    .lineLimit(1)
                Text(subtask.difficulty.label)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.text3)
            }
            Spacer()
            if subtask.status == .completed {
                CompletionKindPill(text: "已完成", color: Theme.ok)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel2))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
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
            HStack(alignment: .top, spacing: 8) {
                Text(definition.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                    .lineLimit(3)
            }
            HStack {
                StatusChip(status: trace.status)
                Text(trace.date.description)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
            }
            MetadataCard(trace: trace)
            if trace.date < store.today {
                Notice(text: "历史只读：任务事实不可改写。", tone: .locked)
            }
            DetailSection("完成进度") {
                DetailProgressControl(
                    traceID: trace.id,
                    progress: progress,
                    editable: canEditManualProgress
                )
            }
            DetailSection("描述") {
                EditableDetailText(
                    text: Binding(
                        get: { trace.descriptionText ?? definition.descriptionText ?? "" },
                        set: { store.updateTraceText(traceID: trace.id, descriptionText: $0) }
                    ),
                    placeholder: "补充这个任务的背景、目标或范围…",
                    editable: canEditText,
                    warm: false,
                    fallback: "未填写描述"
                )
            }
            DetailSection("附言") {
                EditableDetailText(
                    text: Binding(
                        get: { trace.note ?? definition.note ?? "" },
                        set: { store.updateTraceText(traceID: trace.id, note: $0) }
                    ),
                    placeholder: "临时想法、提醒或补充说明…",
                    editable: canEditText,
                    warm: true,
                    fallback: "无附言"
                )
            }
            DetailSection("子任务") {
                VStack(spacing: 6) {
                    ForEach(subtasks, id: \.id) { subtask in
                        SubtaskRow(subtask: subtask)
                    }
                    if subtasks.isEmpty {
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
            DetailSection("任务轨迹时间线") {
                Timeline(trace: trace)
            }
        }
    }
}

struct DetailProgressControl: View {
    @EnvironmentObject private var store: SuntraceStore
    let traceID: DayTraceID
    let progress: TraceProgress
    let editable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(progress.mode == .weightedSubtasks ? "按子任务自动计算" : "手动完成进度")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.text3)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Theme.chip))
                Spacer()
                Text("\(progress.percent)%")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(progress.percent == 100 ? Theme.ok : Theme.accent)
                    .monospacedDigit()
            }

            if editable {
                Slider(
                    value: Binding(
                        get: { Double(progress.percent) },
                        set: { store.setManualProgress(traceID: traceID, percent: $0) }
                    ),
                    in: Double(progress.floorPercent)...100,
                    step: 5
                )
                .tint(Theme.accent)
                if progress.floorPercent > 0 {
                    Text("下限 \(progress.floorPercent)% · 延续后的进度不能回退")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.text3)
                }
            } else {
                ProgressView(value: Double(progress.percent), total: 100)
                    .progressViewStyle(.linear)
                    .tint(progress.percent == 100 ? Theme.ok : Theme.accent)
            }
        }
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
                .background(RoundedRectangle(cornerRadius: 7).fill(warm ? Theme.warnSoft.opacity(0.45) : Theme.panel2))
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
                .background(RoundedRectangle(cornerRadius: 7).fill(warm ? Theme.warnSoft.opacity(0.45) : Theme.panel2))
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

struct MetadataCard: View {
    let trace: DayTrace

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("当日优先级 \(trace.priority)")
            Text("延续次数 \(trace.continuationSeq)")
            if trace.changedToTraceID != nil {
                Text("被变更为新任务")
            }
            if trace.status == .returnedToPool {
                Text("当天已回池")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.text2)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel2))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
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
            ForEach(chainTraces, id: \.id) { item in
                HStack(alignment: .top, spacing: 8) {
                    VStack(spacing: 0) {
                        StatusGlyph(status: item.status)
                        Rectangle().fill(Theme.line2).frame(width: 1, height: 22)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(item.status.uiStyle.label)
                                .font(.system(size: 11, weight: .semibold))
                            if item.id == trace.id {
                                StatusPill(text: "当前", color: Theme.accent)
                            }
                        }
                        Text("\(SuntraceStore.displayDate(item.date)) \(SuntraceStore.weekday(item.date))")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.text3)
                    }
                    Spacer()
                }
            }
        }
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
            HStack {
                StatusPill(text: "未排期", color: Theme.accent)
                Text("任务链仍在任务池")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
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
            DetailSection("描述") {
                EditableDetailText(
                    text: .constant(task.definition.descriptionText ?? ""),
                    placeholder: "",
                    editable: false,
                    warm: false,
                    fallback: "未填写描述"
                )
            }
            DetailSection("附言") {
                EditableDetailText(
                    text: .constant(task.definition.note ?? ""),
                    placeholder: "",
                    editable: false,
                    warm: true,
                    fallback: "无附言"
                )
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
        }
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

            Text(definition.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text1)
                .lineLimit(3)

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

            DetailSection("描述") {
                EditableDetailText(
                    text: Binding(
                        get: { trace.descriptionText ?? definition.descriptionText ?? "" },
                        set: { store.updateTraceText(traceID: trace.id, descriptionText: $0) }
                    ),
                    placeholder: "补充这个计划的背景、目标或范围…",
                    editable: true,
                    warm: false,
                    fallback: "未填写描述"
                )
            }

            DetailSection("附言") {
                EditableDetailText(
                    text: Binding(
                        get: { trace.note ?? definition.note ?? "" },
                        set: { store.updateTraceText(traceID: trace.id, note: $0) }
                    ),
                    placeholder: "未来开始前想提醒自己的事项…",
                    editable: true,
                    warm: true,
                    fallback: "无附言"
                )
            }

            DetailSection("计划操作") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        SmallActionButton(store.copy.openDay, tone: .accent) { openDay() }
                        SmallActionButton(store.copy.reschedule) { store.showingPicker = .reschedule(trace.id) }
                    }
                    SmallActionButton(store.copy.returnToPool) { store.returnToPool(trace.id) }
                }
            }
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

    var latestUnfinished: DayTrace? { item.unfinishedTraces.last }
    var latestContinuation: Int { latestUnfinished?.continuationSeq ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DetailHeader("未完成明细", onClose: { store.clearSelection() })
            Text(item.definition.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text1)
            HStack(spacing: 8) {
                PlanMetaPill(text: "\(item.unfinishedTraces.count) 次未完成", color: Theme.warn)
                PlanMetaPill(text: "\(latestContinuation) 次延续", color: Theme.text2)
            }
            UnfinishedSummaryCard(item: item)
            DetailSection("处理") {
                VStack(alignment: .leading, spacing: 8) {
                    if let active = item.activeTrace {
                        Notice(text: "已延续到 \(SuntraceStore.displayDate(active.date))，当前仍待完成。", tone: .future)
                        SmallActionButton(store.copy.openCurrentPending, tone: .accent) {
                            store.selectedDate = active.date
                            store.page = .day
                            store.selectTrace(active.id)
                        }
                    } else if let source = latestUnfinished {
                        HStack(spacing: 8) {
                            SmallActionButton(store.copy.continueTo, tone: .accent) { store.showingPicker = .continueTrace(source.id) }
                            SmallActionButton(store.copy.abandonChain, tone: .warn) { store.abandon(source.id) }
                        }
                    } else {
                        Text("没有需要处理的未完成轨迹。")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text3)
                    }
                }
            }
            DetailSection("描述") {
                EditableDetailText(
                    text: .constant(item.definition.descriptionText ?? ""),
                    placeholder: "",
                    editable: false,
                    warm: false,
                    fallback: "未填写描述"
                )
            }
            DetailSection("附言") {
                EditableDetailText(
                    text: .constant(item.definition.note ?? ""),
                    placeholder: "",
                    editable: false,
                    warm: true,
                    fallback: "无附言"
                )
            }
            DetailSection("任务链轨迹") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(item.unfinishedTraces, id: \.id) { trace in
                        UnfinishedTraceLine(trace: trace, current: false)
                    }
                    if let active = item.activeTrace {
                        UnfinishedTraceLine(trace: active, current: true)
                    }
                }
            }
        }
    }
}

struct UnfinishedSummaryCard: View {
    let item: UnfinishedPoolItem

    var latestUnfinished: DayTrace? { item.unfinishedTraces.last }

    var body: some View {
        VStack(spacing: 7) {
            if let latestUnfinished {
                summaryRow("最近", "\(SuntraceStore.displayDate(latestUnfinished.date)) \(SuntraceStore.weekday(latestUnfinished.date))", Theme.warn)
                summaryRow("优先级", "\(latestUnfinished.priority)", Theme.text2)
                summaryRow("延续", "第 \(latestUnfinished.continuationSeq) 次", Theme.text2)
            }
            if let active = item.activeTrace {
                summaryRow("当前", "\(SuntraceStore.displayDate(active.date)) \(SuntraceStore.weekday(active.date)) 待完成", Theme.accent)
            } else {
                summaryRow("当前", "暂无活跃日轨迹", Theme.text2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.warnSoft.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
    }

    private func summaryRow(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .frame(width: 38, alignment: .leading)
            Text(value)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(color)
            Spacer(minLength: 0)
        }
    }
}

struct UnfinishedTraceLine: View {
    let trace: DayTrace
    let current: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 0) {
                StatusGlyph(status: trace.status)
                Rectangle().fill(Theme.line2).frame(width: 1, height: 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("\(SuntraceStore.displayDate(trace.date)) \(SuntraceStore.weekday(trace.date))")
                        .font(.system(size: 11, weight: .semibold))
                    if current {
                        StatusPill(text: "当前", color: Theme.accent)
                    }
                }
                Text("当日优先级 \(trace.priority) · 第 \(trace.continuationSeq) 次延续")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
            }
            Spacer()
            StatusChip(status: trace.status)
        }
        .padding(.vertical, 3)
    }
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
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(store.dateChoices(allowPast: true, futureOnly: futureOnly)) { choice in
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

    var futureOnly: Bool {
        if case .reschedule = state.purpose { return true }
        return false
    }
}

struct FromPoolSheet: View {
    @EnvironmentObject private var store: SuntraceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("从任务池排期到这一天")
                .font(.system(size: 14, weight: .semibold))
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
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.chip))
        .frame(width: 260)
    }

    func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.panel : .clear))
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
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Theme.text2)
            .padding(.horizontal, title.count == 1 ? 8 : 10)
            .frame(height: 26)
            .fixedSize(horizontal: true, vertical: false)
            .hoverSurface(
                cornerRadius: 7,
                idleFill: Theme.panel,
                hoverFill: Theme.panel2,
                idleStroke: Theme.line,
                hoverStroke: Theme.line2
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
                idleFill: Theme.panel,
                hoverFill: Theme.panel2,
                idleStroke: Theme.line,
                hoverStroke: Theme.line2
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
}

struct PriorityStepper: View {
    let canMoveUp: Bool
    let canMoveDown: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void

    var body: some View {
        VStack(spacing: 2) {
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
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
        .help("调整当日优先级")
    }

    func stepButton(systemName: String, enabled: Bool, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(enabled ? Theme.text2 : Theme.line2)
                .frame(width: 18, height: 12)
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
