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
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 880),
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
            let traces = engine.getDayTodo(date: selectedDate).traces
            let trace = selectionName == "manual"
                ? traces.first { subtasks(for: $0.id).isEmpty && $0.status == .pending }
                : traces.first
            if let trace {
                selectTrace(trace.id)
            }
        case .future:
            if let trace = engine.futurePlans(today: today).first?.trace {
                selectTrace(trace.id)
            }
        case .pool:
            if let task = engine.taskPool().first {
                selectPool(task.chain.id)
            }
        case .unfinished:
            if let item = engine.unfinishedPool().first {
                selectUnfinished(item.chain.id)
            }
        case .completed:
            if let item = engine.completedPool().first {
                selectCompleted(item.trace.id)
            }
        case .calendar, .zhulong, .settings:
            break
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
        engine.updateTheme(theme)
        persist()
    }

    func setLanguage(_ language: AppLanguage) {
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
        do {
            _ = try ZhulongProviderSettingsStore.makeConfig(from: zhulongProviderDraft)
            guard zhulongProviderDraft.enabled else {
                showToast("Provider 已关闭，未发起连接测试")
                return
            }
            if zhulongProviderDraft.hasStoredAPIKey {
                showToast("Provider 本机配置完整，后续请求会使用 Keychain 凭证")
            } else {
                showToast("Provider 缺少 API Key；本地模型可忽略，远程 provider 需要补齐")
            }
        } catch {
            showToast("Provider 配置无效：\(error.localizedDescription)")
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
        "\(date.month) 月 \(date.day) 日"
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
                seed()
                persist()
            } else {
                engine = loaded
            }
        } catch {
            seed()
            NSLog("Suntrace persistence load failed: %@", String(describing: error))
            toast = "无法读取本地数据库，已使用初始样例数据：\(error.localizedDescription)"
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
        let day1 = LocalDate("2026-07-03")
        let day2 = LocalDate("2026-07-04")
        let day3 = today
        let day4 = LocalDate("2026-07-06")
        let day7 = LocalDate("2026-07-09")

        do {
            let research = try engine.createPoolTask(
                title: "整理 Day Todo 信息架构",
                descriptionText: "把每日任务轨迹、任务池、未完成池与复盘串成一个主窗口。",
                note: "优先保证轨迹不可删除和跨日延续语义。",
                now: now
            )
            let researchDay1 = try engine.scheduleFromPool(chainID: research, date: day1, today: day3, now: now)
            _ = try engine.addSubtask(traceID: researchDay1, title: "拆导航结构", difficulty: .simple, now: now)
            let modelSubtask = try engine.addSubtask(traceID: researchDay1, title: "补领域模型字段", difficulty: .hard, now: now)
            try engine.completeSubtask(modelSubtask, today: day1, now: now)
            engine.settleDays(upTo: day2, now: now)
            let researchDay2 = try engine.continueTrace(traceID: researchDay1, targetDate: day2, today: day2, now: now)
            engine.settleDays(upTo: day3, now: now)
            let researchToday = try engine.continueTrace(traceID: researchDay2, targetDate: day3, today: day3, now: now)
            _ = try engine.addSubtask(traceID: researchToday, title: "SwiftUI 还原原型", difficulty: .hard, now: now)

            let review = try engine.createPoolTask(
                title: "补齐每日复盘写作",
                descriptionText: "完成今天的推进总结、未完成原因和明日注意事项。",
                note: "复盘可补写，但任务事实不能被历史改写。",
                now: now
            )
            let reviewTrace = try engine.scheduleFromPool(chainID: review, date: day3, today: day3, now: now)
            try engine.setManualProgress(traceID: reviewTrace, percent: 35, today: day3)

            let done = try engine.createPoolTask(title: "归档 Claude Mac UI 原型", descriptionText: "把原型文件和实现契约落到 docs。", now: now)
            let doneTrace = try engine.scheduleFromPool(chainID: done, date: day3, today: day3, now: now)
            try engine.markCompleted(traceID: doneTrace, today: day3, now: now)

            let changed = try engine.createPoolTask(title: "写普通 Todo 页面", descriptionText: "旧方向，已被晷迹轨迹模型替代。", now: now)
            let changedTrace = try engine.scheduleFromPool(chainID: changed, date: day3, today: day3, now: now)
            _ = try engine.changeTrace(traceID: changedTrace, newTitle: "写晷迹 Day Todo 页面", today: day3, now: now)

            let poolA = try engine.createPoolTask(title: "设计数据包导出格式", descriptionText: "平台无关状态快照，后续用于手动导出/导入。", now: now)
            _ = poolA
            let poolB = try engine.createPoolTask(title: "评估 GRDB 持久化边界", descriptionText: "SQLite schema 已有，下一步接存储仓库。", note: "不要提前引入账号系统。", now: now)
            _ = poolB

            let futureA = try engine.createPoolTask(title: "接入真实 SQLite Repository", descriptionText: "把内存 engine 状态落到本地数据库。", now: now)
            _ = try engine.scheduleFromPool(chainID: futureA, date: day4, today: day3, now: now)
            let futureB = try engine.createPoolTask(title: "完善烛龙 AI provider 配置", descriptionText: "OpenAI-compatible endpoint，自定义模型与健康检查。", now: now)
            let futureTrace = try engine.scheduleFromPool(chainID: futureB, date: day7, today: day3, now: now)
            _ = try engine.addSubtask(traceID: futureTrace, title: "Provider Registry UI", difficulty: .medium, now: now)

            let calendarSamples: [(String, String, Bool)] = [
                ("2026-07-01", "整理任务池命名", true),
                ("2026-07-01", "补充已完成池轨迹文案", false),
                ("2026-07-02", "复核未完成池明细", false),
                ("2026-07-06", "设计 SQLite Repository", false),
                ("2026-07-06", "补日历热度规则", false),
                ("2026-07-07", "完善设置同步占位", false),
                ("2026-07-08", "补烛龙 AI Provider UI", false),
                ("2026-07-09", "验证整月日历截图", false),
                ("2026-07-10", "复盘导出数据包格式", false),
                ("2026-07-11", "整理人工测试清单", false)
            ]
            for sample in calendarSamples {
                let chainID = try engine.createPoolTask(title: sample.1, descriptionText: "日历总览样例任务。", now: now)
                let traceID = try engine.scheduleFromPool(chainID: chainID, date: LocalDate(sample.0), today: day3, now: now)
                if sample.2, LocalDate(sample.0) == day3 {
                    try engine.markCompleted(traceID: traceID, today: day3, now: now)
                }
            }
            engine.settleDays(upTo: day3, now: now)

            engine.updateDailyReview(
                date: day3,
                summary: "今天完成了 Xcode 工具链、SwiftPM 测试和 Mac UI 契约复核，开始进入 SwiftUI 实现。",
                unfinishedReason: "真实 App target 仍在搭建，持久化接入尚未完成。",
                tomorrowNote: "优先验证主窗口交互，再补 SQLite repository。"
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

enum Theme {
    static let desk = Color(red: 0.898, green: 0.902, blue: 0.914)
    static let background = Color(red: 0.962, green: 0.962, blue: 0.968)
    static let panel = Color.white
    static let panel2 = Color(red: 0.982, green: 0.982, blue: 0.987)
    static let line = Color(red: 0.91, green: 0.91, blue: 0.925)
    static let line2 = Color(red: 0.82, green: 0.82, blue: 0.85)
    static let text1 = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let text2 = Color(red: 0.42, green: 0.42, blue: 0.46)
    static let text3 = Color(red: 0.63, green: 0.63, blue: 0.67)
    static let chip = Color(red: 0.946, green: 0.946, blue: 0.956)
    static let accent = Color(red: 0.16, green: 0.38, blue: 0.78)
    static let accentSoft = Color(red: 0.93, green: 0.955, blue: 1.0)
    static let ok = Color(red: 0.08, green: 0.55, blue: 0.38)
    static let okSoft = Color(red: 0.91, green: 0.98, blue: 0.95)
    static let warn = Color(red: 0.82, green: 0.36, blue: 0.12)
    static let warnSoft = Color(red: 1.0, green: 0.945, blue: 0.9)
}

struct WindowChrome: View {
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(red: 1, green: 0.36, blue: 0.32)).frame(width: 12, height: 12)
            Circle().fill(Color(red: 1, green: 0.76, blue: 0.25)).frame(width: 12, height: 12)
            Circle().fill(Color(red: 0.23, green: 0.78, blue: 0.34)).frame(width: 12, height: 12)
            Spacer()
            Text("晷迹 · suntrace")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.text2)
            Spacer()
            Color.clear.frame(width: 56, height: 1)
        }
        .frame(height: 42)
        .padding(.horizontal, 14)
        .background(Theme.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject private var store: SuntraceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ClockLogo()
                VStack(alignment: .leading, spacing: 0) {
                    Text("晷迹")
                        .font(.system(size: 14, weight: .semibold))
                    Text("suntrace")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text3)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)

            NavGroupTitle("计划")
            NavItem(page: .day, label: "Day Todo", icon: "checklist", count: store.engine.getDayTodo(date: store.today).traces.count)
            NavItem(page: .pool, label: "任务池", icon: "tray", count: store.engine.taskPool().count)
            NavItem(page: .future, label: "未来计划", icon: "calendar.badge.clock", count: store.engine.futurePlans(today: store.today).count)

            NavGroupTitle("轨迹")
                .padding(.top, 12)
            NavItem(page: .unfinished, label: "未完成", icon: "exclamationmark.circle", count: store.engine.unfinishedPool().count)
            NavItem(page: .completed, label: "已完成", icon: "checkmark.seal", count: store.engine.completedPool().count + store.engine.completedSubtaskRecords().count)
            NavItem(page: .calendar, label: "日历", icon: "calendar", count: 0)
            NavItem(page: .zhulong, label: "烛龙 AI", icon: "sparkles", count: 0)

            Spacer()
            NavItem(page: .settings, label: "设置", icon: "gearshape", count: 0)
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
            .font(.system(size: 10.5, weight: .semibold))
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
    let icon: String
    let count: Int

    var active: Bool { store.page == page }

    var body: some View {
        Button {
            store.selectPage(page)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .frame(width: 17)
                Text(label)
                    .font(.system(size: 12.5, weight: active ? .semibold : .medium))
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.text2)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 18, minHeight: 16)
                        .background(Capsule().fill(Theme.chip))
                }
            }
            .foregroundStyle(active ? Theme.accent : Theme.text2)
            .frame(height: 29)
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .background(active ? Theme.accentSoft : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 99)
                    .fill(active ? Theme.accent : .clear)
                    .frame(width: 2.5, height: 13)
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
                Notice(text: "历史日已锁定：任务事实不可改写，可补写复盘。未完成任务可延续或废弃。", tone: .locked)
                    .padding(.horizontal, 24)
            } else if store.isFuture {
                Notice(text: "未来日：可排期与调整顺序，不能提前完成或生成复盘。", tone: .future)
                    .padding(.horizontal, 24)
            }

            if store.isHistory == false {
                HStack(spacing: 8) {
                    TextField(store.isFuture ? "为这一天排期任务，回车确认" : "添加今日任务，回车确认", text: $store.quickText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                        .onSubmit { store.addQuickTask() }
                    HeaderButton("从任务池排期…") { store.showingFromPoolPicker = true }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(traces, id: \.id) { trace in
                        TaskRow(trace: trace)
                    }

                    if traces.isEmpty {
                        EmptyState(kind: .dayTodo, text: "这一天没有留下任务。")
                            .padding(.top, 40)
                    }
                }
                .padding(.horizontal, 24)
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
            Text(SuntraceStore.displayDate(store.selectedDate))
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(Theme.text1)
                .monospacedDigit()
                .lineLimit(1)
            Text(SuntraceStore.weekday(store.selectedDate))
                .font(.system(size: 12))
                .foregroundStyle(Theme.text3)
                .lineLimit(1)
            StatusPill(text: dayBadge, color: badgeColor)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                HeaderButton("‹") { store.selectedDate = SuntraceStore.offset(store.selectedDate, by: -1) }
                HeaderButton("今天") { store.selectedDate = store.today }
                HeaderButton("›") { store.selectedDate = SuntraceStore.offset(store.selectedDate, by: 1) }
                HeaderButton("选日期") { store.showingPicker = .gotoDay }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
    }
}

