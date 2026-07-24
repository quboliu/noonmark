import Foundation

public struct ZhulongPlanningBriefID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct ZhulongPlanningDelegationID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public enum ZhulongPlanningActivity: String, Codable, CaseIterable, Hashable, Sendable {
    case taskDecomposition
    case sequencing
    case riskReview
    case initialScheduling
    case dependencyMapping
    case rollingTriggers
}

public enum ZhulongPlanningBriefError: Error, Equatable, Sendable {
    case emptyGoal
    case emptySuccessCriteria
    case emptyDelegatedActivities
    case emptyListItem
    case emptyOpenQuestion
    case emptyDataScopes
    case emptySourceEntries
    case scopeOutsideSessionProposal
    case sourceEntryOutsideSession
    case duplicateBriefContent
    case briefNotCurrent
    case briefAlreadyReviewed
    case briefNotReviewed
    case blockingQuestionsRemain
    case scopeNotAuthorized
    case activeDelegationAlreadyExists
    case delegationNotActive
    case decisionGateUnresolved
    case briefRevisionRequired
    case decisionGateResolutionMissingFromRevision
}

public struct ZhulongPlanningOpenQuestion: Codable, Equatable, Sendable {
    public let content: String
    public let isBlocking: Bool

    public init(content: String, isBlocking: Bool) throws {
        let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else {
            throw ZhulongPlanningBriefError.emptyOpenQuestion
        }
        self.content = normalized
        self.isBlocking = isBlocking
    }
}

public struct ZhulongPlanningBriefDraft: Codable, Equatable, Sendable {
    public let goal: String
    public let successCriteria: [String]
    public let hardConstraints: [String]
    public let userDecisions: [String]
    public let delegatedActivities: Set<ZhulongPlanningActivity>
    public let assumptions: [String]
    public let openQuestions: [ZhulongPlanningOpenQuestion]
    public let dataScopes: Set<ZhulongDataScope>
    public let sourceEntryIDs: Set<ZhulongSessionEntryID>

    public init(
        goal: String,
        successCriteria: [String],
        hardConstraints: [String],
        userDecisions: [String],
        delegatedActivities: Set<ZhulongPlanningActivity>,
        assumptions: [String],
        openQuestions: [ZhulongPlanningOpenQuestion],
        dataScopes: Set<ZhulongDataScope>,
        sourceEntryIDs: Set<ZhulongSessionEntryID>
    ) throws {
        let normalizedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedGoal.isEmpty == false else {
            throw ZhulongPlanningBriefError.emptyGoal
        }
        guard successCriteria.isEmpty == false else {
            throw ZhulongPlanningBriefError.emptySuccessCriteria
        }
        guard delegatedActivities.isEmpty == false else {
            throw ZhulongPlanningBriefError.emptyDelegatedActivities
        }
        guard dataScopes.isEmpty == false else {
            throw ZhulongPlanningBriefError.emptyDataScopes
        }
        guard sourceEntryIDs.isEmpty == false else {
            throw ZhulongPlanningBriefError.emptySourceEntries
        }
        guard openQuestions.allSatisfy({ question in
            let normalized = question.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty == false && normalized == question.content
        }) else {
            throw ZhulongPlanningBriefError.emptyOpenQuestion
        }

        self.goal = normalizedGoal
        self.successCriteria = try Self.normalize(successCriteria)
        self.hardConstraints = try Self.normalize(hardConstraints)
        self.userDecisions = try Self.normalize(userDecisions)
        self.delegatedActivities = delegatedActivities
        self.assumptions = try Self.normalize(assumptions)
        self.openQuestions = openQuestions
        self.dataScopes = dataScopes
        self.sourceEntryIDs = sourceEntryIDs
    }

    public func replacingGoal(_ goal: String) throws -> Self {
        try Self(
            goal: goal,
            successCriteria: successCriteria,
            hardConstraints: hardConstraints,
            userDecisions: userDecisions,
            delegatedActivities: delegatedActivities,
            assumptions: assumptions,
            openQuestions: openQuestions,
            dataScopes: dataScopes,
            sourceEntryIDs: sourceEntryIDs
        )
    }

    private static func normalize(_ values: [String]) throws -> [String] {
        try values.map { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.isEmpty == false else {
                throw ZhulongPlanningBriefError.emptyListItem
            }
            return normalized
        }
    }
}

