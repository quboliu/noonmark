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
    let interruptionResultURL: URL?

    @MainActor
    static func fromCommandLine() -> Self? {
        let task = AppLaunchArguments.value(after: "--e2e-start-zhulong-workflow")
            .flatMap(ZhulongTask.init(rawValue:))
        let intent = AppLaunchArguments.value(after: "--e2e-prepare-zhulong-intent")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let createsRichSession = AppLaunchArguments.contains("--e2e-rich-zhulong-session")
        let completesDailyReview = AppLaunchArguments.contains("--e2e-complete-zhulong-daily-review")
        let interruptsDailyReview = AppLaunchArguments.contains("--e2e-interrupt-zhulong-daily-review")
        let interruptionResultURL = AppLaunchArguments.value(
            after: "--e2e-zhulong-interruption-result-url"
        ).map { URL(fileURLWithPath: $0) }
        guard task != nil || intent?.isEmpty == false || createsRichSession ||
            completesDailyReview || interruptsDailyReview
        else { return nil }
        return Self(
            task: task,
            intent: intent,
            createsRichSession: createsRichSession,
            completesDailyReview: completesDailyReview,
            interruptsDailyReview: interruptsDailyReview,
            interruptionResultURL: interruptionResultURL
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
                content: "我在。我们可以先回看今天真实发生了什么，再一起安排明天。"
            )
            store.zhulongWorkspace.appendToCurrentSession(
                author: .user,
                kind: .statement,
                content: "我希望明天只保留一个可以兑现的承诺。"
            )
            store.zhulongWorkspace.appendToCurrentSession(
                author: .zhulong,
                kind: .statement,
                content: "好，我们会把明天的开始点收束为一个可验证的动作。"
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
            if interruptsDailyReview {
                verifyInterruptedApplicationGate(on: store)
            }
        }
    }

    @MainActor
    private func verifyInterruptedApplicationGate(
        on store: NoonmarkStore
    ) {
        guard let interruptionResultURL else { return }
        let durableAfter = store.engine.days[store.today]?.reviewSummary
            == "E2E 已确认的每日复盘"
        let successToastWasSuppressed = store.toast
            != store.copy.confirmedReviewSaved
        let snapshotBeforeBlockedMutation = store.engine.snapshot()
        store.poolText = "E2E pending journal 不得越过门禁"
        store.addPoolTask()
        let followUpMutationWasBlocked = store.engine.snapshot()
            == snapshotBeforeBlockedMutation
            && store.poolText == "E2E pending journal 不得越过门禁"
        let result = durableAfter
            && successToastWasSuppressed
            && followUpMutationWasBlocked
            ? "ok: mutation blocked pending Zhulong application"
            : "failed: durable=\(durableAfter) toast=\(successToastWasSuppressed) gate=\(followUpMutationWasBlocked)"
        try? result.write(
            to: interruptionResultURL,
            atomically: true,
            encoding: .utf8
        )
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
        case .taskPoolAnalysis:
            "分析当前任务池"
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
    private static let postApplyTitle = "E2E 烛龙应用后普通写入"

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
                dataCapabilities: [
                    .structuredOutput,
                    .taskContext,
                    .sessionSummary,
                    .memoryContext
                ]
            )
            var providerDraft = store.zhulongProviderDraft
            providerDraft.displayName = "e2e-todo-diff"
            providerDraft.kind = .localModel
            providerDraft.model = "deterministic-plan"
            providerDraft.enabled = true
            store.zhulongProviderDraft = providerDraft
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
                let result = await exerciseRevisionAndApply(on: store)
                try? result.write(to: resultURL, atomically: true, encoding: .utf8)
                store.persist()
                NSApp.terminate(nil)
            }
        } catch {
            store.zhulongWorkspace.reportUIError("E2E Todo diff 准备失败：\(error.localizedDescription)")
        }
    }

    @MainActor
    private func exerciseRevisionAndApply(on store: NoonmarkStore) async -> String {
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

        guard store.zhulongWorkspace.hasActiveTodoAuthorization == false else {
            return "failed: Todo diff was unexpectedly preauthorized"
        }
        guard store.currentZhulongSessionNeedsScopeAuthorization == false else {
            return "failed: Todo diff fixture Provider identity diverged from its session"
        }

        do {
            try await clickConfirmAndApply(on: store)
            try await waitUntil("Todo diff UI application") {
                store.zhulongWorkspace.selectedSession?.todoApplyReceipts.count == 1
            }
        } catch {
            if let resultURL {
                AppViewTreeE2E.writeDump(beside: resultURL)
            }
            return "failed: real Todo diff confirmation failed: \(error.localizedDescription)"
        }
        let appliedDefinitions = store.engine.definitions.values.filter {
            $0.title == "E2E 编辑后的测量"
                || $0.title == "E2E 拆分后的验证"
        }
        guard let session = store.zhulongWorkspace.selectedSession,
              let receipt = session.todoApplyReceipts.last,
              session.todoApplyReceipts.count == 1,
              session.events.suffix(3).map(\.kind) == [
                  .todoDiffRevised, .todoWriteAuthorized, .todoBatchApplied
              ],
              Set(store.engine.definitions.values.map(\.title)) == [
                  "E2E 编辑后的测量",
                  "E2E 拆分后的验证"
              ],
              appliedDefinitions.allSatisfy({
                  $0.createdAt == receipt.appliedAt
              })
        else { return "failed: atomic application mismatch" }
        let appliedChainIDs = Set(appliedDefinitions.map(\.chainID))
        guard let jobRepository = store.automaticClassificationJobRepository,
              let appliedJobs = try? jobRepository.jobs().filter({
                  appliedChainIDs.contains($0.chainID)
              }),
              appliedJobs.count == 2,
              Set(appliedJobs.map(\.chainID)) == appliedChainIDs,
              appliedJobs.allSatisfy({
                  $0.state == .waitingForConfiguration && $0.generation == 1
              })
        else {
            return "failed: Zhulong tasks and automatic jobs were not atomic"
        }

        store.poolText = Self.postApplyTitle
        store.addPoolTask()
        guard let postApplyDefinition = store.engine.definitions.values
            .first(where: { $0.title == Self.postApplyTitle }),
            postApplyDefinition.createdAt > receipt.appliedAt,
            store.poolText.isEmpty
        else {
            return "failed: ordinary Store mutation did not advance after Zhulong apply"
        }
        return "ok"
    }

    @MainActor
    private func clickConfirmAndApply(on store: NoonmarkStore) async throws {
        let identifier = "zhulong-confirm-apply-todo-diff"
        let streamIdentifier = "zhulong-session-stream"
        let label = AppPresentation(language: store.engine.preferences.language)
            .zhulong.confirmAndApplyAtomically
        var mainWindow: NSWindow?
        try await waitUntil("visible Todo diff session stream") {
            guard AppViewTreeE2E.activateMainWindow(),
                  let window = NSApp.windows.first(where: {
                      $0 is NoonmarkWindow
                          && $0.isVisible
                          && $0.isMiniaturized == false
                  }),
                  AppViewTreeE2E.view(
                      identifier: streamIdentifier,
                      in: window
                  ) != nil
            else {
                return false
            }
            mainWindow = window
            return true
        }
        guard let mainWindow else {
            throw ZhulongTodoDiffUIE2EError.failed(
                "Todo diff main window disappeared"
            )
        }
        try await waitUntil("visible Todo diff confirmation") {
            guard let confirmation = AppViewTreeE2E.view(
                identifier: identifier,
                in: mainWindow
            ) else {
                return false
            }
            return AppViewTreeE2E.verificationText(for: confirmation) == label
        }
        let input = try WindowServerInputDriver()
        let resolveTarget = {
            () throws -> WindowServerInputDriver.PointerCoordinate in
            guard NSApp.isActive,
                  NSApp.keyWindow === mainWindow,
                  let confirmation = AppViewTreeE2E.view(
                      identifier: identifier,
                      in: mainWindow
                  ), AppViewTreeE2E.verificationText(for: confirmation) == label
            else {
                throw ZhulongTodoDiffUIE2EError.failed(
                    "Todo diff confirmation changed before mouseDown"
                )
            }
            let point = confirmation.convert(
                NSPoint(
                    x: confirmation.bounds.midX,
                    y: confirmation.bounds.midY
                ),
                to: nil
            )
            return try input.pointerCoordinate(
                windowPoint: point,
                in: mainWindow
            )
        }
        try await input.postClick(
            at: try resolveTarget(),
            modifiers: [],
            resolveTarget: resolveTarget
        )
    }

    @MainActor
    private func waitUntil(
        _ label: String,
        timeout: TimeInterval = 10,
        condition: @escaping @MainActor () throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw ZhulongTodoDiffUIE2EError.failed("timed out: \(label)")
    }
}