struct DateStrip: View {
    @EnvironmentObject private var store: SuntraceStore

    var dates: [LocalDate] {
        (-7...6).map { SuntraceStore.offset(store.today, by: $0) }
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
            HStack(alignment: .top, spacing: 10) {
                Button {
                    store.toggleComplete(trace.id)
                } label: {
                    StatusGlyph(status: trace.status)
                }
                .buttonStyle(.plain)
                .disabled(trace.status != .pending && trace.status != .completed)

                VStack(alignment: .leading, spacing: 4) {
                    Text(definition?.title ?? "未命名任务")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(trace.status == .completed ? Theme.text2 : Theme.text1)
                        .strikethrough(trace.status == .abandoned)

                    HStack(spacing: 6) {
                        ProgressView(value: Double(progress.percent), total: 100)
                            .progressViewStyle(.linear)
                            .tint(progress.percent == 100 ? Theme.ok : Theme.accent)
                            .frame(width: 150)
                        Text("\(progress.percent)%")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }

                    Text(metaText)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text3)
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

                VStack(spacing: 1) {
                    Button("▲") { store.movePriority(trace.id, delta: -1) }
                    Button("▼") { store.movePriority(trace.id, delta: 1) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 9))
                .foregroundStyle(Theme.text3)
            }
            .padding(11)

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
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.accentSoft : Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Theme.accent : Theme.line))
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
        return parts.isEmpty ? "当日优先级 \(trace.priority)" : parts.joined(separator: " · ")
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
            Button("标记完成") { store.toggleComplete(trace.id) }
        }
        if trace.status == .completed {
            Button("撤销完成") { store.toggleComplete(trace.id) }
        }
        Button("延续到…") { store.showingPicker = .continueTrace(trace.id) }
        Button("变更为新任务…") {
            store.selectTrace(trace.id)
            store.changeText = store.definition(for: trace)?.title ?? ""
            store.showingChangeDialog = true
        }
        Button("回到任务池（留下轨迹）") { store.returnToPool(trace.id) }
        Button("改期…") { store.showingPicker = .reschedule(trace.id) }
        Button("复制为新任务") { store.copyAsNewTask(trace.id) }
        Button("废弃任务链", role: .destructive) { store.abandon(trace.id) }
    }
}

