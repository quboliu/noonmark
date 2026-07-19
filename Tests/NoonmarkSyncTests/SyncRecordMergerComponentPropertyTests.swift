@testable import NoonmarkCore
@testable import NoonmarkSync
import XCTest

final class SyncRecordMergerComponentPropertyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let today = LocalDate("2026-07-05")

    func testCompleteAndIncompleteChainComponentsConvergeAcrossEveryInputPermutation() throws {
        let source = NoonmarkEngine()
        let completeChainID = try source.createPoolTask(
            title: "完整组件",
            now: now
        )
        let incompleteChainID = try source.createPoolTask(
            title: "不完整组件",
            now: now.addingTimeInterval(1)
        )
        let sourceSnapshot = source.snapshot()
        let completeDefinition = try XCTUnwrap(
            sourceSnapshot.definitions.first { $0.chainID == completeChainID }
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
        let records = [
            completeChainRecord,
            completeDefinitionRecord,
            incompleteChainRecord
        ]
        let original = NoonmarkEngine().snapshot()
        let merger = SyncRecordMerger(mapper: mapper)
        let detectedAt = now.addingTimeInterval(10)
        let expected = try merger.merge(
            records: records,
            into: original,
            detectedAt: detectedAt
        )

        XCTAssertEqual(
            Set(expected.appliedRecordIDs),
            Set([completeChainRecord.id, completeDefinitionRecord.id])
        )
        XCTAssertEqual(
            expected.waitingRecords,
            [
                SyncWaitingRecord(
                    record: incompleteChainRecord,
                    dependencies: [.currentSnapshotIntegrity]
                )
            ]
        )
        XCTAssertTrue(expected.conflicts.isEmpty)
        XCTAssertEqual(Set(expected.snapshot.chains.map(\.id)), [completeChainID])
        XCTAssertEqual(
            Set(expected.snapshot.definitions.map(\.id)),
            [completeDefinition.id]
        )
        XCTAssertNoThrow(try expected.snapshot.validateIntegrity())

        for permutation in permutations(of: records) {
            let result = try merger.merge(
                records: permutation,
                into: original,
                detectedAt: detectedAt
            )

            XCTAssertEqual(
                result,
                expected,
                "chain components must converge for input order \(permutation.map(\.id))"
            )
            XCTAssertNoThrow(try result.snapshot.validateIntegrity())
        }
    }

    func testConcurrentPositionOneSiblingsConflictCanonicallyInBothOrders() throws {
        let base = NoonmarkEngine()
        let chainID = try base.createPoolTask(
            title: "并发位置冲突",
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
        let merger = SyncRecordMerger(mapper: mapper)
        let detectedAt = now.addingTimeInterval(2)
        let expected = try merger.merge(
            records: records,
            into: baseSnapshot,
            detectedAt: detectedAt
        )

        XCTAssertEqual(expected.snapshot, baseSnapshot)
        XCTAssertTrue(expected.appliedRecordIDs.isEmpty)
        XCTAssertTrue(expected.waitingRecords.isEmpty)
        XCTAssertEqual(expected.conflicts.count, 2)
        XCTAssertEqual(
            Set(expected.conflicts.map(\.remoteRecordID)),
            Set(records.map(\.id))
        )
        XCTAssertEqual(Set(expected.conflicts.map(\.type)), [.invalidRecordPayload])
        XCTAssertNoThrow(try expected.snapshot.validateIntegrity())

        for permutation in permutations(of: records) {
            let result = try merger.merge(
                records: permutation,
                into: baseSnapshot,
                detectedAt: detectedAt
            )

            XCTAssertEqual(
                result,
                expected,
                "sibling collision evidence must not depend on input order"
            )
            XCTAssertNoThrow(try result.snapshot.validateIntegrity())
        }
    }

    func testCompletionUndoSameIDHasOneExactCanonicalOutcomeInBothOrders() throws {
        let completed = NoonmarkEngine()
        let chainID = try completed.createPoolTask(
            title: "完成撤销 exact outcome",
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
        let undoneTrace = try XCTUnwrap(undone.traces[traceID])

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
        XCTAssertFalse(completedRecord.exactlyMatches(undoRecord))

        let merger = SyncRecordMerger(mapper: mapper)
        let detectedAt = now.addingTimeInterval(30)
        let expected = try merger.merge(
            records: [completedRecord, undoRecord],
            into: completedSnapshot,
            detectedAt: detectedAt
        )
        var expectedSnapshot = completedSnapshot
        expectedSnapshot.traces = completedSnapshot.traces.map {
            $0.id == traceID ? undoneTrace : $0
        }

        XCTAssertEqual(expected.snapshot, expectedSnapshot)
        XCTAssertEqual(expected.appliedRecordIDs, [undoRecord.id])
        XCTAssertTrue(expected.waitingRecords.isEmpty)
        XCTAssertTrue(expected.conflicts.isEmpty)
        assertCanonicalOutcomeSets(expected)
        XCTAssertNoThrow(try expected.snapshot.validateIntegrity())

        for permutation in permutations(of: [completedRecord, undoRecord]) {
            let result = try merger.merge(
                records: permutation,
                into: completedSnapshot,
                detectedAt: detectedAt
            )

            XCTAssertEqual(
                result,
                expected,
                "completion undo must choose one exact outcome for its shared record ID"
            )
            assertCanonicalOutcomeSets(result)
            XCTAssertNoThrow(try result.snapshot.validateIntegrity())
        }
    }

    func testDuplicateInputsPreserveCanonicalUniqueDisjointOutcomes() throws {
        let base = NoonmarkEngine()
        let chainID = try base.createPoolTask(
            title: "重复输入性质",
            now: now
        )
        let traceID = try base.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now
        )
        let baseSnapshot = base.snapshot()
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

        let missingTraceID = DayTraceID(
            UUID(uuidString: "A2000000-0000-0000-0000-000000000001")!
        )
        let orphan = Subtask(
            traceID: missingTraceID,
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

        let merger = SyncRecordMerger(mapper: mapper)
        let detectedAt = now.addingTimeInterval(3)
        let expected = try merger.merge(
            records: [
                firstPreference,
                finalPreference,
                orphanRecord,
                invalidRecord
            ],
            into: baseSnapshot,
            detectedAt: detectedAt
        )

        XCTAssertEqual(expected.appliedRecordIDs, [finalPreference.id])
        XCTAssertEqual(
            expected.waitingRecords,
            [
                SyncWaitingRecord(
                    record: orphanRecord,
                    dependencies: [.dayTrace(missingTraceID)]
                )
            ]
        )
        XCTAssertEqual(expected.conflicts.count, 1)
        XCTAssertTrue(
            expected.conflicts[0].remoteRecord.exactlyMatches(invalidRecord)
        )
        XCTAssertEqual(expected.snapshot.preferences.theme, .warmPaper)
        XCTAssertEqual(expected.snapshot.preferences.language, .english)
        assertCanonicalOutcomeSets(expected)
        XCTAssertNoThrow(try expected.snapshot.validateIntegrity())

        var trial: UInt64 = 0
        for firstCount in 1 ... 3 {
            for finalCount in 1 ... 3 {
                for orphanCount in 1 ... 3 {
                    for invalidCount in 1 ... 3 {
                        trial += 1
                        let records = Array(repeating: firstPreference, count: firstCount)
                            + Array(repeating: finalPreference, count: finalCount)
                            + Array(repeating: orphanRecord, count: orphanCount)
                            + Array(repeating: invalidRecord, count: invalidCount)
                        let shuffled = seededShuffle(
                            records,
                            seed: 0x4E4F_4F4E_4D41_524B &+ trial
                        )
                        let result = try merger.merge(
                            records: shuffled,
                            into: baseSnapshot,
                            detectedAt: detectedAt
                        )

                        XCTAssertEqual(
                            result,
                            expected,
                            "exact duplicates must not change canonical outcome in trial \(trial)"
                        )
                        assertCanonicalOutcomeSets(result)
                        XCTAssertNoThrow(try result.snapshot.validateIntegrity())
                    }
                }
            }
        }
        XCTAssertEqual(trial, 81)
    }

    private func assertCanonicalOutcomeSets(
        _ result: SyncMergeResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let applied = result.appliedRecordIDs
        let waiting = result.waitingRecords.map(\.remoteRecordID)
        let conflicted = result.conflicts.map(\.remoteRecordID)

        XCTAssertEqual(Set(applied).count, applied.count, file: file, line: line)
        XCTAssertEqual(Set(waiting).count, waiting.count, file: file, line: line)
        XCTAssertEqual(
            Set(conflicted).count,
            conflicted.count,
            file: file,
            line: line
        )
        XCTAssertEqual(
            Set(result.conflicts.map(\.id)).count,
            result.conflicts.count,
            file: file,
            line: line
        )
        XCTAssertTrue(
            Set(applied).isDisjoint(with: waiting),
            file: file,
            line: line
        )
        XCTAssertTrue(
            Set(applied).isDisjoint(with: conflicted),
            file: file,
            line: line
        )
        XCTAssertTrue(
            Set(waiting).isDisjoint(with: conflicted),
            file: file,
            line: line
        )
    }

    private func permutations<T>(of values: [T]) -> [[T]] {
        guard let first = values.first else { return [[]] }
        return permutations(of: Array(values.dropFirst())).flatMap { tail in
            (0 ... tail.count).map { index in
                var permutation = tail
                permutation.insert(first, at: index)
                return permutation
            }
        }
    }

    private func seededShuffle<T>(_ values: [T], seed: UInt64) -> [T] {
        var shuffled = values
        var generator = DeterministicGenerator(state: seed)
        guard shuffled.count > 1 else { return shuffled }
        for index in stride(from: shuffled.count - 1, through: 1, by: -1) {
            let target = Int(generator.next() % UInt64(index + 1))
            shuffled.swapAt(index, target)
        }
        return shuffled
    }
}

private struct DeterministicGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
