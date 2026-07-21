import Foundation
import NoonmarkCore
import NoonmarkMacRuntime
import NoonmarkZhulong

private struct ZhulongApplicationE2EInterruption: Error {}

struct ZhulongWorkspaceApplicationResult {
    let engine: NoonmarkEngine
    let commitProgress: ZhulongApplicationCommitProgress
    let commitCompleted: Bool
}

enum ZhulongStreamActor: Equatable {
    case user
    case zhulong
    case system
}

extension ZhulongDataScope {
    var presentationCopyKey: ZhulongScopeCopyKey {
        switch self {
        case .currentDayTodo: .currentDayTodo
        case .taskPool: .taskPool
        case .unfinishedPool: .unfinishedPool
        case .completedPool: .completedPool
        case .taskClassifications: .taskClassifications
        }
    }
}

private extension ZhulongSessionEventKind {
    var presentationCopyKey: ZhulongEventCopyKey {
        guard let key = ZhulongEventCopyKey(rawValue: rawValue) else {
            preconditionFailure("Missing Zhulong event presentation key: \(rawValue)")
        }
        return key
    }
}

enum ZhulongStreamSection: CaseIterable, Identifiable {
    case intent
    case brief
    case planning
    case decision
    case todo
    case dailyClose
    case lifecycle

    var id: String {
        switch self {
        case .intent: "intent"
        case .brief: "brief"
        case .planning: "planning"
        case .decision: "decision"
        case .todo: "todo"
        case .dailyClose: "daily-close"
        case .lifecycle: "lifecycle"
        }
    }
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
    let isCriticalSystemNotice: Bool
}

/// Text currently arriving from an authorized Provider. This exists only in
/// memory; a completed Provider response remains the sole source of a durable
/// Zhulong conversation record.
struct ZhulongLiveResponse: Equatable {
    var content: String
}

@MainActor
final class ZhulongWorkspaceStore: ObservableObject {
    @Published private(set) var sessions: [ZhulongSession] = []
    @Published private(set) var selectedSessionID: ZhulongSessionID?
    @Published private(set) var memoryLedger = ZhulongMemoryLedger()
    @Published private(set) var status: ZhulongWorkspaceNotice?
    @Published private(set) var liveResponses: [ZhulongSessionID: ZhulongLiveResponse] = [:]
    @Published private(set) var presentationLanguage: AppLanguage = .chinese
    @Published var variant: ZhulongStreamView {
        didSet {
            streamViewRepository.save(variant)
        }
    }

    private let directoryURL: URL
    private let sessionRepository: EncryptedFileZhulongSessionRepository
    private let memoryRepository: EncryptedFileZhulongMemoryRepository
    private let providerOrchestrator: ZhulongProviderOrchestrator
    private let applicationJournal: EncryptedFileZhulongApplicationJournal
    private let streamViewRepository: ZhulongStreamViewRepository