private enum ZhulongTodoDiffUIE2EError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            message
        }
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
        if expectsRecovery {
            E2EApplicationTermination.schedule()
        }
    }
}

struct ZhulongExactRecoveryE2EAutomation: LaunchAutomationRunnable {
    private enum Phase {
        case setup
        case verify
    }

    private enum Scenario: String {
        case exactAfter = "exact-after"
        case preferenceConflict = "preference-conflict"
    }

    private struct State: Codable {
        let formatVersion: Int
        let scenario: String
        let pendingID: String
        let sessionID: String
        let chainID: String
        let definitionSequence: Int
        let taskTitle: String
        let beforeDigest: String
        let afterDigest: String
        let currentDigest: String
        let beforeUpdatedAtBits: String
        let afterUpdatedAtBits: String
        let beforeDataMode: String
        let currentDataMode: String
    }

    private static let exactAfterTitle = "E2E 烛龙精确 after 时钟"
    private static let preferenceConflictTitle =
        "E2E 烛龙偏好冲突不得应用"

    private let phase: Phase
    private let scenario: Scenario
    private let stateURL: URL
    private let resultURL: URL

    @MainActor
    static func fromCommandLine() -> Self? {
        let setupScenario = AppLaunchArguments.value(
            after: "--e2e-setup-zhulong-exact-recovery"
        )
        let verifyScenario = AppLaunchArguments.value(
            after: "--e2e-verify-zhulong-exact-recovery"
        )
        guard (setupScenario == nil) != (verifyScenario == nil),
              let rawScenario = setupScenario ?? verifyScenario,
              let scenario = Scenario(rawValue: rawScenario),
              let statePath = AppLaunchArguments.value(
                  after: "--e2e-zhulong-exact-recovery-state-url"
              ),
              statePath.isEmpty == false,
              let resultPath = AppLaunchArguments.value(
                  after: "--e2e-zhulong-exact-recovery-result-url"
              ),
              resultPath.isEmpty == false
        else {
            return nil
        }
        return Self(
            phase: setupScenario == nil ? .verify : .setup,
            scenario: scenario,
            stateURL: URL(fileURLWithPath: statePath),
            resultURL: URL(fileURLWithPath: resultPath)
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            switch phase {
            case .setup:
                try setup(on: store)
            case .verify:
                try verify(on: store)
            }
            try writeResult("ok")
        } catch {
            try? writeResult(
                "failed: \(error.localizedDescription)"
            )
        }
        E2EApplicationTermination.schedule()
    }

