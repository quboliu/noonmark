import Foundation
import SuntraceCore

public struct ZhulongDailyCloseID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct ZhulongUnfinishedCauseHypothesisID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct ZhulongUnfinishedCauseResolutionID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct ZhulongDailyReviewDraftID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct ZhulongDailyReviewAuthorizationID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct ZhulongDailyReviewReceiptID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct ZhulongDailyCloseCounts: Codable, Equatable, Sendable {
    public let total: Int
    public let completed: Int
    public let unfinished: Int
    public let continued: Int
    public let changed: Int
    public let returnedToPool: Int
    public let abandoned: Int
    public let pending: Int
}

public struct ZhulongDailyTraceEvidence: Codable, Equatable, Sendable {
    public let traceID: DayTraceID
    public let chainID: TaskChainID
    public let title: String
    public let status: TraceStatus
    public let continuationSequence: Int
    public let progressPercent: Int
    public let subtaskCount: Int
    public let completedSubtaskCount: Int
}

public enum ZhulongDailyCloseError: Error, Equatable, Sendable {
    case invalidTime
    case invalidHypothesis
    case invalidResolution
    case invalidReviewDraft
    case staleEvidence
    case authorizationMismatch
    case authorizationConsumed
    case digestFailure
}

public struct ZhulongDailyCloseSnapshot: Codable, Equatable, Sendable {
    public let id: ZhulongDailyCloseID
    public let sessionID: ZhulongSessionID
    public let date: LocalDate
    public let capturedAt: Date
    public let dayLockedAt: Date?
    public let counts: ZhulongDailyCloseCounts
    public let traces: [ZhulongDailyTraceEvidence]
    public let evidenceDigest: String

    public init(
        id: ZhulongDailyCloseID = ZhulongDailyCloseID(),
        sessionID: ZhulongSessionID,
        date: LocalDate,
        engine: SuntraceEngine,
        capturedAt: Date = Date()
    ) throws {
        guard capturedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ZhulongDailyCloseError.invalidTime
        }
        self.id = id
        self.sessionID = sessionID
        self.date = date
        self.capturedAt = capturedAt
        dayLockedAt = engine.days[date]?.lockedAt
        let stats = engine.dailyReviewStats(date: date)
        let dayTraces = engine.traces.values
            .filter { $0.date == date }
            .sorted { $0.id.description < $1.id.description }
        counts = ZhulongDailyCloseCounts(
            total: stats.total,
            completed: stats.completed,
            unfinished: stats.unfinished,
            continued: stats.continued,
            changed: stats.changed,
            returnedToPool: stats.returnedToPool,
            abandoned: stats.abandoned,
            pending: dayTraces.filter { $0.status == .pending }.count
        )
        traces = dayTraces.map { trace in
            let subtasks = engine.subtasks.values.filter { $0.traceID == trace.id }
            return ZhulongDailyTraceEvidence(
                traceID: trace.id,
                chainID: trace.chainID,
                title: engine.definitions[trace.definitionID]?.title ?? "",
                status: trace.status,
                continuationSequence: trace.continuationSeq,
                progressPercent: engine.traceProgress(for: trace.id).percent,
                subtaskCount: subtasks.count,
                completedSubtaskCount: subtasks.filter { $0.status == .completed }.count
            )
        }
        evidenceDigest = try Self.digest(
            date: date,
            dayLockedAt: dayLockedAt,
            counts: counts,
            traces: traces
        )
    }

    func matches(_ engine: SuntraceEngine) -> Bool {
        guard let current = try? ZhulongDailyCloseSnapshot(
            id: id,
            sessionID: sessionID,
            date: date,
            engine: engine,
            capturedAt: capturedAt
        ) else { return false }
        return current.evidenceDigest == evidenceDigest
    }

    private static func digest(
        date: LocalDate,
        dayLockedAt: Date?,
        counts: ZhulongDailyCloseCounts,
        traces: [ZhulongDailyTraceEvidence]
    ) throws -> String {
        struct Evidence: Encodable {
            let date: LocalDate
            let dayLockedAt: Date?
            let counts: ZhulongDailyCloseCounts
            let traces: [ZhulongDailyTraceEvidence]
        }
        do {
            return try ZhulongTodoDigest.value(Evidence(
                date: date,
                dayLockedAt: dayLockedAt,
                counts: counts,
                traces: traces
            ))
        } catch {
            throw ZhulongDailyCloseError.digestFailure
        }
    }
}

