@testable import NoonmarkCore
@testable import NoonmarkStorage
import NoonmarkSync
import XCTest

final class SQLiteIdeaEntrySyncTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testIdeaCreateEditAndTombstoneSyncRoundTripBetweenDevices() async throws {
        let deviceAURL = makeDatabaseURL("device-a")
        let deviceBURL = makeDatabaseURL("device-b")
        let engineARepository = SQLiteEngineRepository(databaseURL: deviceAURL)
        let engineBRepository = SQLiteEngineRepository(databaseURL: deviceBURL)
        let syncARepository = SQLiteSyncRepository(databaseURL: deviceAURL)
        let syncBRepository = SQLiteSyncRepository(databaseURL: deviceBURL)
        let transport = InMemorySyncTransport()
        let deviceA = SyncDeviceID("mac-a")

        let engineA = NoonmarkEngine()
        try engineARepository.save(engineA.snapshot())
        let kept = try engineA.appendIdea(body: "保留的灵感", now: now)
        let edited = try engineA.appendIdea(
            body: "编辑前的灵感",
            now: now.addingTimeInterval(1)
        )
        let tombstoned = try engineA.appendIdea(
            body: "删除前的灵感",
            now: now.addingTimeInterval(2)
        )
        try engineA.editIdea(
            id: edited.id,
            body: "编辑后的灵感",
            now: now.addingTimeInterval(3)
        )
        try engineA.deleteIdea(id: tombstoned.id, now: now.addingTimeInterval(4))
        try engineARepository.save(
            engineA.snapshot(),
            recordingChangesFor: deviceA,
            changedAt: now.addingTimeInterval(5)
        )

        let pendingEntries = try syncARepository.journalEntries(
            state: .pendingUpload
        )
        XCTAssertEqual(pendingEntries.count, 3)
        XCTAssertEqual(Set(pendingEntries.map(\.entityType)), [.ideaEntry])
        XCTAssertTrue(pendingEntries.allSatisfy {
            $0.operation == .upsert && $0.recordPayload == nil
        })

        let upload = try await SQLiteSyncUploadCoordinator(
            databaseURL: deviceAURL,
            transport: transport
        ).uploadPending()
        XCTAssertEqual(
            upload,
            SQLiteSyncUploadResult(pendingCount: 3, uploadedCount: 3, failedCount: 0)
        )
        let uploaded = try await transport.fetchAll()
        XCTAssertEqual(uploaded.count, 3)
        XCTAssertTrue(uploaded.allSatisfy {
            $0.entityType == .ideaEntry
                && $0.operation == .upsert
                && $0.id.rawValue.hasPrefix("idea:")
        })
        XCTAssertTrue(
            try syncARepository.journalEntries(state: .pendingUpload).isEmpty
        )

        try engineBRepository.save(NoonmarkEngine().snapshot())
        let download = try await SQLiteSyncDownloadCoordinator(
            databaseURL: deviceBURL,
            transport: transport
        ).downloadAndMerge(detectedAt: now.addingTimeInterval(10))
        XCTAssertEqual(download.fetchedCount, 3)
        XCTAssertEqual(download.appliedCount, 3)
        XCTAssertEqual(download.waitingCount, 0)
        XCTAssertEqual(download.conflictCount, 0)