    init(directoryURL: URL, keySource: any ZhulongSidecarKeySource) {
        self.directoryURL = directoryURL
        let streamViewRepository = ZhulongStreamViewRepository()
        self.streamViewRepository = streamViewRepository
        variant = AppLaunchArguments.value(after: "--e2e-zhulong-stream-variant")
            .flatMap(ZhulongStreamView.init(rawValue:))
            ?? streamViewRepository.load()
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

    var selectedLiveResponse: ZhulongLiveResponse? {
        guard let selectedSessionID else { return nil }
        return liveResponses[selectedSessionID]
    }

    var statusMessage: String? {
        status.map { presentationCopy.notice($0) }
    }

    func records(using copy: ZhulongCopy) -> [ZhulongStreamRecord] {
        guard let session = selectedSession else { return [] }
        var projected = session.entries.map { record(for: $0, copy: copy) }
        projected.append(contentsOf: session.events
            .filter { isConversationResponseEvent($0, in: session) == false }
            .map { record(for: $0, copy: copy) })
        return projected.sorted { lhs, rhs in
            if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
            return lhs.id < rhs.id
        }
    }

    func selectedSessionStatus(using copy: ZhulongCopy) -> String {
        copy.sessionStatus(sessionState, style: .compact)
    }

    func setPresentationLanguage(_ language: AppLanguage) {
        guard presentationLanguage != language else { return }
        presentationLanguage = language
    }

    private var presentationCopy: ZhulongCopy {
        AppPresentation(language: presentationLanguage).zhulong
    }

    private var sessionState: ZhulongSessionStateCopyKey {
        guard let session = selectedSession else { return .noSelection }
        if session.workspaceStatus == .paused { return .paused }
        if session.workspaceStatus == .archived { return .archived }
        return switch session.phase {
        case .scopeReview: .scopeReview
        case .readyForProvider: .readyForProvider
        case .providerRunning: .providerRunning
        case .decisionGate: .decisionGate
        case .draftReview: .draftReview
        }
    }

    func createSession(
        intent: String,
        purpose: ZhulongSessionPurpose = .freeform,
        scopes: Set<ZhulongDataScope>,
        now: Date = Date()
    ) {
        do {
            try assertNoPendingApplication()
            let session = try ZhulongSession(
                primaryIntent: intent,
                purpose: purpose,
                proposedScopes: scopes,
                now: now
            )
            try sessionRepository.save(session)
            sessions.insert(session, at: 0)
            selectedSessionID = session.id
            status = nil
        } catch {
            projectSidecarMutationFailure(
                fallback: .sessionCreationFailed
            )
        }
    }

    func selectSession(_ id: ZhulongSessionID) {
        selectedSessionID = id
    }

    func showHome() {
        selectedSessionID = nil
    }

    @discardableResult
    func authorizeCurrentSession(
        providerIdentity: ZhulongProviderConfigurationIdentity,
        now: Date = Date()
    ) -> Bool {
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

    @discardableResult
    func appendToCurrentSession(
        author: ZhulongSessionEntryAuthor,
        kind: ZhulongSessionEntryKind,
        content: String,
        now: Date = Date()
    ) -> Bool {
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
                            initialNoteBody: presentationCopy.planningStageNote(stageTitle: stage.title),
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

    var hasActiveTodoAuthorization: Bool {
        selectedSession?.todoWriteAuthorizations.contains { $0.status == .active } == true
    }

    func applyCurrentTodoDiff(
        to currentEngine: NoonmarkEngine,
        today: LocalDate,
        reference: Date,
        persistEngine: (NoonmarkEngine, Date) throws -> Void,
        reconcileEnginePersistenceFailure: (
            ZhulongPendingApplication
        ) throws -> ZhulongEnginePersistenceResolution
    ) -> ZhulongWorkspaceApplicationResult? {
        guard let session = selectedSession else { return nil }
        do {
            guard try applicationJournal.load() == nil else {
                throw ZhulongPendingApplicationRecoveryError
                    .applicationAlreadyPending
            }
            let currentDraftID = session.currentTodoDiff?.id
            let requiresAuthorization =
                session.todoWriteAuthorizations.contains {
                    $0.draftID == currentDraftID && $0.status == .active
                } == false
            let timeline = try ZhulongApplicationMutationTimeline(
                reference: reference,
                engine: currentEngine,
                selectedSession: session,
                pendingApplication: nil,
                requiresAuthorization: requiresAuthorization
            )
            var afterSession = session
            var afterEngine = try NoonmarkEngine(snapshot: currentEngine.snapshot())
            if let authorizationAt = timeline.authorizationAt {
                _ = try afterSession.authorizeTodoWrite(
                    against: afterEngine,
                    today: today,
                    now: authorizationAt
                )
            }
            let receipt = try afterSession.applyAuthorizedTodoDiff(
                to: &afterEngine,
                today: today,
                now: timeline.applyAt
            )
            let pending = try ZhulongPendingApplication(
                kind: .todoDiff(receipt.draftID),
                sessionID: session.id,
                beforeSnapshot: currentEngine.snapshot(),
                afterSnapshot: afterEngine.snapshot(),
                beforeSession: session,
                afterSession: afterSession,
                createdAt: timeline.applyAt
            )
            let prepareJournal = try applicationJournal.save(pending)
            let outcome = finishApplicationCommit(
                pending: pending,
                prepareJournal: prepareJournal,
                persistEngine: {
                    try persistEngine(afterEngine, timeline.applyAt)
                },
                reconcileEnginePersistenceFailure: {
                    try reconcileEnginePersistenceFailure(pending)
                }
            )
            guard outcome.durableEngineIsAfter else {
                projectApplicationCommit(
                    outcome,
                    operation: .todoBatch
                )
                return nil
            }
            projectApplicationCommit(
                outcome,
                operation: .todoBatch
            )
            return ZhulongWorkspaceApplicationResult(
                engine: afterEngine,
                commitProgress: outcome.progress,
                commitCompleted: outcome.commitCompleted
            )
        } catch {
            projectApplicationPreparationFailure(
                operation: .todoBatch
            )
            return nil
        }
    }

    func applyCurrentDailyReview(
        to currentEngine: NoonmarkEngine,
        reference: Date,
        persistEngine: (NoonmarkEngine, Date) throws -> Void,
        reconcileEnginePersistenceFailure: (
            ZhulongPendingApplication
        ) throws -> ZhulongEnginePersistenceResolution,
        interruptAfterEnginePersisted: Bool = false
    ) -> ZhulongWorkspaceApplicationResult? {
        guard let session = selectedSession,
              let draft = session.dailyReviewDrafts.last
        else { return nil }
        do {
            guard try applicationJournal.load() == nil else {
                throw ZhulongPendingApplicationRecoveryError
                    .applicationAlreadyPending
            }
            let requiresAuthorization =
                session.dailyReviewAuthorizations.contains {
                    $0.draftID == draft.id && $0.status == .active
                } == false
            let timeline = try ZhulongApplicationMutationTimeline(
                reference: reference,
                engine: currentEngine,
                selectedSession: session,
                pendingApplication: nil,
                requiresAuthorization: requiresAuthorization
            )
            var afterSession = session
            var afterEngine = try NoonmarkEngine(snapshot: currentEngine.snapshot())
            if let authorizationAt = timeline.authorizationAt {
                _ = try afterSession.authorizeDailyReview(
                    draft.id,
                    against: afterEngine,
                    now: authorizationAt
                )
            }
            _ = try afterSession.applyAuthorizedDailyReview(
                draft.id,
                to: &afterEngine,
                now: timeline.applyAt
            )
            let pending = try ZhulongPendingApplication(
                kind: .dailyReview(draft.id),
                sessionID: session.id,
                beforeSnapshot: currentEngine.snapshot(),
                afterSnapshot: afterEngine.snapshot(),
                beforeSession: session,
                afterSession: afterSession,
                createdAt: timeline.applyAt
            )
            let prepareJournal = try applicationJournal.save(pending)
            if interruptAfterEnginePersisted {
                let outcome = ZhulongApplicationCommitCoordinator.finish(
                    prepareJournal: prepareJournal,
                    engineAlreadyPersisted: false,
                    persistEngine: {
                        try persistEngine(afterEngine, timeline.applyAt)
                    },
                    reconcileEnginePersistenceFailure: {
                        try reconcileEnginePersistenceFailure(pending)
                    },
                    persistSession: {
                        throw ZhulongApplicationE2EInterruption()
                    },
                    clearJournal: { requirement in
                        try applicationJournal.clear(
                            pending,
                            requiring: requirement
                        )
                    }
                )
                guard outcome.durableEngineIsAfter else {
                    projectApplicationCommit(
                        outcome,
                        operation: .dailyReview
                    )
                    return nil
                }
                status = .e2eInterruption
                return ZhulongWorkspaceApplicationResult(
                    engine: afterEngine,
                    commitProgress: outcome.progress,
                    commitCompleted: outcome.commitCompleted
                )
            }
            let outcome = finishApplicationCommit(
                pending: pending,
                prepareJournal: prepareJournal,
                persistEngine: {
                    try persistEngine(afterEngine, timeline.applyAt)
                },
                reconcileEnginePersistenceFailure: {
                    try reconcileEnginePersistenceFailure(pending)
                }
            )
            guard outcome.durableEngineIsAfter else {
                projectApplicationCommit(
                    outcome,
                    operation: .dailyReview
                )
                return nil
            }
            projectApplicationCommit(
                outcome,
                operation: .dailyReview
            )
            return ZhulongWorkspaceApplicationResult(
                engine: afterEngine,
                commitProgress: outcome.progress,
                commitCompleted: outcome.commitCompleted
            )
        } catch {
            projectApplicationPreparationFailure(
                operation: .dailyReview
            )
            return nil
        }
    }

    func recoverPendingApplication(
        currentEngine: NoonmarkEngine,
        persistEngine: (NoonmarkEngine, Date) throws -> Void,
        reconcileEnginePersistenceFailure: (
            ZhulongPendingApplication
        ) throws -> ZhulongEnginePersistenceResolution
    ) -> NoonmarkEngine {
        do {
            guard let pending = try applicationJournal.load() else {
                status = ZhulongApplicationCommitNoticeProjection
                    .noticeAfterConfirmedAbsentJournal(status)
                return currentEngine
            }
            let operation = applicationCommitOperation(for: pending.kind)
            let plan = try ZhulongPendingApplicationRecoveryPlan(
                currentEngine: currentEngine,
                pendingApplication: pending
            )
            let recoveredEngine = try NoonmarkEngine(
                snapshot: plan.recoveredSnapshot
            )
            let outcome = finishApplicationCommit(
                pending: pending,
                engineAlreadyPersisted: plan.persistenceChangedAt == nil,
                persistEngine: {
                    guard let changedAt = plan.persistenceChangedAt else {
                        return
                    }
                    try persistEngine(recoveredEngine, changedAt)
                },
                reconcileEnginePersistenceFailure: {
                    try reconcileEnginePersistenceFailure(pending)
                }
            )
            guard outcome.durableEngineIsAfter else {
                if outcome.enginePersistenceFailureResolution == .conflict {
                    status = .applicationRecoveryConflict
                } else {
                    projectApplicationCommit(
                        outcome,
                        operation: operation
                    )
                }
                return currentEngine
            }
            if outcome.commitCompleted == false {
                let sidecarError = outcome.underlyingError
                    as? ZhulongSidecarRepositoryError
                status = if sidecarError == .sessionConflict {
                    .applicationRecoveryConflict
                } else {
                    ZhulongApplicationCommitNoticeProjection.notice(
                        operation: operation,
                        state: outcome.progress == .completed
                            ? .verifiedCompletion
                            : .recoveryPending
                    ) ?? .applicationCommitRecoveryPending
                }
                return recoveredEngine
            }
            status = .applicationRecovered
            return recoveredEngine
        } catch ZhulongPendingApplicationRecoveryError.snapshotConflict {
            status = .applicationRecoveryConflict
            return currentEngine
        } catch {
            status = applicationJournalIsDefinitelyAbsent()
                ? .applicationRecoveryFailed
                : .applicationCommitRecoveryPending
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
        do {
            try assertNoPendingApplication()
            status = .providerRunning
            liveResponses[selectedSessionID] = ZhulongLiveResponse(content: "")
            let session = try await providerOrchestrator.runStreaming(
                sessionID: selectedSessionID,
                payload: payload,
                provider: provider,
                onDelta: { [weak self] delta in
                    await self?.appendLiveResponse(
                        delta,
                        for: selectedSessionID
                    )
                }
            )
            replaceLoadedSession(session)
            clearLiveResponse(for: selectedSessionID)
            status = nil
        } catch {
            clearLiveResponse(for: selectedSessionID)
            reload()
            projectSidecarMutationFailure(
                fallback: .providerRunFailed
            )
        }
    }

    private func appendLiveResponse(
        _ delta: String,
        for sessionID: ZhulongSessionID
    ) {
        guard var liveResponse = liveResponses[sessionID] else { return }
        liveResponse.content += delta
        liveResponses[sessionID] = liveResponse
    }

    private func clearLiveResponse(for sessionID: ZhulongSessionID) {
        liveResponses[sessionID] = nil
    }

    func runCurrentPlanningSession(
        payload: ZhulongProviderPayload,
        provider: any ZhulongProvider
    ) async {
        guard let selectedSessionID,
              let delegationID = selectedSession?.activePlanningDelegation?.id
        else { return }
        do {
            try assertNoPendingApplication()
            status = .planningProviderRunning
            let session = try await providerOrchestrator.runPlanning(
                sessionID: selectedSessionID,
                delegationID: delegationID,
                payload: payload,
                provider: provider
            )
            replaceLoadedSession(session)
            status = nil
        } catch {
            reload()
            projectSidecarMutationFailure(
                fallback: .planningRunFailed
            )
        }
    }

    func setMemoryEnabled(_ enabled: Bool) {
        do {
            var ledger = memoryLedger
            ledger.setEnabled(enabled)
            try memoryRepository.save(ledger)
            memoryLedger = ledger
            status = nil
        } catch {
            status = .memorySaveFailed
        }
    }

    func reportUIError(_ notice: ZhulongWorkspaceNotice) {
        status = notice
    }

    func reportUIError(_ message: String) {
        status = .diagnostic(message)
    }

    func reload() {
        let sessionLoad = loadSessions()
        sessions = sessionLoad.sessions
        status = sessionLoad.failureCount == 0
            ? nil
            : .unverifiableSessions(sessionLoad.failureCount)
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
            status = .memoryReadFailed
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
            try assertNoPendingApplication()
            var session = sessions[index]
            let expectedSession = session
            try operation(&session)
            try sessionRepository.save(
                session,
                replacing: expectedSession
            )
            sessions[index] = session
            sessions.sort { $0.events.last?.occurredAt ?? .distantPast > $1.events.last?.occurredAt ?? .distantPast }
            status = nil
            return true
        } catch {
            projectSidecarMutationFailure(
                fallback: .sessionOperationFailed
            )
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

    func assertNoPendingApplication() throws {
        try ZhulongPendingApplicationMutationGate.validate(
            applicationJournal.load()
        )
    }

    func assertMatchesPendingApplicationAfterSnapshot(
        _ candidate: NoonmarkEngine
    ) throws {
        guard let pending = try applicationJournal.load() else {
            throw ZhulongPendingApplicationRecoveryError.snapshotConflict
        }
        let candidateIdentity = try ZhulongApplicationSnapshotDigest.value(
            candidate.snapshot()
        )
        let afterIdentity = try ZhulongApplicationSnapshotDigest.value(
            pending.afterSnapshot
        )
        guard candidateIdentity == afterIdentity else {
            throw ZhulongPendingApplicationRecoveryError.snapshotConflict
        }
    }

    private func projectApplicationCommit(
        _ outcome: ZhulongApplicationCommitOutcome,
        operation: ZhulongApplicationCommitOperation
    ) {
        let progress = applicationCommitProgressEvidence(
            for: outcome.progress
        )
        let presentationState = ZhulongApplicationCommitNoticeProjection.state(
            progress: progress,
            recoveredCommitError:
            outcome.recoveredEnginePersistenceError != nil
                || outcome.recoveredJournalMutation,
            journal: applicationJournalEvidence()
        )
        status = ZhulongApplicationCommitNoticeProjection.notice(
            operation: operation,
            state: presentationState
        )
    }

    private func applicationCommitProgressEvidence(
        for progress: ZhulongApplicationCommitProgress
    ) -> ZhulongApplicationCommitProgressEvidence {
        switch progress {
        case .beforeEngine:
            return .beforeEngine
        case .enginePersistenceUnresolved:
            return .enginePersistenceUnresolved
        case .enginePersisted:
            return .enginePersisted
        case .sessionPersisted:
            return .sessionPersisted
        case .completed:
            return .completed
        }
    }

    private func projectApplicationPreparationFailure(
        operation: ZhulongApplicationCommitOperation
    ) {
        let fallback = switch operation {
        case .todoBatch:
            ZhulongWorkspaceNotice.todoBatchApplyFailed
        case .dailyReview:
            ZhulongWorkspaceNotice.dailyReviewSaveFailed
        }
        status = ZhulongApplicationCommitNoticeProjection
            .mutationFailureNotice(
                fallback: fallback,
                journal: applicationJournalEvidence()
            )
    }

    private func projectSidecarMutationFailure(
        fallback: ZhulongWorkspaceNotice
    ) {
        status = ZhulongApplicationCommitNoticeProjection
            .mutationFailureNotice(
                fallback: fallback,
                journal: applicationJournalEvidence()
            )
    }

    private func applicationJournalIsDefinitelyAbsent() -> Bool {
        do {
            return try applicationJournal.load() == nil
        } catch {
            return false
        }
    }

    private func applicationJournalEvidence() -> ZhulongApplicationJournalEvidence {
        applicationJournalIsDefinitelyAbsent()
            ? .absent
            : .presentOrUnverifiable
    }

    private func applicationCommitOperation(
        for kind: ZhulongPendingApplicationKind
    ) -> ZhulongApplicationCommitOperation {
        switch kind {
        case .todoDiff:
            .todoBatch
        case .dailyReview:
            .dailyReview
        }
    }

    private func finishApplicationCommit(
        pending: ZhulongPendingApplication,
        prepareJournal: ZhulongApplicationJournalCommitOutcome = .committed,
        engineAlreadyPersisted: Bool = false,
        persistEngine: () throws -> Void,
        reconcileEnginePersistenceFailure: () throws ->
            ZhulongEnginePersistenceResolution
    ) -> ZhulongApplicationCommitOutcome {
        let outcome = ZhulongApplicationCommitCoordinator.finish(
            prepareJournal: prepareJournal,
            engineAlreadyPersisted: engineAlreadyPersisted,
            persistEngine: persistEngine,
            reconcileEnginePersistenceFailure:
            reconcileEnginePersistenceFailure,
            persistSession: {
                try ZhulongPendingSessionReconciler.reconcile(
                    pendingApplication: pending,
                    loadPersistedSession: {
                        try sessionRepository.load(pending.sessionID)
                    },
                    replaceExpectedSession: { replacement, expected in
                        try sessionRepository.save(
                            replacement,
                            replacing: expected,
                            authorizedBy: pending
                        )
                    }
                )
                replaceLoadedSession(pending.afterSession)
            },
            clearJournal: { requirement in
                try applicationJournal.clear(
                    pending,
                    requiring: requirement
                )
            }
        )
        if let cleanupError = outcome.cleanupError {
            recordApplicationCommitError(
                cleanupError,
                event: "journal_cleanup_failure"
            )
        }
        if let reconciliationError = outcome.reconciliationError {
            recordApplicationCommitError(
                reconciliationError,
                event: "engine_reconciliation_failure"
            )
        }
        if let recoveredError = outcome.recoveredEnginePersistenceError {
            recordApplicationCommitError(
                recoveredError,
                event: "engine_recovered_after_error"
            )
        }
        return outcome
    }

    private func recordApplicationCommitError(
        _ error: any Error,
        event: String
    ) {
        let telemetry = ZhulongErrorTelemetry(error)
        NSLog(
            "NoonmarkZhulongApplicationCommit event=%@ error_kind=%@ error_code=%@",
            event,
            telemetry.kind.rawValue,
            telemetry.code.map(String.init) ?? "none"
        )
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

    private func record(
        for entry: ZhulongSessionEntry,
        copy: ZhulongCopy
    ) -> ZhulongStreamRecord {
        let actor: ZhulongStreamActor = entry.author == .user ? .user : .zhulong
        let titleKey: ZhulongEntryKindCopyKey = switch entry.kind {
        case .statement: entry.author == .user ? .userStatement : .zhulongStatement
        case .question: .question
        case .answer: .answer
        case .decision: .decision
        case .correction: .correction
        }
        return ZhulongStreamRecord(
            id: "entry-\(entry.id.rawValue.uuidString)",
            occurredAt: entry.createdAt,
            actor: actor,
            section: entry.kind == .decision || entry.kind == .correction ? .decision : .intent,
            eyebrow: entry.author == .user ? copy.userEyebrow : copy.zhulongEyebrow,
            title: copy.entryTitle(titleKey),
            body: entry.content,
            isBoundary: entry.kind == .decision || entry.kind == .correction,
            isInvalidation: false,
            isCriticalSystemNotice: false
        )
    }

    private func isConversationResponseEvent(
        _ event: ZhulongSessionEvent,
        in session: ZhulongSession
    ) -> Bool {
        guard event.kind == .draftReady,
              let runID = event.providerRunID,
              let send = session.providerSends.last(where: { $0.runID == runID })
        else { return false }
        guard case .conversation = send.purpose else { return false }
        return true
    }

    private func record(
        for event: ZhulongSessionEvent,
        copy: ZhulongCopy
    ) -> ZhulongStreamRecord {
        ZhulongStreamRecord(
            id: "event-\(event.sequence)",
            occurredAt: event.occurredAt,
            actor: actor(for: event.kind),
            section: section(for: event.kind),
            eyebrow: eyebrow(for: event.kind, copy: copy),
            title: copy.eventTitle(
                event.kind.presentationCopyKey,
                chineseAuditTitle: event.summary
            ),
            body: detail(for: event, copy: copy),
            isBoundary: isBoundary(event.kind),
            isInvalidation: isInvalidation(event.kind),
            isCriticalSystemNotice: isCriticalSystemNotice(event.kind)
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

    private func eyebrow(
        for kind: ZhulongSessionEventKind,
        copy: ZhulongCopy
    ) -> String {
        switch actor(for: kind) {
        case .user: copy.userDecisionEyebrow
        case .zhulong: copy.zhulongOutputEyebrow
        case .system: isInvalidation(kind) ? copy.historyBoundaryEyebrow : copy.systemBoundaryEyebrow
        }
    }

    private func detail(
        for kind: ZhulongSessionEventKind,
        copy: ZhulongCopy
    ) -> String? {
        switch kind {
        case .scopeAuthorized: copy.scopeAuthorizationDetail
        case .planningDelegationGranted: copy.planningDelegationDetail
        case .todoWriteAuthorized, .dailyReviewAuthorized: copy.singleUseAuthorizationDetail
        case .todoBatchApplied, .dailyReviewApplied: copy.applicationReceiptDetail
        case .planningBriefInvalidated, .planningDelegationInvalidated, .planningRunInvalidated:
            copy.invalidationDetail
        default: nil
        }
    }

    private func detail(
        for event: ZhulongSessionEvent,
        copy: ZhulongCopy
    ) -> String? {
        guard case let .providerRun(runID) = event.reference else {
            return detail(for: event.kind, copy: copy)
        }
        guard let send = selectedSession?.providerSends.last(where: { $0.runID == runID }) else {
            return detail(for: event.kind, copy: copy)
        }
        switch send.result {
        case let .succeeded(_, response):
            switch send.purpose {
            case .conversation:
                return response.content
            case .delegatedPlanning:
                return copy.delegatedPlanningSuccessDetail
            }
        case .failed: return copy.providerFailureDetail
        case .running: return detail(for: event.kind, copy: copy)
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

    private func isCriticalSystemNotice(_ kind: ZhulongSessionEventKind) -> Bool {
        switch kind {
        case .providerRunFailed, .todoBatchApplied, .dailyReviewApplied, .sessionArchived:
            true
        default:
            false
        }
    }
}