    @MainActor
    private func setup(on store: NoonmarkStore) throws {
        let repository = try requireRepository(from: store)
        let journal = try makeJournal(for: store)
        guard try journal.load() == nil else {
            throw ZhulongExactRecoveryE2EAutomationError.failed(
                "setup found an existing pending application"
            )
        }

        let state = switch scenario {
        case .exactAfter:
            try setupExactAfter(
                on: store,
                repository: repository,
                journal: journal
            )
        case .preferenceConflict:
            try setupPreferenceConflict(
                on: store,
                repository: repository,
                journal: journal
            )
        }
        try writeState(state)
    }

    @MainActor
    private func setupExactAfter(
        on store: NoonmarkStore,
        repository: SQLiteEngineRepository,
        journal: EncryptedFileZhulongApplicationJournal
    ) throws -> State {
        let reference = try store.dayContext.moment().instant
        let beforeEngine = try NoonmarkEngine(
            snapshot: store.engine.snapshot()
        )
        let createdAt = try beforeEngine.nextMutationDate(
            reference: reference
        )
        let chainID = try beforeEngine.createPoolTask(
            title: Self.exactAfterTitle,
            now: createdAt
        )
        let beforeSnapshot = beforeEngine.snapshot()
        guard let chainIndex = beforeSnapshot.chains.firstIndex(
            where: { $0.id == chainID }
        ) else {
            throw ZhulongExactRecoveryE2EAutomationError.failed(
                "clock-only chain was not created"
            )
        }
        let beforeUpdatedAt = beforeSnapshot.chains[chainIndex].updatedAt
        let afterUpdatedAt = try nextRepresentableDate(
            after: beforeUpdatedAt
        )
        var afterSnapshot = beforeSnapshot
        afterSnapshot.chains[chainIndex].updatedAt = afterUpdatedAt
        try afterSnapshot.validateIntegrity()
        try verifyClockOnlySnapshots(
            before: beforeSnapshot,
            after: afterSnapshot,
            chainID: chainID
        )
        let afterEngine = try NoonmarkEngine(snapshot: afterSnapshot)
        guard let definitionSequence = afterSnapshot.definitions.first(
            where: { $0.chainID == chainID }
        )?.sequence else {
            throw ZhulongExactRecoveryE2EAutomationError.failed(
                "clock-only task definition was not created"
            )
        }

        try store.save(beforeEngine, mutationAt: createdAt)
        try store.save(afterEngine, mutationAt: afterUpdatedAt)
        store.engine = afterEngine
        guard try repository.load().snapshot() == afterSnapshot else {
            throw ZhulongExactRecoveryE2EAutomationError.failed(
                "SQLite current snapshot is not the exact after snapshot"
            )
        }

        let pendingCreatedAt = try nextRepresentableDate(
            after: afterUpdatedAt
        )
        let beforeSession = try ZhulongSession(
            primaryIntent: "验证精确 after 恢复",
            proposedScopes: [.taskPool],
            now: Date(
                timeIntervalSinceReferenceDate: pendingCreatedAt
                    .timeIntervalSinceReferenceDate.nextDown
            )
        )
        var session = beforeSession
        _ = try session.appendEntry(
            author: .zhulong,
            kind: .statement,
            content: "验证精确 after 恢复已应用",
            now: pendingCreatedAt
        )
        try makeSessionRepository(for: store).save(beforeSession)
        let pending = try ZhulongPendingApplication(
            kind: .todoDiff(ZhulongTodoDiffID()),
            sessionID: session.id,
            beforeSnapshot: beforeSnapshot,
            afterSnapshot: afterSnapshot,
            beforeSession: beforeSession,
            afterSession: session,
            createdAt: pendingCreatedAt
        )
        try journal.save(pending)
        guard try journal.load() == pending else {
            throw ZhulongExactRecoveryE2EAutomationError.failed(
                "encrypted exact-after journal did not round-trip"
            )
        }

        return State(
            formatVersion: 2,
            scenario: scenario.rawValue,
            pendingID: pending.id.uuidString,
            sessionID: session.id.description,
            chainID: chainID.description,
            definitionSequence: definitionSequence,
            taskTitle: Self.exactAfterTitle,
            beforeDigest: try ZhulongApplicationSnapshotDigest.value(
                beforeSnapshot
            ),
            afterDigest: try ZhulongApplicationSnapshotDigest.value(
                afterSnapshot
            ),
            currentDigest: try ZhulongApplicationSnapshotDigest.value(
                afterSnapshot
            ),
            beforeUpdatedAtBits: dateBits(beforeUpdatedAt),
            afterUpdatedAtBits: dateBits(afterUpdatedAt),
            beforeDataMode: beforeSnapshot.preferences.dataMode.rawValue,
            currentDataMode: afterSnapshot.preferences.dataMode.rawValue
        )
    }

