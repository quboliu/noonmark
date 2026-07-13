import SQLite3
@testable import SuntraceCore
@testable import SuntraceStorage
import SuntraceSync
import XCTest

final class SQLiteSyncRepositoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let today = LocalDate("2026-07-05")

    func testFirstSyncOperationInstallsTheCurrentSchemaAndVersion() throws {
        let databaseURL = makeDatabaseURL()
        let repository = SQLiteSyncRepository(databaseURL: databaseURL)

        XCTAssertNil(try repository.loadDeviceIdentity())

        XCTAssertEqual(
            try integerScalar("PRAGMA user_version", at: databaseURL),
            SQLiteSchema.version
        )
        XCTAssertNoThrow(try SQLiteEngineRepository(databaseURL: databaseURL).load())
    }

    func testSyncRepositoryRejectsANonemptyUnversionedStoreWithoutChangingIt() throws {
        let databaseURL = makeDatabaseURL()
        try executeProbeSQL(
            """
            CREATE TABLE sentinel_facts(id INTEGER PRIMARY KEY, value TEXT NOT NULL);
            INSERT INTO sentinel_facts(id, value) VALUES (1, 'preserve-me');
            """,
            at: databaseURL
        )
        let definitionsBefore = try schemaDefinitions(at: databaseURL)
        XCTAssertEqual(try integerScalar("PRAGMA user_version", at: databaseURL), 0)

        XCTAssertThrowsError(
            try SQLiteSyncRepository(databaseURL: databaseURL).saveMetadata(
                SyncMetadataEntry(key: "should.not.exist", value: Data([0x01]), updatedAt: now)
            )
        ) { error in
            guard case SQLiteRepositoryError.invalidStoredValue = error else {
                return XCTFail("expected invalid stored value, got \(error)")
            }
        }

        XCTAssertEqual(try integerScalar("PRAGMA user_version", at: databaseURL), 0)
        XCTAssertEqual(try schemaDefinitions(at: databaseURL), definitionsBefore)
        XCTAssertEqual(try integerScalar("SELECT COUNT(*) FROM sentinel_facts", at: databaseURL), 1)
        XCTAssertEqual(
            try integerScalar(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'sync_metadata'",
                at: databaseURL
            ),
            0
        )
    }

    func testDeviceIdentityAndMetadataRoundTrip() throws {
        let repository = SQLiteSyncRepository(databaseURL: makeDatabaseURL())
        let identity = SyncDeviceIdentity(deviceID: SyncDeviceID("mac-a"), displayName: "Mac A", createdAt: now)
        let metadata = SyncMetadataEntry(key: "cksync.state", value: Data([0x01, 0x02, 0x03]), updatedAt: now)

        try repository.saveDeviceIdentity(identity)
        try repository.saveMetadata(metadata)

        XCTAssertEqual(try repository.loadDeviceIdentity(), identity)
        XCTAssertEqual(try repository.metadata(for: "cksync.state"), metadata)
        XCTAssertNil(try repository.metadata(for: "missing"))
    }

    func testJournalEntriesMoveThroughPendingUploadedAndFailedStates() throws {
        let repository = SQLiteSyncRepository(databaseURL: makeDatabaseURL())
        let firstID = UUID()
        let secondID = UUID()
        let first = SyncJournalEntry(
            id: firstID,
            entityType: .taskChain,
            entityID: "chain-a",
            changedAt: now,
            deviceID: SyncDeviceID("mac-a")
        )
        let second = SyncJournalEntry(
            id: secondID,
            entityType: .dayTrace,
            entityID: "trace-a",
            changedAt: now.addingTimeInterval(1),
            deviceID: SyncDeviceID("mac-a")
        )

        try repository.appendJournalEntry(second)
        try repository.appendJournalEntry(first)

        XCTAssertEqual(try repository.journalEntries(state: .pendingUpload).map(\.id), [firstID, secondID])
        XCTAssertEqual(try repository.journalEntries(state: .pendingUpload, limit: 1).map(\.id), [firstID])

        try repository.markJournalEntriesUploaded([firstID])
        try repository.markJournalEntryFailed(secondID, error: "network unavailable")

        let uploaded = try XCTUnwrap(repository.journalEntries(state: .uploaded).first)
        let failed = try XCTUnwrap(repository.journalEntries(state: .failed).first)

        XCTAssertEqual(uploaded.id, firstID)
        XCTAssertNil(uploaded.lastError)
        XCTAssertEqual(failed.id, secondID)
        XCTAssertEqual(failed.retryCount, 1)
        XCTAssertEqual(failed.lastError, "network unavailable")
    }

    func testJournalEntriesUseDomainDependencyOrderAtTheSameTimestamp() throws {
        let repository = SQLiteSyncRepository(databaseURL: makeDatabaseURL())
        let dependencyOrder: [SyncEntityType] = [
            .taskChain,
            .taskDefinition,
            .day,
            .classificationCommit,
            .dayTrace,
            .traceClassificationEvent,
            .subtask,
            .appPreferences
        ]
        let entries = dependencyOrder.enumerated().map { index, type in
            SyncJournalEntry(
                entityType: type,
                entityID: "entity-\(index)",
                changedAt: now,
                deviceID: SyncDeviceID("mac-a"),
                recordPayload: type.requiresImmutableRecordPayload ? Data([0x01]) : nil
            )
        }

        for entry in entries.reversed() {
            try repository.appendJournalEntry(entry)
        }

        XCTAssertEqual(try repository.journalEntries().map(\.entityType), dependencyOrder)
    }

    func testJournalAppendIsIdempotentForTheSameIDAndExactContent() throws {
        let repository = SQLiteSyncRepository(databaseURL: makeDatabaseURL())
        let entry = SyncJournalEntry(
            id: UUID(uuidString: "A2000000-0000-0000-0000-000000000001")!,
            entityType: .classificationCommit,
            entityID: "classification-commit-a",
            changedAt: now,
            deviceID: SyncDeviceID("mac-a"),
            recordPayload: Data([0x00, 0x7F, 0x80, 0xFF])
        )

        try repository.appendJournalEntry(entry)
        try repository.appendJournalEntry(entry)

        XCTAssertEqual(try repository.journalEntries(), [entry])
    }

    func testJournalAppendRejectsTheSameIDWithDifferentImmutablePayload() throws {
        let repository = SQLiteSyncRepository(databaseURL: makeDatabaseURL())
        let id = UUID(uuidString: "A2000000-0000-0000-0000-000000000002")!
        let original = SyncJournalEntry(
            id: id,
            entityType: .classificationCommit,
            entityID: "classification-commit-a",
            changedAt: now,
            deviceID: SyncDeviceID("mac-a"),
            recordPayload: Data([0x01, 0x00, 0x02])
        )
        let collision = SyncJournalEntry(
            id: id,
            entityType: .classificationCommit,
            entityID: "classification-commit-a",
            changedAt: now,
            deviceID: SyncDeviceID("mac-a"),
            recordPayload: Data([0x01, 0x00, 0x03])
        )

        try repository.appendJournalEntry(original)

        XCTAssertThrowsError(try repository.appendJournalEntry(collision)) { error in
            guard case let SQLiteRepositoryError.invalidStoredValue(message) = error else {
                return XCTFail("expected invalid stored value, got \(error)")
            }
            XCTAssertTrue(message.contains(id.uuidString))
        }
        XCTAssertEqual(try repository.journalEntries(), [original])
    }

    func testJournalCASPreservesExactChangedAtBitsAndRejectsSubmillisecondCollision() throws {
        let repository = SQLiteSyncRepository(databaseURL: makeDatabaseURL())
        let id = UUID(uuidString: "A2000000-0000-0000-0000-000000000006")!
        let originalDate = Date(timeIntervalSinceReferenceDate: 812_345_678.123_1)
        let collidingDate = Date(timeIntervalSinceReferenceDate: 812_345_678.123_2)
        let original = SyncJournalEntry(
            id: id,
            entityType: .classificationCommit,
            entityID: "classification-commit-exact-date",
            changedAt: originalDate,
            deviceID: SyncDeviceID("mac-a"),
            recordPayload: Data([0x21, 0x00, 0x22])
        )
        let collision = SyncJournalEntry(
            id: id,
            entityType: .classificationCommit,
            entityID: "classification-commit-exact-date",
            changedAt: collidingDate,
            deviceID: SyncDeviceID("mac-a"),
            recordPayload: Data([0x21, 0x00, 0x22])
        )
        XCTAssertNotEqual(
            originalDate.timeIntervalSinceReferenceDate.bitPattern,
            collidingDate.timeIntervalSinceReferenceDate.bitPattern
        )

        try repository.appendJournalEntry(original)
        try repository.appendJournalEntry(original)

        XCTAssertThrowsError(try repository.appendJournalEntry(collision))
        let restored = try XCTUnwrap(repository.journalEntries().first)
        XCTAssertEqual(
            restored.changedAt.timeIntervalSinceReferenceDate.bitPattern,
            originalDate.timeIntervalSinceReferenceDate.bitPattern
        )
    }

    func testJournalReaderRejectsChangedAtProjectionThatDisagreesWithExactBits() throws {
        let databaseURL = makeDatabaseURL()
        let repository = SQLiteSyncRepository(databaseURL: databaseURL)
        let entry = SyncJournalEntry(
            id: UUID(uuidString: "A2000000-0000-0000-0000-000000000007")!,
            entityType: .traceClassificationEvent,
            entityID: "classification-event-projection",
            changedAt: Date(timeIntervalSinceReferenceDate: 812_345_678.123_456_7),
            deviceID: SyncDeviceID("mac-a"),
            recordPayload: Data([0x31, 0x00, 0x32])
        )
        try repository.appendJournalEntry(entry)
        try executeProbeSQL(
            """
            UPDATE change_journal
            SET changed_at = '2026-09-29T03:34:39.123Z'
            WHERE id = 'A2000000-0000-0000-0000-000000000007';
            """,
            at: databaseURL
        )

        XCTAssertThrowsError(try repository.journalEntries()) { error in
            guard case let SQLiteRepositoryError.invalidStoredValue(message) = error else {
                return XCTFail("expected invalid stored value, got \(error)")
            }
            XCTAssertTrue(message.contains("projection"))
        }
    }

    func testJournalIdentityCollisionRollsBackAndLeavesTheNextTransactionUsable() throws {
        let repository = SQLiteSyncRepository(databaseURL: makeDatabaseURL())
        let originalID = UUID(uuidString: "A2000000-0000-0000-0000-000000000003")!
        let original = SyncJournalEntry(
            id: originalID,
            entityType: .traceClassificationEvent,
            entityID: "classification-event-a",
            changedAt: now,
            deviceID: SyncDeviceID("mac-a"),
            recordPayload: Data([0x10, 0x00, 0x20])
        )
        let collision = SyncJournalEntry(
            id: originalID,
            entityType: .traceClassificationEvent,
            entityID: "classification-event-a",
            changedAt: now,
            deviceID: SyncDeviceID("mac-a"),
            recordPayload: Data([0x10, 0x00, 0x21])
        )
        let later = SyncJournalEntry(
            id: UUID(uuidString: "A2000000-0000-0000-0000-000000000004")!,
            entityType: .traceClassificationEvent,
            entityID: "classification-event-b",
            changedAt: now.addingTimeInterval(1),
            deviceID: SyncDeviceID("mac-a"),
            recordPayload: Data([0x30, 0x00, 0x40])
        )

        try repository.appendJournalEntry(original)
        XCTAssertThrowsError(try repository.appendJournalEntry(collision))
        try repository.appendJournalEntry(later)

        XCTAssertEqual(try repository.journalEntries(), [original, later])
    }

    func testClassificationCommitJournalPayloadRoundTripsExactly() throws {
        let repository = SQLiteSyncRepository(databaseURL: makeDatabaseURL())
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "同步分类提交", now: now)
        let before = engine.snapshot().classifications
        let plan = try engine.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .new(name: "项目", colorHex: "#2A6FDB"),
                    labels: [.new(name: "待确认", colorHex: "#0E9488")]
                )
            ),
            source: .userDirect,
            interactionID: UUID(),
            now: now
        )
        _ = try engine.commitClassification(
            plan,
            confirmation: .user(decisionID: UUID()),
            now: now
        )
        let after = engine.snapshot().classifications
        let changeRecord = try XCTUnwrap(after.changeRecords.last)
        let envelope = try ClassificationCommitEnvelope(
            before: before,
            after: after,
            changeRecord: changeRecord
        )
        let payload = try envelope.canonicalData()
        let entry = SyncJournalEntry(
            entityType: .classificationCommit,
            entityID: changeRecord.id.uuidString,
            changedAt: changeRecord.committedAt,
            deviceID: SyncDeviceID("mac-a"),
            recordPayload: payload
        )

        try repository.appendJournalEntry(entry)

        let restored = try XCTUnwrap(repository.journalEntries().first)
        XCTAssertEqual(restored, entry)
        XCTAssertEqual(restored.recordPayload, payload)
        XCTAssertEqual(try ClassificationCommitEnvelope.decode(payload), envelope)
    }

    func testTraceClassificationEventJournalPayloadRoundTripsExactly() throws {
        let repository = SQLiteSyncRepository(databaseURL: makeDatabaseURL())
        let event = TraceClassificationSnapshot(
            traceID: DayTraceID(),
            status: .unfinished,
            category: nil,
            labels: [],
            capturedAt: now,
            revision: 1
        )
        let envelope = try TraceClassificationEventEnvelope(
            event: event,
            predecessorEventID: nil
        )
        let payload = try envelope.canonicalData()
        let entry = SyncJournalEntry(
            entityType: .traceClassificationEvent,
            entityID: event.id.uuidString,
            changedAt: event.capturedAt,
            deviceID: SyncDeviceID("mac-event"),
            recordPayload: payload
        )

        try repository.appendJournalEntry(entry)

        let restored = try XCTUnwrap(repository.journalEntries().first)
        XCTAssertEqual(restored, entry)
        XCTAssertEqual(restored.recordPayload, payload)
        XCTAssertEqual(try TraceClassificationEventEnvelope.decode(payload), envelope)
    }

    func testPendingDownloadRoundTripsRecordBytesDependenciesAndExactDates() throws {
        let repository = SQLiteSyncRepository(databaseURL: makeDatabaseURL())
        let modifiedAt = Date(timeIntervalSinceReferenceDate: 812_345_678.123_456_7)
        let attemptedAt = Date(timeIntervalSinceReferenceDate: 812_345_679.987_654_3)
        let dependencies: [ClassificationCommitDependency] = [
            .taskChain(TaskChainID(UUID(uuidString: "A1000000-0000-0000-0000-000000000001")!)),
            .dayTrace(DayTraceID(UUID(uuidString: "A1000000-0000-0000-0000-000000000004")!)),
            .category(TaskCategoryID(UUID(uuidString: "A1000000-0000-0000-0000-000000000002")!)),
            .label(TaskLabelID(UUID(uuidString: "A1000000-0000-0000-0000-000000000003")!)),
            .classificationEvent(
                UUID(uuidString: "A1000000-0000-0000-0000-000000000005")!
            ),
            .classificationCommit(
                UUID(uuidString: "A1000000-0000-0000-0000-000000000006")!
            ),
            .classificationRevision(42)
        ]
        let waiting = try makeWaitingRecord(
            modifiedAt: modifiedAt,
            dependencies: dependencies
        )
        XCTAssertTrue(waiting.record.payload.contains { $0 > 0x7F })

        try repository.reconcilePendingDownloads(
            waiting: [waiting],
            terminal: [],
            attemptedAt: attemptedAt
        )

        let restored = try XCTUnwrap(repository.pendingDownloads().first)
        XCTAssertEqual(restored.record, waiting.record)
        XCTAssertEqual(restored.record.payload, waiting.record.payload)
        XCTAssertEqual(Set(restored.dependencies), Set(dependencies))
        XCTAssertEqual(
            restored.record.modifiedAt.timeIntervalSinceReferenceDate.bitPattern,
            modifiedAt.timeIntervalSinceReferenceDate.bitPattern
        )
        XCTAssertEqual(
            restored.firstSeenAt.timeIntervalSinceReferenceDate.bitPattern,
            attemptedAt.timeIntervalSinceReferenceDate.bitPattern
        )
        XCTAssertEqual(
            restored.lastAttemptedAt.timeIntervalSinceReferenceDate.bitPattern,
            attemptedAt.timeIntervalSinceReferenceDate.bitPattern
        )
        XCTAssertEqual(restored.attemptCount, 1)
    }

    func testRepeatedPendingDownloadPreservesFirstSeenAndReplacesDependencies() throws {
        let repository = SQLiteSyncRepository(databaseURL: makeDatabaseURL())
        let firstAttempt = Date(timeIntervalSinceReferenceDate: 812_345_680.111_111_1)
        let secondAttempt = Date(timeIntervalSinceReferenceDate: 812_345_690.222_222_2)
        let initialDependencies: [ClassificationCommitDependency] = [
            .taskChain(TaskChainID(UUID(uuidString: "A2000000-0000-0000-0000-000000000001")!)),
            .category(TaskCategoryID(UUID(uuidString: "A2000000-0000-0000-0000-000000000002")!))
        ]
        let replacementDependencies: [ClassificationCommitDependency] = [
            .label(TaskLabelID(UUID(uuidString: "A2000000-0000-0000-0000-000000000003")!))
        ]
        let initial = try makeWaitingRecord(
            modifiedAt: now,
            dependencies: initialDependencies
        )

        try repository.reconcilePendingDownloads(
            waiting: [initial],
            terminal: [],
            attemptedAt: firstAttempt
        )
        let repeated = SyncWaitingRecord(
            record: initial.record,
            dependencies: replacementDependencies
        )
        try repository.reconcilePendingDownloads(
            waiting: [repeated],
            terminal: [],
            attemptedAt: secondAttempt
        )

        let restored = try XCTUnwrap(repository.pendingDownloads().first)
        XCTAssertEqual(try repository.pendingDownloads().count, 1)
        XCTAssertEqual(restored.record, initial.record)
        XCTAssertEqual(Set(restored.dependencies), Set(replacementDependencies))
        XCTAssertEqual(
            restored.firstSeenAt.timeIntervalSinceReferenceDate.bitPattern,
            firstAttempt.timeIntervalSinceReferenceDate.bitPattern
        )
        XCTAssertEqual(
            restored.lastAttemptedAt.timeIntervalSinceReferenceDate.bitPattern,
            secondAttempt.timeIntervalSinceReferenceDate.bitPattern
        )
        XCTAssertEqual(restored.attemptCount, 2)
    }

    func testTerminalPendingDownloadDeletesItsDependenciesAndKeepsOtherRecords() throws {
        let databaseURL = makeDatabaseURL()
        let repository = SQLiteSyncRepository(databaseURL: databaseURL)
        let terminal = try makeWaitingRecord(
            modifiedAt: now,
            dependencies: [
                .taskChain(TaskChainID(UUID(uuidString: "A3000000-0000-0000-0000-000000000002")!)),
                .label(TaskLabelID(UUID(uuidString: "A3000000-0000-0000-0000-000000000003")!))
            ]
        )
        let retained = try makeWaitingRecord(
            modifiedAt: now.addingTimeInterval(1),
            dependencies: [
                .category(TaskCategoryID(UUID(uuidString: "A3000000-0000-0000-0000-000000000005")!))
            ]
        )
        try repository.reconcilePendingDownloads(
            waiting: [terminal, retained],
            terminal: [],
            attemptedAt: now
        )
        let terminalToken = try XCTUnwrap(
            repository.pendingDownloads().first { $0.record.id == terminal.record.id }
        )

        try repository.reconcilePendingDownloads(
            waiting: [],
            terminal: [terminalToken],
            attemptedAt: now.addingTimeInterval(10)
        )

        let restored = try repository.pendingDownloads()
        XCTAssertEqual(restored.map(\.record.id), [retained.record.id])
        XCTAssertEqual(
            try integerScalar(
                "SELECT COUNT(*) FROM sync_pending_download_dependencies WHERE record_id = '\(terminal.record.id.rawValue)'",
                at: databaseURL
            ),
            0
        )
        XCTAssertEqual(
            try integerScalar(
                "SELECT COUNT(*) FROM sync_pending_download_dependencies WHERE record_id = '\(retained.record.id.rawValue)'",
                at: databaseURL
            ),
            1
        )
    }

    func testTerminalPendingDownloadCASPreservesARecordUpdatedAfterObservation() throws {
        let repository = SQLiteSyncRepository(databaseURL: makeDatabaseURL())
        let waiting = try makeWaitingRecord(
            modifiedAt: now,
            dependencies: [
                .taskChain(TaskChainID(UUID(uuidString: "A4000000-0000-0000-0000-000000000001")!))
            ]
        )
        try repository.reconcilePendingDownloads(
            waiting: [waiting],
            terminal: [],
            attemptedAt: now
        )
        let staleToken = try XCTUnwrap(repository.pendingDownloads().first)

        try repository.reconcilePendingDownloads(
            waiting: [waiting],
            terminal: [],
            attemptedAt: now.addingTimeInterval(1)
        )
        try repository.reconcilePendingDownloads(
            waiting: [],
            terminal: [staleToken],
            attemptedAt: now.addingTimeInterval(2)
        )

        let retained = try XCTUnwrap(repository.pendingDownloads().first)
        XCTAssertEqual(retained.record, waiting.record)
        XCTAssertEqual(retained.attemptCount, 2)
        XCTAssertEqual(retained.lastAttemptedAt, now.addingTimeInterval(1))
    }

    func testTerminalPendingDownloadCASRequiresTheFullObservedToken() throws {
        let repository = SQLiteSyncRepository(databaseURL: makeDatabaseURL())
        let waiting = try makeWaitingRecord(
            modifiedAt: now,
            dependencies: [
                .taskChain(TaskChainID(UUID(uuidString: "AA000000-0000-0000-0000-000000000001")!))
            ]
        )
        try repository.reconcilePendingDownloads(
            waiting: [waiting],
            terminal: [],
            attemptedAt: now
        )
        let observed = try XCTUnwrap(repository.pendingDownloads().first)

        var changedRecord = observed.record
        changedRecord.modifiedByDeviceID = SyncDeviceID("another-device")
        let differentRecordToken = SyncPendingDownloadRecord(
            record: changedRecord,
            generationID: observed.generationID,
            dependencies: observed.dependencies,
            firstSeenAt: observed.firstSeenAt,
            lastAttemptedAt: observed.lastAttemptedAt,
            attemptCount: observed.attemptCount
        )
        try repository.reconcilePendingDownloads(
            waiting: [],
            terminal: [differentRecordToken],
            attemptedAt: now.addingTimeInterval(1)
        )
        XCTAssertEqual(try repository.pendingDownloads(), [observed])

        let differentDependencyToken = SyncPendingDownloadRecord(
            record: observed.record,
            generationID: observed.generationID,
            dependencies: [
                .label(TaskLabelID(UUID(uuidString: "AA000000-0000-0000-0000-000000000002")!))
            ],
            firstSeenAt: observed.firstSeenAt,
            lastAttemptedAt: observed.lastAttemptedAt,
            attemptCount: observed.attemptCount
        )
        try repository.reconcilePendingDownloads(
            waiting: [],
            terminal: [differentDependencyToken],
            attemptedAt: now.addingTimeInterval(1)
        )
        XCTAssertEqual(try repository.pendingDownloads(), [observed])
    }

    func testTerminalPendingDownloadCASRejectsABAAfterAnIdenticalRowIsRecreated() throws {
        let repository = SQLiteSyncRepository(databaseURL: makeDatabaseURL())
        let waiting = try makeWaitingRecord(
            modifiedAt: now,
            dependencies: [
                .taskChain(TaskChainID(UUID(uuidString: "AB000000-0000-0000-0000-000000000001")!))
            ]
        )
        try repository.reconcilePendingDownloads(
            waiting: [waiting],
            terminal: [],
            attemptedAt: now
        )
        let staleObservation = try XCTUnwrap(repository.pendingDownloads().first)
        try repository.reconcilePendingDownloads(
            waiting: [],
            terminal: [staleObservation],
            attemptedAt: now
        )
        XCTAssertTrue(try repository.pendingDownloads().isEmpty)

        try repository.reconcilePendingDownloads(
            waiting: [waiting],
            terminal: [],
            attemptedAt: now
        )
        let recreated = try XCTUnwrap(repository.pendingDownloads().first)
        XCTAssertNotEqual(recreated.generationID, staleObservation.generationID)
        try repository.reconcilePendingDownloads(
            waiting: [],
            terminal: [staleObservation],
            attemptedAt: now
        )

        XCTAssertEqual(try repository.pendingDownloads(), [recreated])
    }

    func testPendingDownloadRoundTripsEmbeddedNULInTextExactly() throws {
        let repository = SQLiteSyncRepository(databaseURL: makeDatabaseURL())
        let original = try makeWaitingRecord(
            modifiedAt: now,
            dependencies: [
                .taskChain(TaskChainID(UUID(uuidString: "A5000000-0000-0000-0000-000000000001")!))
            ]
        )
        var record = original.record
        record.modifiedByDeviceID = SyncDeviceID("\0remote-suffix")
        let waiting = SyncWaitingRecord(
            record: record,
            dependencies: original.dependencies
        )

        try repository.reconcilePendingDownloads(
            waiting: [waiting],
            terminal: [],
            attemptedAt: now
        )

        XCTAssertEqual(try repository.pendingDownloads().first?.record, record)
        XCTAssertEqual(
            try repository.pendingDownloads().first?.record.modifiedByDeviceID.rawValue.utf8.map { $0 },
            Array("\0remote-suffix".utf8)
        )
    }

    func testPendingDownloadsSortExactDatesChronologicallyBeforeTheReferenceDate() throws {
        let repository = SQLiteSyncRepository(databaseURL: makeDatabaseURL())
        let older = try makeWaitingRecord(
            modifiedAt: now,
            dependencies: [
                .taskChain(TaskChainID(UUID(uuidString: "AC000000-0000-0000-0000-000000000001")!))
            ]
        )
        let newer = try makeWaitingRecord(
            modifiedAt: now.addingTimeInterval(1),
            dependencies: [
                .taskChain(TaskChainID(UUID(uuidString: "AC000000-0000-0000-0000-000000000002")!))
            ]
        )
        let olderAttempt = Date(timeIntervalSinceReferenceDate: -2)
        let newerAttempt = Date(timeIntervalSinceReferenceDate: -1)

        try repository.reconcilePendingDownloads(
            waiting: [newer],
            terminal: [],
            attemptedAt: newerAttempt
        )
        try repository.reconcilePendingDownloads(
            waiting: [older],
            terminal: [],
            attemptedAt: olderAttempt
        )

        XCTAssertEqual(
            try repository.pendingDownloads().map(\.firstSeenAt),
            [olderAttempt, newerAttempt]
        )
    }

    func testPendingDownloadRejectsNonFiniteDatesBeforeWriting() throws {
        let repository = SQLiteSyncRepository(databaseURL: makeDatabaseURL())
        let valid = try makeWaitingRecord(
            modifiedAt: now,
            dependencies: [
                .taskChain(TaskChainID(UUID(uuidString: "A6000000-0000-0000-0000-000000000001")!))
            ]
        )

        XCTAssertThrowsError(
            try repository.reconcilePendingDownloads(
                waiting: [valid],
                terminal: [],
                attemptedAt: Date(timeIntervalSinceReferenceDate: .nan)
            )
        ) { error in
            guard case SQLiteRepositoryError.invalidStoredValue = error else {
                return XCTFail("expected invalid stored value, got \(error)")
            }
        }

        var invalidRecord = valid.record
        invalidRecord.modifiedAt = Date(timeIntervalSinceReferenceDate: .infinity)
        XCTAssertThrowsError(
            try repository.reconcilePendingDownloads(
                waiting: [
                    SyncWaitingRecord(
                        record: invalidRecord,
                        dependencies: valid.dependencies
                    )
                ],
                terminal: [],
                attemptedAt: now
            )
        ) { error in
            guard case SQLiteRepositoryError.invalidStoredValue = error else {
                return XCTFail("expected invalid stored value, got \(error)")
            }
        }

        XCTAssertTrue(try repository.pendingDownloads().isEmpty)
    }

    func testPendingDownloadSchemaRejectsNonIntegerAttemptFacts() throws {
        let databaseURL = makeDatabaseURL()
        let repository = SQLiteSyncRepository(databaseURL: databaseURL)
        let waiting = try makeWaitingRecord(
            modifiedAt: now,
            dependencies: [
                .taskChain(TaskChainID(UUID(uuidString: "A7000000-0000-0000-0000-000000000001")!))
            ]
        )
        try repository.reconcilePendingDownloads(
            waiting: [waiting],
            terminal: [],
            attemptedAt: now
        )

        XCTAssertThrowsError(
            try executeProbeSQL(
                "UPDATE sync_pending_download_records SET attempt_count = 1.5",
                at: databaseURL
            )
        )
        XCTAssertEqual(try repository.pendingDownloads().first?.attemptCount, 1)
    }

    func testPendingDownloadReaderRejectsNonIntegerDateBitsEvenIfChecksAreBypassed() throws {
        let databaseURL = makeDatabaseURL()
        let repository = SQLiteSyncRepository(databaseURL: databaseURL)
        let waiting = try makeWaitingRecord(
            modifiedAt: now,
            dependencies: [
                .taskChain(TaskChainID(UUID(uuidString: "A8000000-0000-0000-0000-000000000001")!))
            ]
        )
        try repository.reconcilePendingDownloads(
            waiting: [waiting],
            terminal: [],
            attemptedAt: now
        )
        try executeProbeSQL(
            """
            PRAGMA ignore_check_constraints = ON;
            UPDATE sync_pending_download_records SET modified_at_bits = 1.5;
            """,
            at: databaseURL
        )

        XCTAssertThrowsError(try repository.pendingDownloads()) { error in
            guard case SQLiteRepositoryError.invalidStoredValue = error else {
                return XCTFail("expected invalid stored value, got \(error)")
            }
        }
    }

    func testPendingDownloadReaderRejectsAttemptCountOutsideSupportedRange() throws {
        let databaseURL = makeDatabaseURL()
        let repository = SQLiteSyncRepository(databaseURL: databaseURL)
        let waiting = try makeWaitingRecord(
            modifiedAt: now,
            dependencies: [
                .taskChain(TaskChainID(UUID(uuidString: "A9000000-0000-0000-0000-000000000001")!))
            ]
        )
        try repository.reconcilePendingDownloads(
            waiting: [waiting],
            terminal: [],
            attemptedAt: now
        )
        try executeProbeSQL(
            """
            PRAGMA ignore_check_constraints = ON;
            UPDATE sync_pending_download_records SET attempt_count = 4294967297;
            """,
            at: databaseURL
        )

        XCTAssertThrowsError(try repository.pendingDownloads()) { error in
            guard case SQLiteRepositoryError.invalidStoredValue = error else {
                return XCTFail("expected invalid stored value, got \(error)")
            }
        }
    }

    func testConflictsCanBeStoredQueriedAndResolved() throws {
        let repository = SQLiteSyncRepository(databaseURL: makeDatabaseURL())
        let remoteRecord = SyncRecord(
            id: SyncRecordID("trace:remote"),
            entityType: .dayTrace,
            entityID: "trace-a",
            modifiedAt: now,
            modifiedByDeviceID: SyncDeviceID("iphone-b"),
            payload: Data([0x00, 0x7F, 0x80, 0xFF])
        )
        let conflict = SyncConflict(
            type: .historicalTraceMutation,
            entityType: .dayTrace,
            entityID: "trace-a",
            localRecordID: SyncRecordID("trace:local"),
            remoteRecord: remoteRecord,
            detectedAt: now,
            message: "历史轨迹不可被远端静默覆盖"
        )

        try repository.saveConflict(conflict)

        XCTAssertEqual(try repository.unresolvedConflicts(), [conflict])

        try repository.resolveConflict(id: conflict.id, resolution: .keepLocal, resolvedAt: now.addingTimeInterval(10))

        XCTAssertTrue(try repository.unresolvedConflicts().isEmpty)
    }

    func testConflictReadRejectsCorruptedRemoteEvidence() throws {
        let databaseURL = makeDatabaseURL()
        let repository = SQLiteSyncRepository(databaseURL: databaseURL)
        let remoteRecord = SyncRecord(
            id: SyncRecordID("classification-commit:corrupted"),
            entityType: .classificationCommit,
            entityID: "corrupted",
            modifiedAt: now,
            modifiedByDeviceID: SyncDeviceID("iphone-b"),
            payload: Data([0x00, 0x01, 0x02])
        )
        let conflict = SyncConflict(
            type: .classificationCommitRejected,
            entityType: .classificationCommit,
            entityID: "corrupted",
            remoteRecord: remoteRecord,
            detectedAt: now,
            message: "证据必须可复核"
        )
        try repository.saveConflict(conflict)
        try executeProbeSQL(
            "UPDATE sync_conflicts SET remote_payload = X'00'",
            at: databaseURL
        )

        XCTAssertThrowsError(try repository.unresolvedConflicts()) { error in
            guard case SQLiteRepositoryError.invalidStoredValue = error else {
                return XCTFail("expected invalid stored value, got \(error)")
            }
        }
    }

    func testAuditLogPersistsMostRecentEntriesFirst() throws {
        let repository = SQLiteSyncRepository(databaseURL: makeDatabaseURL())
        let older = SyncAuditLogEntry(
            direction: .upload,
            entityType: .taskChain,
            entityID: "chain-a",
            action: "uploaded",
            createdAt: now,
            message: "上传任务链"
        )
        let newer = SyncAuditLogEntry(
            direction: .merge,
            entityType: .dayTrace,
            entityID: "trace-a",
            action: "conflict",
            createdAt: now.addingTimeInterval(1),
            message: "检测到冲突"
        )

        try repository.appendAuditLog(older)
        try repository.appendAuditLog(newer)

        XCTAssertEqual(try repository.auditLog().map(\.id), [newer.id, older.id])
        XCTAssertEqual(try repository.auditLog(limit: 1), [newer])
    }

    func testEngineSaveCanRecordDomainChangesIntoSyncJournal() throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let deviceID = SyncDeviceID("mac-a")
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "先保存基础任务", now: now)

        try engineRepository.save(engine.snapshot())

        XCTAssertTrue(try syncRepository.journalEntries().isEmpty)

        let traceID = try engine.scheduleFromPool(chainID: chainID, date: today, today: today, now: now)
        let subtaskID = try engine.addSubtask(traceID: traceID, title: "写入同步队列", difficulty: .medium, now: now)
        try engineRepository.save(engine.snapshot(), recordingChangesFor: deviceID, changedAt: now.addingTimeInterval(10))

        let scheduledEntries = try syncRepository.journalEntries(state: .pendingUpload)
        XCTAssertEqual(scheduledEntries.map(\.entityType), [.day, .dayTrace, .subtask])
        XCTAssertEqual(Set(scheduledEntries.map(\.deviceID)), [deviceID])

        try syncRepository.markJournalEntriesUploaded(scheduledEntries.map(\.id))
        try engineRepository.save(engine.snapshot(), recordingChangesFor: deviceID, changedAt: now.addingTimeInterval(20))

        XCTAssertTrue(try syncRepository.journalEntries(state: .pendingUpload).isEmpty)

        engine.updateDailyReview(date: today, summary: "同步保存复盘", unfinishedReason: nil, tomorrowNote: nil, now: now.addingTimeInterval(30))
        try engine.updateSubtaskDifficulty(subtaskID, difficulty: .hard, today: today)
        try engineRepository.save(engine.snapshot(), recordingChangesFor: deviceID, changedAt: now.addingTimeInterval(30))

        XCTAssertEqual(try syncRepository.journalEntries(state: .pendingUpload).map(\.entityType), [.day, .subtask])
    }

    func testEngineSavePersistsEveryManagementDeltaKindAsImmutableOutboxPayload() throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let engine = SuntraceEngine()
        var ordinal = 0

        @discardableResult
        func commit(_ intent: ClassificationIntent) throws -> ClassificationReceipt {
            ordinal += 1
            let time = now.addingTimeInterval(TimeInterval(ordinal))
            let plan = try engine.prepareClassification(
                intent,
                source: .userDirect,
                interactionID: UUID(),
                now: time
            )
            return try engine.commitClassification(
                plan,
                confirmation: .user(decisionID: UUID()),
                now: time
            )
        }

        _ = try commit(.createCategory(name: "Outbox 来源", colorHex: "#2A6FDB"))
        _ = try commit(.createCategory(name: "Outbox 目标", colorHex: "#0E9488"))
        _ = try commit(.createLabel(name: "Outbox 标签", colorHex: "#7C5CFF"))
        let initial = engine.snapshot().classifications
        let sourceCategoryID = try XCTUnwrap(
            initial.categories.values.first { $0.name == "Outbox 来源" }?.id
        )
        let targetCategoryID = try XCTUnwrap(
            initial.categories.values.first { $0.name == "Outbox 目标" }?.id
        )
        let labelID = try XCTUnwrap(initial.labels.keys.first)
        try engineRepository.save(engine.snapshot())

        func saveAndAssert(
            _ intent: ClassificationIntent,
            expectedKind: String
        ) throws {
            let receipt = try commit(intent)
            try engineRepository.save(
                engine.snapshot(),
                recordingChangesFor: SyncDeviceID("mac-management"),
                changedAt: now.addingTimeInterval(TimeInterval(ordinal))
            )
            let entry = try XCTUnwrap(
                syncRepository.journalEntries(state: .pendingUpload).first
            )
            XCTAssertEqual(entry.entityType, .classificationCommit)
            XCTAssertEqual(entry.entityID, receipt.changeRecordID.uuidString)
            let envelope = try ClassificationCommitEnvelope.decode(
                try XCTUnwrap(entry.recordPayload)
            )
            let actualKind = switch envelope.delta {
            case .setCurrent:
                "setCurrent"
            case .create:
                "create"
            case .rename:
                "rename"
            case .lifecycle:
                "lifecycle"
            case .merge:
                "merge"
            case .hardDelete:
                "hardDelete"
            }
            XCTAssertEqual(actualKind, expectedKind)
            try syncRepository.markJournalEntriesUploaded([entry.id])
        }

        try saveAndAssert(
            .renameCategory(sourceCategoryID, to: "Outbox 来源 v2"),
            expectedKind: "rename"
        )
        try saveAndAssert(.archiveLabel(labelID), expectedKind: "lifecycle")
        try saveAndAssert(
            .mergeCategory(source: sourceCategoryID, into: targetCategoryID),
            expectedKind: "merge"
        )
        try saveAndAssert(.hardDeleteLabel(labelID), expectedKind: "hardDelete")

        XCTAssertEqual(try engineRepository.load().snapshot(), engine.snapshot())
        XCTAssertTrue(try syncRepository.journalEntries(state: .pendingUpload).isEmpty)
    }

    func testEngineSaveRollsBackSnapshotAndJournalWhenJournalIdentityCollides() throws {
        let databaseURL = makeDatabaseURL()
        let collisionID = UUID(uuidString: "A2000000-0000-0000-0000-000000000005")!
        let engineRepository = SQLiteEngineRepository(
            databaseURL: databaseURL,
            journalEntryIDGenerator: { collisionID }
        )
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "验证 journal 原子保存", now: now)
        let before = engine.snapshot()
        try engineRepository.save(before)

        _ = try engine.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )
        let after = engine.snapshot()

        XCTAssertThrowsError(
            try engineRepository.save(
                after,
                recordingChangesFor: SyncDeviceID("mac-collision"),
                changedAt: now.addingTimeInterval(2)
            )
        ) { error in
            guard case let SQLiteRepositoryError.invalidStoredValue(message) = error else {
                return XCTFail("expected invalid stored value, got \(error)")
            }
            XCTAssertTrue(message.contains("sync journal identity collision"))
        }
        XCTAssertEqual(try engineRepository.load().snapshot(), before)
        XCTAssertTrue(try syncRepository.journalEntries().isEmpty)

        try SQLiteEngineRepository(databaseURL: databaseURL).save(
            after,
            recordingChangesFor: SyncDeviceID("mac-collision"),
            changedAt: now.addingTimeInterval(2)
        )

        XCTAssertEqual(try engineRepository.load().snapshot(), after)
        XCTAssertFalse(try syncRepository.journalEntries().isEmpty)
    }

    func testDownloadedMergeTransactionRollsBackEveryFactWhenAuditWriteFails() throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let before = SuntraceEngine().snapshot()
        try engineRepository.save(before)

        let baselineWaiting = try makeWaitingRecord(
            modifiedAt: now,
            dependencies: [.taskChain(TaskChainID())]
        )
        try syncRepository.reconcilePendingDownloads(
            waiting: [baselineWaiting],
            terminal: [],
            attemptedAt: now
        )
        let baselinePending = try syncRepository.pendingDownloads()
        let baselineAudit = SyncAuditLogEntry(
            id: UUID(uuidString: "A2000000-0000-0000-0000-000000000008")!,
            direction: .download,
            entityType: .day,
            entityID: "baseline-day",
            action: "baseline",
            createdAt: now,
            message: "must survive rollback"
        )
        let baselineMetadata = SyncMetadataEntry(
            key: "generic.download.lastFetch",
            value: Data([0x51, 0x00, 0x52]),
            updatedAt: now
        )
        try syncRepository.appendAuditLog(baselineAudit)
        try syncRepository.saveMetadata(baselineMetadata)

        let merged = SuntraceEngine()
        _ = try merged.createPoolTask(
            title: "事务失败不得留下任务",
            now: now.addingTimeInterval(1)
        )
        let newWaiting = try makeWaitingRecord(
            modifiedAt: now.addingTimeInterval(1),
            dependencies: [.taskChain(TaskChainID())]
        )
        let remoteRecord = SyncRecord(
            id: SyncRecordID("day:transaction-conflict"),
            entityType: .day,
            entityID: "transaction-conflict",
            modifiedAt: now.addingTimeInterval(1),
            modifiedByDeviceID: SyncDeviceID("remote-mac"),
            payload: Data([0x61, 0x00, 0x62])
        )
        let conflict = SyncConflict(
            type: .invalidRecordPayload,
            entityType: remoteRecord.entityType,
            entityID: remoteRecord.entityID,
            remoteRecord: remoteRecord,
            detectedAt: now.addingTimeInterval(2),
            message: "must roll back"
        )
        let collidingAuditID = UUID(
            uuidString: "A2000000-0000-0000-0000-000000000010"
        )!
        let auditEntries = [
            SyncAuditLogEntry(
                id: collidingAuditID,
                direction: .download,
                entityType: .taskChain,
                entityID: "first",
                action: "merged",
                createdAt: now.addingTimeInterval(2)
            ),
            SyncAuditLogEntry(
                id: collidingAuditID,
                direction: .download,
                entityType: .classificationCommit,
                entityID: "second",
                action: "waiting",
                createdAt: now.addingTimeInterval(2)
            )
        ]
        let replacementMetadata = SyncMetadataEntry(
            key: baselineMetadata.key,
            value: Data([0x71, 0x00, 0x72]),
            updatedAt: now.addingTimeInterval(2)
        )

        XCTAssertThrowsError(
            try syncRepository.commitDownloadedMerge(
                SQLiteSyncDownloadCommit(
                    snapshot: merged.snapshot(),
                    conflicts: [conflict],
                    waiting: [newWaiting],
                    terminal: baselinePending,
                    auditEntries: auditEntries,
                    metadata: replacementMetadata,
                    attemptedAt: now.addingTimeInterval(2)
                )
            )
        )

        XCTAssertEqual(try engineRepository.load().snapshot(), before)
        XCTAssertEqual(try syncRepository.pendingDownloads(), baselinePending)
        XCTAssertTrue(try syncRepository.unresolvedConflicts().isEmpty)
        XCTAssertEqual(try syncRepository.auditLog(), [baselineAudit])
        XCTAssertEqual(
            try syncRepository.metadata(for: baselineMetadata.key),
            baselineMetadata
        )
    }

    private func makeDatabaseURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("suntrace-sync-storage-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func makeWaitingRecord(
        modifiedAt: Date,
        dependencies: [ClassificationCommitDependency]
    ) throws -> SyncWaitingRecord {
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "待重试分类提交", now: modifiedAt)
        let before = engine.snapshot().classifications
        let plan = try engine.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .new(name: "远端分类", colorHex: "#2A6FDB"),
                    labels: [.new(name: "待同步", colorHex: "#0E9488")]
                )
            ),
            source: .userDirect,
            interactionID: UUID(),
            now: modifiedAt
        )
        let receipt = try engine.commitClassification(
            plan,
            confirmation: .user(decisionID: UUID()),
            now: modifiedAt
        )
        let after = engine.snapshot().classifications
        let changeRecord = try XCTUnwrap(
            after.changeRecords.first { $0.id == receipt.changeRecordID }
        )
        let envelope = try ClassificationCommitEnvelope(
            before: before,
            after: after,
            changeRecord: changeRecord
        )
        return SyncWaitingRecord(
            record: try SyncRecordMapper().record(
                for: envelope,
                modifiedBy: SyncDeviceID("remote-mac")
            ),
            dependencies: dependencies
        )
    }

    private func executeProbeSQL(_ sql: String, at databaseURL: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            sqlite3_close(database)
            throw SQLiteRepositoryError.openFailed("test probe could not open database")
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteRepositoryError.executeFailed("test probe SQL failed")
        }
    }

    private func integerScalar(_ sql: String, at databaseURL: URL) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            sqlite3_close(database)
            throw SQLiteRepositoryError.openFailed("test probe could not open database")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteRepositoryError.prepareFailed("test probe could not prepare scalar")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteRepositoryError.stepFailed("test probe could not read scalar")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func schemaDefinitions(at databaseURL: URL) throws -> [String: String] {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            sqlite3_close(database)
            throw SQLiteRepositoryError.openFailed("test probe could not open database")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            """
            SELECT type, name, sql
            FROM sqlite_master
            WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%'
            ORDER BY type, name
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw SQLiteRepositoryError.prepareFailed("test probe could not prepare schema query")
        }
        defer { sqlite3_finalize(statement) }

        var definitions: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let typeValue = sqlite3_column_text(statement, 0),
                  let nameValue = sqlite3_column_text(statement, 1),
                  let sqlValue = sqlite3_column_text(statement, 2)
            else {
                throw SQLiteRepositoryError.invalidStoredValue("test probe read a NULL schema value")
            }
            let type = String(cString: typeValue)
            let name = String(cString: nameValue)
            definitions["\(type):\(name)"] = String(cString: sqlValue)
        }
        guard sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE else {
            throw SQLiteRepositoryError.stepFailed("test probe could not read schema")
        }
        return definitions
    }
}