struct TaskPoolPage: View {
    @EnvironmentObject private var store: SuntraceStore

    var tasks: [PoolTask] { store.engine.taskPool() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "任务池", subtitle: "尚未安排日期的任务。排期后会出现在对应的 Day Todo。")
            TextField("新建任务到任务池，回车确认", text: $store.poolText)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .onSubmit { store.addPoolTask() }

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(tasks, id: \.chain.id) { task in
                        PoolTaskRow(task: task)
                    }
                    if tasks.isEmpty {
                        EmptyState(kind: .taskPool, text: "任务池是空的。")
                            .padding(.top, 40)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

struct PoolTaskRow: View {
    @EnvironmentObject private var store: SuntraceStore
    let task: PoolTask

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .stroke(Theme.line2, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.definition.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(task.definition.descriptionText ?? "尚未安排日期")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
            }
            Spacer()
            SmallActionButton("排期到今天", tone: .accent) { store.schedulePoolTask(task.chain.id, date: store.today) }
            SmallActionButton("排期到明天") { store.schedulePoolTask(task.chain.id, date: SuntraceStore.offset(store.today, by: 1)) }
            SmallActionButton("选日期…") { store.showingPicker = .schedulePool(task.chain.id) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8).fill(store.selectedPoolChainID == task.chain.id ? Theme.accentSoft : Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(store.selectedPoolChainID == task.chain.id ? Theme.accent : Theme.line))
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
            PageHeader(title: "未来计划", subtitle: "已排到未来日期的计划草稿，可改期或回到任务池。")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(grouped, id: \.0) { date, items in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text("\(SuntraceStore.displayDate(date)) · \(SuntraceStore.weekday(date))")
                                    .font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Button("查看当天 →") {
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
                        EmptyState(kind: .futurePlans, text: "还没有未来计划。")
                            .padding(.top, 40)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }
}

struct FuturePlanRow: View {
    @EnvironmentObject private var store: SuntraceStore
    let item: FuturePlanItem

    var body: some View {
        HStack(spacing: 10) {
            StatusGlyph(status: item.trace.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.definition.title)
                    .font(.system(size: 13, weight: .semibold))
                Text("计划草稿 · 当日优先级 \(item.trace.priority)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
            }
            Spacer()
            StatusChip(status: item.trace.status)
            VStack(spacing: 1) {
                Button("▲") { store.movePriority(item.trace.id, delta: -1) }
                Button("▼") { store.movePriority(item.trace.id, delta: 1) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 9))
            .foregroundStyle(Theme.text3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8).fill(store.selectedTraceID == item.trace.id ? Theme.accentSoft : Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(store.selectedTraceID == item.trace.id ? Theme.accent : Theme.line))
        .onTapGesture { store.selectTrace(item.trace.id) }
        .contextMenu {
            Button("查看详情") { store.selectTrace(item.trace.id) }
            Button("改期…") { store.showingPicker = .reschedule(item.trace.id) }
            Button("回到任务池") { store.returnToPool(item.trace.id) }
        }
    }
}

struct UnfinishedPoolPage: View {
    @EnvironmentObject private var store: SuntraceStore
    var items: [UnfinishedPoolItem] { store.engine.unfinishedPool() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "未完成", subtitle: "按任务链去重的未完成轨迹。延续它，或明确废弃。")
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(items, id: \.chain.id) { item in
                        UnfinishedRow(item: item)
                    }
                    if items.isEmpty {
                        EmptyState(kind: .unfinishedPool, text: "没有待处理的未完成任务。")
                            .padding(.top, 40)
                    }
                }
                .padding(.horizontal, 20)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("✕")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.warn)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Theme.warnSoft))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.definition.title)
                        .font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 7) {
                        Text("\(item.unfinishedTraces.count) 次未完成").foregroundStyle(Theme.warn)
                        Text("·")
                        Text("\(item.unfinishedTraces.last?.continuationSeq ?? 0) 次延续")
                        Text("·")
                        Text("最近未完成 \(SuntraceStore.displayDate(item.unfinishedTraces.last?.date ?? store.today))")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
                }
                Spacer()
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
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.accentSoft))
                } else if let source = item.unfinishedTraces.last {
                    SmallActionButton("延续到…", tone: .accent) { store.showingPicker = .continueTrace(source.id) }
                    SmallActionButton("废弃任务链", tone: .warn) { store.abandon(source.id) }
                }
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
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(item.unfinishedTraces, id: \.id) { trace in
                        HStack(spacing: 8) {
                            Text(SuntraceStore.displayDate(trace.date))
                                .frame(width: 84, alignment: .leading)
                            Text(trace.status == .continued ? "→ 已延续" : "✕ 未完成")
                                .fontWeight(.semibold)
                                .foregroundStyle(trace.status == .continued ? Theme.text2 : Theme.warn)
                            Text("第 \(trace.continuationSeq) 次延续")
                            Spacer()
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text3)
                    }
                }
                .padding(.leading, 30)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
        .onTapGesture { store.selectUnfinished(item.chain.id) }
    }
}

