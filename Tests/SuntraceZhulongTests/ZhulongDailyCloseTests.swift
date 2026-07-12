@testable import SuntraceCore
@testable import SuntraceZhulong
import XCTest

final class ZhulongDailyCloseTests: XCTestCase {
    private let date = LocalDate("2026-07-12")
    private let nextDate = LocalDate("2026-07-13")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let sessionID = ZhulongSessionID(
        UUID(uuidString: "AAAAAAAA-1000-0000-0000-000000000001")!
    )

    func testCaptureIsReadOnlyBeforeAndAfterCoreDaySettlement() throws {
        let engine = SuntraceEngine()
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
        engine.settleDays(upTo: nextDate, now: now.addingTimeInterval(2))
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

    func testOnlyConfirmedCauseCanEnterReviewAndSaveDoesNotSettleDay() throws {
        var engine = SuntraceEngine()
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
        var engine = SuntraceEngine()
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
}
