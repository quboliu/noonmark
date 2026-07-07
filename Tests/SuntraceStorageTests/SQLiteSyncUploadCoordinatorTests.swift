@testable import SuntraceCore
@testable import SuntraceStorage
import SuntraceSync
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
        let engine = SuntraceEngine()
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

        try engineRepository.save(SuntraceEngine().snapshot())
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
    }

    func testTransportFailureMarksUploadableEntriesFailedAndThrows() async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let deviceID = SyncDeviceID("mac-a")
        let engine = SuntraceEngine()

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

    private func makeDatabaseURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("suntrace-sync-upload-\(UUID().uuidString)")
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

private actor FailingSyncTransport: SyncRecordTransport {
    func push(_ records: [SyncRecord]) async throws {
        throw TestSyncTransportError.unavailable
    }

    func fetchAll() async throws -> [SyncRecord] {
        []
    }
}