    @MainActor
    private func setupPreferenceConflict(
        on store: NoonmarkStore,
        repository: SQLiteEngineRepository,
        journal: EncryptedFileZhulongApplicationJournal
    ) throws -> State {
        let beforeSnapshot = store.engine.snapshot()
        guard beforeSnapshot.preferences.dataMode == .localFirst else {
            throw ZhulongExactRecoveryE2EAutomationError.failed(
                "preference-conflict fixture did not start local-first"
            )
        }
        let reference = try store.dayContext.moment().instant
        let afterEngine = try NoonmarkEngine(snapshot: beforeSnapshot)
        let createdAt = try afterEngine.nextMutationDate(
            reference: reference
        )
        let chainID = try afterEngine.createPoolTask(
            title: Self.preferenceConflictTitle,
            now: createdAt
        )
        let afterSnapshot = afterEngine.snapshot()
        guard let definitionSequence = afterSnapshot.definitions.first(
            where: { $0.chainID == chainID }
        )?.sequence else {
            throw ZhulongExactRecoveryE2EAutomationError.failed(
                "preference-conflict task definition was not created"
            )
        }
        try verifySinglePoolTaskApplication(
            before: beforeSnapshot,
            after: afterSnapshot,
            chainID: chainID,
            title: Self.preferenceConflictTitle
        )

        let currentEngine = try NoonmarkEngine(snapshot: beforeSnapshot)
        currentEngine.updateDataMode(.onlineFirst)
        let currentSnapshot = currentEngine.snapshot()
        try verifyLocalOnlyPreferenceDivergence(
            before: beforeSnapshot,
            current: currentSnapshot
        )
        guard currentSnapshot != afterSnapshot else {
            throw ZhulongExactRecoveryE2EAutomationError.failed(
                "preference-conflict current snapshot matched after"
            )
        }

        try store.save(currentEngine, mutationAt: createdAt)
        store.engine = currentEngine
        guard try repository.load().snapshot() == currentSnapshot else {
            throw ZhulongExactRecoveryE2EAutomationError.failed(
                "SQLite current snapshot is not the preference-only third snapshot"
            )
        }

        let pendingCreatedAt = try nextRepresentableDate(after: createdAt)
        let beforeSession = try ZhulongSession(
            primaryIntent: "验证本机偏好冲突",
            proposedScopes: [.taskPool],
            now: Date(
                timeIntervalSinceReferenceDate: pendingCreatedAt
                    .timeIntervalSinceReferenceDate.nextDown
            )
        )
        var session = beforeSession
        _ = try session.appendEntry(
            author: .zhulong,
            kind: .statement,
            content: "验证本机偏好冲突已应用",
            now: pendingCreatedAt
        )
        try makeSessionRepository(for: store).save(beforeSession)
        let pending = try ZhulongPendingApplication(
            kind: .todoDiff(ZhulongTodoDiffID()),
            sessionID: session.id,
            beforeSnapshot: beforeSnapshot,
            afterSnapshot: afterSnapshot,
            beforeSession: beforeSession,
            afterSession: session,
            createdAt: pendingCreatedAt
        )
        try journal.save(pending)
        guard try journal.load() == pending else {
            throw ZhulongExactRecoveryE2EAutomationError.failed(
                "encrypted preference-conflict journal did not round-trip"
            )
        }

        return State(
            formatVersion: 2,
            scenario: scenario.rawValue,
            pendingID: pending.id.uuidString,
            sessionID: session.id.description,
            chainID: chainID.description,
            definitionSequence: definitionSequence,
            taskTitle: Self.preferenceConflictTitle,
            beforeDigest: try ZhulongApplicationSnapshotDigest.value(
                beforeSnapshot
            ),
            afterDigest: try ZhulongApplicationSnapshotDigest.value(
                afterSnapshot
            ),
            currentDigest: try ZhulongApplicationSnapshotDigest.value(
                currentSnapshot
            ),
            beforeUpdatedAtBits: "not-applicable",
            afterUpdatedAtBits: "not-applicable",
            beforeDataMode: beforeSnapshot.preferences.dataMode.rawValue,
            currentDataMode: currentSnapshot.preferences.dataMode.rawValue
        )
    }

