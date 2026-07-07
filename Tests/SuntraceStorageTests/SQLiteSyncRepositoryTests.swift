@testable import SuntraceStorage
import SuntraceSync
import XCTest

final class SQLiteSyncRepositoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

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
