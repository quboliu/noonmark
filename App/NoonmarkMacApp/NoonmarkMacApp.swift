import AppKit
import CryptoKit
import NoonmarkAI
@_spi(ClassificationUserDecision) import NoonmarkCore
import NoonmarkStorage
import NoonmarkSync
import NoonmarkZhulong
import NoonmarkZhulongAI
import SwiftUI
import UniformTypeIdentifiers

@main
@MainActor
final class NoonmarkMacApp: NSObject, NSApplicationDelegate {
    private static var retainedDelegate: NoonmarkMacApp?
    private var window: NSWindow?
    private let store = NoonmarkStore()

    static func main() {
        let app = NSApplication.shared
        let delegate = NoonmarkMacApp()
        if CommandLine.arguments.contains("--e2e-enable-zhulong") {
            delegate.store.zhulongProviderDraft.enabled = true
        }
        if CommandLine.arguments.contains("--e2e-reset-selection") {
            delegate.store.resetLaunchSelection()
        }
        if CommandLine.arguments.contains("--page"), let index = CommandLine.arguments.firstIndex(of: "--page") {
            let valueIndex = CommandLine.arguments.index(after: index)
            let pageName = CommandLine.arguments.indices.contains(valueIndex) ? CommandLine.arguments[valueIndex] : ""
            if let page = NoonmarkStore.Page(commandLineValue: pageName) {
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

        let root = NoonmarkRootView()
            .environmentObject(store)
            .preferredColorScheme(.light)

        let window = NoonmarkWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: NoonmarkVisualMetrics.launchSize.width,
                height: NoonmarkVisualMetrics.launchSize.height
            ),
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
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        let hostingView = NSHostingView(rootView: root)
        hostingView.sizingOptions = []
        hostingView.frame = window.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(hostingView)
        window.center()
        window.minSize = NoonmarkVisualMetrics.minimumSize
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
        false
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
        guard store.showingClassificationManager == false else { return }
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
    var actions: [@MainActor (NoonmarkStore) -> Void]
    var quitsAfterAutomation: Bool

    @MainActor
    static func fromCommandLine() -> LaunchAutomation? {
        var actions: [@MainActor (NoonmarkStore) -> Void] = []
        let quickTaskTitle = NoonmarkStore.commandLineValue(after: "--e2e-add-quick-task")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let quickTaskTitle, quickTaskTitle.isEmpty == false {
            actions.append { store in
                store.page = .day
                store.selectedDate = store.today
                store.quickText = quickTaskTitle
                store.addQuickTask()
            }
        }

        append(ProviderE2EAutomation.fromCommandLine(), to: &actions)
        append(ZhulongStreamE2EAutomation.fromCommandLine(), to: &actions)
        append(ZhulongTodoDiffE2EAutomation.fromCommandLine(), to: &actions)
        append(ZhulongPersistenceE2EAutomation.fromCommandLine(), to: &actions)
        append(ClassificationE2EAutomation.fromCommandLine(), to: &actions)
        append(WorkflowE2EAutomation.fromCommandLine(), to: &actions)
        append(LifecycleE2EAutomation.fromCommandLine(), to: &actions)
        append(LifecycleRestartE2EAutomation.fromCommandLine(), to: &actions)
        append(ReactivationAtomicityE2EAutomation.fromCommandLine(), to: &actions)
        append(DataPackageE2EAutomation.fromCommandLine(), to: &actions)
        append(TaskNoteE2EAutomation.fromCommandLine(), to: &actions)
        append(TaskNoteMutationAtomicityE2EAutomation.fromCommandLine(), to: &actions)
        append(TaskNoteMutationAtomicityUIE2EAutomation.fromCommandLine(), to: &actions)
        append(TaskTitleDeleteE2EAutomation.fromCommandLine(), to: &actions)
        append(QuickTaskReturnE2EAutomation.fromCommandLine(), to: &actions)
        append(ReportedBugsE2EAutomation.fromCommandLine(), to: &actions)
        append(ReviewE2EAutomation.fromCommandLine(), to: &actions)
        append(ReviewZhulongEntryE2EAutomation.fromCommandLine(), to: &actions)
        append(ContextMenuActionsE2EAutomation.fromCommandLine(), to: &actions)
        append(UndoE2EAutomation.fromCommandLine(), to: &actions)
        append(CopyUndoPersistenceE2EAutomation.fromCommandLine(), to: &actions)
        append(DateStripE2EAutomation.fromCommandLine(), to: &actions)
        append(KeyboardDateNavigationE2EAutomation.fromCommandLine(), to: &actions)
        append(ZhulongNavigationE2EAutomation.fromCommandLine(), to: &actions)
        append(SubtaskMutationE2EAutomation.fromCommandLine(), to: &actions)
        append(SummarySidebarE2EAutomation.fromCommandLine(), to: &actions)
        append(PoolListLayoutE2EAutomation.fromCommandLine(), to: &actions)
        append(WindowResizeE2EAutomation.fromCommandLine(), to: &actions)
        append(WindowCloseBehaviorE2EAutomation.fromCommandLine(), to: &actions)
        append(LaunchSelectionE2EAutomation.fromCommandLine(), to: &actions)
        append(UIEntryE2EAutomation.fromCommandLine(), to: &actions)

        if let seedClockResultPath = NoonmarkStore.commandLineValue(
            after: "--e2e-seed-clock-result-url"
        ) {
            actions.append { store in
                SeedClockE2EVerifier.run(
                    on: store,
                    resultURL: URL(fileURLWithPath: seedClockResultPath)
                )
            }
        }

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
    func run(on store: NoonmarkStore) {
        actions.forEach { $0(store) }

        if quitsAfterAutomation {
            store.persist()
            NSApp.terminate(nil)
        }
    }

    @MainActor
    private static func append(
        _ automation: (some LaunchAutomationRunnable)?,
        to actions: inout [@MainActor (NoonmarkStore) -> Void]
    ) {
        guard let automation else { return }
        actions.append { store in
            automation.run(on: store)
        }
    }
}

private protocol LaunchAutomationRunnable {
    @MainActor
    func run(on store: NoonmarkStore)
}

private struct PoolListLayoutE2EAutomation: LaunchAutomationRunnable {
    let resultURL: URL
    let usesMinimumWindowSize: Bool

    @MainActor
    static func fromCommandLine() -> PoolListLayoutE2EAutomation? {
        guard CommandLine.arguments.contains("--e2e-pool-list-layout-probe"),
              let resultPath = NoonmarkStore.commandLineValue(
                  after: "--e2e-pool-list-layout-result-url"
              )
        else {
            return nil
        }
        return PoolListLayoutE2EAutomation(
            resultURL: URL(fileURLWithPath: resultPath),
            usesMinimumWindowSize: CommandLine.arguments.contains(
                "--e2e-pool-list-layout-minimum-window"
            )
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        store.page = .pool
        let adaptiveVisibleLabelCounts: [String: Int]
        do {
            adaptiveVisibleLabelCounts = try installAdaptiveProbeTasks(on: store)
        } catch {
            finishSetupFailure(error, resultURL: resultURL)
            return
        }
        let expectedWindowSize = usesMinimumWindowSize
            ? NoonmarkVisualMetrics.minimumSize
            : NoonmarkVisualMetrics.launchSize
        if usesMinimumWindowSize, let window = NSApp.windows.first(where: { $0 is NoonmarkWindow }) {
            let frame = window.frame
            window.setFrame(
                NSRect(
                    x: frame.minX,
                    y: frame.maxY - expectedWindowSize.height,
                    width: expectedWindowSize.width,
                    height: expectedWindowSize.height
                ),
                display: true
            )
        }
        let expectations = store.engine.taskPool().map { task in
            let classification = store.currentClassification(for: task.chain.id)
            let namespace = TaskClassificationAccessibilityNamespace(
                surface: "pool-row",
                instanceID: task.chain.id.description
            )
            let rowNamespace = PoolTaskRowE2ENamespace(
                taskIdentifier: task.chain.id.description
            )
            return PoolListLayoutUIE2EExpectation(
                taskIdentifier: task.chain.id.description,
                title: task.definition.title,
                labelNamesByIdentifier: Dictionary(
                    uniqueKeysWithValues: (classification?.labels ?? []).map {
                        (namespace.labelIdentifier($0.id), $0.name)
                    }
                ),
                expectedVisibleLabelCount: adaptiveVisibleLabelCounts[
                    task.chain.id.description
                ] ?? min(2, classification?.labels.count ?? 0),
                actionTitlesByIdentifier: [
                    rowNamespace.scheduleTodayIdentifier: store.copy.scheduleToday,
                    rowNamespace.scheduleTomorrowIdentifier: store.copy.scheduleTomorrow,
                    rowNamespace.scheduleDateIdentifier: store.copy.schedulePickDate
                ]
            )
        }
        PoolListLayoutUIE2EDriver.start(
            expectations: expectations,
            expectedWindowSize: expectedWindowSize,
            resultURL: resultURL
        )
    }

    @MainActor
    private func installAdaptiveProbeTasks(
        on store: NoonmarkStore
    ) throws -> [String: Int] {
        guard let category = store.engine.taskPool().compactMap({ task in
            store.currentClassification(for: task.chain.id)?.category
        }).first(where: { $0.name == "学习" }),
            let categoryUUID = UUID(uuidString: category.id)
        else {
            throw PoolListLayoutE2EAutomationError.failed(
                "缺少用于响应式布局探针的当前学习分组"
            )
        }
        let categoryChoice = TaskCategoryChoice.existing(
            TaskCategoryID(categoryUUID)
        )

        func createTask(
            title: String,
            labels: [String]
        ) throws -> String {
            let chainID = try store.engine.createPoolTask(title: title)
            try store.replaceTaskClassification(
                chainID: chainID,
                category: categoryChoice,
                labels: labels.map {
                    .new(name: $0, colorHex: "#7C5CFF")
                }
            )
            return chainID.description
        }

        let oneLabelTask = try createTask(
            title: "一级回退布局验证",
            labels: [
                "超长响应式标签甲甲甲甲甲甲甲",
                "超长响应式标签乙乙乙乙乙乙乙",
                "超长响应式标签丙丙丙丙丙丙丙"
            ]
        )
        let overflowOnlyTask = try createTask(
            title: "零级回退布局验证",
            labels: [
                "极长响应式标签甲甲甲甲甲甲甲甲甲甲甲甲甲甲甲甲甲甲甲甲甲甲甲甲甲甲甲甲甲甲",
                "极长响应式标签乙乙乙乙乙乙乙乙乙乙乙乙乙乙乙乙乙乙乙乙乙乙乙乙乙乙乙乙乙乙",
                "极长响应式标签丙丙丙丙丙丙丙丙丙丙丙丙丙丙丙丙丙丙丙丙丙丙丙丙丙丙丙丙丙丙"
            ]
        )
        return [
            oneLabelTask: 1,
            overflowOnlyTask: 0
        ]
    }

    @MainActor
    private func finishSetupFailure(_ error: Error, resultURL: URL) {
        try? FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? "failed: 响应式任务池探针准备失败：\(error.localizedDescription)".write(
            to: resultURL,
            atomically: true,
            encoding: .utf8
        )
        NSApp.terminate(nil)
    }
}

private enum PoolListLayoutE2EAutomationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

private struct ZhulongE2ESidecarKeySource: ZhulongSidecarKeySource {
    func loadOrCreateKey() throws -> Data {
        Data(repeating: 0x4E, count: 32)
    }
}

private struct ZhulongStreamE2EAutomation: LaunchAutomationRunnable {
    let task: ZhulongTask?
    let intent: String?
    let createsRichSession: Bool
    let completesDailyReview: Bool
    let interruptsDailyReview: Bool

    @MainActor
    static func fromCommandLine() -> Self? {
        let task = NoonmarkStore.commandLineValue(after: "--e2e-start-zhulong-workflow")
            .flatMap(ZhulongTask.init(rawValue:))
        let intent = NoonmarkStore.commandLineValue(after: "--e2e-prepare-zhulong-intent")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let createsRichSession = CommandLine.arguments.contains("--e2e-rich-zhulong-session")
        let completesDailyReview = CommandLine.arguments.contains("--e2e-complete-zhulong-daily-review")
        let interruptsDailyReview = CommandLine.arguments.contains("--e2e-interrupt-zhulong-daily-review")
        guard task != nil || intent?.isEmpty == false || createsRichSession ||
            completesDailyReview || interruptsDailyReview
        else { return nil }
        return Self(
            task: task,
            intent: intent,
            createsRichSession: createsRichSession,
            completesDailyReview: completesDailyReview,
            interruptsDailyReview: interruptsDailyReview
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        store.page = .zhulong
        if let task {
            store.startZhulongWorkspaceSession(
                intent: task.e2eIntent,
                task: task
            )
            store.authorizeCurrentZhulongWorkspaceSession()
        } else if let intent, intent.isEmpty == false {
            store.startZhulongWorkspaceSession(intent: intent)
        }
        if createsRichSession, store.zhulongWorkspace.selectedSession != nil {
            if store.zhulongWorkspace.selectedSession?.phase == .scopeReview {
                store.authorizeCurrentZhulongWorkspaceSession()
            }
            store.zhulongWorkspace.appendToCurrentSession(
                author: .zhulong,
                kind: .statement,
                content: "已读取授权范围，并建立每日收尾事实基线。"
            )
            store.zhulongWorkspace.pauseCurrentSession()
            store.zhulongWorkspace.resumeCurrentSession()
            store.zhulongWorkspace.captureDailyClose(date: store.today, from: store.engine)
        }
        if completesDailyReview || interruptsDailyReview {
            store.publishCurrentZhulongDailyReview(
                summary: "E2E 已确认的每日复盘",
                tomorrowNote: "E2E 明日只保留一个可信承诺"
            )
            store.confirmAndSaveCurrentZhulongDailyReview(
                interruptAfterEnginePersisted: interruptsDailyReview
            )
        }
    }
}

private extension ZhulongTask {
    var e2eIntent: String {
        switch self {
        case .dailyReview:
            "结束今天并形成下一次可信承诺"
        case .habitInsight:
            "分析近期习惯与完成节奏"
        case .taskDecomposition:
            "梳理一个需要形成计划的任务"
        case .scheduling:
            "重新安排任务池与未完成任务"
        case .classification:
            "整理任务的分组与标签"
        case .theoryAnalysis:
            "分析当前任务背后的理论与方法"
        }
    }
}

private struct ZhulongTodoDiffE2EProvider: ZhulongProvider {
    let configurationIdentity: ZhulongProviderConfigurationIdentity

    func complete(_ request: ZhulongProviderRequest) async -> ZhulongProviderResult {
        .success(ZhulongProviderResponse(content: Self.planArtifact, draftVersion: 1))
    }

    private static let planArtifact = """
    {
      "kind":"planArtifact",
      "summary":"先取得测量，再交付近期切片。",
      "stages":[
        {
          "id":"measure",
          "title":"工程测量",
          "objective":"取得真实数据",
          "horizon":"nearTerm",
          "dependencyIDs":[],
          "deliverables":["测量记录","验证记录"],
          "triggerCondition":null
        },
        {
          "id":"delivery",
          "title":"交付切片",
          "objective":"完成任务成形闭环",
          "horizon":"later",
          "dependencyIDs":["measure"],
          "deliverables":[],
          "triggerCondition":"测量记录已审查"
        }
      ],
      "decisionExplanations":[
        {
          "subject":"为何先测量",
          "userDecisions":["先完成 Mac 版"],
          "assumptions":[],
          "dataScopes":["currentDayTodo"],
          "evidence":["当前没有同度量工程数据"],
          "constraints":["普通 Todo 必须离线可用"],
          "alternatives":[
            {"title":"直接排期","tradeoffs":["快，但没有证据"]},
            {"title":"先测量","tradeoffs":["较慢，但可校准"]}
          ],
          "counterexamples":["直接排期会隐藏证据缺口"],
          "rationale":"测量后才能形成可信承诺。",
          "uncertainties":["测量结果尚未知"],
          "expectedImpacts":["近期只生成调查任务"],
          "requiredAuthorizations":["todoWrite"]
        }
      ],
      "precisionClaims":[]
    }
    """
}

private struct ZhulongTodoDiffE2EAutomation: LaunchAutomationRunnable {
    let resultURL: URL?

    @MainActor
    static func fromCommandLine() -> Self? {
        guard CommandLine.arguments.contains("--e2e-prepare-zhulong-todo-diff") else {
            return nil
        }
        return Self(
            resultURL: NoonmarkStore.commandLineValue(
                after: "--e2e-zhulong-todo-diff-result-url"
            ).map(URL.init(fileURLWithPath:))
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            store.page = .zhulong
            let identity = try ZhulongProviderConfigurationIdentity(
                providerID: "e2e-todo-diff",
                kind: .localModel,
                baseURL: nil,
                location: .local,
                model: "deterministic-plan",
                dataCapabilities: [.structuredOutput, .taskContext]
            )
            store.zhulongWorkspace.createSession(
                intent: "审查并形成可信的 Todo 变更",
                scopes: [.currentDayTodo]
            )
            store.zhulongWorkspace.authorizeCurrentSession(providerIdentity: identity)
            guard let sourceEntryID = store.zhulongWorkspace.selectedSession?.entries.first?.id else {
                return
            }
            store.zhulongWorkspace.publishPlanningBrief(
                try ZhulongPlanningBriefDraft(
                    goal: "发布稳定版",
                    successCriteria: ["真实 App E2E 通过"],
                    hardConstraints: ["普通 Todo 必须离线可用"],
                    userDecisions: ["先完成 Mac 版"],
                    delegatedActivities: [.taskDecomposition, .sequencing, .riskReview],
                    assumptions: [],
                    openQuestions: [],
                    dataScopes: [.currentDayTodo],
                    sourceEntryIDs: [sourceEntryID]
                )
            )
            store.zhulongWorkspace.reviewCurrentPlanningBrief()
            store.zhulongWorkspace.delegateCurrentPlanningBrief()
            let payload = try ZhulongProviderPayload(
                systemPrompt: "只返回符合规划协议的结构化产物。",
                userPrompt: "规划发布新版",
                contextVersion: "e2e-todo-diff-v1",
                scopeContent: [.currentDayTodo: "E2E 当前 Day Todo 摘要"]
            )
            let provider = ZhulongTodoDiffE2EProvider(configurationIdentity: identity)
            Task { @MainActor in
                await store.zhulongWorkspace.runCurrentPlanningSession(
                    payload: payload,
                    provider: provider
                )
                store.publishCurrentZhulongTodoDiff()
                guard let resultURL else { return }
                let result = exerciseRevisionAndApply(on: store)
                try? result.write(to: resultURL, atomically: true, encoding: .utf8)
                store.persist()
                NSApp.terminate(nil)
            }
        } catch {
            store.zhulongWorkspace.reportUIError("E2E Todo diff 准备失败：\(error.localizedDescription)")
        }
    }

    @MainActor
    private func exerciseRevisionAndApply(on store: NoonmarkStore) -> String {
        guard let original = store.zhulongWorkspace.selectedSession?.currentTodoDiff,
              original.items.count == 2
        else { return "failed: missing original diff" }
        let editedID = original.items[0].id
        let removedID = original.items[1].id
        let splitID = ZhulongTodoDiffItemID()
        let items = [
            ZhulongTodoDiffItem(
                id: editedID,
                operation: .createTask(
                    title: "E2E 编辑后的测量",
                    descriptionText: "取得真实数据",
                    initialNoteBody: "保留第一项并修改",
                    plannedSubtasks: [],
                    targetDate: nil
                )
            ),
            ZhulongTodoDiffItem(
                id: splitID,
                operation: .createTask(
                    title: "E2E 拆分后的验证",
                    descriptionText: "取得真实数据",
                    initialNoteBody: "由用户拆分新增",
                    plannedSubtasks: [],
                    targetDate: nil
                )
            )
        ]
        guard store.zhulongWorkspace.reviseCurrentTodoDiff(items: items),
              let revision = store.zhulongWorkspace.selectedSession?.currentTodoDiff,
              case let .userRevision(parentID, modifiedIDs) = revision.source,
              parentID == original.id,
              revision.version == 2,
              Set(modifiedIDs) == [editedID, removedID, splitID]
        else { return "failed: revision audit mismatch" }

        store.confirmAndApplyCurrentZhulongTodoDiff()
        let titles = Set(store.engine.definitions.values.map(\.title))
        guard titles == ["E2E 编辑后的测量", "E2E 拆分后的验证"],
              store.zhulongWorkspace.selectedSession?.todoApplyReceipts.count == 1,
              store.zhulongWorkspace.selectedSession?.events.suffix(3).map(\.kind) == [
                  .todoDiffRevised, .todoWriteAuthorized, .todoBatchApplied
              ]
        else { return "failed: atomic application mismatch" }
        return "ok"
    }
}

private struct ZhulongPersistenceE2EAutomation: LaunchAutomationRunnable {
    let resultURL: URL
    let expectsRecovery: Bool

    @MainActor
    static func fromCommandLine() -> Self? {
        guard let path = NoonmarkStore.commandLineValue(
            after: "--e2e-verify-zhulong-persistence-result-url"
        ), path.isEmpty == false else { return nil }
        return Self(
            resultURL: URL(fileURLWithPath: path),
            expectsRecovery: CommandLine.arguments.contains("--e2e-expect-zhulong-recovery")
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        let sessions = store.zhulongWorkspace.sessions
        let latest = sessions.first
        let baseRecovered = sessions.count == 1 &&
            latest?.authorization != nil &&
            latest?.dailyCloseSnapshots.count == 1 &&
            latest?.events.contains(where: { $0.kind == .sessionPaused }) == true &&
            latest?.events.contains(where: { $0.kind == .sessionResumed }) == true
        let recovered = baseRecovered && (expectsRecovery
            ? latest?.dailyReviewReceipts.count == 1 &&
                store.zhulongWorkspace.statusMessage?.contains("已恢复") == true
            : store.zhulongWorkspace.statusMessage == nil)
        let detectedCorruption = sessions.count == 1 &&
            store.zhulongWorkspace.statusMessage?.contains("无法验证") == true
        let result = recovered
            ? "ok"
            : (detectedCorruption
                ? "corruption-detected"
                : "failed: \(store.zhulongWorkspace.statusMessage ?? "missing status")")
        try? result.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

private struct ClassificationE2EAutomation: LaunchAutomationRunnable {
    private enum Mode {
        case edit
        case verify
    }

    private static let categoryName = "验证"
    private static let labelNames = ["SQLite", "重启", "白盒"]
    private static let interactionID = UUID(uuidString: "8312940E-8B19-4D05-94FB-6FE92D7BBE63")

    private let mode: Mode
    private let title: String
    private let resultURL: URL

    @MainActor
    static func fromCommandLine() -> ClassificationE2EAutomation? {
        let edits = CommandLine.arguments.contains("--e2e-classification-edit")
        let verifies = CommandLine.arguments.contains("--e2e-classification-verify")
        guard edits != verifies else { return nil }
        guard let title = NoonmarkStore.commandLineValue(after: "--e2e-classification-title")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            title.isEmpty == false,
            let resultPath = NoonmarkStore.commandLineValue(after: "--e2e-classification-result-url")
        else {
            return nil
        }
        return ClassificationE2EAutomation(
            mode: edits ? .edit : .verify,
            title: title,
            resultURL: URL(fileURLWithPath: resultPath)
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            switch mode {
            case .edit:
                try edit(on: store)
            case .verify:
                try verify(on: store)
            }
            try writeResult("ok")
        } catch {
            try? writeResult("failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func edit(on store: NoonmarkStore) throws {
        guard let interactionID = Self.interactionID else {
            throw ClassificationE2EAutomationError.failed("invalid fixed interaction ID")
        }
        store.page = .pool
        store.poolText = title
        store.addPoolTask()
        guard let task = store.engine.taskPool().first(where: { $0.definition.title == title }) else {
            throw ClassificationE2EAutomationError.failed("task was not created")
        }

        let receipt = try store.replaceTaskClassification(
            chainID: task.chain.id,
            category: .new(name: Self.categoryName, colorHex: "#6F5FF7"),
            labels: [
                .new(name: Self.labelNames[0], colorHex: "#3276E8"),
                .new(name: Self.labelNames[1], colorHex: "#E78B1F"),
                .new(name: Self.labelNames[2], colorHex: "#0E9488")
            ],
            interactionID: interactionID
        )
        guard receipt.revision == 1,
              receipt.decisionID == interactionID,
              receipt.changeRecordID != receipt.planID
        else {
            throw ClassificationE2EAutomationError.failed("classification receipt is incomplete")
        }
        try verifyProjection(for: task.chain.id, in: store)
    }

    @MainActor
    private func verify(on store: NoonmarkStore) throws {
        guard let task = store.engine.taskPool().first(where: { $0.definition.title == title }) else {
            throw ClassificationE2EAutomationError.failed("task was not restored after restart")
        }
        try verifyProjection(for: task.chain.id, in: store)

        let state = store.engine.snapshot().classifications
        guard state.changeRecords.count == 1,
              state.committedReceiptsByInteractionID.count == 1
        else {
            throw ClassificationE2EAutomationError.failed("audit trail duplicated or disappeared after restart")
        }
        store.page = .pool
        store.selectPool(task.chain.id)
    }

    @MainActor
    private func verifyProjection(for chainID: TaskChainID, in store: NoonmarkStore) throws {
        guard let projection = store.currentClassification(for: chainID),
              projection.category?.name == Self.categoryName,
              Set(projection.labels.map(\.name)) == Set(Self.labelNames),
              projection.revision == 1
        else {
            throw ClassificationE2EAutomationError.failed("classification projection does not match")
        }
    }

    private func writeResult(_ result: String) throws {
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

private enum ClassificationE2EAutomationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

private struct LaunchSelectionE2EAutomation: LaunchAutomationRunnable {
    var selectionName: String

    @MainActor
    static func fromCommandLine() -> LaunchSelectionE2EAutomation? {
        guard let selectionName = NoonmarkStore.commandLineValue(after: "--select"),
              ["first", "manual", "changed"].contains(selectionName)
        else {
            return nil
        }
        return LaunchSelectionE2EAutomation(selectionName: selectionName)
    }

    func run(on store: NoonmarkStore) {
        store.selectItemForLaunch(selectionName)
    }
}

private struct UIEntryE2EAutomation: LaunchAutomationRunnable {
    private enum Mode {
        case classificationManager(selectsLabels: Bool)
        case classificationOverflow
        case zhulongWorkflows
    }

    private let mode: Mode
    private let resultURL: URL
    private let keepsAppOpen: Bool

    @MainActor
    static func fromCommandLine() -> UIEntryE2EAutomation? {
        let opensClassificationManager = CommandLine.arguments.contains(
            "--e2e-classification-manager-via-ui"
        )
        let opensClassificationManagerLabels = CommandLine.arguments.contains(
            "--e2e-classification-manager-labels-via-ui"
        )
        let opensClassificationOverflow = CommandLine.arguments.contains(
            "--e2e-classification-overflow-via-ui"
        )
        let opensZhulongWorkflows = CommandLine.arguments.contains(
            "--e2e-zhulong-workflows-via-ui"
        )
        let selectedModeCount = [
            opensClassificationManager,
            opensClassificationManagerLabels,
            opensClassificationOverflow,
            opensZhulongWorkflows
        ].filter { $0 }.count
        guard selectedModeCount == 1 else { return nil }

        let mode: Mode
        let resultArgument: String
        if opensClassificationManager || opensClassificationManagerLabels {
            mode = .classificationManager(selectsLabels: opensClassificationManagerLabels)
            resultArgument = "--e2e-classification-manager-ui-result-url"
        } else if opensClassificationOverflow {
            mode = .classificationOverflow
            resultArgument = "--e2e-classification-overflow-ui-result-url"
        } else {
            mode = .zhulongWorkflows
            resultArgument = "--e2e-zhulong-workflows-ui-result-url"
        }
        guard let resultPath = NoonmarkStore.commandLineValue(after: resultArgument) else {
            return nil
        }
        return UIEntryE2EAutomation(
            mode: mode,
            resultURL: URL(fileURLWithPath: resultPath),
            keepsAppOpen: CommandLine.arguments.contains("--e2e-ui-entry-keep-open")
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        switch mode {
        case let .classificationManager(selectsLabels):
            ClassificationManagerUIE2EDriver.start(
                resultURL: resultURL,
                keepsAppOpen: keepsAppOpen,
                selectsLabels: selectsLabels
            )
        case .classificationOverflow:
            guard let task = store.engine.taskPool().first(where: { task in
                (store.currentClassification(for: task.chain.id)?.labels.count ?? 0) > 2
            }), let classification = store.currentClassification(for: task.chain.id) else {
                try? "failed: 当前任务池没有标签溢出的任务".write(
                    to: resultURL,
                    atomically: true,
                    encoding: .utf8
                )
                return
            }
            ClassificationOverflowUIE2EDriver.start(
                chainIdentifier: task.chain.id.description,
                labels: classification.labels,
                resultURL: resultURL,
                keepsAppOpen: keepsAppOpen
            )
        case .zhulongWorkflows:
            ZhulongWorkflowE2EUIInteractionDriver.start(resultURL: resultURL)
        }
    }
}

private struct ReviewE2EAutomation: LaunchAutomationRunnable {
    var summary: String

    @MainActor
    static func fromCommandLine() -> ReviewE2EAutomation? {
        guard CommandLine.arguments.contains("--e2e-update-review") else { return nil }
        return ReviewE2EAutomation(
            summary: NoonmarkStore.commandLineValue(after: "--e2e-review-summary") ?? "E2E 自动保存反馈"
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
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
        let resultURL = NoonmarkStore.commandLineValue(after: "--e2e-review-zhulong-result-url")
            .map { URL(fileURLWithPath: $0) }
        return ReviewZhulongEntryE2EAutomation(resultURL: resultURL)
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        store.page = .day
        store.selectedDate = store.today
        store.zhulongProviderDraft.enabled = true
        store.requestZhulongDailyReviewFromReviewRail()

        guard store.page == .zhulong,
              store.zhulongWorkspace.selectedSession?.phase == .scopeReview,
              store.zhulongWorkspace.selectedSession?.proposedScopes == [.currentDayTodo]
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
        let resultURL = NoonmarkStore.commandLineValue(after: "--e2e-context-menu-result-url")
            .map { URL(fileURLWithPath: $0) }
        return ContextMenuActionsE2EAutomation(resultURL: resultURL)
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            store.engine = NoonmarkEngine()
            let today = store.today
            let past = NoonmarkStore.offset(today, by: -1)
            let future = NoonmarkStore.offset(today, by: 1)

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
            try store.engine.settleDays(upTo: today)
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
    private func makeTrace(title: String, date: LocalDate, today: LocalDate, store: NoonmarkStore) throws -> DayTraceID {
        let chainID = try store.engine.createPoolTask(title: title)
        return try store.engine.scheduleFromPool(chainID: chainID, date: date, today: today)
    }

    @MainActor
    private func trace(_ id: DayTraceID, in store: NoonmarkStore) throws -> DayTrace {
        guard let trace = store.engine.traces[id] else {
            throw ContextMenuActionsE2EAutomationError.missingTrace
        }
        return trace
    }

    private func assertActions(
        _ actual: [NoonmarkStore.TraceContextAction],
        _ expected: [NoonmarkStore.TraceContextAction],
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

private struct CopyUndoPersistenceE2EState: Codable {
    let sourceChainID: TaskChainID
    let sourceTraceID: DayTraceID
    let copiedChainID: TaskChainID
    let classificationRevision: UInt64
    let sourceHistoryEventCount: Int
}

private struct CopyUndoPersistenceE2EAutomation: LaunchAutomationRunnable {
    private enum Mode {
        case setup
        case verify
    }

    private let mode: Mode?
    private let stateURL: URL?
    private let resultURL: URL?

    @MainActor
    static func fromCommandLine() -> Self? {
        let shouldSetup = CommandLine.arguments.contains(
            "--e2e-copy-undo-persistence-setup"
        )
        let shouldVerify = CommandLine.arguments.contains(
            "--e2e-copy-undo-persistence-verify"
        )
        guard shouldSetup || shouldVerify else { return nil }
        let mode: Mode? = switch (shouldSetup, shouldVerify) {
        case (true, false): .setup
        case (false, true): .verify
        default: nil
        }
        return Self(
            mode: mode,
            stateURL: NoonmarkStore.commandLineValue(
                after: "--e2e-copy-undo-persistence-state-url"
            ).map { URL(fileURLWithPath: $0) },
            resultURL: NoonmarkStore.commandLineValue(
                after: "--e2e-copy-undo-persistence-result-url"
            ).map { URL(fileURLWithPath: $0) }
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            guard let mode, let stateURL, let resultURL else {
                throw CopyUndoPersistenceE2EError.failed(
                    "missing or conflicting copy-undo persistence arguments"
                )
            }
            switch mode {
            case .setup:
                try setup(on: store, stateURL: stateURL)
            case .verify:
                try verify(on: store, stateURL: stateURL)
            }
            try writeResult("ok", to: resultURL)
        } catch {
            if let resultURL {
                try? writeResult(
                    "failed: \(error.localizedDescription)",
                    to: resultURL
                )
            }
        }
    }

    @MainActor
    private func setup(
        on store: NoonmarkStore,
        stateURL: URL
    ) throws {
        guard store.engine.chains.isEmpty,
              store.engine.definitions.isEmpty,
              store.engine.traces.isEmpty
        else {
            throw CopyUndoPersistenceE2EError.failed(
                "isolated copy-undo database was not empty"
            )
        }

        let past = NoonmarkStore.offset(store.today, by: -1)
        let sourceChainID = try store.engine.createPoolTask(
            title: "E2E 持久化已分类复制来源"
        )
        let sourceTraceID = try store.engine.scheduleFromPool(
            chainID: sourceChainID,
            date: past,
            today: past
        )
        _ = try store.replaceTaskClassification(
            chainID: sourceChainID,
            category: .new(name: "E2E 持久化分类", colorHex: "#2A6FDB"),
            labels: [.new(name: "E2E 持久化标签", colorHex: "#0E9488")]
        )
        try store.engine.markCompleted(traceID: sourceTraceID, today: past)
        try store.engine.settleDays(upTo: store.today)
        let beforeCopy = store.engine.snapshot()
        let sourceChainBefore = store.engine.chains[sourceChainID]
        let sourceTraceBefore = store.engine.traces[sourceTraceID]
        let sourceHistoryBefore = try sourceHistory(
            in: store,
            traceID: sourceTraceID
        )

        store.clearUndoHistory()
        store.copyAsNewTask(sourceTraceID)
        let copiedChainID = try unwrap(
            store.engine.taskPool().first?.chain.id,
            "persisted classified copy"
        )
        let copiedBeforeUndo = try taskClassification(
            in: store,
            chainID: copiedChainID
        )
        guard copiedBeforeUndo.category?.name == "E2E 持久化分类",
              copiedBeforeUndo.labels.map(\.name) == ["E2E 持久化标签"]
        else {
            throw CopyUndoPersistenceE2EError.failed(
                "persisted copy did not inherit source classification"
            )
        }

        store.undo()
        guard store.toast == "已撤销" else {
            throw CopyUndoPersistenceE2EError.failed(
                "persistent copy undo failed: \(store.toast ?? "missing toast")"
            )
        }
        let snapshot = store.engine.snapshot()
        try snapshot.validateIntegrity()
        let copiedAfterUndo = try taskClassification(
            in: store,
            chainID: copiedChainID
        )
        let sourceAfterUndo = try taskClassification(
            in: store,
            chainID: sourceChainID
        )
        let sourceHistoryAfter = try sourceHistory(
            in: store,
            traceID: sourceTraceID
        )
        guard store.engine.taskPool().isEmpty,
              store.engine.chains[copiedChainID]?.state == .abandoned,
              store.engine.definitions.values.contains(where: {
                  $0.chainID == copiedChainID
              }),
              store.engine.traces.values.contains(where: {
                  $0.chainID == copiedChainID
              }) == false,
              copiedAfterUndo.category == nil,
              copiedAfterUndo.labels.isEmpty,
              store.engine.chains[sourceChainID] == sourceChainBefore,
              store.engine.traces[sourceTraceID] == sourceTraceBefore,
              sourceAfterUndo.category?.name == "E2E 持久化分类",
              sourceAfterUndo.labels.map(\.name) == ["E2E 持久化标签"],
              sourceHistoryAfter == sourceHistoryBefore,
              snapshot.classifications.changeRecords.starts(
                  with: beforeCopy.classifications.changeRecords
              ),
              snapshot.classifications.revision
                  == beforeCopy.classifications.revision + 2
        else {
            throw CopyUndoPersistenceE2EError.failed(
                "copy undo did not append a compensating classification fact atomically"
            )
        }

        let state = CopyUndoPersistenceE2EState(
            sourceChainID: sourceChainID,
            sourceTraceID: sourceTraceID,
            copiedChainID: copiedChainID,
            classificationRevision: snapshot.classifications.revision,
            sourceHistoryEventCount: sourceHistoryAfter.events.count
        )
        try writeState(state, to: stateURL)
    }

    @MainActor
    private func verify(
        on store: NoonmarkStore,
        stateURL: URL
    ) throws {
        let state = try readState(from: stateURL)
        let snapshot = store.engine.snapshot()
        try snapshot.validateIntegrity()
        let source = try taskClassification(
            in: store,
            chainID: state.sourceChainID
        )
        let sourceHistory = try sourceHistory(
            in: store,
            traceID: state.sourceTraceID
        )
        let copied = try taskClassification(
            in: store,
            chainID: state.copiedChainID
        )
        guard store.engine.taskPool().isEmpty,
              store.engine.traces[state.sourceTraceID]?.status == .completed,
              store.engine.chains[state.copiedChainID]?.state == .abandoned,
              store.engine.definitions.values.contains(where: {
                  $0.chainID == state.copiedChainID
              }),
              store.engine.traces.values.contains(where: {
                  $0.chainID == state.copiedChainID
              }) == false,
              source.category?.name == "E2E 持久化分类",
              source.labels.map(\.name) == ["E2E 持久化标签"],
              sourceHistory.category?.name == "E2E 持久化分类",
              sourceHistory.labels.map(\.name) == ["E2E 持久化标签"],
              sourceHistory.events.count == state.sourceHistoryEventCount,
              copied.category == nil,
              copied.labels.isEmpty,
              snapshot.classifications.revision == state.classificationRevision
        else {
            throw CopyUndoPersistenceE2EError.failed(
                "copy undo state did not survive SQLite restart"
            )
        }
    }

    @MainActor
    private func taskClassification(
        in store: NoonmarkStore,
        chainID: TaskChainID
    ) throws -> TaskClassificationProjection {
        guard case let .task(projection) = try store.engine.classification(
            .task(chainID)
        ) else {
            throw CopyUndoPersistenceE2EError.failed(
                "missing task classification projection"
            )
        }
        return projection
    }

    @MainActor
    private func sourceHistory(
        in store: NoonmarkStore,
        traceID: DayTraceID
    ) throws -> TraceClassificationProjection {
        guard case let .history(projection) = try store.engine.classification(
            .history(traceID)
        ) else {
            throw CopyUndoPersistenceE2EError.failed(
                "missing source classification history"
            )
        }
        return projection
    }

    private func unwrap<Value>(_ value: Value?, _ label: String) throws -> Value {
        guard let value else {
            throw CopyUndoPersistenceE2EError.failed("missing \(label)")
        }
        return value
    }

    private func writeState(
        _ state: CopyUndoPersistenceE2EState,
        to url: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }

    private func readState(from url: URL) throws -> CopyUndoPersistenceE2EState {
        try JSONDecoder().decode(
            CopyUndoPersistenceE2EState.self,
            from: Data(contentsOf: url)
        )
    }

    private func writeResult(_ result: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: url, atomically: true, encoding: .utf8)
    }
}

private enum CopyUndoPersistenceE2EError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            message
        }
    }
}

private struct UndoE2EAutomation: LaunchAutomationRunnable {
    var resultURL: URL?

    @MainActor
    static func fromCommandLine() -> UndoE2EAutomation? {
        guard CommandLine.arguments.contains("--e2e-undo-workflow") else { return nil }
        let resultURL = NoonmarkStore.commandLineValue(after: "--e2e-undo-result-url")
            .map { URL(fileURLWithPath: $0) }
        return UndoE2EAutomation(resultURL: resultURL)
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            try verifyPoolAddUndo(on: store)
            try verifyPoolNoteAppendUndoUsesTombstone(on: store)
            try verifyPoolNoteEditUndoAdvancesVersion(on: store)
            try verifyPoolNoteDeleteUndoUsesNewIdentity(on: store)
            try verifyPoolNoteUndoCompositionKeepsLogicalIdentity(on: store)
            try verifyTraceNoteUndoCompositionKeepsLogicalIdentity(on: store)
            try verifyCurrentContinuationUndo(on: store)
            try verifyCurrentAbandonUndo(on: store)
            try verifyNoteUndoKeepsEarlierUndo(on: store)
            try verifyFutureRescheduleUndo(on: store)
            try verifyUnclassifiedCopyAsNewTaskUndo(on: store)
            try verifyCopyAsNewTaskUndo(on: store)
            try verifyHistoricalAbandonIsNotUndoable(on: store)
            try writeResult("ok")
        } catch {
            try? writeResult("failed: \(error)")
        }
    }

    @MainActor
    private func reset(_ store: NoonmarkStore) {
        store.engine = NoonmarkEngine()
        store.page = .day
        store.selectedDate = store.today
        store.selectedCalendarDate = store.today
        store.clearSelection()
        store.clearUndoHistory()
    }

    @MainActor
    private func verifyPoolAddUndo(on store: NoonmarkStore) throws {
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
    private func verifyPoolNoteAppendUndoUsesTombstone(
        on store: NoonmarkStore
    ) throws {
        reset(store)
        let chainID = try store.engine.createPoolTask(title: "E2E 撤销新增附言")
        store.detailNoteText = "刚新增的附言"
        store.appendPoolNote(chainID: chainID)
        let noteID = try unwrap(
            store.engine.taskPool().first?.chain.activeNoteEntries.first?.id,
            "appended note identity"
        )

        store.undo()

        let chain = try unwrap(
            store.engine.taskPool().first?.chain,
            "chain after append undo"
        )
        guard chain.activeNoteEntries.isEmpty,
              chain.noteEntries.first(where: { $0.id == noteID })?.isDeleted == true
        else {
            throw UndoE2EAutomationError.failed(
                "note append undo did not preserve a tombstone"
            )
        }
    }

    @MainActor
    private func verifyPoolNoteEditUndoAdvancesVersion(
        on store: NoonmarkStore
    ) throws {
        reset(store)
        let chainID = try store.engine.createPoolTask(
            title: "E2E 撤销编辑附言",
            initialNoteBody: "编辑前"
        )
        let original = try unwrap(
            store.engine.taskPool().first?.chain.activeNoteEntries.first,
            "original note"
        )
        store.editPoolNote(
            chainID: chainID,
            noteID: original.id,
            body: "编辑后"
        )
        let editedAt = try unwrap(
            store.engine.taskPool().first?.chain.activeNoteEntries.first?.updatedAt,
            "edited note time"
        )

        store.undo()

        let restored = try unwrap(
            store.engine.taskPool().first?.chain.activeNoteEntries.first,
            "restored note"
        )
        guard restored.id == original.id,
              restored.body == original.body,
              restored.updatedAt > editedAt
        else {
            throw UndoE2EAutomationError.failed(
                "note edit undo did not create a forward version"
            )
        }
    }

    @MainActor
    private func verifyPoolNoteDeleteUndoUsesNewIdentity(
        on store: NoonmarkStore
    ) throws {
        reset(store)
        let chainID = try store.engine.createPoolTask(
            title: "E2E 撤销删除附言",
            initialNoteBody: "删除前正文"
        )
        let original = try unwrap(
            store.engine.taskPool().first?.chain.activeNoteEntries.first,
            "note before delete"
        )
        store.deletePoolNote(chainID: chainID, noteID: original.id)

        store.undo()

        let chain = try unwrap(
            store.engine.taskPool().first?.chain,
            "chain after delete undo"
        )
        let restored = try unwrap(
            chain.activeNoteEntries.first,
            "new note after delete undo"
        )
        guard restored.id != original.id,
              restored.body == original.body,
              chain.noteEntries.first(where: {
                  $0.id == original.id
              })?.isDeleted == true
        else {
            throw UndoE2EAutomationError.failed(
                "note delete undo revived the tombstoned identity"
            )
        }
    }

    @MainActor
    private func verifyPoolNoteUndoCompositionKeepsLogicalIdentity(
        on store: NoonmarkStore
    ) throws {
        reset(store)
        let chainID = try store.engine.createPoolTask(
            title: "E2E 任务池附言连续撤销"
        )
        store.detailNoteText = "新增正文"
        store.appendPoolNote(chainID: chainID)
        let originalID = try unwrap(
            store.engine.chains[chainID]?.activeNoteEntries.first?.id,
            "pool note before edit and delete"
        )
        store.editPoolNote(
            chainID: chainID,
            noteID: originalID,
            body: "编辑后正文"
        )
        store.deletePoolNote(chainID: chainID, noteID: originalID)

        store.undo()
        let restoredID = try unwrap(
            store.engine.chains[chainID]?.activeNoteEntries.first?.id,
            "pool note restored after delete undo"
        )
        guard restoredID != originalID,
              store.engine.chains[chainID]?.activeNoteEntries.first?.body == "编辑后正文"
        else {
            throw UndoE2EAutomationError.failed(
                "pool delete undo did not restore edited note under a fresh storage identity"
            )
        }

        store.undo()
        guard store.engine.chains[chainID]?.activeNoteEntries.first?.id == restoredID,
              store.engine.chains[chainID]?.activeNoteEntries.first?.body == "新增正文",
              store.toast == "已撤销"
        else {
            throw UndoE2EAutomationError.failed(
                "pool delete undo lost the logical identity needed by the earlier edit undo"
            )
        }

        store.undo()
        guard let chain = store.engine.chains[chainID],
              chain.activeNoteEntries.isEmpty,
              chain.noteEntries.first(where: { $0.id == originalID })?.isDeleted == true,
              chain.noteEntries.first(where: { $0.id == restoredID })?.isDeleted == true,
              store.toast == "已撤销"
        else {
            throw UndoE2EAutomationError.failed(
                "pool append undo did not compose after edit and delete undo"
            )
        }
    }

    @MainActor
    private func verifyTraceNoteUndoCompositionKeepsLogicalIdentity(
        on store: NoonmarkStore
    ) throws {
        reset(store)
        let traceID = try makeTrace(
            title: "E2E 日轨迹附言连续撤销",
            date: store.today,
            today: store.today,
            store: store
        )
        store.detailNoteText = "轨迹新增正文"
        store.appendTraceNote(traceID: traceID)
        let originalID = try unwrap(
            store.engine.traces[traceID]?.activeNoteEntries.first?.id,
            "trace note before edit and delete"
        )
        store.editTraceNote(
            traceID: traceID,
            noteID: originalID,
            body: "轨迹编辑后正文"
        )
        store.deleteTraceNote(traceID: traceID, noteID: originalID)

        store.undo()
        let restoredID = try unwrap(
            store.engine.traces[traceID]?.activeNoteEntries.first?.id,
            "trace note restored after delete undo"
        )
        guard restoredID != originalID,
              store.engine.traces[traceID]?.activeNoteEntries.first?.body == "轨迹编辑后正文"
        else {
            throw UndoE2EAutomationError.failed(
                "trace delete undo did not restore edited note under a fresh storage identity"
            )
        }

        store.undo()
        guard store.engine.traces[traceID]?.activeNoteEntries.first?.id == restoredID,
              store.engine.traces[traceID]?.activeNoteEntries.first?.body == "轨迹新增正文",
              store.toast == "已撤销"
        else {
            throw UndoE2EAutomationError.failed(
                "trace delete undo lost the logical identity needed by the earlier edit undo"
            )
        }

        store.undo()
        guard let trace = store.engine.traces[traceID],
              trace.activeNoteEntries.isEmpty,
              trace.noteEntries.first(where: { $0.id == originalID })?.isDeleted == true,
              trace.noteEntries.first(where: { $0.id == restoredID })?.isDeleted == true,
              store.toast == "已撤销"
        else {
            throw UndoE2EAutomationError.failed(
                "trace append undo did not compose after edit and delete undo"
            )
        }
    }

    @MainActor
    private func verifyCurrentContinuationUndo(on store: NoonmarkStore) throws {
        reset(store)
        let traceID = try makeTrace(title: "E2E 撤销当前延续", date: store.today, today: store.today, store: store)
        let chainID = try unwrap(store.engine.traces[traceID]?.chainID, "continuation chain")
        _ = try store.replaceTaskClassification(
            chainID: chainID,
            category: .new(name: "E2E 撤销分类", colorHex: "#2A6FDB"),
            labels: []
        )
        store.clearUndoHistory()
        let tomorrow = NoonmarkStore.offset(store.today, by: 1)
        store.continueTrace(traceID, to: tomorrow)
        guard store.engine.traces.values.contains(where: { $0.date == tomorrow && $0.status == .pending }) else {
            throw UndoE2EAutomationError.failed("continuation did not create tomorrow trace")
        }
        store.undo()
        guard store.engine.traces[traceID]?.status == .pending,
              store.engine.traces.values.contains(where: { $0.date == tomorrow }) == false,
              store.toast == "已撤销"
        else {
            throw UndoE2EAutomationError.failed("current continuation undo did not restore the source trace")
        }
    }

    @MainActor
    private func verifyCurrentAbandonUndo(on store: NoonmarkStore) throws {
        reset(store)
        let traceID = try makeTrace(title: "E2E 撤销当前废弃", date: store.today, today: store.today, store: store)
        store.abandon(traceID)
        guard store.engine.traces[traceID]?.status == .abandoned else {
            throw UndoE2EAutomationError.failed("current abandon did not abandon trace")
        }
        store.undo()
        guard let restoredTrace = store.engine.traces[traceID],
              restoredTrace.status == .pending,
              store.engine.chains[restoredTrace.chainID]?.state == .active,
              store.toast == "已撤销"
        else {
            throw UndoE2EAutomationError.failed("current abandon undo did not reactivate the chain")
        }
    }

    @MainActor
    private func verifyNoteUndoKeepsEarlierUndo(on store: NoonmarkStore) throws {
        reset(store)
        let noteChainID = try store.engine.createPoolTask(title: "E2E 附言所属任务")
        store.poolText = "E2E 较早的可撤销操作"
        store.addPoolTask()
        store.detailNoteText = "E2E 后发生的附言操作"
        store.appendPoolNote(chainID: noteChainID)
        let noteID = try unwrap(
            store.engine.chains[noteChainID]?.activeNoteEntries.first?.id,
            "note appended after earlier undoable action"
        )

        store.undo()
        guard store.engine.chains[noteChainID]?.noteEntries.first(where: {
            $0.id == noteID
        })?.isDeleted == true else {
            throw UndoE2EAutomationError.failed("first undo did not tombstone the later note")
        }

        store.undo()

        guard store.engine.taskPool().map(\.chain.id) == [noteChainID],
              store.engine.chains[noteChainID]?.noteEntries.first(where: {
                  $0.id == noteID
              })?.isDeleted == true,
              store.toast == "已撤销"
        else {
            throw UndoE2EAutomationError.failed("note undo discarded or poisoned the earlier undo entry")
        }
    }

    @MainActor
    private func verifyFutureRescheduleUndo(on store: NoonmarkStore) throws {
        reset(store)
        let tomorrow = NoonmarkStore.offset(store.today, by: 1)
        let nextWeek = NoonmarkStore.offset(store.today, by: 7)
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
    private func verifyCopyAsNewTaskUndo(on store: NoonmarkStore) throws {
        reset(store)
        let past = NoonmarkStore.offset(store.today, by: -1)
        let traceID = try makeTrace(title: "E2E 撤销复制新任务", date: past, today: past, store: store)
        let sourceChainID = try unwrap(
            store.engine.traces[traceID]?.chainID,
            "classified copy source chain"
        )
        _ = try store.replaceTaskClassification(
            chainID: sourceChainID,
            category: .new(name: "E2E 已分类来源", colorHex: "#2A6FDB"),
            labels: [.new(name: "E2E 复制标签", colorHex: "#0E9488")]
        )
        try store.engine.markCompleted(traceID: traceID, today: past)
        try store.engine.settleDays(upTo: store.today)
        let beforeCopy = store.engine.snapshot()
        guard case let .task(sourceClassification) = try store.engine.classification(
            .task(sourceChainID)
        ),
            sourceClassification.category?.name == "E2E 已分类来源",
            sourceClassification.labels.map(\.name) == ["E2E 复制标签"],
            case let .history(sourceHistory) = try store.engine.classification(
                .history(traceID)
            ),
            sourceHistory.category?.name == "E2E 已分类来源",
            sourceHistory.labels.map(\.name) == ["E2E 复制标签"]
        else {
            throw UndoE2EAutomationError.failed(
                "copy source fixture did not contain faithful current and historical classification"
            )
        }

        store.clearUndoHistory()
        store.copyAsNewTask(traceID)
        let copiedChainID = try unwrap(
            store.engine.taskPool().first?.chain.id,
            "classified copied pool task"
        )
        guard copiedChainID != sourceChainID,
              case let .task(copiedClassification) = try store.engine.classification(
                  .task(copiedChainID)
              ),
              copiedClassification.category?.name == "E2E 已分类来源",
              copiedClassification.labels.map(\.name) == ["E2E 复制标签"]
        else {
            throw UndoE2EAutomationError.failed(
                "copy as new task did not create a classified pool task"
            )
        }

        store.undo()
        let afterUndo = store.engine.snapshot()
        try afterUndo.validateIntegrity()
        let copiedAfterUndo = try taskProjection(
            store.engine.classification(.task(copiedChainID))
        )
        let sourceAfterUndo = try taskProjection(
            store.engine.classification(.task(sourceChainID))
        )
        let sourceHistoryAfter = try historyProjection(
            store.engine.classification(.history(traceID))
        )
        guard store.engine.taskPool().isEmpty,
              store.engine.chains[copiedChainID]?.state == .abandoned,
              store.engine.definitions.values.contains(where: {
                  $0.chainID == copiedChainID
              }),
              store.engine.traces.values.contains(where: {
                  $0.chainID == copiedChainID
              }) == false,
              store.engine.traces[traceID]?.status == .completed,
              store.engine.chains[sourceChainID] == beforeCopy.chains.first(where: {
                  $0.id == sourceChainID
              }),
              copiedAfterUndo.category == nil,
              copiedAfterUndo.labels.isEmpty,
              sourceAfterUndo.category?.name == sourceClassification.category?.name,
              sourceAfterUndo.labels.map(\.name) == sourceClassification.labels.map(\.name),
              sourceHistoryAfter == sourceHistory,
              afterUndo.classifications.changeRecords.starts(
                  with: beforeCopy.classifications.changeRecords
              ),
              afterUndo.classifications.revision
                  == beforeCopy.classifications.revision + 2,
              store.toast == "已撤销"
        else {
            throw UndoE2EAutomationError.failed(
                "classified copy undo did not hide the copy with an append-only compensation"
            )
        }
    }

    @MainActor
    private func verifyUnclassifiedCopyAsNewTaskUndo(
        on store: NoonmarkStore
    ) throws {
        reset(store)
        let past = NoonmarkStore.offset(store.today, by: -1)
        let traceID = try makeTrace(
            title: "E2E 撤销未分类复制新任务",
            date: past,
            today: past,
            store: store
        )
        try store.engine.markCompleted(traceID: traceID, today: past)
        store.copyAsNewTask(traceID)
        let copiedChainID = try unwrap(
            store.engine.taskPool().first?.chain.id,
            "unclassified copied pool task"
        )

        store.undo()
        guard store.engine.taskPool().isEmpty,
              store.engine.chains[copiedChainID] == nil,
              store.engine.definitions.values.contains(where: {
                  $0.chainID == copiedChainID
              }) == false,
              store.engine.traces[traceID]?.status == .completed,
              store.toast == "已撤销"
        else {
            throw UndoE2EAutomationError.failed(
                "unclassified copy undo did not delete the isolated copy"
            )
        }
    }

    private func taskProjection(
        _ projection: ClassificationProjection
    ) throws -> TaskClassificationProjection {
        guard case let .task(task) = projection else {
            throw UndoE2EAutomationError.failed(
                "missing task classification projection"
            )
        }
        return task
    }

    private func historyProjection(
        _ projection: ClassificationProjection
    ) throws -> TraceClassificationProjection {
        guard case let .history(history) = projection else {
            throw UndoE2EAutomationError.failed(
                "missing trace classification projection"
            )
        }
        return history
    }

    @MainActor
    private func verifyHistoricalAbandonIsNotUndoable(on store: NoonmarkStore) throws {
        reset(store)
        let past = NoonmarkStore.offset(store.today, by: -1)
        let traceID = try makeTrace(title: "E2E 历史废弃不可撤销", date: past, today: past, store: store)
        try store.engine.settleDays(upTo: store.today)
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
    private func makeTrace(title: String, date: LocalDate, today: LocalDate, store: NoonmarkStore) throws -> DayTraceID {
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

    private func unwrap<Value>(_ value: Value?, _ label: String) throws -> Value {
        guard let value else {
            throw UndoE2EAutomationError.failed("missing \(label)")
        }
        return value
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
        let resultURL = NoonmarkStore.commandLineValue(after: "--e2e-date-strip-result-url")
            .map { URL(fileURLWithPath: $0) }
        return DateStripE2EAutomation(resultURL: resultURL)
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            store.page = .day
            store.selectedDate = store.today
            guard store.dateStripDates().count == 14,
                  store.selectedDateStripIndex == 6
            else {
                throw DateStripE2EAutomationError.failed("today index did not match 14-day strip")
            }

            store.selectedDate = NoonmarkStore.offset(store.today, by: 1)
            guard store.selectedDateStripIndex == 7 else {
                throw DateStripE2EAutomationError.failed("next-day index did not move by one cell")
            }

            store.selectedDate = NoonmarkStore.offset(store.today, by: -6)
            guard store.selectedDateStripIndex == 0 else {
                throw DateStripE2EAutomationError.failed("leading strip date did not map to first cell")
            }

            store.selectedDate = NoonmarkStore.offset(store.today, by: 8)
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
        let resultURL = NoonmarkStore.commandLineValue(after: "--e2e-keyboard-date-result-url")
            .map { URL(fileURLWithPath: $0) }
        return KeyboardDateNavigationE2EAutomation(resultURL: resultURL)
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            try verifyDayTodoNavigation(on: store)
            try verifyCalendarNavigation(on: store)
            try writeResult("ok")
        } catch {
            try? writeResult("failed: \(error)")
        }
    }

    @MainActor
    private func verifyDayTodoNavigation(on store: NoonmarkStore) throws {
        store.page = .day
        store.selectedDate = store.today
        store.moveSelectedDate(.right)
        try expect(store.selectedDate == NoonmarkStore.offset(store.today, by: 1), "day right arrow did not move by one day")
        store.moveSelectedDate(.left)
        try expect(store.selectedDate == store.today, "day left arrow did not return to today")
        store.moveSelectedDate(.down)
        try expect(store.selectedDate == NoonmarkStore.offset(store.today, by: 7), "day down arrow did not move by one week")
        store.moveSelectedDate(.up)
        try expect(store.selectedDate == store.today, "day up arrow did not return to today")
    }

    @MainActor
    private func verifyCalendarNavigation(on store: NoonmarkStore) throws {
        store.page = .calendar
        store.selectedCalendarDate = store.today
        store.moveSelectedDate(.right)
        try expect(store.selectedCalendarDate == NoonmarkStore.offset(store.today, by: 1), "calendar right arrow did not move by one day")
        store.moveSelectedDate(.left)
        try expect(store.selectedCalendarDate == store.today, "calendar left arrow did not return to today")
        store.moveSelectedDate(.down)
        try expect(store.selectedCalendarDate == NoonmarkStore.offset(store.today, by: 7), "calendar down arrow did not move by one week")
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
        let resultURL = NoonmarkStore.commandLineValue(after: "--e2e-zhulong-navigation-result-url")
            .map { URL(fileURLWithPath: $0) }
        return ZhulongNavigationE2EAutomation(resultURL: resultURL)
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            store.zhulongProviderDraft.enabled = false
            store.ensureVisiblePage()
            try expect(store.visibleNavigationPages.contains(.zhulong), "local-mode zhulong entry was hidden")
            store.selectPage(.zhulong)
            try expect(store.page == .zhulong, "local-mode zhulong selection did not open the page")

            store.zhulongProviderDraft.enabled = true
            try expect(store.visibleNavigationPages.contains(.zhulong), "enabled zhulong was not visible")
            store.selectPage(.zhulong)
            try expect(store.page == .zhulong, "enabled zhulong selection did not open the page")
            store.zhulongWorkspace.showHome()
            try expect(store.shouldShowDetailRail == false, "empty zhulong home kept the detail rail visible")
            try expect(ZhulongHomeIntentResolver.task(for: "结束今天并安排明天") == .dailyReview, "review intent was routed incorrectly")
            try expect(ZhulongHomeIntentResolver.task(for: "给任务池重新排期") == .scheduling, "scheduling intent was routed incorrectly")
            try expect(ZhulongHomeIntentResolver.task(for: "帮我整理分组") == .classification, "group intent was routed incorrectly")
            try expect(ZhulongHomeIntentResolver.task(for: "整理标签") == .classification, "label intent was routed incorrectly")
            try expect(ZhulongHomeIntentResolver.task(for: "梳理一个模糊任务") == .taskDecomposition, "default intent was routed incorrectly")

            let sessionCount = store.zhulongWorkspace.sessions.count
            store.startZhulongWorkspaceSession(intent: "结束今天并安排明天")
            try expect(store.zhulongWorkspace.sessions.count == sessionCount + 1, "workspace session was not created")
            try expect(store.zhulongWorkspace.selectedSession?.phase == .scopeReview, "new session bypassed scope review")
            try expect(store.zhulongWorkspace.selectedSession?.purpose == .dailyClose, "freeform daily close lost its purpose")
            store.authorizeCurrentZhulongWorkspaceSession()
            try expect(store.zhulongWorkspace.selectedSession?.phase == .readyForProvider, "scope authorization was not persisted")

            store.zhulongProviderDraft.enabled = false
            store.ensureVisiblePage()
            try expect(store.visibleNavigationPages.contains(.zhulong), "local-mode zhulong entry was hidden")
            try expect(store.page == .zhulong, "local mode unexpectedly left the zhulong workspace")

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
        let resultURL = NoonmarkStore.commandLineValue(after: "--e2e-subtask-mutation-result-url")
            .map { URL(fileURLWithPath: $0) }
        return SubtaskMutationE2EAutomation(resultURL: resultURL)
    }

    @MainActor
    func run(on store: NoonmarkStore) {
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
        let resultURL = NoonmarkStore.commandLineValue(after: "--e2e-window-resize-result-url")
            .map { URL(fileURLWithPath: $0) }
        return WindowResizeE2EAutomation(resultURL: resultURL)
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            guard let window = NSApp.windows.first(where: { $0 is NoonmarkWindow }) else {
                throw WindowResizeE2EAutomationError.failed("missing NoonmarkWindow")
            }
            guard window.styleMask.contains(.resizable) else {
                throw WindowResizeE2EAutomationError.failed("window was not resizable")
            }
            guard window.minSize == NoonmarkVisualMetrics.minimumSize else {
                throw WindowResizeE2EAutomationError.failed(
                    "window minSize was not preserved: actual=\(NSStringFromSize(window.minSize)) " +
                        "content=\(NSStringFromSize(window.contentMinSize)) " +
                        "expected=\(NSStringFromSize(NoonmarkVisualMetrics.minimumSize))"
                )
            }
            guard Int(window.frame.width.rounded()) == Int(NoonmarkVisualMetrics.launchSize.width),
                  Int(window.frame.height.rounded()) == Int(NoonmarkVisualMetrics.launchSize.height)
            else {
                throw WindowResizeE2EAutomationError.failed("window launch size was not preserved")
            }

            let originalFrame = window.frame
            let resizedFrame = NSRect(
                x: originalFrame.minX,
                y: originalFrame.maxY - NoonmarkVisualMetrics.minimumSize.height,
                width: NoonmarkVisualMetrics.minimumSize.width,
                height: NoonmarkVisualMetrics.minimumSize.height
            )
            window.setFrame(resizedFrame, display: true)
            guard Int(window.frame.width.rounded()) == Int(NoonmarkVisualMetrics.minimumSize.width),
                  Int(window.frame.height.rounded()) == Int(NoonmarkVisualMetrics.minimumSize.height)
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

private struct WindowCloseBehaviorE2EAutomation: LaunchAutomationRunnable {
    var resultURL: URL?

    @MainActor
    static func fromCommandLine() -> WindowCloseBehaviorE2EAutomation? {
        guard CommandLine.arguments.contains("--e2e-window-close-behavior-probe") else { return nil }
        let resultURL = NoonmarkStore.commandLineValue(after: "--e2e-window-close-behavior-result-url")
            .map { URL(fileURLWithPath: $0) }
        return WindowCloseBehaviorE2EAutomation(resultURL: resultURL)
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        Task { @MainActor in
            do {
                guard let delegate = NSApp.delegate as? NoonmarkMacApp else {
                    throw WindowCloseBehaviorE2EAutomationError.failed("missing app delegate")
                }
                guard delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp) == false else {
                    throw WindowCloseBehaviorE2EAutomationError.failed("closing last window would terminate app")
                }
                guard let window = NSApp.windows.first(where: { $0 is NoonmarkWindow }) else {
                    throw WindowCloseBehaviorE2EAutomationError.failed("missing NoonmarkWindow")
                }

                window.performClose(nil)
                try await Task.sleep(nanoseconds: 250_000_000)

                let visibleNoonmarkWindows = NSApp.windows.filter { $0 is NoonmarkWindow && $0.isVisible }
                guard visibleNoonmarkWindows.isEmpty else {
                    throw WindowCloseBehaviorE2EAutomationError.failed("window remained visible after close")
                }

                delegate.openMainWindow()
                try await Task.sleep(nanoseconds: 250_000_000)

                guard NSApp.windows.contains(where: { $0 is NoonmarkWindow && $0.isVisible }) else {
                    throw WindowCloseBehaviorE2EAutomationError.failed("window did not reopen after dock activation")
                }

                try writeResult("ok")
            } catch {
                try? writeResult("failed: \(error.localizedDescription)")
            }

            store.persist()
            NSApp.terminate(nil)
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

private enum WindowCloseBehaviorE2EAutomationError: LocalizedError {
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
        let resultURL = NoonmarkStore.commandLineValue(after: "--e2e-summary-sidebar-result-url")
            .map { URL(fileURLWithPath: $0) }
        return SummarySidebarE2EAutomation(resultURL: resultURL)
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            store.page = .pool
            store.clearSelection()
            store.zhulongProviderDraft.enabled = false
            guard store.usesZhulongContextRail, store.shouldShowDetailRail else {
                throw SummarySidebarE2EAutomationError.failed("local-mode context rail was unavailable")
            }

            for page in [NoonmarkStore.Page.pool, .future, .unfinished, .completed] {
                store.page = page
                store.clearSelection()
                guard store.usesZhulongContextRail, store.shouldShowDetailRail else {
                    throw SummarySidebarE2EAutomationError.failed("\(page.rawValue) zhulong context rail was unavailable")
                }
            }

            store.page = .pool
            if let task = store.engine.taskPool().first {
                store.selectPool(task.chain.id)
            }
            guard store.hasActiveDetailSelection, store.shouldShowDetailRail else {
                throw SummarySidebarE2EAutomationError.failed("selection detail rail did not override local analysis")
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
              let exportPath = NoonmarkStore.commandLineValue(after: "--e2e-data-package-url")
        else {
            return nil
        }
        let resultURL = NoonmarkStore.commandLineValue(after: "--e2e-data-package-result-url")
            .map { URL(fileURLWithPath: $0) }
        return DataPackageE2EAutomation(
            exportURL: URL(fileURLWithPath: exportPath),
            resultURL: resultURL
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
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

            store.engine = NoonmarkEngine()
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

struct TaskNoteE2EState: Codable {
    let chainID: TaskChainID
    let definitionID: TaskDefinitionID
    let traceID: DayTraceID
    let editedNoteID: TaskNoteEntryID
    let deletedNoteID: TaskNoteEntryID
}

private struct TaskNoteE2EAutomation: LaunchAutomationRunnable {
    private enum Mode {
        case mutate
        case verify
        case copyContract
    }

    private static let title = "E2E 附言编辑删除"
    private static let editedBody = "VISIBLE NOTE 7263"
    private static let deletedBody = "GHOST NOTE 9184"

    private let mode: Mode?
    let stateURL: URL?
    let resultURL: URL?

    @MainActor
    static func fromCommandLine() -> TaskNoteE2EAutomation? {
        let shouldMutate = CommandLine.arguments.contains("--e2e-task-note-mutate")
        let shouldVerify = CommandLine.arguments.contains("--e2e-task-note-verify")
        let shouldVerifyCopy = CommandLine.arguments.contains("--e2e-task-note-copy-contract")
        guard shouldMutate || shouldVerify || shouldVerifyCopy else { return nil }

        let mode: Mode? = switch (shouldMutate, shouldVerify, shouldVerifyCopy) {
        case (true, false, false): .mutate
        case (false, true, false): .verify
        case (false, false, true): .copyContract
        default: nil
        }
        return TaskNoteE2EAutomation(
            mode: mode,
            stateURL: NoonmarkStore.commandLineValue(after: "--e2e-task-note-state-url")
                .map { URL(fileURLWithPath: $0) },
            resultURL: NoonmarkStore.commandLineValue(after: "--e2e-task-note-result-url")
                .map { URL(fileURLWithPath: $0) }
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            guard let mode, let stateURL, let resultURL else {
                throw TaskNoteE2EAutomationError.failed("missing or conflicting task-note automation arguments")
            }
            switch mode {
            case .mutate:
                let state = try prepareUIInteraction(on: store, stateURL: stateURL)
                TaskNoteE2EUIInteractionDriver.start(
                    state: state,
                    editedBody: Self.editedBody,
                    resultURL: resultURL
                )
            case .verify:
                try verify(on: store, stateURL: stateURL)
                try writeResult("ok", to: resultURL)
            case .copyContract:
                try verify(on: store, stateURL: stateURL)
                store.setLanguage(.english)
                let state = try readState(from: stateURL)
                TaskNoteCopyE2EUIInteractionDriver.start(
                    state: state,
                    resultURL: resultURL
                )
            }
        } catch {
            try? writeResult("failed: \(error.localizedDescription)", to: resultURL)
            switch mode {
            case .mutate, .copyContract:
                DispatchQueue.main.async {
                    NSApp.terminate(nil)
                }
            case .verify, nil:
                break
            }
        }
    }

    @MainActor
    private func prepareUIInteraction(
        on store: NoonmarkStore,
        stateURL: URL
    ) throws -> TaskNoteE2EState {
        guard store.engine.chains.isEmpty,
              store.engine.definitions.isEmpty,
              store.engine.traces.isEmpty
        else {
            throw TaskNoteE2EAutomationError.failed("isolated task-note database was not empty")
        }

        store.page = .pool
        store.poolText = Self.title
        store.addPoolTask()
        guard let chainID = store.selectedPoolChainID,
              let initialChain = store.engine.chains[chainID],
              initialChain.activeNoteEntries.count == 1
        else {
            throw TaskNoteE2EAutomationError.failed("task-note fixture was not created in the task pool")
        }

        store.detailNoteText = Self.deletedBody
        store.appendPoolNote(chainID: chainID)
        guard let chain = store.engine.chains[chainID],
              let definition = store.currentDefinition(for: chainID),
              chain.activeNoteEntries.count == 2,
              let editedNoteID = chain.activeNoteEntries.first?.id,
              let deletedNoteID = chain.activeNoteEntries.last?.id,
              editedNoteID != deletedNoteID
        else {
            throw TaskNoteE2EAutomationError.failed("task-note fixture did not contain two stable entries")
        }

        store.schedulePoolTask(chainID, date: store.today)
        guard let traceID = store.selectedTraceID,
              let scheduledTrace = store.engine.traces[traceID],
              scheduledTrace.definitionID == definition.id,
              scheduledTrace.activeNoteEntries.map(\.id) == [editedNoteID, deletedNoteID]
        else {
            throw TaskNoteE2EAutomationError.failed("task-note entries were not snapshotted into the Day Todo")
        }

        store.page = .day
        store.selectedDate = store.today
        store.selectedCalendarDate = store.today
        store.selectTrace(traceID)
        store.persist()
        let state = TaskNoteE2EState(
            chainID: chainID,
            definitionID: definition.id,
            traceID: traceID,
            editedNoteID: editedNoteID,
            deletedNoteID: deletedNoteID
        )
        try writeState(state, to: stateURL)
        return state
    }

    @MainActor
    private func verify(on store: NoonmarkStore, stateURL: URL) throws {
        let state = try readState(from: stateURL)
        guard let chain = store.engine.chains[state.chainID],
              chain.state == .active,
              let definition = store.engine.definitions[state.definitionID],
              definition.chainID == state.chainID,
              let trace = store.engine.traces[state.traceID],
              trace.chainID == state.chainID,
              trace.definitionID == state.definitionID,
              trace.noteEntries.count == 2,
              let editedEntry = trace.noteEntries.first(where: { $0.id == state.editedNoteID }),
              editedEntry.body == Self.editedBody,
              editedEntry.deletedAt == nil,
              editedEntry.updatedAt >= editedEntry.createdAt,
              let deletedEntry = trace.noteEntries.first(where: { $0.id == state.deletedNoteID }),
              deletedEntry.body.isEmpty,
              deletedEntry.deletedAt != nil,
              deletedEntry.updatedAt == deletedEntry.deletedAt,
              deletedEntry.updatedAt >= deletedEntry.createdAt,
              trace.activeNoteEntries.map(\.id) == [state.editedNoteID],
              chain.activeNoteEntries.count == 2,
              chain.activeNoteEntries.contains(where: {
                  $0.id == state.deletedNoteID && $0.body == Self.deletedBody
              })
        else {
            throw TaskNoteE2EAutomationError.failed("task-note state did not survive restart exactly")
        }

        store.page = .day
        store.selectedDate = store.today
        store.selectedCalendarDate = store.today
        store.selectTrace(state.traceID)
    }

    private func writeState(_ state: TaskNoteE2EState, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    private func readState(from url: URL) throws -> TaskNoteE2EState {
        try JSONDecoder().decode(TaskNoteE2EState.self, from: Data(contentsOf: url))
    }

    private func writeResult(_ result: String, to url: URL?) throws {
        guard let url else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: url, atomically: true, encoding: .utf8)
    }
}

private enum TaskNoteE2EAutomationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            message
        }
    }
}

struct TaskNoteMutationAtomicityE2EState: Codable {
    let baseline: NoonmarkSnapshot
    let poolChainID: TaskChainID
    let poolEditedNoteID: TaskNoteEntryID
    let poolDeletedNoteID: TaskNoteEntryID
    let traceID: DayTraceID
    let traceEditedNoteID: TaskNoteEntryID
    let traceDeletedNoteID: TaskNoteEntryID
}

private struct TaskNoteMutationAtomicityUIE2EAutomation: LaunchAutomationRunnable {
    let stateURL: URL?
    let resultURL: URL?

    @MainActor
    static func fromCommandLine() -> TaskNoteMutationAtomicityUIE2EAutomation? {
        guard CommandLine.arguments.contains(
            "--e2e-task-note-atomicity-ui-edit"
        ) else { return nil }
        return TaskNoteMutationAtomicityUIE2EAutomation(
            stateURL: NoonmarkStore.commandLineValue(
                after: "--e2e-task-note-atomicity-state-url"
            ).map { URL(fileURLWithPath: $0) },
            resultURL: NoonmarkStore.commandLineValue(
                after: "--e2e-task-note-atomicity-result-url"
            ).map { URL(fileURLWithPath: $0) }
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            guard let stateURL, let resultURL else {
                throw TaskNoteMutationAtomicityE2EError.failed(
                    "missing task-note atomicity UI arguments"
                )
            }
            let state = try JSONDecoder().decode(
                TaskNoteMutationAtomicityE2EState.self,
                from: Data(contentsOf: stateURL)
            )
            guard store.engine.snapshot() == state.baseline else {
                throw TaskNoteMutationAtomicityE2EError.failed(
                    "task-note atomicity UI fixture did not match the persisted baseline"
                )
            }
            store.page = .day
            store.selectedDate = store.today
            store.selectedCalendarDate = store.today
            store.selectTrace(state.traceID)
            try store.armPersistenceFailureForE2E()
            TaskNotePersistenceFailureUIE2EDriver.start(
                noteID: state.traceEditedNoteID,
                editedBody: "UNSAVED UI TRACE EDIT 4973",
                resultURL: resultURL
            )
        } catch {
            store.disarmPersistenceFailureForE2E()
            if let resultURL {
                try? FileManager.default.createDirectory(
                    at: resultURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? "failed: \(error.localizedDescription)".write(
                    to: resultURL,
                    atomically: true,
                    encoding: .utf8
                )
            }
            NSApp.terminate(nil)
        }
    }
}

private struct TaskNoteMutationAtomicityE2EAutomation: LaunchAutomationRunnable {
    private enum Mode {
        case exerciseFailures
        case verifyRestart
    }

    private static let poolOriginalBody = "POOL ORIGINAL NOTE 1832"
    private static let poolDeleteBody = "POOL DELETE TARGET 5471"
    private static let traceOriginalBody = "TRACE ORIGINAL NOTE 2604"
    private static let traceDeleteBody = "TRACE DELETE TARGET 8395"

    private let mode: Mode?
    let stateURL: URL?
    let resultURL: URL?

    @MainActor
    static func fromCommandLine() -> TaskNoteMutationAtomicityE2EAutomation? {
        let exercisesFailures = CommandLine.arguments.contains(
            "--e2e-task-note-atomicity-exercise"
        )
        let verifiesRestart = CommandLine.arguments.contains(
            "--e2e-task-note-atomicity-verify"
        )
        guard exercisesFailures || verifiesRestart else { return nil }

        let mode: Mode? = switch (exercisesFailures, verifiesRestart) {
        case (true, false): .exerciseFailures
        case (false, true): .verifyRestart
        default: nil
        }
        return TaskNoteMutationAtomicityE2EAutomation(
            mode: mode,
            stateURL: NoonmarkStore.commandLineValue(
                after: "--e2e-task-note-atomicity-state-url"
            ).map { URL(fileURLWithPath: $0) },
            resultURL: NoonmarkStore.commandLineValue(
                after: "--e2e-task-note-atomicity-result-url"
            ).map { URL(fileURLWithPath: $0) }
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            guard let mode, let stateURL, let resultURL else {
                throw TaskNoteMutationAtomicityE2EError.failed(
                    "missing or conflicting task-note atomicity arguments"
                )
            }
            switch mode {
            case .exerciseFailures:
                try exerciseFailures(on: store, stateURL: stateURL)
            case .verifyRestart:
                try verifyRestart(on: store, stateURL: stateURL)
            }
            try writeResult("ok", to: resultURL)
        } catch {
            if let resultURL {
                try? writeResult("failed: \(error.localizedDescription)", to: resultURL)
            }
        }
    }

    @MainActor
    private func exerciseFailures(
        on store: NoonmarkStore,
        stateURL: URL
    ) throws {
        guard store.engine.chains.isEmpty,
              store.engine.definitions.isEmpty,
              store.engine.traces.isEmpty
        else {
            throw TaskNoteMutationAtomicityE2EError.failed(
                "isolated task-note atomicity database was not empty"
            )
        }

        let base = Date(timeIntervalSinceReferenceDate: 804_600_000)
        let poolChainID = try store.engine.createPoolTask(
            title: "E2E 附言保存失败任务池",
            initialNoteBody: Self.poolOriginalBody,
            now: base
        )
        let poolEditedNoteID = try requiredNoteID(
            store.engine.chains[poolChainID]?.activeNoteEntries.first?.id,
            label: "pool edit target"
        )
        let poolDeletedNoteID = try store.engine.appendPoolNote(
            chainID: poolChainID,
            body: Self.poolDeleteBody,
            now: base.addingTimeInterval(1)
        )

        let traceChainID = try store.engine.createPoolTask(
            title: "E2E 附言保存失败日轨迹",
            initialNoteBody: Self.traceOriginalBody,
            now: base.addingTimeInterval(2)
        )
        let traceEditedNoteID = try requiredNoteID(
            store.engine.chains[traceChainID]?.activeNoteEntries.first?.id,
            label: "trace edit target"
        )
        let traceDeletedNoteID = try store.engine.appendPoolNote(
            chainID: traceChainID,
            body: Self.traceDeleteBody,
            now: base.addingTimeInterval(3)
        )
        let traceID = try store.engine.scheduleFromPool(
            chainID: traceChainID,
            date: store.today,
            today: store.today,
            now: base.addingTimeInterval(4)
        )
        store.persist()

        let baseline = store.engine.snapshot()
        try baseline.validateIntegrity()
        let state = TaskNoteMutationAtomicityE2EState(
            baseline: baseline,
            poolChainID: poolChainID,
            poolEditedNoteID: poolEditedNoteID,
            poolDeletedNoteID: poolDeletedNoteID,
            traceID: traceID,
            traceEditedNoteID: traceEditedNoteID,
            traceDeletedNoteID: traceDeletedNoteID
        )
        try writeState(state, to: stateURL)
        try verifyPersistedBaseline(baseline)

        var failures: [String] = []
        failures += rejectionFailures(
            label: "pool append",
            store: store,
            baseline: baseline,
            composerInput: "UNSAVED POOL APPEND 4136"
        ) {
            store.appendPoolNote(chainID: poolChainID)
        }
        failures += rejectionFailures(
            label: "pool edit",
            store: store,
            baseline: baseline,
            composerInput: "UNCHANGED POOL COMPOSER 7870"
        ) {
            store.editPoolNote(
                chainID: poolChainID,
                noteID: poolEditedNoteID,
                body: "UNSAVED POOL EDIT 6218"
            )
        }
        failures += rejectionFailures(
            label: "pool delete",
            store: store,
            baseline: baseline,
            composerInput: "UNCHANGED POOL DELETE COMPOSER 9465"
        ) {
            store.deletePoolNote(chainID: poolChainID, noteID: poolDeletedNoteID)
        }
        failures += rejectionFailures(
            label: "trace append",
            store: store,
            baseline: baseline,
            composerInput: "UNSAVED TRACE APPEND 3581"
        ) {
            store.appendTraceNote(traceID: traceID)
        }
        failures += rejectionFailures(
            label: "trace edit",
            store: store,
            baseline: baseline,
            composerInput: "UNCHANGED TRACE COMPOSER 1049"
        ) {
            store.editTraceNote(
                traceID: traceID,
                noteID: traceEditedNoteID,
                body: "UNSAVED TRACE EDIT 5724"
            )
        }
        failures += rejectionFailures(
            label: "trace delete",
            store: store,
            baseline: baseline,
            composerInput: "UNCHANGED TRACE DELETE COMPOSER 8357"
        ) {
            store.deleteTraceNote(traceID: traceID, noteID: traceDeletedNoteID)
        }

        guard failures.isEmpty else {
            throw TaskNoteMutationAtomicityE2EError.failed(
                failures.joined(separator: "; ")
            )
        }
        try verifyPersistedBaseline(baseline)
    }

    @MainActor
    private func rejectionFailures(
        label: String,
        store: NoonmarkStore,
        baseline: NoonmarkSnapshot,
        composerInput: String,
        mutation: () -> Void
    ) -> [String] {
        var failures: [String] = []
        store.engine = (try? NoonmarkEngine(snapshot: baseline)) ?? NoonmarkEngine()
        store.clearUndoHistory()
        store.detailNoteText = composerInput
        do {
            try store.armPersistenceFailureForE2E()
        } catch {
            return ["\(label) could not arm isolated save failure: \(error.localizedDescription)"]
        }

        mutation()
        store.disarmPersistenceFailureForE2E()
        if store.engine.snapshot() != baseline {
            failures.append("\(label) published an unpersisted engine mutation")
        }
        if store.detailNoteText != composerInput {
            failures.append("\(label) cleared user input after save failure")
        }
        if store.toast?.hasPrefix("保存失败：") != true {
            failures.append(
                "\(label) did not keep the save-failure message: \(store.toast ?? "missing")"
            )
        }

        store.engine = (try? NoonmarkEngine(snapshot: baseline)) ?? NoonmarkEngine()
        do {
            try store.armPersistenceFailureForE2E()
            store.undo()
            store.disarmPersistenceFailureForE2E()
            if store.toast != "没有可撤销的操作" {
                failures.append("\(label) changed the undo stack after save failure")
            }
        } catch {
            store.disarmPersistenceFailureForE2E()
            failures.append("\(label) undo-stack probe failed: \(error.localizedDescription)")
        }

        store.engine = (try? NoonmarkEngine(snapshot: baseline)) ?? NoonmarkEngine()
        store.clearUndoHistory()
        store.detailNoteText = composerInput
        return failures
    }

    @MainActor
    private func verifyRestart(
        on store: NoonmarkStore,
        stateURL: URL
    ) throws {
        let state = try readState(from: stateURL)
        let snapshot = store.engine.snapshot()
        try snapshot.validateIntegrity()
        guard snapshot == state.baseline,
              store.engine.chains[state.poolChainID]?.activeNoteEntries.map(\.id) == [
                  state.poolEditedNoteID,
                  state.poolDeletedNoteID
              ],
              store.engine.traces[state.traceID]?.activeNoteEntries.map(\.id) == [
                  state.traceEditedNoteID,
                  state.traceDeletedNoteID
              ]
        else {
            throw TaskNoteMutationAtomicityE2EError.failed(
                "failed task-note mutations changed restarted state"
            )
        }
    }

    @MainActor
    private func verifyPersistedBaseline(_ baseline: NoonmarkSnapshot) throws {
        guard let databasePath = NoonmarkStore.commandLineValue(after: "--data-url") else {
            throw TaskNoteMutationAtomicityE2EError.failed(
                "task-note atomicity E2E requires an explicit data URL"
            )
        }
        let persisted = try SQLiteEngineRepository(
            databaseURL: URL(fileURLWithPath: databasePath)
        ).load().snapshot()
        guard persisted == baseline else {
            throw TaskNoteMutationAtomicityE2EError.failed(
                "isolated SQLite state diverged from the in-memory baseline"
            )
        }
    }

    private func requiredNoteID(
        _ noteID: TaskNoteEntryID?,
        label: String
    ) throws -> TaskNoteEntryID {
        guard let noteID else {
            throw TaskNoteMutationAtomicityE2EError.failed("missing \(label)")
        }
        return noteID
    }

    private func writeState(
        _ state: TaskNoteMutationAtomicityE2EState,
        to url: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    private func readState(from url: URL) throws -> TaskNoteMutationAtomicityE2EState {
        try JSONDecoder().decode(
            TaskNoteMutationAtomicityE2EState.self,
            from: Data(contentsOf: url)
        )
    }

    private func writeResult(_ result: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: url, atomically: true, encoding: .utf8)
    }
}

private enum TaskNoteMutationAtomicityE2EError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            message
        }
    }
}

private struct TaskTitleDeleteE2EAutomation: LaunchAutomationRunnable {
    var resultURL: URL?

    @MainActor
    static func fromCommandLine() -> TaskTitleDeleteE2EAutomation? {
        guard CommandLine.arguments.contains("--e2e-task-title-delete-workflow") else { return nil }
        let resultURL = NoonmarkStore.commandLineValue(after: "--e2e-task-title-delete-result-url")
            .map { URL(fileURLWithPath: $0) }
        return TaskTitleDeleteE2EAutomation(resultURL: resultURL)
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            store.engine = NoonmarkEngine()
            let today = store.today
            let tomorrow = NoonmarkStore.offset(today, by: 1)
            let yesterday = NoonmarkStore.offset(today, by: -1)

            let poolChainID = try store.engine.createPoolTask(title: "E2E 任务池旧标题")
            let markdownTitle = "**E2E 任务池**\n软换行  \n硬换行"
            store.renamePoolTask(chainID: poolChainID, title: markdownTitle)
            try expect(store.engine.taskPool().first?.definition.title == markdownTitle, "pool title did not preserve Markdown lines")

            let deleteChainID = try store.engine.createPoolTask(title: "E2E 任务池删除")
            store.deletePoolTask(deleteChainID)
            try expect(store.engine.chains[deleteChainID] == nil, "unscheduled pool task was not deleted")

            let currentChainID = try store.engine.createPoolTask(title: "E2E 今日旧标题")
            let currentTraceID = try store.engine.scheduleFromPool(chainID: currentChainID, date: today, today: today)
            store.renameTraceTitle(traceID: currentTraceID, title: "E2E 今日新标题")
            let currentTrace = try trace(currentTraceID, in: store)
            try expect(currentTrace.status == .pending, "current rename changed trace status")
            try expect(store.definition(for: currentTrace)?.title == "E2E 今日新标题", "current title did not rename")
            try expect(store.engine.traces.values.allSatisfy { $0.status != .changed }, "rename created changed trace")

            let futureChainID = try store.engine.createPoolTask(title: "E2E 未来旧标题")
            let futureTraceID = try store.engine.scheduleFromPool(chainID: futureChainID, date: tomorrow, today: today)
            store.renameTraceTitle(traceID: futureTraceID, title: "E2E 未来新标题")
            try expect(store.definition(for: try trace(futureTraceID, in: store))?.title == "E2E 未来新标题", "future title did not rename")

            let returnedChainID = try store.engine.createPoolTask(title: "E2E 回池删除")
            let returnedTraceID = try store.engine.scheduleFromPool(chainID: returnedChainID, date: today, today: today)
            store.returnToPool(returnedTraceID)
            store.deletePoolTask(returnedChainID)
            try expect(store.engine.traces[returnedTraceID]?.status == .returnedToPool, "returned trace was deleted")
            try expect(store.engine.taskPool().contains { $0.chain.id == returnedChainID } == false, "returned chain remained in pool")

            let completedChainID = try store.engine.createPoolTask(title: "E2E 已完成旧标题")
            let completedTraceID = try store.engine.scheduleFromPool(chainID: completedChainID, date: today, today: today)
            try store.engine.markCompleted(traceID: completedTraceID, today: today)
            try expectThrows {
                try store.engine.renameTaskTitle(chainID: completedChainID, title: "E2E 已完成新标题", today: today)
            }

            let unfinishedChainID = try store.engine.createPoolTask(title: "E2E 未完成旧标题")
            _ = try store.engine.scheduleFromPool(chainID: unfinishedChainID, date: yesterday, today: yesterday)
            try store.engine.settleDays(upTo: today)
            try expectThrows {
                try store.engine.renameTaskTitle(chainID: unfinishedChainID, title: "E2E 未完成新标题", today: today)
            }

            try writeResult("ok")
        } catch {
            try? writeResult("failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func trace(_ id: DayTraceID, in store: NoonmarkStore) throws -> DayTrace {
        guard let trace = store.engine.traces[id] else {
            throw TaskTitleDeleteE2EAutomationError.failed("missing trace")
        }
        return trace
    }

    private func expect(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw TaskTitleDeleteE2EAutomationError.failed(message)
        }
    }

    private func expectThrows(_ operation: () throws -> Void) throws {
        do {
            try operation()
            throw TaskTitleDeleteE2EAutomationError.failed("operation unexpectedly succeeded")
        } catch let error as TaskTitleDeleteE2EAutomationError {
            throw error
        } catch {}
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

private enum TaskTitleDeleteE2EAutomationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

private struct QuickTaskReturnE2EAutomation: LaunchAutomationRunnable {
    let resultURL: URL
    let title: String

    @MainActor
    static func fromCommandLine() -> Self? {
        guard CommandLine.arguments.contains("--e2e-add-quick-task-with-return"),
              let resultPath = NoonmarkStore.commandLineValue(
                  after: "--e2e-add-quick-task-with-return-result-url"
              )
        else { return nil }
        let title = NoonmarkStore.commandLineValue(after: "--e2e-add-quick-task-with-return")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Self(resultURL: URL(fileURLWithPath: resultPath), title: title)
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        store.page = .day
        store.selectedDate = store.today
        store.quickText = title
        let eventSucceeded = MarkdownEditorKeyboardProbe.submitWithReturn {
            store.addQuickTask()
        }
        let taskExists = store.engine.getDayTodo(date: store.today).traces.contains { trace in
            store.definition(for: trace)?.title == title
        }
        let result = eventSucceeded && taskExists && store.quickText.isEmpty
            ? "ok"
            : "failed: event=\(eventSucceeded) task=\(taskExists) cleared=\(store.quickText.isEmpty)"
        try? result.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

private struct ReportedBugsE2EAutomation: LaunchAutomationRunnable {
    let resultURL: URL

    @MainActor
    static func fromCommandLine() -> Self? {
        guard CommandLine.arguments.contains("--e2e-reported-bugs"),
              let path = NoonmarkStore.commandLineValue(after: "--e2e-reported-bugs-result-url")
        else { return nil }
        return Self(resultURL: URL(fileURLWithPath: path))
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        var failures: [String] = []
        failures.append(contentsOf: MarkdownEditorKeyboardProbe.failures())
        exerciseTitleAndCompletion(on: store, failures: &failures)
        exerciseClassification(on: store, failures: &failures)
        exerciseGroupLifecycle(on: store, failures: &failures)
        let result = failures.isEmpty ? "ok" : "failed: " + failures.joined(separator: " | ")
        try? result.write(to: resultURL, atomically: true, encoding: .utf8)
    }

    @MainActor
    private func exerciseTitleAndCompletion(
        on store: NoonmarkStore,
        failures: inout [String]
    ) {
        guard let trace = store.engine.getDayTodo(date: store.today).traces.first(where: {
            store.definition(for: $0)?.title == "制作发布会主视觉"
        }) else {
            failures.append("missing subtask fixture")
            return
        }
        store.renameTraceTitle(traceID: trace.id, title: "第一行\n第二行\r\n第三行")
        let actualTitle = store.engine.traces[trace.id].flatMap(store.definition(for:))?.title
        if actualTitle != "第一行\n第二行\n第三行" {
            failures.append("title line breaks were not preserved: \(actualTitle ?? "nil")")
        }

        store.toggleComplete(trace.id)
        if store.engine.traces[trace.id]?.status != .pending {
            failures.append("parent with open subtasks completed")
        }
        if store.toast != "还有未完成子任务，完成全部子任务后才能完成父任务" {
            failures.append("parent completion leaked raw error: \(store.toast ?? "nil")")
        }
    }

    @MainActor
    private func exerciseClassification(
        on store: NoonmarkStore,
        failures: inout [String]
    ) {
        guard let task = store.engine.taskPool().first(where: {
            $0.definition.title == "预约年度体检"
        }), let current = store.currentClassification(for: task.chain.id),
        let category = current.category,
        current.labels.count == 2,
        let categoryID = UUID(uuidString: category.id),
        let remainingLabelID = UUID(uuidString: current.labels[1].id)
        else {
            failures.append("missing classification fixture")
            return
        }
        do {
            _ = try store.replaceTaskClassification(
                chainID: task.chain.id,
                category: .existing(TaskCategoryID(categoryID)),
                labels: [.existing(TaskLabelID(remainingLabelID))]
            )
        } catch {
            failures.append("label removal failed: \(error.localizedDescription)")
            return
        }

        guard let alternate = store.classificationCatalog()?.categories.first(where: {
            $0.lifecycle == .active && $0.id != category.id
        }), let alternateID = UUID(uuidString: alternate.id) else {
            failures.append("missing alternate group")
            return
        }
        do {
            _ = try store.replaceTaskClassification(
                chainID: task.chain.id,
                category: .existing(TaskCategoryID(alternateID)),
                labels: [.existing(TaskLabelID(remainingLabelID))]
            )
        } catch {
            failures.append("group switch failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func exerciseGroupLifecycle(
        on store: NoonmarkStore,
        failures: inout [String]
    ) {
        do {
            _ = try store.applyClassificationIntent(
                .createCategory(name: "临时分组", colorHex: "#D87831")
            )
            guard let created = store.classificationCatalog()?.categories.first(where: {
                $0.name == "临时分组"
            }), let rawID = UUID(uuidString: created.id) else {
                failures.append("group creation was not projected")
                return
            }
            let id = TaskCategoryID(rawID)
            _ = try store.applyClassificationIntent(.renameCategory(id, to: "已重命名分组"))
            _ = try store.applyClassificationIntent(.archiveCategory(id))
            _ = try store.applyClassificationIntent(.restoreCategory(id))
            _ = try store.applyClassificationIntent(.hardDeleteCategory(id))
            if store.classificationCatalog()?.categories.contains(where: { $0.id == created.id }) == true {
                failures.append("unused group was not discarded")
            }

            _ = try store.applyClassificationIntent(
                .createLabel(name: "临时标签", colorHex: "#0E9488")
            )
            guard let createdLabel = store.classificationCatalog()?.labels.first(where: {
                $0.name == "临时标签"
            }), let rawLabelID = UUID(uuidString: createdLabel.id) else {
                failures.append("label creation was not projected")
                return
            }
            let labelID = TaskLabelID(rawLabelID)
            _ = try store.applyClassificationIntent(.renameLabel(labelID, to: "已重命名标签"))
            _ = try store.applyClassificationIntent(.archiveLabel(labelID))
            _ = try store.applyClassificationIntent(.restoreLabel(labelID))
            _ = try store.applyClassificationIntent(.hardDeleteLabel(labelID))
            if store.classificationCatalog()?.labels.contains(where: { $0.id == createdLabel.id }) == true {
                failures.append("unused label was not discarded")
            }
        } catch {
            failures.append("group lifecycle failed: \(error.localizedDescription)")
        }
    }
}

private struct LifecycleE2EAutomation: LaunchAutomationRunnable {
    var resultURL: URL?

    @MainActor
    static func fromCommandLine() -> LifecycleE2EAutomation? {
        guard CommandLine.arguments.contains("--e2e-lifecycle-workflow") else { return nil }
        let resultURL = NoonmarkStore.commandLineValue(after: "--e2e-lifecycle-result-url")
            .map { URL(fileURLWithPath: $0) }
        return LifecycleE2EAutomation(resultURL: resultURL)
    }

    @MainActor
    func run(on store: NoonmarkStore) {
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
    private func runChangeFlow(on store: NoonmarkStore) throws {
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
    private func runReturnToPoolFlow(on store: NoonmarkStore) throws {
        let chainID = try store.engine.createPoolTask(title: "E2E 回池任务", descriptionText: "E2E 回池路径。")
        let traceID = try store.engine.scheduleFromPool(chainID: chainID, date: store.today, today: store.today)
        store.returnToPool(traceID)
    }

    @MainActor
    private func runAbandonFlow(on store: NoonmarkStore) throws {
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

private struct LifecycleRestartE2EAutomation: LaunchAutomationRunnable {
    var resultURL: URL?

    @MainActor
    static func fromCommandLine() -> Self? {
        guard CommandLine.arguments.contains("--e2e-lifecycle-restart-verify") else {
            return nil
        }
        let resultURL = NoonmarkStore.commandLineValue(
            after: "--e2e-lifecycle-result-url"
        ).map { URL(fileURLWithPath: $0) }
        return Self(resultURL: resultURL)
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            let definition = try required(
                store.engine.definitions.values.first {
                    $0.title == "E2E 废弃任务"
                },
                "reactivated definition was not loaded after restart"
            )
            let trace = try required(
                store.engine.traces.values.first {
                    $0.definitionID == definition.id
                },
                "reactivated trace was not loaded after restart"
            )
            let chain = try required(
                store.engine.chains[trace.chainID],
                "reactivated chain was not loaded after restart"
            )
            guard chain.state == .active,
                  trace.status == .pending,
                  trace.settledAt == nil
            else {
                throw LifecycleE2EAutomationError.failed(
                    "reactivated lifecycle facts changed after restart"
                )
            }
            try writeResult("ok")
        } catch {
            try? writeResult("failed: \(error.localizedDescription)")
        }
    }

    private func required<Value>(
        _ value: Value?,
        _ message: String
    ) throws -> Value {
        guard let value else {
            throw LifecycleE2EAutomationError.failed(message)
        }
        return value
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

private struct ReactivationAtomicityE2EState: Codable {
    let baseline: NoonmarkSnapshot
    let chainID: TaskChainID
    let traceID: DayTraceID
}

private struct ReactivationAtomicityE2EAutomation: LaunchAutomationRunnable {
    private enum Mode {
        case exerciseFailure
        case verifyRestart
    }

    private let mode: Mode?
    let stateURL: URL?
    let resultURL: URL?

    @MainActor
    static func fromCommandLine() -> Self? {
        let exercisesFailure = CommandLine.arguments.contains(
            "--e2e-reactivation-atomicity-exercise"
        )
        let verifiesRestart = CommandLine.arguments.contains(
            "--e2e-reactivation-atomicity-verify"
        )
        guard exercisesFailure || verifiesRestart else { return nil }
        let mode: Mode? = switch (exercisesFailure, verifiesRestart) {
        case (true, false): .exerciseFailure
        case (false, true): .verifyRestart
        default: nil
        }
        return Self(
            mode: mode,
            stateURL: NoonmarkStore.commandLineValue(
                after: "--e2e-reactivation-atomicity-state-url"
            ).map { URL(fileURLWithPath: $0) },
            resultURL: NoonmarkStore.commandLineValue(
                after: "--e2e-reactivation-atomicity-result-url"
            ).map { URL(fileURLWithPath: $0) }
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            guard let mode, let stateURL, let resultURL else {
                throw LifecycleE2EAutomationError.failed(
                    "missing or conflicting reactivation atomicity arguments"
                )
            }
            switch mode {
            case .exerciseFailure:
                try exerciseFailure(on: store, stateURL: stateURL)
            case .verifyRestart:
                try verifyRestart(on: store, stateURL: stateURL)
            }
            try writeResult("ok", to: resultURL)
        } catch {
            if let resultURL {
                try? writeResult("failed: \(error.localizedDescription)", to: resultURL)
            }
        }
    }

    @MainActor
    private func exerciseFailure(
        on store: NoonmarkStore,
        stateURL: URL
    ) throws {
        guard store.engine.chains.isEmpty,
              store.engine.definitions.isEmpty,
              store.engine.traces.isEmpty
        else {
            throw LifecycleE2EAutomationError.failed(
                "isolated reactivation atomicity database was not empty"
            )
        }

        let base = Date(timeIntervalSinceReferenceDate: 804_700_000)
        let chainID = try store.engine.createPoolTask(
            title: "E2E 重新启用保存失败",
            now: base
        )
        let traceID = try store.engine.scheduleFromPool(
            chainID: chainID,
            date: store.today,
            today: store.today,
            now: base.addingTimeInterval(1)
        )
        try store.engine.abandonChain(
            from: traceID,
            now: base.addingTimeInterval(2)
        )
        store.persist()
        let baseline = store.engine.snapshot()
        try baseline.validateIntegrity()
        try writeState(
            ReactivationAtomicityE2EState(
                baseline: baseline,
                chainID: chainID,
                traceID: traceID
            ),
            to: stateURL
        )

        store.clearUndoHistory()
        try store.armPersistenceFailureForE2E()
        let committed = store.reactivateAbandonedChain(from: traceID)
        store.disarmPersistenceFailureForE2E()
        guard committed == false,
              store.engine.snapshot() == baseline,
              store.toast?.hasPrefix("保存失败：") == true
        else {
            throw LifecycleE2EAutomationError.failed(
                "failed reactivation published state or success feedback"
            )
        }

        try store.armPersistenceFailureForE2E()
        store.undo()
        store.disarmPersistenceFailureForE2E()
        guard store.toast == "没有可撤销的操作" else {
            throw LifecycleE2EAutomationError.failed(
                "failed reactivation changed the undo stack"
            )
        }
        try verifyPersistedBaseline(baseline)
    }

    @MainActor
    private func verifyRestart(
        on store: NoonmarkStore,
        stateURL: URL
    ) throws {
        let state = try readState(from: stateURL)
        guard store.engine.snapshot() == state.baseline,
              store.engine.chains[state.chainID]?.state == .abandoned,
              store.engine.traces[state.traceID]?.status == .abandoned
        else {
            throw LifecycleE2EAutomationError.failed(
                "failed reactivation changed restarted lifecycle state"
            )
        }
    }

    @MainActor
    private func verifyPersistedBaseline(_ baseline: NoonmarkSnapshot) throws {
        guard let databasePath = NoonmarkStore.commandLineValue(after: "--data-url") else {
            throw LifecycleE2EAutomationError.failed(
                "reactivation atomicity E2E requires an explicit data URL"
            )
        }
        let persisted = try SQLiteEngineRepository(
            databaseURL: URL(fileURLWithPath: databasePath)
        ).load().snapshot()
        guard persisted == baseline else {
            throw LifecycleE2EAutomationError.failed(
                "failed reactivation changed isolated SQLite state"
            )
        }
    }

    private func writeState(
        _ state: ReactivationAtomicityE2EState,
        to url: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    private func readState(from url: URL) throws -> ReactivationAtomicityE2EState {
        try JSONDecoder().decode(
            ReactivationAtomicityE2EState.self,
            from: Data(contentsOf: url)
        )
    }

    private func writeResult(_ result: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct WorkflowE2EAutomation: LaunchAutomationRunnable {
    var title: String
    var resultURL: URL?

    @MainActor
    static func fromCommandLine() -> WorkflowE2EAutomation? {
        guard CommandLine.arguments.contains("--e2e-domain-workflow") else { return nil }
        let title = NoonmarkStore.commandLineValue(after: "--e2e-workflow-title") ?? "E2E 排期延续复盘"
        let resultURL = NoonmarkStore.commandLineValue(after: "--e2e-workflow-result-url")
            .map { URL(fileURLWithPath: $0) }
        return WorkflowE2EAutomation(title: title, resultURL: resultURL)
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            let tomorrow = NoonmarkStore.offset(store.today, by: 1)

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

        let expectedName = NoonmarkStore.commandLineValue(after: "--e2e-provider-name") ?? ""
        let expectedBaseURL = NoonmarkStore.commandLineValue(after: "--e2e-provider-base-url") ?? ""
        let expectedModel = NoonmarkStore.commandLineValue(after: "--e2e-provider-model") ?? ""
        let expectedAPIKey = NoonmarkStore.commandLineValue(after: "--e2e-provider-api-key") ?? ""
        let resultURL = NoonmarkStore.commandLineValue(after: "--e2e-provider-result-url")
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
    func run(on store: NoonmarkStore) {
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
    private func configureProvider(on store: NoonmarkStore) throws {
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
    private func verifyProvider(on store: NoonmarkStore) throws {
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

final class NoonmarkWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    override var canBecomeMain: Bool { true }
}

enum TaskClassificationDisplay: Equatable {
    case current(TaskClassificationProjection)
    case historical(TraceClassificationProjection)

    var category: ClassificationItemProjection? {
        switch self {
        case let .current(projection):
            projection.category
        case let .historical(projection):
            projection.category
        }
    }

    var labels: [ClassificationItemProjection] {
        switch self {
        case let .current(projection):
            projection.labels
        case let .historical(projection):
            projection.labels
        }
    }

    var isHistorical: Bool {
        if case .historical = self { return true }
        return false
    }

    var isEmpty: Bool {
        category == nil && labels.isEmpty
    }
}

private enum PersistenceFailureE2EError: LocalizedError {
    case injectedSaveFailure
    case unsafeFailpointRequest

    var errorDescription: String? {
        switch self {
        case .injectedSaveFailure:
            "E2E injected isolated persistence save failure"
        case .unsafeFailpointRequest:
            "save failpoint requires the E2E app, an explicit data URL, and its automation flag"
        }
    }
}

private struct EnginePersistenceCommitError: LocalizedError {
    let underlying: Error

    var errorDescription: String? {
        "保存失败：\(underlying.localizedDescription)"
    }
}

@MainActor
final class NoonmarkStore: ObservableObject {
    private enum NoteUndoOwner: Equatable {
        case trace(DayTraceID)
        case pool(TaskChainID)
    }

    private struct NoteIdentityRemap {
        let owner: NoteUndoOwner
        let oldID: TaskNoteEntryID
        let newID: TaskNoteEntryID
    }

    private enum UndoEntry {
        case snapshot(NoonmarkSnapshot)
        case copiedTask(snapshot: NoonmarkSnapshot, chainID: TaskChainID)
        case traceNoteAppend(traceID: DayTraceID, noteID: TaskNoteEntryID)
        case traceNoteEdit(
            traceID: DayTraceID,
            noteID: TaskNoteEntryID,
            previousBody: String
        )
        case traceNoteDelete(
            traceID: DayTraceID,
            noteID: TaskNoteEntryID,
            deletedBody: String
        )
        case poolNoteAppend(chainID: TaskChainID, noteID: TaskNoteEntryID)
        case poolNoteEdit(
            chainID: TaskChainID,
            noteID: TaskNoteEntryID,
            previousBody: String
        )
        case poolNoteDelete(
            chainID: TaskChainID,
            noteID: TaskNoteEntryID,
            deletedBody: String
        )

        var snapshot: NoonmarkSnapshot? {
            switch self {
            case let .snapshot(snapshot), let .copiedTask(snapshot, _):
                snapshot
            default:
                nil
            }
        }

        func remappingNoteIdentity(
            _ remap: NoteIdentityRemap
        ) -> UndoEntry {
            switch (remap.owner, self) {
            case let (.trace(expectedTraceID), .traceNoteAppend(traceID, noteID))
                where traceID == expectedTraceID && noteID == remap.oldID:
                .traceNoteAppend(traceID: traceID, noteID: remap.newID)
            case let (.trace(expectedTraceID), .traceNoteEdit(traceID, noteID, previousBody))
                where traceID == expectedTraceID && noteID == remap.oldID:
                .traceNoteEdit(
                    traceID: traceID,
                    noteID: remap.newID,
                    previousBody: previousBody
                )
            case let (.trace(expectedTraceID), .traceNoteDelete(traceID, noteID, deletedBody))
                where traceID == expectedTraceID && noteID == remap.oldID:
                .traceNoteDelete(
                    traceID: traceID,
                    noteID: remap.newID,
                    deletedBody: deletedBody
                )
            case let (.pool(expectedChainID), .poolNoteAppend(chainID, noteID))
                where chainID == expectedChainID && noteID == remap.oldID:
                .poolNoteAppend(chainID: chainID, noteID: remap.newID)
            case let (.pool(expectedChainID), .poolNoteEdit(chainID, noteID, previousBody))
                where chainID == expectedChainID && noteID == remap.oldID:
                .poolNoteEdit(
                    chainID: chainID,
                    noteID: remap.newID,
                    previousBody: previousBody
                )
            case let (.pool(expectedChainID), .poolNoteDelete(chainID, noteID, deletedBody))
                where chainID == expectedChainID && noteID == remap.oldID:
                .poolNoteDelete(
                    chainID: chainID,
                    noteID: remap.newID,
                    deletedBody: deletedBody
                )
            default:
                self
            }
        }
    }

    private struct ZhulongWorkflowRoute {
        let task: ZhulongTask
        let purpose: ZhulongSessionPurpose
    }

    private static let zhulongWorkflowRoutes = [
        ZhulongWorkflowRoute(task: .dailyReview, purpose: .dailyClose),
        ZhulongWorkflowRoute(task: .taskDecomposition, purpose: .taskShaping),
        ZhulongWorkflowRoute(task: .scheduling, purpose: .schedulingAssistance),
        ZhulongWorkflowRoute(task: .classification, purpose: .classificationAssistance),
        ZhulongWorkflowRoute(task: .habitInsight, purpose: .habitInsight),
        ZhulongWorkflowRoute(task: .theoryAnalysis, purpose: .theoryAnalysis)
    ]

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
            case "day":
                self = .day
            case "pool":
                self = .pool
            case "future":
                self = .future
            case "unfinished":
                self = .unfinished
            case "completed":
                self = .completed
            case "calendar":
                self = .calendar
            case "zhulong":
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

    @Published var engine = NoonmarkEngine()
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
    @Published var showingClassificationManager = false
    @Published var changeText = ""
    @Published var detailSubtaskText = ""
    @Published var detailNoteText = ""
    @Published var toast: String?
    @Published var zhulongProviderDraft = ZhulongProviderSettingsStore.load()
    @Published var reviewAutosaveMessage: String?
    @Published var isLocalFirstSyncing = false
    @Published var localFirstSyncMessage: String?

    let today = LocalDate("2026-07-05")
    private let repository: SQLiteEngineRepository?
    private let databaseURL: URL?
    private let syncDeviceID: SyncDeviceID?
    private let permitsPersistenceFailureE2E: Bool
    lazy var zhulongWorkspace = ZhulongWorkspaceStore(
        directoryURL: zhulongSidecarDirectoryURL,
        keySource: zhulongSidecarKeySource
    )
    private var toastTask: Task<Void, Never>?
    private var localFirstSyncAutomationTask: Task<Void, Never>?
    private var undoStack: [UndoEntry] = []
    private var persistenceFailuresRemainingForE2E = 0

    init() {
        permitsPersistenceFailureE2E = CommandLine.arguments.contains(
            "--e2e-persistence-failure-automation"
        )
            && Self.commandLineValue(after: "--data-url") != nil
            && Bundle.main.bundleIdentifier == "app.noonmark.mac.e2e"
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
        recoverPendingZhulongApplication()
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

    var isZhulongEnabled: Bool {
        true
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
        if page == .zhulong {
            return zhulongWorkspace.selectedSession != nil
        }
        if hasActiveDetailSelection {
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

    func isUnclassified(_ chainID: TaskChainID) -> Bool {
        guard let classification = currentClassification(for: chainID) else { return true }
        return classification.category == nil && classification.labels.isEmpty
    }

    func newTaskLabelSuggestions(for draft: String) -> [ClassificationCatalogItemProjection] {
        let selectedKeys = Set(parsedTaskDraft(draft).labelNames.map(ClassificationNameCanonicalizer.canonicalKey))
        return orderedActiveLabelSuggestions(
            query: lastHashQuery(in: draft),
            excludingCanonicalKeys: selectedKeys
        )
    }

    func shouldShowNewTaskLabelSuggestions(for draft: String) -> Bool {
        draft.contains("#")
            && lastHashQuery(in: draft) != nil
            && newTaskLabelSuggestions(for: draft).isEmpty == false
    }

    func completeLastHashToken(in draft: String, with labelName: String) -> String {
        guard let hashIndex = draft.lastIndex(of: "#") else {
            return "\(draft) #\(labelName)"
        }
        let prefix = draft[..<hashIndex]
        return "\(prefix)#\(labelName) "
    }

    private func orderedActiveLabelSuggestions(
        query: String?,
        excludingCanonicalKeys: Set<String>
    ) -> [ClassificationCatalogItemProjection] {
        let normalizedQuery = query?.trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespacesAndNewlines)) ?? ""
        return (classificationCatalog()?.labels ?? [])
            .filter { $0.lifecycle == .active }
            .filter { label in
                guard excludingCanonicalKeys.contains(ClassificationNameCanonicalizer.canonicalKey(label.name)) == false else {
                    return false
                }
                guard normalizedQuery.isEmpty == false else { return true }
                return label.name.localizedStandardContains(normalizedQuery)
            }
            .sorted { lhs, rhs in
                if lhs.currentUsageCount != rhs.currentUsageCount {
                    return lhs.currentUsageCount > rhs.currentUsageCount
                }
                return ClassificationNameCanonicalizer.canonicalKey(lhs.name)
                    < ClassificationNameCanonicalizer.canonicalKey(rhs.name)
            }
    }

    private func taskLabelChoices(for names: [String]) -> [TaskLabelChoice] {
        let activeLabels = (classificationCatalog()?.labels ?? []).filter { $0.lifecycle == .active }
        var seenKeys: Set<String> = []
        return names.compactMap { rawName in
            let name = ClassificationNameCanonicalizer.displayName(
                rawName.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            )
            let key = ClassificationNameCanonicalizer.canonicalKey(name)
            guard name.isEmpty == false, seenKeys.insert(key).inserted else { return nil }
            if let existing = activeLabels.first(where: {
                ClassificationNameCanonicalizer.canonicalKey($0.name) == key
            }), let id = UUID(uuidString: existing.id) {
                return .existing(TaskLabelID(id))
            }
            return .new(name: name, colorHex: "#0E9488")
        }
    }

    @discardableResult
    private func applyTaskDraftLabels(chainID: TaskChainID, labelNames: [String]) throws -> Bool {
        let choices = taskLabelChoices(for: labelNames)
        guard choices.isEmpty == false else { return false }
        _ = try replaceTaskClassification(chainID: chainID, category: nil, labels: choices)
        return true
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
        let originalSnapshot = engine.snapshot()
        do {
            pushUndoSnapshotIfAllowed(on: selectedDate)
            let chainID = try engine.createPoolTask(title: draft.title, descriptionText: "快速记录自 Day Todo。", now: Date())
            _ = try engine.scheduleFromPool(chainID: chainID, date: selectedDate, today: today)
            let savedWithClassification = try applyTaskDraftLabels(
                chainID: chainID,
                labelNames: draft.labelNames
            )
            if savedWithClassification == false {
                try save(engine)
            }
            invalidateUndoHistoryIfClassificationChanged()
            quickText = ""
            showToast("已添加「\(draft.title)」")
        } catch {
            if let restored = try? NoonmarkEngine(snapshot: originalSnapshot) {
                engine = restored
            }
            showToast(error.localizedDescription)
        }
    }

    func addPoolTask() {
        let draft = parsedTaskDraft(poolText)
        guard draft.title.isEmpty == false else { return }
        let originalSnapshot = engine.snapshot()
        do {
            pushUndoSnapshot()
            let chainID = try engine.createPoolTask(
                title: draft.title,
                descriptionText: "任务池中的待排期任务。",
                initialNoteBody: "可以排期到今天、明天或指定日期。"
            )
            let savedWithClassification = try applyTaskDraftLabels(
                chainID: chainID,
                labelNames: draft.labelNames
            )
            if savedWithClassification == false {
                try save(engine)
            }
            invalidateUndoHistoryIfClassificationChanged()
            selectedPoolChainID = chainID
            poolText = ""
            showToast("已加入任务池")
        } catch {
            if let restored = try? NoonmarkEngine(snapshot: originalSnapshot) {
                engine = restored
            }
            showToast(error.localizedDescription)
        }
    }

    private func parsedTaskDraft(_ rawText: String) -> (title: String, labelNames: [String]) {
        let raw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.isEmpty == false else { return ("", []) }
        let pattern = #"#([^\s#]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (raw, [])
        }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        let matches = regex.matches(in: raw, range: range)
        let labelNames = matches.compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: raw) else { return nil }
            let labelName = String(raw[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            return labelName.isEmpty ? nil : labelName
        }
        let title = regex.stringByReplacingMatches(
            in: raw,
            range: range,
            withTemplate: " "
        )
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
        return (title, labelNames)
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
        let hasOpenSubtasks = engine.subtaskProgress(for: traceID).canCompleteParent == false
        if trace.status == .pending && hasOpenSubtasks {
            showToast(NoonmarkError.openSubtasksPreventCompletion.localizedDescription)
            return
        }
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
            if let trace = engine.traces[traceID], trace.date > today {
                pushUndoSnapshotIfAllowed(on: trace.date)
            }
            try engine.returnToPool(traceID: traceID, today: today)
            page = .pool
            clearSelection()
            persist()
            showToast("已回池；当天轨迹会永久保留")
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
            showToast("任务链已废弃；可从未完成池重新启用")
        } catch {
            showToast(error.localizedDescription)
        }
    }

    @discardableResult
    func reactivateAbandonedChain(from traceID: DayTraceID) -> Bool {
        let undoSnapshot = engine.snapshot()
        do {
            _ = try commitEngineMutation { candidate in
                try candidate.reactivateAbandonedChain(from: traceID, today: today)
            }
            pushUndoEntry(with: .snapshot(undoSnapshot))
            showToast("已取消废弃")
            return true
        } catch {
            showToast(error.localizedDescription)
            return false
        }
    }

    func copyAsNewTask(_ traceID: DayTraceID) {
        let undoSnapshot = engine.snapshot()
        do {
            let candidate = try NoonmarkEngine(snapshot: undoSnapshot)
            let copiedChainID = try candidate.copyAsNewTask(
                from: traceID,
                target: .taskPool,
                today: today
            )
            try save(candidate)
            engine = candidate
            pushUndoEntry(
                with: .copiedTask(
                    snapshot: undoSnapshot,
                    chainID: copiedChainID
                )
            )
            page = .pool
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
            let newID = try engine.changeTrace(traceID: selectedTraceID, newTitle: title, today: today)
            showingChangeDialog = false
            changeText = ""
            selectTrace(newID)
            persist()
            showToast("已变更；原轨迹已成为历史，不能撤销")
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

    func updateTraceText(traceID: DayTraceID, descriptionText: String) {
        guard let trace = engine.traces[traceID] else { return }
        do {
            pushUndoSnapshotIfAllowed(on: trace.date)
            try engine.updateTraceText(
                traceID: traceID,
                descriptionText: descriptionText,
                today: today
            )
            objectWillChange.send()
            persist()
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func renameTraceTitle(traceID: DayTraceID, title: String) {
        guard let trace = engine.traces[traceID] else { return }
        let nextTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard nextTitle.isEmpty == false else { return }
        do {
            pushUndoSnapshotIfAllowed(on: trace.date)
            try engine.renameTaskTitle(chainID: trace.chainID, title: nextTitle, today: today)
            objectWillChange.send()
            persist()
            showToast("任务标题已更新")
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func renamePoolTask(chainID: TaskChainID, title: String) {
        let nextTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard nextTitle.isEmpty == false else { return }
        do {
            pushUndoSnapshot()
            try engine.renameTaskTitle(chainID: chainID, title: nextTitle, today: today)
            objectWillChange.send()
            persist()
            showToast("任务标题已更新")
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func updatePoolTaskText(chainID: TaskChainID, descriptionText: String) {
        guard let definition = currentDefinition(for: chainID) else { return }
        do {
            objectWillChange.send()
            try engine.updatePoolTask(
                chainID: chainID,
                title: definition.title,
                descriptionText: descriptionText
            )
            persist()
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func deletePoolTask(_ chainID: TaskChainID) {
        do {
            let workingEngine = try NoonmarkEngine(snapshot: engine.snapshot())
            let outcome = try workingEngine.removeTaskFromPool(chainID: chainID)
            try save(workingEngine)
            engine = workingEngine
            clearUndoHistory()
            if selectedPoolChainID == chainID {
                clearSelection()
            }
            let message = switch outcome {
            case .deleted:
                "已从任务池删除"
            case .removedKeepingHistory:
                "已移出任务池；分组、标签与任务历史已保留"
            }
            showToast(message)
        } catch {
            showToast("移出任务池失败：\(error.localizedDescription)")
        }
    }

    @discardableResult
    func appendTraceNote(traceID: DayTraceID) -> Bool {
        let body = detailNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.isEmpty == false, engine.traces[traceID] != nil else { return false }
        do {
            let noteID = try commitEngineMutation { candidate in
                try candidate.appendTraceNote(
                    traceID: traceID,
                    body: body,
                    today: today
                )
            }
            pushUndoEntry(
                with: .traceNoteAppend(traceID: traceID, noteID: noteID)
            )
            detailNoteText = ""
            return true
        } catch {
            showToast(error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func appendPoolNote(chainID: TaskChainID) -> Bool {
        let body = detailNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.isEmpty == false else { return false }
        do {
            let noteID = try commitEngineMutation { candidate in
                try candidate.appendPoolNote(chainID: chainID, body: body)
            }
            pushUndoEntry(
                with: .poolNoteAppend(chainID: chainID, noteID: noteID)
            )
            detailNoteText = ""
            return true
        } catch {
            showToast(error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func editTraceNote(
        traceID: DayTraceID,
        noteID: TaskNoteEntryID,
        body: String
    ) -> Bool {
        guard let trace = engine.traces[traceID],
              let previousBody = trace.activeNoteEntries.first(where: {
                  $0.id == noteID
              })?.body
        else { return false }
        do {
            try commitEngineMutation { candidate in
                try candidate.editTraceNote(
                    traceID: traceID,
                    noteID: noteID,
                    body: body,
                    today: today
                )
            }
            pushUndoEntry(
                with: .traceNoteEdit(
                    traceID: traceID,
                    noteID: noteID,
                    previousBody: previousBody
                )
            )
            return true
        } catch {
            showToast(error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func deleteTraceNote(traceID: DayTraceID, noteID: TaskNoteEntryID) -> Bool {
        guard let trace = engine.traces[traceID],
              let deletedBody = trace.activeNoteEntries.first(where: {
                  $0.id == noteID
              })?.body
        else { return false }
        do {
            try commitEngineMutation { candidate in
                try candidate.deleteTraceNote(
                    traceID: traceID,
                    noteID: noteID,
                    today: today
                )
            }
            pushUndoEntry(
                with: .traceNoteDelete(
                    traceID: traceID,
                    noteID: noteID,
                    deletedBody: deletedBody
                )
            )
            showToast(copy.noteDeletedToast)
            return true
        } catch {
            showToast(error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func editPoolNote(
        chainID: TaskChainID,
        noteID: TaskNoteEntryID,
        body: String
    ) -> Bool {
        guard let previousBody = engine.taskPool().first(where: {
            $0.chain.id == chainID
        })?.chain.activeNoteEntries.first(where: {
            $0.id == noteID
        })?.body else { return false }
        do {
            try commitEngineMutation { candidate in
                try candidate.editPoolNote(
                    chainID: chainID,
                    noteID: noteID,
                    body: body
                )
            }
            pushUndoEntry(
                with: .poolNoteEdit(
                    chainID: chainID,
                    noteID: noteID,
                    previousBody: previousBody
                )
            )
            return true
        } catch {
            showToast(error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func deletePoolNote(chainID: TaskChainID, noteID: TaskNoteEntryID) -> Bool {
        guard let deletedBody = engine.taskPool().first(where: {
            $0.chain.id == chainID
        })?.chain.activeNoteEntries.first(where: {
            $0.id == noteID
        })?.body else { return false }
        do {
            try commitEngineMutation { candidate in
                try candidate.deletePoolNote(chainID: chainID, noteID: noteID)
            }
            pushUndoEntry(
                with: .poolNoteDelete(
                    chainID: chainID,
                    noteID: noteID,
                    deletedBody: deletedBody
                )
            )
            showToast(copy.noteDeletedToast)
            return true
        } catch {
            showToast(error.localizedDescription)
            return false
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
        try NoonmarkDataPackage.write(engine.snapshot(), to: url)
    }

    func importDataPackage(from url: URL) throws {
        let snapshot = try NoonmarkDataPackage.read(from: url)

        pushUndoSnapshot()
        engine = try NoonmarkEngine(snapshot: snapshot)
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

    func startZhulongWorkspaceSession(intent: String) {
        let task = ZhulongHomeIntentResolver.task(for: intent)
        startZhulongWorkspaceSession(intent: intent, task: task)
    }

    func startZhulongWorkspaceSession(intent: String, task: ZhulongTask) {
        zhulongWorkspace.createSession(
            intent: intent,
            purpose: zhulongSessionPurpose(for: task),
            scopes: zhulongDataScopes(for: task)
        )
    }

    func zhulongTask(for session: ZhulongSession) -> ZhulongTask {
        if session.purpose == .freeform {
            return ZhulongHomeIntentResolver.task(for: session.primaryIntent)
        }
        guard let route = Self.zhulongWorkflowRoutes.first(where: {
            $0.purpose == session.purpose
        }) else {
            preconditionFailure("Missing Zhulong workflow route for purpose \(session.purpose.rawValue)")
        }
        return route.task
    }

    func recentZhulongSession(matching scopes: Set<ZhulongDataScope>) -> ZhulongSession? {
        zhulongWorkspace.sessions.first { session in
            session.workspaceStatus != .archived && scopes.isSubset(of: session.proposedScopes)
        }
    }

    func zhulongWorkspaceStatus(_ session: ZhulongSession) -> String {
        if session.workspaceStatus == .paused { return "已暂停" }
        if session.workspaceStatus == .archived { return "已归档" }
        return switch session.phase {
        case .scopeReview: "等待范围确认"
        case .readyForProvider: "范围已确认"
        case .providerRunning: "Provider 正在运行"
        case .decisionGate: "等待用户决定"
        case .draftReview: "草稿待审"
        }
    }

    func authorizeCurrentZhulongWorkspaceSession() {
        do {
            zhulongWorkspace.authorizeCurrentSession(
                providerIdentity: try zhulongProviderIdentity()
            )
        } catch {
            showToast("无法确认烛龙范围：\(error.localizedDescription)")
        }
    }

    func runCurrentZhulongProvider() {
        Task { @MainActor in
            await runCurrentZhulongProviderRequest()
        }
    }

    func runCurrentZhulongPlanningProvider() {
        Task { @MainActor in
            await runCurrentZhulongPlanningProviderRequest()
        }
    }

    func captureCurrentZhulongDailyClose() {
        zhulongWorkspace.captureDailyClose(date: today, from: engine)
    }

    func publishCurrentZhulongTodoDiff() {
        zhulongWorkspace.publishTodoDiff(from: engine, planningDate: today)
    }

    func confirmAndApplyCurrentZhulongTodoDiff() {
        if zhulongWorkspace.hasActiveTodoAuthorization == false {
            zhulongWorkspace.authorizeCurrentTodoDiff(against: engine, today: today)
        }
        guard zhulongWorkspace.hasActiveTodoAuthorization else { return }
        guard let updatedEngine = zhulongWorkspace.applyCurrentTodoDiff(
            to: engine,
            today: today,
            persistEngine: { [self] candidate in try save(candidate) }
        ) else { return }
        engine = updatedEngine
        invalidateUndoHistoryIfClassificationChanged()
        normalizeSelection()
        showToast("已原子应用 Todo diff")
    }

    func publishCurrentZhulongDailyReview(summary: String?, tomorrowNote: String?) {
        zhulongWorkspace.publishDailyReviewDraft(
            summary: summary,
            tomorrowNote: tomorrowNote
        )
    }

    func confirmAndSaveCurrentZhulongDailyReview(
        interruptAfterEnginePersisted: Bool = false
    ) {
        if zhulongWorkspace.hasActiveDailyReviewAuthorization == false {
            zhulongWorkspace.authorizeCurrentDailyReview(against: engine)
        }
        guard zhulongWorkspace.hasActiveDailyReviewAuthorization else { return }
        guard let updatedEngine = zhulongWorkspace.applyCurrentDailyReview(
            to: engine,
            persistEngine: { [self] candidate in try save(candidate) },
            interruptAfterEnginePersisted: interruptAfterEnginePersisted
        ) else { return }
        engine = updatedEngine
        normalizeSelection()
        showToast("已保存用户确认的每日复盘")
    }

    private func recoverPendingZhulongApplication() {
        guard repository != nil else { return }
        engine = zhulongWorkspace.recoverPendingApplication(
            currentEngine: engine,
            persistEngine: { [self] candidate in try save(candidate) }
        )
    }

    private func runCurrentZhulongProviderRequest() async {
        do {
            guard let session = zhulongWorkspace.selectedSession else {
                throw ZhulongProviderUIError.missingSession
            }
            let payload = try zhulongProviderPayload(for: session)
            await zhulongWorkspace.runCurrentSession(
                payload: payload,
                provider: try makeZhulongAIProviderAdapter()
            )
        } catch {
            showToast("无法运行 Provider：\(error.localizedDescription)")
        }
    }

    private func runCurrentZhulongPlanningProviderRequest() async {
        do {
            guard let session = zhulongWorkspace.selectedSession,
                  session.activePlanningDelegation != nil
            else {
                throw ZhulongProviderUIError.missingPlanningDelegation
            }
            let payload = try zhulongPlanningProviderPayload(for: session)
            await zhulongWorkspace.runCurrentPlanningSession(
                payload: payload,
                provider: try makeZhulongAIProviderAdapter()
            )
        } catch {
            showToast("无法运行规划 Provider：\(error.localizedDescription)")
        }
    }

    private func makeZhulongAIProviderAdapter() throws -> ZhulongAIProviderAdapter {
        guard zhulongProviderDraft.enabled else {
            throw ZhulongProviderUIError.providerDisabled
        }
        guard zhulongProviderDraft.kind == .openAICompatible else {
            throw ZhulongProviderUIError.unsupportedProviderKind
        }
        let config = try ZhulongProviderSettingsStore.makeConfig(from: zhulongProviderDraft)
        let upstream = OpenAICompatibleProvider(
            config: config,
            apiKeyResolver: { ref in
                guard ref == ZhulongProviderKeychain.keyRef else { return nil }
                return try ZhulongProviderKeychain.readAPIKey()
            }
        )
        return ZhulongAIProviderAdapter(
            configurationIdentity: try zhulongProviderIdentity(),
            upstream: upstream
        )
    }

    func requestZhulongDailyReviewFromReviewRail() {
        page = .zhulong
        startZhulongWorkspaceSession(intent: "结束今天并形成下一次可信承诺")
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
        guard let entry = undoStack.last else {
            showToast("没有可撤销的操作")
            return
        }
        let candidate: NoonmarkEngine
        var noteIdentityRemap: NoteIdentityRemap?
        do {
            let currentSnapshot = engine.snapshot()
            switch entry {
            case let .snapshot(snapshot):
                candidate = try NoonmarkEngine(snapshot: snapshot)
                try candidate.prepareSnapshotUndo(
                    replacing: currentSnapshot,
                    now: Date()
                )
            case let .copiedTask(_, copiedChainID):
                candidate = try NoonmarkEngine(snapshot: currentSnapshot)
                _ = try candidate.removeTaskFromPool(
                    chainID: copiedChainID,
                    now: try copiedTaskUndoDate(
                        chainID: copiedChainID,
                        in: candidate
                    )
                )
            case .traceNoteAppend, .traceNoteEdit, .traceNoteDelete,
                 .poolNoteAppend, .poolNoteEdit, .poolNoteDelete:
                candidate = try NoonmarkEngine(snapshot: currentSnapshot)
                noteIdentityRemap = try applyNoteUndo(entry, to: candidate)
            }
            try save(candidate)
        } catch {
            NSLog("Noonmark undo failed: %@", String(describing: error))
            showToast("无法撤销：\(error.localizedDescription)")
            return
        }
        undoStack.removeLast()
        if let noteIdentityRemap {
            undoStack = undoStack.map {
                $0.remappingNoteIdentity(noteIdentityRemap)
            }
        }
        engine = candidate
        Theme.apply(engine.preferences.theme)
        normalizeSelection()
        showToast("已撤销")
    }

    private func copiedTaskUndoDate(
        chainID: TaskChainID,
        in candidate: NoonmarkEngine
    ) throws -> Date {
        guard let chain = candidate.chains[chainID] else {
            throw NoonmarkError.notFound("copied task chain")
        }
        let chainFrontier = chain.updatedAt.timeIntervalSinceReferenceDate
        guard chainFrontier.isFinite, chainFrontier.nextUp.isFinite else {
            throw NoonmarkError.invalidInput("copied task undo time is invalid")
        }
        let afterChain = Date(
            timeIntervalSinceReferenceDate: chainFrontier.nextUp
        )
        return max(
            afterChain,
            candidate.nextClassificationMutationDate()
        )
    }

    private func applyNoteUndo(
        _ entry: UndoEntry,
        to candidate: NoonmarkEngine
    ) throws -> NoteIdentityRemap? {
        switch entry {
        case .snapshot, .copiedTask:
            throw NoonmarkError.invalidTransition("snapshot is not a note undo action")
        case let .traceNoteAppend(traceID, noteID):
            let trace = try noteUndoTrace(traceID, in: candidate)
            let note = try noteUndoEntry(noteID, in: trace.noteEntries)
            try candidate.deleteTraceNote(
                traceID: traceID,
                noteID: noteID,
                today: today,
                now: try forwardNoteUndoDate(after: [note.updatedAt])
            )
            return nil
        case let .traceNoteEdit(traceID, noteID, previousBody):
            let trace = try noteUndoTrace(traceID, in: candidate)
            let note = try noteUndoEntry(noteID, in: trace.noteEntries)
            try candidate.editTraceNote(
                traceID: traceID,
                noteID: noteID,
                body: previousBody,
                today: today,
                now: try forwardNoteUndoDate(after: [note.updatedAt])
            )
            return nil
        case let .traceNoteDelete(traceID, noteID, deletedBody):
            let trace = try noteUndoTrace(traceID, in: candidate)
            let newID = try candidate.appendTraceNote(
                traceID: traceID,
                body: deletedBody,
                today: today,
                now: try forwardNoteUndoDate(
                    after: [trace.createdAt] + trace.noteEntries.map(\.updatedAt)
                )
            )
            return NoteIdentityRemap(
                owner: .trace(traceID),
                oldID: noteID,
                newID: newID
            )
        case let .poolNoteAppend(chainID, noteID):
            let chain = try noteUndoChain(chainID, in: candidate)
            let note = try noteUndoEntry(noteID, in: chain.noteEntries)
            try candidate.deletePoolNote(
                chainID: chainID,
                noteID: noteID,
                now: try forwardNoteUndoDate(
                    after: [note.updatedAt, chain.updatedAt]
                )
            )
            return nil
        case let .poolNoteEdit(chainID, noteID, previousBody):
            let chain = try noteUndoChain(chainID, in: candidate)
            let note = try noteUndoEntry(noteID, in: chain.noteEntries)
            try candidate.editPoolNote(
                chainID: chainID,
                noteID: noteID,
                body: previousBody,
                now: try forwardNoteUndoDate(
                    after: [note.updatedAt, chain.updatedAt]
                )
            )
            return nil
        case let .poolNoteDelete(chainID, noteID, deletedBody):
            let chain = try noteUndoChain(chainID, in: candidate)
            let newID = try candidate.appendPoolNote(
                chainID: chainID,
                body: deletedBody,
                now: try forwardNoteUndoDate(
                    after: [chain.createdAt] + chain.noteEntries.map(\.updatedAt)
                )
            )
            return NoteIdentityRemap(
                owner: .pool(chainID),
                oldID: noteID,
                newID: newID
            )
        }
    }

    private func noteUndoTrace(
        _ traceID: DayTraceID,
        in candidate: NoonmarkEngine
    ) throws -> DayTrace {
        guard let trace = candidate.traces[traceID] else {
            throw NoonmarkError.notFound("day trace")
        }
        return trace
    }

    private func noteUndoChain(
        _ chainID: TaskChainID,
        in candidate: NoonmarkEngine
    ) throws -> TaskChain {
        guard let chain = candidate.chains[chainID] else {
            throw NoonmarkError.notFound("task chain")
        }
        return chain
    }

    private func noteUndoEntry(
        _ noteID: TaskNoteEntryID,
        in entries: [TaskNoteEntry]
    ) throws -> TaskNoteEntry {
        guard let note = entries.first(where: {
            $0.id == noteID && !$0.isDeleted
        }) else {
            throw NoonmarkError.notFound("task note")
        }
        return note
    }

    private func forwardNoteUndoDate(after frontiers: [Date]) throws -> Date {
        let frontier = frontiers.map(\.timeIntervalSinceReferenceDate).max()
            ?? Date().timeIntervalSinceReferenceDate
        let current = Date().timeIntervalSinceReferenceDate
        guard frontier.isFinite, current.isFinite, frontier.nextUp.isFinite else {
            throw NoonmarkError.invalidInput("task note undo time is invalid")
        }
        return Date(
            timeIntervalSinceReferenceDate: max(frontier.nextUp, current)
        )
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

    private var zhulongSidecarDirectoryURL: URL {
        if let databaseURL {
            return databaseURL.deletingLastPathComponent()
                .appendingPathComponent("ZhulongSidecar", isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noonmark-zhulong-ephemeral-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
    }

    private var zhulongSidecarKeySource: any ZhulongSidecarKeySource {
        guard CommandLine.arguments.contains("--e2e-zhulong-sidecar-key") else {
            return KeychainZhulongSidecarKeySource()
        }
        return ZhulongE2ESidecarKeySource()
    }

    private func zhulongDataScopes(for task: ZhulongTask) -> Set<ZhulongDataScope> {
        switch task {
        case .dailyReview, .habitInsight, .taskDecomposition:
            [.currentDayTodo]
        case .scheduling:
            [.currentDayTodo, .taskPool, .unfinishedPool]
        case .classification, .theoryAnalysis:
            [.currentDayTodo, .taskPool, .unfinishedPool, .completedPool, .taskClassifications]
        }
    }

    private func zhulongSessionPurpose(for task: ZhulongTask) -> ZhulongSessionPurpose {
        guard let route = Self.zhulongWorkflowRoutes.first(where: { $0.task == task }) else {
            preconditionFailure("Missing Zhulong workflow route for task \(task.rawValue)")
        }
        return route.purpose
    }

    private func zhulongProviderPayload(for session: ZhulongSession) throws -> ZhulongProviderPayload {
        let task = zhulongTask(for: session)
        var scopeContent: [ZhulongDataScope: String] = [:]
        var systemPrompt: String?
        for scope in session.proposedScopes.sorted(by: { $0.rawValue < $1.rawValue }) {
            let snapshot = zhulongScopeSnapshot(for: scope)
            let request = AIPromptBuilder().buildRequest(
                task: task,
                scope: snapshot,
                report: LocalInsightAnalyzer().analyze(snapshot)
            )
            systemPrompt = systemPrompt ?? request.systemPrompt
            scopeContent[scope] = request.userPrompt
        }
        let digestMaterial = scopeContent
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue):\($0.value)" }
            .joined(separator: "\n")
        let digest = SHA256.hash(data: Data(digestMaterial.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return try ZhulongProviderPayload(
            systemPrompt: systemPrompt ?? "你是晷迹的烛龙，只能处理用户授权的数据。",
            userPrompt: "本次主要意图：\(session.primaryIntent)",
            contextVersion: "sha256:\(digest)",
            scopeContent: scopeContent
        )
    }

    private func zhulongPlanningProviderPayload(
        for session: ZhulongSession
    ) throws -> ZhulongProviderPayload {
        guard let brief = session.currentPlanningBrief else {
            throw ZhulongProviderUIError.missingPlanningBrief
        }
        let base = try zhulongProviderPayload(for: session)
        let systemPrompt = """
        你是晷迹的烛龙。你正在执行用户对当前规划简报授予的一次性规划委托。
        只能使用授权数据，不得声称已经写入 Todo，不得改写历史事实。
        只返回一个 JSON 对象，不要 Markdown。若缺少关键决定，kind 必须为 decisionGate；否则为 planArtifact。
        decisionGate 仅允许 kind、summary、prompt、reason、evidenceGaps、options；每个 option 仅允许 id、title、impact。
        planArtifact 仅允许 kind、summary、stages、decisionExplanations、precisionClaims。
        每个 stage 仅允许 id、title、objective、horizon、dependencyIDs、deliverables、triggerCondition。
        每个 decisionExplanation 仅允许 subject、userDecisions、assumptions、dataScopes、evidence、constraints、alternatives、counterexamples、rationale、uncertainties、expectedImpacts、requiredAuthorizations。
        每个 alternative 仅允许 title、tradeoffs。每个 precisionClaim 仅允许 kind、dateValue、numericValue、basisSource、basis、basisValue、dataScope。
        """
        let briefText = """
        规划简报 v\(brief.version)
        目标：\(brief.goal)
        成功标准：\(brief.successCriteria.joined(separator: "；"))
        硬约束：\(brief.hardConstraints.joined(separator: "；"))
        用户决定：\(brief.userDecisions.joined(separator: "；"))
        显式假设：\(brief.assumptions.joined(separator: "；"))
        授权活动：\(brief.delegatedActivities.map(\.rawValue).sorted().joined(separator: "，"))
        """
        return try ZhulongProviderPayload(
            systemPrompt: systemPrompt,
            userPrompt: briefText,
            contextVersion: base.contextVersion,
            scopeContent: base.scopeContent
        )
    }

    private func zhulongScopeSnapshot(for scope: ZhulongDataScope) -> AIScopeSnapshot {
        switch scope {
        case .currentDayTodo:
            return AIScopeSnapshot.day(date: today, from: engine, isCurrentDay: true)
        case .taskPool:
            return AIScopeSnapshot.pools(
                from: engine,
                includeTaskPool: true,
                includeUnfinishedPool: false,
                includeCompletedPool: false
            )
        case .unfinishedPool:
            return AIScopeSnapshot.pools(
                from: engine,
                includeTaskPool: false,
                includeUnfinishedPool: true,
                includeCompletedPool: false
            )
        case .completedPool:
            return AIScopeSnapshot.pools(
                from: engine,
                includeTaskPool: false,
                includeUnfinishedPool: false,
                includeCompletedPool: true
            )
        case .taskClassifications:
            let classifications = engine.snapshot().classifications
            return AIScopeSnapshot(
                ranges: [],
                classifications: AIClassificationCatalogSnapshot(
                    categories: classifications.categories.values.map(\.name).sorted(),
                    labels: classifications.labels.values.map(\.name).sorted()
                )
            )
        }
    }

    private func zhulongProviderIdentity() throws -> ZhulongProviderConfigurationIdentity {
        guard zhulongProviderDraft.enabled else {
            return try ZhulongProviderConfigurationIdentity(
                providerID: "noonmark-local-evidence",
                kind: .localModel,
                baseURL: nil,
                location: .local,
                model: "local-evidence-v1",
                dataCapabilities: [.structuredOutput, .taskContext, .memoryContext]
            )
        }
        let kind: ZhulongProviderKind = switch zhulongProviderDraft.kind {
        case .openAICompatible: .openAICompatible
        case .localModel: .localModel
        case .customHTTP: .customHTTP
        }
        let isLocal = kind == .localModel
        return try ZhulongProviderConfigurationIdentity(
            providerID: zhulongProviderDraft.normalizedDisplayName,
            kind: kind,
            baseURL: isLocal ? nil : zhulongProviderDraft.normalizedBaseURL,
            location: isLocal ? .local : .remote,
            model: zhulongProviderDraft.normalizedModel.isEmpty
                ? "local-evidence-v1"
                : zhulongProviderDraft.normalizedModel,
            dataCapabilities: [.structuredOutput, .taskContext, .sessionSummary, .memoryContext]
        )
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
            NSLog("Noonmark sync identity load failed: %@", String(describing: error))
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
            engine = NoonmarkEngine()
            Theme.apply(engine.preferences.theme)
            NSLog("Noonmark persistence load failed: %@", String(describing: error))
            toast = "无法读取本地数据库，已使用空白数据：\(error.localizedDescription)"
        }
    }

    func persist() {
        do {
            try save(engine)
        } catch {
            NSLog("Noonmark persistence save failed: %@", String(describing: error))
            showToast("保存失败：\(error.localizedDescription)")
        }
    }

    func currentClassification(for chainID: TaskChainID) -> TaskClassificationProjection? {
        guard case let .task(projection) = try? engine.classification(.task(chainID)) else {
            return nil
        }
        return projection
    }

    func displayableClassification(
        for chainID: TaskChainID
    ) -> TaskClassificationDisplay? {
        guard let projection = currentClassification(for: chainID),
              projection.isEmpty == false
        else { return nil }
        return .current(projection)
    }

    func displayableClassification(
        for trace: DayTrace
    ) -> TaskClassificationDisplay? {
        if case let .history(projection) = try? engine.classification(.history(trace.id)) {
            if projection.category != nil || projection.labels.isEmpty == false {
                return .historical(projection)
            }
        }
        return displayableClassification(for: trace.chainID)
    }

    func classificationCatalog() -> ClassificationCatalogProjection? {
        guard case let .catalog(projection) = try? engine.classification(.catalog) else {
            return nil
        }
        return projection
    }

    @discardableResult
    func replaceTaskClassification(
        chainID: TaskChainID,
        category: TaskCategoryChoice?,
        labels: [TaskLabelChoice],
        interactionID: UUID = UUID()
    ) throws -> ClassificationReceipt {
        let workingEngine = try NoonmarkEngine(snapshot: engine.snapshot())
        let mutationDate = workingEngine.nextClassificationMutationDate()
        let plan = try workingEngine.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: category,
                    labels: labels
                )
            ),
            source: .userDirect,
            interactionID: interactionID,
            now: mutationDate
        )
        let receipt = try workingEngine.commitClassification(
            plan,
            confirmation: .confirmedByUser(confirming: plan, decisionID: interactionID),
            now: mutationDate
        )

        try save(workingEngine)
        engine = workingEngine
        invalidateUndoHistoryIfClassificationChanged()
        return receipt
    }

    @discardableResult
    func applyClassificationIntent(
        _ intent: ClassificationIntent,
        interactionID: UUID = UUID()
    ) throws -> ClassificationReceipt {
        let workingEngine = try NoonmarkEngine(snapshot: engine.snapshot())
        let mutationDate = workingEngine.nextClassificationMutationDate()
        let plan = try workingEngine.prepareClassification(
            intent,
            source: .userDirect,
            interactionID: interactionID,
            now: mutationDate
        )
        guard plan.blockers.isEmpty else {
            throw NoonmarkError.invalidTransition("这个分组仍被任务或历史引用，不能废弃；可改为归档。")
        }
        let receipt = try workingEngine.commitClassification(
            plan,
            confirmation: .confirmedByUser(confirming: plan, decisionID: interactionID),
            now: mutationDate
        )
        try save(workingEngine)
        engine = workingEngine
        invalidateUndoHistoryIfClassificationChanged()
        return receipt
    }

    private func save(_ candidate: NoonmarkEngine) throws {
        guard let repository else { return }
        if persistenceFailuresRemainingForE2E > 0 {
            persistenceFailuresRemainingForE2E -= 1
            throw PersistenceFailureE2EError.injectedSaveFailure
        }
        if let syncDeviceID {
            try repository.save(
                candidate.snapshot(),
                recordingChangesFor: syncDeviceID
            )
        } else {
            try repository.save(candidate)
        }
    }

    @discardableResult
    private func commitEngineMutation<Result>(
        _ mutation: (NoonmarkEngine) throws -> Result
    ) throws -> Result {
        let candidate = try NoonmarkEngine(snapshot: engine.snapshot())
        let result = try mutation(candidate)
        do {
            try save(candidate)
        } catch {
            if error is PersistenceFailureE2EError {
                NSLog("Noonmark E2E injected persistence save failure")
            } else {
                NSLog("Noonmark persistence save failed: %@", String(describing: error))
            }
            throw EnginePersistenceCommitError(underlying: error)
        }
        engine = candidate
        return result
    }

    func armPersistenceFailureForE2E(count: Int = 1) throws {
        guard permitsPersistenceFailureE2E, count > 0 else {
            throw PersistenceFailureE2EError.unsafeFailpointRequest
        }
        persistenceFailuresRemainingForE2E += count
    }

    func disarmPersistenceFailureForE2E() {
        persistenceFailuresRemainingForE2E = 0
    }

    private func pushUndoSnapshotIfAllowed(on date: LocalDate) {
        guard date >= today else { return }
        pushUndoSnapshot()
    }

    private func pushUndoSnapshot() {
        pushUndoEntry(with: .snapshot(engine.snapshot()))
    }

    private func pushUndoEntry(with entry: UndoEntry) {
        undoStack.append(entry)
        if undoStack.count > 20 {
            undoStack.removeFirst(undoStack.count - 20)
        }
    }

    private func invalidateUndoHistoryIfClassificationChanged() {
        let classifications = engine.snapshot().classifications
        guard undoStack.contains(where: {
            $0.snapshot?.classifications != nil
                && $0.snapshot?.classifications != classifications
        }) else { return }
        clearUndoHistory()
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
        let day0 = LocalDate("2026-07-01")
        let dayMinus3 = LocalDate("2026-07-02")
        let day1 = LocalDate("2026-07-03")
        let day2 = LocalDate("2026-07-04")
        let day3 = today
        let day4 = LocalDate("2026-07-06")
        let day5 = LocalDate("2026-07-07")
        // Deterministic fixture timezone: every seeded Date uses this fixed UTC-04 offset
        // so snapshot and Audit bytes never depend on the host's current time zone.
        guard let seedTimeZone = TimeZone(secondsFromGMT: -4 * 60 * 60) else {
            preconditionFailure("Seed time zone must be available")
        }
        var seedCalendar = Calendar(identifier: .gregorian)
        seedCalendar.locale = Locale(identifier: "en_US_POSIX")
        seedCalendar.timeZone = seedTimeZone
        func eventTime(_ date: LocalDate, hour: Int, minute: Int) -> Date {
            var components = DateComponents()
            components.year = date.year
            components.month = date.month
            components.day = date.day
            components.hour = hour
            components.minute = minute
            guard let timestamp = seedCalendar.date(from: components),
                  timestamp.timeIntervalSinceReferenceDate.isFinite
            else {
                preconditionFailure("Seed event time must be a finite Gregorian date")
            }
            return timestamp
        }
        let seedStart = eventTime(day0, hour: 8, minute: 0)
        var nextSeedSetupTime = seedStart
        var lastReplayedEventTime: Date?
        func seedNow(at eventTime: Date? = nil) -> Date {
            if let eventTime {
                precondition(eventTime.timeIntervalSinceReferenceDate.isFinite)
                if let lastReplayedEventTime {
                    precondition(
                        eventTime >= lastReplayedEventTime,
                        "Seed domain events must be replayed in timestamp order"
                    )
                }
                lastReplayedEventTime = eventTime
                return eventTime
            }
            let timestamp = nextSeedSetupTime
            precondition(timestamp.timeIntervalSinceReferenceDate.isFinite)
            nextSeedSetupTime = timestamp.addingTimeInterval(1)
            return timestamp
        }
        func setClassification(
            chainID: TaskChainID,
            category: (name: String, colorHex: String),
            labels: [(name: String, colorHex: String)]
        ) throws {
            let interactionID = UUID()
            let timestamp = seedNow()
            let plan = try engine.prepareClassification(
                .setCurrent(
                    TaskClassificationDraft(
                        chainID: chainID,
                        category: .new(name: category.name, colorHex: category.colorHex),
                        labels: labels.map { .new(name: $0.name, colorHex: $0.colorHex) }
                    )
                ),
                source: .userDirect,
                interactionID: interactionID,
                now: timestamp
            )
            _ = try engine.commitClassification(
                plan,
                confirmation: .confirmedByUser(confirming: plan, decisionID: interactionID),
                now: timestamp
            )
        }
        do {
            // Phase 1: create every setup fact before replaying any domain event. The
            // setup clock is independent from explicit business time and ends before
            // the first event at 08:05, so later audit revisions cannot move backwards.
            let okr = try engine.createPoolTask(
                title: "整理 Q3 OKR 草案",
                descriptionText: "汇总三条产品线负责人给的季度目标，收敛成不超过 3 个 O、每个 O 配 3 个可量化 KR。",
                now: seedNow()
            )
            try setClassification(
                chainID: okr,
                category: ("复盘", "#0E9488"),
                labels: []
            )
            let launchScript = try engine.createPoolTask(title: "给发布会准备演示脚本", descriptionText: "准备发布会现场演示脚本。", now: seedNow())
            let physical = try engine.createPoolTask(title: "预约年度体检", descriptionText: "预约年度体检时间。", now: seedNow())
            try setClassification(
                chainID: physical,
                category: ("生活", "#D1477A"),
                labels: [("健康", "#0E9488"), ("年度", "#E0851B")]
            )
            let wireframe = try engine.createPoolTask(title: "画首页线框图", descriptionText: "日历完成样例任务。", now: seedNow())
            let repository = try engine.createPoolTask(title: "搭建项目仓库与 CI", descriptionText: "日历完成样例任务。", now: seedNow())
            let rust = try engine.createPoolTask(title: "学习 Rust 基础语法", descriptionText: "废弃样例任务。", now: seedNow())
            let contract = try engine.createPoolTask(title: "回复设计合同邮件", descriptionText: "确认合同条款并回复对方。", now: seedNow())
            let iconExport = try engine.createPoolTask(title: "修复图标导出脚本", descriptionText: "修复图标资源导出脚本。", now: seedNow())
            try setClassification(
                chainID: iconExport,
                category: ("工程", "#2A6FDB"),
                labels: []
            )
            let weeklyReport = try engine.createPoolTask(title: "写本周周报", descriptionText: "整理本周进展和风险。", now: seedNow())
            try setClassification(
                chainID: weeklyReport,
                category: ("复盘", "#0E9488"),
                labels: []
            )
            let pricing = try engine.createPoolTask(title: "调研竞品定价", descriptionText: "旧任务范围过大，需要变更为可交付对比表。", now: seedNow())
            let visual = try engine.createPoolTask(title: "制作发布会主视觉", descriptionText: "推进发布会主视觉定稿。", now: seedNow())
            try setClassification(
                chainID: visual,
                category: ("工程", "#2A6FDB"),
                labels: []
            )
            let onboarding = try engine.createPoolTask(title: "审阅 onboarding 三屏文案", descriptionText: "审阅 onboarding 三屏文案。", now: seedNow())
            try setClassification(
                chainID: onboarding,
                category: ("复盘", "#0E9488"),
                labels: []
            )
            let running = try engine.createPoolTask(title: "晨跑 5 公里", descriptionText: "完成晨跑。", now: seedNow())
            try setClassification(
                chainID: running,
                category: ("生活", "#D1477A"),
                labels: []
            )
            let downloads = try engine.createPoolTask(title: "清理下载文件夹", descriptionText: "清理下载文件夹。", now: seedNow())
            try setClassification(
                chainID: downloads,
                category: ("生活", "#D1477A"),
                labels: []
            )
            let reading = try engine.createPoolTask(title: "读《卡片笔记写作法》第三章", descriptionText: "任务池样例任务。", now: seedNow())
            try setClassification(
                chainID: reading,
                category: ("学习", "#7C5CFF"),
                labels: [
                    ("阅读", "#0E9488"),
                    ("卡片笔记", "#2A6FDB"),
                    ("写作", "#D1477A"),
                    ("第三章", "#E0851B")
                ]
            )
            let animationAPI = try engine.createPoolTask(title: "调研 SwiftUI 动画 API", descriptionText: "任务池样例任务。", now: seedNow())
            try setClassification(
                chainID: animationAPI,
                category: ("工程", "#2A6FDB"),
                labels: [("SwiftUI", "#7C5CFF"), ("动画", "#0E9488")]
            )

            let standup = try engine.createPoolTask(title: "准备周一站会要点", descriptionText: "未来计划样例任务。", now: seedNow())
            try setClassification(
                chainID: standup,
                category: ("复盘", "#0E9488"),
                labels: []
            )
            let invoice = try engine.createPoolTask(title: "整理六月发票报销", descriptionText: "未来计划样例任务。", now: seedNow())
            try setClassification(
                chainID: invoice,
                category: ("生活", "#D1477A"),
                labels: []
            )
            let dinner = try engine.createPoolTask(title: "预订团队聚餐餐厅", descriptionText: "未来计划样例任务。", now: seedNow())
            try setClassification(
                chainID: dinner,
                category: ("生活", "#D1477A"),
                labels: []
            )

            precondition(
                nextSeedSetupTime < eventTime(day0, hour: 8, minute: 5),
                "Seed setup facts must precede the first domain event"
            )

            // Phase 2: replay domain events in global timestamp order. Calls sharing
            // one timestamp keep their established relative order for deterministic
            // priorities, but no explicit business timestamp is globally clamped.
            let okrDay0 = try engine.scheduleFromPool(
                chainID: okr,
                date: day0,
                today: day0,
                now: seedNow(at: eventTime(day0, hour: 8, minute: 5))
            )
            let repositoryTrace = try engine.scheduleFromPool(
                chainID: repository,
                date: day0,
                today: day0,
                now: seedNow(at: eventTime(day0, hour: 8, minute: 30))
            )
            try engine.markCompleted(
                traceID: repositoryTrace,
                today: day0,
                now: seedNow(at: eventTime(day0, hour: 9, minute: 10))
            )
            let rustTrace = try engine.scheduleFromPool(
                chainID: rust,
                date: day0,
                today: day0,
                now: seedNow(at: eventTime(day0, hour: 10, minute: 0))
            )
            try engine.abandonChain(
                from: rustTrace,
                now: seedNow(at: eventTime(day0, hour: 10, minute: 1))
            )

            _ = try engine.scheduleFromPool(
                chainID: launchScript,
                date: dayMinus3,
                today: dayMinus3,
                now: seedNow(at: eventTime(dayMinus3, hour: 8, minute: 0))
            )
            let physicalTrace = try engine.scheduleFromPool(
                chainID: physical,
                date: dayMinus3,
                today: dayMinus3,
                now: seedNow(at: eventTime(dayMinus3, hour: 9, minute: 0))
            )
            try engine.returnToPool(
                traceID: physicalTrace,
                today: dayMinus3,
                now: seedNow(at: eventTime(dayMinus3, hour: 9, minute: 1))
            )
            let wireframeTrace = try engine.scheduleFromPool(
                chainID: wireframe,
                date: dayMinus3,
                today: dayMinus3,
                now: seedNow(at: eventTime(dayMinus3, hour: 9, minute: 5))
            )
            try engine.markCompleted(
                traceID: wireframeTrace,
                today: dayMinus3,
                now: seedNow(at: eventTime(dayMinus3, hour: 16, minute: 30))
            )

            try engine.settleDays(
                upTo: day1,
                now: seedNow(at: eventTime(day1, hour: 0, minute: 1))
            )
            let okrDay1 = try engine.continueTrace(
                traceID: okrDay0,
                targetDate: day1,
                today: day1,
                now: seedNow(at: eventTime(day1, hour: 8, minute: 0))
            )
            let okrToday = try engine.continueTrace(
                traceID: okrDay1,
                targetDate: day3,
                today: day1,
                now: seedNow(at: eventTime(day1, hour: 8, minute: 1))
            )
            let contractTrace = try engine.scheduleFromPool(
                chainID: contract,
                date: day1,
                today: day1,
                now: seedNow(at: eventTime(day1, hour: 9, minute: 0))
            )
            let weeklyDay1 = try engine.scheduleFromPool(
                chainID: weeklyReport,
                date: day1,
                today: day1,
                now: seedNow(at: eventTime(day1, hour: 9, minute: 0))
            )
            let visualDay1 = try engine.scheduleFromPool(
                chainID: visual,
                date: day1,
                today: day1,
                now: seedNow(at: eventTime(day1, hour: 9, minute: 0))
            )
            let visualReference = try engine.addSubtask(
                traceID: visualDay1,
                title: "收集视觉参考",
                difficulty: .simple,
                now: seedNow(at: eventTime(day1, hour: 9, minute: 1))
            )
            _ = try engine.addSubtask(
                traceID: visualDay1,
                title: "出 3 版草图",
                difficulty: .hard,
                now: seedNow(at: eventTime(day1, hour: 9, minute: 2))
            )
            try engine.markCompleted(
                traceID: contractTrace,
                today: day1,
                now: seedNow(at: eventTime(day1, hour: 11, minute: 20))
            )
            try engine.completeSubtask(
                visualReference,
                today: day1,
                now: seedNow(at: eventTime(day1, hour: 15, minute: 20))
            )
            let weeklyDay2 = try engine.continueTrace(
                traceID: weeklyDay1,
                targetDate: day2,
                today: day1,
                now: seedNow(at: eventTime(day1, hour: 18, minute: 0))
            )
            let visualDay2 = try engine.continueTrace(
                traceID: visualDay1,
                targetDate: day2,
                today: day1,
                now: seedNow(at: eventTime(day1, hour: 18, minute: 0))
            )

            let iconDay2 = try engine.scheduleFromPool(
                chainID: iconExport,
                date: day2,
                today: day2,
                now: seedNow(at: eventTime(day2, hour: 9, minute: 0))
            )
            let pricingTrace = try engine.scheduleFromPool(
                chainID: pricing,
                date: day2,
                today: day2,
                now: seedNow(at: eventTime(day2, hour: 9, minute: 0))
            )
            try engine.setManualProgress(
                traceID: iconDay2,
                percent: 45,
                today: day2,
                now: seedNow(at: eventTime(day2, hour: 10, minute: 0))
            )
            _ = try engine.changeTrace(
                traceID: pricingTrace,
                newTitle: "输出竞品定价对比表",
                today: day2,
                now: seedNow(at: eventTime(day2, hour: 10, minute: 0))
            )
            if let draftSubtask = engine.subtasks.values.first(where: {
                $0.traceID == visualDay2 && $0.title == "出 3 版草图"
            }) {
                try engine.completeSubtask(
                    draftSubtask.id,
                    today: day2,
                    now: seedNow(at: eventTime(day2, hour: 15, minute: 45))
                )
            }
            _ = try engine.addSubtask(
                traceID: visualDay2,
                title: "定稿并交付",
                difficulty: .medium,
                now: seedNow(at: eventTime(day2, hour: 15, minute: 46))
            )
            try engine.markCompleted(
                traceID: weeklyDay2,
                today: day2,
                now: seedNow(at: eventTime(day2, hour: 17, minute: 45))
            )
            let iconToday = try engine.continueTrace(
                traceID: iconDay2,
                targetDate: day3,
                today: day2,
                now: seedNow(at: eventTime(day2, hour: 18, minute: 0))
            )
            let visualToday = try engine.continueTrace(
                traceID: visualDay2,
                targetDate: day3,
                today: day2,
                now: seedNow(at: eventTime(day2, hour: 18, minute: 0))
            )
            if engine.subtasks.values.contains(where: { $0.traceID == visualToday }) == false {
                _ = try engine.addSubtask(
                    traceID: visualToday,
                    title: "定稿并交付",
                    difficulty: .medium,
                    now: seedNow(at: eventTime(day2, hour: 18, minute: 1))
                )
            }

            try engine.settleDays(
                upTo: day3,
                now: seedNow(at: eventTime(day3, hour: 0, minute: 1))
            )
            engine.updateDailyReview(
                date: day1,
                summary: "合同邮件处理完毕；OKR 草案低估了工作量，明天优先。",
                unfinishedReason: "OKR 依赖的数据下午才拿到，被会议切碎。",
                tomorrowNote: "上午先做 OKR，别先开邮箱。",
                now: seedNow(at: eventTime(day3, hour: 0, minute: 2))
            )
            engine.updateDailyReview(
                date: day2,
                summary: "周报和图标脚本推进顺利；竞品调研范围太大，拆成了对比表任务。",
                unfinishedReason: "竞品对比表低估了整理时间。",
                tomorrowNote: "对比表先列框架再填数据。",
                now: seedNow(at: eventTime(day3, hour: 0, minute: 3))
            )

            let runningTrace = try engine.scheduleFromPool(
                chainID: running,
                date: day3,
                today: day3,
                now: seedNow(at: eventTime(day3, hour: 7, minute: 0))
            )
            try engine.markCompleted(
                traceID: runningTrace,
                today: day3,
                now: seedNow(at: eventTime(day3, hour: 7, minute: 36))
            )
            let onboardingTrace = try engine.scheduleFromPool(
                chainID: onboarding,
                date: day3,
                today: day3,
                now: seedNow(at: eventTime(day3, hour: 8, minute: 0))
            )
            _ = try engine.scheduleFromPool(
                chainID: downloads,
                date: day3,
                today: day3,
                now: seedNow(at: eventTime(day3, hour: 8, minute: 0))
            )
            let headline = try engine.addSubtask(
                traceID: onboardingTrace,
                title: "首屏标题与副标题",
                difficulty: .simple,
                now: seedNow(at: eventTime(day3, hour: 8, minute: 1))
            )
            _ = try engine.addSubtask(
                traceID: onboardingTrace,
                title: "通知权限请求文案",
                difficulty: .medium,
                now: seedNow(at: eventTime(day3, hour: 8, minute: 2))
            )
            try engine.setManualProgress(
                traceID: iconToday,
                percent: 45,
                today: day3,
                now: seedNow(at: eventTime(day3, hour: 9, minute: 0))
            )
            try engine.completeSubtask(
                headline,
                today: day3,
                now: seedNow(at: eventTime(day3, hour: 9, minute: 0))
            )
            _ = try engine.scheduleFromPool(
                chainID: standup,
                date: day4,
                today: day3,
                now: seedNow(at: eventTime(day3, hour: 10, minute: 0))
            )
            _ = try engine.scheduleFromPool(
                chainID: invoice,
                date: day5,
                today: day3,
                now: seedNow(at: eventTime(day3, hour: 10, minute: 1))
            )
            _ = try engine.scheduleFromPool(
                chainID: dinner,
                date: day4,
                today: day3,
                now: seedNow(at: eventTime(day3, hour: 10, minute: 2))
            )
            try engine.setManualProgress(
                traceID: okrToday,
                percent: 30,
                today: day3,
                now: seedNow(at: eventTime(day3, hour: 14, minute: 0))
            )
            _ = try engine.appendTraceNote(
                traceID: okrToday,
                body: "等数据组下午的留存看板再定第 2 个 KR 的口径。",
                today: day3,
                now: seedNow(at: eventTime(day3, hour: 14, minute: 20))
            )
            engine.updateDailyReview(
                date: day3,
                summary: "",
                unfinishedReason: "",
                tomorrowNote: "",
                now: seedNow(at: eventTime(day3, hour: 15, minute: 0))
            )
        } catch {
            assertionFailure("Seed data failed: \(error)")
        }
    }
}

struct NoonmarkRootView: View {
    @EnvironmentObject private var store: NoonmarkStore

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
            .disabled(store.showingClassificationManager)
            .accessibilityHidden(store.showingClassificationManager)

            if let toast = store.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.noonmarkSystem(size: 12, weight: .medium))
                        .foregroundStyle(Theme.background)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Theme.text1))
                        .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 30)
                        .accessibilityIdentifier("app.toast")
                        .background {
                            AppE2EViewAnchor(
                                identifier: "app.toast",
                                verificationText: toast
                            )
                        }
                }
            }

            if store.showingClassificationManager {
                ZStack {
                    Color.black.opacity(0.16)
                        .contentShape(Rectangle())
                        .onTapGesture {}
                        .accessibilityHidden(true)

                    ClassificationManagementDialog {
                        store.showingClassificationManager = false
                    }
                    .environmentObject(store)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Theme.line.opacity(0.8))
                    )
                    .shadow(color: .black.opacity(0.18), radius: 28, y: 12)
                    .transition(.scale(scale: 0.98).combined(with: .opacity))
                }
                .ignoresSafeArea()
                .zIndex(1)
            }
        }
        .font(.noonmarkSystem(size: 13))
        .animation(.easeOut(duration: 0.16), value: store.showingClassificationManager)
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
            if store.showingClassificationManager == false {
                store.moveSelectedDate(direction)
            }
        }
        .onAppear {
            syncNativeWindowTitle()
            if store.showingClassificationManager {
                resignBackgroundFocus()
            }
        }
        .onChange(of: store.showingClassificationManager) { _, isPresented in
            if isPresented {
                resignBackgroundFocus()
            }
        }
        .onChange(of: store.windowTitle) { _, _ in
            syncNativeWindowTitle()
        }
        .onChange(of: store.isZhulongEnabled) { _, _ in
            store.ensureVisiblePage()
        }
    }

    private func syncNativeWindowTitle() {
        NSApp.windows.first { $0 is NoonmarkWindow }?.title = store.windowTitle
    }

    private func resignBackgroundFocus() {
        DispatchQueue.main.async {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }
}

struct PickerSheetState: Identifiable {
    let id = UUID()
    let purpose: NoonmarkStore.DatePickerPurpose
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
            ? "可选 sidecar：复盘分析、任务拆解、排期建议和分组与标签整理。"
            : "Optional sidecar for reviews, decomposition, scheduling, and classification."
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
        HStack(spacing: 0) {
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
        .frame(height: NoonmarkVisualMetrics.trafficLightHitTarget)
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
                .frame(
                    width: NoonmarkVisualMetrics.trafficLightDiameter,
                    height: NoonmarkVisualMetrics.trafficLightDiameter
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(
            width: NoonmarkVisualMetrics.trafficLightHitTarget,
            height: NoonmarkVisualMetrics.trafficLightHitTarget
        )
        .contentShape(Rectangle())
        .accessibilityLabel(accessibilityLabel)
    }

    private func closeWindow() {
        currentWindow?.performClose(nil)
    }

    private func minimizeWindow() {
        currentWindow?.miniaturize(nil)
    }

    private func zoomWindow() {
        currentWindow?.zoom(nil)
    }

    private var currentWindow: NSWindow? {
        NSApp.keyWindow ?? NSApp.windows.first { $0 is NoonmarkWindow }
    }
}

struct Sidebar: View {
    @EnvironmentObject private var store: NoonmarkStore

    var planPages: [NoonmarkStore.Page] {
        [.day, .pool, .future]
    }

    var tracePages: [NoonmarkStore.Page] {
        [.unfinished, .completed, .calendar, .zhulong]
            .filter { store.visibleNavigationPages.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TrafficLightDots()
                .padding(.horizontal, 16)
                .padding(.bottom, 18)

            HStack(spacing: 8) {
                ClockLogo()
                Text(store.copy.appName)
                    .font(.noonmarkSystem(size: 17, weight: .bold))
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
        .frame(width: NoonmarkVisualMetrics.sidebarWidth)
        .padding(.top, 10)
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
        .frame(
            width: NoonmarkVisualMetrics.clockLogoSize,
            height: NoonmarkVisualMetrics.clockLogoSize
        )
    }
}

struct NavGroupTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.noonmarkSystem(size: 11.5, weight: .semibold))
            .foregroundStyle(Theme.text3)
            .tracking(0.4)
            .padding(.horizontal, 20)
            .padding(.bottom, 5)
    }
}

struct NavItem: View {
    @EnvironmentObject private var store: NoonmarkStore
    let page: NoonmarkStore.Page
    let label: String
    let count: Int

    var active: Bool { store.page == page }

    var body: some View {
        Button {
            store.selectPage(page)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: page.navigationSystemImage)
                    .font(
                        .noonmarkRenderedSystem(
                            size: NoonmarkVisualMetrics.navigationIconSize,
                            weight: .medium
                        )
                    )
                    .frame(width: 19)
                    .foregroundStyle(page.navigationIconColor)
                Text(label)
                    .font(.noonmarkSystem(size: 14.5, weight: active ? .semibold : .medium))
                    .foregroundStyle(active ? Theme.text1 : Theme.text2)
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(.noonmarkSystem(size: 12, weight: active ? .semibold : .regular))
                        .foregroundStyle(Theme.text2)
                        .padding(.horizontal, 7)
                        .frame(minWidth: 21, minHeight: 18)
                        .background(Capsule().fill(active ? Theme.panel.opacity(0.8) : Theme.chip))
                }
            }
            .frame(height: NoonmarkVisualMetrics.navigationRowHeight)
            .padding(.leading, 14)
            .padding(.trailing, 12)
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
        .padding(.horizontal, 9)
        .padding(.vertical, 1.5)
    }
}

struct MainSurface: View {
    @EnvironmentObject private var store: NoonmarkStore

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
                    .frame(width: NoonmarkVisualMetrics.detailRailWidth)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Theme.line.opacity(0.58)).frame(width: 1)
                    }
            }
        }
        .background(Theme.panel)
    }
}

struct TaskSelectionClearingScrollView<Content: View>: View {
    @EnvironmentObject private var store: NoonmarkStore
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
    @EnvironmentObject private var store: NoonmarkStore

    var traces: [DayTrace] {
        store.engine.getDayTodo(date: store.selectedDate).traces
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DayTodoHeader(dayBadge: dayBadge, badgeColor: badgeColor)

            DateStrip()
                .padding(.horizontal, NoonmarkVisualMetrics.pageHorizontalPadding)
                .padding(.bottom, 10)

            if store.isHistory {
                Notice(text: store.copy.lockedDayNotice, tone: .locked)
                    .padding(.horizontal, NoonmarkVisualMetrics.pageHorizontalPadding)
            } else if store.isFuture {
                Notice(text: store.copy.futureDayNotice, tone: .future)
                    .padding(.horizontal, NoonmarkVisualMetrics.pageHorizontalPadding)
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
                .padding(.horizontal, NoonmarkVisualMetrics.pageHorizontalPadding)
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
    @EnvironmentObject private var store: NoonmarkStore
    let dayBadge: String
    let badgeColor: Color

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(NoonmarkStore.displayFullDate(store.selectedDate))
                .font(.noonmarkSystem(size: 21, weight: .bold))
                .foregroundStyle(Theme.text1)
                .monospacedDigit()
                .lineLimit(1)
            Text(NoonmarkStore.weekday(store.selectedDate))
                .font(.noonmarkSystem(size: 12))
                .foregroundStyle(Theme.text3)
                .lineLimit(1)
            DayStateBadge(text: dayBadge, color: badgeColor, filled: store.selectedDate == store.today)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                HeaderButton("‹") { store.selectedDate = NoonmarkStore.offset(store.selectedDate, by: -1) }
                HeaderButton(store.copy.today) { store.selectedDate = store.today }
                HeaderButton("›") { store.selectedDate = NoonmarkStore.offset(store.selectedDate, by: 1) }
                HeaderButton(store.copy.chooseDate) { store.showingPicker = .gotoDay }
            }
        }
        .padding(.horizontal, NoonmarkVisualMetrics.pageHorizontalPadding)
        .padding(.top, 16)
    }
}

struct DayStateBadge: View {
    let text: String
    let color: Color
    let filled: Bool

    var body: some View {
        Text(text)
            .font(.noonmarkSystem(size: 11, weight: .semibold))
            .foregroundStyle(filled ? .white : color)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(filled ? color : color.opacity(0.12)))
    }
}

struct DayQuickAdd: View {
    @EnvironmentObject private var store: NoonmarkStore

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
    @EnvironmentObject private var store: NoonmarkStore
    let placeholder: String
    @Binding var text: String
    let onSubmit: () -> Void

    var suggestions: [ClassificationCatalogItemProjection] {
        store.newTaskLabelSuggestions(for: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MarkdownEditor(
                text: $text,
                placeholder: placeholder,
                style: .compact,
                commitsOnReturn: true,
                onCommit: onSubmit
            )
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.controlFill))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line.opacity(0.72)))

            if store.shouldShowNewTaskLabelSuggestions(for: text) {
                VStack(spacing: 0) {
                    ForEach(suggestions.prefix(6)) { label in
                        Button {
                            text = store.completeLastHashToken(in: text, with: label.name)
                        } label: {
                            HStack(spacing: 7) {
                                Text("#")
                                    .font(.noonmarkSystem(size: 10, weight: .black, design: .rounded))
                                    .foregroundStyle(label.color)
                                    .frame(width: 18, height: 18)
                                    .background(RoundedRectangle(cornerRadius: 3).fill(label.color.opacity(0.10)))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 3)
                                            .stroke(label.color.opacity(0.48), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                                    }
                                Text("#\(label.name)")
                                    .font(.noonmarkSystem(size: 11.5, weight: .semibold))
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
    @EnvironmentObject private var store: NoonmarkStore

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
                            Text(NoonmarkStore.weekday(date).replacingOccurrences(of: "周", with: ""))
                                .font(.noonmarkSystem(size: 9.5, weight: .medium))
                                .foregroundStyle(Theme.text3)
                            Text("\(date.day)")
                                .font(.noonmarkSystem(size: 12, weight: .semibold))
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
    @EnvironmentObject private var store: NoonmarkStore
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
                    MarkdownInlineText(definition?.title ?? "未命名任务")
                        .font(.noonmarkSystem(size: 13, weight: .medium))
                        .foregroundStyle(trace.status.uiStyle.titleColor)
                        .strikethrough(trace.status.uiStyle.strikethrough)

                    if let classification = store.displayableClassification(for: trace) {
                        TaskClassificationBadges(
                            display: classification,
                            taskTitle: definition?.title ?? "未命名任务",
                            accessibilityNamespace: TaskClassificationAccessibilityNamespace(
                                surface: "day-row",
                                instanceID: trace.id.description
                            )
                        )
                        .padding(.top, 4)
                    }

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
                                .font(.noonmarkSystem(size: 10, weight: .semibold))
                                .foregroundStyle(progress.percent == 100 ? Theme.ok : Theme.accent)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .padding(.top, 5)
                    }

                    if metaText.isEmpty == false {
                        Text(metaText)
                            .font(.noonmarkSystem(size: 11))
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
                .layoutPriority(1)

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
            .padding(.vertical, NoonmarkVisualMetrics.taskRowVerticalPadding)

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
                .font(.noonmarkSystem(size: 9, weight: .bold))
                .rotationEffect(.degrees(expanded ? 90 : 0))
            Text("\(count) 子任务")
                .font(.noonmarkSystem(size: 11, weight: .semibold))
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
                MarkdownInlineText(title)
                    .lineLimit(1)
                Image(systemName: "arrow.right")
                    .font(.noonmarkSystem(size: compact ? 8.5 : 9.5, weight: .bold))
            }
            .font(.noonmarkSystem(size: compact ? 10.5 : 11, weight: .semibold))
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
    @EnvironmentObject private var store: NoonmarkStore
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
                    .overlay(Text(subtask.status == .completed ? "✓" : "").font(.noonmarkSystem(size: 9)).foregroundStyle(.white))
                    .frame(width: 15, height: 15)
            }
            .buttonStyle(.plain)

            MarkdownInlineText(subtask.title)
                .font(.noonmarkSystem(size: 12))
                .foregroundStyle(subtask.status == .completed ? Theme.text3 : Theme.text1)
                .strikethrough(subtask.status == .completed)

            Spacer()

            if subtask.completedAt != nil && canMutate == false {
                Image(systemName: "lock.fill")
                    .font(.noonmarkSystem(size: 9))
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
                        .font(.noonmarkSystem(size: 9, weight: .semibold))
                    Text(subtask.difficulty.label)
                    Image(systemName: "chevron.down")
                        .font(.noonmarkSystem(size: 8, weight: .bold))
                }
                .font(.noonmarkSystem(size: 9, weight: .bold))
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
    @EnvironmentObject private var store: NoonmarkStore
    let trace: DayTrace
    var actions: [NoonmarkStore.TraceContextAction] { store.contextMenuActions(for: trace) }

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
    @EnvironmentObject private var store: NoonmarkStore

    var tasks: [PoolTask] { store.engine.taskPool() }
    var groups: [PoolTaskGroup] {
        Dictionary(grouping: tasks, by: {
            store.currentClassification(for: $0.chain.id)?.category?.name ?? "未分组"
        })
            .map { PoolTaskGroup(title: $0.key, tasks: $0.value.sorted { $0.definition.createdAt < $1.definition.createdAt }) }
            .sorted {
                if $0.title == "未分组" { return false }
                if $1.title == "未分组" { return true }
                return ClassificationNameCanonicalizer.canonicalKey($0.title)
                    < ClassificationNameCanonicalizer.canonicalKey($1.title)
            }
    }

    var shouldShowGroups: Bool {
        groups.count > 1 || groups.contains { $0.title != "未分组" }
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
                                            .font(.noonmarkSystem(size: 12, weight: .semibold))
                                            .foregroundStyle(Theme.text2)
                                        Text("\(group.tasks.count)")
                                            .font(.noonmarkSystem(size: 10.5, weight: .semibold))
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
                .padding(.horizontal, NoonmarkVisualMetrics.pageHorizontalPadding)
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
    @EnvironmentObject private var store: NoonmarkStore

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
    @EnvironmentObject private var store: NoonmarkStore
    let task: PoolTask

    var body: some View {
        let selected = store.selectedPoolChainID == task.chain.id
        let e2eNamespace = PoolTaskRowE2ENamespace(
            taskIdentifier: task.chain.id.description
        )
        HStack(alignment: .top, spacing: 10) {
            PoolTaskPlaceholderGlyph()
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    MarkdownInlineText(task.definition.title)
                        .font(.noonmarkSystem(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                        .lineLimit(1)
                        .layoutPriority(1)
                        .background {
                            AppE2EViewAnchor(
                                identifier: e2eNamespace.titleIdentifier,
                                verificationText: task.definition.title
                            )
                        }
                    if let classification = store.currentClassification(for: task.chain.id) {
                        TaskClassificationBadges(
                            display: .current(classification),
                            taskTitle: task.definition.title,
                            accessibilityNamespace: TaskClassificationAccessibilityNamespace(
                                surface: "pool-row",
                                instanceID: task.chain.id.description
                            ),
                            showsCategory: false
                        )
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    SmallActionButton(store.copy.scheduleToday, tone: .accent) {
                        store.schedulePoolTask(task.chain.id, date: store.today)
                    }
                    .background {
                        AppE2EViewAnchor(
                            identifier: e2eNamespace.scheduleTodayIdentifier,
                            verificationText: store.copy.scheduleToday
                        )
                    }
                    SmallActionButton(store.copy.scheduleTomorrow) {
                        store.schedulePoolTask(
                            task.chain.id,
                            date: NoonmarkStore.offset(store.today, by: 1)
                        )
                    }
                    .background {
                        AppE2EViewAnchor(
                            identifier: e2eNamespace.scheduleTomorrowIdentifier,
                            verificationText: store.copy.scheduleTomorrow
                        )
                    }
                    SmallActionButton(store.copy.schedulePickDate) {
                        store.showingPicker = .schedulePool(task.chain.id)
                    }
                    .background {
                        AppE2EViewAnchor(
                            identifier: e2eNamespace.scheduleDateIdentifier,
                            verificationText: store.copy.schedulePickDate
                        )
                    }
                    Button(role: .destructive) {
                        store.deletePoolTask(task.chain.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.noonmarkSystem(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.warn)
                    .help("删除任务")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, NoonmarkVisualMetrics.taskRowVerticalPadding)
        .listRowSurface(selected: selected, tint: Theme.navPool, separatorLeadingInset: 40)
        .onTapGesture { store.selectPool(task.chain.id) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pool.task.\(task.chain.id.description)")
        .accessibilityLabel("任务「\(task.definition.title)」")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { store.selectPool(task.chain.id) }
    }
}

private extension TaskClassificationProjection {
    var isEmpty: Bool {
        category == nil && labels.isEmpty
    }
}

private extension ClassificationItemProjection {
    var color: Color {
        classificationColor(colorHex)
    }
}

private extension ClassificationCatalogItemProjection {
    var color: Color {
        classificationColor(colorHex)
    }
}

private func classificationColor(_ colorHex: String) -> Color {
    let raw = colorHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard raw.count == 6, let value = Int(raw, radix: 16) else {
        return Theme.navPool
    }
    return Theme.hex(value)
}

struct PoolTaskPlaceholderGlyph: View {
    var body: some View {
        Circle()
            .stroke(Theme.line2, style: StrokeStyle(lineWidth: 1.5, dash: [2.4, 2]))
            .frame(width: 18, height: 18)
    }
}

struct FuturePlansPage: View {
    @EnvironmentObject private var store: NoonmarkStore
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
                                Text("\(NoonmarkStore.displayDate(date)) · \(NoonmarkStore.weekday(date))")
                                    .font(.noonmarkSystem(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.text1)
                                    .monospacedDigit()
                                Button(store.copy.openDay) {
                                    store.selectedDate = date
                                    store.page = .day
                                }
                                .buttonStyle(.plain)
                                .font(.noonmarkSystem(size: 11.5))
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
                .padding(.horizontal, NoonmarkVisualMetrics.pageHorizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
        }
    }
}

struct FuturePlanRow: View {
    @EnvironmentObject private var store: NoonmarkStore
    let item: FuturePlanItem

    var body: some View {
        let selected = store.selectedTraceID == item.trace.id
        HStack(spacing: 10) {
            PlanningGlyph(systemName: "calendar.badge.clock", color: Theme.navFuture)
            VStack(alignment: .leading, spacing: 0) {
                MarkdownInlineText(item.definition.title)
                    .font(.noonmarkSystem(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                    .lineLimit(1)
                if let classification = store.displayableClassification(for: item.trace) {
                    TaskClassificationBadges(
                        display: classification,
                        taskTitle: item.definition.title,
                        accessibilityNamespace: TaskClassificationAccessibilityNamespace(
                            surface: "future-row",
                            instanceID: item.trace.id.description
                        )
                    )
                    .padding(.top, 4)
                }
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
        .padding(.vertical, NoonmarkVisualMetrics.taskRowVerticalPadding)
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
            .font(.noonmarkSystem(size: 11, weight: .semibold))
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
            .font(.noonmarkSystem(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

struct UnfinishedPoolPage: View {
    @EnvironmentObject private var store: NoonmarkStore
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
                .padding(.horizontal, NoonmarkVisualMetrics.pageHorizontalPadding)
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
    @EnvironmentObject private var store: NoonmarkStore
    let item: UnfinishedPoolItem

    var expanded: Bool { store.expandedUnfinishedChainIDs.contains(item.chain.id) }
    private var activeDateLabel: String {
        guard let active = item.activeTrace else { return "" }
        return active.date == store.today ? "今天" : NoonmarkStore.displayDate(active.date)
    }

    var body: some View {
        let selected = store.selectedUnfinishedChainID == item.chain.id
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                StatusGlyph(status: item.isAbandoned ? .abandoned : .unfinished)
                VStack(alignment: .leading, spacing: 0) {
                    MarkdownInlineText(item.definition.title)
                        .font(.noonmarkSystem(size: 13, weight: .semibold))
                        .foregroundStyle(item.isAbandoned ? Theme.text2 : Theme.text1)
                        .lineLimit(1)
                    if let classificationTrace = item.activeTrace ?? item.latestUnfinishedTrace {
                        if let classification = store.displayableClassification(for: classificationTrace) {
                            TaskClassificationBadges(
                                display: classification,
                                taskTitle: item.definition.title,
                                accessibilityNamespace: TaskClassificationAccessibilityNamespace(
                                    surface: "unfinished-row",
                                    instanceID: classificationTrace.id.description
                                )
                            )
                            .padding(.top, 4)
                        }
                    }
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
                    .font(.noonmarkSystem(size: 11))
                    .foregroundStyle(item.isAbandoned ? Theme.text2 : Theme.warn)
                    .monospacedDigit()
                UnfinishedMetaSeparator()
                Text(store.copy.unfinishedContinuationCount(item.continuationCount))
                    .font(.noonmarkSystem(size: 11))
                    .foregroundStyle(Theme.text3)
                    .monospacedDigit()
                if let latestUnfinished = item.latestUnfinishedTrace {
                    UnfinishedMetaSeparator()
                    Text(store.copy.lastMissedDate(NoonmarkStore.displayDate(latestUnfinished.date)))
                        .font(.noonmarkSystem(size: 11))
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
                    .font(.noonmarkSystem(size: 10.5, weight: .medium))
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
                .font(.noonmarkSystem(size: 11))
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
            .font(.noonmarkSystem(size: 11))
            .foregroundStyle(Theme.text3)
    }
}

struct UnfinishedInlineTrace: View {
    let trace: DayTrace

    var body: some View {
        HStack(spacing: 8) {
            StatusGlyph(status: trace.status)
            Text(NoonmarkStore.displayDate(trace.date))
                .font(.noonmarkSystem(size: 11, weight: .medium))
                .foregroundStyle(Theme.text2)
                .frame(width: 74, alignment: .leading)
            Text(statusLabel)
                .font(.noonmarkSystem(size: 11, weight: .semibold))
                .foregroundStyle(statusColor)
            Text("第 \(trace.continuationSeq) 次延续")
                .font(.noonmarkSystem(size: 11))
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
    @EnvironmentObject private var store: NoonmarkStore
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
                                    .font(.noonmarkSystem(size: 13, weight: .semibold))
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
                .padding(.horizontal, NoonmarkVisualMetrics.pageHorizontalPadding)
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
        return "\(NoonmarkStore.displayDate(date)) \(NoonmarkStore.weekday(date))\(suffix)"
    }
}

struct CompletedRow: View {
    @EnvironmentObject private var store: NoonmarkStore
    let item: CompletedPoolItem

    var body: some View {
        let isSelected = store.selectedCompletedTraceID == item.trace.id
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                StatusGlyph(status: .completed)
                VStack(alignment: .leading, spacing: 0) {
                    MarkdownInlineText(item.definition.title)
                        .font(.noonmarkSystem(size: 13, weight: .medium))
                        .lineLimit(1)
                    if let classification = store.displayableClassification(for: item.trace) {
                        TaskClassificationBadges(
                            display: classification,
                            taskTitle: item.definition.title,
                            accessibilityNamespace: TaskClassificationAccessibilityNamespace(
                                surface: "completed-row",
                                instanceID: item.trace.id.description
                            )
                        )
                        .padding(.top, 4)
                    }
                }
                Spacer()
                CompletionTimeText(time: NoonmarkStore.displayTime(item.trace.completedAt))
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
        .padding(.vertical, NoonmarkVisualMetrics.taskRowVerticalPadding)
        .listRowSurface(selected: isSelected, tint: Theme.accent, separatorLeadingInset: 40)
        .onTapGesture { store.selectCompleted(item.trace.id) }
    }
}

struct CompletedSubtaskRow: View {
    @EnvironmentObject private var store: NoonmarkStore
    let record: CompletedSubtaskRecord

    var body: some View {
        let isSelected = store.selectedCompletedSubtaskID == record.subtask.id
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                StatusGlyph(status: .completed)
                VStack(alignment: .leading, spacing: 1) {
                    MarkdownInlineText(record.subtask.title)
                        .font(.noonmarkSystem(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text("属于「\(record.parentDefinition.title)」")
                        .font(.noonmarkSystem(size: 10.5))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                    if let classification = store.displayableClassification(for: record.parentTrace) {
                        TaskClassificationBadges(
                            display: classification,
                            taskTitle: record.parentDefinition.title,
                            accessibilityNamespace: TaskClassificationAccessibilityNamespace(
                                surface: "completed-subtask-row",
                                instanceID: record.subtask.id.description
                            )
                        )
                        .padding(.top, 4)
                    }
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
        .padding(.vertical, NoonmarkVisualMetrics.taskRowVerticalPadding)
        .listRowSurface(selected: isSelected, tint: Theme.accent, separatorLeadingInset: 40)
        .onTapGesture { store.selectCompletedSubtask(record.subtask.id) }
    }
}

struct CompletionKindPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.noonmarkSystem(size: 10, weight: .semibold))
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
                .font(.noonmarkSystem(size: 11))
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
                        .font(.noonmarkSystem(size: 9, weight: .bold))
                        .foregroundStyle(node.foreground)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(node.background))
                    Text(NoonmarkStore.displayDate(node.date))
                        .font(.noonmarkSystem(size: 10.5))
                        .foregroundStyle(Theme.text3)
                        .monospacedDigit()
                }
                .padding(.trailing, 2)
            }
        }
    }
}

struct CalendarPage: View {
    @EnvironmentObject private var store: NoonmarkStore

    var calendarCells: [CalendarCellModel] {
        let year = store.selectedCalendarDate.year
        let month = store.selectedCalendarDate.month
        let lead = NoonmarkStore.mondayLeadBlankCount(year: year, month: month)
        let dayCount = NoonmarkStore.daysInMonth(year: year, month: month)
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
                        .font(.noonmarkSystem(size: 21, weight: .bold))
                        .foregroundStyle(Theme.text1)
                        .monospacedDigit()
                    Spacer()
                    HeaderButton("‹") {
                        store.selectedCalendarDate = NoonmarkStore.shiftedMonth(from: store.selectedCalendarDate, by: -1)
                    }
                    HeaderButton(store.copy.today) { store.selectedCalendarDate = store.today }
                    HeaderButton("›") {
                        store.selectedCalendarDate = NoonmarkStore.shiftedMonth(from: store.selectedCalendarDate, by: 1)
                    }
                }

                Text(store.copy.calendarSubtitle)
                    .font(.noonmarkSystem(size: 12))
                    .foregroundStyle(Theme.text3)
                    .padding(.top, 4)

                HStack {
                    ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) {
                        Text($0)
                            .font(.noonmarkSystem(size: 11, weight: .semibold))
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
                .frame(width: NoonmarkVisualMetrics.calendarRailWidth)
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
    @EnvironmentObject private var store: NoonmarkStore
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
                    .font(.noonmarkSystem(size: 12.5, weight: isToday || selected ? .bold : .medium))
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
                        MarkdownInlineText(store.definition(for: trace)?.title ?? "")
                            .font(.noonmarkSystem(size: 9.5))
                            .foregroundStyle(titleColor(for: trace.status))
                            .strikethrough(trace.status == .completed || trace.status == .abandoned)
                            .lineLimit(1)
                    }
                    .frame(height: 12, alignment: .leading)
                }
                if traces.count > 6 {
                    Text("+\(traces.count - 6)")
                        .font(.noonmarkSystem(size: 9))
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
    static func make(for date: LocalDate, store: NoonmarkStore) -> CalendarDayInsight {
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
                    .font(.noonmarkSystem(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .tracking(0.6)
                Spacer()
                Text("\(insight.completionRate)% 完成")
                    .font(.noonmarkSystem(size: 11.5, weight: .semibold))
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
                .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .frame(width: 28, alignment: .leading)
            Text(text)
                .font(.noonmarkSystem(size: 11.5))
                .foregroundStyle(Theme.text2)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct CalendarDetailPanel: View {
    @EnvironmentObject private var store: NoonmarkStore
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
                    Text(verbatim: "\(store.selectedCalendarDate.year)年\(NoonmarkStore.displayDate(store.selectedCalendarDate))")
                        .font(.noonmarkSystem(size: 15, weight: .bold))
                        .foregroundStyle(Theme.text1)
                        .monospacedDigit()
                    Text(NoonmarkStore.weekday(store.selectedCalendarDate))
                        .font(.noonmarkSystem(size: 11))
                        .foregroundStyle(Theme.text3)
                }

                HStack(spacing: 8) {
                    Text(dayKind.text)
                        .font(.noonmarkSystem(size: 11, weight: .semibold))
                        .foregroundStyle(dayKind.foreground)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(dayKind.background))
                    Text("\(traces.count) 项任务")
                        .font(.noonmarkSystem(size: 11))
                        .foregroundStyle(Theme.text3)
                        .monospacedDigit()
                }
                .padding(.top, 7)

                Button("在 Day Todo 打开这一天 →") {
                    store.selectedDate = store.selectedCalendarDate
                    store.page = .day
                }
                .buttonStyle(.plain)
                .font(.noonmarkSystem(size: 11.5))
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
    @EnvironmentObject private var store: NoonmarkStore
    let trace: DayTrace

    var body: some View {
        HStack(spacing: 9) {
            StatusGlyph(status: trace.status, scale: .compact)

            VStack(alignment: .leading, spacing: 1) {
                MarkdownInlineText(store.definition(for: trace)?.title ?? "")
                    .font(.noonmarkSystem(size: 12.5, weight: .medium))
                    .foregroundStyle(titleColor)
                    .strikethrough(trace.status == .completed || trace.status == .abandoned)
                    .lineLimit(1)
                if metaText.isEmpty == false {
                    Text(metaText)
                        .font(.noonmarkSystem(size: 10.5))
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
    @EnvironmentObject private var store: NoonmarkStore
    @State private var selectedPane: SettingsPane

    init() {
        let initialPane: SettingsPane = CommandLine.arguments.contains("--e2e-settings-groups")
            ? .groups
            : .general
        _selectedPane = State(initialValue: initialPane)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: store.copy.navSettings, subtitle: store.copy.settingsSubtitle)
            ScrollView {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 14) {
                        SettingsPaneToolbar(selectedPane: $selectedPane)
                        SettingsPaneContent(pane: selectedPane)
                            .frame(maxWidth: 740, alignment: .topLeading)
                    }
                    .frame(maxWidth: 780, alignment: .topLeading)
                    if store.engine.preferences.settingsPoemDisplayPolicy.enabled {
                        SettingsPoemAside(text: store.engine.preferences.settingsPoemDisplayPolicy.text)
                            .frame(width: 300)
                            .padding(.top, 40)
                    }
                }
                .padding(.horizontal, NoonmarkVisualMetrics.pageHorizontalPadding)
                .padding(.vertical, 18)
            }
        }
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case groups
    case data
    case sync
    case zhulong
    case privacy

    var id: String { rawValue }

    func title(copy: AppCopy) -> String {
        switch self {
        case .general: copy.preferencesTitle
        case .groups: "组织"
        case .data: copy.dataSectionTitle
        case .sync: copy.syncTitle
        case .zhulong: copy.providerTitle
        case .privacy: copy.privacyTitle
        }
    }

    var systemImage: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .groups: "square.grid.2x2"
        case .data: "square.and.arrow.up.on.square"
        case .sync: "arrow.triangle.2.circlepath"
        case .zhulong: "sparkles"
        case .privacy: "lock.shield"
        }
    }
}

struct SettingsPaneToolbar: View {
    @EnvironmentObject private var store: NoonmarkStore
    @Binding var selectedPane: SettingsPane

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(SettingsPane.allCases) { pane in
                    Button {
                        selectedPane = pane
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: pane.systemImage)
                                .font(.noonmarkSystem(size: 11, weight: .semibold))
                            Text(pane.title(copy: store.copy))
                                .font(.noonmarkSystem(size: 11.5, weight: selectedPane == pane ? .semibold : .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(selectedPane == pane ? Theme.accent : Theme.text2)
                        .padding(.horizontal, 7)
                        .frame(height: 28)
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
            case .groups:
                GroupManagementSettingsCard()
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
    @EnvironmentObject private var store: NoonmarkStore

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
                        .font(.noonmarkSystem(size: 12.5, weight: .medium))
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(store.copy.settingsPoemEditorTitle)
                                .font(.noonmarkSystem(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.text3)
                            Spacer()
                            SmallActionButton(store.copy.resetSettingsPoem) {
                                store.resetSettingsPoemText()
                            }
                        }
                        MarkdownEditor(
                            text: poemTextBinding,
                            placeholder: "输入诗文或 Markdown",
                            style: .body,
                            height: 150
                        )
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
                .font(.noonmarkCustom("Songti SC", size: 18).weight(.semibold))
                .foregroundStyle(Theme.text1.opacity(0.72))
            MarkdownText(text)
                .font(.noonmarkCustom("Songti SC", size: 15))
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
    @EnvironmentObject private var store: NoonmarkStore

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
    @EnvironmentObject private var store: NoonmarkStore

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
                        .font(.noonmarkSystem(size: 11.5))
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
    @EnvironmentObject private var store: NoonmarkStore

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
                                .font(.noonmarkSystem(size: 11.5))
                                .foregroundStyle(Theme.text3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let endpointURL = NoonmarkStore.configuredLocalFirstSyncEndpointURL(for: policy.endpoint) {
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
                                .font(.noonmarkSystem(size: 11.5, weight: .medium))
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
                    .font(.noonmarkSystem(size: 11.5))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ScheduledBackupCard: View {
    @EnvironmentObject private var store: NoonmarkStore

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
                    .font(.noonmarkSystem(size: 11.5))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SyncOptionsCard: View {
    @EnvironmentObject private var store: NoonmarkStore

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.engine.syncEndpointOptions().enumerated()), id: \.element.kind) { index, option in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.copy.syncTitle(for: option.kind))
                            .font(.noonmarkSystem(size: 13, weight: .medium))
                            .foregroundStyle(Theme.text1)
                        Text(store.copy.syncDescription(for: option.kind))
                            .font(.noonmarkSystem(size: 11.5))
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
    @EnvironmentObject private var store: NoonmarkStore

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
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Toggle("启用烛龙", isOn: $store.zhulongProviderDraft.enabled)
                        .toggleStyle(.checkbox)
                        .font(.noonmarkSystem(size: 12.5, weight: .medium))
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
                        .font(.noonmarkSystem(size: 11.5))
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
    @EnvironmentObject private var store: NoonmarkStore

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
                    .font(.noonmarkSystem(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.navSettings)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.chip))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.noonmarkSystem(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                    Text(subtitle)
                        .font(.noonmarkSystem(size: 11.5))
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
                .font(.noonmarkSystem(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.text2)
            Spacer()
            Text(value)
                .font(.noonmarkSystem(size: 11.5, weight: .semibold))
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
                .font(.noonmarkSystem(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .frame(width: 62, alignment: .leading)
            Text(value)
                .font(.noonmarkSystem(size: 11.5, weight: .medium))
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
                .font(.noonmarkSystem(size: 12))
                .foregroundStyle(Theme.text2)
                .lineSpacing(3)
            Spacer(minLength: 0)
        }
    }
}

struct ZhulongPage: View {
    var body: some View {
        ZhulongConvergedHome()
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
                        .font(.noonmarkSystem(size: 11.5, weight: selection == kind ? .semibold : .medium))
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
                .font(.noonmarkSystem(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text3)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.noonmarkSystem(size: 12.5))
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
                .font(.noonmarkSystem(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text3)
            SecureField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.noonmarkSystem(size: 12.5))
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
                .font(.noonmarkSystem(size: 11, weight: .medium))
                .foregroundStyle(Theme.text3)
                .frame(width: 74, alignment: .leading)
            Text(value)
                .font(.noonmarkSystem(size: 12))
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

struct ZhulongScopeChip: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.noonmarkSystem(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.text2)
            Spacer()
            Text(value)
                .font(.noonmarkSystem(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
    }
}

struct ZhulongRail: View {
    @EnvironmentObject private var store: NoonmarkStore

    var body: some View {
        ZhulongWorkspaceRail(workspace: store.zhulongWorkspace)
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
    let intent: String
    let recentSession: ZhulongSession?

    @MainActor
    static func make(for page: NoonmarkStore.Page, store: NoonmarkStore) -> ZhulongContextModel? {
        switch page {
        case .pool:
            let tasks = store.engine.taskPool()
            let contextCount = tasks.filter {
                ($0.definition.descriptionText ?? "").isEmpty == false || $0.chain.activeNoteEntries.isEmpty == false
            }.count
            let unclassifiedCount = tasks.filter { store.isUnclassified($0.chain.id) }.count
            return ZhulongContextModel(
                title: "任务池排期",
                subtitle: "任务池不再单独给本地汇总解释；只把当前队列交给烛龙统一生成排期草稿。",
                stats: [
                    Stat(title: "未排期", value: "\(tasks.count) 项"),
                    Stat(title: "有说明", value: "\(contextCount) 项"),
                    Stat(title: "未分组", value: "\(unclassifiedCount) 项")
                ],
                intent: "给任务池重新排期",
                recentSession: store.recentZhulongSession(matching: [.taskPool, .unfinishedPool])
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
                intent: "检查未来安排并调整承诺",
                recentSession: store.recentZhulongSession(matching: [.taskPool, .unfinishedPool])
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
                intent: "梳理未完成任务的下一步",
                recentSession: store.recentZhulongSession(matching: [.unfinishedPool])
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
                intent: "复看完成轨迹并提取可复用证据",
                recentSession: store.recentZhulongSession(matching: [.completedPool])
            )
        case .day, .calendar, .zhulong, .settings:
            return nil
        }
    }
}

struct ZhulongContextRail: View {
    @EnvironmentObject private var store: NoonmarkStore
    let model: ZhulongContextModel

    var statusText: String {
        store.zhulongProviderDraft.isConfigured ? "Provider 已启用" : "本地模式"
    }

    var entryTitle: String {
        model.recentSession == nil ? "交给烛龙" : "继续最近会话"
    }

    var entrySubtitle: String {
        if let recentSession = model.recentSession {
            return "\(recentSession.primaryIntent) · \(store.zhulongWorkspaceStatus(recentSession))"
        }
        return "建立加密会话，先确认本次范围；没有 Provider 时仍可使用本地证据。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("烛龙")
                    .font(.noonmarkSystem(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .tracking(0.8)
                Spacer()
                StatusPill(text: statusText, color: store.zhulongProviderDraft.isConfigured ? Theme.accent : Theme.ok)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(model.title)
                    .font(.noonmarkSystem(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Text(model.subtitle)
                    .font(.noonmarkSystem(size: 12))
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
                        .font(.noonmarkSystem(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entryTitle)
                            .font(.noonmarkSystem(size: 12.5, weight: .semibold))
                            .foregroundStyle(Theme.text1)
                        Text(entrySubtitle)
                            .font(.noonmarkSystem(size: 11))
                            .foregroundStyle(Theme.text3)
                            .lineLimit(3)
                    }
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.noonmarkSystem(size: 10, weight: .semibold))
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
        store.page = .zhulong
        if let recentSession = model.recentSession {
            store.zhulongWorkspace.selectSession(recentSession.id)
        } else {
            store.startZhulongWorkspaceSession(intent: model.intent)
        }
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
    static func make(for page: NoonmarkStore.Page, store: NoonmarkStore) -> SidebarAnalysisModel? {
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
                    plans.first.map { "最近计划：\(NoonmarkStore.displayDate($0.trace.date)) · \($0.definition.title)" } ?? "未来计划为空。",
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
                    completed.first.map { "最近完成：\(NoonmarkStore.displayDate($0.trace.date)) · \($0.definition.title)" } ?? "暂无完成记录。",
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
    let unclassifiedCount: Int
    let groups: [Group]

    var totalCount: Int { orderedTasks.count }
    var oldestCreatedAt: Date? { orderedTasks.first?.definition.createdAt }

    @MainActor
    static func make(store: NoonmarkStore) -> PoolSummaryModel {
        let orderedTasks = store.engine.taskPool()
            .sorted { $0.definition.createdAt < $1.definition.createdAt }
        let contextCount = orderedTasks.filter {
            ($0.definition.descriptionText ?? "").isEmpty == false || $0.chain.activeNoteEntries.isEmpty == false
        }.count
        let plannedCount = orderedTasks.filter { $0.definition.plannedSubtasks.isEmpty == false }.count
        let needsDetailCount = orderedTasks.filter {
            ($0.definition.descriptionText ?? "").isEmpty &&
                $0.chain.activeNoteEntries.isEmpty &&
                $0.definition.plannedSubtasks.isEmpty
        }.count
        let unclassifiedCount = orderedTasks.filter { store.isUnclassified($0.chain.id) }.count

        var groups: [Group] = []
        var groupIndexes: [String: Int] = [:]
        for task in orderedTasks {
            let category = store.currentClassification(for: task.chain.id)?.category
            let id = category?.id ?? "no-primary-category"
            if let index = groupIndexes[id] {
                groups[index].count += 1
            } else {
                groupIndexes[id] = groups.count
                groups.append(
                    Group(
                        id: id,
                        title: category?.name ?? "未分组",
                        color: category?.color ?? Theme.text3,
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
            unclassifiedCount: unclassifiedCount,
            groups: groups
        )
    }
}

struct PoolSummaryRail: View {
    @EnvironmentObject private var store: NoonmarkStore

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
                .font(.noonmarkSystem(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .tracking(0.8)

            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text("\(model.totalCount)")
                    .font(.noonmarkSystem(size: 32, weight: .semibold))
                    .foregroundStyle(Theme.navPool)
                    .monospacedDigit()
                Text("未排期")
                    .font(.noonmarkSystem(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text2)
            }

            Text(model.oldestCreatedAt.map { "最早入池 \(PoolSummaryFormatter.createdAtLabel($0))" } ?? "现在是空的。")
                .font(.noonmarkSystem(size: 11.5))
                .foregroundStyle(Theme.text2)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                PoolSummaryMetric(label: "有说明", value: model.contextCount, color: Theme.navPool)
                PoolSummaryMetric(label: "已拆分", value: model.plannedCount, color: Theme.accent)
                PoolSummaryMetric(label: "待补充", value: model.needsDetailCount, color: Theme.warn)
                PoolSummaryMetric(label: "未分组", value: model.unclassifiedCount, color: Theme.text3)
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
                .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.text3)
            Text("\(value)")
                .font(.noonmarkSystem(size: 18, weight: .semibold))
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
                    .font(.noonmarkSystem(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text1)
                    .lineLimit(1)
                Spacer()
                Text("\(group.count) 项")
                    .font(.noonmarkSystem(size: 11, weight: .semibold))
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
                .font(.noonmarkSystem(size: 10.5))
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
    @EnvironmentObject private var store: NoonmarkStore
    let task: PoolTask

    var meta: String {
        let hasDescription = (task.definition.descriptionText ?? "").isEmpty == false
        let hasNote = task.chain.activeNoteEntries.isEmpty == false
        let plannedSubtaskCount = task.definition.plannedSubtasks.count
        var parts = ["\(PoolSummaryFormatter.createdAtLabel(task.definition.createdAt)) 入池"]
        if store.isUnclassified(task.chain.id) {
            parts.append("未分组")
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
                MarkdownInlineText(task.definition.title)
                    .font(.noonmarkSystem(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.text1)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let classification = store.displayableClassification(for: task.chain.id) {
                    TaskClassificationBadges(
                        display: classification,
                        taskTitle: task.definition.title,
                        accessibilityNamespace: TaskClassificationAccessibilityNamespace(
                            surface: "pool-summary-row",
                            instanceID: task.chain.id.description
                        )
                    )
                    .padding(.top, 4)
                }

                Text(meta)
                    .font(.noonmarkSystem(size: 10.5))
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
                    .font(.noonmarkSystem(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .tracking(0.8)
                Text(model.subtitle)
                    .font(.noonmarkSystem(size: 12))
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
                .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.text3)
            Text(metric.value)
                .font(.noonmarkSystem(size: 18, weight: .semibold))
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
                            .font(.noonmarkSystem(size: 11.5))
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
                .font(.noonmarkSystem(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 18, height: 18)
            Text(text)
                .font(.noonmarkSystem(size: 11.5))
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
    @EnvironmentObject private var store: NoonmarkStore

    var zhulongContextModel: ZhulongContextModel? {
        guard store.usesZhulongContextRail else { return nil }
        return ZhulongContextModel.make(for: store.page, store: store)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
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
            .padding(NoonmarkVisualMetrics.detailPadding)
        }
        .background(Theme.panel)
    }

    var hint: String {
        switch store.page {
        case .pool: "选中任务查看详情与排期操作。"
        case .future: "选中计划查看详情，可改期或回池。"
        case .unfinished: "选中任务链查看未完成明细。"
        case .completed: "选中记录可跳转当天或复制为新任务。"
        case .zhulong: "选择或继续烛龙会话后，在这里查看授权范围、证据和待确认 Todo diff。"
        default: ""
        }
    }
}

struct RailHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.noonmarkSystem(size: 12))
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
                .font(.noonmarkSystem(size: 11, weight: .semibold))
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
                .font(.noonmarkSystem(size: 11, weight: .semibold))
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
                .font(.noonmarkSystem(size: 13, weight: .semibold))
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
            MarkdownText(title)
                .font(.noonmarkSystem(size: 14, weight: .semibold))
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

struct EditableDetailTitleRow<Trailing: View>: View {
    let title: String
    let editable: Bool
    let onCommit: (String) -> Void
    @ViewBuilder let trailing: Trailing
    @State private var draft: String

    init(
        _ title: String,
        editable: Bool,
        onCommit: @escaping (String) -> Void,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.editable = editable
        self.onCommit = onCommit
        self.trailing = trailing()
        _draft = State(initialValue: title)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if editable {
                MarkdownEditor(
                    text: $draft,
                    placeholder: "任务标题",
                    style: .title,
                    showsSurface: false,
                    onCommit: commitDraft,
                    onEndEditing: commitDraft
                )
                    .onChange(of: title) { _, newValue in
                        if draft != newValue {
                            draft = newValue
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                MarkdownText(title, fallback: "未命名任务")
                    .font(.noonmarkSystem(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            trailing
                .padding(.top, 1)
                .frame(minWidth: 24, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func commitDraft() {
        let nextTitle = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard nextTitle.isEmpty == false else {
            draft = title
            return
        }
        guard nextTitle != title else {
            draft = title
            return
        }
        draft = nextTitle
        onCommit(nextTitle)
    }
}

extension EditableDetailTitleRow where Trailing == EmptyView {
    init(_ title: String, editable: Bool, onCommit: @escaping (String) -> Void) {
        self.init(title, editable: editable, onCommit: onCommit) {
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
    @EnvironmentObject private var store: NoonmarkStore
    let item: CompletedPoolItem

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
                editable: false
            )

            HStack(spacing: 8) {
                StatusChip(status: .completed)
                Text("\(NoonmarkStore.displayDate(item.trace.date)) \(NoonmarkStore.weekday(item.trace.date))")
                    .font(.noonmarkSystem(size: 11))
                    .foregroundStyle(Theme.text3)
            }

            DetailProgressSection(
                traceID: item.trace.id,
                progress: store.engine.traceProgress(for: item.trace.id),
                editable: false
            )

            TaskClassificationDetailSection(
                trace: item.trace,
                taskTitle: item.definition.title,
                editable: false
            )

            TraceTimelineSection(trace: item.trace)

            DetailNotesSection(
                traceID: item.trace.id,
                entries: item.trace.activeNoteEntries,
                editable: false,
                placeholder: store.copy.noteComposerPlaceholder
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
    @EnvironmentObject private var store: NoonmarkStore
    let trace: DayTrace

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("任务轨迹")
                    .font(.noonmarkSystem(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .tracking(0.6)
                Spacer()
                MarkdownText(summaryText)
                    .font(.noonmarkSystem(size: 11))
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
            .font(.noonmarkSystem(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Capsule().fill(Theme.chip))
    }
}

struct CompletedSubtaskDetail: View {
    @EnvironmentObject private var store: NoonmarkStore
    let record: CompletedSubtaskRecord

    var completedAt: String { NoonmarkStore.displayTime(record.subtask.completedAt) ?? "未记录" }

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
                Text("\(NoonmarkStore.displayDate(record.date)) \(NoonmarkStore.weekday(record.date))")
                    .font(.noonmarkSystem(size: 11))
                    .foregroundStyle(Theme.text3)
            }

            CompletionSummaryCard(items: [
                CompletionSummaryItem(label: "父任务", value: record.parentDefinition.title, color: Theme.text2),
                CompletionSummaryItem(label: "难度", value: record.subtask.difficulty.label, color: record.subtask.difficulty == .hard ? Theme.warn : Theme.text2),
                CompletionSummaryItem(label: "完成", value: NoonmarkStore.displayDate(record.date), color: Theme.ok),
                CompletionSummaryItem(label: "时间", value: completedAt, color: Theme.text2)
            ])

            Notice(text: "子任务完成事实独立展示，父任务轨迹仍保留在当天。", tone: .locked)

            TaskClassificationDetailSection(
                trace: record.parentTrace,
                taskTitle: record.parentDefinition.title,
                editable: false
            )

            DetailSection("父任务") {
                VStack(alignment: .leading, spacing: 7) {
                    MarkdownInlineText(record.parentDefinition.title)
                        .font(.noonmarkSystem(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                        .lineLimit(2)
                    MarkdownText(record.parentDefinition.descriptionText ?? "", fallback: "未填写描述")
                        .font(.noonmarkSystem(size: 11.5))
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
                        .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                        .frame(width: 38, alignment: .leading)
                    Text(item.value)
                        .font(.noonmarkSystem(size: 11.5, weight: .medium))
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
    @EnvironmentObject private var store: NoonmarkStore
    let trace: DayTrace
    let definition: TaskDefinition

    var progress: TraceProgress { store.engine.traceProgress(for: trace.id) }
    var subtasks: [Subtask] { store.subtasks(for: trace.id) }
    var canEditText: Bool { trace.status == .pending && trace.date >= store.today }
    var canRenameTitle: Bool { trace.status == .pending && trace.date >= store.today }
    var canEditManualProgress: Bool { trace.status == .pending && trace.date == store.today && subtasks.isEmpty }
    var canAddSubtask: Bool { trace.status == .pending && trace.date >= store.today }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DetailHeader("任务详情", onClose: { store.clearSelection() }, trailing: {
                IconMenuButton(menuContent: {
                    TaskContextMenu(trace: trace)
                })
            })
            EditableDetailTitleRow(definition.title, editable: canRenameTitle) {
                store.renameTraceTitle(traceID: trace.id, title: $0)
            }

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
                Text("\(NoonmarkStore.displayDate(trace.date)) \(NoonmarkStore.weekday(trace.date))")
                    .font(.noonmarkSystem(size: 11))
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
            TaskClassificationDetailSection(
                trace: trace,
                taskTitle: definition.title,
                editable: canEditText
            )
            DetailSection("子任务") {
                VStack(spacing: 6) {
                    ForEach(subtasks, id: \.id) { subtask in
                        SubtaskRow(subtask: subtask)
                    }
                    if subtasks.isEmpty && !canAddSubtask {
                        Text("暂无子任务")
                            .font(.noonmarkSystem(size: 12))
                            .foregroundStyle(Theme.text3)
                    }
                    if canAddSubtask {
                        MarkdownEditor(
                            text: $store.detailSubtaskText,
                            placeholder: "添加子任务，回车确认",
                            style: .compact,
                            commitsOnReturn: true,
                            onCommit: { store.addDetailSubtask(traceID: trace.id) }
                        )
                            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                    }
                }
            }
            DetailSection("任务轨迹") {
                Timeline(trace: trace)
            }
            DetailNotesSection(
                traceID: trace.id,
                entries: trace.activeNoteEntries,
                editable: canEditText,
                placeholder: store.copy.noteComposerPlaceholder
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
                .font(.noonmarkSystem(size: 11, weight: .semibold))
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
            .font(.noonmarkSystem(size: 13, weight: .bold))
            .foregroundStyle(progress.percent == 100 ? Theme.ok : Theme.accent)
            .monospacedDigit()
    }
}

struct DetailProgressControl: View {
    @EnvironmentObject private var store: NoonmarkStore
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
                        .font(.noonmarkSystem(size: 10))
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
            MarkdownEditor(
                text: normalizedBinding,
                placeholder: placeholder,
                style: .body,
                warm: warm
            )
                .italic(warm)
                .foregroundStyle(warm ? Theme.text2 : Theme.text1)
                .frame(minHeight: 86)
                .background(RoundedRectangle(cornerRadius: 7).fill(warm ? Theme.noteBackground : Theme.panel2))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
        } else {
            MarkdownText(text, fallback: fallback)
                .font(.noonmarkSystem(size: 12))
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

struct DetailNotesSection: View {
    @EnvironmentObject private var store: NoonmarkStore
    let traceID: DayTraceID
    let entries: [TaskNoteEntry]
    let editable: Bool
    let placeholder: String

    var body: some View {
        TaskNoteEntriesSection(
            entries: entries,
            editable: editable,
            placeholder: placeholder,
            newNoteText: $store.detailNoteText,
            onAppend: { store.appendTraceNote(traceID: traceID) },
            onEdit: { noteID, body in
                store.editTraceNote(traceID: traceID, noteID: noteID, body: body)
            },
            onDelete: { noteID in
                store.deleteTraceNote(traceID: traceID, noteID: noteID)
            }
        )
    }
}

struct TaskNoteEntriesSection: View {
    @EnvironmentObject private var store: NoonmarkStore

    let entries: [TaskNoteEntry]
    let editable: Bool
    let placeholder: String
    @Binding var newNoteText: String
    let onAppend: () -> Bool
    let onEdit: (TaskNoteEntryID, String) -> Bool
    let onDelete: (TaskNoteEntryID) -> Bool

    @State private var editingNoteID: TaskNoteEntryID?
    @State private var editDraft = ""

    var body: some View {
        if entries.isEmpty == false || editable {
            DetailSection(store.copy.noteSectionTitle) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        DetailNoteEntryRow(
                            entry: entry,
                            editable: editable,
                            isEditing: editingNoteID == entry.id,
                            editDraft: $editDraft,
                            onStartEditing: {
                                editDraft = entry.body
                                editingNoteID = entry.id
                            },
                            onCancelEditing: {
                                editDraft = ""
                                editingNoteID = nil
                            },
                            onSaveEditing: {
                                let body = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard body.isEmpty == false else { return }
                                guard onEdit(entry.id, body) else { return }
                                editDraft = ""
                                editingNoteID = nil
                            },
                            onDelete: {
                                guard onDelete(entry.id) else { return }
                                editDraft = ""
                                editingNoteID = nil
                            }
                        )

                        if index < entries.count - 1 || editable {
                            Divider()
                                .overlay(Theme.line)
                        }
                    }

                    if editable {
                        MarkdownEditor(
                            text: $newNoteText,
                            placeholder: placeholder,
                            style: .compact,
                            warm: true,
                            showsSurface: false,
                            height: 32,
                            commitsOnReturn: true,
                            onCommit: {
                                _ = onAppend()
                            },
                            nativeAccessibilityIdentifier: "detail.note.composer"
                        )
                            .foregroundStyle(Theme.text1)
                            .accessibilityIdentifier("detail.note.composer")
                            .background {
                                AppE2EViewAnchor(
                                    identifier: "detail.note.composer.copy",
                                    verificationText: placeholder
                                )
                            }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.noteBackground))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .accessibilityIdentifier("detail.note.section")
            .background {
                AppE2EViewAnchor(
                    identifier: "detail.note.section",
                    verificationText: store.copy.noteSectionTitle
                )
            }
        }
    }
}

struct DetailNoteEntryRow: View {
    @EnvironmentObject private var store: NoonmarkStore

    let entry: TaskNoteEntry
    let editable: Bool
    let isEditing: Bool
    @Binding var editDraft: String
    let onStartEditing: () -> Void
    let onCancelEditing: () -> Void
    let onSaveEditing: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 8) {
                Text(Self.timestampFormatter.string(from: entry.createdAt))
                    .font(.noonmarkSystem(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.text3)
                    .monospacedDigit()
                Spacer(minLength: 0)
                if editable, !isEditing {
                    TaskNoteOverflowControl(
                        entryID: entry.id,
                        copy: store.copy,
                        onEdit: onStartEditing,
                        onDelete: onDelete
                    )
                    .frame(width: 18, height: 18)
                }
            }

            if isEditing {
                MarkdownEditor(
                    text: $editDraft,
                    placeholder: store.copy.editNotePlaceholder,
                    style: .body,
                    warm: true,
                    showsSurface: false,
                    height: 58,
                    nativeAccessibilityIdentifier: "detail.note.editor.\(entry.id.description)"
                )
                    .foregroundStyle(Theme.text1)
                    .frame(minHeight: 58)
                    .accessibilityIdentifier("detail.note.editor.\(entry.id.description)")
                    .background {
                        AppE2EViewAnchor(
                            identifier: "detail.note.editor.state.\(entry.id.description)",
                            verificationText: store.copy.editNotePlaceholder
                        )
                    }

                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    TaskNoteTextActionControl(
                        title: store.copy.cancel,
                        identifier: "detail.note.cancel.\(entry.id.description)",
                        emphasis: .secondary,
                        action: onCancelEditing
                    )
                    TaskNoteTextActionControl(
                        title: store.copy.save,
                        identifier: "detail.note.save.\(entry.id.description)",
                        emphasis: .accent,
                        isEnabled: editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                        action: onSaveEditing
                    )
                }
            } else {
                MarkdownText(entry.body)
                    .font(.noonmarkSystem(size: 12))
                    .italic()
                    .foregroundStyle(Theme.text2)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("detail.note.entry.\(entry.id.description)")
        .background {
            AppE2EViewAnchor(identifier: "detail.note.entry.state.\(entry.id.description)")
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_SG")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

struct TraceContextCard: View {
    @EnvironmentObject private var store: NoonmarkStore
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
        .font(.noonmarkSystem(size: 11))
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
    @EnvironmentObject private var store: NoonmarkStore
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
                                .font(.noonmarkSystem(size: 11.5, weight: .semibold))
                                .foregroundStyle(nodeStyle.labelColor)
                            if isCurrent {
                                TimelineCurrentBadge()
                            }
                            Spacer(minLength: 0)
                            Text("#\(item.continuationSeq + 1)")
                                .font(.noonmarkSystem(size: 10))
                                .foregroundStyle(Theme.text3)
                                .monospacedDigit()
                        }
                        Text("\(NoonmarkStore.displayDate(item.date)) \(NoonmarkStore.weekday(item.date))")
                            .font(.noonmarkSystem(size: 10.5))
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
            .font(.noonmarkSystem(size: 8.5, weight: .bold))
            .foregroundStyle(style.glyphForeground)
            .frame(width: 14, height: 14)
            .background(Circle().fill(style.glyphBackground))
            .overlay(Circle().stroke(style.glyphBorder, lineWidth: 1.5))
    }
}

struct TimelineCurrentBadge: View {
    var body: some View {
        Text("当前所在")
            .font(.noonmarkSystem(size: 9, weight: .medium))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(Capsule().stroke(Theme.accent, lineWidth: 1))
    }
}

struct PoolDetail: View {
    @EnvironmentObject private var store: NoonmarkStore
    let task: PoolTask

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DetailHeader("任务池", onClose: { store.clearSelection() }, trailing: {
                IconMenuButton(menuContent: {
                    Button("删除任务", role: .destructive) { store.deletePoolTask(task.chain.id) }
                })
            })
            EditableDetailTitleRow(task.definition.title, editable: true) {
                store.renamePoolTask(chainID: task.chain.id, title: $0)
            }
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
                    .font(.noonmarkSystem(size: 11))
                    .foregroundStyle(Theme.text3)
            }
            DetailSection("分组与标签") {
                TaskClassificationEditor(
                    chainID: task.chain.id,
                    taskTitle: task.definition.title
                )
            }
            DetailSection("子任务") {
                PoolPlannedSubtasksSection(task: task)
            }
            DetailSection("状态") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("尚未进入任何 Day Todo。排期后会生成对应日期的日轨迹。")
                    Text(task.chain.state == .active ? "任务链状态：活跃" : "任务链状态：已关闭")
                }
                .font(.noonmarkSystem(size: 12))
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
                        SmallActionButton(store.copy.scheduleTomorrow) { store.schedulePoolTask(task.chain.id, date: NoonmarkStore.offset(store.today, by: 1)) }
                    }
                    SmallActionButton(store.copy.schedulePickSpecificDate) { store.showingPicker = .schedulePool(task.chain.id) }
                }
            }
            PoolNotesSection(chainID: task.chain.id, entries: task.chain.activeNoteEntries)
        }
    }
}

struct PoolPlannedSubtasksSection: View {
    @EnvironmentObject private var store: NoonmarkStore
    let task: PoolTask

    var plannedSubtasks: [PlannedSubtask] {
        task.definition.plannedSubtasks.sorted { $0.position < $1.position }
    }

    var body: some View {
        VStack(spacing: 6) {
            ForEach(plannedSubtasks) { plannedSubtask in
                PlannedSubtaskRow(chainID: task.chain.id, plannedSubtask: plannedSubtask)
            }
            MarkdownEditor(
                text: $store.detailSubtaskText,
                placeholder: "添加子任务，回车确认",
                style: .compact,
                commitsOnReturn: true,
                onCommit: { store.addPoolPlannedSubtask(chainID: task.chain.id) }
            )
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
        }
    }
}

struct PlannedSubtaskRow: View {
    @EnvironmentObject private var store: NoonmarkStore
    let chainID: TaskChainID
    let plannedSubtask: PlannedSubtask

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 5)
                .fill(Theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line2, lineWidth: 1.5))
                .frame(width: 15, height: 15)

            MarkdownInlineText(plannedSubtask.title)
                .font(.noonmarkSystem(size: 12))
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
                        .font(.noonmarkSystem(size: 9, weight: .semibold))
                    Text(plannedSubtask.difficulty.label)
                    Image(systemName: "chevron.down")
                        .font(.noonmarkSystem(size: 8, weight: .bold))
                }
                .font(.noonmarkSystem(size: 9, weight: .bold))
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
                    .font(.noonmarkSystem(size: 8, weight: .bold))
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
    @EnvironmentObject private var store: NoonmarkStore
    let chainID: TaskChainID
    let entries: [TaskNoteEntry]

    var body: some View {
        TaskNoteEntriesSection(
            entries: entries,
            editable: true,
            placeholder: store.copy.noteComposerPlaceholder,
            newNoteText: $store.detailNoteText,
            onAppend: { store.appendPoolNote(chainID: chainID) },
            onEdit: { noteID, body in
                store.editPoolNote(chainID: chainID, noteID: noteID, body: body)
            },
            onDelete: { noteID in
                store.deletePoolNote(chainID: chainID, noteID: noteID)
            }
        )
    }
}

struct FuturePlanDetail: View {
    @EnvironmentObject private var store: NoonmarkStore
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
            EditableDetailTitleRow(definition.title, editable: true) {
                store.renameTraceTitle(traceID: trace.id, title: $0)
            }

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
                Text("\(NoonmarkStore.displayDate(trace.date)) \(NoonmarkStore.weekday(trace.date))")
                    .font(.noonmarkSystem(size: 11))
                    .foregroundStyle(Theme.text3)
            }

            PlanSummaryCard(items: [
                PlanSummaryItem(label: "日期", value: NoonmarkStore.displayDate(trace.date), color: Theme.navFuture),
                PlanSummaryItem(label: "优先级", value: "\(trace.priority)", color: Theme.text2),
                PlanSummaryItem(label: "状态", value: "未到期", color: Theme.text2)
            ])

            Notice(text: "未来计划可改期、排序或回池；到达当天前不能标记完成。", tone: .locked)

            TaskClassificationDetailSection(
                trace: trace,
                taskTitle: definition.title,
                editable: true
            )

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
                entries: trace.activeNoteEntries,
                editable: true,
                placeholder: store.copy.noteComposerPlaceholder
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
                        .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                        .frame(width: 44, alignment: .leading)
                    Text(item.value)
                        .font(.noonmarkSystem(size: 11.5, weight: .medium))
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
    @EnvironmentObject private var store: NoonmarkStore
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
                    Text("\(NoonmarkStore.displayDate(trace.date)) \(NoonmarkStore.weekday(trace.date))")
                        .font(.noonmarkSystem(size: 11))
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

                TaskClassificationDetailSection(
                    trace: trace,
                    taskTitle: item.definition.title,
                    editable: false
                )

                DetailSection("任务轨迹") {
                    Timeline(trace: trace)
                }

                DetailNotesSection(
                    traceID: trace.id,
                    entries: trace.activeNoteEntries,
                    editable: false,
                    placeholder: store.copy.noteComposerPlaceholder
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
                Text("已延续到 \(NoonmarkStore.displayDate(active.date))")
                    .foregroundStyle(Theme.accent)
            }
            Spacer(minLength: 0)
        }
        .font(.noonmarkSystem(size: 11))
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
    @EnvironmentObject private var store: NoonmarkStore

    var day: Day? { store.engine.days[store.selectedDate] }
    var stats: DailyReviewStats { store.engine.dailyReviewStats(date: store.selectedDate) }
    var noReview: Bool { store.isFuture }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("每日复盘")
                    .font(.noonmarkSystem(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .tracking(0.8)
                if let message = store.reviewAutosaveMessage {
                    ReviewSavedIndicator(text: message)
                }
                Spacer()
                Text("\(NoonmarkStore.displayDate(store.selectedDate)) \(NoonmarkStore.weekday(store.selectedDate))")
                    .font(.noonmarkSystem(size: 11))
                    .foregroundStyle(Theme.text3)
            }
            if store.isHistory {
                Text("历史日复盘可随时补写")
                    .font(.noonmarkSystem(size: 11))
                    .foregroundStyle(Theme.accent)
            }
            if store.selectedDate == store.today {
                ZhulongReviewEntryButton()
            }
            if noReview {
                Text("未来日还没有复盘。到了这一天，复盘会在这里生成。")
                    .font(.noonmarkSystem(size: 12))
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
                .font(.noonmarkSystem(size: 8.5, weight: .bold))
            Text(text)
        }
        .font(.noonmarkSystem(size: 10))
        .foregroundStyle(Theme.ok.opacity(0.9))
    }
}

struct ZhulongReviewEntryButton: View {
    @EnvironmentObject private var store: NoonmarkStore

    var body: some View {
        Button {
            store.requestZhulongDailyReviewFromReviewRail()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.noonmarkSystem(size: 11, weight: .semibold))
                Text(store.copy.analyzeTodayWithZhulong)
                    .font(.noonmarkSystem(size: 11.5, weight: .semibold))
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
                    .font(.noonmarkSystem(size: 10, weight: .semibold))
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
                    .font(.noonmarkSystem(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                Spacer()
                Text("\(stats.total)")
                    .font(.noonmarkSystem(size: 22, weight: .semibold))
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
        .font(.noonmarkSystem(size: 11))
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
                .font(.noonmarkSystem(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.text2)
            MarkdownEditor(text: $text, placeholder: placeholder, style: .body)
                .frame(minHeight: 92)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
        }
    }
}

struct DatePickerSheet: View {
    @EnvironmentObject private var store: NoonmarkStore
    let state: PickerSheetState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(state.purpose.title)
                .font(.noonmarkSystem(size: 14, weight: .semibold))
            Text(state.purpose.rangeHint)
                .font(.noonmarkSystem(size: 11.5))
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
                                    .font(.noonmarkSystem(size: 12.5))
                                Spacer()
                                Text(choice.subtitle)
                                    .font(.noonmarkSystem(size: 11))
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
    @EnvironmentObject private var store: NoonmarkStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("从任务池排期到这一天")
                .font(.noonmarkSystem(size: 14, weight: .semibold))
            if store.selectedDate < store.today {
                Notice(text: "任务池不能排期到过去日期。请先切到今天或未来日期。", tone: .locked)
            } else {
                ForEach(store.engine.taskPool(), id: \.chain.id) { task in
                    Button {
                        store.schedulePoolTask(task.chain.id, date: store.selectedDate)
                        store.showingFromPoolPicker = false
                    } label: {
                        HStack {
                            MarkdownInlineText(task.definition.title)
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
    @EnvironmentObject private var store: NoonmarkStore

    var oldTitle: String {
        guard let trace = store.selectedTrace else { return "" }
        return store.definition(for: trace)?.title ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("变更为新任务")
                .font(.noonmarkSystem(size: 14, weight: .semibold))
            Text("旧任务会保留在当天并标注已变更，新任务开启新的任务链。")
                .font(.noonmarkSystem(size: 12))
                .foregroundStyle(Theme.text2)
            MarkdownText(oldTitle)
                .font(.noonmarkSystem(size: 12))
                .foregroundStyle(Theme.text3)
                .strikethrough()
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
            MarkdownEditor(
                text: $store.changeText,
                placeholder: "新的任务标题",
                style: .title,
                onCommit: { store.changeSelectedTrace() }
            )
                .frame(minHeight: 58)
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
                .font(.noonmarkSystem(size: 11, weight: .semibold))
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
                .font(.noonmarkSystem(size: 12, weight: selected ? .semibold : .regular))
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
                .font(.noonmarkSystem(size: 12, weight: isSelected ? .semibold : .regular))
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
                        .font(.noonmarkSystem(size: 21, weight: .bold))
                    if let badge {
                        StatusPill(text: badge, color: badgeColor)
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.noonmarkSystem(size: 12))
                        .foregroundStyle(Theme.text3)
                }
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, NoonmarkVisualMetrics.pageHorizontalPadding)
        .padding(.vertical, 14)
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
            .font(.noonmarkSystem(size: 12))
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
            .font(.noonmarkSystem(size: 11.5))
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
                .font(.noonmarkSystem(size: 8, weight: .bold))
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
            .font(.noonmarkSystem(size: 11, weight: .semibold))
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
            .font(.noonmarkSystem(size: scale == .compact ? 10 : 11, weight: .bold))
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
        .font(.noonmarkSystem(size: scale == .compact ? 10.5 : 11, weight: .medium))
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
        .font(.noonmarkSystem(size: 12))
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
                .font(.noonmarkSystem(size: 12.5))
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
                .font(.noonmarkSystem(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .tracking(0.6)
            content
        }
    }
}

struct TaskClassificationDetailSection: View {
    @EnvironmentObject private var store: NoonmarkStore

    let trace: DayTrace
    let taskTitle: String
    let editable: Bool

    var body: some View {
        DetailSection("分组与标签") {
            if editable {
                TaskClassificationEditor(
                    chainID: trace.chainID,
                    taskTitle: taskTitle
                )
            } else if let display = store.displayableClassification(for: trace) {
                VStack(alignment: .leading, spacing: 7) {
                    TaskClassificationBadges(
                        display: display,
                        taskTitle: taskTitle,
                        accessibilityNamespace: TaskClassificationAccessibilityNamespace(
                            surface: "detail",
                            instanceID: trace.id.description
                        )
                    )
                    if display.isHistorical {
                        Text("显示这条任务轨迹形成时的分组与标签；历史事实不可改写。")
                            .font(.noonmarkSystem(size: 10.5))
                            .foregroundStyle(Theme.text3)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
            } else {
                Text("这条任务轨迹形成时未设置分组或标签。")
                    .font(.noonmarkSystem(size: 11.5))
                    .foregroundStyle(Theme.text3)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
            }
        }
    }
}
