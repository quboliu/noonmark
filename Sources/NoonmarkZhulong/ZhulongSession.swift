import Foundation

public struct ZhulongSessionID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString.lowercased() }
}

public enum ZhulongProviderKind: String, Codable, Hashable, Sendable {
    case openAICompatible
    case localModel
    case customHTTP
}

public enum ZhulongProviderLocation: String, Codable, Hashable, Sendable {
    case local
    case remote
}

public enum ZhulongProviderDataCapability: String, Codable, Hashable, Sendable {
    case structuredOutput
    case taskContext
    case sessionSummary
    case memoryContext
}

public struct ZhulongProviderConfigurationIdentity: Codable, Hashable, Sendable {
    public let providerID: String
    public let kind: ZhulongProviderKind
    public let baseURL: URL?
    public let location: ZhulongProviderLocation
    public let model: String
    public let dataCapabilities: Set<ZhulongProviderDataCapability>

    public init(
        providerID: String,
        kind: ZhulongProviderKind,
        baseURL: URL?,
        location: ZhulongProviderLocation,
        model: String,
        dataCapabilities: Set<ZhulongProviderDataCapability>
    ) throws {
        let normalizedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedProviderID.isEmpty == false,
              normalizedModel.isEmpty == false,
              dataCapabilities.isEmpty == false
        else {
            throw ZhulongSessionError.emptyProviderIdentity
        }
        guard location != .remote || baseURL != nil else {
            throw ZhulongSessionError.invalidProviderIdentity
        }
        if let components = baseURL.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) {
            guard components.user == nil, components.password == nil, components.fragment == nil else {
                throw ZhulongSessionError.invalidProviderIdentity
            }
        }

        self.providerID = normalizedProviderID
        self.kind = kind
        self.baseURL = baseURL
        self.location = location
        self.model = normalizedModel
        self.dataCapabilities = dataCapabilities
    }

    public var dataRecipient: ZhulongProviderDataRecipient {
        ZhulongProviderDataRecipient(
            location: location,
            remoteEndpoint: location == .remote ? baseURL : nil
        )
    }
}

public struct ZhulongProviderDataRecipient: Hashable, Sendable {
    public let location: ZhulongProviderLocation
    public let remoteEndpoint: URL?

    fileprivate init(
        location: ZhulongProviderLocation,
        remoteEndpoint: URL?
    ) {
        self.location = location
        self.remoteEndpoint = remoteEndpoint
    }
}

public enum ZhulongDataScope: String, Codable, CaseIterable, Hashable, Sendable {
    case currentDayTodo
    case taskPool
    case unfinishedPool
    case completedPool
    case taskClassifications
}

public enum ZhulongSessionPhase: String, Codable, Equatable, Sendable {
    case scopeReview
    case readyForProvider
    case providerRunning
    case decisionGate
    case draftReview
}

public enum ZhulongScopeAuthorizationRequirement: Equatable, Sendable {
    case initialSession
    case dataScopeChanged
    case dataRecipientChanged
}

public enum ZhulongSessionEventKind: String, Codable, Equatable, Sendable {
    case sessionCreated
    case scopeAuthorized
    case providerRunStarted
    case providerRunFailed
    case draftReady
    case sessionCorrected
    case sessionDecisionRecorded
    case planningBriefPublished
    case planningBriefReviewed
    case planningBriefInvalidated
    case planningDelegationGranted
    case planningDelegationConsumed
    case planningDelegationInvalidated
    case planningRunInvalidated
    case planningDecisionGateOpened
    case planningDecisionGateResolved
    case todoDiffPublished
    case todoDiffRevised
    case todoWriteAuthorized
    case todoBatchApplied
    case dailyCloseCaptured
    case unfinishedCauseProposed
    case unfinishedCauseResolved
    case dailyReviewDraftPublished
    case dailyReviewAuthorized
    case dailyReviewApplied
    case sessionPaused
    case sessionResumed
    case sessionArchived
}

public struct ZhulongSessionEvent: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let kind: ZhulongSessionEventKind
    public let occurredAt: Date
    public let summary: String
    public let reference: ZhulongSessionEventReference?

    public var providerRunID: ZhulongProviderRunID? {
        guard case let .providerRun(runID) = reference else { return nil }
        return runID
    }

    public var sessionEntryID: ZhulongSessionEntryID? {
        guard case let .sessionEntry(entryID) = reference else { return nil }
        return entryID
    }
}

