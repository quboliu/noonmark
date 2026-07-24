@testable import NoonmarkCore
@testable import NoonmarkZhulong
import XCTest

final class ZhulongDailyCloseTests: XCTestCase {
    private let date = LocalDate("2026-07-12")
    private let nextDate = LocalDate("2026-07-13")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let sessionID = ZhulongSessionID(
        UUID(uuidString: "AAAAAAAA-1000-0000-0000-000000000001")!
    )

    func testCaptureIsReadOnlyBeforeAndAfterCoreDaySettlement() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "未完成任务", now: now)
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: date,
            today: date,
            now: now
        )

        let before = try ZhulongDailyCloseSnapshot(
            sessionID: sessionID,
            date: date,
            engine: engine,
            capturedAt: now.addingTimeInterval(1)
        )

        XCTAssertNil(engine.days[date]?.lockedAt)
        XCTAssertEqual(engine.traces[traceID]?.status, .pending)
        XCTAssertEqual(before.counts.pending, 1)
        try engine.settleDays(upTo: nextDate, now: now.addingTimeInterval(2))
        let after = try ZhulongDailyCloseSnapshot(
            sessionID: sessionID,
            date: date,
            engine: engine,
            capturedAt: now.addingTimeInterval(3)
        )
        XCTAssertNotNil(after.dayLockedAt)
        XCTAssertEqual(after.counts.unfinished, 1)
        XCTAssertNotEqual(before.evidenceDigest, after.evidenceDigest)
    }

    func testCaptureExcludesCancelledFutureDraftAndItsSubtasks() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "未来计划草稿", now: now)
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: nextDate,
            today: date,
            now: now
        )
        _ = try engine.addSubtask(
            traceID: traceID,
            title: "不应进入每日收尾证据",
            now: now.addingTimeInterval(1)
        )
        try engine.returnToPool(
            traceID: traceID,
            today: date,
            now: now.addingTimeInterval(2)
        )

        let cancelledDraft = try XCTUnwrap(engine.traces[traceID])
        XCTAssertEqual(cancelledDraft.status, .cancelledDraft)
        XCTAssertFalse(cancelledDraft.formsDayHistory)
        XCTAssertEqual(engine.subtasks.values.filter { $0.traceID == traceID }.count, 1)

        let snapshot = try ZhulongDailyCloseSnapshot(
            sessionID: sessionID,
            date: nextDate,
            engine: engine,
            capturedAt: now.addingTimeInterval(3)
        )

        XCTAssertEqual(snapshot.counts.total, 0)
        XCTAssertEqual(snapshot.counts.completed, 0)
        XCTAssertEqual(snapshot.counts.unfinished, 0)
        XCTAssertEqual(snapshot.counts.deferred, 0)
        XCTAssertEqual(snapshot.counts.changed, 0)
        XCTAssertEqual(snapshot.counts.returnedToPool, 0)
        XCTAssertEqual(snapshot.counts.abandoned, 0)
        XCTAssertEqual(snapshot.counts.pending, 0)
        XCTAssertTrue(snapshot.traces.isEmpty)
        XCTAssertFalse(snapshot.evidenceDigest.isEmpty)
        XCTAssertTrue(snapshot.matches(engine))
        XCTAssertNoThrow(
            try snapshot.validateForPersistence(expectedSessionID: sessionID)
        )
    }

    func testOnlyConfirmedCauseCanEnterReviewAndSaveDoesNotSettleDay() throws {
        var engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "仍在进行", now: now)
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: date,
            today: date,
            now: now
        )
        let snapshot = try ZhulongDailyCloseSnapshot(
            sessionID: sessionID,
            date: date,
            engine: engine,
            capturedAt: now.addingTimeInterval(1)
        )
        let confirmedHypothesis = try ZhulongUnfinishedCauseHypothesis(
            dailyCloseID: snapshot.id,
            content: "可能低估了任务范围",
            evidenceTraceIDs: [traceID],
            confidence: 0.6,
            counterexamples: ["也可能只是外部依赖延迟"],
            createdAt: now.addingTimeInterval(2)
        )
        let rejectedHypothesis = try ZhulongUnfinishedCauseHypothesis(
            dailyCloseID: snapshot.id,
            content: "可能优先级不清",
            evidenceTraceIDs: [traceID],
            confidence: 0.4,
            counterexamples: ["当天优先级已经明确"],
            createdAt: now.addingTimeInterval(2)
        )
        let confirmed = try ZhulongUnfinishedCauseResolution(
            hypothesis: confirmedHypothesis,
            decision: .confirmed(content: "任务范围比预期大"),
            resolvedAt: now.addingTimeInterval(3)
        )
        let rejected = try ZhulongUnfinishedCauseResolution(
            hypothesis: rejectedHypothesis,
            decision: .rejected,
            resolvedAt: now.addingTimeInterval(3)
        )
        let draft = try ZhulongDailyReviewDraft(
            snapshot: snapshot,
            summary: "完成了证据整理",
            tomorrowNote: "重新确认范围",
            causeResolutions: [confirmed, rejected],
            createdAt: now.addingTimeInterval(4)
        )
        XCTAssertEqual(draft.unfinishedReason, "任务范围比预期大")
        XCTAssertEqual(draft.confirmedCauseResolutionIDs, [confirmed.id])

        let applier = ZhulongDailyReviewApplier()
        var authorization = try applier.authorize(
            draft,
            snapshot: snapshot,
            against: engine,
            now: now.addingTimeInterval(5)
        )
        _ = try applier.apply(
            draft,
            snapshot: snapshot,
            authorization: &authorization,
            to: &engine,
            now: now.addingTimeInterval(6)
        )

        XCTAssertNil(engine.days[date]?.lockedAt)
        XCTAssertEqual(engine.traces[traceID]?.status, .pending)
        XCTAssertEqual(engine.days[date]?.reviewUnfinishedReason, "任务范围比预期大")
        XCTAssertThrowsError(
            try applier.apply(
                draft,
                snapshot: snapshot,
                authorization: &authorization,
                to: &engine,
                now: now.addingTimeInterval(7)
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongDailyCloseError, .authorizationConsumed)
        }
    }

    func testEvidenceChangeInvalidatesReviewWithoutPartialMutation() throws {
        var engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "会变化的任务", now: now)
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: date,
            today: date,
            now: now
        )
        let snapshot = try ZhulongDailyCloseSnapshot(
            sessionID: sessionID,
            date: date,
            engine: engine,
            capturedAt: now.addingTimeInterval(1)
        )
        let draft = try ZhulongDailyReviewDraft(
            snapshot: snapshot,
            summary: "准备保存",
            tomorrowNote: nil,
            causeResolutions: [],
            createdAt: now.addingTimeInterval(2)
        )
        let applier = ZhulongDailyReviewApplier()
        var authorization = try applier.authorize(
            draft,
            snapshot: snapshot,
            against: engine,
            now: now.addingTimeInterval(3)
        )
        try engine.markCompleted(
            traceID: traceID,
            today: date,
            now: now.addingTimeInterval(4)
        )
        let before = engine.snapshot()

        XCTAssertThrowsError(
            try applier.apply(
                draft,
                snapshot: snapshot,
                authorization: &authorization,
                to: &engine,
                now: now.addingTimeInterval(5)
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongDailyCloseError, .staleEvidence)
        }
        XCTAssertEqual(engine.snapshot(), before)
        XCTAssertEqual(authorization.status, .active)
    }

    func testSessionRecordsDailyCloseLedgerAndAppliesReviewAtomically() throws {
        var session = try ZhulongSession(
            id: sessionID,
            primaryIntent: "完成每日收尾",
            proposedScopes: [.currentDayTodo],
            now: now
        )
        var engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "仍在进行", now: now)
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: date,
            today: date,
            now: now
        )
        let snapshot = try session.captureDailyClose(
            date: date,
            from: engine,
            now: now.addingTimeInterval(1)
        )
        let hypothesis = try ZhulongUnfinishedCauseHypothesis(
            dailyCloseID: snapshot.id,
            content: "任务范围可能大于预期",
            evidenceTraceIDs: [traceID],
            confidence: 0.65,
            counterexamples: ["也可能是外部依赖延迟"],
            createdAt: now.addingTimeInterval(2)
        )
        try session.proposeUnfinishedCause(hypothesis)
        let resolution = try session.resolveUnfinishedCause(
            hypothesis.id,
            decision: .confirmed(content: "任务范围比预期大"),
            now: now.addingTimeInterval(3)
        )
        let draft = try session.publishDailyReviewDraft(
            dailyCloseID: snapshot.id,
            summary: "完成了证据整理",
            tomorrowNote: "重新确认范围",
            causeResolutionIDs: [resolution.id],
            now: now.addingTimeInterval(4)
        )
        _ = try session.authorizeDailyReview(
            draft.id,
            against: engine,
            now: now.addingTimeInterval(5)
        )
        let receipt = try session.applyAuthorizedDailyReview(
            draft.id,
            to: &engine,
            now: now.addingTimeInterval(6)
        )

        XCTAssertEqual(session.dailyReviewReceipts, [receipt])
        XCTAssertEqual(engine.days[date]?.reviewUnfinishedReason, "任务范围比预期大")
        XCTAssertEqual(session.phase, .scopeReview)
        XCTAssertEqual(session.events.suffix(6).map(\.kind), [
            .dailyCloseCaptured,
            .unfinishedCauseProposed,
            .unfinishedCauseResolved,
            .dailyReviewDraftPublished,
            .dailyReviewAuthorized,
            .dailyReviewApplied
        ])
    }

    func testPersistenceValidationRejectsCancelledDraftEvidenceWithValidDigest() throws {
        let snapshot = try makePendingSnapshot()
        let trace = try XCTUnwrap(snapshot.traces.first)
        let cancelledDraft = ZhulongDailyTraceEvidence(
            traceID: trace.traceID,
            chainID: trace.chainID,
            title: trace.title,
            status: .cancelledDraft,
            continuationSequence: trace.continuationSequence,
            progressPercent: trace.progressPercent,
            subtaskCount: trace.subtaskCount,
            completedSubtaskCount: trace.completedSubtaskCount
        )
        let counts = ZhulongDailyCloseCounts(
            total: 1,
            completed: 0,
            unfinished: 0,
            deferred: 0,
            changed: 0,
            returnedToPool: 0,
            abandoned: 0,
            pending: 0
        )
        let forged = try rebuilding(
            snapshot,
            counts: counts,
            traces: [cancelledDraft]
        )

        XCTAssertThrowsError(
            try forged.validateForPersistence(expectedSessionID: sessionID)
        ) { error in
            XCTAssertEqual(error as? ZhulongDailyCloseError, .staleEvidence)
        }
    }

    func testPersistenceValidationRejectsCountsThatDoNotCoverEveryTraceStatus() throws {
        let snapshot = try makePendingSnapshot()
        let pending = try XCTUnwrap(snapshot.traces.first)
        let cancelledDraft = ZhulongDailyTraceEvidence(
            traceID: DayTraceID(),
            chainID: pending.chainID,
            title: "已取消计划草稿",
            status: .cancelledDraft,
            continuationSequence: 0,
            progressPercent: 0,
            subtaskCount: 0,
            completedSubtaskCount: 0
        )
        let counts = ZhulongDailyCloseCounts(
            total: 2,
            completed: 0,
            unfinished: 0,
            deferred: 0,
            changed: 0,
            returnedToPool: 0,
            abandoned: 0,
            pending: 1
        )
        let forged = try rebuilding(
            snapshot,
            counts: counts,
            traces: [pending, cancelledDraft]
        )

        XCTAssertEqual(counts.total, 2)
        XCTAssertEqual(statusCountSum(counts), 1)
        XCTAssertThrowsError(
            try forged.validateForPersistence(expectedSessionID: sessionID)
        ) { error in
            XCTAssertEqual(error as? ZhulongDailyCloseError, .staleEvidence)
        }
    }

    private func makePendingSnapshot() throws -> ZhulongDailyCloseSnapshot {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "待收尾任务", now: now)
        _ = try engine.scheduleFromPool(
            chainID: chainID,
            date: date,
            today: date,
            now: now
        )
        return try ZhulongDailyCloseSnapshot(
            sessionID: sessionID,
            date: date,
            engine: engine,
            capturedAt: now.addingTimeInterval(1)
        )
    }

    private func rebuilding(
        _ snapshot: ZhulongDailyCloseSnapshot,
        counts: ZhulongDailyCloseCounts,
        traces: [ZhulongDailyTraceEvidence]
    ) throws -> ZhulongDailyCloseSnapshot {
        let evidenceDigest = try ZhulongTodoDigest.value(DailyCloseEvidenceFixture(
            date: snapshot.date,
            dayLockedAt: snapshot.dayLockedAt,
            counts: counts,
            traces: traces
        ))
        let fixture = DailyCloseSnapshotFixture(
            id: snapshot.id,
            sessionID: snapshot.sessionID,
            date: snapshot.date,
            capturedAt: snapshot.capturedAt,
            dayLockedAt: snapshot.dayLockedAt,
            counts: counts,
            traces: traces,
            evidenceDigest: evidenceDigest
        )
        return try JSONDecoder().decode(
            ZhulongDailyCloseSnapshot.self,
            from: JSONEncoder().encode(fixture)
        )
    }

    private func statusCountSum(_ counts: ZhulongDailyCloseCounts) -> Int {
        counts.completed +
            counts.unfinished +
            counts.deferred +
            counts.changed +
            counts.returnedToPool +
            counts.abandoned +
            counts.pending
    }
}

private struct DailyCloseEvidenceFixture: Encodable {
    let date: LocalDate
    let dayLockedAt: Date?
    let counts: ZhulongDailyCloseCounts
    let traces: [ZhulongDailyTraceEvidence]
}

private struct DailyCloseSnapshotFixture: Encodable {
    let id: ZhulongDailyCloseID
    let sessionID: ZhulongSessionID
    let date: LocalDate
    let capturedAt: Date
    let dayLockedAt: Date?
    let counts: ZhulongDailyCloseCounts
    let traces: [ZhulongDailyTraceEvidence]
    let evidenceDigest: String
}
