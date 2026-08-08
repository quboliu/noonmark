@testable import NoonmarkCore
@testable import NoonmarkStorage
import NoonmarkSync
import XCTest

final class SQLiteSyncUploadCoordinatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let today = LocalDate("2026-07-05")

    func testUploadPendingPushesRecordsAndMarksJournalUploaded() async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let transport = InMemorySyncTransport()
        let deviceID = SyncDeviceID("mac-a")
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "上传同步记录", now: now)

        try engineRepository.save(engine.snapshot())

        let traceID = try engine.scheduleFromPool(chainID: chainID, date: today, today: today, now: now)
        _ = try engine.addSubtask(traceID: traceID, title: "进入上传队列", difficulty: .medium, now: now)
        try engineRepository.save(engine.snapshot(), recordingChangesFor: deviceID, changedAt: now.addingTimeInterval(10))

        let coordinator = SQLiteSyncUploadCoordinator(databaseURL: databaseURL, transport: transport)
        let result = try await coordinator.uploadPending()
        let uploadedRecords = try await transport.bootstrapRecords()

        XCTAssertEqual(result, SQLiteSyncUploadResult(pendingCount: 3, uploadedCount: 3, failedCount: 0))
        XCTAssertEqual(Set(uploadedRecords.map(\.entityType)), [.day, .dayTrace, .subtask])
        XCTAssertTrue(try syncRepository.journalEntries(state: .pendingUpload).isEmpty)
        XCTAssertEqual(try syncRepository.journalEntries(state: .uploaded).count, 3)
        XCTAssertEqual(Set(try syncRepository.auditLog().map(\.action)), ["uploaded"])
    }

    func testUploadSoftLimitNeverSplitsANewRecurringSeries() async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(
            databaseURL: databaseURL
        )
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let transport = InMemorySyncTransport()
        let deviceID = SyncDeviceID("mac-cycle")
        let engine = NoonmarkEngine()
        try engineRepository.save(engine.snapshot())

        _ = try engine.createTaskCycleSeries(
            title: "四十天复盘",
            startDate: today,
            endDate: LocalDate("2026-08-13"),
            schedule: .daily,
            today: today,
            now: now
        )
        try engineRepository.save(
            engine.snapshot(),
            recordingChangesFor: deviceID,
            changedAt: now
        )
        let journalCount = try syncRepository.journalEntries(
            state: .pendingUpload
        ).count
        XCTAssertGreaterThan(journalCount, 100)

        let coordinator = SQLiteSyncUploadCoordinator(
            databaseURL: databaseURL,
            transport: transport
        )
        let result = try await coordinator.uploadPending(limit: 100)
        let records = try await transport.bootstrapRecords()
        let mergeResult = SyncRecordMerger().merge(
            records: records,
            into: try ValidatedSyncSnapshot(
                NoonmarkEngine().snapshot()
            ),
            detectedAt: now.addingTimeInterval(1)
        )

        XCTAssertEqual(result.pendingCount, journalCount)
        XCTAssertEqual(result.uploadedCount, journalCount)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertTrue(
            try syncRepository.journalEntries(
                state: .pendingUpload
            ).isEmpty
        )
        XCTAssertTrue(mergeResult.conflicts.isEmpty)
        XCTAssertTrue(mergeResult.waitingRecords.isEmpty)
        XCTAssertNoThrow(try mergeResult.snapshot.validateIntegrity())
        XCTAssertEqual(mergeResult.snapshot.taskCycleSeries.count, 1)
        XCTAssertEqual(mergeResult.snapshot.chains.count, 40)
    }

    func testMissingEntityJournalEntryFailsClosedWithoutPushing() async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let transport = InMemorySyncTransport()
        let missingDay = SyncJournalEntry(
            entityType: .day,
            entityID: today.description,
            changedAt: now,
            deviceID: SyncDeviceID("mac-a")
        )

        try engineRepository.save(NoonmarkEngine().snapshot())
        try syncRepository.appendJournalEntry(missingDay)

        let coordinator = SQLiteSyncUploadCoordinator(databaseURL: databaseURL, transport: transport)
        let result = try await coordinator.uploadPending()
        let uploadedRecords = try await transport.bootstrapRecords()

        XCTAssertEqual(result, SQLiteSyncUploadResult(pendingCount: 1, uploadedCount: 0, failedCount: 1))
        XCTAssertTrue(uploadedRecords.isEmpty)

        let failed = try XCTUnwrap(
            syncRepository.journalEntries(state: .blockedCorruption).first
        )
        XCTAssertEqual(failed.id, missingDay.id)
        XCTAssertEqual(failed.retryCount, 1)
        XCTAssertTrue(failed.lastError?.contains("missingEntity") == true)
        XCTAssertEqual(try syncRepository.auditLog(limit: 1).first?.action, "materializationFailed")

        let retryResult = try await coordinator.uploadPending()
        XCTAssertEqual(
            retryResult,
            SQLiteSyncUploadResult(pendingCount: 0, uploadedCount: 0, failedCount: 1)
        )
        let failedAgain = try XCTUnwrap(
            syncRepository.journalEntries(state: .blockedCorruption).first
        )
        XCTAssertEqual(failedAgain.id, missingDay.id)
        XCTAssertEqual(failedAgain.retryCount, 1)
        XCTAssertTrue(try syncRepository.journalEntries(state: .uploaded).isEmpty)
        XCTAssertEqual(
            try syncRepository.auditLog().filter { $0.action == "materializationFailed" }.count,
            1
        )
    }

    func testTransientTransportFailureKeepsUploadPendingAndThrows() async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let deviceID = SyncDeviceID("mac-a")
        let engine = NoonmarkEngine()

        try engineRepository.save(engine.snapshot())
        engine.updateDailyReview(date: today, summary: "待上传复盘", unfinishedReason: nil, tomorrowNote: nil, now: now)
        try engineRepository.save(engine.snapshot(), recordingChangesFor: deviceID, changedAt: now)

        let coordinator = SQLiteSyncUploadCoordinator(databaseURL: databaseURL, transport: FailingSyncTransport())

        do {
            _ = try await coordinator.uploadPending()
            XCTFail("uploadPending should throw when transport push fails")
        } catch TestSyncTransportError.unavailable {
            let pending = try XCTUnwrap(
                syncRepository.journalEntries(
                    state: .pendingUpload
                ).first
            )
            XCTAssertEqual(pending.entityType, .day)
            XCTAssertEqual(pending.retryCount, 0)
            XCTAssertNil(pending.lastError)
            XCTAssertEqual(
                try syncRepository.auditLog(limit: 1).first?.action,
                "uploadRetryPending"
            )
        }
    }

    func testTransientTransportFailureRetriesPendingJournalAndAuditsRecovery() async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let transport = RecoveringSyncTransport()
        let deviceID = SyncDeviceID("mac-a")
        let engine = NoonmarkEngine()

        try engineRepository.save(engine.snapshot())
        engine.updateDailyReview(
            date: today,
            summary: "恢复后上传",
            unfinishedReason: nil,
            tomorrowNote: nil,
            now: now
        )
        try engineRepository.save(
            engine.snapshot(),
            recordingChangesFor: deviceID,
            changedAt: now
        )

        let coordinator = SQLiteSyncUploadCoordinator(
            databaseURL: databaseURL,
            transport: transport
        )
        do {
            _ = try await coordinator.uploadPending()
            XCTFail("首次瞬时失败必须抛错")
        } catch {
            XCTAssertEqual(error as? TestSyncTransportError, .unavailable)
        }

        let pending = try XCTUnwrap(
            syncRepository.journalEntries(state: .pendingUpload).first
        )
        XCTAssertEqual(pending.retryCount, 0)
        XCTAssertNil(pending.lastError)

        let recovered = try await coordinator.uploadPending()

        XCTAssertEqual(
            recovered,
            SQLiteSyncUploadResult(pendingCount: 1, uploadedCount: 1, failedCount: 0)
        )
        XCTAssertTrue(
            try syncRepository.journalEntries(
                state: .blockedCorruption
            ).isEmpty
        )
        let uploaded = try XCTUnwrap(syncRepository.journalEntries(state: .uploaded).first)
        XCTAssertEqual(uploaded.id, pending.id)
        XCTAssertEqual(uploaded.retryCount, 0)
        XCTAssertNil(uploaded.lastError)
        let pushAttemptCount = await transport.pushAttemptCount()
        XCTAssertEqual(pushAttemptCount, 2)
        XCTAssertEqual(
            Set(try syncRepository.auditLog().map(\.action)),
            ["uploadRetryPending", "uploaded"]
        )
    }

    func testBlockedCorruptionDoesNotPreventHealthyPendingUpload() async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let transport = InMemorySyncTransport()
        let deviceID = SyncDeviceID("mac-a")
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "父提交优先重试", now: now)
        let beforeClassification = engine.snapshot()
        let plan = try engine.prepareClassification(
            .createCategory(name: "依赖父项", colorHex: "#2A6FDB"),
            source: .userDirect,
            interactionID: UUID(),
            now: now.addingTimeInterval(20)
        )
        _ = try engine.commitClassification(
            plan,
            confirmation: .user(decisionID: UUID()),
            now: now.addingTimeInterval(20)
        )
        let afterClassification = engine.snapshot()
        let parentEntry = try XCTUnwrap(
            try SyncSnapshotDiffer().journalEntries(
                from: beforeClassification,
                to: afterClassification,
                changedAt: now.addingTimeInterval(20),
                deviceID: deviceID
            ).first { $0.entityType == .classificationCommit }
        )
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(30)
        )
        let childEntry = SyncJournalEntry(
            entityType: .dayTrace,
            entityID: traceID.rawValue.uuidString,
            changedAt: now,
            deviceID: deviceID
        )

        try engineRepository.save(engine.snapshot())
        try syncRepository.appendJournalEntry(parentEntry)
        try syncRepository.markJournalEntryBlockedCorruption(
            parentEntry.id,
            error: "deterministic"
        )
        try syncRepository.appendJournalEntry(childEntry)

        let coordinator = SQLiteSyncUploadCoordinator(
            databaseURL: databaseURL,
            transport: transport
        )
        let result = try await coordinator.uploadPending(limit: 1)

        XCTAssertEqual(
            result,
            SQLiteSyncUploadResult(pendingCount: 1, uploadedCount: 1, failedCount: 1)
        )
        let uploadedTypes = try await transport.bootstrapRecords().map(\.entityType)
        XCTAssertEqual(uploadedTypes, [.dayTrace])
        XCTAssertEqual(
            try syncRepository.journalEntries(state: .pendingUpload).map(\.id),
            []
        )
        XCTAssertEqual(
            try syncRepository.journalEntries(state: .uploaded).map(\.id),
            [childEntry.id]
        )
        XCTAssertEqual(
            try syncRepository.journalEntries(
                state: .blockedCorruption
            ).map(\.id),
            [parentEntry.id]
        )
    }

    func testPublishedLocalReceiptSurvivesRestartUntilTransportConfirms()
        async throws
    {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let transport = AwaitingConfirmationSyncTransport()
        let deviceID = SyncDeviceID("mac-confirmation")
        let engine = NoonmarkEngine()
        try engineRepository.save(engine.snapshot())
        engine.updateDailyReview(
            date: today,
            summary: "等待 iCloud 系统确认",
            unfinishedReason: nil,
            tomorrowNote: nil,
            now: now
        )
        try engineRepository.save(
            engine.snapshot(),
            recordingChangesFor: deviceID,
            changedAt: now
        )

        let first = try await SQLiteSyncUploadCoordinator(
            databaseURL: databaseURL,
            transport: transport
        ).uploadPending()
        XCTAssertEqual(
            first,
            SQLiteSyncUploadResult(
                pendingCount: 1,
                uploadedCount: 0,
                failedCount: 0,
                awaitingConfirmationCount: 1
            )
        )
        let published = try XCTUnwrap(
            syncRepository.journalEntries(state: .publishedLocal).first
        )
        XCTAssertNotNil(published.transportReceipt)

        let restarted = SQLiteSyncUploadCoordinator(
            databaseURL: databaseURL,
            transport: transport
        )
        let stillWaiting = try await restarted.uploadPending()
        XCTAssertEqual(stillWaiting.awaitingConfirmationCount, 1)
        XCTAssertTrue(
            try syncRepository.journalEntries(state: .uploaded).isEmpty
        )

        await transport.confirmUploads()
        let confirmed = try await restarted.uploadPending()
        XCTAssertEqual(
            confirmed,
            SQLiteSyncUploadResult(
                pendingCount: 0,
                uploadedCount: 1,
                failedCount: 0
            )
        )
        XCTAssertEqual(
            try syncRepository.journalEntries(state: .uploaded).map(\.id),
            [published.id]
        )
        XCTAssertEqual(
            Set(try syncRepository.auditLog().map(\.action)),
            ["publishedLocal", "uploadConfirmed"]
        )
    }

    func testConsecutivePreferenceMutationsSurviveRestartAndLimitedUploads() async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let transport = InMemorySyncTransport()
        let deviceID = SyncDeviceID("mac-preferences")
        let firstClock = now.addingTimeInterval(10)
        let secondClock = now.addingTimeInterval(20)
        let engine = NoonmarkEngine()
        try engineRepository.save(engine.snapshot())

        try engine.updateTheme(
            .warmPaper,
            writerID: deviceID.rawValue,
            now: firstClock
        )
        try engineRepository.save(
            engine.snapshot(),
            recordingChangesFor: deviceID,
            changedAt: firstClock
        )
        try engine.updateLanguage(
            .english,
            writerID: deviceID.rawValue,
            now: secondClock
        )
        try engineRepository.save(
            engine.snapshot(),
            recordingChangesFor: deviceID,
            changedAt: secondClock
        )

        let pending = try syncRepository.journalEntries(
            state: .pendingUpload
        )
        XCTAssertEqual(pending.map(\.entityType), [
            .appPreferences,
            .appPreferences
        ])
        XCTAssertTrue(pending.allSatisfy { $0.recordPayload?.isEmpty == false })

        let firstCoordinator = SQLiteSyncUploadCoordinator(
            databaseURL: databaseURL,
            transport: transport
        )
        let firstResult = try await firstCoordinator.uploadPending(limit: 1)
        let firstRemoteRecords = try await transport.bootstrapRecords()
        let firstRemote = try XCTUnwrap(
            firstRemoteRecords.first
        )
        let firstEnvelope = try SyncRecordMapper()
            .decodeAppPreferences(firstRemote)

        XCTAssertEqual(
            firstResult,
            SQLiteSyncUploadResult(
                pendingCount: 1,
                uploadedCount: 1,
                failedCount: 0
            )
        )
        XCTAssertEqual(firstEnvelope.theme, .warmPaper)
        XCTAssertEqual(firstEnvelope.language, .chinese)
        XCTAssertEqual(
            firstEnvelope.updatedAt.timeIntervalSinceReferenceDate.bitPattern,
            firstClock.timeIntervalSinceReferenceDate.bitPattern
        )
        XCTAssertEqual(
            try syncRepository.journalEntries(state: .pendingUpload).count,
            1
        )

        let restartedCoordinator = SQLiteSyncUploadCoordinator(
            databaseURL: databaseURL,
            transport: transport
        )
        let secondResult = try await restartedCoordinator.uploadPending(
            limit: 1
        )
        let finalRemoteRecords = try await transport.bootstrapRecords()
        let finalRemote = try XCTUnwrap(
            finalRemoteRecords.first
        )
        let finalEnvelope = try SyncRecordMapper()
            .decodeAppPreferences(finalRemote)

        XCTAssertEqual(
            secondResult,
            SQLiteSyncUploadResult(
                pendingCount: 1,
                uploadedCount: 1,
                failedCount: 0
            )
        )
        XCTAssertEqual(finalEnvelope.theme, .warmPaper)
        XCTAssertEqual(finalEnvelope.language, .english)
        XCTAssertEqual(
            finalEnvelope.updatedAt.timeIntervalSinceReferenceDate.bitPattern,
            secondClock.timeIntervalSinceReferenceDate.bitPattern
        )
        XCTAssertTrue(
            try syncRepository.journalEntries(state: .pendingUpload).isEmpty
        )
        XCTAssertTrue(
            try syncRepository.journalEntries(
                state: .blockedCorruption
            ).isEmpty
        )
        XCTAssertEqual(
            try syncRepository.journalEntries(state: .uploaded).count,
            2
        )
        XCTAssertEqual(
            try syncRepository.auditLog().filter { $0.action == "uploaded" }
                .count,
            2
        )
    }

    func testConsecutivePreferenceMutationsUploadTogetherToLatestCurrentRecord() async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let transport = InMemorySyncTransport()
        let deviceID = SyncDeviceID("mac-preferences-batch")
        let firstClock = now.addingTimeInterval(30)
        let secondClock = now.addingTimeInterval(40)
        let engine = NoonmarkEngine()
        try engineRepository.save(engine.snapshot())

        try engine.updateTheme(
            .warmPaper,
            writerID: deviceID.rawValue,
            now: firstClock
        )
        try engineRepository.save(
            engine.snapshot(),
            recordingChangesFor: deviceID,
            changedAt: firstClock
        )
        try engine.updateLanguage(
            .english,
            writerID: deviceID.rawValue,
            now: secondClock
        )
        try engineRepository.save(
            engine.snapshot(),
            recordingChangesFor: deviceID,
            changedAt: secondClock
        )

        let result = try await SQLiteSyncUploadCoordinator(
            databaseURL: databaseURL,
            transport: transport
        ).uploadPending()
        let remoteRecords = try await transport.bootstrapRecords()
        let remote = try XCTUnwrap(remoteRecords.first)
        let envelope = try SyncRecordMapper().decodeAppPreferences(remote)

        XCTAssertEqual(
            result,
            SQLiteSyncUploadResult(
                pendingCount: 2,
                uploadedCount: 2,
                failedCount: 0
            )
        )
        XCTAssertTrue(
            try syncRepository.journalEntries(state: .pendingUpload).isEmpty
        )
        XCTAssertTrue(
            try syncRepository.journalEntries(
                state: .blockedCorruption
            ).isEmpty
        )
        XCTAssertEqual(
            try syncRepository.journalEntries(state: .uploaded).count,
            2
        )
        XCTAssertEqual(remoteRecords.count, 1)
        XCTAssertEqual(envelope.theme, .warmPaper)
        XCTAssertEqual(envelope.language, .english)
        XCTAssertEqual(
            envelope.updatedAt.timeIntervalSinceReferenceDate.bitPattern,
            secondClock.timeIntervalSinceReferenceDate.bitPattern
        )
    }

    func testCommittedPreferenceBatchRetryRemainsCanonicalAndUploadsBothJournals() async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let transport = CommitThenThrowOnceSyncTransport()
        let deviceID = SyncDeviceID("mac-preferences-retry")
        let firstClock = now.addingTimeInterval(30)
        let secondClock = now.addingTimeInterval(40)
        let engine = NoonmarkEngine()
        try engineRepository.save(engine.snapshot())

        try engine.updateTheme(
            .warmPaper,
            writerID: deviceID.rawValue,
            now: firstClock
        )
        try engineRepository.save(
            engine.snapshot(),
            recordingChangesFor: deviceID,
            changedAt: firstClock
        )
        try engine.updateLanguage(
            .english,
            writerID: deviceID.rawValue,
            now: secondClock
        )
        try engineRepository.save(
            engine.snapshot(),
            recordingChangesFor: deviceID,
            changedAt: secondClock
        )
        let coordinator = SQLiteSyncUploadCoordinator(
            databaseURL: databaseURL,
            transport: transport
        )

        do {
            _ = try await coordinator.uploadPending()
            XCTFail("committed transport failure must remain visible")
        } catch {
            XCTAssertEqual(error as? TestSyncTransportError, .unavailable)
        }
        let committedRecords = try await transport.bootstrapRecords()
        XCTAssertEqual(committedRecords.count, 1)
        XCTAssertEqual(
            try syncRepository.journalEntries(
                state: .pendingUpload
            ).count,
            2
        )

        let result = try await coordinator.uploadPending()
        let retriedRecords = try await transport.bootstrapRecords()
        let remote = try XCTUnwrap(retriedRecords.first)
        let envelope = try SyncRecordMapper().decodeAppPreferences(remote)

        XCTAssertEqual(
            result,
            SQLiteSyncUploadResult(
                pendingCount: 2,
                uploadedCount: 2,
                failedCount: 0
            )
        )
        XCTAssertEqual(
            try syncRepository.journalEntries(state: .uploaded).count,
            2
        )
        XCTAssertTrue(
            try syncRepository.journalEntries(
                state: .blockedCorruption
            ).isEmpty
        )
        XCTAssertEqual(envelope.language, .english)
        XCTAssertEqual(envelope.writerDeviceID, deviceID)
        XCTAssertEqual(
            envelope.updatedAt.timeIntervalSinceReferenceDate.bitPattern,
            secondClock.timeIntervalSinceReferenceDate.bitPattern
        )
    }

    private func makeDatabaseURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("noonmark-sync-upload-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

private enum TestSyncTransportError: Error {
    case unavailable
}

private actor RecoveringSyncTransport: SyncRecordTransport {
    private var attempts = 0
    private var records: [SyncRecordID: SyncRecord] = [:]

    func pushAccepting(
        _ records: [SyncRecord]
    ) async throws -> SyncTransportPushReceipt {
        attempts += 1
        guard attempts > 1 else {
            throw TestSyncTransportError.unavailable
        }
        for record in records {
            self.records[record.id] = record
        }
        return fixturePushReceipt()
    }

    func pull(
        after frontier: SyncTransportFrontier,
        limit _: Int
    ) async throws -> SyncTransportChangePage {
        fixturePage(records: Array(records.values), after: frontier)
    }

    func pushAttemptCount() -> Int {
        attempts
    }
}

private actor CommitThenThrowOnceSyncTransport: SyncRecordTransport {
    private let transport = InMemorySyncTransport()
    private var didThrow = false

    func pushAccepting(
        _ records: [SyncRecord]
    ) async throws -> SyncTransportPushReceipt {
        let receipt = try await transport.pushAccepting(records)
        guard didThrow else {
            didThrow = true
            throw TestSyncTransportError.unavailable
        }
        return receipt
    }

    func pull(
        after frontier: SyncTransportFrontier,
        limit: Int
    ) async throws -> SyncTransportChangePage {
        try await transport.pull(after: frontier, limit: limit)
    }
}

private actor FailingSyncTransport: SyncRecordTransport {
    func pushAccepting(
        _: [SyncRecord]
    ) async throws -> SyncTransportPushReceipt {
        throw TestSyncTransportError.unavailable
    }

    func pull(
        after frontier: SyncTransportFrontier,
        limit _: Int
    ) async throws -> SyncTransportChangePage {
        fixturePage(records: [], after: frontier)
    }
}

private actor AwaitingConfirmationSyncTransport: SyncRecordTransport {
    private var isConfirmed = false
    private var records: [SyncRecord] = []

    func pushAccepting(
        _ records: [SyncRecord]
    ) async throws -> SyncTransportPushReceipt {
        self.records = records
        return SyncTransportPushReceipt(
            batches: [
                SyncTransportBatchReference(
                    producerID: "test-producer",
                    sequence: 1,
                    contentHash: String(repeating: "a", count: 64),
                    artifactPaths: ["batches/test/0001.json"]
                )
            ],
            confirmation: .awaitingUploadConfirmation
        )
    }

    func confirmationStatus(
        for _: SyncTransportPushReceipt
    ) async throws -> SyncTransportConfirmation {
        isConfirmed ? .confirmed : .awaitingUploadConfirmation
    }

    func pull(
        after frontier: SyncTransportFrontier,
        limit _: Int
    ) async throws -> SyncTransportChangePage {
        SyncTransportChangePage(
            records: records,
            frontier: frontier,
            hasMore: false,
            observedProducerCount: 1
        )
    }

    func confirmUploads() {
        isConfirmed = true
    }
}
