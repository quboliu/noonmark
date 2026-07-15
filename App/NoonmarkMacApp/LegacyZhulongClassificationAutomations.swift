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

struct ZhulongStreamE2EAutomation: LaunchAutomationRunnable {
    let task: ZhulongTask?
    let intent: String?
    let createsRichSession: Bool
    let completesDailyReview: Bool
    let interruptsDailyReview: Bool

    @MainActor
    static func fromCommandLine() -> Self? {
        let task = AppLaunchArguments.value(after: "--e2e-start-zhulong-workflow")
            .flatMap(ZhulongTask.init(rawValue:))
        let intent = AppLaunchArguments.value(after: "--e2e-prepare-zhulong-intent")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let createsRichSession = AppLaunchArguments.contains("--e2e-rich-zhulong-session")
        let completesDailyReview = AppLaunchArguments.contains("--e2e-complete-zhulong-daily-review")
        let interruptsDailyReview = AppLaunchArguments.contains("--e2e-interrupt-zhulong-daily-review")
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

struct ZhulongTodoDiffE2EAutomation: LaunchAutomationRunnable {
    let resultURL: URL?

    @MainActor
    static func fromCommandLine() -> Self? {
        guard AppLaunchArguments.contains("--e2e-prepare-zhulong-todo-diff") else {
            return nil
        }
        return Self(
            resultURL: AppLaunchArguments.value(
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

struct ZhulongPersistenceE2EAutomation: LaunchAutomationRunnable {
    let resultURL: URL
    let expectsRecovery: Bool

    @MainActor
    static func fromCommandLine() -> Self? {
        guard let path = AppLaunchArguments.value(
            after: "--e2e-verify-zhulong-persistence-result-url"
        ), path.isEmpty == false else { return nil }
        return Self(
            resultURL: URL(fileURLWithPath: path),
            expectsRecovery: AppLaunchArguments.contains("--e2e-expect-zhulong-recovery")
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

struct ClassificationE2EAutomation: LaunchAutomationRunnable {
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
        let edits = AppLaunchArguments.contains("--e2e-classification-edit")
        let verifies = AppLaunchArguments.contains("--e2e-classification-verify")
        guard edits != verifies else { return nil }
        guard let title = AppLaunchArguments.value(after: "--e2e-classification-title")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            title.isEmpty == false,
            let resultPath = AppLaunchArguments.value(after: "--e2e-classification-result-url")
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