struct CompletedPoolPage: View {
    @EnvironmentObject private var store: SuntraceStore
    var items: [CompletedPoolItem] { store.engine.completedPool() }
    var subtaskRecords: [CompletedSubtaskRecord] { store.engine.completedSubtaskRecords() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "已完成", subtitle: "按完成记录逐条展示，并附带每条的任务轨迹。")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(groupedDates, id: \.self) { date in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(SuntraceStore.displayDate(date))
                                .font(.system(size: 12, weight: .semibold))
                            ForEach(items.filter { $0.trace.date == date }, id: \.trace.id) { item in
                                CompletedRow(item: item)
                            }
                            ForEach(subtaskRecords.filter { $0.date == date }, id: \.subtask.id) { record in
                                CompletedSubtaskRow(record: record)
                            }
                        }
                    }
                    if items.isEmpty && subtaskRecords.isEmpty {
                        EmptyState(kind: .completedPool, text: "还没有完成记录。")
                            .padding(.top, 40)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }

    var groupedDates: [LocalDate] {
        Array(Set(items.map { $0.trace.date } + subtaskRecords.map(\.date))).sorted(by: >)
    }
}

struct CompletedRow: View {
    @EnvironmentObject private var store: SuntraceStore
    let item: CompletedPoolItem

    var body: some View {
        HStack(spacing: 10) {
            StatusGlyph(status: .completed)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.definition.title)
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 4) {
                    Text("始于 \(SuntraceStore.displayDate(item.trajectory.startDate))")
                    Text("·")
                    Text("延续 \(item.trajectory.continuedDates.count) 天")
                    Text("·")
                    Text("完成于 \(SuntraceStore.displayDate(item.trajectory.completedDate))")
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
            }
            Spacer()
            SmallActionButton("跳转当天") {
                store.selectedDate = item.trace.date
                store.page = .day
                store.selectTrace(item.trace.id)
            }
            SmallActionButton("复制为新任务") { store.copyAsNewTask(item.trace.id) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(store.selectedCompletedTraceID == item.trace.id ? Theme.accentSoft : Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(store.selectedCompletedTraceID == item.trace.id ? Theme.accent : Theme.line))
        .onTapGesture { store.selectCompleted(item.trace.id) }
    }
}

