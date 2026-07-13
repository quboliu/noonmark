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
        let uploadedRecords = try await transport.fetchAll()

        XCTAssertEqual(result, SQLiteSyncUploadResult(pendingCount: 3, uploadedCount: 3, failedCount: 0))
        XCTAssertEqual(Set(uploadedRecords.map(\.entityType)), [.day, .dayTrace, .subtask])
        XCTAssertTrue(try syncRepository.journalEntries(state: .pendingUpload).isEmpty)
        XCTAssertEqual(try syncRepository.journalEntries(state: .uploaded).count, 3)
        XCTAssertEqual(Set(try syncRepository.auditLog().map(\.action)), ["uploaded"])
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
        let uploadedRecords = try await transport.fetchAll()

        XCTAssertEqual(result, SQLiteSyncUploadResult(pendingCount: 1, uploadedCount: 0, failedCount: 1))
        XCTAssertTrue(uploadedRecords.isEmpty)

        let failed = try XCTUnwrap(syncRepository.journalEntries(state: .failed).first)
        XCTAssertEqual(failed.id, missingDay.id)
        XCTAssertEqual(failed.retryCount, 1)
        XCTAssertTrue(failed.lastError?.contains("missingEntity") == true)
        XCTAssertEqual(try syncRepository.auditLog(limit: 1).first?.action, "materializationFailed")

        let retryResult = try await coordinator.uploadPending()
        XCTAssertEqual(
            retryResult,
            SQLiteSyncUploadResult(pendingCount: 1, uploadedCount: 0, failedCount: 1)
        )
        let failedAgain = try XCTUnwrap(syncRepository.journalEntries(state: .failed).first)
        XCTAssertEqual(failedAgain.id, missingDay.id)
        XCTAssertEqual(failedAgain.retryCount, 2)
        XCTAssertTrue(try syncRepository.journalEntries(state: .uploaded).isEmpty)
        XCTAssertEqual(
            try syncRepository.auditLog().filter { $0.action == "materializationFailed" }.count,
            2
        )
    }

    func testTransportFailureMarksUploadableEntriesFailedAndThrows() async throws {
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
            let failed = try XCTUnwrap(syncRepository.journalEntries(state: .failed).first)
            XCTAssertEqual(failed.entityType, .day)
            XCTAssertEqual(failed.retryCount, 1)
            XCTAssertTrue(failed.lastError?.contains("unavailable") == true)
            XCTAssertEqual(try syncRepository.auditLog(limit: 1).first?.action, "uploadFailed")
        }
    }

    func testTransientTransportFailureRetriesFailedJournalAndAuditsRecovery() async throws {
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

        let failed = try XCTUnwrap(syncRepository.journalEntries(state: .failed).first)
        XCTAssertEqual(failed.retryCount, 1)
        XCTAssertTrue(failed.lastError?.contains("unavailable") == true)

        let recovered = try await coordinator.uploadPending()

        XCTAssertEqual(
            recovered,
            SQLiteSyncUploadResult(pendingCount: 1, uploadedCount: 1, failedCount: 0)
        )
        XCTAssertTrue(try syncRepository.journalEntries(state: .failed).isEmpty)
        let uploaded = try XCTUnwrap(syncRepository.journalEntries(state: .uploaded).first)
        XCTAssertEqual(uploaded.id, failed.id)
        XCTAssertEqual(uploaded.retryCount, 1)
        XCTAssertNil(uploaded.lastError)
        let pushAttemptCount = await transport.pushAttemptCount()
        XCTAssertEqual(pushAttemptCount, 2)
        XCTAssertEqual(
            Set(try syncRepository.auditLog().map(\.action)),
            ["uploadFailed", "uploaded"]
        )
    }

    func testFailedClassificationParentKeepsGlobalPriorityAheadOfOlderPendingChild() async throws {
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
        try syncRepository.markJournalEntryFailed(parentEntry.id, error: "transient")
        try syncRepository.appendJournalEntry(childEntry)

        let coordinator = SQLiteSyncUploadCoordinator(
            databaseURL: databaseURL,
            transport: transport
        )
        let result = try await coordinator.uploadPending(limit: 1)

        XCTAssertEqual(
            result,
            SQLiteSyncUploadResult(pendingCount: 1, uploadedCount: 1, failedCount: 0)
        )
        let uploadedTypes = try await transport.fetchAll().map(\.entityType)
        XCTAssertEqual(uploadedTypes, [.classificationCommit])
        XCTAssertEqual(
            try syncRepository.journalEntries(state: .pendingUpload).map(\.id),
            [childEntry.id]
        )
        XCTAssertEqual(
            try syncRepository.journalEntries(state: .uploaded).map(\.id),
            [parentEntry.id]
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

    func push(_ records: [SyncRecord]) async throws {
        attempts += 1
        guard attempts > 1 else {
            throw TestSyncTransportError.unavailable
        }
        for record in records {
            self.records[record.id] = record
        }
    }

    func fetchAll() async throws -> [SyncRecord] {
        Array(records.values)
    }

    func pushAttemptCount() -> Int {
        attempts
    }
}

private actor FailingSyncTransport: SyncRecordTransport {
    func push(_ records: [SyncRecord]) async throws {
        throw TestSyncTransportError.unavailable
    }

    func fetchAll() async throws -> [SyncRecord] {
        []
    }
}
