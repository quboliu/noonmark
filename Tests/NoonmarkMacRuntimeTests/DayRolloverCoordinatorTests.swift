import Foundation
import NoonmarkCore
import NoonmarkDayContext
@testable import NoonmarkMacRuntime
import XCTest

@MainActor
final class DayRolloverCoordinatorTests: XCTestCase {
    func testReconcileSettlesCandidateBeforePersistenceAndLeavesSourceUntouched() throws {
        let yesterday = LocalDate("2026-07-14")
        let today = LocalDate("2026-07-15")
        let (engine, traceID) = try makePendingTrace(on: yesterday)
        var persistedStatus: TraceStatus?
        var persistedLockedAt: Date?

        let reconciled = try DayRolloverCoordinator().reconcile(
            engine: engine,
            moment: makeMoment(today)
        ) { candidate in
            persistedStatus = candidate.traces[traceID]?.status
            persistedLockedAt = candidate.days[yesterday]?.lockedAt
        }

        XCTAssertEqual(engine.traces[traceID]?.status, .pending)
        XCTAssertNil(engine.days[yesterday]?.lockedAt)
        XCTAssertEqual(persistedStatus, .unfinished)
        XCTAssertNotNil(persistedLockedAt)
        XCTAssertEqual(reconciled.traces[traceID]?.status, .unfinished)
        XCTAssertNotNil(reconciled.days[yesterday]?.lockedAt)
    }

    func testPersistenceFailureDoesNotMutateSourceEngine() throws {
        let yesterday = LocalDate("2026-07-14")
        let today = LocalDate("2026-07-15")
        let (engine, traceID) = try makePendingTrace(on: yesterday)

        XCTAssertThrowsError(
            try DayRolloverCoordinator().reconcile(
                engine: engine,
                moment: makeMoment(today)
            ) { _ in
                throw TestPersistenceError.injected
            }
        ) { error in
            XCTAssertEqual(error as? TestPersistenceError, .injected)
        }

        XCTAssertEqual(engine.traces[traceID]?.status, .pending)
        XCTAssertNil(engine.days[yesterday]?.lockedAt)
    }

    func testReconcileIsIdempotentForAnAlreadyAppliedDay() throws {
        let yesterday = LocalDate("2026-07-14")
        let today = LocalDate("2026-07-15")
        let (engine, traceID) = try makePendingTrace(on: yesterday)
        let coordinator = DayRolloverCoordinator()
        let first = try coordinator.reconcile(
            engine: engine,
            moment: makeMoment(today),
            persist: { _ in }
        )
        let firstSettledAt = first.traces[traceID]?.settledAt

        let second = try coordinator.reconcile(
            engine: first,
            moment: makeMoment(today),
            persist: { _ in }
        )

        XCTAssertEqual(second.traces[traceID]?.status, .unfinished)
        XCTAssertEqual(second.traces[traceID]?.settledAt, firstSettledAt)
        XCTAssertEqual(second.days[yesterday]?.lockedAt, first.days[yesterday]?.lockedAt)
    }

    private func makePendingTrace(on date: LocalDate) throws -> (NoonmarkEngine, DayTraceID) {
        let engine = NoonmarkEngine()
        let now = makeMoment(date).instant
        let chainID = try engine.createPoolTask(title: "Pending", now: now)
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: date,
            today: date,
            now: now
        )
        return (engine, traceID)
    }

    private func makeMoment(_ date: LocalDate) -> NaturalDayMoment {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = date.year
        components.month = date.month
        components.day = date.day
        components.hour = 12
        let instant = components.date!
        return NaturalDayMoment(
            instant: instant,
            state: NaturalDayState(
                today: date,
                timeZoneIdentifier: "UTC",
                localeIdentifier: "en_SG"
            )
        )
    }
}

private enum TestPersistenceError: Error {
    case injected
}