    @MainActor
    private func verify(on store: NoonmarkStore) throws {
        _ = try requireRepository(from: store)
        let state = try readState()
        guard state.formatVersion == 2,
              state.scenario == scenario.rawValue
        else {
            throw ZhulongExactRecoveryE2EAutomationError.failed(
                "recovery state version or scenario did not match"
            )
        }
        switch scenario {
        case .exactAfter:
            try verifyExactAfter(on: store, state: state)
        case .preferenceConflict:
            try verifyPreferenceConflict(on: store, state: state)
        }
    }

    @MainActor
    private func verifyExactAfter(
        on store: NoonmarkStore,
        state: State
    ) throws {
        let journal = try makeJournal(for: store)
        guard store.zhulongWorkspace.status == .applicationRecovered else {
            throw ZhulongExactRecoveryE2EAutomationError.failed(
                "exact-after restart did not report applicationRecovered"
            )
        }
        guard try journal.load() == nil,
              FileManager.default.fileExists(
                  atPath: journal.fileURL.path
              ) == false
        else {
            throw ZhulongExactRecoveryE2EAutomationError.failed(
                "exact-after recovery did not clear the journal"
            )
        }
        guard store.zhulongWorkspace.sessions.contains(
            where: { $0.id.description == state.sessionID }
        ) else {
            throw ZhulongExactRecoveryE2EAutomationError.failed(
                "exact-after recovery did not persist the after session"
            )
        }

        let snapshot = store.engine.snapshot()
        let digest = try ZhulongApplicationSnapshotDigest.value(snapshot)
        guard digest == state.afterDigest,
              digest == state.currentDigest,
              digest != state.beforeDigest
        else {
            throw ZhulongExactRecoveryE2EAutomationError.failed(
                "exact-after recovery reconciled to the wrong snapshot"
            )
        }
        guard let chain = snapshot.chains.first(
            where: { $0.id.description == state.chainID }
        ), dateBits(chain.updatedAt) == state.afterUpdatedAtBits,
           let beforeBits = UInt64(state.beforeUpdatedAtBits),
           let afterBits = UInt64(state.afterUpdatedAtBits)
        else {
            throw ZhulongExactRecoveryE2EAutomationError.failed(
                "exact-after chain clock did not survive restart"
            )
        }
        let beforeSeconds = Double(bitPattern: beforeBits)
        let afterSeconds = Double(bitPattern: afterBits)
        guard afterSeconds == beforeSeconds.nextUp else {
            throw ZhulongExactRecoveryE2EAutomationError.failed(
                "exact-after clocks were not adjacent representable values"
            )
        }
    }

    @MainActor
    private func verifyPreferenceConflict(
        on store: NoonmarkStore,
        state: State
    ) throws {
        let journal = try makeJournal(for: store)
        guard store.zhulongWorkspace.status ==
            .applicationRecoveryConflict
        else {
            throw ZhulongExactRecoveryE2EAutomationError.failed(
                "preference-only divergence did not report applicationRecoveryConflict"
            )
        }
        guard FileManager.default.fileExists(
            atPath: journal.fileURL.path
        ), let pending = try journal.load()
        else {
            throw ZhulongExactRecoveryE2EAutomationError.failed(
                "preference conflict did not retain its encrypted journal"
            )
        }
        guard pending.id.uuidString == state.pendingID,
              pending.sessionID.description == state.sessionID,
              try ZhulongApplicationSnapshotDigest.value(
                  pending.beforeSnapshot
              ) == state.beforeDigest,
              try ZhulongApplicationSnapshotDigest.value(
                  pending.afterSnapshot
              ) == state.afterDigest
        else {
            throw ZhulongExactRecoveryE2EAutomationError.failed(
                "retained preference-conflict journal changed"
            )
        }
        try verifySinglePoolTaskApplication(
            before: pending.beforeSnapshot,
            after: pending.afterSnapshot,
            chainID: try taskChainID(state.chainID),
            title: state.taskTitle
        )

        let currentSnapshot = store.engine.snapshot()
        try verifyLocalOnlyPreferenceDivergence(
            before: pending.beforeSnapshot,
            current: currentSnapshot
        )
        let currentDigest = try ZhulongApplicationSnapshotDigest.value(
            currentSnapshot
        )
        guard currentDigest == state.currentDigest,
              currentDigest != state.beforeDigest,
              currentDigest != state.afterDigest,
              currentSnapshot.preferences.dataMode.rawValue ==
              state.currentDataMode,
              currentSnapshot.definitions.contains(
                  where: { $0.title == state.taskTitle }
              ) == false
        else {
            throw ZhulongExactRecoveryE2EAutomationError.failed(
                "preference conflict applied or replaced the third snapshot"
            )
        }
    }

