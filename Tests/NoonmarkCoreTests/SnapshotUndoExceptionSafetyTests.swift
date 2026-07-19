@testable import NoonmarkCore
import XCTest

final class SnapshotUndoExceptionSafetyTests: XCTestCase {
    func testInvalidUndoClockLeavesReceiverExactlyUnchanged() throws {
        let target = NoonmarkEngine()
        let targetBeforeAttempt = target.snapshot()
        let current = NoonmarkEngine()
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let today = LocalDate("2026-07-16")
        let chainID = try current.createPoolTask(
            title: "只存在于当前快照的事实",
            now: now
        )
        _ = try current.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )

        XCTAssertThrowsError(
            try target.prepareSnapshotUndo(
                replacing: current.snapshot(),
                now: Date(timeIntervalSinceReferenceDate: .nan)
            )
        )
        XCTAssertEqual(target.snapshot(), targetBeforeAttempt)
    }
}
