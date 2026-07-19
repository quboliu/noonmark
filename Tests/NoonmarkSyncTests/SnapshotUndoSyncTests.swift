@testable import NoonmarkCore
@testable import NoonmarkSync
import XCTest

final class SnapshotUndoSyncTests: XCTestCase {
    private let today = LocalDate("2026-07-16")
    private let base = Date(timeIntervalSinceReferenceDate: 920_000)
    private let mapper = SyncRecordMapper()

    func testSubtaskCreationAndCancellationConvergeInBothInputOrders() throws {
        let fixture = try makeSubtaskCancellationFixture()
        let creationRecord = try mapper.record(
            for: fixture.created,
            modifiedBy: SyncDeviceID("creator")
        )
        let cancellationRecord = try mapper.record(
            for: fixture.cancelled,
            modifiedBy: SyncDeviceID("undoer")
        )

        for records in [
            [creationRecord, cancellationRecord],
            [cancellationRecord, creationRecord]
        ] {
            let result = try SyncRecordMerger(mapper: mapper).merge(
                records: records,
                into: fixture.baseline,
                detectedAt: base.addingTimeInterval(10)
            )
            XCTAssertTrue(result.conflicts.isEmpty)
            let engine = try NoonmarkEngine(snapshot: result.snapshot)
            XCTAssertEqual(
                engine.subtasks[fixture.created.id]?.status,
                .cancelledDraft
            )
            XCTAssertEqual(
                engine.subtasks[fixture.created.id]?.draftCancellationID,
                fixture.cancelled.draftCancellationID
            )
            XCTAssertEqual(
                engine.subtaskProgress(for: fixture.created.traceID).total,
                0
            )
        }
    }

    func testSubtaskRedoBeatsCancellationInBothInputOrders() throws {
        let fixture = try makeSubtaskCancellationFixture()
        let redoneEngine = try NoonmarkEngine(
            snapshot: fixture.createdSnapshot
        )
        try redoneEngine.prepareSnapshotUndo(
            replacing: fixture.cancelledSnapshot,
            now: base.addingTimeInterval(3)
        )
        let redone = try XCTUnwrap(
            redoneEngine.subtasks[fixture.created.id]
        )
        let cancellationRecord = try mapper.record(
            for: fixture.cancelled,
            modifiedBy: SyncDeviceID("undoer")
        )
        let redoRecord = try mapper.record(
            for: redone,
            modifiedBy: SyncDeviceID("redoer")
        )

        for records in [
            [cancellationRecord, redoRecord],
            [redoRecord, cancellationRecord]
        ] {
            let result = try SyncRecordMerger(mapper: mapper).merge(
                records: records,
                into: fixture.baseline,
                detectedAt: base.addingTimeInterval(10)
            )
            XCTAssertTrue(result.conflicts.isEmpty)
            let restored = try XCTUnwrap(
                result.snapshot.subtasks.first {
                    $0.id == fixture.created.id
                }
            )
            XCTAssertEqual(restored.status, .pending)
            XCTAssertEqual(
                restored.draftCancellationID,
                fixture.cancelled.draftCancellationID
            )
            XCTAssertEqual(
                restored.updatedAt
                    .timeIntervalSinceReferenceDate.bitPattern,
                redone.updatedAt
                    .timeIntervalSinceReferenceDate.bitPattern
            )
        }
    }

    func testNewerPendingWithoutCancellationWitnessCannotResurrectSubtask() throws {
        let fixture = try makeSubtaskCancellationFixture()
        var forged = fixture.created
        forged.updatedAt = base.addingTimeInterval(100)
        let cancellationRecord = try mapper.record(
            for: fixture.cancelled,
            modifiedBy: SyncDeviceID("undoer")
        )
        let forgedRecord = try mapper.record(
            for: forged,
            modifiedBy: SyncDeviceID("offline")
        )

        let merged = try CurrentSyncRecordMerger(mapper: mapper).merge(
            existing: cancellationRecord,
            incoming: forgedRecord
        )

        XCTAssertEqual(
            try mapper.decodeSubtask(merged).status,
            .cancelledDraft
        )
    }

    func testWholeTaskCancellationAndRedoConvergeThroughJournalRecords() throws {
        let before = NoonmarkEngine().snapshot()
        let forwardEngine = NoonmarkEngine()
        let chainID = try forwardEngine.createPoolTask(
            title: "同步撤销整条任务",
            now: base
        )
        let traceID = try forwardEngine.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: base
        )
        let forward = forwardEngine.snapshot()