        let restored = try engineBRepository.load()
        XCTAssertEqual(restored.snapshot(), engineA.snapshot())
        XCTAssertEqual(restored.ideas[kept.id]?.body, "保留的灵感")
        XCTAssertEqual(restored.ideas[edited.id]?.body, "编辑后的灵感")
        XCTAssertEqual(restored.ideas[tombstoned.id]?.isDeleted, true)
        XCTAssertEqual(
            restored.ideas[tombstoned.id]?.deletedAt,
            now.addingTimeInterval(4)
        )
        XCTAssertTrue(
            try syncBRepository.journalEntries(state: .pendingUpload).isEmpty
        )
    }

    func testIdeaEditsConvergeToLatestWriterAcrossDevices() async throws {
        let deviceAURL = makeDatabaseURL("device-a")
        let deviceBURL = makeDatabaseURL("device-b")
        let engineARepository = SQLiteEngineRepository(databaseURL: deviceAURL)
        let engineBRepository = SQLiteEngineRepository(databaseURL: deviceBURL)
        let transport = InMemorySyncTransport()
        let deviceA = SyncDeviceID("mac-a")

        let engineA = NoonmarkEngine()
        try engineARepository.save(engineA.snapshot())
        let idea = try engineA.appendIdea(body: "第一版", now: now)
        try engineARepository.save(
            engineA.snapshot(),
            recordingChangesFor: deviceA,
            changedAt: now.addingTimeInterval(1)
        )
        _ = try await SQLiteSyncUploadCoordinator(
            databaseURL: deviceAURL,
            transport: transport
        ).uploadPending()

        try engineBRepository.save(NoonmarkEngine().snapshot())
        let firstDownload = try await SQLiteSyncDownloadCoordinator(
            databaseURL: deviceBURL,
            transport: transport
        ).downloadAndMerge(detectedAt: now.addingTimeInterval(2))
        XCTAssertEqual(firstDownload.appliedCount, 1)
        XCTAssertEqual(firstDownload.conflictCount, 0)
        XCTAssertEqual(
            try engineBRepository.load().ideas[idea.id]?.body,
            "第一版"
        )

        try engineA.editIdea(
            id: idea.id,
            body: "第二版",
            now: now.addingTimeInterval(3)
        )
        try engineARepository.save(
            engineA.snapshot(),
            recordingChangesFor: deviceA,
            changedAt: now.addingTimeInterval(4)
        )
        _ = try await SQLiteSyncUploadCoordinator(
            databaseURL: deviceAURL,
            transport: transport
        ).uploadPending()

        let secondDownload = try await SQLiteSyncDownloadCoordinator(
            databaseURL: deviceBURL,
            transport: transport
        ).downloadAndMerge(detectedAt: now.addingTimeInterval(5))
        XCTAssertEqual(secondDownload.fetchedCount, 1)
        XCTAssertEqual(secondDownload.appliedCount, 1)
        XCTAssertEqual(secondDownload.waitingCount, 0)
        XCTAssertEqual(secondDownload.conflictCount, 0)

        let restored = try engineBRepository.load()
        XCTAssertEqual(restored.snapshot(), engineA.snapshot())
        XCTAssertEqual(restored.ideas[idea.id]?.body, "第二版")
        XCTAssertEqual(
            restored.ideas[idea.id]?.updatedAt,
            now.addingTimeInterval(3)
        )
    }

    func testIdeaPinAndRestoreSyncRoundTripBetweenDevices() async throws {
        let deviceAURL = makeDatabaseURL("device-a")
        let deviceBURL = makeDatabaseURL("device-b")
        let engineARepository = SQLiteEngineRepository(databaseURL: deviceAURL)
        let engineBRepository = SQLiteEngineRepository(databaseURL: deviceBURL)
        let transport = InMemorySyncTransport()
        let deviceA = SyncDeviceID("mac-a")

        let engineA = NoonmarkEngine()
        try engineARepository.save(engineA.snapshot())
        let pinned = try engineA.appendIdea(body: "置顶同步", now: now)
        let restored = try engineA.appendIdea(
            body: "删除再恢复",
            now: now.addingTimeInterval(1)
        )
        try engineA.pinIdea(id: pinned.id, now: now.addingTimeInterval(2))
        try engineA.deleteIdea(id: restored.id, now: now.addingTimeInterval(3))
        try engineA.restoreIdea(
            id: restored.id,
            body: "恢复后的正文",
            now: now.addingTimeInterval(4)
        )
        try engineARepository.save(
            engineA.snapshot(),
            recordingChangesFor: deviceA,
            changedAt: now.addingTimeInterval(5)
        )

        let pendingEntries = try SQLiteSyncRepository(databaseURL: deviceAURL)
            .journalEntries(state: .pendingUpload)
        XCTAssertEqual(pendingEntries.count, 2)
        XCTAssertEqual(Set(pendingEntries.map(\.entityType)), [.ideaEntry])

        let upload = try await SQLiteSyncUploadCoordinator(
            databaseURL: deviceAURL,
            transport: transport
        ).uploadPending()
        XCTAssertEqual(
            upload,
            SQLiteSyncUploadResult(pendingCount: 2, uploadedCount: 2, failedCount: 0)
        )

        try engineBRepository.save(NoonmarkEngine().snapshot())
        let download = try await SQLiteSyncDownloadCoordinator(
            databaseURL: deviceBURL,
            transport: transport
        ).downloadAndMerge(detectedAt: now.addingTimeInterval(10))
        XCTAssertEqual(download.fetchedCount, 2)
        XCTAssertEqual(download.appliedCount, 2)
        XCTAssertEqual(download.waitingCount, 0)
        XCTAssertEqual(download.conflictCount, 0)

        let restoredB = try engineBRepository.load()
        XCTAssertEqual(restoredB.snapshot(), engineA.snapshot())
        XCTAssertEqual(
            restoredB.ideas[pinned.id]?.pinnedAt,
            now.addingTimeInterval(2)
        )
        XCTAssertEqual(restoredB.pinnedIdeas().map(\.id), [pinned.id])
        XCTAssertEqual(restoredB.ideas[restored.id]?.isDeleted, false)
        XCTAssertEqual(restoredB.ideas[restored.id]?.body, "恢复后的正文")
        XCTAssertNil(restoredB.ideas[restored.id]?.pinnedAt)
        XCTAssertTrue(restoredB.ideaTrash().isEmpty)
    }

    private func makeDatabaseURL(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("noonmark-idea-sync-\(name)-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
