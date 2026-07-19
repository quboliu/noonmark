import Foundation
import NoonmarkCore

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
        engine: NoonmarkEngine,
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
            .filter {
                $0.date == date && $0.formsDayHistory
            }
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
            let subtasks = engine.subtasks.values.filter {
                $0.traceID == trace.id && $0.isUserPresentable
            }
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

    func matches(_ engine: NoonmarkEngine) -> Bool {
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
        let normalizedDecision = switch decision {
        case let .confirmed(content):
            ZhulongUnfinishedCauseDecision.confirmed(
                content: content.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        case .rejected:
            ZhulongUnfinishedCauseDecision.rejected
        }
        if case let .confirmed(content) = normalizedDecision, content.isEmpty {
            throw ZhulongDailyCloseError.invalidResolution
        }
        guard resolvedAt.timeIntervalSinceReferenceDate.isFinite,
              resolvedAt > hypothesis.createdAt
        else {
            throw ZhulongDailyCloseError.invalidResolution
        }
        self.id = id
        hypothesisID = hypothesis.id
        self.decision = normalizedDecision
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
        against engine: NoonmarkEngine,
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
        to engine: inout NoonmarkEngine,
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
        let staged = try NoonmarkEngine(snapshot: engine.snapshot())
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

extension ZhulongDailyCloseSnapshot {
    func validateForPersistence(expectedSessionID: ZhulongSessionID) throws {
        let allowedTraceStatuses: Set<TraceStatus> = [
            .pending,
            .completed,
            .unfinished,
            .continued,
            .changed,
            .returnedToPool,
            .abandoned
        ]
        let statusCountSum = [
            counts.completed,
            counts.unfinished,
            counts.continued,
            counts.changed,
            counts.returnedToPool,
            counts.abandoned,
            counts.pending
        ].reduce((value: 0, overflowed: false)) { partial, count in
            let addition = partial.value.addingReportingOverflow(count)
            return (
                value: addition.partialValue,
                overflowed: partial.overflowed || addition.overflow
            )
        }
        guard sessionID == expectedSessionID,
              capturedAt.timeIntervalSinceReferenceDate.isFinite,
              dayLockedAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
              Set(traces.map(\.traceID)).count == traces.count,
              traces.allSatisfy({ allowedTraceStatuses.contains($0.status) }),
              counts.total == traces.count,
              statusCountSum.overflowed == false,
              counts.total == statusCountSum.value,
              counts.completed == traces.filter({ $0.status == .completed }).count,
              counts.unfinished == traces.filter({ $0.status == .unfinished }).count,
              counts.continued == traces.filter({ $0.status == .continued }).count,
              counts.changed == traces.filter({ $0.status == .changed }).count,
              counts.returnedToPool == traces.filter({ $0.status == .returnedToPool }).count,
              counts.abandoned == traces.filter({ $0.status == .abandoned }).count,
              counts.pending == traces.filter({ $0.status == .pending }).count,
              traces.allSatisfy({ trace in
                  trace.continuationSequence >= 0 &&
                      (0 ... 100).contains(trace.progressPercent) &&
                      trace.subtaskCount >= 0 &&
                      trace.completedSubtaskCount >= 0 &&
                      trace.completedSubtaskCount <= trace.subtaskCount
              }),
              evidenceDigest == (try? Self.digest(
                  date: date,
                  dayLockedAt: dayLockedAt,
                  counts: counts,
                  traces: traces
              ))
        else {
            throw ZhulongDailyCloseError.staleEvidence
        }
    }
}

extension ZhulongUnfinishedCauseHypothesis {
    func validateForPersistence(snapshot: ZhulongDailyCloseSnapshot) throws {
        let unfinishedTraceIDs = Set(snapshot.traces.compactMap { trace in
            trace.status == .pending || trace.status == .unfinished ? trace.traceID : nil
        })
        guard dailyCloseID == snapshot.id,
              createdAt > snapshot.capturedAt,
              Set(evidenceTraceIDs).isSubset(of: unfinishedTraceIDs),
              (try? ZhulongUnfinishedCauseHypothesis(
                  id: id,
                  dailyCloseID: dailyCloseID,
                  content: content,
                  evidenceTraceIDs: evidenceTraceIDs,
                  confidence: confidence,
                  counterexamples: counterexamples,
                  createdAt: createdAt
              )) == self
        else {
            throw ZhulongDailyCloseError.invalidHypothesis
        }
    }
}

extension ZhulongUnfinishedCauseResolution {
    func validateForPersistence(hypothesis: ZhulongUnfinishedCauseHypothesis) throws {
        guard hypothesisID == hypothesis.id,
              (try? ZhulongUnfinishedCauseResolution(
                  id: id,
                  hypothesis: hypothesis,
                  decision: decision,
                  resolvedAt: resolvedAt
              )) == self
        else {
            throw ZhulongDailyCloseError.invalidResolution
        }
    }
}

extension ZhulongDailyReviewDraft {
    func validateForPersistence(
        snapshot: ZhulongDailyCloseSnapshot,
        resolutions: [ZhulongUnfinishedCauseResolution]
    ) throws {
        guard dailyCloseID == snapshot.id,
              confirmedCauseResolutionIDs == resolutions.compactMap({ resolution in
                  guard case .confirmed = resolution.decision else { return nil }
                  return resolution.id
              }),
              (try? ZhulongDailyReviewDraft(
                  id: id,
                  snapshot: snapshot,
                  summary: summary,
                  tomorrowNote: tomorrowNote,
                  causeResolutions: resolutions,
                  createdAt: createdAt
              )) == self
        else {
            throw ZhulongDailyCloseError.invalidReviewDraft
        }
    }
}

public extension ZhulongSession {
    @discardableResult
    mutating func captureDailyClose(
        date: LocalDate,
        from engine: NoonmarkEngine,
        now: Date = Date()
    ) throws -> ZhulongDailyCloseSnapshot {
        try validateDailyCloseActivity(now)
        guard proposedScopes.contains(.currentDayTodo) else {
            throw ZhulongSessionError.scopeNotAuthorized
        }
        let snapshot = try ZhulongDailyCloseSnapshot(
            sessionID: id,
            date: date,
            engine: engine,
            capturedAt: now
        )
        dailyCloseSnapshots.append(snapshot)
        appendEvent(
            .dailyCloseCaptured,
            summary: "已捕获每日收尾事实快照",
            reference: .dailyClose(snapshot.id),
            now: now
        )
        return snapshot
    }

    mutating func proposeUnfinishedCause(_ hypothesis: ZhulongUnfinishedCauseHypothesis) throws {
        try validateDailyCloseActivity(hypothesis.createdAt)
        guard let snapshot = dailyCloseSnapshots.first(where: { $0.id == hypothesis.dailyCloseID }) else {
            throw ZhulongDailyCloseError.invalidHypothesis
        }
        let unfinishedTraceIDs = Set(snapshot.traces.compactMap { trace in
            trace.status == .pending || trace.status == .unfinished ? trace.traceID : nil
        })
        guard hypothesis.createdAt > snapshot.capturedAt,
              unfinishedCauseHypotheses.contains(where: { $0.id == hypothesis.id }) == false,
              Set(hypothesis.evidenceTraceIDs).isSubset(of: unfinishedTraceIDs)
        else {
            throw ZhulongDailyCloseError.invalidHypothesis
        }
        unfinishedCauseHypotheses.append(hypothesis)
        appendEvent(
            .unfinishedCauseProposed,
            summary: "烛龙已提出未完成原因假设",
            reference: .unfinishedCauseHypothesis(hypothesis.id),
            now: hypothesis.createdAt
        )
    }

    @discardableResult
    mutating func resolveUnfinishedCause(
        _ hypothesisID: ZhulongUnfinishedCauseHypothesisID,
        decision: ZhulongUnfinishedCauseDecision,
        now: Date = Date()
    ) throws -> ZhulongUnfinishedCauseResolution {
        try validateDailyCloseActivity(now)
        guard let hypothesis = unfinishedCauseHypotheses.first(where: { $0.id == hypothesisID }),
              unfinishedCauseResolutions.contains(where: { $0.hypothesisID == hypothesisID }) == false
        else {
            throw ZhulongDailyCloseError.invalidResolution
        }
        let resolution = try ZhulongUnfinishedCauseResolution(
            hypothesis: hypothesis,
            decision: decision,
            resolvedAt: now
        )
        unfinishedCauseResolutions.append(resolution)
        appendEvent(
            .unfinishedCauseResolved,
            summary: "用户已裁决未完成原因假设",
            reference: .unfinishedCauseResolution(resolution.id),
            now: now
        )
        return resolution
    }

    @discardableResult
    mutating func publishDailyReviewDraft(
        dailyCloseID: ZhulongDailyCloseID,
        summary: String?,
        tomorrowNote: String?,
        causeResolutionIDs: [ZhulongUnfinishedCauseResolutionID],
        now: Date = Date()
    ) throws -> ZhulongDailyReviewDraft {
        try validateDailyCloseActivity(now)
        guard let snapshot = dailyCloseSnapshots.first(where: { $0.id == dailyCloseID }),
              Set(causeResolutionIDs).count == causeResolutionIDs.count
        else {
            throw ZhulongDailyCloseError.invalidReviewDraft
        }
        let resolutions = try causeResolutionIDs.map { resolutionID in
            guard let resolution = unfinishedCauseResolutions.first(where: { $0.id == resolutionID }),
                  unfinishedCauseHypotheses.contains(where: {
                      $0.id == resolution.hypothesisID && $0.dailyCloseID == dailyCloseID
                  })
            else {
                throw ZhulongDailyCloseError.invalidReviewDraft
            }
            return resolution
        }
        let draft = try ZhulongDailyReviewDraft(
            snapshot: snapshot,
            summary: summary,
            tomorrowNote: tomorrowNote,
            causeResolutions: resolutions,
            createdAt: now
        )
        dailyReviewDrafts.append(draft)
        appendEvent(
            .dailyReviewDraftPublished,
            summary: "已发布可编辑 AI 复盘草稿",
            reference: .dailyReviewDraft(draft.id),
            now: now
        )
        return draft
    }

    @discardableResult
    mutating func authorizeDailyReview(
        _ draftID: ZhulongDailyReviewDraftID,
        against engine: NoonmarkEngine,
        now: Date = Date()
    ) throws -> ZhulongDailyReviewAuthorization {
        try validateDailyCloseActivity(now)
        guard let draft = dailyReviewDrafts.first(where: { $0.id == draftID }),
              let snapshot = dailyCloseSnapshots.first(where: { $0.id == draft.dailyCloseID }),
              dailyReviewAuthorizations.contains(where: { $0.draftID == draftID }) == false
        else {
            throw ZhulongDailyCloseError.authorizationMismatch
        }
        let authorization = try ZhulongDailyReviewApplier().authorize(
            draft,
            snapshot: snapshot,
            against: engine,
            now: now
        )
        dailyReviewAuthorizations.append(authorization)
        appendEvent(
            .dailyReviewAuthorized,
            summary: "用户已对当前 AI 复盘草稿授予一次性保存授权",
            reference: .dailyReviewAuthorization(authorization.id),
            now: now
        )
        return authorization
    }

    @discardableResult
    mutating func applyAuthorizedDailyReview(
        _ draftID: ZhulongDailyReviewDraftID,
        to engine: inout NoonmarkEngine,
        now: Date = Date()
    ) throws -> ZhulongDailyReviewReceipt {
        try validateDailyCloseActivity(now)
        var stagedSession = self
        let stagedEngine = try NoonmarkEngine(snapshot: engine.snapshot())
        guard let draft = stagedSession.dailyReviewDrafts.first(where: { $0.id == draftID }),
              let snapshot = stagedSession.dailyCloseSnapshots.first(where: {
                  $0.id == draft.dailyCloseID
              }),
              let authorizationIndex = stagedSession.dailyReviewAuthorizations.firstIndex(where: {
                  $0.draftID == draftID && $0.status == .active
              })
        else {
            throw ZhulongDailyCloseError.authorizationMismatch
        }
        var authorization = stagedSession.dailyReviewAuthorizations[authorizationIndex]
        var mutableEngine = stagedEngine
        let receipt = try ZhulongDailyReviewApplier().apply(
            draft,
            snapshot: snapshot,
            authorization: &authorization,
            to: &mutableEngine,
            now: now
        )
        stagedSession.dailyReviewAuthorizations[authorizationIndex] = authorization
        stagedSession.dailyReviewReceipts.append(receipt)
        stagedSession.appendEvent(
            .dailyReviewApplied,
            summary: "已保存用户确认的每日复盘",
            reference: .dailyReviewReceipt(receipt.id),
            now: now
        )
        self = stagedSession
        engine = mutableEngine
        return receipt
    }

    private func validateDailyCloseActivity(_ now: Date) throws {
        guard workspaceStatus == .active else {
            throw ZhulongSessionError.workspaceInactive
        }
        guard phase != .providerRunning else {
            throw ZhulongSessionError.providerRunStillActive
        }
        try validateActivityTime(now)
    }
}
