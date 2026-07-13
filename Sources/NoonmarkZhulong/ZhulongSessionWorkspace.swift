import Foundation

public struct ZhulongSessionEntryID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public enum ZhulongSessionEntryAuthor: String, Codable, Equatable, Sendable {
    case user
    case zhulong
}

public enum ZhulongSessionEntryKind: String, Codable, Equatable, Sendable {
    case statement
    case question
    case answer
    case decision
    case correction
}

public struct ZhulongSessionEntry: Codable, Equatable, Sendable {
    public let id: ZhulongSessionEntryID
    public let author: ZhulongSessionEntryAuthor
    public let kind: ZhulongSessionEntryKind
    public let content: String
    public let createdAt: Date
    public let correctsEntryID: ZhulongSessionEntryID?
}

public enum ZhulongWorkspaceStatus: String, Codable, Equatable, Sendable {
    case active
    case paused
    case archived
}

public enum ZhulongSessionEventReference: Codable, Equatable, Sendable {
    case providerRun(ZhulongProviderRunID)
    case sessionEntry(ZhulongSessionEntryID)
    case planningBrief(ZhulongPlanningBriefID)
    case planningDelegation(ZhulongPlanningDelegationID)
    case decisionGate(ZhulongDecisionGateID)
    case planArtifact(ZhulongPlanArtifactID)
    case todoDiff(ZhulongTodoDiffID)
    case todoWriteAuthorization(ZhulongTodoWriteAuthorizationID)
    case todoApplyReceipt(ZhulongTodoApplyReceiptID)
    case dailyClose(ZhulongDailyCloseID)
    case unfinishedCauseHypothesis(ZhulongUnfinishedCauseHypothesisID)
    case unfinishedCauseResolution(ZhulongUnfinishedCauseResolutionID)
    case dailyReviewDraft(ZhulongDailyReviewDraftID)
    case dailyReviewAuthorization(ZhulongDailyReviewAuthorizationID)
    case dailyReviewReceipt(ZhulongDailyReviewReceiptID)
}

public extension ZhulongSession {
    @discardableResult
    mutating func appendEntry(
        author: ZhulongSessionEntryAuthor,
        kind: ZhulongSessionEntryKind,
        content: String,
        now: Date = Date()
    ) throws -> ZhulongSessionEntry {
        guard workspaceStatus == .active else {
            throw ZhulongSessionError.workspaceInactive
        }
        guard kind != .correction else {
            throw ZhulongSessionError.correctionRequiresTarget
        }
        guard phase != .decisionGate || kind != .decision else {
            throw ZhulongSessionError.decisionGateRequiresAtomicResolution
        }
        return try appendEntryUnchecked(author: author, kind: kind, content: content, now: now)
    }

    internal mutating func appendDecisionGateResolutionEntry(
        author: ZhulongSessionEntryAuthor,
        content: String,
        now: Date
    ) throws -> ZhulongSessionEntry {
        try appendEntryUnchecked(author: author, kind: .decision, content: content, now: now)
    }

    private mutating func appendEntryUnchecked(
        author: ZhulongSessionEntryAuthor,
        kind: ZhulongSessionEntryKind,
        content: String,
        now: Date
    ) throws -> ZhulongSessionEntry {
        let normalized = try normalizedEntryContent(content)
        try validateActivityTime(now)
        let entry = ZhulongSessionEntry(
            id: ZhulongSessionEntryID(),
            author: author,
            kind: kind,
            content: normalized,
            createdAt: now,
            correctsEntryID: nil
        )
        entries.append(entry)
        if kind == .decision {
            appendEvent(
                .sessionDecisionRecorded,
                summary: "已记录用户决定",
                reference: .sessionEntry(entry.id),
                now: now
            )
        }
        return entry
    }

    @discardableResult
    mutating func correctEntry(
        _ targetID: ZhulongSessionEntryID,
        author: ZhulongSessionEntryAuthor,
        replacementContent: String,
        now: Date = Date()
    ) throws -> ZhulongSessionEntry {
        guard workspaceStatus == .active else {
            throw ZhulongSessionError.workspaceInactive
        }
        guard let target = entries.first(where: { $0.id == targetID }) else {
            throw ZhulongSessionError.missingCorrectionTarget
        }
        if phase == .providerRunning && canCorrectDuringDelegatedPlanning(targetID) == false {
            throw ZhulongSessionError.providerRunStillActive
        }
        guard target.correctsEntryID == nil else {
            throw ZhulongSessionError.correctionTargetIsCorrection
        }
        let normalized = try normalizedEntryContent(replacementContent)
        try validateActivityTime(now)
        let correction = ZhulongSessionEntry(
            id: ZhulongSessionEntryID(),
            author: author,
            kind: .correction,
            content: normalized,
            createdAt: now,
            correctsEntryID: targetID
        )
        entries.append(correction)
        appendEvent(
            .sessionCorrected,
            summary: "已追加会话更正",
            reference: .sessionEntry(correction.id),
            now: now
        )
        invalidatePlanningDerivedFromSource(targetID, after: now)
        return correction
    }