public struct ZhulongScopeAuthorization: Equatable, Sendable {
    public let scopes: Set<ZhulongDataScope>
    public let providerIdentity: ZhulongProviderConfigurationIdentity
    public let grantedAt: Date
}

public enum ZhulongSessionError: Error, Equatable, Sendable {
    case emptyPrimaryIntent
    case emptyScopeProposal
    case emptyProviderIdentity
    case invalidProviderIdentity
    case scopeNotAuthorized
    case scopeDoesNotMatchProposal
    case providerIdentityMismatch
    case providerPayloadScopeMismatch
    case providerRunMismatch
    case noInterruptedProviderRun
    case invalidDraftVersion
    case invalidProviderFailure
    case invalidProviderResponse
    case workspaceInactive
    case invalidWorkspaceTransition
    case providerRunStillActive
    case planningDelegationRequired
    case emptySessionEntry
    case correctionRequiresTarget
    case missingCorrectionTarget
    case correctionTargetIsCorrection
    case decisionGateRequiresAtomicResolution
    case nonMonotonicEventTime
    case invalidTransition(from: ZhulongSessionPhase, to: ZhulongSessionPhase)
}

public enum ZhulongSessionPurpose: String, Codable, Equatable, Sendable {
    case freeform
    case taskShaping
    case dailyClose
    case schedulingAssistance
    case classificationAssistance
    case habitInsight
    case theoryAnalysis
}

public struct ZhulongSession: Equatable, Sendable {
    public let id: ZhulongSessionID
    public let initialPrimaryIntent: String
    public let purpose: ZhulongSessionPurpose
    public let proposedScopes: Set<ZhulongDataScope>
    public private(set) var phase: ZhulongSessionPhase
    public private(set) var authorizations: [ZhulongScopeAuthorization]
    public private(set) var draftVersion: Int?
    public private(set) var providerSends: [ZhulongProviderSendRecord]
    public private(set) var events: [ZhulongSessionEvent]
    public internal(set) var workspaceStatus: ZhulongWorkspaceStatus
    public internal(set) var entries: [ZhulongSessionEntry]
    public internal(set) var planningBriefs: [ZhulongPlanningBrief]
    public internal(set) var planningBriefReviews: [ZhulongPlanningBriefReview]
    public internal(set) var planningBriefInvalidations: [ZhulongPlanningBriefInvalidation]
    public internal(set) var planningDelegations: [ZhulongPlanningDelegation]
    public internal(set) var planningDelegationConsumptions: [ZhulongPlanningDelegationConsumption]
    public internal(set) var planningDelegationInvalidations: [ZhulongPlanningDelegationInvalidation]
    public internal(set) var planningRunInvalidations: [ZhulongPlanningRunInvalidation]
    public internal(set) var decisionGates: [ZhulongDecisionGate]
    public internal(set) var decisionGateResolutions: [ZhulongDecisionGateResolution]
    public internal(set) var planArtifacts: [ZhulongPlanArtifact]
    public internal(set) var todoDiffDrafts: [ZhulongTodoDiffDraft]
    public internal(set) var todoWriteAuthorizations: [ZhulongTodoWriteAuthorization]
    public internal(set) var todoApplyReceipts: [ZhulongTodoApplyReceipt]
    public internal(set) var dailyCloseSnapshots: [ZhulongDailyCloseSnapshot]
    public internal(set) var unfinishedCauseHypotheses: [ZhulongUnfinishedCauseHypothesis]
    public internal(set) var unfinishedCauseResolutions: [ZhulongUnfinishedCauseResolution]
    public internal(set) var dailyReviewDrafts: [ZhulongDailyReviewDraft]
    public internal(set) var dailyReviewAuthorizations: [ZhulongDailyReviewAuthorization]
    public internal(set) var dailyReviewReceipts: [ZhulongDailyReviewReceipt]

    public var authorization: ZhulongScopeAuthorization? { authorizations.last }
    public var primaryIntent: String {
        guard let firstEntry = entries.first else { return initialPrimaryIntent }
        return effectiveContent(for: firstEntry.id) ?? initialPrimaryIntent
    }