public struct ZhulongPlanningBrief: Codable, Equatable, Sendable {
    public let id: ZhulongPlanningBriefID
    public let version: Int
    public let goal: String
    public let successCriteria: [String]
    public let hardConstraints: [String]
    public let userDecisions: [String]
    public let delegatedActivities: Set<ZhulongPlanningActivity>
    public let assumptions: [String]
    public let openQuestions: [ZhulongPlanningOpenQuestion]
    public let dataScopes: Set<ZhulongDataScope>
    public let sourceEntryIDs: Set<ZhulongSessionEntryID>
    public let publishedAt: Date

    fileprivate init(draft: ZhulongPlanningBriefDraft, version: Int, publishedAt: Date) {
        id = ZhulongPlanningBriefID()
        self.version = version
        goal = draft.goal
        successCriteria = draft.successCriteria
        hardConstraints = draft.hardConstraints
        userDecisions = draft.userDecisions
        delegatedActivities = draft.delegatedActivities
        assumptions = draft.assumptions
        openQuestions = draft.openQuestions
        dataScopes = draft.dataScopes
        sourceEntryIDs = draft.sourceEntryIDs
        self.publishedAt = publishedAt
    }

    fileprivate func hasSameContent(as draft: ZhulongPlanningBriefDraft) -> Bool {
        goal == draft.goal &&
            successCriteria == draft.successCriteria &&
            hardConstraints == draft.hardConstraints &&
            userDecisions == draft.userDecisions &&
            delegatedActivities == draft.delegatedActivities &&
            assumptions == draft.assumptions &&
            openQuestions == draft.openQuestions &&
            dataScopes == draft.dataScopes &&
            sourceEntryIDs == draft.sourceEntryIDs
    }
}

public struct ZhulongPlanningBriefReview: Codable, Equatable, Sendable {
    public let briefID: ZhulongPlanningBriefID
    public let reviewedAt: Date
}

public struct ZhulongPlanningBriefInvalidation: Codable, Equatable, Sendable {
    public let briefID: ZhulongPlanningBriefID
    public let sourceEntryID: ZhulongSessionEntryID
    public let invalidatedAt: Date
}

public enum ZhulongPlanningRunInvalidationReason: String, Codable, Equatable, Sendable {
    case briefRevised
    case sourceCorrected
}

public struct ZhulongPlanningRunInvalidation: Codable, Equatable, Sendable {
    public let runID: ZhulongProviderRunID
    public let briefID: ZhulongPlanningBriefID
    public let sourceEntryID: ZhulongSessionEntryID?
    public let invalidatedAt: Date
    public let reason: ZhulongPlanningRunInvalidationReason
}

public struct ZhulongPlanningDelegation: Codable, Equatable, Sendable {
    public let id: ZhulongPlanningDelegationID
    public let sessionID: ZhulongSessionID
    public let briefID: ZhulongPlanningBriefID
    public let briefVersion: Int
    public let providerIdentity: ZhulongProviderConfigurationIdentity
    public let dataScopes: Set<ZhulongDataScope>
    public let activities: Set<ZhulongPlanningActivity>
    public let grantedAt: Date
}

public struct ZhulongPlanningDelegationConsumption: Codable, Equatable, Sendable {
    public let delegationID: ZhulongPlanningDelegationID
    public let consumedAt: Date
}

public enum ZhulongDelegationInvalidationReason: String, Codable, Equatable, Sendable {
    case briefRevised
    case briefSourceCorrected
    case authorizationChanged
}

public struct ZhulongPlanningDelegationInvalidation: Codable, Equatable, Sendable {
    public let delegationID: ZhulongPlanningDelegationID
    public let invalidatedAt: Date
    public let reason: ZhulongDelegationInvalidationReason
}

public extension ZhulongSession {
    var effectiveDraftVersion: Int? {
        guard phase == .draftReview,
              let draftVersion,
              let send = providerSends.last,
              send.status == .succeeded
        else { return nil }
        guard let contract = send.planningContract else { return draftVersion }
        guard currentPlanningBrief?.id == contract.briefID,
              currentPlanningBrief?.version == contract.briefVersion,
              planningRunInvalidations.contains(where: { $0.runID == send.runID }) == false
        else { return nil }
        return draftVersion
    }

