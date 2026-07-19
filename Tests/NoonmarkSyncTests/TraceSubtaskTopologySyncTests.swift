@testable import NoonmarkCore
@testable import NoonmarkSync
import XCTest

final class TraceSubtaskTopologySyncTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_735_689_600)
    private let yesterday = LocalDate("2024-12-31")
    private let today = LocalDate("2025-01-01")
    private let tomorrow = LocalDate("2025-01-02")
    private let mapper = SyncRecordMapper()

    func testCompleteCrossChainContinuationConflictsAtomicallyForEveryInputOrder() throws {
        let fixture = try traceFixture()
        var invalidTarget = fixture.target
        invalidTarget.chainID = fixture.otherChainID
        invalidTarget.definitionID = fixture.otherDefinitionID
        let records = try [fixture.source, invalidTarget].map(record)

        for input in permutations(of: records) {
            let result = try SyncRecordMerger(mapper: mapper).merge(
                records: input,
                into: fixture.baseSnapshot,
                detectedAt: base.addingTimeInterval(10)
            )

            XCTAssertEqual(result.snapshot, fixture.baseSnapshot)
            XCTAssertTrue(result.appliedRecordIDs.isEmpty)
            XCTAssertTrue(result.waitingRecords.isEmpty)
            XCTAssertEqual(
                Set(result.conflicts.map(\.remoteRecordID)),
                Set(records.map(\.id))
            )
        }
    }

    func testCompleteInvalidTraceLinkFactsConflictInsteadOfWaiting() throws {
        let fixture = try traceFixture()

        var wrongSourceStatus = fixture.source
        wrongSourceStatus.status = .pending

        var wrongSequence = fixture.target
        wrongSequence.continuationSeq = fixture.source.continuationSeq

        var wrongDate = fixture.target
        wrongDate.date = yesterday

        var selfChange = fixture.source
        selfChange.status = .changed
        selfChange.changedToTraceID = selfChange.id
        selfChange.settledAt = selfChange.contentUpdatedAt

        let scenarios = [
            [wrongSourceStatus, fixture.target],
            [fixture.source, wrongSequence],
            [fixture.source, wrongDate],
            [selfChange]
        ]
        for traces in scenarios {
            var baseSnapshot = fixture.baseSnapshot
            if traces.contains(where: { $0.date == yesterday }) {
                baseSnapshot.days.append(Day(date: yesterday, now: base))
                baseSnapshot.days.sort { $0.date < $1.date }
            }
            let records = try traces.map(record)
            let result = try SyncRecordMerger(mapper: mapper).merge(
                records: records,
                into: baseSnapshot,
                detectedAt: base.addingTimeInterval(10)
            )

            XCTAssertEqual(result.snapshot, baseSnapshot)
            XCTAssertTrue(result.appliedRecordIDs.isEmpty)
            XCTAssertTrue(result.waitingRecords.isEmpty)
            XCTAssertEqual(
                Set(result.conflicts.map(\.remoteRecordID)),
                Set(records.map(\.id))
            )
        }
    }

    func testMissingTraceAndSubtaskContinuationSourcesRemainTypedWaiting() throws {
        let fixture = try traceFixture()
        var missingTraceTarget = fixture.target
        let missingTraceID = DayTraceID(
            UUID(uuidString: "B1000000-0000-0000-0000-000000000001")!
        )
        missingTraceTarget.continuedFromTraceID = missingTraceID
        let traceRecord = try record(missingTraceTarget)

        let traceResult = try SyncRecordMerger(mapper: mapper).merge(
            records: [traceRecord],
            into: fixture.baseSnapshot,
            detectedAt: base
        )
        XCTAssertTrue(traceResult.appliedRecordIDs.isEmpty)
        XCTAssertTrue(traceResult.conflicts.isEmpty)
        XCTAssertEqual(
            traceResult.waitingRecords,
            [
                SyncWaitingRecord(
                    record: traceRecord,
                    dependencies: [.dayTrace(missingTraceID)]
                )
            ]
        )

        let missingSubtaskID = SubtaskID(
            UUID(uuidString: "B1000000-0000-0000-0000-000000000002")!
        )
        let subtask = Subtask(
            lineageID: SubtaskLineageID(),
            traceID: fixture.target.id,
            title: "等待 source",
            position: 1,
            continuedFromSubtaskID: missingSubtaskID,
            now: base.addingTimeInterval(4)
        )
        let subtaskRecord = try record(subtask)
        var subtaskBase = fixture.baseSnapshot
        subtaskBase.traces = [fixture.source, fixture.target]

        let subtaskResult = try SyncRecordMerger(mapper: mapper).merge(
            records: [subtaskRecord],
            into: subtaskBase,
            detectedAt: base
        )
        XCTAssertTrue(subtaskResult.appliedRecordIDs.isEmpty)
        XCTAssertTrue(subtaskResult.conflicts.isEmpty)
        XCTAssertEqual(
            subtaskResult.waitingRecords,
            [
                SyncWaitingRecord(
                    record: subtaskRecord,
                    dependencies: [.subtask(missingSubtaskID)]
                )
            ]
        )
    }

    func testCompleteInvalidSubtaskLinksConflictAtomicallyWithoutPartialSource() throws {
        let fixture = try traceFixture()
        var subtaskBase = fixture.baseSnapshot
        subtaskBase.traces = [fixture.source, fixture.target]
        let sourceID = SubtaskID(
            UUID(uuidString: "B2000000-0000-0000-0000-000000000001")!
        )
        let targetID = SubtaskID(
            UUID(uuidString: "B2000000-0000-0000-0000-000000000002")!
        )
        let sourceLineageID = SubtaskLineageID(
            UUID(uuidString: "B2000000-0000-0000-0000-000000000003")!
        )
        var source = Subtask(
            id: sourceID,
            lineageID: sourceLineageID,
            traceID: fixture.source.id,
            title: "source",
            status: .continued,
            position: 1,
            now: base.addingTimeInterval(2)
        )
        source.updatedAt = base.addingTimeInterval(3)
        source.settledAt = base.addingTimeInterval(3)
        let target = Subtask(
            id: targetID,
            lineageID: SubtaskLineageID(
                UUID(uuidString: "B2000000-0000-0000-0000-000000000004")!
            ),
            traceID: fixture.target.id,
            title: "target",
            position: 1,
            continuedFromSubtaskID: sourceID,
            now: base.addingTimeInterval(3)
        )
        let records = try [source, target].map(record)

        for input in permutations(of: records) {
            let result = try SyncRecordMerger(mapper: mapper).merge(
                records: input,
                into: subtaskBase,
                detectedAt: base.addingTimeInterval(10)
            )

            XCTAssertEqual(result.snapshot, subtaskBase)
            XCTAssertTrue(result.appliedRecordIDs.isEmpty)
            XCTAssertTrue(result.waitingRecords.isEmpty)
            XCTAssertEqual(
                Set(result.conflicts.map(\.remoteRecordID)),
                Set(records.map(\.id))
            )
        }
    }

    func testSelfAndCyclicSubtaskLinksAreTerminalConflicts() throws {
        let fixture = try traceFixture()
        var subtaskBase = fixture.baseSnapshot
        subtaskBase.traces = [fixture.source, fixture.target]
        let firstID = SubtaskID(
            UUID(uuidString: "B3000000-0000-0000-0000-000000000001")!
        )
        let secondID = SubtaskID(
            UUID(uuidString: "B3000000-0000-0000-0000-000000000002")!
        )
        var selfLinked = Subtask(
            id: firstID,
            traceID: fixture.target.id,
            title: "self",
            position: 1,
            continuedFromSubtaskID: firstID,
            now: base.addingTimeInterval(3)
        )
        let selfRecord = try record(selfLinked)
        var selfResult = try SyncRecordMerger(mapper: mapper).merge(
            records: [selfRecord],
            into: subtaskBase,
            detectedAt: base
        )
        XCTAssertTrue(selfResult.appliedRecordIDs.isEmpty)
        XCTAssertTrue(selfResult.waitingRecords.isEmpty)
        XCTAssertEqual(selfResult.conflicts.map(\.remoteRecordID), [selfRecord.id])

        selfLinked.status = .continued
        selfLinked.updatedAt = base.addingTimeInterval(4)
        selfLinked.settledAt = base.addingTimeInterval(4)
        selfLinked.continuedFromSubtaskID = secondID
        var second = Subtask(
            id: secondID,
            traceID: fixture.source.id,
            title: "cycle",
            status: .continued,
            position: 1,
            continuedFromSubtaskID: firstID,
            now: base.addingTimeInterval(3)
        )
        second.updatedAt = base.addingTimeInterval(4)
        second.settledAt = base.addingTimeInterval(4)
        let cycleRecords = try [selfLinked, second].map(record)
        selfResult = try SyncRecordMerger(mapper: mapper).merge(
            records: cycleRecords,
            into: subtaskBase,
            detectedAt: base
        )
        XCTAssertTrue(selfResult.appliedRecordIDs.isEmpty)
        XCTAssertTrue(selfResult.waitingRecords.isEmpty)
        XCTAssertEqual(
            Set(selfResult.conflicts.map(\.remoteRecordID)),
            Set(cycleRecords.map(\.id))
        )
    }

    func testSnapshotTraceOrderUsesStableIDFallbackForExactClockTies() throws {
        let engine = NoonmarkEngine()
        let firstChainID = try engine.createPoolTask(
            title: "B trace",
            now: base
        )
        let secondChainID = try engine.createPoolTask(
            title: "A trace",
            now: base
        )
        var baseSnapshot = engine.snapshot()
        baseSnapshot.days = [Day(date: today, now: base)]
        let firstDefinitionID = try XCTUnwrap(
            baseSnapshot.definitions.first { $0.chainID == firstChainID }?.id
        )
        let secondDefinitionID = try XCTUnwrap(
            baseSnapshot.definitions.first { $0.chainID == secondChainID }?.id
        )
        let higherID = DayTraceID(
            UUID(uuidString: "F0000000-0000-0000-0000-000000000001")!
        )
        let lowerID = DayTraceID(
            UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        )
        var higher = DayTrace(
            id: higherID,
            chainID: firstChainID,
            definitionID: firstDefinitionID,
            date: today,
            status: .cancelledDraft,
            priority: 1,
            draftCancellationID: UUID(
                uuidString: "B5000000-0000-0000-0000-000000000001"
            ),
            draftCancelledOn: today,
            now: base,
            contentUpdatedAt: base.addingTimeInterval(1)
        )
        higher.settledAt = base.addingTimeInterval(1)
        var lower = DayTrace(
            id: lowerID,
            chainID: secondChainID,
            definitionID: secondDefinitionID,
            date: today,
            status: .cancelledDraft,
            priority: 1,
            draftCancellationID: UUID(
                uuidString: "B5000000-0000-0000-0000-000000000002"
            ),
            draftCancelledOn: today,
            now: base,
            contentUpdatedAt: base.addingTimeInterval(1)
        )
        lower.settledAt = base.addingTimeInterval(1)
        let records = try [higher, lower].map(record)

        for input in permutations(of: records) {
            let result = try SyncRecordMerger(mapper: mapper).merge(
                records: input,
                into: baseSnapshot,
                detectedAt: base
            )
            XCTAssertTrue(result.conflicts.isEmpty)
            XCTAssertTrue(result.waitingRecords.isEmpty)
            XCTAssertEqual(result.snapshot.traces.map(\.id), [lowerID, higherID])
        }
    }

    func testInvalidTraceStatusAndProgressFailAtCurrentRecordBoundary() throws {
        let fixture = try traceFixture()
        var pendingWithCompletion = fixture.target
        pendingWithCompletion.completedAt = pendingWithCompletion.contentUpdatedAt
        var invalidProgress = fixture.target
        invalidProgress.manualProgressPercent = 101

        for trace in [pendingWithCompletion, invalidProgress] {
            let incoming = try record(trace)
            let result = try SyncRecordMerger(mapper: mapper).merge(
                records: [incoming],
                into: fixture.baseSnapshot,
                detectedAt: base
            )

            XCTAssertEqual(result.snapshot, fixture.baseSnapshot)
            XCTAssertTrue(result.appliedRecordIDs.isEmpty)
            XCTAssertTrue(result.waitingRecords.isEmpty)
            XCTAssertEqual(result.conflicts.map(\.remoteRecordID), [incoming.id])
        }
    }

    func testDuplicateVisiblePrioritySlotConflictsAtomicallyAcrossChains() throws {
        let engine = NoonmarkEngine()
        let firstChainID = try engine.createPoolTask(
            title: "slot A",
            now: base
        )
        let secondChainID = try engine.createPoolTask(
            title: "slot B",
            now: base
        )
        var baseSnapshot = engine.snapshot()
        baseSnapshot.days = [Day(date: today, now: base)]
        let firstDefinitionID = try XCTUnwrap(
            baseSnapshot.definitions.first { $0.chainID == firstChainID }?.id
        )
        let secondDefinitionID = try XCTUnwrap(
            baseSnapshot.definitions.first { $0.chainID == secondChainID }?.id
        )
        let traces = [
            DayTrace(
                id: DayTraceID(
                    UUID(uuidString: "B4000000-0000-0000-0000-000000000001")!
                ),
                chainID: firstChainID,
                definitionID: firstDefinitionID,
                date: today,
                priority: 1,
                now: base.addingTimeInterval(1)
            ),
            DayTrace(
                id: DayTraceID(
                    UUID(uuidString: "B4000000-0000-0000-0000-000000000002")!
                ),
                chainID: secondChainID,
                definitionID: secondDefinitionID,
                date: today,
                priority: 1,
                now: base.addingTimeInterval(1)
            )
        ]
        let records = try traces.map(record)

        for input in permutations(of: records) {
            let result = try SyncRecordMerger(mapper: mapper).merge(
                records: input,
                into: baseSnapshot,
                detectedAt: base
            )
            XCTAssertEqual(result.snapshot, baseSnapshot)
            XCTAssertTrue(result.appliedRecordIDs.isEmpty)
            XCTAssertTrue(result.waitingRecords.isEmpty)
            XCTAssertEqual(
                Set(result.conflicts.map(\.remoteRecordID)),
                Set(records.map(\.id))
            )
        }
    }

    func testTraceAndSubtaskSharingCancellationIdentityConflictAsOneComponent() throws {
        let fixture = try traceFixture()
        var snapshot = fixture.baseSnapshot
        var parent = fixture.target
        parent.continuedFromTraceID = nil
        parent.continuationSeq = 0
        snapshot.traces = [parent]
        let cancellationID = UUID(
            uuidString: "B6000000-0000-0000-0000-000000000001"
        )!
        var cancelledTrace = DayTrace(
            id: DayTraceID(
                UUID(uuidString: "B6000000-0000-0000-0000-000000000002")!
            ),
            chainID: fixture.otherChainID,
            definitionID: fixture.otherDefinitionID,
            date: today,
            status: .cancelledDraft,
            priority: 99,
            draftCancellationID: cancellationID,
            draftCancelledOn: today,
            now: base.addingTimeInterval(1),
            contentUpdatedAt: base.addingTimeInterval(2)
        )
        cancelledTrace.settledAt = base.addingTimeInterval(2)
        var cancelledSubtask = Subtask(
            id: SubtaskID(
                UUID(uuidString: "B6000000-0000-0000-0000-000000000003")!
            ),
            traceID: parent.id,
            title: "cancelled child",
            position: 1,
            draftCancellationID: cancellationID,
            now: base.addingTimeInterval(1)
        )
        cancelledSubtask.status = .cancelledDraft
        cancelledSubtask.updatedAt = base.addingTimeInterval(2)
        cancelledSubtask.settledAt = base.addingTimeInterval(2)
        let records = [
            try record(cancelledTrace),
            try record(cancelledSubtask)
        ]

        for input in permutations(of: records) {
            let result = try SyncRecordMerger(mapper: mapper).merge(
                records: input,
                into: snapshot,
                detectedAt: base
            )
            XCTAssertEqual(result.snapshot, snapshot)
            XCTAssertTrue(result.appliedRecordIDs.isEmpty)
            XCTAssertTrue(result.waitingRecords.isEmpty)
            XCTAssertEqual(
                Set(result.conflicts.map(\.remoteRecordID)),
                Set(records.map(\.id))
            )
        }
    }

    func testRejectedTraceParentMakesSubtaskConflictInsteadOfWaitForever() throws {
        let fixture = try traceFixture()
        var invalidTrace = fixture.target
        invalidTrace.continuedFromTraceID = nil
        invalidTrace.continuationSeq = 0
        invalidTrace.completedAt = invalidTrace.contentUpdatedAt
        let child = Subtask(
            traceID: invalidTrace.id,
            title: "child of rejected trace",
            position: 1,
            now: base.addingTimeInterval(3)
        )
        let traceRecord = try record(invalidTrace)
        let childRecord = try record(child)

        let result = try SyncRecordMerger(mapper: mapper).merge(
            records: [childRecord, traceRecord],
            into: fixture.baseSnapshot,
            detectedAt: base
        )

        XCTAssertTrue(result.appliedRecordIDs.isEmpty)
        XCTAssertTrue(result.waitingRecords.isEmpty)
        XCTAssertEqual(
            Set(result.conflicts.map(\.remoteRecordID)),
            Set([traceRecord.id, childRecord.id])
        )
    }

    func testRejectedDefinitionParentMakesTraceConflictInsteadOfWaitForever() throws {
        let engine = NoonmarkEngine()
        var snapshot = engine.snapshot()
        snapshot.days = [Day(date: today, now: base)]
        let chain = TaskChain(now: base)
        let invalidDefinition = TaskDefinition(
            chainID: chain.id,
            sequence: 0,
            title: "invalid definition",
            now: base
        )
        let trace = DayTrace(
            chainID: chain.id,
            definitionID: invalidDefinition.id,
            date: today,
            priority: 1,
            now: base
        )
        let chainRecord = try mapper.record(
            for: chain,
            modifiedBy: SyncDeviceID("mac-a")
        )
        let definitionRecord = try mapper.record(
            for: invalidDefinition,
            modifiedBy: SyncDeviceID("mac-a")
        )
        let traceRecord = try record(trace)

        let result = try SyncRecordMerger(mapper: mapper).merge(
            records: [traceRecord, definitionRecord, chainRecord],
            into: snapshot,
            detectedAt: base
        )

        XCTAssertTrue(result.appliedRecordIDs.isEmpty)
        XCTAssertFalse(
            result.waitingRecords.contains {
                $0.remoteRecordID == traceRecord.id
            }
        )
        XCTAssertTrue(
            result.conflicts.contains {
                $0.remoteRecordID == definitionRecord.id
            }
        )
        XCTAssertTrue(
            result.conflicts.contains {
                $0.remoteRecordID == traceRecord.id
            }
        )
    }

    private func traceFixture() throws -> (
        baseSnapshot: NoonmarkSnapshot,
        source: DayTrace,
        target: DayTrace,
        otherChainID: TaskChainID,
        otherDefinitionID: TaskDefinitionID
    ) {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "source chain",
            now: base
        )
        let otherChainID = try engine.createPoolTask(
            title: "other chain",
            now: base
        )
        var baseSnapshot = engine.snapshot()
        baseSnapshot.days = [
            Day(date: today, now: base),
            Day(date: tomorrow, now: base)
        ]
        let definitionID = try XCTUnwrap(
            baseSnapshot.definitions.first { $0.chainID == chainID }?.id
        )
        let otherDefinitionID = try XCTUnwrap(
            baseSnapshot.definitions.first { $0.chainID == otherChainID }?.id
        )
        let source = DayTrace(
            id: DayTraceID(
                UUID(uuidString: "B0000000-0000-0000-0000-000000000001")!
            ),
            chainID: chainID,
            definitionID: definitionID,
            date: today,
            status: .continued,
            priority: 1,
            now: base.addingTimeInterval(1),
            contentUpdatedAt: base.addingTimeInterval(3)
        )
        let target = DayTrace(
            id: DayTraceID(
                UUID(uuidString: "B0000000-0000-0000-0000-000000000002")!
            ),
            chainID: chainID,
            definitionID: definitionID,
            date: tomorrow,
            priority: 1,
            continuationSeq: 1,
            continuedFromTraceID: source.id,
            now: base.addingTimeInterval(3)
        )
        return (
            baseSnapshot,
            source,
            target,
            otherChainID,
            otherDefinitionID
        )
    }

    private func record(_ trace: DayTrace) throws -> SyncRecord {
        try mapper.record(for: trace, modifiedBy: SyncDeviceID("mac-a"))
    }

    private func record(_ subtask: Subtask) throws -> SyncRecord {
        try mapper.record(for: subtask, modifiedBy: SyncDeviceID("mac-a"))
    }

    private func permutations<T>(of values: [T]) -> [[T]] {
        guard let first = values.first else { return [[]] }
        return permutations(of: Array(values.dropFirst())).flatMap { tail in
            (0 ... tail.count).map { index in
                var candidate = tail
                candidate.insert(first, at: index)
                return candidate
            }
        }
    }
}
