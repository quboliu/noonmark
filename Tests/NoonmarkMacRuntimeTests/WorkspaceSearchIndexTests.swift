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