public struct ZhulongUnfinishedCauseHypothesis: Codable, Equatable, Sendable {
    public let id: ZhulongUnfinishedCauseHypothesisID
    public let dailyCloseID: ZhulongDailyCloseID
    public let content: String
    public let evidenceTraceIDs: [DayTraceID]
    public let confidence: Double
    public let counterexamples: [String]
    public let createdAt: Date

    public init(
        id: ZhulongUnfinishedCauseHypothesisID = ZhulongUnfinishedCauseHypothesisID(),
        dailyCloseID: ZhulongDailyCloseID,
        content: String,
        evidenceTraceIDs: [DayTraceID],
        confidence: Double,
        counterexamples: [String],
        createdAt: Date = Date()
    ) throws {
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCounterexamples = counterexamples.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard normalizedContent.isEmpty == false,
              evidenceTraceIDs.isEmpty == false,
              Set(evidenceTraceIDs).count == evidenceTraceIDs.count,
              confidence.isFinite,
              confidence >= 0,
              confidence <= 1,
              normalizedCounterexamples.isEmpty == false,
              normalizedCounterexamples.allSatisfy({ $0.isEmpty == false }),
              createdAt.timeIntervalSinceReferenceDate.isFinite
        else {
            throw ZhulongDailyCloseError.invalidHypothesis
        }
        self.id = id
        self.dailyCloseID = dailyCloseID
        self.content = normalizedContent
        self.evidenceTraceIDs = evidenceTraceIDs
        self.confidence = confidence
        self.counterexamples = normalizedCounterexamples
        self.createdAt = createdAt
    }
}

public enum ZhulongUnfinishedCauseDecision: Codable, Equatable, Sendable {
    case confirmed(content: String)
    case rejected
}

public struct ZhulongUnfinishedCauseResolution: Codable, Equatable, Sendable {
    public let id: ZhulongUnfinishedCauseResolutionID
    public let hypothesisID: ZhulongUnfinishedCauseHypothesisID
    public let decision: ZhulongUnfinishedCauseDecision
    public let resolvedAt: Date

    public init(
        id: ZhulongUnfinishedCauseResolutionID = ZhulongUnfinishedCauseResolutionID(),
        hypothesis: ZhulongUnfinishedCauseHypothesis,
        decision: ZhulongUnfinishedCauseDecision,
        resolvedAt: Date = Date()
    ) throws {
        let hasInvalidConfirmedContent = switch decision {
        case let .confirmed(content):
            content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .rejected:
            false
        }
        if hasInvalidConfirmedContent {
            throw ZhulongDailyCloseError.invalidResolution
        }
        guard resolvedAt.timeIntervalSinceReferenceDate.isFinite,
              resolvedAt > hypothesis.createdAt
        else {
            throw ZhulongDailyCloseError.invalidResolution
        }
        self.id = id
        hypothesisID = hypothesis.id
        self.decision = decision
        self.resolvedAt = resolvedAt
    }
}

public struct ZhulongDailyReviewDraft: Codable, Equatable, Sendable {
    public let id: ZhulongDailyReviewDraftID
    public let dailyCloseID: ZhulongDailyCloseID
    public let date: LocalDate
    public let evidenceDigest: String
    public let summary: String?
    public let unfinishedReason: String?
    public let tomorrowNote: String?
    public let confirmedCauseResolutionIDs: [ZhulongUnfinishedCauseResolutionID]
    public let createdAt: Date