    @MainActor
    private func requireRepository(
        from store: NoonmarkStore
    ) throws -> SQLiteEngineRepository {
        guard Bundle.main.bundleIdentifier == "app.noonmark.mac.e2e",
              let repository = store.repository,
              store.databaseURL != nil
        else {
            throw ZhulongExactRecoveryE2EAutomationError.failed(
                "exact recovery evidence requires the persistent E2E app"
            )
        }
        return repository
    }

    @MainActor
    private func makeJournal(
        for store: NoonmarkStore
    ) throws -> EncryptedFileZhulongApplicationJournal {
        guard AppLaunchArguments.contains("--e2e-zhulong-sidecar-key")
        else {
            throw ZhulongExactRecoveryE2EAutomationError.failed(
                "exact recovery evidence requires the E2E sidecar key"
            )
        }
        return EncryptedFileZhulongApplicationJournal(
            directoryURL: store.zhulongSidecarDirectoryURL,
            keySource: ZhulongE2ESidecarKeySource()
        )
    }

    @MainActor
    private func makeSessionRepository(
        for store: NoonmarkStore
    ) -> EncryptedFileZhulongSessionRepository {
        EncryptedFileZhulongSessionRepository(
            directoryURL: store.zhulongSidecarDirectoryURL,
            keySource: ZhulongE2ESidecarKeySource()
        )
    }

    private func verifyClockOnlySnapshots(
        before: NoonmarkSnapshot,
        after: NoonmarkSnapshot,
        chainID: TaskChainID
    ) throws {
        guard let beforeIndex = before.chains.firstIndex(
            where: { $0.id == chainID }
        ), let afterIndex = after.chains.firstIndex(
            where: { $0.id == chainID }
        )
        else {
            throw ZhulongExactRecoveryE2EAutomationError.failed(
                "clock-only snapshots lost their target chain"
            )
        }
        let beforeUpdatedAt = before.chains[beforeIndex].updatedAt
        let afterUpdatedAt = after.chains[afterIndex].updatedAt
        var normalizedAfter = after
        normalizedAfter.chains[afterIndex].updatedAt = beforeUpdatedAt
        guard afterUpdatedAt.timeIntervalSinceReferenceDate ==
            beforeUpdatedAt.timeIntervalSinceReferenceDate.nextUp,
            normalizedAfter == before
        else {
            throw ZhulongExactRecoveryE2EAutomationError.failed(
                "pending snapshots differ by more than one nextUp Date bit"
            )
        }
    }

    private func verifySinglePoolTaskApplication(
        before: NoonmarkSnapshot,
        after: NoonmarkSnapshot,
        chainID: TaskChainID,
        title: String
    ) throws {
        var strippedAfter = after
        strippedAfter.chains.removeAll { $0.id == chainID }
        strippedAfter.definitions.removeAll { $0.chainID == chainID }
        guard strippedAfter == before,
              after.chains.count == before.chains.count + 1,
              after.definitions.count == before.definitions.count + 1,
              after.definitions.contains(
                  where: {
                      $0.chainID == chainID && $0.title == title
                  }
              )
        else {
            throw ZhulongExactRecoveryE2EAutomationError.failed(
                "pending after snapshot is not one isolated pool-task application"
            )
        }
    }

    private func verifyLocalOnlyPreferenceDivergence(
        before: NoonmarkSnapshot,
        current: NoonmarkSnapshot
    ) throws {
        var normalizedCurrent = current
        normalizedCurrent.preferences.dataMode = before.preferences.dataMode
        guard before.preferences.dataMode == .localFirst,
              current.preferences.dataMode == .onlineFirst,
              normalizedCurrent == before
        else {
            throw ZhulongExactRecoveryE2EAutomationError.failed(
                "third snapshot does not differ only by local-only data mode"
            )
        }
    }

