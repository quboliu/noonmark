@testable import NoonmarkCore
@testable import NoonmarkStorage
import XCTest

final class SnapshotUndoPersistenceTests: XCTestCase {
    private let today = LocalDate("2026-07-16")
    private let tomorrow = LocalDate("2026-07-17")
    private let base = Date(timeIntervalSinceReferenceDate: 910_000)

    func testNewTaskUndoSurvivesSQLiteRestartWithoutResurrection() throws {
        let databaseURL = temporaryDatabaseURL()
        let repository = SQLiteEngineRepository(databaseURL: databaseURL)
        let before = NoonmarkEngine().snapshot()
        let current = NoonmarkEngine()
        let chainID = try current.createPoolTask(
            title: "SQLite 撤销新增任务",
            now: base
        )
        let traceID = try current.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: base
        )
        let subtaskID = try current.addSubtask(
            traceID: traceID,
            title: "随隐藏父轨迹保留",
            now: base
        )
        let forward = current.snapshot()
        try repository.save(forward)

        let undone = try NoonmarkEngine(snapshot: before)
        try undone.prepareSnapshotUndo(
            replacing: forward,
            now: base.addingTimeInterval(1)
        )
        try repository.save(undone.snapshot())

        let restarted = try repository.load()
        XCTAssertEqual(restarted.chains[chainID]?.state, .abandoned)
        XCTAssertEqual(
            restarted.traces[traceID]?.status,
            .cancelledDraft
        )
        XCTAssertEqual(restarted.subtasks[subtaskID]?.status, .pending)
        XCTAssertTrue(restarted.getDayTodo(date: today).traces.isEmpty)
        XCTAssertTrue(restarted.taskPool().isEmpty)
        XCTAssertNoThrow(try restarted.snapshot().validateIntegrity())
    }

    func testAddedSubtaskUndoCancellationSurvivesSQLiteRestart() throws {
        let databaseURL = temporaryDatabaseURL()
        let repository = SQLiteEngineRepository(databaseURL: databaseURL)
        let current = NoonmarkEngine()
        let chainID = try current.createPoolTask(
            title: "SQLite 撤销新增子任务",
            now: base
        )
        let traceID = try current.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: base
        )
        let before = current.snapshot()
        try repository.save(before)

        let subtaskID = try current.addSubtask(
            traceID: traceID,
            title: "应保留取消墓碑",
            now: base.addingTimeInterval(1)
        )
        let forward = current.snapshot()
        try repository.save(forward)

        let undone = try NoonmarkEngine(snapshot: before)
        try undone.prepareSnapshotUndo(
            replacing: forward,
            now: base.addingTimeInterval(2)
        )
        let cancellationID = try XCTUnwrap(
            undone.subtasks[subtaskID]?.draftCancellationID
        )
        try repository.save(undone.snapshot())

        let restarted = try repository.load()
        XCTAssertEqual(
            restarted.subtasks[subtaskID]?.status,
            .cancelledDraft
        )
        XCTAssertEqual(
            restarted.subtasks[subtaskID]?.draftCancellationID,
            cancellationID
        )
        XCTAssertEqual(restarted.subtaskProgress(for: traceID).total, 0)
        XCTAssertEqual(restarted.traceProgress(for: traceID).mode, .manual)
        XCTAssertNoThrow(try restarted.snapshot().validateIntegrity())
    }

    func testContinuationUndoAtomicallyTransfersPendingTraceAcrossSQLiteRestart() throws {
        let databaseURL = temporaryDatabaseURL()
        let repository = SQLiteEngineRepository(databaseURL: databaseURL)
        let current = NoonmarkEngine()
        let chainID = try current.createPoolTask(
            title: "SQLite 撤销延续",
            now: base
        )
        let sourceTraceID = try current.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: base
        )
        let before = current.snapshot()
        let targetTraceID = try current.continueTrace(
            traceID: sourceTraceID,
            targetDate: tomorrow,
            today: today,
            now: base.addingTimeInterval(1)
        )
        let forward = current.snapshot()
        try repository.save(forward)

        let undone = try NoonmarkEngine(snapshot: before)
        try undone.prepareSnapshotUndo(
            replacing: forward,
            now: base.addingTimeInterval(2)
        )
        XCTAssertEqual(undone.traces[sourceTraceID]?.status, .pending)
        XCTAssertEqual(
            undone.traces[targetTraceID]?.status,
            .cancelledDraft
        )
        try repository.save(undone.snapshot())

        let restarted = try repository.load()
        XCTAssertEqual(restarted.traces[sourceTraceID]?.status, .pending)
        XCTAssertEqual(
            restarted.traces[targetTraceID]?.status,
            .cancelledDraft
        )
        XCTAssertEqual(
            restarted.getDayTodo(date: today).traces.map(\.id),
            [sourceTraceID]
        )
        XCTAssertTrue(restarted.futurePlans(today: today).isEmpty)
        XCTAssertNoThrow(try restarted.snapshot().validateIntegrity())
    }

    func testUnscheduledTaskRemovalRetainsHiddenFactsAcrossSQLiteRestart() throws {
        let databaseURL = temporaryDatabaseURL()
        let repository = SQLiteEngineRepository(databaseURL: databaseURL)
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "SQLite 隐藏未排程删除",
            now: base
        )
        let definitionID = try XCTUnwrap(
            engine.taskPool().first {
                $0.chain.id == chainID
            }?.definition.id
        )
        try repository.save(engine.snapshot())

        let outcome = try engine.removeTaskFromPool(
            chainID: chainID,
            now: base.addingTimeInterval(1)
        )
        try repository.save(engine.snapshot())

        let restarted = try repository.load()
        XCTAssertEqual(outcome, .deleted)
        XCTAssertEqual(restarted.chains[chainID]?.state, .abandoned)
        XCTAssertEqual(
            restarted.definitions[definitionID]?.chainID,
            chainID
        )
        XCTAssertFalse(
            restarted.taskPool().contains { $0.chain.id == chainID }
        )
        XCTAssertNoThrow(try restarted.snapshot().validateIntegrity())
    }

    func testUnclassifiedCopiedTaskUndoRetainsHiddenFactsAcrossSQLiteRestart() throws {
        let databaseURL = temporaryDatabaseURL()
        let repository = SQLiteEngineRepository(databaseURL: databaseURL)
        let engine = NoonmarkEngine()
        let sourceChainID = try engine.createPoolTask(
            title: "SQLite 未分类复制来源",
            now: base
        )
        let sourceTraceID = try engine.scheduleFromPool(
            chainID: sourceChainID,
            date: today,
            today: today,
            now: base
        )
        try engine.markCompleted(
            traceID: sourceTraceID,
            today: today,
            now: base.addingTimeInterval(1)
        )
        let copiedChainID = try engine.copyAsNewTask(
            from: sourceTraceID,
            target: .taskPool,
            today: today,
            now: base.addingTimeInterval(2)
        )
        let copiedDefinitionID = try XCTUnwrap(
            engine.taskPool().first {
                $0.chain.id == copiedChainID
            }?.definition.id
        )
        try repository.save(engine.snapshot())

        _ = try engine.removeTaskFromPool(
            chainID: copiedChainID,
            now: base.addingTimeInterval(3)
        )
        try repository.save(engine.snapshot())

        let restarted = try repository.load()
        XCTAssertEqual(
            restarted.chains[copiedChainID]?.state,
            .abandoned
        )
        XCTAssertEqual(
            restarted.definitions[copiedDefinitionID]?.chainID,
            copiedChainID
        )
        XCTAssertEqual(
            restarted.traces[sourceTraceID]?.status,
            .completed
        )
        XCTAssertFalse(
            restarted.taskPool().contains {
                $0.chain.id == copiedChainID
            }
        )
        XCTAssertNoThrow(try restarted.snapshot().validateIntegrity())
    }

    private func temporaryDatabaseURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noonmark-snapshot-undo-\(UUID().uuidString).sqlite"
            )
        addTeardownBlock {
            for candidate in [
                url,
                URL(fileURLWithPath: url.path + "-wal"),
                URL(fileURLWithPath: url.path + "-shm")
            ] {
                try? FileManager.default.removeItem(at: candidate)
            }
        }
        return url
    }
}