    var currentPlanningBrief: ZhulongPlanningBrief? {
        guard let brief = planningBriefs.last,
              planningBriefInvalidations.contains(where: { $0.briefID == brief.id }) == false
        else { return nil }
        return brief
    }

    var reviewedPlanningBrief: ZhulongPlanningBrief? {
        guard let brief = currentPlanningBrief,
              planningBriefReviews.contains(where: { $0.briefID == brief.id })
        else { return nil }
        return brief
    }

    var activePlanningDelegation: ZhulongPlanningDelegation? {
        guard let brief = currentPlanningBrief,
              let delegation = planningDelegations.last(where: { $0.briefID == brief.id }),
              planningDelegationConsumptions.contains(where: { $0.delegationID == delegation.id }) == false,
              planningDelegationInvalidations.contains(where: { $0.delegationID == delegation.id }) == false
        else { return nil }
        return delegation
    }

    @discardableResult
    mutating func publishPlanningBrief(
        _ draft: ZhulongPlanningBriefDraft,
        now: Date = Date()
    ) throws -> ZhulongPlanningBrief {
        guard workspaceStatus == .active else {
            throw ZhulongSessionError.workspaceInactive
        }
        guard phase != .providerRunning else {
            throw ZhulongSessionError.providerRunStillActive
        }
        try validateDecisionGateAllowsBriefRevision(draft)
        guard draft.dataScopes.isSubset(of: proposedScopes) else {
            throw ZhulongPlanningBriefError.scopeOutsideSessionProposal
        }
        let sourceEntries = entries.filter { draft.sourceEntryIDs.contains($0.id) }
        guard sourceEntries.count == draft.sourceEntryIDs.count,
              sourceEntries.allSatisfy({ $0.correctsEntryID == nil })
        else {
            throw ZhulongPlanningBriefError.sourceEntryOutsideSession
        }
        guard currentPlanningBrief?.hasSameContent(as: draft) != true else {
            throw ZhulongPlanningBriefError.duplicateBriefContent
        }
        try validateActivityTime(now)

        let invalidatedDelegation = activePlanningDelegation
        let previousBriefID = currentPlanningBrief?.id
        let brief = ZhulongPlanningBrief(
            draft: draft,
            version: (planningBriefs.last?.version ?? 0) + 1,
            publishedAt: now
        )
        planningBriefs.append(brief)
        appendEvent(
            .planningBriefPublished,
            summary: "已发布规划简报 v\(brief.version)",
            reference: .planningBrief(brief.id),
            now: now
        )
        var lastInvalidatedAt = now
        if let previousBriefID {
            lastInvalidatedAt = invalidatePlanningRuns(
                derivedFrom: previousBriefID,
                reason: .briefRevised,
                sourceEntryID: nil,
                after: lastInvalidatedAt
            )
        }
        if let invalidatedDelegation {
            let invalidatedAt = strictlyLater(than: lastInvalidatedAt)
            planningDelegationInvalidations.append(ZhulongPlanningDelegationInvalidation(
                delegationID: invalidatedDelegation.id,
                invalidatedAt: invalidatedAt,
                reason: .briefRevised
            ))
            appendEvent(
                .planningDelegationInvalidated,
                summary: "简报修订已使旧规划委托失效",
                reference: .planningDelegation(invalidatedDelegation.id),
                now: invalidatedAt
            )
        }
        return brief
    }

    private func validateDecisionGateAllowsBriefRevision(
        _ draft: ZhulongPlanningBriefDraft
    ) throws {
        guard phase != .decisionGate else {
            throw ZhulongPlanningBriefError.decisionGateUnresolved
        }
        guard let resolution = latestDecisionGateResolutionRequiringBriefRevision else {
            return
        }
        guard draft.sourceEntryIDs.contains(resolution.decisionEntryID),
              let decision = effectiveContent(for: resolution.decisionEntryID),
              draft.userDecisions.contains(decision)
        else {
            throw ZhulongPlanningBriefError.decisionGateResolutionMissingFromRevision
        }
    }

