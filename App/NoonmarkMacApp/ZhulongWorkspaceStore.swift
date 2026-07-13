import Foundation
import NoonmarkCore
import NoonmarkZhulong

enum ZhulongStreamActor: Equatable {
    case user
    case zhulong
    case system
}

enum ZhulongStreamSection: String, CaseIterable, Identifiable {
    case intent = "意图与范围"
    case brief = "活简报"
    case planning = "规划运行"
    case decision = "决定与授权"
    case todo = "Todo 应用"
    case dailyClose = "每日收尾"
    case lifecycle = "会话状态"

    var id: String { rawValue }
}

struct ZhulongStreamRecord: Identifiable, Equatable {
    let id: String
    let occurredAt: Date
    let actor: ZhulongStreamActor
    let section: ZhulongStreamSection
    let eyebrow: String
    let title: String
    let body: String?
    let isBoundary: Bool
    let isInvalidation: Bool
}

@MainActor
final class ZhulongWorkspaceStore: ObservableObject {
    @Published private(set) var sessions: [ZhulongSession] = []
    @Published private(set) var selectedSessionID: ZhulongSessionID?
    @Published private(set) var memoryLedger = ZhulongMemoryLedger()
    @Published private(set) var statusMessage: String?
    private let directoryURL: URL
    private let sessionRepository: EncryptedFileZhulongSessionRepository
    private let memoryRepository: EncryptedFileZhulongMemoryRepository
    private let providerOrchestrator: ZhulongProviderOrchestrator
    private let applicationJournal: EncryptedFileZhulongApplicationJournal

    init(directoryURL: URL, keySource: any ZhulongSidecarKeySource) {
        self.directoryURL = directoryURL
        let sessionRepository = EncryptedFileZhulongSessionRepository(
            directoryURL: directoryURL,
            keySource: keySource
        )
        self.sessionRepository = sessionRepository
        providerOrchestrator = ZhulongProviderOrchestrator(repository: sessionRepository)
        applicationJournal = EncryptedFileZhulongApplicationJournal(
            directoryURL: directoryURL,
            keySource: keySource
        )
        memoryRepository = EncryptedFileZhulongMemoryRepository(
            directoryURL: directoryURL,
            keySource: keySource
        )
        reload()
    }

    var selectedSession: ZhulongSession? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    var records: [ZhulongStreamRecord] {
        guard let session = selectedSession else { return [] }
        var projected = session.entries.map(record(for:))
        projected.append(contentsOf: session.events.map(record(for:)))
        return projected.sorted { lhs, rhs in
            if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
            return lhs.id < rhs.id
        }
    }

    var selectedSessionStatus: String {
        guard let session = selectedSession else { return "未选择会话" }
        if session.workspaceStatus == .paused { return "已暂停" }
        if session.workspaceStatus == .archived { return "已归档" }
        switch session.phase {
        case .scopeReview: return "等待范围确认"
        case .readyForProvider: return "范围已确认"
        case .providerRunning: return "Provider 正在运行"
        case .decisionGate: return "等待用户决定"
        case .draftReview: return "草稿待审"
        }
    }

    func createSession(
        intent: String,
        purpose: ZhulongSessionPurpose = .freeform,
        scopes: Set<ZhulongDataScope>,
        now: Date = Date()
    ) {
        do {
            let session = try ZhulongSession(
                primaryIntent: intent,
                purpose: purpose,
                proposedScopes: scopes,
                now: now
            )
            try sessionRepository.save(session)
            sessions.insert(session, at: 0)
            selectedSessionID = session.id
            statusMessage = nil
        } catch {
            statusMessage = "无法建立会话：\(error.localizedDescription)"
        }
    }

    func selectSession(_ id: ZhulongSessionID) {
        selectedSessionID = id
    }

    func showHome() {
        selectedSessionID = nil
    }

    func authorizeCurrentSession(
        providerIdentity: ZhulongProviderConfigurationIdentity,
        now: Date = Date()
    ) {
        updateSelectedSession { session in
            try session.authorizeScope(
                session.proposedScopes,
                providerIdentity: providerIdentity,
                expiresAt: now.addingTimeInterval(60 * 60),
                now: now
            )
        }
    }