    private func taskChainID(_ value: String) throws -> TaskChainID {
        guard let rawValue = UUID(uuidString: value) else {
            throw ZhulongExactRecoveryE2EAutomationError.failed(
                "state contains an invalid task-chain ID"
            )
        }
        return TaskChainID(rawValue)
    }

    private func nextRepresentableDate(after date: Date) throws -> Date {
        let seconds = date.timeIntervalSinceReferenceDate
        let nextSeconds = seconds.nextUp
        guard seconds.isFinite,
              nextSeconds.isFinite,
              nextSeconds > seconds
        else {
            throw ZhulongExactRecoveryE2EAutomationError.failed(
                "Date frontier has no finite next representable value"
            )
        }
        return Date(timeIntervalSinceReferenceDate: nextSeconds)
    }

    private func dateBits(_ date: Date) -> String {
        String(date.timeIntervalSinceReferenceDate.bitPattern)
    }

    private func writeState(_ state: State) throws {
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    private func readState() throws -> State {
        try JSONDecoder().decode(
            State.self,
            from: Data(contentsOf: stateURL)
        )
    }

    private func writeResult(_ result: String) throws {
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(
            to: resultURL,
            atomically: true,
            encoding: .utf8
        )
    }
}

private enum ZhulongExactRecoveryE2EAutomationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            message
        }
    }
}

struct ZhulongPendingGateE2EAutomation: LaunchAutomationRunnable {
    private enum Phase {
        case setup
        case verify
    }

    private static let afterTitle = "E2E pending gate 不得落盘"

    private let phase: Phase
    private let resultURL: URL