    private func canCorrectDuringDelegatedPlanning(_ targetID: ZhulongSessionEntryID) -> Bool {
        guard let send = providerSends.last,
              send.status == .running,
              let contract = send.planningContract,
              let brief = currentPlanningBrief,
              brief.id == contract.briefID,
              brief.version == contract.briefVersion
        else { return false }
        return brief.sourceEntryIDs.contains(targetID) == false
    }

    func effectiveContent(for entryID: ZhulongSessionEntryID) -> String? {
        guard let original = entries.first(where: { $0.id == entryID }) else { return nil }
        return entries.last(where: { $0.correctsEntryID == entryID })?.content ?? original.content
    }

    mutating func pause(now: Date = Date()) throws {
        guard workspaceStatus == .active else {
            throw ZhulongSessionError.invalidWorkspaceTransition
        }
        guard phase != .providerRunning else {
            throw ZhulongSessionError.providerRunStillActive
        }
        try validateActivityTime(now)
        workspaceStatus = .paused
        appendEvent(.sessionPaused, summary: "会话已暂停", now: now)
    }

    mutating func resume(now: Date = Date()) throws {
        guard workspaceStatus == .paused else {
            throw ZhulongSessionError.invalidWorkspaceTransition
        }
        try validateActivityTime(now)
        workspaceStatus = .active
        appendEvent(.sessionResumed, summary: "会话已恢复", now: now)
    }

    mutating func archive(now: Date = Date()) throws {
        guard workspaceStatus != .archived else {
            throw ZhulongSessionError.invalidWorkspaceTransition
        }
        guard phase != .providerRunning else {
            throw ZhulongSessionError.providerRunStillActive
        }
        try validateActivityTime(now)
        workspaceStatus = .archived
        appendEvent(.sessionArchived, summary: "会话已归档", now: now)
    }

    private func normalizedEntryContent(_ content: String) throws -> String {
        let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else {
            throw ZhulongSessionError.emptySessionEntry
        }
        return normalized
    }

    private mutating func invalidatePlanningDerivedFromSource(
        _ sourceEntryID: ZhulongSessionEntryID,
        after correctionDate: Date
    ) {
        guard let brief = currentPlanningBrief,
              brief.sourceEntryIDs.contains(sourceEntryID)
        else { return }
        let briefInvalidatedAt = Date(
            timeIntervalSinceReferenceDate: correctionDate.timeIntervalSinceReferenceDate.nextUp
        )
        let invalidatesOpenDecisionGate = phase == .decisionGate &&
            currentDecisionGate?.briefID == brief.id
        let activeDelegation = activePlanningDelegation
        planningBriefInvalidations.append(ZhulongPlanningBriefInvalidation(
            briefID: brief.id,
            sourceEntryID: sourceEntryID,
            invalidatedAt: briefInvalidatedAt
        ))
        appendEvent(
            .planningBriefInvalidated,
            summary: "来源更正已使规划简报失效",
            reference: .planningBrief(brief.id),
            now: briefInvalidatedAt
        )
        let lastInvalidatedAt = invalidatePlanningRuns(
            derivedFrom: brief.id,
            reason: .sourceCorrected,
            sourceEntryID: sourceEntryID,
            after: briefInvalidatedAt
        )
        if invalidatesOpenDecisionGate {
            leaveDecisionGateAfterSourceInvalidation()
        }
        if let activeDelegation {
            let delegationInvalidatedAt = Date(
                timeIntervalSinceReferenceDate: lastInvalidatedAt.timeIntervalSinceReferenceDate.nextUp
            )
            planningDelegationInvalidations.append(ZhulongPlanningDelegationInvalidation(
                delegationID: activeDelegation.id,
                invalidatedAt: delegationInvalidatedAt,
                reason: .briefSourceCorrected
            ))
            appendEvent(
                .planningDelegationInvalidated,
                summary: "来源更正已使规划委托失效",
                reference: .planningDelegation(activeDelegation.id),
                now: delegationInvalidatedAt
            )
        }
    }
}