    func pauseCurrentSession(now: Date = Date()) {
        updateSelectedSession { try $0.pause(now: now) }
    }

    func resumeCurrentSession(now: Date = Date()) {
        updateSelectedSession { try $0.resume(now: now) }
    }

    func appendToCurrentSession(
        author: ZhulongSessionEntryAuthor,
        kind: ZhulongSessionEntryKind,
        content: String,
        now: Date = Date()
    ) {
        updateSelectedSession { session in
            try session.appendEntry(
                author: author,
                kind: kind,
                content: content,
                now: now
            )
        }
    }

    func publishPlanningBrief(_ draft: ZhulongPlanningBriefDraft, now: Date = Date()) {
        updateSelectedSession { session in
            try session.publishPlanningBrief(draft, now: now)
        }
    }

    func reviewCurrentPlanningBrief(now: Date = Date()) {
        updateSelectedSession { session in
            guard let brief = session.currentPlanningBrief else {
                throw ZhulongPlanningBriefError.briefNotCurrent
            }
            try session.reviewPlanningBrief(brief.id, now: now)
        }
    }

    func delegateCurrentPlanningBrief(now: Date = Date()) {
        updateSelectedSession { session in
            guard let brief = session.currentPlanningBrief else {
                throw ZhulongPlanningBriefError.briefNotCurrent
            }
            try session.delegatePlanning(for: brief.id, now: now)
        }
    }

    func resolveCurrentDecisionGate(
        selectedOptionID: String,
        supplementalDecision: String?,
        now: Date = Date()
    ) {
        updateSelectedSession { session in
            guard let gate = session.currentDecisionGate else {
                throw ZhulongSessionError.invalidProviderResponse
            }
            try session.resolveDecisionGate(
                gate.id,
                selectedOptionID: selectedOptionID,
                supplementalDecision: supplementalDecision,
                now: now
            )
        }
    }

    func incorporateDecisionGateResolution(now: Date = Date()) {
        updateSelectedSession { session in
            guard let brief = session.currentPlanningBrief,
                  let resolution = session.latestDecisionGateResolutionRequiringBriefRevision,
                  let decision = session.entries.first(where: { $0.id == resolution.decisionEntryID })?.content
            else {
                throw ZhulongPlanningBriefError.briefRevisionRequired
            }
            var sourceEntryIDs = brief.sourceEntryIDs
            sourceEntryIDs.insert(resolution.decisionEntryID)
            var userDecisions = brief.userDecisions
            if userDecisions.contains(decision) == false {
                userDecisions.append(decision)
            }
            let revision = try ZhulongPlanningBriefDraft(
                goal: brief.goal,
                successCriteria: brief.successCriteria,
                hardConstraints: brief.hardConstraints,
                userDecisions: userDecisions,
                delegatedActivities: brief.delegatedActivities,
                assumptions: brief.assumptions,
                openQuestions: brief.openQuestions,
                dataScopes: brief.dataScopes,
                sourceEntryIDs: sourceEntryIDs
            )
            try session.publishPlanningBrief(revision, now: now)
        }
    }

    func publishTodoDiff(
        from engine: NoonmarkEngine,
        planningDate: LocalDate,
        now: Date = Date()
    ) {
        updateSelectedSession { session in
            guard let artifact = session.effectivePlanArtifact else {
                throw ZhulongTodoDiffError.todoDiffRequired
            }
            let items = artifact.proposal.stages
                .filter { $0.horizon == .nearTerm }
                .flatMap { stage in
                    stage.deliverables.map { deliverable in
                        ZhulongTodoDiffItem(operation: .createTask(
                            title: deliverable,
                            descriptionText: stage.objective,
                            initialNoteBody: "来自规划阶段：\(stage.title)",
                            plannedSubtasks: [],
                            targetDate: nil
                        ))
                    }
                }
            guard items.isEmpty == false else {
                throw ZhulongTodoDiffError.emptyDiff
            }
            let draft = try ZhulongTodoDiffDraft(
                sessionID: session.id,
                planArtifactID: artifact.id,
                planArtifactVersion: artifact.version,
                planningDate: planningDate,
                sourceSnapshot: engine.snapshot(),
                createdAt: now,
                items: items
            )
            try session.publishTodoDiff(draft, now: now)
        }
    }