    var latestActivityAt: Date {
        max(
            events.last?.occurredAt ?? .distantPast,
            entries.last?.createdAt ?? .distantPast
        )
    }

    public init(
        id: ZhulongSessionID = ZhulongSessionID(),
        primaryIntent: String,
        purpose: ZhulongSessionPurpose = .freeform,
        proposedScopes: Set<ZhulongDataScope>,
        now: Date = Date()
    ) throws {
        let normalizedIntent = primaryIntent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedIntent.isEmpty == false else {
            throw ZhulongSessionError.emptyPrimaryIntent
        }
        guard proposedScopes.isEmpty == false else {
            throw ZhulongSessionError.emptyScopeProposal
        }

        self.id = id
        initialPrimaryIntent = normalizedIntent
        self.purpose = purpose
        self.proposedScopes = proposedScopes
        phase = .scopeReview
        authorizations = []
        draftVersion = nil
        providerSends = []
        workspaceStatus = .active
        entries = [
            ZhulongSessionEntry(
                id: ZhulongSessionEntryID(),
                author: .user,
                kind: .statement,
                content: normalizedIntent,
                createdAt: now,
                correctsEntryID: nil
            )
        ]
        planningBriefs = []
        planningBriefReviews = []
        planningBriefInvalidations = []
        planningDelegations = []
        planningDelegationConsumptions = []
        planningDelegationInvalidations = []
        planningRunInvalidations = []
        decisionGates = []
        decisionGateResolutions = []
        planArtifacts = []
        todoDiffDrafts = []
        todoWriteAuthorizations = []
        todoApplyReceipts = []
        dailyCloseSnapshots = []
        unfinishedCauseHypotheses = []
        unfinishedCauseResolutions = []
        dailyReviewDrafts = []
        dailyReviewAuthorizations = []
        dailyReviewReceipts = []
        events = [
            ZhulongSessionEvent(
                sequence: 1,
                kind: .sessionCreated,
                occurredAt: now,
                summary: "已建立烛龙会话",
                reference: nil
            )
        ]
    }

    init(
        restoredID: ZhulongSessionID,
        primaryIntent: String,
        purpose: ZhulongSessionPurpose,
        proposedScopes: Set<ZhulongDataScope>,
        phase: ZhulongSessionPhase,
        authorizations: [ZhulongScopeAuthorization],
        draftVersion: Int?,
        providerSends: [ZhulongProviderSendRecord],
        events: [ZhulongSessionEvent],
        workspaceStatus: ZhulongWorkspaceStatus,
        entries: [ZhulongSessionEntry],
        planningBriefs: [ZhulongPlanningBrief] = [],
        planningBriefReviews: [ZhulongPlanningBriefReview] = [],
        planningBriefInvalidations: [ZhulongPlanningBriefInvalidation] = [],
        planningDelegations: [ZhulongPlanningDelegation] = [],
        planningDelegationConsumptions: [ZhulongPlanningDelegationConsumption] = [],
        planningDelegationInvalidations: [ZhulongPlanningDelegationInvalidation] = [],
        planningRunInvalidations: [ZhulongPlanningRunInvalidation] = [],
        decisionGates: [ZhulongDecisionGate] = [],
        decisionGateResolutions: [ZhulongDecisionGateResolution] = [],
        planArtifacts: [ZhulongPlanArtifact] = [],
        todoDiffDrafts: [ZhulongTodoDiffDraft] = [],
        todoWriteAuthorizations: [ZhulongTodoWriteAuthorization] = [],
        todoApplyReceipts: [ZhulongTodoApplyReceipt] = [],
        dailyCloseSnapshots: [ZhulongDailyCloseSnapshot] = [],
        unfinishedCauseHypotheses: [ZhulongUnfinishedCauseHypothesis] = [],
        unfinishedCauseResolutions: [ZhulongUnfinishedCauseResolution] = [],
        dailyReviewDrafts: [ZhulongDailyReviewDraft] = [],
        dailyReviewAuthorizations: [ZhulongDailyReviewAuthorization] = [],
        dailyReviewReceipts: [ZhulongDailyReviewReceipt] = []
    ) {
        id = restoredID
        initialPrimaryIntent = primaryIntent
        self.purpose = purpose
        self.proposedScopes = proposedScopes
        self.phase = phase
        self.authorizations = authorizations
        self.draftVersion = draftVersion
        self.providerSends = providerSends
        self.events = events
        self.workspaceStatus = workspaceStatus
        self.entries = entries
        self.planningBriefs = planningBriefs
        self.planningBriefReviews = planningBriefReviews
        self.planningBriefInvalidations = planningBriefInvalidations
        self.planningDelegations = planningDelegations
        self.planningDelegationConsumptions = planningDelegationConsumptions
        self.planningDelegationInvalidations = planningDelegationInvalidations
        self.planningRunInvalidations = planningRunInvalidations
        self.decisionGates = decisionGates
        self.decisionGateResolutions = decisionGateResolutions
        self.planArtifacts = planArtifacts
        self.todoDiffDrafts = todoDiffDrafts
        self.todoWriteAuthorizations = todoWriteAuthorizations
        self.todoApplyReceipts = todoApplyReceipts
        self.dailyCloseSnapshots = dailyCloseSnapshots
        self.unfinishedCauseHypotheses = unfinishedCauseHypotheses
        self.unfinishedCauseResolutions = unfinishedCauseResolutions
        self.dailyReviewDrafts = dailyReviewDrafts
        self.dailyReviewAuthorizations = dailyReviewAuthorizations
        self.dailyReviewReceipts = dailyReviewReceipts
    }