struct CompletedSubtaskRow: View {
    @EnvironmentObject private var store: SuntraceStore
    let record: CompletedSubtaskRecord

    var body: some View {
        HStack(spacing: 10) {
            Text("子")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.ok)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Theme.okSoft))
            VStack(alignment: .leading, spacing: 4) {
                Text(record.subtask.title)
                    .font(.system(size: 13, weight: .semibold))
                Text("属于「\(record.parentDefinition.title)」")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
            }
            Spacer()
            SmallActionButton("跳转当天") {
                store.selectedDate = record.date
                store.page = .day
                store.selectTrace(record.parentTrace.id)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(store.selectedCompletedSubtaskID == record.subtask.id ? Theme.accentSoft : Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(store.selectedCompletedSubtaskID == record.subtask.id ? Theme.accent : Theme.line))
        .onTapGesture { store.selectCompletedSubtask(record.subtask.id) }
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
                    HeaderButton("今天") { store.selectedCalendarDate = store.today }
                    HeaderButton("›") {
                        store.selectedCalendarDate = SuntraceStore.shiftedMonth(from: store.selectedCalendarDate, by: 1)
                    }
                }
                .padding(.top, 16)
                .padding(.horizontal, 18)

                Text("整月轨迹总览。点选任一天，右侧查看当天详情。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
                    .padding(.top, 4)
                    .padding(.horizontal, 18)

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
                .padding(.horizontal, 18)

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
                .padding(.top, 2)
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
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
        .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Theme.accentSoft : Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Theme.accent : isToday ? Theme.accent : Theme.line))
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
        switch status {
        case .completed: Theme.ok
        case .pending: Theme.accent
        case .unfinished: Theme.warn
        default: Theme.text3
        }
    }

    func titleColor(for status: TraceStatus) -> Color {
        switch status {
        case .completed, .abandoned:
            Theme.text3
        case .pending:
            Theme.text1
        default:
            Theme.text2
        }
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
                Rectangle().fill(Theme.line).frame(height: 1)
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(traces, id: \.id) { trace in
                        CalendarDetailRow(trace: trace)
                    }
                    if traces.isEmpty {
                        EmptyState(kind: .calendar, text: "这一天没有留下任务。")
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
            StatusGlyph(status: trace.status)
                .frame(width: 16, height: 16)

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
            StatusChip(status: trace.status)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
    }

    var titleColor: Color {
        switch trace.status {
        case .completed, .abandoned:
            Theme.text3
        case .pending:
            Theme.text1
        default:
            Theme.text2
        }
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
            PageHeader(title: "设置")
            VStack(alignment: .leading, spacing: 18) {
                SettingSection(title: "外观") {
                    SegmentedPair(
                        left: "冷灰",
                        right: "微暖纸感",
                        leftSelected: store.engine.preferences.theme == .coolGray,
                        leftAction: { store.setTheme(.coolGray) },
                        rightAction: { store.setTheme(.warmPaper) }
                    )
                }
                SettingSection(title: "语言") {
                    SegmentedPair(
                        left: "中文",
                        right: "English",
                        leftSelected: store.engine.preferences.language == .chinese,
                        leftAction: { store.setLanguage(.chinese) },
                        rightAction: { store.setLanguage(.english) }
                    )
                }
                SettingSection(title: "数据") {
                    HStack {
                        SmallActionButton("导出数据 (JSON)", tone: .accent) { store.exportDataPackage() }
                        SmallActionButton("导入数据…") { store.importDataPackage() }
                    }
                }
                SettingSection(title: "同步") {
                    SyncOptionsCard()
                }
                Spacer()
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 0)
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
                        Text(option.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.text1)
                        Text(option.description)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.text3)
                    }
                    Spacer()
                    StatusPill(text: "规划中", color: Theme.text3)
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

                    ZhulongPoemCard()
                }
                .padding(20)
            }
        }
    }

    var zhulongCapabilities: [ZhulongCapability] {
        [
            ZhulongCapability(title: "复盘分析", scope: "当前 Day Todo + 每日复盘", evidence: "\(store.engine.dailyReviewStats(date: store.today).total) 项今日任务"),
            ZhulongCapability(title: "任务拆解", scope: "用户选中的任务链", evidence: "生成子任务草稿，用户确认后添加"),
            ZhulongCapability(title: "排期建议", scope: "任务池 + 未来计划 + 未完成池", evidence: "\(store.engine.taskPool().count) 项未排期任务"),
            ZhulongCapability(title: "Label 分类建议", scope: "任务标题、状态和轨迹摘要", evidence: "只生成候选 label，不自动写入")
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
    let title: String
    let scope: String
    let evidence: String
}

struct ZhulongCapabilityRow: View {
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
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
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
                    TaskDetail(trace: trace, definition: definition)
                } else if let task = store.selectedPoolTask {
                    PoolDetail(task: task)
                } else if let item = store.selectedUnfinishedItem {
                    UnfinishedDetail(item: item)
                } else if store.page == .zhulong {
                    ZhulongRail()
                } else if store.page == .day {
                    ReviewRail()
                } else {
                    EmptyState(kind: hintKind, text: hint)
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

    var hintKind: EmptyStateKind {
        switch store.page {
        case .pool: .taskPool
        case .future: .futurePlans
        case .unfinished: .unfinishedPool
        case .completed: .completedPool
        default: .dayTodo
        }
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
            HStack {
                Text("任务详情")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .tracking(0.8)
                Spacer()
                Button("×") { store.clearSelection() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.text3)
            }
            HStack(alignment: .top) {
                Text(definition.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Spacer()
                Menu("•••") {
                    TaskContextMenu(trace: trace)
                }
                .menuStyle(.borderlessButton)
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
                            Text(label(for: item.status))
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

    func label(for status: TraceStatus) -> String {
        switch status {
        case .pending: "待完成"
        case .completed: "已完成"
        case .unfinished: "未完成"
        case .continued: "已延续"
        case .changed: "已变更"
        case .returnedToPool: "已回池"
        case .abandoned: "已废弃"
        }
    }
}

struct PoolDetail: View {
    @EnvironmentObject private var store: SuntraceStore
    let task: PoolTask

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("任务池")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .tracking(0.8)
                Spacer()
                Button("×") { store.clearSelection() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.text3)
            }
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
                        SmallActionButton("排期到今天", tone: .accent) { store.schedulePoolTask(task.chain.id, date: store.today) }
                        SmallActionButton("排期到明天") { store.schedulePoolTask(task.chain.id, date: SuntraceStore.offset(store.today, by: 1)) }
                    }
                    SmallActionButton("排期到指定日期…") { store.showingPicker = .schedulePool(task.chain.id) }
                }
            }
        }
    }
}