    func authorizeCurrentTodoDiff(
        against engine: NoonmarkEngine,
        today: LocalDate,
        now: Date = Date()
    ) {
        updateSelectedSession { session in
            try session.authorizeTodoWrite(against: engine, today: today, now: now)
        }
    }

    @discardableResult
    func reviseCurrentTodoDiff(
        items: [ZhulongTodoDiffItem],
        now: Date = Date()
    ) -> Bool {
        updateSelectedSession { session in
            guard let parent = session.currentTodoDiff else {
                throw ZhulongTodoDiffError.todoDiffRequired
            }
            let revision = try ZhulongTodoDiffDraft(
                revising: parent,
                createdAt: now,
                items: items
            )
            try session.reviseTodoDiff(revision, now: now)
        }
    }

    func publishDailyReviewDraft(
        summary: String?,
        tomorrowNote: String?,
        now: Date = Date()
    ) {
        updateSelectedSession { session in
            guard let snapshot = session.dailyCloseSnapshots.last else {
                throw ZhulongDailyCloseError.invalidReviewDraft
            }
            try session.publishDailyReviewDraft(
                dailyCloseID: snapshot.id,
                summary: summary,
                tomorrowNote: tomorrowNote,
                causeResolutionIDs: [],
                now: now
            )
        }
    }

    func authorizeCurrentDailyReview(
        against engine: NoonmarkEngine,
        now: Date = Date()
    ) {
        updateSelectedSession { session in
            guard let draft = session.dailyReviewDrafts.last else {
                throw ZhulongDailyCloseError.invalidReviewDraft
            }
            try session.authorizeDailyReview(draft.id, against: engine, now: now)
        }
    }

    var hasActiveDailyReviewAuthorization: Bool {
        selectedSession?.dailyReviewAuthorizations.contains { $0.status == .active } == true
    }

    var hasActiveTodoAuthorization: Bool {
        selectedSession?.todoWriteAuthorizations.contains { $0.status == .active } == true
    }

    func applyCurrentTodoDiff(
        to currentEngine: NoonmarkEngine,
        today: LocalDate,
        persistEngine: (NoonmarkEngine) throws -> Void,
        now: Date = Date()
    ) -> NoonmarkEngine? {
        guard let session = selectedSession else { return nil }
        do {
            var afterSession = session
            var afterEngine = try NoonmarkEngine(snapshot: currentEngine.snapshot())
            let receipt = try afterSession.applyAuthorizedTodoDiff(
                to: &afterEngine,
                today: today,
                now: now
            )
            let pending = try ZhulongPendingApplication(
                kind: .todoDiff(receipt.draftID),
                sessionID: session.id,
                beforeSnapshot: currentEngine.snapshot(),
                afterSnapshot: afterEngine.snapshot(),
                afterSession: afterSession,
                createdAt: now
            )
            try applicationJournal.save(pending)
            do {
                try persistEngine(afterEngine)
            } catch {
                try? applicationJournal.clear()
                throw error
            }
            try sessionRepository.save(afterSession)
            try applicationJournal.clear()
            replaceLoadedSession(afterSession)
            statusMessage = nil
            return afterEngine
        } catch {
            statusMessage = "Todo 批次应用失败：\(error.localizedDescription)"
            return nil
        }
    }