    @MainActor
    static func fromCommandLine() -> Self? {
        let setsUp = AppLaunchArguments.contains(
            "--e2e-setup-zhulong-pending-gate"
        )
        let verifies = AppLaunchArguments.contains(
            "--e2e-verify-zhulong-pending-gate"
        )
        guard setsUp != verifies,
              let path = AppLaunchArguments.value(
                  after: "--e2e-zhulong-pending-gate-result-url"
              ),
              path.isEmpty == false
        else { return nil }
        return Self(
            phase: setsUp ? .setup : .verify,
            resultURL: URL(fileURLWithPath: path)
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        Task { @MainActor in
            do {
                switch phase {
                case .setup:
                    try setup(on: store)
                case .verify:
                    try await verify(on: store)
                }
                try writeResult("ok")
            } catch {
                try? writeResult("failed: \(error.localizedDescription)")
            }
            E2EApplicationTermination.schedule()
        }
    }

    @MainActor
    private func setup(on store: NoonmarkStore) throws {
        let fixture = try requireFixtureRepositories(from: store)
        guard try fixture.journal.load() == nil else {
            throw Failure.failed("setup found an existing pending application")
        }

        let reference = try store.dayContext.moment().instant
        let beforeEngine = NoonmarkEngine()
        let afterEngine = NoonmarkEngine()
        let appliedAt = try afterEngine.nextMutationDate(reference: reference)
        _ = try afterEngine.createPoolTask(
            title: Self.afterTitle,
            now: appliedAt
        )
        let currentEngine = NoonmarkEngine()
        currentEngine.updateDataMode(.onlineFirst)

        let beforeSnapshot = beforeEngine.snapshot()
        let afterSnapshot = afterEngine.snapshot()
        let currentSnapshot = currentEngine.snapshot()
        guard currentSnapshot.days.isEmpty,
              currentSnapshot.chains.isEmpty,
              currentSnapshot.traces.isEmpty,
              currentSnapshot.subtasks.isEmpty,
              beforeSnapshot != currentSnapshot,
              beforeSnapshot != afterSnapshot,
              currentSnapshot != afterSnapshot
        else {
            throw Failure.failed(
                "bootstrap fixture did not create three exact empty/before/after states"
            )
        }

        try fixture.engine.replaceForDataImport(
            currentSnapshot,
            preserving: store.syncDeviceIdentity
        )
        store.engine = currentEngine
        guard try fixture.engine.load().snapshot() == currentSnapshot else {
            throw Failure.failed("bootstrap third Engine was not persisted")
        }

        let pendingAt = Date(
            timeIntervalSinceReferenceDate:
                appliedAt.timeIntervalSinceReferenceDate.nextUp
        )
        let beforeSession = try ZhulongSession(
            primaryIntent: "验证 pending application 全局写围栏",
            proposedScopes: [.taskPool],
            now: appliedAt
        )
        var afterSession = beforeSession
        _ = try afterSession.appendEntry(
            author: .zhulong,
            kind: .statement,
            content: "pending application 等待精确恢复",
            now: pendingAt
        )
        try fixture.sessions.save(beforeSession)
        let pending = try ZhulongPendingApplication(
            kind: .todoDiff(ZhulongTodoDiffID()),
            sessionID: beforeSession.id,
            beforeSnapshot: beforeSnapshot,
            afterSnapshot: afterSnapshot,
            beforeSession: beforeSession,
            afterSession: afterSession,
            createdAt: pendingAt
        )
        try fixture.journal.save(pending)
        guard try fixture.journal.load() == pending else {
            throw Failure.failed("pending application did not round-trip")
        }
    }

    @MainActor
    private func verify(on store: NoonmarkStore) async throws {
        let fixture = try requireFixtureRepositories(from: store)
        guard store.zhulongWorkspace.status == .applicationRecoveryConflict,
              let pending = try fixture.journal.load()
        else {
            throw Failure.failed(
                "bootstrap restart did not retain an exact recovery conflict"
            )
        }
        let baselineEngine = store.engine.snapshot()
        let baselinePersistedEngine = try fixture.engine.load().snapshot()
        let baselineSession = try fixture.sessions.load(pending.sessionID)
        guard baselineEngine == baselinePersistedEngine,
              baselineSession == pending.beforeSession,
              baselineEngine.days.isEmpty,
              baselineEngine.chains.isEmpty,
              baselineEngine.traces.isEmpty,
              baselineEngine.subtasks.isEmpty,
              baselineEngine != pending.beforeSnapshot,
              baselineEngine != pending.afterSnapshot
        else {
            throw Failure.failed("bootstrap restart changed the third state")
        }

        func assertUnchanged(_ boundary: String) throws {
            guard store.engine.snapshot() == baselineEngine,
                  try fixture.engine.load().snapshot() == baselinePersistedEngine,
                  try fixture.sessions.load(pending.sessionID) == baselineSession,
                  try fixture.journal.load() == pending
            else {
                throw Failure.failed(
                    "\(boundary) crossed the pending application fence"
                )
            }
        }

        do {
            try store.save(
                store.engine,
                mutationAt: Date(
                    timeIntervalSinceReferenceDate:
                        pending.createdAt.timeIntervalSinceReferenceDate.nextUp
                )
            )
            throw Failure.failed("direct Engine save was not blocked")
        } catch let error as StoreMutationGateError
            where error.isPendingZhulongApplication {}
        try assertUnchanged("direct Engine save")

        store.persist()
        try assertUnchanged("Store persist")

        let nextDate = LocalDate(year: 2026, month: 7, day: 6)
        let rolloverMoment = NaturalDayMoment(
            instant: Date(timeIntervalSince1970: 1_783_353_600),
            state: NaturalDayState(
                today: nextDate,
                timeZoneIdentifier: "America/New_York",
                localeIdentifier: "en_SG"
            )
        )
        do {
            try store.reconcileNaturalDay(
                rolloverMoment,
                signal: .manual
            )
            throw Failure.failed("natural-day rollover was not blocked")
        } catch let error as StoreMutationGateError
            where error.isPendingZhulongApplication {}
        try assertUnchanged("natural-day rollover")

        let rejectedImportURL = fixture.engineURL
            .deletingLastPathComponent()
            .appendingPathComponent("pending-gate-import-must-not-be-read.json")
        do {
            _ = try await store.prepareDataImport(from: rejectedImportURL)
            throw Failure.failed("data import preparation was not blocked")
        } catch let error as StoreMutationGateError
            where error.isPendingZhulongApplication {}
        try assertUnchanged("data import")

        store.syncLocalFolderNow()
        guard store.isLocalFirstSyncing == false else {
            throw Failure.failed("sync started while an application was pending")
        }
        try assertUnchanged("sync start")
    }

    @MainActor
    private func requireFixtureRepositories(
        from store: NoonmarkStore
    ) throws -> (
        engine: SQLiteEngineRepository,
        engineURL: URL,
        sessions: EncryptedFileZhulongSessionRepository,
        journal: EncryptedFileZhulongApplicationJournal
    ) {
        guard Bundle.main.bundleIdentifier == "app.noonmark.mac.e2e",
              AppLaunchArguments.contains("--e2e-zhulong-sidecar-key"),
              let engine = store.repository,
              let engineURL = store.databaseURL
        else {
            throw Failure.failed(
                "pending-gate evidence requires the persistent E2E app"
            )
        }
        return (
            engine,
            engineURL,
            EncryptedFileZhulongSessionRepository(
                directoryURL: store.zhulongSidecarDirectoryURL,
                keySource: ZhulongE2ESidecarKeySource()
            ),
            EncryptedFileZhulongApplicationJournal(
                directoryURL: store.zhulongSidecarDirectoryURL,
                keySource: ZhulongE2ESidecarKeySource()
            )
        )
    }

    private func writeResult(_ value: String) throws {
        try value.write(
            to: resultURL,
            atomically: true,
            encoding: .utf8
        )
    }

    private enum Failure: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(message): message
            }
        }
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
