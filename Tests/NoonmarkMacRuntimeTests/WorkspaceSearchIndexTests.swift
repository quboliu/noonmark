import Foundation
import NoonmarkCore
@testable import NoonmarkMacRuntime
import XCTest

final class WorkspaceSearchIndexTests: XCTestCase {
    private let today = LocalDate("2026-07-15")
    private let start = Date(timeIntervalSince1970: 1_784_100_000)

    func testSearchCoversPoolTasksTracesNotesAndSubtasks() throws {
        let fixture = try makeFixture()
        let index = WorkspaceSearchIndex(engine: fixture.engine)

        let poolResult = try XCTUnwrap(index.search("cafe").first)
        XCTAssertEqual(poolResult.kind, .poolTask)
        XCTAssertEqual(poolResult.title, "Café strategy")
        XCTAssertEqual(poolResult.destination, .pool(chainID: fixture.poolChainID))

        let noteResult = try XCTUnwrap(index.search("German locale").first)
        XCTAssertEqual(noteResult.kind, .task)
        XCTAssertEqual(
            noteResult.destination,
            .trace(id: fixture.traceID, date: today, status: .pending)
        )

        let subtaskResults = index.search("translate hero")
        XCTAssertEqual(subtaskResults.first?.kind, .subtask)
        XCTAssertEqual(subtaskResults.first?.title, "Translate hero copy")
        XCTAssertTrue(subtaskResults.contains { $0.kind == .task })
    }

    func testEveryQueryTokenMustMatchAcrossTitleAndContext() throws {
        let fixture = try makeFixture()
        let index = WorkspaceSearchIndex(engine: fixture.engine)

        XCTAssertEqual(index.search("launch German").first?.title, "Launch onboarding")
        XCTAssertTrue(index.search("launch French").isEmpty)
    }

    func testTitleMatchesRankAheadOfContextMatches() throws {
        let fixture = try makeFixture()
        let exactChain = try fixture.engine.createPoolTask(
            title: "Pricing",
            descriptionText: "A direct title match",
            now: start.addingTimeInterval(10)
        )
        let index = WorkspaceSearchIndex(engine: fixture.engine)

        let results = index.search("pricing")
        XCTAssertEqual(results.first?.destination, .pool(chainID: exactChain))
        XCTAssertTrue(results.contains { $0.destination == .pool(chainID: fixture.poolChainID) })
    }

    func testEmptyQueryAndNonPositiveLimitReturnNoResults() throws {
        let index = WorkspaceSearchIndex(engine: try makeFixture().engine)

        XCTAssertTrue(index.search("   ").isEmpty)
        XCTAssertTrue(index.search("launch", limit: 0).isEmpty)
    }

    func testCancelledFutureFactsStayHiddenWhileReturnedPoolDraftIsSearchable() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "Hidden cancelled plan",
            now: start
        )
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: LocalDate("2026-07-16"),
            today: today,
            now: start.addingTimeInterval(1)
        )
        let cancelledSubtaskID = try engine.addSubtask(
            traceID: traceID,
            title: "Hidden cancelled subtask",
            now: start.addingTimeInterval(2)
        )
        try engine.returnToPool(
            traceID: traceID,
            today: today,
            now: start.addingTimeInterval(3)
        )

        let index = WorkspaceSearchIndex(engine: engine)
        XCTAssertTrue(index.search("Hidden cancelled plan").allSatisfy {
            $0.destination == .pool(chainID: chainID)
        })
        let subtaskResults = index.search("Hidden cancelled subtask")
        XCTAssertEqual(
            subtaskResults.map(\.destination),
            [.pool(chainID: chainID)]
        )
        XCTAssertFalse(subtaskResults.contains {
            guard case let .subtask(id, _, _, _) = $0.destination else {
                return false
            }
            return id == cancelledSubtaskID
        })
    }

    func testSameDayReturnAndRescheduleIndexesOnlyTheCurrentTrace() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "同日回池再排期", now: start)
        let returnedTraceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: start.addingTimeInterval(1)
        )
        try engine.returnToPool(
            traceID: returnedTraceID,
            today: today,
            now: start.addingTimeInterval(2)
        )
        let replacementTraceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: start.addingTimeInterval(3)
        )

        let results = WorkspaceSearchIndex(engine: engine).search("同日回池再排期")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(
            results.first?.destination,
            .trace(id: replacementTraceID, date: today, status: .pending)
        )
    }

    func testSnapshotUndoCancelledSubtaskIsNotSearchableUnderVisibleTrace() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "Visible parent",
            now: start
        )
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: start.addingTimeInterval(1)
        )
        let before = engine.snapshot()
        _ = try engine.addSubtask(
            traceID: traceID,
            title: "Snapshot undo hidden child",
            now: start.addingTimeInterval(2)
        )
        let undone = try NoonmarkEngine(snapshot: before)
        try undone.prepareSnapshotUndo(
            replacing: engine.snapshot(),
            now: start.addingTimeInterval(3)
        )

        let index = WorkspaceSearchIndex(engine: undone)
        XCTAssertTrue(index.search("Visible parent").contains {
            $0.destination
                == .trace(id: traceID, date: today, status: .pending)
        })
        XCTAssertTrue(index.search("Snapshot undo hidden child").isEmpty)
    }

    private func makeFixture() throws -> (
        engine: NoonmarkEngine,
        poolChainID: TaskChainID,
        traceID: DayTraceID
    ) {
        let engine = NoonmarkEngine()
        let poolChainID = try engine.createPoolTask(
            title: "Café strategy",
            descriptionText: "Compare product pricing",
            initialNoteBody: "Prepare commercial review",
            now: start
        )
        let traceChainID = try engine.createPoolTask(
            title: "Launch onboarding",
            descriptionText: "Ship the welcome flow",
            now: start.addingTimeInterval(1)
        )
        let traceID = try engine.scheduleFromPool(
            chainID: traceChainID,
            date: today,
            today: today,
            now: start.addingTimeInterval(2)
        )
        _ = try engine.addSubtask(
            traceID: traceID,
            title: "Translate hero copy",
            now: start.addingTimeInterval(3)
        )
        _ = try engine.appendTraceNote(
            traceID: traceID,
            body: "Check the German locale",
            today: today,
            now: start.addingTimeInterval(4)
        )
        return (engine, poolChainID, traceID)
    }
}