    func applyCurrentDailyReview(
        to currentEngine: NoonmarkEngine,
        persistEngine: (NoonmarkEngine) throws -> Void,
        interruptAfterEnginePersisted: Bool = false,
        now: Date = Date()
    ) -> NoonmarkEngine? {
        guard let session = selectedSession,
              let draft = session.dailyReviewDrafts.last
        else { return nil }
        do {
            var afterSession = session
            var afterEngine = try NoonmarkEngine(snapshot: currentEngine.snapshot())
            _ = try afterSession.applyAuthorizedDailyReview(
                draft.id,
                to: &afterEngine,
                now: now
            )
            let pending = try ZhulongPendingApplication(
                kind: .dailyReview(draft.id),
                sessionID: session.id,
                beforeSnapshot: currentEngine.snapshot(),
                afterSnapshot: afterEngine.snapshot(),
                afterSession: afterSession,
                createdAt: now
            )
            try applicationJournal.save(pending)
            do {
                try persistEngine(afterEngine)
            } catch {
                try? applicationJournal.clear()
                throw error
            }
            if interruptAfterEnginePersisted {
                statusMessage = "E2E：已在 SQLite 提交后中断，等待重启恢复。"
                return afterEngine
            }
            try sessionRepository.save(afterSession)
            try applicationJournal.clear()
            replaceLoadedSession(afterSession)
            statusMessage = nil
            return afterEngine
        } catch {
            statusMessage = "每日复盘保存失败：\(error.localizedDescription)"
            return nil
        }
    }

    func recoverPendingApplication(
        currentEngine: NoonmarkEngine,
        persistEngine: (NoonmarkEngine) throws -> Void
    ) -> NoonmarkEngine {
        do {
            guard let pending = try applicationJournal.load() else { return currentEngine }
            let currentSnapshot = currentEngine.snapshot()
            let currentDigest = try ZhulongApplicationSnapshotDigest.value(currentSnapshot)
            let beforeDigest = try ZhulongApplicationSnapshotDigest.value(pending.beforeSnapshot)
            let afterDigest = try ZhulongApplicationSnapshotDigest.value(pending.afterSnapshot)
            let recoveredEngine: NoonmarkEngine
            if currentDigest == beforeDigest {
                recoveredEngine = try NoonmarkEngine(snapshot: pending.afterSnapshot)
                try persistEngine(recoveredEngine)
            } else if currentDigest == afterDigest {
                recoveredEngine = currentEngine
            } else {
                statusMessage = "检测到未完成的烛龙写入，但当前 Todo 已发生其他变化；已停止自动恢复。"
                return currentEngine
            }
            try sessionRepository.save(pending.afterSession)
            try applicationJournal.clear()
            replaceLoadedSession(pending.afterSession)
            statusMessage = "已恢复上次中断的烛龙原子写入。"
            return recoveredEngine
        } catch {
            statusMessage = "无法恢复烛龙原子写入：\(error.localizedDescription)"
            return currentEngine
        }
    }

    func captureDailyClose(
        date: LocalDate,
        from engine: NoonmarkEngine,
        now: Date = Date()
    ) {
        updateSelectedSession { session in
            try session.captureDailyClose(date: date, from: engine, now: now)
        }
    }

    func runCurrentSession(
        payload: ZhulongProviderPayload,
        provider: any ZhulongProvider
    ) async {
        guard let selectedSessionID else { return }
        statusMessage = "Provider 正在处理已授权内容。"
        do {
            let session = try await providerOrchestrator.run(
                sessionID: selectedSessionID,
                payload: payload,
                provider: provider
            )
            replaceLoadedSession(session)
            statusMessage = nil
        } catch {
            reload()
            statusMessage = "Provider 运行失败：\(error.localizedDescription)"
        }
    }

    func runCurrentPlanningSession(
        payload: ZhulongProviderPayload,
        provider: any ZhulongProvider
    ) async {
        guard let selectedSessionID,
              let delegationID = selectedSession?.activePlanningDelegation?.id
        else { return }
        statusMessage = "Provider 正在执行本次单次规划委托。"
        do {
            let session = try await providerOrchestrator.runPlanning(
                sessionID: selectedSessionID,
                delegationID: delegationID,
                payload: payload,
                provider: provider
            )
            replaceLoadedSession(session)
            statusMessage = nil
        } catch {
            reload()
            statusMessage = "规划运行失败：\(error.localizedDescription)"
        }
    }