    public mutating func authorizeScope(
        _ scopes: Set<ZhulongDataScope>,
        providerIdentity: ZhulongProviderConfigurationIdentity,
        now: Date = Date()
    ) throws {
        guard workspaceStatus == .active else {
            throw ZhulongSessionError.workspaceInactive
        }
        let canExplicitlyReauthorize = phase == .readyForProvider || phase == .draftReview
        guard phase == .scopeReview || canExplicitlyReauthorize else {
            throw ZhulongSessionError.invalidTransition(from: phase, to: .readyForProvider)
        }
        guard scopes == proposedScopes else {
            throw ZhulongSessionError.scopeDoesNotMatchProposal
        }
        try validateEventTime(now)

        let invalidatedDelegation = activePlanningDelegation
        authorizations.append(ZhulongScopeAuthorization(
            scopes: scopes,
            providerIdentity: providerIdentity,
            grantedAt: now
        ))
        // Reauthorisation means the data scope or its recipient changed. The
        // old draft remains in the append-only history but cannot keep posing
        // as the current provider result.
        draftVersion = nil
        phase = .readyForProvider
        appendEvent(
            .scopeAuthorized,
            summary: "已授权 \(scopes.count) 项数据范围",
            now: now
        )
        if let invalidatedDelegation {
            let invalidatedAt = Date(
                timeIntervalSinceReferenceDate: now.timeIntervalSinceReferenceDate.nextUp
            )
            planningDelegationInvalidations.append(ZhulongPlanningDelegationInvalidation(
                delegationID: invalidatedDelegation.id,
                invalidatedAt: invalidatedAt,
                reason: .authorizationChanged
            ))
            appendEvent(
                .planningDelegationInvalidated,
                summary: "授权变更已使旧规划委托失效",
                reference: .planningDelegation(invalidatedDelegation.id),
                now: invalidatedAt
            )
        }
    }

    public func requiresScopeAuthorization(
        for providerIdentity: ZhulongProviderConfigurationIdentity
    ) -> Bool {
        scopeAuthorizationRequirement(
            for: providerIdentity
        ) != nil
    }

    public func scopeAuthorizationRequirement(
        for providerIdentity: ZhulongProviderConfigurationIdentity
    ) -> ZhulongScopeAuthorizationRequirement? {
        guard workspaceStatus == .active else { return nil }
        guard phase == .scopeReview
            || phase == .readyForProvider
            || phase == .draftReview
        else {
            return nil
        }
        guard let authorization else {
            return .initialSession
        }
        if authorization.scopes != proposedScopes {
            return .dataScopeChanged
        }
        if authorization.providerIdentity.dataRecipient
            != providerIdentity.dataRecipient
        {
            return .dataRecipientChanged
        }
        return nil
    }

