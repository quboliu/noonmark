@testable import NoonmarkCore
@testable import NoonmarkSync
import XCTest

final class SyncRecordMergerAtomicityRegressionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let today = LocalDate("2026-07-05")

    func testSameIDCompletionUndoCanonicalizationUsesUnlockedDaySnapshotContext() throws {
        let completed = NoonmarkEngine()
        let chainID = try completed.createPoolTask(
            title: "同 ID 完成撤销",
            now: now
        )
        let traceID = try completed.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )
        try completed.markCompleted(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(10)
        )
        let completedSnapshot = completed.snapshot()

        let undone = try NoonmarkEngine(snapshot: completedSnapshot)
        try undone.undoCompleted(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(20)
        )

        let mapper = SyncRecordMapper()
        let completedRecord = try mapper.record(
            for: XCTUnwrap(completed.traces[traceID]),
            modifiedBy: SyncDeviceID("completed-device")
        )
        let undoRecord = try mapper.record(
            for: XCTUnwrap(undone.traces[traceID]),
            modifiedBy: SyncDeviceID("undo-device")
        )
        XCTAssertEqual(completedRecord.id, undoRecord.id)

        for records in [
            [completedRecord, undoRecord],
            [undoRecord, completedRecord]
        ] {
            let result = try SyncRecordMerger(mapper: mapper).merge(
                records: records,
                into: completedSnapshot,
                detectedAt: now.addingTimeInterval(30)
            )

            XCTAssertTrue(result.conflicts.isEmpty)
            XCTAssertTrue(result.waitingRecords.isEmpty)
            XCTAssertEqual(result.appliedRecordIDs, [undoRecord.id])
            XCTAssertEqual(
                result.snapshot.traces.first { $0.id == traceID }?.status,
                .pending
            )
            XCTAssertNil(
                result.snapshot.traces.first { $0.id == traceID }?
                    .completedAt
            )
        }
    }

    func testCompleteChainComponentAppliesIndependentlyOfIncompleteSibling() throws {
        let source = NoonmarkEngine()
        let completeChainID = try source.createPoolTask(
            title: "完整组件",
            now: now
        )
        let incompleteChainID = try source.createPoolTask(
            title: "不完整组件",
            now: now.addingTimeInterval(1)
        )
        let snapshot = source.snapshot()
        let completeDefinition = try XCTUnwrap(
            snapshot.definitions.first { $0.chainID == completeChainID }
        )
        let mapper = SyncRecordMapper()
        let completeChainRecord = try mapper.record(
            for: XCTUnwrap(source.chains[completeChainID]),
            modifiedBy: SyncDeviceID("complete-chain-device")
        )
        let completeDefinitionRecord = try mapper.record(
            for: completeDefinition,
            modifiedBy: SyncDeviceID("complete-definition-device")
        )
        let incompleteChainRecord = try mapper.record(
            for: XCTUnwrap(source.chains[incompleteChainID]),
            modifiedBy: SyncDeviceID("incomplete-chain-device")
        )

        let result = try SyncRecordMerger(mapper: mapper).merge(
            records: [
                incompleteChainRecord,
                completeDefinitionRecord,
                completeChainRecord
            ],
            into: NoonmarkEngine().snapshot(),
            detectedAt: now.addingTimeInterval(10)
        )

        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(
            Set(result.appliedRecordIDs),
            Set([completeChainRecord.id, completeDefinitionRecord.id])
        )
        XCTAssertEqual(
            Set(result.snapshot.chains.map(\.id)),
            [completeChainID]
        )
        XCTAssertEqual(
            Set(result.snapshot.definitions.map(\.id)),
            [completeDefinition.id]
        )
        XCTAssertEqual(
            result.waitingRecords,
            [
                SyncWaitingRecord(
                    record: incompleteChainRecord,
                    dependencies: [.currentSnapshotIntegrity]
                )
            ]
        )
        XCTAssertNoThrow(try result.snapshot.validateIntegrity())
    }

    func testRolledBackChainAndDefinitionRetainOneAtomicExternalDependency() throws {
        let source = NoonmarkEngine()
        let chainID = try source.createPoolTask(
            title: "回滚后依赖重算",
            now: now
        )
        let successorID = TaskDefinitionID(
            UUID(uuidString: "A1000000-0000-0000-0000-000000000001")!
        )
        var definition = try XCTUnwrap(
            source.definitions.values.first { $0.chainID == chainID }
        )
        let supersededAt = now.addingTimeInterval(1)
        definition.supersededAt = supersededAt
        definition.supersededByDefinitionID = successorID
        try definition.markContentModified(at: supersededAt)

        let mapper = SyncRecordMapper()
        let chainRecord = try mapper.record(
            for: XCTUnwrap(source.chains[chainID]),
            modifiedBy: SyncDeviceID("chain-device")
        )
        let definitionRecord = try mapper.record(
            for: definition,
            modifiedBy: SyncDeviceID("definition-device")
        )

        let result = try SyncRecordMerger(mapper: mapper).merge(
            records: [definitionRecord, chainRecord],
            into: NoonmarkEngine().snapshot(),
            detectedAt: now.addingTimeInterval(2)
        )

        XCTAssertEqual(result.snapshot, NoonmarkEngine().snapshot())
        XCTAssertTrue(result.appliedRecordIDs.isEmpty)
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(
            Set(result.waitingRecords.map(\.remoteRecordID)),
            [chainRecord.id, definitionRecord.id]
        )
        XCTAssertEqual(
            result.waitingRecords.map(\.dependencies),
            Array(
                repeating: [.taskDefinition(successorID)],
                count: 2
            )
        )
    }

    func testUnmergeableSameIDVariantsEachReceiveAnExactEvidenceOutcome() throws {
        let source = NoonmarkEngine()
        let chainID = try source.createPoolTask(
            title: "同 ID variant",
            now: now
        )
        let originalChain = try XCTUnwrap(source.chains[chainID])
        var collidingChain = originalChain
        collidingChain.createdAt = now.addingTimeInterval(1)
        collidingChain.updatedAt = now.addingTimeInterval(1)

        let mapper = SyncRecordMapper()
        let originalRecord = try mapper.record(
            for: originalChain,
            modifiedBy: SyncDeviceID("original-device")
        )
        let collidingRecord = try mapper.record(
            for: collidingChain,
            modifiedBy: SyncDeviceID("collision-device")
        )
        XCTAssertEqual(originalRecord.id, collidingRecord.id)
        XCTAssertFalse(originalRecord.exactlyMatches(collidingRecord))

        let result = try SyncRecordMerger(mapper: mapper).merge(
            records: [originalRecord, collidingRecord],
            into: NoonmarkEngine().snapshot(),
            detectedAt: now.addingTimeInterval(2)
        )

        XCTAssertEqual(result.snapshot, NoonmarkEngine().snapshot())
        XCTAssertTrue(result.appliedRecordIDs.isEmpty)
        XCTAssertTrue(result.waitingRecords.isEmpty)
        XCTAssertEqual(result.conflicts.count, 2)
        XCTAssertEqual(Set(result.conflicts.map(\.id)).count, 2)
        for record in [originalRecord, collidingRecord] {
            XCTAssertTrue(
                result.conflicts.contains {
                    $0.remoteRecord.exactlyMatches(record)
                },
                "every exact same-ID variant must have an auditable outcome"
            )
        }
    }

    func testSubtaskPositionCollisionIsConflictRatherThanDependencyFreeWaiting() throws {
        let base = NoonmarkEngine()
        let chainID = try base.createPoolTask(
            title: "位置冲突",
            now: now
        )
        let traceID = try base.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now
        )
        let baseSnapshot = base.snapshot()
        let firstBranch = try NoonmarkEngine(snapshot: baseSnapshot)
        let secondBranch = try NoonmarkEngine(snapshot: baseSnapshot)
        let firstID = try firstBranch.addSubtask(
            traceID: traceID,
            title: "位置一甲",
            now: now.addingTimeInterval(1)
        )
        let secondID = try secondBranch.addSubtask(
            traceID: traceID,
            title: "位置一乙",
            now: now.addingTimeInterval(1)
        )
        let mapper = SyncRecordMapper()
        let records = [
            try mapper.record(
                for: XCTUnwrap(firstBranch.subtasks[firstID]),
                modifiedBy: SyncDeviceID("first-branch")
            ),
            try mapper.record(
                for: XCTUnwrap(secondBranch.subtasks[secondID]),
                modifiedBy: SyncDeviceID("second-branch")
            )
        ]

        let result = try SyncRecordMerger(mapper: mapper).merge(
            records: records,
            into: baseSnapshot,
            detectedAt: now.addingTimeInterval(2)
        )

        XCTAssertEqual(result.snapshot, baseSnapshot)
        XCTAssertTrue(result.appliedRecordIDs.isEmpty)
        XCTAssertTrue(result.waitingRecords.isEmpty)
        XCTAssertEqual(result.conflicts.count, 2)
        XCTAssertEqual(Set(result.conflicts.map(\.remoteRecordID)), Set(records.map(\.id)))
        XCTAssertEqual(Set(result.conflicts.map(\.type)), [.invalidRecordPayload])
    }

    func testMergeOutcomesAreCanonicalUniqueAndMutuallyExclusive() throws {
        let base = NoonmarkEngine()
        let chainID = try base.createPoolTask(
            title: "结果规范化",
            now: now
        )
        let traceID = try base.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now
        )
        let mapper = SyncRecordMapper()

        let firstPreferenceDevice = SyncDeviceID("preference-first")
        let firstPreference = try mapper.record(
            for: AppPreferencesEnvelope(
                theme: .warmPaper,
                language: .chinese,
                updatedAt: now.addingTimeInterval(1),
                writerDeviceID: firstPreferenceDevice
            ),
            modifiedBy: firstPreferenceDevice
        )
        let finalPreferenceDevice = SyncDeviceID("preference-final")
        let finalPreference = try mapper.record(
            for: AppPreferencesEnvelope(
                theme: .warmPaper,
                language: .english,
                updatedAt: now.addingTimeInterval(2),
                writerDeviceID: finalPreferenceDevice
            ),
            modifiedBy: finalPreferenceDevice
        )
        XCTAssertEqual(firstPreference.id, finalPreference.id)

        let orphan = Subtask(
            traceID: DayTraceID(
                UUID(uuidString: "A2000000-0000-0000-0000-000000000001")!
            ),
            title: "重复等待",
            position: 1,
            now: now
        )
        let orphanRecord = try mapper.record(
            for: orphan,
            modifiedBy: SyncDeviceID("orphan-device")
        )

        let invalidSubtask = Subtask(
            traceID: traceID,
            title: "重复冲突",
            position: 1,
            now: now
        )
        var invalidRecord = try mapper.record(
            for: invalidSubtask,
            modifiedBy: SyncDeviceID("invalid-device")
        )
        invalidRecord.modifiedAt = now.addingTimeInterval(1)

        let result = try SyncRecordMerger(mapper: mapper).merge(
            records: [
                firstPreference,
                finalPreference,
                orphanRecord,
                orphanRecord,
                invalidRecord,
                invalidRecord
            ],
            into: base.snapshot(),
            detectedAt: now.addingTimeInterval(3)
        )

        XCTAssertEqual(result.appliedRecordIDs, [finalPreference.id])
        XCTAssertEqual(
            result.waitingRecords,
            [
                SyncWaitingRecord(
                    record: orphanRecord,
                    dependencies: [.dayTrace(orphan.traceID)]
                )
            ]
        )
        XCTAssertEqual(result.conflicts.count, 1)
        XCTAssertTrue(
            result.conflicts[0].remoteRecord.exactlyMatches(invalidRecord)
        )

        let applied = Set(result.appliedRecordIDs)
        let waiting = Set(result.waitingRecords.map(\.remoteRecordID))
        let conflicted = Set(result.conflicts.map(\.remoteRecordID))
        XCTAssertTrue(applied.isDisjoint(with: waiting))
        XCTAssertTrue(applied.isDisjoint(with: conflicted))
        XCTAssertTrue(waiting.isDisjoint(with: conflicted))
        XCTAssertEqual(result.snapshot.preferences.theme, .warmPaper)
        XCTAssertEqual(result.snapshot.preferences.language, .english)
        XCTAssertNoThrow(try result.snapshot.validateIntegrity())
    }
}
