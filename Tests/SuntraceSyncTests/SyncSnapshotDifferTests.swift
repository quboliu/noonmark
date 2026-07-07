@testable import SuntraceCore
@testable import SuntraceSync
import XCTest

final class SyncSnapshotDifferTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let later = Date(timeIntervalSince1970: 1_800_000_100)
    private let today = LocalDate("2026-07-05")

    func testNewDomainObjectsBecomePendingUpsertsInDependencyOrder() throws {
        let oldSnapshot = SuntraceEngine().snapshot()
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "同步新增任务", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: today, today: today, now: now)
        _ = try engine.addSubtask(traceID: traceID, title: "新增子任务", difficulty: .medium, now: now)

        let entries = SyncSnapshotDiffer().journalEntries(
            from: oldSnapshot,
            to: engine.snapshot(),
            changedAt: later,
            deviceID: SyncDeviceID("mac-a")
        )

        XCTAssertEqual(entries.map(\.entityType), [.taskChain, .taskDefinition, .day, .dayTrace, .subtask])
        XCTAssertEqual(Set(entries.map(\.state)), [.pendingUpload])
        XCTAssertEqual(Set(entries.map(\.operation)), [.upsert])
        XCTAssertEqual(Set(entries.map(\.changedAt)), [later])
        XCTAssertEqual(Set(entries.map(\.deviceID)), [SyncDeviceID("mac-a")])
    }

    func testUnchangedSnapshotProducesNoJournalEntries() throws {
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "无变化任务", now: now)
        _ = try engine.scheduleFromPool(chainID: chainID, date: today, today: today, now: now)
        let snapshot = engine.snapshot()

        XCTAssertTrue(
            SyncSnapshotDiffer().journalEntries(
                from: snapshot,
                to: snapshot,
                changedAt: later,
                deviceID: SyncDeviceID("mac-a")
            ).isEmpty
        )
    }

    func testReviewSubtaskAndPreferencesChangesAreTrackedAtEntityLevel() throws {
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "局部变更任务", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: today, today: today, now: now)
        let subtaskID = try engine.addSubtask(traceID: traceID, title: "调整难度", difficulty: .simple, now: now)
        let oldSnapshot = engine.snapshot()

        engine.updateDailyReview(date: today, summary: "已复盘", unfinishedReason: nil, tomorrowNote: nil, now: later)
        try engine.updateSubtaskDifficulty(subtaskID, difficulty: .hard, today: today)
        engine.updateTheme(.warmPaper)

        let entries = SyncSnapshotDiffer().journalEntries(
            from: oldSnapshot,
            to: engine.snapshot(),
            changedAt: later,
            deviceID: SyncDeviceID("mac-a")
        )

        XCTAssertEqual(entries.map(\.entityType), [.day, .subtask, .appPreferences])
        XCTAssertEqual(entries.map(\.entityID).last, "default")
    }
}
