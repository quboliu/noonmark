@testable import NoonmarkCore
@testable import NoonmarkSync
import XCTest

final class TaskDefinitionTopologySyncTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 812_345_678.5)

    func testCrossChainSuccessorConflictsAsOneComponentRegardlessOfUUIDOrder() throws {
        for reversedUUIDOrder in [false, true] {
            let records = try crossChainSuccessorRecords(
                reversedUUIDOrder: reversedUUIDOrder
            )
            let expectedIDs = Set(records.map(\.id))

            for permutation in permutations(of: records) {
                let result = try SyncRecordMerger().merge(
                    records: permutation,
                    into: NoonmarkEngine().snapshot(),
                    detectedAt: now.addingTimeInterval(10)
                )

                XCTAssertEqual(result.snapshot, NoonmarkEngine().snapshot())
                XCTAssertTrue(result.appliedRecordIDs.isEmpty)
                XCTAssertTrue(result.waitingRecords.isEmpty)
                XCTAssertEqual(
                    Set(result.conflicts.map(\.remoteRecordID)),
                    expectedIDs,
                    "cross-chain successor must reject its whole connected component"
                )
                XCTAssertEqual(
                    Set(result.conflicts.map(\.type)),
                    [.invalidRecordPayload]
                )
            }

            let definitionRecords = records.filter {
                $0.entityType == .taskDefinition
            }
            for permutation in permutations(of: definitionRecords) {
                let result = try SyncRecordMerger().merge(
                    records: permutation,
                    into: NoonmarkEngine().snapshot(),
                    detectedAt: now.addingTimeInterval(10)
                )

                XCTAssertEqual(result.snapshot, NoonmarkEngine().snapshot())
                XCTAssertTrue(result.appliedRecordIDs.isEmpty)
                XCTAssertTrue(result.waitingRecords.isEmpty)
                XCTAssertEqual(
                    Set(result.conflicts.map(\.remoteRecordID)),
                    Set(definitionRecords.map(\.id))
                )
            }
        }
    }

    func testClosedSuccessorCycleConflictsAcrossEveryInputPermutation() throws {
        let fixture = try sameChainRecords(
            historicalEdges: [(0, 1), (1, 0)],
            currentIndex: 2
        )
        let expectedIDs = Set(fixture.records.map(\.id))

        for permutation in permutations(of: fixture.records) {
            let result = try SyncRecordMerger().merge(
                records: permutation,
                into: NoonmarkEngine().snapshot(),
                detectedAt: now.addingTimeInterval(10)
            )

            XCTAssertEqual(result.snapshot, NoonmarkEngine().snapshot())
            XCTAssertTrue(result.appliedRecordIDs.isEmpty)
            XCTAssertTrue(result.waitingRecords.isEmpty)
            XCTAssertEqual(Set(result.conflicts.map(\.remoteRecordID)), expectedIDs)
        }
    }

    func testValidSuccessorChainAppliesAcrossEveryInputPermutation() throws {
        let fixture = try sameChainRecords(
            historicalEdges: [(0, 1), (1, 2)],
            currentIndex: 2
        )
        let expectedSnapshot = NoonmarkSnapshot(
            days: [],
            chains: [fixture.chain],
            definitions: fixture.definitions,
            traces: [],
            subtasks: [],
            preferences: AppPreferences(),
            classifications: TaskClassificationState()
        )

        for permutation in permutations(of: fixture.records) {
            let result = try SyncRecordMerger().merge(
                records: permutation,
                into: NoonmarkEngine().snapshot(),
                detectedAt: now.addingTimeInterval(10)
            )

            XCTAssertEqual(result.snapshot, expectedSnapshot)
            XCTAssertEqual(
                Set(result.appliedRecordIDs),
                Set(fixture.records.map(\.id))
            )
            XCTAssertTrue(result.waitingRecords.isEmpty)
            XCTAssertTrue(result.conflicts.isEmpty)
            XCTAssertNoThrow(try result.snapshot.validateIntegrity())
        }
    }

    func testDuplicateDefinitionSequenceConflictsAcrossEveryInputPermutation() throws {
        let fixture = try sameChainRecords(
            historicalEdges: [(0, 1), (1, 2)],
            currentIndex: 2,
            sequences: [1, 1, 3]
        )
        let expectedIDs = Set(fixture.records.map(\.id))

        for permutation in permutations(of: fixture.records) {
            let result = try SyncRecordMerger().merge(
                records: permutation,
                into: NoonmarkEngine().snapshot(),
                detectedAt: now.addingTimeInterval(10)
            )

            XCTAssertEqual(result.snapshot, NoonmarkEngine().snapshot())
            XCTAssertTrue(result.appliedRecordIDs.isEmpty)
            XCTAssertTrue(result.waitingRecords.isEmpty)
            XCTAssertEqual(Set(result.conflicts.map(\.remoteRecordID)), expectedIDs)
        }
    }

    func testOnlyTrulyMissingSuccessorWaitsWithExactDependency() throws {
        let chainID = taskChainID("A0000000-0000-0000-0000-000000000001")
        let definitionID = taskDefinitionID(
            "A1000000-0000-0000-0000-000000000001"
        )
        let missingID = taskDefinitionID(
            "A1000000-0000-0000-0000-000000000002"
        )
        let chain = TaskChain(id: chainID, now: now)
        var historical = TaskDefinition(
            id: definitionID,
            chainID: chainID,
            sequence: 1,
            title: "等待真正缺少的 successor",
            now: now
        )
        try supersede(
            &historical,
            by: missingID,
            at: now.addingTimeInterval(1)
        )
        let mapper = SyncRecordMapper()
        let chainRecord = try mapper.record(
            for: chain,
            modifiedBy: SyncDeviceID("chain")
        )
        let definitionRecord = try mapper.record(
            for: historical,
            modifiedBy: SyncDeviceID("definition")
        )

        for records in [
            [chainRecord, definitionRecord],
            [definitionRecord, chainRecord]
        ] {
            let result = try SyncRecordMerger(mapper: mapper).merge(
                records: records,
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
                    repeating: [.taskDefinition(missingID)],
                    count: 2
                )
            )
        }
    }

    func testCurrentBoundaryRejectsInvalidDefinitionSelfContainedFacts() throws {
        let chainID = taskChainID("B0000000-0000-0000-0000-000000000001")
        let successorID = taskDefinitionID(
            "B1000000-0000-0000-0000-000000000002"
        )
        var successorWithoutDate = TaskDefinition(
            chainID: chainID,
            sequence: 1,
            title: "successor without date",
            now: now
        )
        successorWithoutDate.supersededByDefinitionID = successorID

        var dateWithoutSuccessor = TaskDefinition(
            chainID: chainID,
            sequence: 1,
            title: "date without successor",
            now: now
        )
        let supersededAt = now.addingTimeInterval(1)
        dateWithoutSuccessor.supersededAt = supersededAt
        try dateWithoutSuccessor.markContentModified(at: supersededAt)

        var invalidSequence = TaskDefinition(
            chainID: chainID,
            sequence: 0,
            title: "invalid sequence",
            now: now
        )
        invalidSequence.sequence = 0

        let paddedTitle = TaskDefinition(
            chainID: chainID,
            sequence: 1,
            title: " padded title ",
            now: now
        )
        let invalidPlannedSubtask = TaskDefinition(
            chainID: chainID,
            sequence: 1,
            title: "invalid planned subtask",
            plannedSubtasks: [
                PlannedSubtask(
                    title: " padded child ",
                    position: 1,
                    now: now
                )
            ],
            now: now
        )
        var selfSuccessor = TaskDefinition(
            chainID: chainID,
            sequence: 1,
            title: "self successor",
            now: now
        )
        try supersede(
            &selfSuccessor,
            by: selfSuccessor.id,
            at: supersededAt
        )
        let mapper = SyncRecordMapper()

        let transitionWitnessRecord = try mapper.record(
            for: successorWithoutDate,
            modifiedBy: SyncDeviceID("transition-witness")
        )
        XCTAssertNoThrow(
            try CurrentSyncRecordMerger(mapper: mapper).validate(
                transitionWitnessRecord
            )
        )

        for definition in [
            dateWithoutSuccessor,
            invalidSequence,
            paddedTitle,
            invalidPlannedSubtask,
            selfSuccessor
        ] {
            let record = try mapper.record(
                for: definition,
                modifiedBy: SyncDeviceID("invalid-definition")
            )
            XCTAssertThrowsError(
                try CurrentSyncRecordMerger(mapper: mapper).validate(record),
                "boundary must reject malformed definition \(definition.id)"
            )
        }
    }

    private func crossChainSuccessorRecords(
        reversedUUIDOrder: Bool
    ) throws -> [SyncRecord] {
        let firstRaw = reversedUUIDOrder
            ? "F0000000-0000-0000-0000-000000000001"
            : "10000000-0000-0000-0000-000000000001"
        let secondRaw = reversedUUIDOrder
            ? "10000000-0000-0000-0000-000000000001"
            : "F0000000-0000-0000-0000-000000000001"
        let firstChainID = taskChainID(firstRaw)
        let secondChainID = taskChainID(secondRaw)
        let firstDefinitionID = taskDefinitionID(
            "C1000000-0000-0000-0000-000000000001"
        )
        let secondDefinitionID = taskDefinitionID(
            "C1000000-0000-0000-0000-000000000002"
        )
        let firstChain = TaskChain(id: firstChainID, now: now)
        let secondChain = TaskChain(id: secondChainID, now: now)
        var firstDefinition = TaskDefinition(
            id: firstDefinitionID,
            chainID: firstChainID,
            sequence: 1,
            title: "cross-chain source",
            now: now
        )
        try supersede(
            &firstDefinition,
            by: secondDefinitionID,
            at: now.addingTimeInterval(1)
        )
        let secondDefinition = TaskDefinition(
            id: secondDefinitionID,
            chainID: secondChainID,
            sequence: 1,
            title: "cross-chain target",
            now: now
        )
        let mapper = SyncRecordMapper()
        return try [
            mapper.record(
                for: firstChain,
                modifiedBy: SyncDeviceID("first-chain")
            ),
            mapper.record(
                for: firstDefinition,
                modifiedBy: SyncDeviceID("first-definition")
            ),
            mapper.record(
                for: secondChain,
                modifiedBy: SyncDeviceID("second-chain")
            ),
            mapper.record(
                for: secondDefinition,
                modifiedBy: SyncDeviceID("second-definition")
            )
        ]
    }

    private func sameChainRecords(
        historicalEdges: [(Int, Int)],
        currentIndex: Int,
        sequences: [Int] = [1, 2, 3]
    ) throws -> (
        chain: TaskChain,
        definitions: [TaskDefinition],
        records: [SyncRecord]
    ) {
        let chainID = taskChainID("D0000000-0000-0000-0000-000000000001")
        let chain = TaskChain(id: chainID, now: now)
        let definitionIDs = (1 ... 3).map {
            taskDefinitionID(
                "D1000000-0000-0000-0000-00000000000\($0)"
            )
        }
        var definitions = definitionIDs.enumerated().map { index, id in
            TaskDefinition(
                id: id,
                chainID: chainID,
                sequence: sequences[index],
                title: "definition \(index + 1)",
                now: now.addingTimeInterval(TimeInterval(index))
            )
        }
        for (source, target) in historicalEdges {
            try supersede(
                &definitions[source],
                by: definitions[target].id,
                at: now.addingTimeInterval(4 + TimeInterval(source))
            )
        }
        XCTAssertNil(definitions[currentIndex].supersededAt)
        let mapper = SyncRecordMapper()
        let records = try [
            mapper.record(
                for: chain,
                modifiedBy: SyncDeviceID("chain")
            )
        ] + definitions.map {
            try mapper.record(
                for: $0,
                modifiedBy: SyncDeviceID("definition-\($0.sequence)")
            )
        }
        return (chain, definitions, records)
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

    private func taskChainID(_ value: String) -> TaskChainID {
        TaskChainID(UUID(uuidString: value)!)
    }

    private func taskDefinitionID(_ value: String) -> TaskDefinitionID {
        TaskDefinitionID(UUID(uuidString: value)!)
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
}