    func setMemoryEnabled(_ enabled: Bool) {
        do {
            var ledger = memoryLedger
            ledger.setEnabled(enabled)
            try memoryRepository.save(ledger)
            memoryLedger = ledger
            statusMessage = nil
        } catch {
            statusMessage = "无法保存记忆设置：\(error.localizedDescription)"
        }
    }

    func reportUIError(_ message: String) {
        statusMessage = message
    }

    func reload() {
        let sessionLoad = loadSessions()
        sessions = sessionLoad.sessions
        statusMessage = sessionLoad.failureCount == 0
            ? nil
            : "有 \(sessionLoad.failureCount) 个加密会话无法验证，内容未载入。"
        if let selectedSessionID {
            let selectionStillExists = sessions.contains { $0.id == selectedSessionID }
            if selectionStillExists == false {
                self.selectedSessionID = nil
            }
        }
        do {
            memoryLedger = try memoryRepository.load()
        } catch ZhulongSidecarRepositoryError.missingMemoryLedger {
            memoryLedger = ZhulongMemoryLedger()
        } catch {
            statusMessage = "记忆 sidecar 无法读取：\(error.localizedDescription)"
        }
    }

    @discardableResult
    private func updateSelectedSession(
        _ operation: (inout ZhulongSession) throws -> Void
    ) -> Bool {
        guard let selectedSessionID,
              let index = sessions.firstIndex(where: { $0.id == selectedSessionID })
        else { return false }
        do {
            var session = sessions[index]
            try operation(&session)
            try sessionRepository.save(session)
            sessions[index] = session
            sessions.sort { $0.events.last?.occurredAt ?? .distantPast > $1.events.last?.occurredAt ?? .distantPast }
            statusMessage = nil
            return true
        } catch {
            statusMessage = "会话操作失败：\(error.localizedDescription)"
            return false
        }
    }

    private func replaceLoadedSession(_ session: ZhulongSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        sessions.sort { $0.events.last?.occurredAt ?? .distantPast > $1.events.last?.occurredAt ?? .distantPast }
    }