    @discardableResult
    mutating func invalidatePlanningRuns(
        derivedFrom briefID: ZhulongPlanningBriefID,
        reason: ZhulongPlanningRunInvalidationReason,
        sourceEntryID: ZhulongSessionEntryID?,
        after date: Date
    ) -> Date {
        let derivedRuns = providerSends.filter { send in
            guard let contract = send.planningContract else { return false }
            return contract.briefID == briefID &&
                planningRunInvalidations.contains(where: { $0.runID == send.runID }) == false
        }
        var lastInvalidatedAt = date
        for run in derivedRuns {
            let invalidatedAt = strictlyLater(than: lastInvalidatedAt)
            planningRunInvalidations.append(ZhulongPlanningRunInvalidation(
                runID: run.runID,
                briefID: briefID,
                sourceEntryID: sourceEntryID,
                invalidatedAt: invalidatedAt,
                reason: reason
            ))
            appendEvent(
                .planningRunInvalidated,
                summary: reason == .briefRevised
                    ? "简报修订已使旧规划运行与草稿失效"
                    : "来源更正已使规划运行与草稿失效",
                reference: .providerRun(run.runID),
                now: invalidatedAt
            )
            lastInvalidatedAt = invalidatedAt
        }
        return lastInvalidatedAt
    }

    mutating func reviewPlanningBrief(
        _ briefID: ZhulongPlanningBriefID,
        now: Date = Date()
    ) throws {
        guard workspaceStatus == .active else {
            throw ZhulongSessionError.workspaceInactive
        }
        guard phase != .providerRunning else {
            throw ZhulongSessionError.providerRunStillActive
        }
        guard currentPlanningBrief?.id == briefID else {
            throw ZhulongPlanningBriefError.briefNotCurrent
        }
        guard planningBriefReviews.contains(where: { $0.briefID == briefID }) == false else {
            throw ZhulongPlanningBriefError.briefAlreadyReviewed
        }
        try validateActivityTime(now)
        planningBriefReviews.append(ZhulongPlanningBriefReview(briefID: briefID, reviewedAt: now))
        appendEvent(
            .planningBriefReviewed,
            summary: "用户已审查规划简报",
            reference: .planningBrief(briefID),
            now: now
        )
    }

    @discardableResult
    mutating func delegatePlanning(
        for briefID: ZhulongPlanningBriefID,
        now: Date = Date()
    ) throws -> ZhulongPlanningDelegation {
        guard workspaceStatus == .active else {
            throw ZhulongSessionError.workspaceInactive
        }
        guard phase != .providerRunning else {
            throw ZhulongSessionError.providerRunStillActive
        }
        try validateDecisionGateAllowsDelegation()
        guard let brief = currentPlanningBrief, brief.id == briefID else {
            throw ZhulongPlanningBriefError.briefNotCurrent
        }
        guard reviewedPlanningBrief?.id == briefID else {
            throw ZhulongPlanningBriefError.briefNotReviewed
        }
        guard brief.openQuestions.contains(where: \.isBlocking) == false else {
            throw ZhulongPlanningBriefError.blockingQuestionsRemain
        }
        guard activePlanningDelegation == nil else {
            throw ZhulongPlanningBriefError.activeDelegationAlreadyExists
        }
        guard let authorization else {
            throw ZhulongPlanningBriefError.scopeNotAuthorized
        }
        guard brief.dataScopes.isSubset(of: authorization.scopes) else {
            throw ZhulongPlanningBriefError.scopeNotAuthorized
        }
        try validateActivityTime(now)

        let delegation = ZhulongPlanningDelegation(
            id: ZhulongPlanningDelegationID(),
            sessionID: id,
            briefID: brief.id,
            briefVersion: brief.version,
            providerIdentity: authorization.providerIdentity,
            dataScopes: brief.dataScopes,
            activities: brief.delegatedActivities,
            grantedAt: now
        )
        planningDelegations.append(delegation)
        appendEvent(
            .planningDelegationGranted,
            summary: "已建立单次规划委托，不包含 Todo 写入",
            reference: .planningDelegation(delegation.id),
            now: now
        )
        return delegation
    }

    private func validateDecisionGateAllowsDelegation() throws {
        guard currentDecisionGate == nil else {
            throw ZhulongPlanningBriefError.decisionGateUnresolved
        }
        guard currentBriefRequiresDecisionGateRevision == false else {
            throw ZhulongPlanningBriefError.briefRevisionRequired
        }
    }

    private func strictlyLater(than date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.nextUp)
    }
}
