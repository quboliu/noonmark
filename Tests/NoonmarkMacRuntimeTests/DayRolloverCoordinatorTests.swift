import Foundation
import NoonmarkCore
import NoonmarkDayContext
@testable import NoonmarkMacRuntime
import NoonmarkStorage
import NoonmarkSync
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
        ) { candidate, _ in
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
            ) { _, _ in
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
            persist: { _, _ in }
        )
        let firstSettledAt = first.traces[traceID]?.settledAt

        let second = try coordinator.reconcile(
            engine: first,
            moment: makeMoment(today),
            persist: { _, _ in }
        )

        XCTAssertEqual(second.traces[traceID]?.status, .unfinished)
        XCTAssertEqual(second.traces[traceID]?.settledAt, firstSettledAt)
        XCTAssertEqual(second.days[yesterday]?.lockedAt, first.days[yesterday]?.lockedAt)
    }

    func testReconcileDoesNotPersistAnAlreadySettledSnapshot() throws {
        let yesterday = LocalDate("2026-07-14")
        let today = LocalDate("2026-07-15")
        let (engine, _) = try makePendingTrace(on: yesterday)
        let coordinator = DayRolloverCoordinator()
        let settled = try coordinator.reconcile(
            engine: engine,
            moment: makeMoment(today),
            persist: { _, _ in }
        )
        var didPersist = false

        let reconciled = try coordinator.reconcile(
            engine: settled,
            moment: makeMoment(today)
        ) { _, _ in
            didPersist = true
        }

        XCTAssertFalse(didPersist)
        XCTAssertEqual(reconciled.snapshot(), settled.snapshot())
    }

    func testReconcileAdvancesPastPersistedFactsWhenWallClockMovesBackwards() throws {
        let yesterday = LocalDate("2026-07-14")
        let today = LocalDate("2026-07-15")
        let persistedFrontier = makeMoment(LocalDate("2026-07-16")).instant
        let (engine, traceID) = try makePendingTrace(
            on: yesterday,
            now: persistedFrontier
        )

        let reconciled = try DayRolloverCoordinator().reconcile(
            engine: engine,
            moment: makeMoment(today),
            persist: { _, _ in }
        )

        let settledAt = try XCTUnwrap(reconciled.traces[traceID]?.settledAt)
        let lockedAt = try XCTUnwrap(reconciled.days[yesterday]?.lockedAt)
        XCTAssertEqual(
            settledAt.timeIntervalSinceReferenceDate,
            persistedFrontier.timeIntervalSinceReferenceDate.nextUp
        )
        XCTAssertEqual(lockedAt, settledAt)
    }

    func testReconcilePersistsRollbackSafeLogicalInstantIntoOrderedJournal() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("noonmark-rollover-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(
                    at: URL(fileURLWithPath: databaseURL.path + suffix)
                )
            }
        }
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let deviceID = SyncDeviceID("rollback-mac")
        let yesterday = LocalDate("2026-07-14")
        let today = LocalDate("2026-07-15")
        let persistedFrontier = makeMoment(LocalDate("2026-07-16")).instant
        let (engine, traceID) = try makePendingTrace(
            on: yesterday,
            now: persistedFrontier
        )
        try engineRepository.save(engine.snapshot())
        var persistedMutationInstant: Date?

        let reconciled = try DayRolloverCoordinator().reconcile(
            engine: engine,
            moment: makeMoment(today)
        ) { candidate, mutationInstant in
            persistedMutationInstant = mutationInstant
            try engineRepository.save(
                candidate.snapshot(),
                recordingChangesFor: deviceID,
                changedAt: mutationInstant
            )
        }

        let expectedInterval = persistedFrontier
            .timeIntervalSinceReferenceDate.nextUp
        let expectedBits = expectedInterval.bitPattern
        XCTAssertEqual(
            persistedMutationInstant?.timeIntervalSinceReferenceDate.bitPattern,
            expectedBits
        )
        XCTAssertEqual(
            reconciled.days[yesterday]?.lockedAt?
                .timeIntervalSinceReferenceDate.bitPattern,
            expectedBits
        )
        XCTAssertEqual(
            reconciled.traces[traceID]?.settledAt?
                .timeIntervalSinceReferenceDate.bitPattern,
            expectedBits
        )

        let journal = try syncRepository.journalEntries(
            state: .pendingUpload
        )
        XCTAssertEqual(
            journal.map(\.entityType),
            [.day, .dayTrace, .traceClassificationEvent]
        )
        XCTAssertEqual(
            journal.map {
                $0.changedAt.timeIntervalSinceReferenceDate.bitPattern
            },
            [expectedBits, expectedBits, expectedBits]
        )
    }

    private func makePendingTrace(on date: LocalDate) throws -> (NoonmarkEngine, DayTraceID) {
        try makePendingTrace(on: date, now: makeMoment(date).instant)
    }

    private func makePendingTrace(
        on date: LocalDate,
        now: Date
    ) throws -> (NoonmarkEngine, DayTraceID) {
        let engine = NoonmarkEngine()
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
