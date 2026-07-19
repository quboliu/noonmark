@testable import NoonmarkCore
import XCTest

final class NoonmarkSnapshotDefinitionTopologyTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 812_345_678.5)

    func testSnapshotRejectsClosedHistoricalDefinitionSuccessorCycle() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "Core successor cycle",
            now: now
        )
        let chain = try XCTUnwrap(engine.chains[chainID])
        var first = try XCTUnwrap(
            engine.definitions.values.first { $0.chainID == chainID }
        )
        var second = TaskDefinition(
            chainID: chainID,
            sequence: 2,
            title: "second",
            now: now.addingTimeInterval(1)
        )
        let current = TaskDefinition(
            chainID: chainID,
            sequence: 3,
            title: "current",
            now: now.addingTimeInterval(2)
        )
        try supersede(
            &first,
            by: second.id,
            at: now.addingTimeInterval(3)
        )
        try supersede(
            &second,
            by: first.id,
            at: now.addingTimeInterval(4)
        )
        let snapshot = NoonmarkSnapshot(
            days: [],
            chains: [chain],
            definitions: [first, second, current],
            traces: [],
            subtasks: [],
            preferences: AppPreferences(),
            classifications: TaskClassificationState()
        )

        XCTAssertThrowsError(try snapshot.validateIntegrity()) { error in
            XCTAssertEqual(
                error as? NoonmarkError,
                .invalidInput(
                    "snapshot contains invalid task definition topology"
                )
            )
        }
    }

    func testSnapshotRejectsSelfSuccessorWithoutSupersededDate() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "Core incomplete supersession",
            now: now
        )
        var snapshot = engine.snapshot()
        let definitionIndex = try XCTUnwrap(
            snapshot.definitions.firstIndex { $0.chainID == chainID }
        )
        snapshot.definitions[definitionIndex].supersededByDefinitionID =
            snapshot.definitions[definitionIndex].id

        XCTAssertThrowsError(try snapshot.validateIntegrity())
    }

    func testSnapshotUndoCurrentDefinitionMayRetainTransitionWitness() throws {
        let today = LocalDate("2026-07-16")
        let tomorrow = LocalDate("2026-07-17")
        let renamed = NoonmarkEngine()
        let chainID = try renamed.createPoolTask(
            title: "before rename",
            now: now
        )
        _ = try renamed.scheduleFromPool(
            chainID: chainID,
            date: tomorrow,
            today: today,
            now: now.addingTimeInterval(1)
        )
        let beforeRename = renamed.snapshot()
        try renamed.renameTaskTitle(
            chainID: chainID,
            title: "after rename",
            today: today,
            now: now.addingTimeInterval(2)
        )

        let undone = try NoonmarkEngine(snapshot: beforeRename)
        try undone.prepareSnapshotUndo(
            replacing: renamed.snapshot(),
            now: now.addingTimeInterval(3)
        )
        let restoredCurrent = try XCTUnwrap(
            undone.definitions.values.first {
                $0.chainID == chainID && $0.supersededAt == nil
            }
        )

        XCTAssertNotNil(restoredCurrent.supersededByDefinitionID)
        XCTAssertNoThrow(try undone.snapshot().validateIntegrity())
    }

    private func supersede(
        _ definition: inout TaskDefinition,
        by successorID: TaskDefinitionID,
        at date: Date
    ) throws {
        definition.supersededAt = date
        definition.supersededByDefinitionID = successorID
        try definition.markContentModified(at: date)
    }
}