    public mutating func beginProviderRun(
        payload: ZhulongProviderPayload,
        providerIdentity: ZhulongProviderConfigurationIdentity,
        runID: ZhulongProviderRunID = ZhulongProviderRunID(),
        now: Date = Date()
    ) throws -> ZhulongProviderRequest {
        let authorization = try validateProviderStart(
            providerIdentity: providerIdentity,
            allowsDraftReview: true
        )
        guard payload.scopes.isSubset(of: authorization.scopes) else {
            throw ZhulongSessionError.providerPayloadScopeMismatch
        }
        try validateEventTime(now)
        return startProviderRun(
            payload: payload,
            providerIdentity: providerIdentity,
            purpose: .conversation,
            runID: runID,
            now: now
        )
    }

    public mutating func beginPlanningProviderRun(
        delegationID: ZhulongPlanningDelegationID,
        payload: ZhulongProviderPayload,
        providerIdentity: ZhulongProviderConfigurationIdentity,
        runID: ZhulongProviderRunID = ZhulongProviderRunID(),
        now: Date = Date()
    ) throws -> ZhulongProviderRequest {
        guard let delegation = activePlanningDelegation,
              delegation.id == delegationID
        else {
            throw ZhulongPlanningBriefError.delegationNotActive
        }
        let providerStartedAt = Date(
            timeIntervalSinceReferenceDate: now.timeIntervalSinceReferenceDate.nextUp
        )
        let authorization = try validateProviderStart(
            providerIdentity: providerIdentity,
            allowsDraftReview: true
        )
        guard authorization.providerIdentity.dataRecipient
            == delegation.providerIdentity.dataRecipient,
              delegation.dataScopes.isSubset(of: authorization.scopes),
              payload.scopes == delegation.dataScopes
        else {
            throw ZhulongSessionError.providerPayloadScopeMismatch
        }
        try validateEventTime(now)

        planningDelegationConsumptions.append(ZhulongPlanningDelegationConsumption(
            delegationID: delegationID,
            consumedAt: now
        ))
        appendEvent(
            .planningDelegationConsumed,
            summary: "单次规划委托已消费",
            reference: .planningDelegation(delegationID),
            now: now
        )
        return startProviderRun(
            payload: payload,
            providerIdentity: providerIdentity,
            purpose: .delegatedPlanning(ZhulongPlanningRunContract(delegation: delegation)),
            runID: runID,
            now: providerStartedAt
        )
    }

    private func validateProviderStart(
        providerIdentity: ZhulongProviderConfigurationIdentity,
        allowsDraftReview: Bool
    ) throws -> ZhulongScopeAuthorization {
        guard workspaceStatus == .active else {
            throw ZhulongSessionError.workspaceInactive
        }
        let phaseAllowsRun = phase == .readyForProvider ||
            (allowsDraftReview && phase == .draftReview)
        guard phaseAllowsRun, let authorization else {
            if authorization == nil {
                throw ZhulongSessionError.scopeNotAuthorized
            }
            throw ZhulongSessionError.invalidTransition(from: phase, to: .providerRunning)
        }
        guard providerIdentity.dataRecipient
            == authorization.providerIdentity.dataRecipient
        else {
            throw ZhulongSessionError.providerIdentityMismatch
        }
        return authorization
    }

    private mutating func startProviderRun(
        payload: ZhulongProviderPayload,
        providerIdentity: ZhulongProviderConfigurationIdentity,
        purpose: ZhulongProviderRunPurpose,
        runID: ZhulongProviderRunID,
        now: Date
    ) -> ZhulongProviderRequest {
        let send = ZhulongProviderSendRecord(
            runID: runID,
            providerIdentity: providerIdentity,
            payload: payload,
            purpose: purpose,
            startedAt: now
        )
        providerSends.append(send)
        draftVersion = nil
        phase = .providerRunning
        appendEvent(
            .providerRunStarted,
            summary: "已向 Provider 发送授权内容",
            reference: .providerRun(runID),
            now: now
        )
        let expectedPlanArtifactVersion: Int? = switch purpose {
        case .conversation: nil
        case .delegatedPlanning:
            (planArtifacts.last?.version ?? 0) + 1
        }
        return ZhulongProviderRequest(
            runID: runID,
            sessionID: id,
            providerIdentity: providerIdentity,
            payload: payload,
            purpose: purpose,
            expectedPlanArtifactVersion: expectedPlanArtifactVersion,
            startedAt: now
        )
    }