        let undoneEngine = try NoonmarkEngine(snapshot: before)
        let undoAt = base.addingTimeInterval(1)
        try undoneEngine.prepareSnapshotUndo(
            replacing: forward,
            now: undoAt
        )
        let undone = undoneEngine.snapshot()
        let undoEntries = try SyncSnapshotDiffer(mapper: mapper)
            .journalEntries(
                from: forward,
                to: undone,
                changedAt: undoAt,
                deviceID: SyncDeviceID("undoer")
            )
        let undoRecords = try SyncRecordMaterializer(mapper: mapper)
            .records(for: undoEntries, in: undone)
        let cancelledResult = try SyncRecordMerger(mapper: mapper).merge(
            records: Array(undoRecords.reversed()),
            into: forward,
            detectedAt: base.addingTimeInterval(10)
        )

        XCTAssertTrue(cancelledResult.conflicts.isEmpty)
        XCTAssertEqual(
            cancelledResult.snapshot.chains.first {
                $0.id == chainID
            }?.state,
            .abandoned
        )
        XCTAssertEqual(
            cancelledResult.snapshot.traces.first {
                $0.id == traceID
            }?.status,
            .cancelledDraft
        )

        let redoneEngine = try NoonmarkEngine(snapshot: forward)
        let redoAt = base.addingTimeInterval(2)
        try redoneEngine.prepareSnapshotUndo(
            replacing: undone,
            now: redoAt
        )
        let redone = redoneEngine.snapshot()
        let redoEntries = try SyncSnapshotDiffer(mapper: mapper)
            .journalEntries(
                from: undone,
                to: redone,
                changedAt: redoAt,
                deviceID: SyncDeviceID("redoer")
            )
        let redoRecords = try SyncRecordMaterializer(mapper: mapper)
            .records(for: redoEntries, in: redone)
        let restoredResult = try SyncRecordMerger(mapper: mapper).merge(
            records: Array(redoRecords.reversed()),
            into: undone,
            detectedAt: base.addingTimeInterval(11)
        )

