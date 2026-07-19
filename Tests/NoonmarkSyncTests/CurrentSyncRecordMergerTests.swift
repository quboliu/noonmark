import Foundation
@testable import NoonmarkCore
@testable import NoonmarkSync
import XCTest

final class CurrentSyncRecordMergerTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 812_345_678.25)
    private let today = LocalDate("2026-07-16")

    func testTransportBatchCanonicalizesConsecutivePreferenceVersionsToFinalWinner() throws {
        let mapper = SyncRecordMapper()
        let first = try mapper.record(
            for: AppPreferencesEnvelope(
                theme: .warmPaper,
                language: .chinese,
                updatedAt: Date(timeIntervalSinceReferenceDate: 10)
            ),
            modifiedBy: SyncDeviceID("mac-first")
        )
        let final = try mapper.record(
            for: AppPreferencesEnvelope(
                theme: .warmPaper,
                language: .english,
                updatedAt: Date(timeIntervalSinceReferenceDate: 20)
            ),
            modifiedBy: SyncDeviceID("mac-final")
        )

        for records in [[first, final], [final, first]] {
            let batch = try CurrentSyncRecordMerger().prepareTransportBatch(
                existingRecords: [],
                incomingRecords: records
            )

            XCTAssertEqual(batch.records, [final])
        }
    }

    func testTransportBatchRejectsDivergentPreferenceWithSameVersion() throws {
        let mapper = SyncRecordMapper()
        let clock = Date(timeIntervalSinceReferenceDate: 20)
        let first = try mapper.record(
            for: AppPreferencesEnvelope(
                theme: .warmPaper,
                language: .chinese,
                updatedAt: clock
            ),
            modifiedBy: SyncDeviceID("mac-same")
        )
        let divergent = try mapper.record(
            for: AppPreferencesEnvelope(
                theme: .coolGray,
                language: .english,
                updatedAt: clock
            ),
            modifiedBy: SyncDeviceID("mac-same")
        )

        XCTAssertThrowsError(
            try CurrentSyncRecordMerger().prepareTransportBatch(
                existingRecords: [],
                incomingRecords: [first, divergent]
            )
        ) { error in
            XCTAssertEqual(
                error as? SyncRecordTransportError,
                .invalidCurrentRecordMerge(recordID: first.id)
            )
        }
    }

    func testTransportBatchRejectsDivergentPreferenceVersionAcrossEveryPermutation() throws {
        let mapper = SyncRecordMapper()
        let sharedClock = Date(timeIntervalSinceReferenceDate: 20)
        let first = try mapper.record(
            for: AppPreferencesEnvelope(
                theme: .warmPaper,
                language: .chinese,
                updatedAt: sharedClock
            ),
            modifiedBy: SyncDeviceID("mac-same")
        )
        let divergent = try mapper.record(
            for: AppPreferencesEnvelope(
                theme: .coolGray,
                language: .english,
                updatedAt: sharedClock
            ),
            modifiedBy: SyncDeviceID("mac-same")
        )
        let later = try mapper.record(
            for: AppPreferencesEnvelope(
                theme: .warmPaper,
                language: .english,
                updatedAt: sharedClock.addingTimeInterval(1)
            ),
            modifiedBy: SyncDeviceID("mac-later")
        )
        let permutations = [
            [first, divergent, later],
            [first, later, divergent],
            [divergent, first, later],
            [divergent, later, first],
            [later, first, divergent],
            [later, divergent, first]
        ]

        for records in permutations {
            XCTAssertThrowsError(
                try CurrentSyncRecordMerger().prepareTransportBatch(
                    existingRecords: [],
                    incomingRecords: records
                )
            ) { error in
                XCTAssertEqual(
                    error as? SyncRecordTransportError,
                    .invalidCurrentRecordMerge(recordID: first.id)
                )
            }
        }
    }

    func testSyntheticChainCanonicalRecordRetainsEveryExactOrigin() throws {
        let base = NoonmarkEngine()
        let chainID = try base.createPoolTask(
            title: "synthetic provenance",
            now: now
        )
        let baseline = base.snapshot()
        let left = try NoonmarkEngine(snapshot: baseline)
        _ = try left.appendPoolNote(
            chainID: chainID,
            body: "left",
            now: now.addingTimeInterval(1)
        )
        let right = try NoonmarkEngine(snapshot: baseline)
        _ = try right.appendPoolNote(
            chainID: chainID,
            body: "right",
            now: now.addingTimeInterval(2)
        )
        let mapper = SyncRecordMapper()
        let leftRecord = try mapper.record(
            for: try XCTUnwrap(left.chains[chainID]),
            modifiedBy: SyncDeviceID("mac-left")
        )
        let rightRecord = try mapper.record(
            for: try XCTUnwrap(right.chains[chainID]),
            modifiedBy: SyncDeviceID("mac-right")
        )
        let batch = try CurrentSyncRecordMerger(mapper: mapper)
            .prepareTransportBatch(
                existingRecords: [],
                incomingRecords: [rightRecord, leftRecord]
            )
        XCTAssertEqual(batch.records.count, 1)
        XCTAssertEqual(batch.provenanceGroups.count, 1)
        let canonicalRecord = try XCTUnwrap(batch.records.first)
        let provenance = try XCTUnwrap(batch.provenanceGroups.first)

        XCTAssertFalse(canonicalRecord.exactlyMatches(leftRecord))
        XCTAssertFalse(canonicalRecord.exactlyMatches(rightRecord))
        XCTAssertEqual(
            Set(provenance.sourceEvidenceIDs),
            Set([
                SyncRecordEvidenceID(record: leftRecord),
                SyncRecordEvidenceID(record: rightRecord)
            ])
        )
        XCTAssertEqual(
            provenance.canonicalEvidenceID,
            SyncRecordEvidenceID(record: canonicalRecord)
        )

        let merged = try SyncRecordMerger(mapper: mapper).merge(
            records: [leftRecord, rightRecord],
            into: baseline,
            detectedAt: now.addingTimeInterval(3)
        )
        XCTAssertEqual(merged.outcomes.count, 2)
        XCTAssertTrue(merged.outcomes.allSatisfy {
            $0.disposition == .merged
                && $0.canonicalEvidenceID == provenance.canonicalEvidenceID
        })
    }

    func testThreeVariantFoldKeepsOnlyLiveSyntheticContributors() throws {
        let base = NoonmarkEngine()
        let chainID = try base.createPoolTask(
            title: "three-way provenance",
            now: now
        )
        let baseline = base.snapshot()
        let mapper = SyncRecordMapper()
        let older = try mapper.record(
            for: try XCTUnwrap(base.chains[chainID]),
            modifiedBy: SyncDeviceID("mac-older")
        )

        let left = try NoonmarkEngine(snapshot: baseline)
        _ = try left.appendPoolNote(
            chainID: chainID,
            body: "left",
            now: now.addingTimeInterval(1)
        )
        let leftRecord = try mapper.record(
            for: try XCTUnwrap(left.chains[chainID]),
            modifiedBy: SyncDeviceID("mac-left")
        )

        let right = try NoonmarkEngine(snapshot: baseline)
        _ = try right.appendPoolNote(
            chainID: chainID,
            body: "right",
            now: now.addingTimeInterval(2)
        )
        let rightRecord = try mapper.record(
            for: try XCTUnwrap(right.chains[chainID]),
            modifiedBy: SyncDeviceID("mac-right")
        )
        let permutations = [
            [older, leftRecord, rightRecord],
            [older, rightRecord, leftRecord],
            [leftRecord, older, rightRecord],
            [leftRecord, rightRecord, older],
            [rightRecord, older, leftRecord],
            [rightRecord, leftRecord, older]
        ]
        let liveBatch = try CurrentSyncRecordMerger(mapper: mapper)
            .prepareTransportBatch(
                existingRecords: [],
                incomingRecords: [leftRecord, rightRecord]
            )
        let liveCanonical = try XCTUnwrap(liveBatch.records.first)
        let sourceEvidenceIDs = Set([
            SyncRecordEvidenceID(record: older),
            SyncRecordEvidenceID(record: leftRecord),
            SyncRecordEvidenceID(record: rightRecord)
        ])

        for records in permutations {
            let batch = try CurrentSyncRecordMerger(mapper: mapper)
                .prepareTransportBatch(
                    existingRecords: [],
                    incomingRecords: records
                )
            let provenance = try XCTUnwrap(batch.provenanceGroups.first)
            XCTAssertEqual(
                Set(provenance.contributingEvidenceIDs),
                Set([
                    SyncRecordEvidenceID(record: leftRecord),
                    SyncRecordEvidenceID(record: rightRecord)
                ])
            )
            XCTAssertEqual(
                provenance.supersededEvidenceIDs,
                [SyncRecordEvidenceID(record: older)]
            )
            XCTAssertEqual(Set(provenance.sourceEvidenceIDs), sourceEvidenceIDs)
            XCTAssertTrue(
                try XCTUnwrap(batch.records.first)
                    .exactlyMatches(liveCanonical)
            )
            XCTAssertEqual(
                provenance.canonicalEvidenceID,
                SyncRecordEvidenceID(record: liveCanonical)
            )

            let result = try SyncRecordMerger(mapper: mapper).merge(
                records: records,
                into: baseline,
                detectedAt: now.addingTimeInterval(3)
            )
            let dispositions = Dictionary(
                uniqueKeysWithValues: result.outcomes.map {
                    ($0.evidence.id, $0.disposition)
                }
            )
            XCTAssertEqual(
                dispositions[SyncRecordEvidenceID(record: older)],
                .ignored
            )
            XCTAssertEqual(
                dispositions[SyncRecordEvidenceID(record: leftRecord)],
                .merged
            )
            XCTAssertEqual(
                dispositions[SyncRecordEvidenceID(record: rightRecord)],
                .merged
            )
            XCTAssertTrue(result.outcomes.allSatisfy {
                $0.canonicalEvidenceID == provenance.canonicalEvidenceID
            })
        }
    }

    func testProvenanceKeepsExactSourceThatCarriesReactivationWitness() throws {
        let chainID = TaskChainID(
            UUID(uuidString: "A3000000-0000-0000-0000-000000000001")!
        )
        var abandoned = TaskChain(
            id: chainID,
            state: .abandoned,
            now: now
        )
        abandoned.updatedAt = now.addingTimeInterval(1)
        var restored = abandoned
        restored.state = .active
        restored.updatedAt = now.addingTimeInterval(2)
        let witness = try ChainReactivationEnvelope(
            operationID: UUID(
                uuidString: "A3000000-0000-0000-0000-000000000002"
            )!,
            abandonedChain: abandoned,
            restoredChain: restored
        )

        let mapper = SyncRecordMapper()
        let abandonedRecord = try mapper.record(
            for: abandoned,
            modifiedBy: SyncDeviceID("witness-device")
        )
        let plain = try mapper.record(
            for: restored,
            modifiedBy: SyncDeviceID("witness-device")
        )
        let witnessed = try mapper.record(
            for: restored,
            modifiedBy: SyncDeviceID("witness-device"),
            reactivationWitnesses: [witness]
        )
        XCTAssertTrue(plain.reactivationWitnesses.isEmpty)
        XCTAssertFalse(witnessed.reactivationWitnesses.isEmpty)
        XCTAssertFalse(plain.exactlyMatches(witnessed))

        let batch = try CurrentSyncRecordMerger(mapper: mapper)
            .prepareTransportBatch(
                existingRecords: [],
                incomingRecords: [plain, abandonedRecord, witnessed]
            )
        let provenance = try XCTUnwrap(batch.provenanceGroups.first {
            $0.canonicalRecord.id == witnessed.id
        })

        XCTAssertTrue(provenance.canonicalRecord.exactlyMatches(witnessed))
        XCTAssertEqual(
            provenance.contributingEvidenceIDs,
            [SyncRecordEvidenceID(record: witnessed)]
        )
        XCTAssertEqual(
            provenance.supersededEvidenceIDs,
            [
                SyncRecordEvidenceID(record: abandonedRecord),
                SyncRecordEvidenceID(record: plain)
            ].sorted { $0.rawValue < $1.rawValue }
        )
    }

    func testValidationRejectsReactivationWitnessesOnEveryNonTaskChainRecord() throws {
        let mapper = SyncRecordMapper()
        let records = try makeValidNonTaskChainRecords(mapper: mapper)
        XCTAssertEqual(
            Set(records.map(\.entityType)),
            Set(SyncEntityType.allCases.filter { $0 != .taskChain })
        )

        for record in records {
            let witnessed = SyncRecord(
                id: record.id,
                entityType: record.entityType,
                entityID: record.entityID,
                operation: record.operation,
                modifiedAt: record.modifiedAt,
                modifiedByDeviceID: record.modifiedByDeviceID,
                payload: record.payload,
                reactivationWitnesses: [Data([0xCA, 0xFE])]
            )

            XCTAssertThrowsError(
                try CurrentSyncRecordMerger(mapper: mapper).validate(witnessed),
                "\(record.entityType.rawValue) must reject task-chain-only witnesses"
            )
        }
    }

    func testTransportBatchRejectsReactivationWitnessOnImmutableRecord() throws {
        let mapper = SyncRecordMapper()
        let immutable = try XCTUnwrap(
            makeValidNonTaskChainRecords(mapper: mapper).first {
                $0.entityType.requiresImmutableRecordPayload
            }
        )
        let witnessed = SyncRecord(
            id: immutable.id,
            entityType: immutable.entityType,
            entityID: immutable.entityID,
            operation: immutable.operation,
            modifiedAt: immutable.modifiedAt,
            modifiedByDeviceID: immutable.modifiedByDeviceID,
            payload: immutable.payload,
            reactivationWitnesses: [Data([0xCA, 0xFE])]
        )

        XCTAssertThrowsError(
            try CurrentSyncRecordMerger(mapper: mapper).prepareTransportBatch(
                existingRecords: [],
                incomingRecords: [witnessed]
            )
        ) { error in
            XCTAssertEqual(
                error as? SyncRecordTransportError,
                .invalidCurrentRecordMerge(recordID: immutable.id)
            )
        }
    }

    func testValidationRejectsForgedCanonicalMutationClockHeaders() throws {
        let mapper = SyncRecordMapper()
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "拒绝伪造同步时钟",
            initialNoteBody: "任务附言",
            now: now
        )
        let chainNoteID = try XCTUnwrap(
            engine.taskPool().first?.chain.activeNoteEntries.first?.id
        )
        let noteUpdatedAt = now.addingTimeInterval(20)
        try engine.editPoolNote(
            chainID: chainID,
            noteID: chainNoteID,
            body: "任务附言已更新",
            now: noteUpdatedAt
        )
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )
        let traceNoteID = try XCTUnwrap(
            engine.traces[traceID]?.activeNoteEntries.first?.id
        )
        let traceNoteUpdatedAt = now.addingTimeInterval(30)
        try engine.editTraceNote(
            traceID: traceID,
            noteID: traceNoteID,
            body: "轨迹附言已更新",
            today: today,
            now: traceNoteUpdatedAt
        )
        let snapshot = engine.snapshot()
        let records = try [
            mapper.record(
                for: try XCTUnwrap(snapshot.days.first),
                modifiedBy: SyncDeviceID("clock-day")
            ),
            mapper.record(
                for: try XCTUnwrap(snapshot.chains.first),
                modifiedBy: SyncDeviceID("clock-chain")
            ),
            mapper.record(
                for: try XCTUnwrap(snapshot.definitions.first),
                modifiedBy: SyncDeviceID("clock-definition")
            ),
            mapper.record(
                for: try XCTUnwrap(snapshot.traces.first),
                modifiedBy: SyncDeviceID("clock-trace")
            )
        ]
        XCTAssertEqual(records[1].modifiedAt, noteUpdatedAt)
        XCTAssertEqual(records[3].modifiedAt, traceNoteUpdatedAt)

        for record in records {
            var forged = record
            forged.modifiedAt = Date(
                timeIntervalSinceReferenceDate: record.modifiedAt
                    .timeIntervalSinceReferenceDate.nextUp
            )
            XCTAssertNotEqual(
                forged.modifiedAt.timeIntervalSinceReferenceDate.bitPattern,
                record.modifiedAt.timeIntervalSinceReferenceDate.bitPattern
            )

            XCTAssertThrowsError(
                try CurrentSyncRecordMerger(mapper: mapper).validate(forged),
                "\(record.entityType.rawValue) must exact-match its payload mutation clock"
            ) { error in
                XCTAssertEqual(
                    error as? CurrentSyncRecordMergeError,
                    .invalidContentClock
                )
            }
        }
    }

    private func makeValidNonTaskChainRecords(
        mapper: SyncRecordMapper
    ) throws -> [SyncRecord] {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "见证边界",
            now: now
        )
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now
        )
        _ = try engine.addSubtask(
            traceID: traceID,
            title: "覆盖全部 current 类型",
            now: now
        )
        let deviceID = SyncDeviceID("witness-boundary")
        var records = try mapper.records(
            from: engine.snapshot(),
            modifiedBy: deviceID
        ).filter { $0.entityType != .taskChain }

        let before = engine.snapshot().classifications
        let plan = try engine.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .new(name: "工程", colorHex: "#2A6FDB"),
                    labels: []
                )
            ),
            source: .userDirect,
            interactionID: UUID(
                uuidString: "A1000000-0000-0000-0000-000000000001"
            )!,
            now: now
        )
        let receipt = try engine.commitClassification(
            plan,
            confirmation: .user(
                decisionID: UUID(
                    uuidString: "A1000000-0000-0000-0000-000000000002"
                )!
            ),
            now: now
        )
        let after = engine.snapshot().classifications
        let changeRecord = try XCTUnwrap(
            after.changeRecords.first { $0.id == receipt.changeRecordID }
        )
        records.append(
            try mapper.record(
                for: ClassificationCommitEnvelope(
                    before: before,
                    after: after,
                    changeRecord: changeRecord
                ),
                modifiedBy: deviceID
            )
        )

        let traceEvent = TraceClassificationSnapshot(
            id: UUID(
                uuidString: "A1000000-0000-0000-0000-000000000003"
            )!,
            traceID: traceID,
            status: .continued,
            category: nil,
            labels: [],
            capturedAt: now,
            revision: 1
        )
        records.append(
            try mapper.record(
                for: TraceClassificationEventEnvelope(
                    event: traceEvent,
                    predecessorEventID: nil
                ),
                modifiedBy: deviceID
            )
        )
        return records
    }
}
