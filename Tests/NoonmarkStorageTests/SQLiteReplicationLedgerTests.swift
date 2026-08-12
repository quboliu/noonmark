@testable import NoonmarkStorage
import NoonmarkCore
import NoonmarkSync
import XCTest

final class SQLiteReplicationLedgerTests: XCTestCase {
    private let generationID = UUID(
        uuidString: "71000000-0000-0000-0000-000000000001"
    )!
    private let producerID = UUID(
        uuidString: "72000000-0000-0000-0000-000000000001"
    )!
    private let now = Date(timeIntervalSinceReferenceDate: 810_000_000)

    func testOutOfOrderConfirmationPersistsAndAdvancesLongestPrefixAfterRestart()
        throws
    {
        let databaseURL = makeDatabaseURL()
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let firstEntry = SyncJournalEntry(
            id: UUID(uuidString: "73000000-0000-0000-0000-000000000001")!,
            entityType: .taskChain,
            entityID: "first-confirmed-event",
            changedAt: now,
            deviceID: SyncDeviceID("confirmation-order-device")
        )
        let secondEntry = SyncJournalEntry(
            id: UUID(uuidString: "73000000-0000-0000-0000-000000000002")!,
            entityType: .dayTrace,
            entityID: "second-confirmed-event",
            changedAt: now.addingTimeInterval(1),
            deviceID: SyncDeviceID("confirmation-order-device")
        )
        try syncRepository.appendJournalEntry(firstEntry)
        try syncRepository.appendJournalEntry(secondEntry)

        let first = try publication(
            sequence: 1,
            previousSealDigest: nil
        )
        let second = try publication(
            sequence: 2,
            previousSealDigest: first.reference.sealDigest
        )
        let ledger = SQLiteReplicationLedger(databaseURL: databaseURL)
        try ledger.recordSealedLocalPublications(
            [
                SQLiteSealedLocalPublication(
                    publication: first,
                    journalEntryIDs: [firstEntry.id]
                ),
                SQLiteSealedLocalPublication(
                    publication: second,
                    journalEntryIDs: [secondEntry.id]
                ),
            ],
            sealedAt: now.addingTimeInterval(2)
        )

        let afterSecond = try ledger.recordConfirmation(
            for: second.reference,
            confirmedAt: now.addingTimeInterval(3)
        )

        XCTAssertEqual(afterSecond.confirmedSequences, [2])
        XCTAssertNil(afterSecond.selfWatermark)
        XCTAssertEqual(
            try syncRepository.journalEntries(state: .pendingUpload).map(\.id),
            [firstEntry.id, secondEntry.id]
        )

        let restartedLedger = SQLiteReplicationLedger(
            databaseURL: databaseURL
        )
        XCTAssertEqual(
            try restartedLedger.snapshot(
                generationID: generationID,
                producerID: producerID
            ),
            afterSecond
        )

        let afterFirst = try restartedLedger.recordConfirmation(
            for: first.reference,
            confirmedAt: now.addingTimeInterval(4)
        )

        XCTAssertEqual(afterFirst.confirmedSequences, [1, 2])
        XCTAssertEqual(
            afterFirst.selfWatermark,
            ReplicationSelfWatermark(
                sequence: 2,
                sealDigest: second.reference.sealDigest
            )
        )
        XCTAssertEqual(
            try syncRepository.journalEntries(state: .uploaded).map(\.id),
            [firstEntry.id, secondEntry.id]
        )
        XCTAssertTrue(
            try syncRepository.journalEntries(state: .pendingUpload).isEmpty
        )
    }

    func testDisabledControlRejectsLateConfirmationInsideLedgerTransaction()
        throws
    {
        let databaseURL = makeDatabaseURL()
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let enabledControl = try syncRepository
            .loadOrInstallLocalFirstReplicationControl(installedAt: now)
        let entry = SyncJournalEntry(
            entityType: .taskChain,
            entityID: "late-confirmation",
            changedAt: now,
            deviceID: SyncDeviceID("late-confirmation-device")
        )
        try syncRepository.appendJournalEntry(entry)
        let sealed = try publication(sequence: 1)
        let ledger = SQLiteReplicationLedger(databaseURL: databaseURL)
        try ledger.recordSealedLocalPublications(
            [
                SQLiteSealedLocalPublication(
                    publication: sealed,
                    journalEntryIDs: [entry.id]
                ),
            ],
            sealedAt: now.addingTimeInterval(1),
            expectedReplicationControl: enabledControl
        )
        _ = try syncRepository.transitionLocalFirstReplicationControl(
            expectedGeneration: enabledControl.generation,
            policy: .disabled,
            updatedAt: now.addingTimeInterval(2)
        )

        XCTAssertThrowsError(
            try ledger.recordConfirmation(
                for: sealed.reference,
                confirmedAt: now.addingTimeInterval(3),
                expectedReplicationControl: enabledControl
            )
        )
        let snapshot = try ledger.snapshot(
            generationID: generationID,
            producerID: producerID
        )
        XCTAssertTrue(snapshot.confirmedSequences.isEmpty)
        XCTAssertNil(snapshot.selfWatermark)
        XCTAssertEqual(
            try syncRepository.journalEntries(state: .pendingUpload)
                .map(\.id),
            [entry.id]
        )
    }