        XCTAssertTrue(restoredResult.conflicts.isEmpty)
        XCTAssertEqual(
            restoredResult.snapshot.chains.first {
                $0.id == chainID
            }?.state,
            .active
        )
        XCTAssertEqual(
            restoredResult.snapshot.traces.first {
                $0.id == traceID
            }?.status,
            .pending
        )
    }

    func testPoolOnlyTaskRedoUsesChainOnlyReactivationWitness() throws {
        let before = NoonmarkEngine().snapshot()
        let forwardEngine = NoonmarkEngine()
        let chainID = try forwardEngine.createPoolTask(
            title: "同步撤销池任务",
            now: base
        )
        let forward = forwardEngine.snapshot()
        let undoneEngine = try NoonmarkEngine(snapshot: before)
        try undoneEngine.prepareSnapshotUndo(
            replacing: forward,
            now: base.addingTimeInterval(1)
        )
        let undone = undoneEngine.snapshot()
        let redoneEngine = try NoonmarkEngine(snapshot: forward)
        let redoAt = base.addingTimeInterval(2)
        try redoneEngine.prepareSnapshotUndo(
            replacing: undone,
            now: redoAt
        )
        let redone = redoneEngine.snapshot()

        let entries = try SyncSnapshotDiffer(mapper: mapper)
            .journalEntries(
                from: undone,
                to: redone,
                changedAt: redoAt,
                deviceID: SyncDeviceID("redoer")
            )
        let records = try SyncRecordMaterializer(mapper: mapper)
            .records(for: entries, in: redone)
        let chainRecord = try XCTUnwrap(
            records.first { $0.entityType == .taskChain }
        )
        let result = try SyncRecordMerger(mapper: mapper).merge(
            records: records,
            into: undone,
            detectedAt: base.addingTimeInterval(10)
        )

        XCTAssertEqual(chainRecord.reactivationWitnesses.count, 1)
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(
            result.snapshot.chains.first { $0.id == chainID }?.state,
            .active
        )
        XCTAssertEqual(
            try NoonmarkEngine(snapshot: result.snapshot)
                .taskPool().map(\.chain.id),
            [chainID]
        )
    }

    func testUnclassifiedCopiedTaskUndoConvergesWithoutResurrectionInBothInputOrders() throws {
        let source = NoonmarkEngine()
        let sourceChainID = try source.createPoolTask(
            title: "同步未分类复制来源",
            now: base
        )
        let sourceTraceID = try source.scheduleFromPool(
            chainID: sourceChainID,
            date: today,
            today: today,
            now: base
        )
        try source.markCompleted(
            traceID: sourceTraceID,
            today: today,
            now: base.addingTimeInterval(1)
        )
        let beforeCopy = source.snapshot()
        let copiedChainID = try source.copyAsNewTask(
            from: sourceTraceID,
            target: .taskPool,
            today: today,
            now: base.addingTimeInterval(2)
        )
        let copiedDefinition = try XCTUnwrap(
            source.definitions.values.first {
                $0.chainID == copiedChainID
            }
        )
        let copiedCreation = try XCTUnwrap(source.chains[copiedChainID])
        let forward = source.snapshot()

        _ = try source.removeTaskFromPool(
            chainID: copiedChainID,
            now: base.addingTimeInterval(3)
        )
        let undone = source.snapshot()
        let entries = try SyncSnapshotDiffer(mapper: mapper)
            .journalEntries(
                from: forward,
                to: undone,
                changedAt: base.addingTimeInterval(3),
                deviceID: SyncDeviceID("undoer")
            )
        let removalRecord = try XCTUnwrap(
            SyncRecordMaterializer(mapper: mapper)
                .records(for: entries, in: undone)
                .first { $0.entityType == .taskChain }
        )
        let creationRecord = try mapper.record(
            for: copiedCreation,
            modifiedBy: SyncDeviceID("creator")
        )
        let definitionRecord = try mapper.record(
            for: copiedDefinition,
            modifiedBy: SyncDeviceID("creator")
        )

        for records in [
            [definitionRecord, creationRecord, removalRecord],
            [removalRecord, creationRecord, definitionRecord]
        ] {
            let result = try SyncRecordMerger(mapper: mapper).merge(
                records: records,
                into: beforeCopy,
                detectedAt: base.addingTimeInterval(10)
            )
            XCTAssertTrue(result.conflicts.isEmpty)
            XCTAssertTrue(result.waitingRecords.isEmpty)
            let merged = try NoonmarkEngine(snapshot: result.snapshot)
            XCTAssertEqual(
                merged.chains[copiedChainID]?.state,
                .abandoned
            )
            XCTAssertEqual(
                merged.definitions[copiedDefinition.id]?.chainID,
                copiedChainID
            )
            XCTAssertEqual(
                merged.traces[sourceTraceID]?.status,
                .completed
            )
            XCTAssertFalse(
                merged.taskPool().contains {
                    $0.chain.id == copiedChainID
                }
            )
        }
    }

    func testUnscheduledPoolRemovalConvergesWithoutResurrectionInBothInputOrders() throws {
        let baseline = NoonmarkEngine().snapshot()
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "同步未排程删除",
            now: base
        )
        let creationChain = try XCTUnwrap(engine.chains[chainID])
        let definition = try XCTUnwrap(
            engine.definitions.values.first {
                $0.chainID == chainID
            }
        )
        let forward = engine.snapshot()

        _ = try engine.removeTaskFromPool(
            chainID: chainID,
            now: base.addingTimeInterval(1)
        )
        let removed = engine.snapshot()
        let entries = try SyncSnapshotDiffer(mapper: mapper)
            .journalEntries(
                from: forward,
                to: removed,
                changedAt: base.addingTimeInterval(1),
                deviceID: SyncDeviceID("remover")
            )
        let removalRecord = try XCTUnwrap(
            SyncRecordMaterializer(mapper: mapper)
                .records(for: entries, in: removed)
                .first { $0.entityType == .taskChain }
        )
        let creationRecord = try mapper.record(
            for: creationChain,
            modifiedBy: SyncDeviceID("creator")
        )
        let definitionRecord = try mapper.record(
            for: definition,
            modifiedBy: SyncDeviceID("creator")
        )

        for records in [
            [definitionRecord, creationRecord, removalRecord],
            [removalRecord, creationRecord, definitionRecord]
        ] {
            let result = try SyncRecordMerger(mapper: mapper).merge(
                records: records,
                into: baseline,
                detectedAt: base.addingTimeInterval(10)
            )
            XCTAssertTrue(result.conflicts.isEmpty)
            XCTAssertTrue(result.waitingRecords.isEmpty)
            let merged = try NoonmarkEngine(snapshot: result.snapshot)
            XCTAssertEqual(merged.chains[chainID]?.state, .abandoned)
            XCTAssertEqual(
                merged.definitions[definition.id]?.chainID,
                chainID
            )
            XCTAssertTrue(merged.taskPool().isEmpty)
        }
    }

    func testPoolOnlyRedoIgnoresMultipleUnchangedCancelledDraftTombstones() throws {
        let secondFutureDate = LocalDate("2026-07-18")
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "同步多取消草稿池任务",
            now: base
        )
        let firstTraceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: LocalDate("2026-07-17"),
            today: today,
            now: base.addingTimeInterval(1)
        )
        try engine.returnToPool(
            traceID: firstTraceID,
            today: today,
            now: base.addingTimeInterval(2)
        )
        let secondTraceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: secondFutureDate,
            today: today,
            now: base.addingTimeInterval(3)
        )
        try engine.returnToPool(
            traceID: secondTraceID,
            today: today,
            now: base.addingTimeInterval(4)
        )
        let activeWithTombstones = engine.snapshot()
        _ = try engine.removeTaskFromPool(
            chainID: chainID,
            now: base.addingTimeInterval(5)
        )
        let abandoned = engine.snapshot()

        let redoneEngine = try NoonmarkEngine(
            snapshot: activeWithTombstones
        )
        let redoAt = base.addingTimeInterval(6)
        try redoneEngine.prepareSnapshotUndo(
            replacing: abandoned,
            now: redoAt
        )
        let redone = redoneEngine.snapshot()
        let entries = try SyncSnapshotDiffer(mapper: mapper)
            .journalEntries(
                from: abandoned,
                to: redone,
                changedAt: redoAt,
                deviceID: SyncDeviceID("redoer")
            )
        let chainRecord = try XCTUnwrap(
            SyncRecordMaterializer(mapper: mapper)
                .records(for: entries, in: redone)
                .first { $0.entityType == .taskChain }
        )
        let abandonedRecord = try mapper.record(
            for: XCTUnwrap(
                abandoned.chains.first { $0.id == chainID }
            ),
            modifiedBy: SyncDeviceID("undoer")
        )

        XCTAssertEqual(chainRecord.reactivationWitnesses.count, 1)
        for records in [
            [abandonedRecord, chainRecord],
            [chainRecord, abandonedRecord]
        ] {
            let result = try SyncRecordMerger(mapper: mapper).merge(
                records: records,
                into: abandoned,
                detectedAt: base.addingTimeInterval(10)
            )
            XCTAssertTrue(result.conflicts.isEmpty)
            XCTAssertTrue(result.waitingRecords.isEmpty)
            let merged = try NoonmarkEngine(snapshot: result.snapshot)
            XCTAssertEqual(merged.chains[chainID]?.state, .active)
            XCTAssertEqual(
                merged.traces[firstTraceID]?.status,
                .cancelledDraft
            )
            XCTAssertEqual(
                merged.traces[secondTraceID]?.status,
                .cancelledDraft
            )
            XCTAssertEqual(merged.taskPool().map(\.chain.id), [chainID])
        }
    }

    private func makeSubtaskCancellationFixture() throws -> (
        baseline: NoonmarkSnapshot,
        createdSnapshot: NoonmarkSnapshot,
        cancelledSnapshot: NoonmarkSnapshot,
        created: Subtask,
        cancelled: Subtask
    ) {
        let current = NoonmarkEngine()
        let chainID = try current.createPoolTask(
            title: "同步撤销新增子任务",
            now: base
        )
        let traceID = try current.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: base
        )
        let baseline = current.snapshot()
        let subtaskID = try current.addSubtask(
            traceID: traceID,
            title: "同步取消墓碑",
            now: base.addingTimeInterval(1)
        )
        let createdSnapshot = current.snapshot()
        let created = try XCTUnwrap(current.subtasks[subtaskID])

        let undone = try NoonmarkEngine(snapshot: baseline)
        try undone.prepareSnapshotUndo(
            replacing: createdSnapshot,
            now: base.addingTimeInterval(2)
        )
        let cancelledSnapshot = undone.snapshot()
        let cancelled = try XCTUnwrap(undone.subtasks[subtaskID])
        return (
            baseline,
            createdSnapshot,
            cancelledSnapshot,
            created,
            cancelled
        )
    }
}
