import AppKit
import Combine
import CryptoKit
import Darwin
import NoonmarkAI
@_spi(ClassificationUserDecision) import NoonmarkCore
import NoonmarkDayContext
import NoonmarkMacRuntime
import NoonmarkMacUIContract
import NoonmarkStorage
import NoonmarkSync
import NoonmarkZhulong
import NoonmarkZhulongAI
import SwiftUI
import UniformTypeIdentifiers

struct PoolContextMenuPresentationE2EAutomation: LaunchAutomationRunnable {
    @MainActor
    static func fromCommandLine() -> Self? {
        guard AppLaunchArguments.contains("--e2e-open-pool-context-menu") else {
            return nil
        }
        return Self()
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        store.page = .pool
        guard let task = store.engine.taskPool().first else { return }
        PoolContextMenuPresentationE2EDriver.start(
            taskIdentifier: task.chain.id.description
        )
    }
}

struct PoolContextMenuActionE2EAutomation: LaunchAutomationRunnable {
    let resultURL: URL
    let chainURL: URL

    @MainActor
    static func fromCommandLine() -> Self? {
        guard let resultPath = AppLaunchArguments.value(
            after: "--e2e-pool-context-menu-action-result-url"
        ), let chainPath = AppLaunchArguments.value(
            after: "--e2e-pool-context-menu-action-chain-url"
        ) else {
            return nil
        }
        return Self(
            resultURL: URL(fileURLWithPath: resultPath),
            chainURL: URL(fileURLWithPath: chainPath)
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        store.page = .pool
        if store.engine.taskPool().isEmpty {
            store.poolText = "E2E 右键排期任务"
            store.addPoolTask()
        }
        guard let task = store.selectedPoolTask ?? store.engine.taskPool().first else { return }
        try? FileManager.default.createDirectory(
            at: chainURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? task.chain.id.description.write(
            to: chainURL,
            atomically: true,
            encoding: .utf8
        )
        PoolContextMenuPresentationE2EDriver.selectScheduleToday(
            taskIdentifier: task.chain.id.description,
            resultURL: resultURL,
            isScheduled: {
                store.engine.taskPool().contains { $0.chain.id == task.chain.id } == false
                    && store.engine.traces.values.contains {
                        $0.chainID == task.chain.id
                            && $0.date == store.today
                            && $0.status == .pending
                    }
            }
        )
    }
}

struct PoolListLayoutE2EAutomation: LaunchAutomationRunnable {
    let resultURL: URL
    let usesMinimumWindowSize: Bool

    @MainActor
    static func fromCommandLine() -> PoolListLayoutE2EAutomation? {
        guard AppLaunchArguments.contains("--e2e-pool-list-layout-probe"),
              let resultPath = AppLaunchArguments.value(
                  after: "--e2e-pool-list-layout-result-url"
              )
        else {
            return nil
        }
        return PoolListLayoutE2EAutomation(
            resultURL: URL(fileURLWithPath: resultPath),
            usesMinimumWindowSize: AppLaunchArguments.contains(
                "--e2e-pool-list-layout-minimum-window"
            )
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        store.page = .pool
        store.isDetailRailExpanded = usesMinimumWindowSize
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
            window.contentView?.layoutSubtreeIfNeeded()
        }
        let expectations = store.engine.taskPool().map { task in
            let classification = store.currentClassification(for: task.chain.id)
            let namespace = TaskClassificationAccessibilityNamespace(
                surface: "pool-row",
                instanceID: task.chain.id.description
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
                forbiddenInlineActionTitles: [
                    store.copy.scheduleToday,
                    store.copy.scheduleTomorrow,
                    store.copy.chooseScheduleDate,
                    store.copy.deleteTask
                ]
            )
        }
        DispatchQueue.main.async {
            PoolListLayoutUIE2EDriver.start(
                expectations: expectations,
                expectedWindowSize: expectedWindowSize,
                expectsExpandedDetailRail: usesMinimumWindowSize,
                resultURL: resultURL
            )
        }
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
        let extremeLabelTask = try createTask(
            title: "极长标签布局验证",
            labels: [
                "极长响应式标签甲甲甲甲甲甲甲甲甲甲甲甲甲甲甲甲甲甲甲甲甲甲甲甲甲甲甲甲甲甲",
                "极长响应式标签乙乙乙乙乙乙乙乙乙乙乙乙乙乙乙乙乙乙乙乙乙乙乙乙乙乙乙乙乙乙",
                "极长响应式标签丙丙丙丙丙丙丙丙丙丙丙丙丙丙丙丙丙丙丙丙丙丙丙丙丙丙丙丙丙丙"
            ]
        )
        return [
            oneLabelTask: usesMinimumWindowSize ? 1 : 2,
            extremeLabelTask: usesMinimumWindowSize ? 0 : 1
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

struct ZhulongE2ESidecarKeySource: ZhulongSidecarKeySource {
    func loadOrCreateKey() throws -> Data {
        Data(repeating: 0x4E, count: 32)
    }
}

struct LaunchSelectionE2EAutomation: LaunchAutomationRunnable {
    var selectionName: String

    @MainActor
    static func fromCommandLine() -> LaunchSelectionE2EAutomation? {
        guard let selectionName = AppLaunchArguments.value(after: "--select"),
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

struct UIEntryE2EAutomation: LaunchAutomationRunnable {
    private enum Mode {
        case classificationManager(selectsLabels: Bool)
        case classificationLabelMenu
        case classificationOverflow
        case markdownEditor
        case zhulongWorkflows
    }

    private let mode: Mode
    private let resultURL: URL
    private let keepsAppOpen: Bool
    private let startGateConfiguration: UIEntryE2EStartGate.Configuration

    @MainActor
    static func fromCommandLine() -> UIEntryE2EAutomation? {
        let opensClassificationManager = AppLaunchArguments.contains(
            "--e2e-classification-manager-via-ui"
        )
        let opensClassificationManagerLabels = AppLaunchArguments.contains(
            "--e2e-classification-manager-labels-via-ui"
        )
        let opensClassificationLabelMenu = AppLaunchArguments.contains(
            "--e2e-classification-label-menu-via-ui"
        )
        let opensClassificationOverflow = AppLaunchArguments.contains(
            "--e2e-classification-overflow-via-ui"
        )
        let exercisesMarkdownEditor = AppLaunchArguments.contains(
            "--e2e-markdown-editor-via-ui"
        )
        let opensZhulongWorkflows = AppLaunchArguments.contains(
            "--e2e-zhulong-workflows-via-ui"
        )
        let selectedModeCount = [
            opensClassificationManager,
            opensClassificationManagerLabels,
            opensClassificationLabelMenu,
            opensClassificationOverflow,
            exercisesMarkdownEditor,
            opensZhulongWorkflows
        ].filter { $0 }.count
        guard selectedModeCount == 1 else { return nil }

        let mode: Mode
        let resultArgument: String
        if opensClassificationManager || opensClassificationManagerLabels {
            mode = .classificationManager(selectsLabels: opensClassificationManagerLabels)
            resultArgument = "--e2e-classification-manager-ui-result-url"
        } else if opensClassificationLabelMenu {
            mode = .classificationLabelMenu
            resultArgument = "--e2e-classification-label-menu-ui-result-url"
        } else if opensClassificationOverflow {
            mode = .classificationOverflow
            resultArgument = "--e2e-classification-overflow-ui-result-url"
        } else if exercisesMarkdownEditor {
            mode = .markdownEditor
            resultArgument = "--e2e-markdown-editor-ui-result-url"
        } else {
            mode = .zhulongWorkflows
            resultArgument = "--e2e-zhulong-workflows-ui-result-url"
        }
        guard let resultPath = AppLaunchArguments.value(after: resultArgument) else {
            return nil
        }
        let resultURL = URL(fileURLWithPath: resultPath)
        return UIEntryE2EAutomation(
            mode: mode,
            resultURL: resultURL,
            keepsAppOpen: AppLaunchArguments.contains("--e2e-ui-entry-keep-open"),
            startGateConfiguration: UIEntryE2EStartGate.fromCommandLine(
                resultURL: resultURL
            )
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        switch startGateConfiguration {
        case .disabled:
            startDriver(on: store)
        case let .invalid(message):
            finishStartGateFailure(message)
        case let .enabled(startGate):
            do {
                try startGate.publishWaiting()
            } catch {
                finishStartGateFailure(error.localizedDescription)
                return
            }
            Task { @MainActor in
                do {
                    let expectedWindowNumber = try await startGate.waitForArm()
                    try startGate.activateMainWindow(
                        expectedWindowNumber: expectedWindowNumber
                    )
                    startDriver(on: store)
                } catch {
                    finishStartGateFailure(error.localizedDescription)
                }
            }
        }
    }

    @MainActor
    private func startDriver(on store: NoonmarkStore) {
        switch mode {
        case let .classificationManager(selectsLabels):
            ClassificationManagerUIE2EDriver.start(
                resultURL: resultURL,
                keepsAppOpen: keepsAppOpen,
                selectsLabels: selectsLabels
            )
        case .classificationLabelMenu:
            guard let task = store.selectedPoolTask ?? store.engine.taskPool().first,
                  let catalog = store.classificationCatalog()
            else {
                try? "failed: 当前任务池没有可用于标签菜单的 fixture".write(
                    to: resultURL,
                    atomically: true,
                    encoding: .utf8
                )
                return
            }
            let selectedIDs = Set(
                store.currentClassification(for: task.chain.id)?.labels.map(\.id) ?? []
            )
            guard let availableLabel = catalog.labels.first(where: {
                $0.lifecycle == .active && selectedIDs.contains($0.id) == false
            }) else {
                try? "failed: fixture 没有未选标签".write(
                    to: resultURL,
                    atomically: true,
                    encoding: .utf8
                )
                return
            }
            ClassificationLabelMenuUIE2EDriver.start(
                chainIdentifier: task.chain.id.description,
                availableLabelIdentifier: availableLabel.id,
                resultURL: resultURL,
                keepsAppOpen: keepsAppOpen
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
                keepsAppOpen: keepsAppOpen,
                invalidatesFirstCaptureReadiness: AppLaunchArguments.contains(
                    "--e2e-classification-overflow-invalidate-first-ready"
                )
            )
        case .markdownEditor:
            if store.engine.taskPool().isEmpty {
                store.poolText = "E2E Markdown 编辑"
                store.addPoolTask()
            }
            guard let task = store.selectedPoolTask ?? store.engine.taskPool().first else {
                try? "failed: 没有可编辑的任务池 fixture".write(
                    to: resultURL,
                    atomically: true,
                    encoding: .utf8
                )
                return
            }
            let initialText = "alpha beta"
            store.page = .pool
            store.selectPool(task.chain.id)
            store.updatePoolTaskText(
                chainID: task.chain.id,
                descriptionText: initialText
            )
            MarkdownEditorUIE2EDriver.start(
                resultURL: resultURL,
                initialText: initialText,
                classificationMenuIdentifier: "classification.editor.category.\(task.chain.id.description)",
                readback: {
                    store.currentDefinition(for: task.chain.id)?.descriptionText ?? ""
                }
            )
        case .zhulongWorkflows:
            ZhulongWorkflowE2EUIInteractionDriver.start(resultURL: resultURL)
        }
    }

    @MainActor
    private func finishStartGateFailure(_ message: String) {
        let result = "failed: UI-entry start gate：\(message)"
        do {
            try FileManager.default.createDirectory(
                at: resultURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try result.write(to: resultURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog(
                "Noonmark UI-entry start gate failure write failed: %@",
                String(describing: error)
            )
        }
        AppViewTreeE2E.writeDump(beside: resultURL)
        E2EApplicationTermination.schedule()
    }
}

struct ReviewE2EAutomation: LaunchAutomationRunnable {
    var summary: String

    @MainActor
    static func fromCommandLine() -> ReviewE2EAutomation? {
        guard AppLaunchArguments.contains("--e2e-update-review") else { return nil }
        return ReviewE2EAutomation(
            summary: AppLaunchArguments.value(after: "--e2e-review-summary") ?? "E2E 自动保存反馈"
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        store.page = .day
        store.selectedDate = store.today
        store.updateReview(summary: summary)
    }
}

struct ReviewZhulongEntryE2EAutomation: LaunchAutomationRunnable {
    var resultURL: URL?

    @MainActor
    static func fromCommandLine() -> ReviewZhulongEntryE2EAutomation? {
        guard AppLaunchArguments.contains("--e2e-review-zhulong-entry") else { return nil }
        let resultURL = AppLaunchArguments.value(after: "--e2e-review-zhulong-result-url")
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

struct ContextMenuActionsE2EAutomation: LaunchAutomationRunnable {
    var resultURL: URL?

    @MainActor
    static func fromCommandLine() -> ContextMenuActionsE2EAutomation? {
        guard AppLaunchArguments.contains("--e2e-context-menu-actions") else { return nil }
        let resultURL = AppLaunchArguments.value(after: "--e2e-context-menu-result-url")
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
                [
                    .markComplete,
                    .pinToTop,
                    .deferTo,
                    .changeToNewTask,
                    .returnToPool,
                    .abandonChain,
                    .deleteNewCurrentDayTask,
                ],
                "current pending"
            )

            let currentWithSubtasksID = try makeTrace(title: "E2E 当前带子任务", date: today, today: today, store: store)
            _ = try store.engine.addSubtask(traceID: currentWithSubtasksID, title: "子任务")
            try assertActions(
                store.contextMenuActions(for: try trace(currentWithSubtasksID, in: store)),
                [
                    .pinToTop,
                    .deferTo,
                    .changeToNewTask,
                    .returnToPool,
                    .abandonChain,
                    .deleteNewCurrentDayTask,
                ],
                "current pending with subtasks"
            )

            let currentWithResolvedSubtasksID = try makeTrace(
                title: "E2E 当前子任务均已处理",
                date: today,
                today: today,
                store: store
            )
            let completedSubtaskID = try store.engine.addSubtask(
                traceID: currentWithResolvedSubtasksID,
                title: "已完成子任务"
            )
            let abandonedSubtaskID = try store.engine.addSubtask(
                traceID: currentWithResolvedSubtasksID,
                title: "已废弃子任务"
            )
            try store.engine.completeSubtask(
                completedSubtaskID,
                today: today
            )
            try store.engine.abandonSubtask(
                abandonedSubtaskID,
                today: today
            )
            try assertActions(
                store.contextMenuActions(
                    for: try trace(
                        currentWithResolvedSubtasksID,
                        in: store
                    )
                ),
                [
                    .markComplete,
                    .pinToTop,
                    .deferTo,
                    .changeToNewTask,
                    .returnToPool,
                    .abandonChain,
                    .deleteNewCurrentDayTask
                ],
                "current pending with resolved subtasks"
            )
            try store.engine.markCompleted(
                traceID: currentWithResolvedSubtasksID,
                today: today
            )
            try assertActions(
                store.contextMenuActions(
                    for: try trace(
                        currentWithResolvedSubtasksID,
                        in: store
                    )
                ),
                [.undoComplete],
                "current completed with subtasks"
            )

            let completedID = try makeTrace(title: "E2E 当前已完成", date: today, today: today, store: store)
            try store.engine.markCompleted(traceID: completedID, today: today)
            try assertActions(
                store.contextMenuActions(for: try trace(completedID, in: store)),
                [.undoComplete],
                "current completed"
            )

            let deferredSourceID = try makeTrace(
                title: "E2E 当前已延期",
                date: today,
                today: today,
                store: store
            )
            _ = try store.engine.deferCurrentTrace(
                traceID: deferredSourceID,
                targetDate: future,
                today: today
            )
            try assertActions(
                store.contextMenuActions(
                    for: try trace(deferredSourceID, in: store)
                ),
                [.withdrawDeferral],
                "current deferred"
            )

            let historicalUnfinishedID = try makeTrace(title: "E2E 历史未完成", date: past, today: past, store: store)
            let historicalCompletedID = try makeTrace(title: "E2E 历史已完成", date: past, today: past, store: store)
            try store.engine.markCompleted(traceID: historicalCompletedID, today: past)
            try store.engine.settleDays(upTo: today)
            try assertActions(
                store.contextMenuActions(for: try trace(historicalUnfinishedID, in: store)),
                [.continueTo, .abandonChain],
                "historical unfinished"
            )
            try assertActions(
                store.contextMenuActions(for: try trace(historicalCompletedID, in: store)),
                [.copyAsNewTask],
                "historical completed"
            )

            let futureID = try makeTrace(title: "E2E 未来待完成", date: future, today: today, store: store)
            try assertActions(
                store.contextMenuActions(for: try trace(futureID, in: store)),
                [.pinToTop, .reschedule, .returnToPool],
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

struct QuickAddUIE2EAutomation: LaunchAutomationRunnable {
    enum Surface: String {
        case day
        case future
        case pool
    }

    let surface: Surface
    let resultURL: URL
    let title: String

    @MainActor
    static func fromCommandLine() -> Self? {
        guard let rawSurface = AppLaunchArguments.value(
            after: "--e2e-quick-add-via-ui"
        ), let surface = Surface(rawValue: rawSurface),
            let title = AppLaunchArguments.value(
                after: "--e2e-quick-add-ui-title"
            ), let resultPath = AppLaunchArguments.value(
                after: "--e2e-quick-add-ui-result-url"
            )
        else { return nil }
        return Self(
            surface: surface,
            resultURL: URL(fileURLWithPath: resultPath),
            title: title
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        switch surface {
        case .day:
            store.page = .day
            store.selectedDate = store.today
        case .future:
            store.page = .day
            store.selectedDate = NoonmarkStore.offset(store.today, by: 1)
        case .pool:
            store.page = .pool
        }

        QuickAddUIE2EDriver.start(
            resultURL: resultURL,
            title: title,
            editorIdentifier: surface == .pool ? "quick-add.pool" : "quick-add.day",
            inputReadback: {
                switch surface {
                case .day, .future: store.quickText
                case .pool: store.poolText
                }
            },
            taskExists: { candidateTitle in
                let chainID: TaskChainID? = switch surface {
                case .day:
                    store.engine.getDayTodo(date: store.today).traces.first { trace in
                        store.definition(for: trace)?.title == candidateTitle
                    }?.chainID
                case .future:
                    store.engine.futurePlans(today: store.today).first { plan in
                        plan.definition.title == candidateTitle
                    }?.trace.chainID
                case .pool:
                    store.engine.taskPool().first { task in
                        task.definition.title == candidateTitle
                    }?.chain.id
                }
                guard let chainID else { return false }
                return store.automaticClassificationStatus(for: chainID)
                    == .waitingForConfiguration
            }
        )
    }
}

struct ReportedBugsE2EAutomation: LaunchAutomationRunnable {
    let resultURL: URL

    @MainActor
    static func fromCommandLine() -> Self? {
        guard AppLaunchArguments.contains("--e2e-reported-bugs"),
              let path = AppLaunchArguments.value(after: "--e2e-reported-bugs-result-url")
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
        if store.toast != store.copy.openSubtasksPreventCompletion {
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
