@testable import SuntraceCore
@testable import SuntraceStorage
import SuntraceSync
import XCTest

final class SQLiteSyncDownloadCoordinatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let today = LocalDate("2026-07-05")

    func testDownloadAndMergeAppliesRemoteRecordsWithoutCreatingUploadJournal() async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let source = SuntraceEngine()
        let chainID = try source.createPoolTask(title: "从远端下载任务", now: now)
        let traceID = try source.scheduleFromPool(chainID: chainID, date: today, today: today, now: now)
        _ = try source.addSubtask(traceID: traceID, title: "合并远端子任务", difficulty: .hard, now: now)
        let records = try SyncRecordMapper().records(from: source.snapshot(), modifiedBy: SyncDeviceID("iphone-b"))
        let transport = InMemorySyncTransport(records: records)

        try engineRepository.save(SuntraceEngine().snapshot())

        let coordinator = SQLiteSyncDownloadCoordinator(databaseURL: databaseURL, transport: transport)
        let result = try await coordinator.downloadAndMerge(detectedAt: now.addingTimeInterval(10))
        let restored = try engineRepository.load()

        XCTAssertEqual(result.fetchedCount, records.count)
        XCTAssertEqual(result.appliedCount, records.count)
        XCTAssertEqual(result.conflictCount, 0)
        XCTAssertEqual(restored.snapshot(), source.snapshot())
        XCTAssertTrue(try syncRepository.journalEntries(state: .pendingUpload).isEmpty)
        XCTAssertEqual(Set(try syncRepository.auditLog().map(\.action)), ["merged"])
        XCTAssertNotNil(try syncRepository.metadata(for: "generic.download.lastFetch"))
    }

    func testDownloadConflictIsPersistedWithoutOverwritingLocalSnapshot() async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let local = SuntraceEngine()
        let chainID = try local.createPoolTask(title: "本地历史任务", now: now)
        let traceID = try local.scheduleFromPool(chainID: chainID, date: today, today: today, now: now)
        try local.markCompleted(traceID: traceID, today: today, now: now.addingTimeInterval(1))
        try engineRepository.save(local.snapshot())

        var remoteTrace = try XCTUnwrap(local.snapshot().traces.first)
        remoteTrace.status = .pending
        remoteTrace.completedAt = nil
        let remoteRecord = try SyncRecordMapper().record(for: remoteTrace, modifiedBy: SyncDeviceID("iphone-b"))
        let transport = InMemorySyncTransport(records: [remoteRecord])

        let coordinator = SQLiteSyncDownloadCoordinator(databaseURL: databaseURL, transport: transport)
        let result = try await coordinator.downloadAndMerge(detectedAt: now.addingTimeInterval(10))

        XCTAssertEqual(result, SQLiteSyncDownloadResult(fetchedCount: 1, appliedCount: 0, conflictCount: 1))
        XCTAssertEqual(try engineRepository.load().snapshot(), local.snapshot())

        let conflict = try XCTUnwrap(syncRepository.unresolvedConflicts().first)
        XCTAssertEqual(conflict.type, .historicalTraceMutation)
        XCTAssertEqual(conflict.remoteRecordID, remoteRecord.id)
        XCTAssertEqual(try syncRepository.auditLog(limit: 1).first?.action, "conflict")
    }

    func testEmptyRemoteFetchUpdatesMetadataOnly() async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)

        try engineRepository.save(SuntraceEngine().snapshot())

        let coordinator = SQLiteSyncDownloadCoordinator(databaseURL: databaseURL, transport: InMemorySyncTransport())
        let result = try await coordinator.downloadAndMerge(detectedAt: now)

        XCTAssertEqual(result, SQLiteSyncDownloadResult(fetchedCount: 0, appliedCount: 0, conflictCount: 0))
        XCTAssertTrue(try syncRepository.auditLog().isEmpty)
        XCTAssertNotNil(try syncRepository.metadata(for: "generic.download.lastFetch"))
    }

    private func makeDatabaseURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("suntrace-sync-download-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
