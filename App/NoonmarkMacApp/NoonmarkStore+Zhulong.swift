import CryptoKit
import Foundation
import NoonmarkAI
@_spi(ClassificationUserDecision) import NoonmarkCore
import NoonmarkMacRuntime
import NoonmarkZhulong
import NoonmarkZhulongAI

extension NoonmarkStore {
    func saveZhulongProvider() {
        do {
            let transition = try ZhulongProviderSettingsStore.save(
                zhulongProviderDraft
            )
            zhulongProviderDraft = transition.draft
            automaticClassificationProviderConfigurationDidChange(transition)
            if zhulongProviderDraft.enabled == false {
                ensureVisiblePage()
            }
            showToast(zhulongCopy.providerActionNotice(.configurationSaved))
        } catch {
            showZhulongProviderSettingsFailure(error)
        }
    }

    func clearZhulongProvider() {
        do {
            let transition = try ZhulongProviderSettingsStore.clear()
            zhulongProviderDraft = transition.draft
            automaticClassificationProviderConfigurationDidChange(transition)
            ensureVisiblePage(preferredFallback: .day)
            showToast(zhulongCopy.providerActionNotice(.configurationCleared))
        } catch {
            showZhulongProviderSettingsFailure(error)
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
                showToast(zhulongCopy.providerActionNotice(.connectionTestSkippedDisabled))
                return
            }
            guard config.kind == .openAICompatible else {
                showToast(zhulongCopy.providerActionNotice(.healthCheckUnsupported))
                return
            }

            let provider = OpenAICompatibleProvider(
                config: config,
                apiKeyResolver: { ref in
                    try ZhulongProviderKeychain.resolveAPIKey(ref)
                }
            )
            let health = await provider.healthCheck()
            switch health.status {
            case .healthy:
                showToast(zhulongCopy.providerActionNotice(.connectionSucceeded))
            case .unavailable:
                showToast(zhulongCopy.providerActionNotice(.connectionFailed))
            case .unconfigured:
                showToast(zhulongCopy.providerActionNotice(.providerNotEnabled))
            }
        } catch {
            showZhulongProviderSettingsFailure(error)
        }
    }

    private var zhulongCopy: ZhulongCopy {
        AppPresentation(language: engine.preferences.language).zhulong
    }

    private func showZhulongProviderSettingsFailure(_ error: Error) {
        NSLog(
            "Noonmark provider settings failed: %@",
            String(reflecting: error)
        )
        let failure = (error as? ZhulongProviderSettingsError)?
            .presentationFailure ?? .unexpected
        showPersistentFailureMessage(
            zhulongCopy.providerSettingsFailure(failure),
            context: .provider
        )
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
        let state: ZhulongSessionStateCopyKey = if session.workspaceStatus == .paused {
            .paused
        } else if session.workspaceStatus == .archived {
            .archived
        } else {
            switch session.phase {
            case .scopeReview: .scopeReview
            case .readyForProvider: .readyForProvider
            case .providerRunning: .providerRunning
            case .decisionGate: .decisionGate
            case .draftReview: .draftReview
            }
        }
        return AppPresentation(language: engine.preferences.language)
            .zhulong.sessionStatus(state, style: .compact)
    }

    var zhulongProviderStatusMessage: String {
        AppPresentation(language: engine.preferences.language)
            .zhulong.providerStatus(zhulongProviderDraft.status)
    }

    func authorizeCurrentZhulongWorkspaceSession() {
        do {
            zhulongWorkspace.authorizeCurrentSession(
                providerIdentity: try zhulongProviderIdentity()
            )
        } catch {
            showOperationFailure(.provider, error: error)
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
        guard prepareNaturalDayForUserMutation() != nil else { return }
        zhulongWorkspace.captureDailyClose(date: today, from: engine)
    }

    func publishCurrentZhulongTodoDiff() {
        guard prepareNaturalDayForUserMutation() != nil else { return }
        zhulongWorkspace.publishTodoDiff(from: engine, planningDate: today)
    }

    func confirmAndApplyCurrentZhulongTodoDiff() {
        guard isLocalFirstSyncing == false else {
            showOperationFailure(
                .sync,
                error: DataPackageImportError.syncInProgress
            )
            return
        }
        guard let moment = prepareNaturalDayForUserMutation() else { return }
        let originalSnapshot = engine.snapshot()
        guard let result = zhulongWorkspace.applyCurrentTodoDiff(
            to: engine,
            today: today,
            reference: moment.instant,
            persistEngine: { [self] candidate, applyAt in
                try savePendingZhulongApplication(
                    candidate,
                    originalSnapshot: originalSnapshot,
                    mutationAt: applyAt
                )
            },
            reconcileEnginePersistenceFailure: { [self] pending in
                try reconcileZhulongEnginePersistenceFailure(for: pending)
            }
        ) else { return }
        engine = result.engine
        automaticClassificationJobsDidChange()
        clearUndoHistory()
        normalizeSelection()
        if result.commitCompleted {
            showToast(copy.todoDiffApplied)
        }
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
        guard isLocalFirstSyncing == false else {
            showOperationFailure(
                .sync,
                error: DataPackageImportError.syncInProgress
            )
            return
        }
        guard let moment = prepareNaturalDayForUserMutation() else { return }
        guard let result = zhulongWorkspace.applyCurrentDailyReview(
            to: engine,
            reference: moment.instant,
            persistEngine: { [self] candidate, applyAt in
                try savePendingZhulongApplication(
                    candidate,
                    mutationAt: applyAt
                )
            },
            reconcileEnginePersistenceFailure: { [self] pending in
                try reconcileZhulongEnginePersistenceFailure(for: pending)
            },
            interruptAfterEnginePersisted: interruptAfterEnginePersisted
        ) else { return }
        engine = result.engine
        clearUndoHistory()
        normalizeSelection()
        if result.commitCompleted {
            showToast(copy.confirmedReviewSaved)
        }
    }

    func recoverPendingZhulongApplication() {
        guard repository != nil else { return }
        let originalSnapshot = engine.snapshot()
        engine = zhulongWorkspace.recoverPendingApplication(
            currentEngine: engine,
            persistEngine: { [self] candidate, changedAt in
                try savePendingZhulongApplication(
                    candidate,
                    originalSnapshot: originalSnapshot,
                    mutationAt: changedAt
                )
            },
            reconcileEnginePersistenceFailure: { [self] pending in
                try reconcileZhulongEnginePersistenceFailure(for: pending)
            }
        )
        automaticClassificationJobsDidChange()
        clearUndoHistory()
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
            showOperationFailure(.provider, error: error)
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
            showOperationFailure(.provider, error: error)
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
                try ZhulongProviderKeychain.resolveAPIKey(ref)
            }
        )
        return ZhulongAIProviderAdapter(
            configurationIdentity: try zhulongProviderIdentity(),
            upstream: upstream
        )
    }

    func requestZhulongDailyReviewFromReviewRail() {
        page = .zhulong
        startZhulongWorkspaceSession(intent: copy.zhulongDailyReviewIntent)
    }

    var zhulongSidecarDirectoryURL: URL {
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

    var zhulongSidecarKeySource: any ZhulongSidecarKeySource {
        guard AppLaunchArguments.contains("--e2e-zhulong-sidecar-key") else {
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
}
