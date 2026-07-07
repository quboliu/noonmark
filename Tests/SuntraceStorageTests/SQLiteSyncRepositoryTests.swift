@testable import SuntraceCore
@testable import SuntraceStorage
import SuntraceSync
import XCTest

final class SQLiteSyncRepositoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let today = LocalDate("2026-07-05")

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

    func testConflictsCanBeStoredQueriedAndResolved() throws {
        let repository = SQLiteSyncRepository(databaseURL: makeDatabaseURL())
        let conflict = SyncConflict(
            id: UUID(),
            type: .historicalTraceMutation,
            entityType: .dayTrace,
            entityID: "trace-a",
            localRecordID: SyncRecordID("trace:local"),
            remoteRecordID: SyncRecordID("trace:remote"),
            detectedAt: now,
            message: "历史轨迹不可被远端静默覆盖"
        )

        try repository.saveConflict(conflict)

        XCTAssertEqual(try repository.unresolvedConflicts(), [conflict])

        try repository.resolveConflict(id: conflict.id, resolution: .keepLocal, resolvedAt: now.addingTimeInterval(10))

        XCTAssertTrue(try repository.unresolvedConflicts().isEmpty)
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

    private func makeDatabaseURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("suntrace-sync-storage-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