    public init(
        id: ZhulongDailyReviewDraftID = ZhulongDailyReviewDraftID(),
        snapshot: ZhulongDailyCloseSnapshot,
        summary: String?,
        tomorrowNote: String?,
        causeResolutions: [ZhulongUnfinishedCauseResolution],
        createdAt: Date = Date()
    ) throws {
        let normalizedSummary = Self.normalized(summary)
        let normalizedTomorrowNote = Self.normalized(tomorrowNote)
        let confirmed = causeResolutions.compactMap { resolution -> (ZhulongUnfinishedCauseResolutionID, String)? in
            guard case let .confirmed(content) = resolution.decision else { return nil }
            return (resolution.id, content.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard Set(causeResolutions.map(\.hypothesisID)).count == causeResolutions.count,
              confirmed.allSatisfy({ $0.1.isEmpty == false }),
              createdAt.timeIntervalSinceReferenceDate.isFinite,
              createdAt > snapshot.capturedAt,
              normalizedSummary != nil || normalizedTomorrowNote != nil || confirmed.isEmpty == false
        else {
            throw ZhulongDailyCloseError.invalidReviewDraft
        }
        self.id = id
        dailyCloseID = snapshot.id
        date = snapshot.date
        evidenceDigest = snapshot.evidenceDigest
        self.summary = normalizedSummary
        unfinishedReason = confirmed.isEmpty
            ? nil
            : confirmed.map(\.1).joined(separator: "；")
        self.tomorrowNote = normalizedTomorrowNote
        confirmedCauseResolutionIDs = confirmed.map(\.0)
        self.createdAt = createdAt
    }

    func integrityDigest() throws -> String {
        do {
            return try ZhulongTodoDigest.value(self)
        } catch {
            throw ZhulongDailyCloseError.digestFailure
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

public enum ZhulongDailyReviewAuthorizationStatus: Codable, Equatable, Sendable {
    case active
    case consumed(receiptID: ZhulongDailyReviewReceiptID, consumedAt: Date)
}

public struct ZhulongDailyReviewAuthorization: Codable, Equatable, Sendable {
    public let id: ZhulongDailyReviewAuthorizationID
    public let draftID: ZhulongDailyReviewDraftID
    public let draftDigest: String
    public let grantedAt: Date
    public private(set) var status: ZhulongDailyReviewAuthorizationStatus

    fileprivate init(draft: ZhulongDailyReviewDraft, draftDigest: String, grantedAt: Date) {
        id = ZhulongDailyReviewAuthorizationID()
        draftID = draft.id
        self.draftDigest = draftDigest
        self.grantedAt = grantedAt
        status = .active
    }

    fileprivate mutating func consume(
        receiptID: ZhulongDailyReviewReceiptID,
        at date: Date
    ) {
        status = .consumed(receiptID: receiptID, consumedAt: date)
    }
}

public struct ZhulongDailyReviewReceipt: Codable, Equatable, Sendable {
    public let id: ZhulongDailyReviewReceiptID
    public let authorizationID: ZhulongDailyReviewAuthorizationID
    public let draftID: ZhulongDailyReviewDraftID
    public let beforeSnapshotDigest: String
    public let afterSnapshotDigest: String
    public let appliedAt: Date
}

public struct ZhulongDailyReviewApplier: Sendable {
    public init() {}

    public func authorize(
        _ draft: ZhulongDailyReviewDraft,
        snapshot: ZhulongDailyCloseSnapshot,
        against engine: SuntraceEngine,
        now: Date = Date()
    ) throws -> ZhulongDailyReviewAuthorization {
        guard draft.dailyCloseID == snapshot.id,
              draft.evidenceDigest == snapshot.evidenceDigest,
              now.timeIntervalSinceReferenceDate.isFinite,
              now > draft.createdAt
        else {
            throw ZhulongDailyCloseError.authorizationMismatch
        }
        guard snapshot.matches(engine) else { throw ZhulongDailyCloseError.staleEvidence }
        return try ZhulongDailyReviewAuthorization(
            draft: draft,
            draftDigest: draft.integrityDigest(),
            grantedAt: now
        )
    }

    public func apply(
        _ draft: ZhulongDailyReviewDraft,
        snapshot: ZhulongDailyCloseSnapshot,
        authorization: inout ZhulongDailyReviewAuthorization,
        to engine: inout SuntraceEngine,
        now: Date = Date()
    ) throws -> ZhulongDailyReviewReceipt {
        guard authorization.status == .active else {
            throw ZhulongDailyCloseError.authorizationConsumed
        }
        guard now.timeIntervalSinceReferenceDate.isFinite,
              now > authorization.grantedAt,
              authorization.draftID == draft.id,
              authorization.draftDigest == (try? draft.integrityDigest()),
              draft.dailyCloseID == snapshot.id,
              draft.evidenceDigest == snapshot.evidenceDigest
        else {
            throw ZhulongDailyCloseError.authorizationMismatch
        }
        guard snapshot.matches(engine) else { throw ZhulongDailyCloseError.staleEvidence }
        let staged = try SuntraceEngine(snapshot: engine.snapshot())
        let before = try ZhulongTodoDigest.snapshot(staged.snapshot())
        staged.updateDailyReview(
            date: draft.date,
            summary: draft.summary,
            unfinishedReason: draft.unfinishedReason,
            tomorrowNote: draft.tomorrowNote,
            now: now
        )
        let after = try ZhulongTodoDigest.snapshot(staged.snapshot())
        let receiptID = ZhulongDailyReviewReceiptID()
        let receipt = ZhulongDailyReviewReceipt(
            id: receiptID,
            authorizationID: authorization.id,
            draftID: draft.id,
            beforeSnapshotDigest: before,
            afterSnapshotDigest: after,
            appliedAt: now
        )
        authorization.consume(receiptID: receiptID, at: now)
        engine = staged
        return receipt
    }
}