    public mutating func recordProviderResponse(
        _ response: ZhulongProviderResponse,
        runID: ZhulongProviderRunID,
        now: Date = Date()
    ) throws {
        guard phase == .providerRunning else {
            throw ZhulongSessionError.invalidTransition(from: phase, to: .draftReview)
        }
        let sendIndex = try activeSendIndex(runID: runID)
        guard case .conversation = providerSends[sendIndex].purpose else {
            throw ZhulongSessionError.invalidProviderResponse
        }
        guard let responseDraftVersion = response.draftVersion,
              responseDraftVersion > 0,
              response.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            throw ZhulongSessionError.invalidProviderResponse
        }
        try validateEventTime(now)

        providerSends[sendIndex] = providerSends[sendIndex].completing(with: response, at: now)
        entries.append(ZhulongSessionEntry(
            id: ZhulongSessionEntryID(),
            author: .zhulong,
            kind: .statement,
            content: response.content,
            createdAt: now,
            correctsEntryID: nil
        ))
        draftVersion = responseDraftVersion
        phase = .draftReview
        appendEvent(
            .draftReady,
            summary: "Provider 已返回可审查草稿",
            reference: .providerRun(runID),
            now: now
        )
    }

    public mutating func recordPlanningProviderResponse(
        _ response: ZhulongProviderResponse,
        runID: ZhulongProviderRunID,
        now: Date = Date()
    ) throws {
        guard phase == .providerRunning else {
            throw ZhulongSessionError.invalidTransition(from: phase, to: .draftReview)
        }
        let output = try ZhulongPlanningOutputParser().parse(response.content)
        let sendIndex = try activeSendIndex(runID: runID)
        guard case let .delegatedPlanning(contract) = providerSends[sendIndex].purpose,
              let brief = currentPlanningBrief,
              brief.id == contract.briefID,
              brief.version == contract.briefVersion
        else {
            throw ZhulongSessionError.invalidProviderResponse
        }
        switch output {
        case .decisionGate:
            guard response.draftVersion == nil else {
                throw ZhulongSessionError.invalidProviderResponse
            }
        case .planArtifact:
            let expectedVersion = (planArtifacts.last?.version ?? 0) + 1
            guard response.draftVersion == expectedVersion else {
                throw ZhulongSessionError.invalidDraftVersion
            }
        }
        try validatePlanningOutputDisclosure(
            output,
            brief: brief,
            contract: contract,
            payload: providerSends[sendIndex].payload
        )
        try validateEventTime(now)

        providerSends[sendIndex] = providerSends[sendIndex].completing(with: response, at: now)
        switch output {
        case let .decisionGate(gateDraft):
            let gate = ZhulongDecisionGate(
                id: ZhulongDecisionGateID(),
                sessionID: id,
                runID: runID,
                briefID: contract.briefID,
                briefVersion: contract.briefVersion,
                providerIdentity: providerSends[sendIndex].providerIdentity,
                contextVersion: providerSends[sendIndex].payload.contextVersion,
                openedAt: now,
                draft: gateDraft
            )
            decisionGates.append(gate)
            draftVersion = nil
            phase = .decisionGate
            appendEvent(
                .planningDecisionGateOpened,
                summary: "规划运行已停在用户决策门",
                reference: .decisionGate(gate.id),
                now: now
            )
        case let .planArtifact(proposal):
            guard let version = response.draftVersion else {
                throw ZhulongSessionError.invalidDraftVersion
            }
            let planArtifact = ZhulongPlanArtifact(
                id: ZhulongPlanArtifactID(),
                sessionID: id,
                runID: runID,
                briefID: contract.briefID,
                briefVersion: contract.briefVersion,
                providerIdentity: providerSends[sendIndex].providerIdentity,
                contextVersion: providerSends[sendIndex].payload.contextVersion,
                version: version,
                createdAt: now,
                proposal: proposal
            )
            planArtifacts.append(planArtifact)
            draftVersion = version
            phase = .draftReview
            appendEvent(
                .draftReady,
                summary: "Provider 已返回可审查结构化计划产物",
                reference: .planArtifact(planArtifact.id),
                now: now
            )
        }
    }

    private func validatePlanningOutputDisclosure(
        _ output: ZhulongPlanningOutputDraft,
        brief: ZhulongPlanningBrief,
        contract: ZhulongPlanningRunContract,
        payload: ZhulongProviderPayload
    ) throws {
        guard case let .planArtifact(proposal) = output else { return }
        guard proposal.isBound(to: brief, contract: contract, payload: payload) else {
            throw ZhulongPlanningOutputError.explanationOutsidePlanningContract
        }
    }

    @discardableResult
    public mutating func resolveDecisionGate(
        _ gateID: ZhulongDecisionGateID,
        selectedOptionID: String,
        supplementalDecision: String? = nil,
        now: Date = Date()
    ) throws -> ZhulongDecisionGateResolution {
        guard phase == .decisionGate,
              let gate = currentDecisionGate,
              gate.id == gateID,
              let option = gate.draft.options.first(where: { $0.id == selectedOptionID })
        else {
            throw ZhulongSessionError.invalidProviderResponse
        }
        let supplement = supplementalDecision?.trimmingCharacters(in: .whitespacesAndNewlines)
        let decisionContent = if let supplement, supplement.isEmpty == false {
            "\(option.title)：\(supplement)"
        } else {
            option.title
        }
        let entry = try appendDecisionGateResolutionEntry(
            author: .user,
            content: decisionContent,
            now: now
        )
        let resolvedAt = Date(
            timeIntervalSinceReferenceDate: now.timeIntervalSinceReferenceDate.nextUp
        )
        let resolution = ZhulongDecisionGateResolution(
            gateID: gate.id,
            selectedOptionID: option.id,
            decisionEntryID: entry.id,
            resolvedAt: resolvedAt
        )
        decisionGateResolutions.append(resolution)
        phase = .readyForProvider
        appendEvent(
            .planningDecisionGateResolved,
            summary: "用户已处置规划决策门，必须修订简报后重新委托",
            reference: .decisionGate(gate.id),
            now: resolvedAt
        )
        return resolution
    }

    mutating func leaveDecisionGateAfterSourceInvalidation() {
        if phase == .decisionGate {
            phase = .readyForProvider
        }
    }

    public mutating func recordProviderFailure(
        _ failure: ZhulongProviderFailure,
        runID: ZhulongProviderRunID,
        now: Date = Date()
    ) throws {
        guard phase == .providerRunning else {
            throw ZhulongSessionError.invalidTransition(from: phase, to: .readyForProvider)
        }
        guard failure.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              failure.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            throw ZhulongSessionError.invalidProviderFailure
        }
        try validateEventTime(now)
        let sendIndex = try activeSendIndex(runID: runID)

        providerSends[sendIndex] = providerSends[sendIndex].failing(with: failure, at: now)
        phase = .readyForProvider
        appendEvent(
            .providerRunFailed,
            summary: "Provider 请求失败",
            reference: .providerRun(runID),
            now: now
        )
    }

    public mutating func recoverInterruptedProviderRun(now: Date = Date()) throws {
        guard phase == .providerRunning,
              let runID = providerSends.last?.runID,
              providerSends.last?.status == .running
        else {
            throw ZhulongSessionError.noInterruptedProviderRun
        }
        try recordProviderFailure(
            ZhulongProviderFailure(
                code: "provider_run_interrupted",
                message: "上次 Provider 请求因应用中断而停止"
            ),
            runID: runID,
            now: now
        )
    }

    mutating func appendEvent(
        _ kind: ZhulongSessionEventKind,
        summary: String,
        reference: ZhulongSessionEventReference? = nil,
        now: Date
    ) {
        events.append(
            ZhulongSessionEvent(
                sequence: UInt64(events.count + 1),
                kind: kind,
                occurredAt: now,
                summary: summary,
                reference: reference
            )
        )
    }

    func validateActivityTime(_ now: Date) throws {
        guard now.timeIntervalSinceReferenceDate.isFinite,
              now > latestActivityAt
        else {
            throw ZhulongSessionError.nonMonotonicEventTime
        }
    }

    private func validateEventTime(_ now: Date) throws {
        try validateActivityTime(now)
    }

    private func activeSendIndex(runID: ZhulongProviderRunID) throws -> Int {
        guard let index = providerSends.indices.last,
              providerSends[index].runID == runID,
              providerSends[index].status == .running
        else {
            throw ZhulongSessionError.providerRunMismatch
        }
        return index
    }
}