    func testValidatedForkEvidencePersistsDeterministicResolutionAcrossRestart()
        throws
    {
        let databaseURL = makeDatabaseURL()
        try SQLiteEngineRepository(databaseURL: databaseURL)
            .save(NoonmarkEngine().snapshot())
        let first = try publication(sequence: 1, recordIndex: 1)
        let fork = try publication(sequence: 1, recordIndex: 2)
        let evidence = try ReplicationForkEvidence(
            branches: [
                ReceivedReplicationPublication(
                    reference: fork.reference,
                    records: fork.records
                ),
                ReceivedReplicationPublication(
                    reference: first.reference,
                    records: first.records
                ),
            ]
        )
        let ledger = SQLiteReplicationLedger(databaseURL: databaseURL)

        let recorded = try ledger.recordValidatedForkEvidence(
            evidence,
            detectedAt: now
        )

        XCTAssertEqual(recorded.resolutionID, evidence.resolutionID)
        XCTAssertEqual(recorded.state, .branchesValidated)
        XCTAssertEqual(recorded.evidence, evidence)

        let restarted = SQLiteReplicationLedger(databaseURL: databaseURL)
        XCTAssertEqual(
            try restarted.forkResolution(
                resolutionID: evidence.resolutionID
            ),
            recorded
        )
        XCTAssertEqual(
            try restarted.recordValidatedForkEvidence(
                evidence,
                detectedAt: now.addingTimeInterval(1)
            ),
            recorded
        )
    }

    func testProducerRotationFenceRollsBackBaselineWhenActiveEpochChanged()
        throws
    {
        let databaseURL = makeDatabaseURL()
        let ledger = SQLiteReplicationLedger(databaseURL: databaseURL)
        XCTAssertEqual(
            try ledger.loadOrInstallActiveProducerID(
                suggestedProducerID: producerID,
                installedAt: now
            ),
            producerID
        )
        let replacementProducerID = UUID(
            uuidString: "72000000-0000-0000-0000-000000000002"
        )!
        let staleRetiringProducerID = UUID(
            uuidString: "72000000-0000-0000-0000-000000000003"
        )!
        let nonexistentResolutionID = ReplicationDigest(
            rawValue: String(repeating: "a", count: 64)
        )!
        let baseline = try ReplicationPublicationBuilder().seal(
            records: [try preferenceRecord(index: 3)],
            generationID: generationID,
            producerID: replacementProducerID,
            sequence: 1,
            previousSealDigest: nil,
            basedOnResolutionID: nonexistentResolutionID,
            resolutionManifest: ReplicationForkResolutionManifest(
                resolutionID: nonexistentResolutionID,
                decidedAt: nil,
                outcomes: []
            )
        )

        XCTAssertThrowsError(
            try ledger.rotateActiveProducerAndSealBaseline(
                retiringProducerID: staleRetiringProducerID,
                replacementProducerID: replacementProducerID,
                publication: SQLiteSealedLocalPublication(
                    publication: baseline,
                    journalEntryIDs: []
                ),
                sealedAt: now.addingTimeInterval(1)
            )
        )
        XCTAssertNil(
            try ledger.latestSealedReference(
                generationID: generationID,
                producerID: replacementProducerID
            )
        )
        XCTAssertEqual(
            try ledger.loadOrInstallActiveProducerID(
                suggestedProducerID: staleRetiringProducerID,
                installedAt: now.addingTimeInterval(2)
            ),
            producerID,
            "failed rotation must preserve the exact active producer"
        )
    }

    private func publication(
        sequence: UInt64,
        previousSealDigest: ReplicationDigest? = nil,
        recordIndex: Int? = nil
    ) throws -> SealedReplicationPublication {
        try ReplicationPublicationBuilder(
            maximumRecordsPerChunk: 1
        ).seal(
            records: [
                try preferenceRecord(index: recordIndex ?? Int(sequence)),
            ],
            generationID: generationID,
            producerID: producerID,
            sequence: sequence,
            previousSealDigest: previousSealDigest
        )
    }

    private func preferenceRecord(index: Int) throws -> SyncRecord {
        try SyncRecordMapper().record(
            for: AppPreferencesEnvelope(
                theme: index.isMultiple(of: 2) ? .coolGray : .warmPaper,
                language: index.isMultiple(of: 2) ? .english : .chinese,
                updatedAt: now.addingTimeInterval(Double(index))
            ),
            modifiedBy: SyncDeviceID("replication-ledger-\(index)")
        )
    }

    private func makeDatabaseURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noonmark-replication-ledger-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent("noonmark.sqlite")
    }
}