struct UnfinishedDetail: View {
    @EnvironmentObject private var store: SuntraceStore
    let item: UnfinishedPoolItem

    var latestUnfinished: DayTrace? { item.unfinishedTraces.last }
    var latestContinuation: Int { latestUnfinished?.continuationSeq ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("未完成明细")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .tracking(0.8)
                Spacer()
                Button("×") { store.clearSelection() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.text3)
            }
            Text(item.definition.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text1)
            HStack(spacing: 8) {
                StatusPill(text: "\(item.unfinishedTraces.count) 次未完成", color: Theme.warn)
                StatusPill(text: "\(latestContinuation) 次延续", color: Theme.text2)
            }
            DetailSection("处理") {
                VStack(alignment: .leading, spacing: 8) {
                    if let active = item.activeTrace {
                        Notice(text: "已延续到 \(SuntraceStore.displayDate(active.date))，当前仍待完成。", tone: .future)
                        SmallActionButton("跳转到当前待完成", tone: .accent) {
                            store.selectedDate = active.date
                            store.page = .day
                            store.selectTrace(active.id)
                        }
                    } else if let source = latestUnfinished {
                        HStack(spacing: 8) {
                            SmallActionButton("延续到…", tone: .accent) { store.showingPicker = .continueTrace(source.id) }
                            SmallActionButton("废弃任务链", tone: .warn) { store.abandon(source.id) }
                        }
                    } else {
                        Text("没有需要处理的未完成轨迹。")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text3)
                    }
                }
            }
            DetailSection("最近状态") {
                VStack(alignment: .leading, spacing: 6) {
                    if let latestUnfinished {
                        Text("最近未完成：\(SuntraceStore.displayDate(latestUnfinished.date)) \(SuntraceStore.weekday(latestUnfinished.date))")
                        Text("当日优先级 \(latestUnfinished.priority) · 第 \(latestUnfinished.continuationSeq) 次延续")
                    }
                    if let active = item.activeTrace {
                        Text("当前待完成：\(SuntraceStore.displayDate(active.date)) \(SuntraceStore.weekday(active.date))")
                    }
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
                if noReview == false {
                    StatusPill(text: "已自动保存", color: Theme.ok)
                }
                Spacer()
                Text(store.selectedDate.description)
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
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
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
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
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

struct StatusGlyph: View {
    let status: TraceStatus

    var body: some View {
        Text(glyph)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(foreground)
            .frame(width: 18, height: 18)
            .background(Circle().fill(background))
            .overlay(Circle().stroke(border, lineWidth: 1.5))
    }

    var glyph: String {
        switch status {
        case .pending: ""
        case .completed: "✓"
        case .unfinished: "✕"
        case .continued: "→"
        case .changed: "⇄"
        case .returnedToPool: "↩"
        case .abandoned: "—"
        }
    }

    var foreground: Color {
        switch status {
        case .completed: .white
        case .unfinished: Theme.warn
        case .pending: Theme.accent
        default: Theme.text2
        }
    }

    var background: Color {
        switch status {
        case .completed: Theme.ok
        case .unfinished: Theme.warnSoft
        case .pending: Theme.panel
        default: Theme.chip
        }
    }

    var border: Color {
        status == .pending ? Theme.line2 : .clear
    }
}

struct StatusChip: View {
    let status: TraceStatus

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    var label: String {
        switch status {
        case .pending: "待完成"
        case .completed: "已完成"
        case .unfinished: "未完成"
        case .continued: "已延续"
        case .changed: "已变更"
        case .returnedToPool: "已回池"
        case .abandoned: "已废弃"
        }
    }

    var color: Color {
        switch status {
        case .completed: Theme.ok
        case .unfinished: Theme.warn
        case .pending: Theme.accent
        default: Theme.text2
        }
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

    var systemImage: String {
        switch self {
        case .dayTodo: "checklist"
        case .taskPool: "tray"
        case .futurePlans: "calendar.badge.clock"
        case .unfinishedPool: "exclamationmark.circle"
        case .completedPool: "checkmark.seal"
        case .calendar: "calendar"
        }
    }

    var accent: Color {
        switch self {
        case .dayTodo, .futurePlans, .calendar:
            Theme.accent
        case .taskPool:
            Theme.text2
        case .unfinishedPool:
            Theme.warn
        case .completedPool:
            Theme.ok
        }
    }
}

struct EmptyState: View {
    let kind: EmptyStateKind
    let text: String

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(kind.accent.opacity(0.08))
                    .frame(width: 62, height: 48)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(kind.accent.opacity(0.18), lineWidth: 1)
                    )
                Image(systemName: kind.systemImage)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(kind.accent)
            }
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text3)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity)
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