    private func loadSessions() -> (sessions: [ZhulongSession], failureCount: Int) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return ([], 0) }
        var failureCount = 0
        let sessions = urls.compactMap { url -> ZhulongSession? in
            guard url.pathExtension == "zhs" else { return nil }
            guard let uuid = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                failureCount += 1
                return nil
            }
            do {
                return try sessionRepository.load(ZhulongSessionID(uuid))
            } catch {
                failureCount += 1
                return nil
            }
        }
        .sorted { $0.events.last?.occurredAt ?? .distantPast > $1.events.last?.occurredAt ?? .distantPast }
        return (sessions, failureCount)
    }

    private func record(for entry: ZhulongSessionEntry) -> ZhulongStreamRecord {
        let actor: ZhulongStreamActor = entry.author == .user ? .user : .zhulong
        let title: String = switch entry.kind {
        case .statement: entry.author == .user ? "用户说明" : "烛龙说明"
        case .question: "需要澄清"
        case .answer: "用户回答"
        case .decision: "用户决定"
        case .correction: "追加更正"
        }
        return ZhulongStreamRecord(
            id: "entry-\(entry.id.rawValue.uuidString)",
            occurredAt: entry.createdAt,
            actor: actor,
            section: entry.kind == .decision || entry.kind == .correction ? .decision : .intent,
            eyebrow: entry.author == .user ? "你" : "烛龙",
            title: title,
            body: entry.content,
            isBoundary: entry.kind == .decision || entry.kind == .correction,
            isInvalidation: false
        )
    }

    private func record(for event: ZhulongSessionEvent) -> ZhulongStreamRecord {
        ZhulongStreamRecord(
            id: "event-\(event.sequence)",
            occurredAt: event.occurredAt,
            actor: actor(for: event.kind),
            section: section(for: event.kind),
            eyebrow: eyebrow(for: event.kind),
            title: event.summary,
            body: detail(for: event),
            isBoundary: isBoundary(event.kind),
            isInvalidation: isInvalidation(event.kind)
        )
    }

    private func actor(for kind: ZhulongSessionEventKind) -> ZhulongStreamActor {
        switch kind {
        case .sessionDecisionRecorded, .planningBriefReviewed, .planningDelegationGranted,
             .planningDecisionGateResolved, .todoDiffRevised, .todoWriteAuthorized,
             .unfinishedCauseResolved, .dailyReviewAuthorized:
            .user
        case .draftReady, .planningBriefPublished, .planningDecisionGateOpened,
             .todoDiffPublished, .unfinishedCauseProposed, .dailyReviewDraftPublished:
            .zhulong
        default:
            .system
        }
    }

    private func section(for kind: ZhulongSessionEventKind) -> ZhulongStreamSection {
        switch kind {
        case .sessionCreated, .scopeAuthorized: .intent
        case .planningBriefPublished, .planningBriefReviewed, .planningBriefInvalidated: .brief
        case .providerRunStarted, .providerRunFailed, .draftReady, .planningDelegationGranted,
             .planningDelegationConsumed, .planningDelegationInvalidated, .planningRunInvalidated:
            .planning
        case .sessionDecisionRecorded, .planningDecisionGateOpened, .planningDecisionGateResolved:
            .decision
        case .todoDiffPublished, .todoDiffRevised, .todoWriteAuthorized, .todoBatchApplied:
            .todo
        case .dailyCloseCaptured, .unfinishedCauseProposed, .unfinishedCauseResolved,
             .dailyReviewDraftPublished, .dailyReviewAuthorized, .dailyReviewApplied:
            .dailyClose
        case .sessionCorrected, .sessionPaused, .sessionResumed, .sessionArchived:
            .lifecycle
        }
    }

    private func eyebrow(for kind: ZhulongSessionEventKind) -> String {
        switch actor(for: kind) {
        case .user: "用户决定"
        case .zhulong: "烛龙产物"
        case .system: isInvalidation(kind) ? "历史边界" : "系统边界"
        }
    }

    private func detail(for kind: ZhulongSessionEventKind) -> String? {
        switch kind {
        case .scopeAuthorized: "范围绑定当前 Provider 配置身份，有效期一小时；Todo 写入仍需另行确认。"
        case .planningDelegationGranted: "这是一次性规划委托，不包含 Todo 写入或未来托管。"
        case .todoWriteAuthorized, .dailyReviewAuthorized: "这项授权只可消费一次，并绑定当前草稿摘要。"
        case .todoBatchApplied, .dailyReviewApplied: "结果已形成不可重排的应用回执。"
        case .planningBriefInvalidated, .planningDelegationInvalidated, .planningRunInvalidated:
            "原内容继续可审计，但不能恢复旧执行能力。"
        default: nil
        }
    }

    private func detail(for event: ZhulongSessionEvent) -> String? {
        guard case let .providerRun(runID) = event.reference else {
            return detail(for: event.kind)
        }
        guard let send = selectedSession?.providerSends.last(where: { $0.runID == runID }) else {
            return detail(for: event.kind)
        }
        switch send.result {
        case let .succeeded(_, response):
            switch send.purpose {
            case .conversation:
                return response.content
            case .delegatedPlanning:
                return "Provider 已返回结构化规划产物；原始响应保留在加密会话账本中。"
            }
        case let .failed(_, failure): return failure.message
        case .running: return detail(for: event.kind)
        }
    }

    private func isBoundary(_ kind: ZhulongSessionEventKind) -> Bool {
        switch kind {
        case .scopeAuthorized, .planningBriefReviewed, .planningDelegationGranted,
             .planningDecisionGateOpened, .planningDecisionGateResolved,
             .todoWriteAuthorized, .todoBatchApplied, .sessionCorrected,
             .planningBriefInvalidated, .planningDelegationInvalidated,
             .planningRunInvalidated, .dailyReviewAuthorized, .dailyReviewApplied:
            true
        default:
            false
        }
    }

    private func isInvalidation(_ kind: ZhulongSessionEventKind) -> Bool {
        switch kind {
        case .planningBriefInvalidated, .planningDelegationInvalidated, .planningRunInvalidated:
            true
        default:
            false
        }
    }
}
