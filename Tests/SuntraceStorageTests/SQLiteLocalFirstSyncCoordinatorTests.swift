@testable import SuntraceCore
@testable import SuntraceStorage
import SuntraceSync
import XCTest

final class SQLiteLocalFirstSyncCoordinatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let today = LocalDate("2026-07-05")

    func testTwoSQLiteStoresSyncThroughLocalFolderEndpoint() async throws {
        let folderURL = makeFolderURL()
        let macURL = makeDatabaseURL("mac")
        let phoneURL = makeDatabaseURL("phone")
        let macRepository = SQLiteEngineRepository(databaseURL: macURL)
        let phoneRepository = SQLiteEngineRepository(databaseURL: phoneURL)
        let macDevice = SyncDeviceID("mac-a")
        let phoneDevice = SyncDeviceID("phone-b")

        let macEngine = SuntraceEngine()
        let chainID = try macEngine.createPoolTask(title: "同步到另一台设备", now: now)
        let traceID = try macEngine.scheduleFromPool(chainID: chainID, date: today, today: today, now: now)
        _ = try macEngine.addSubtask(traceID: traceID, title: "写本地文件夹同步测试", now: now)
        try macRepository.save(macEngine.snapshot(), recordingChangesFor: macDevice, changedAt: now)
        let decisionID = UUID(uuidString: "41000000-0000-0000-0000-000000000002")!
        try commitClassification(
            on: macEngine,
            chainID: chainID,
            interactionID: UUID(uuidString: "41000000-0000-0000-0000-000000000001")!,
            decisionID: decisionID,
            now: now.addingTimeInterval(1)
        )
        try macRepository.save(
            macEngine.snapshot(),
            recordingChangesFor: macDevice,
            changedAt: now.addingTimeInterval(1)
        )
        try phoneRepository.save(SuntraceEngine().snapshot())

        let macSync = SQLiteLocalFirstSyncCoordinator(
            databaseURL: macURL,
            transport: LocalFolderSyncTransport(rootURL: folderURL)
        )
        let phoneSync = SQLiteLocalFirstSyncCoordinator(
            databaseURL: phoneURL,
            transport: LocalFolderSyncTransport(rootURL: folderURL)
        )

        let macUpload = try await macSync.sync(now: now.addingTimeInterval(10))
        let phoneDownload = try await phoneSync.sync(now: now.addingTimeInterval(20))
        let phoneEngine = try phoneRepository.load()

        XCTAssertGreaterThanOrEqual(macUpload.upload.uploadedCount, 6)
        XCTAssertGreaterThanOrEqual(phoneDownload.download.appliedCount, 6)
        XCTAssertEqual(phoneDownload.download.waitingCount, 0)
        XCTAssertEqual(phoneDownload.download.conflictCount, 0)
        XCTAssertEqual(phoneEngine.getDayTodo(date: today).traces.first?.id, traceID)
        XCTAssertEqual(phoneEngine.subtasks.count, 1)
        let phoneClassification = phoneEngine.snapshot().classifications
        let macClassification = macEngine.snapshot().classifications
        XCTAssertEqual(phoneClassification, macClassification)
        let current = try XCTUnwrap(
            phoneClassification.currentByChainID[chainID]
        )
        let categoryID = try XCTUnwrap(current.categoryID)
        XCTAssertEqual(
            phoneClassification.categories[categoryID]?.name,
            "项目"
        )
        XCTAssertEqual(
            Set(current.labelIDs.compactMap {
                phoneClassification.labels[$0]?.name
            }),
            ["同步", "复盘"]
        )
        XCTAssertEqual(current.category?.source, .userDirect)
        XCTAssertTrue(current.labels.allSatisfy { $0.source == .userDirect })
        XCTAssertEqual(current.category?.decisionID, decisionID)
        XCTAssertTrue(current.labels.allSatisfy { $0.decisionID == decisionID })
        XCTAssertEqual(
            phoneClassification.committedReceiptsByInteractionID.count,
            1
        )

        phoneEngine.updateDailyReview(
            date: today,
            summary: "手机端补写复盘",
            unfinishedReason: nil,
            tomorrowNote: nil,
            now: now.addingTimeInterval(30)
        )
        try phoneRepository.save(phoneEngine.snapshot(), recordingChangesFor: phoneDevice, changedAt: now.addingTimeInterval(30))

        let phoneUpload = try await phoneSync.sync(now: now.addingTimeInterval(40))
        let macDownload = try await macSync.sync(now: now.addingTimeInterval(50))
        let restoredMac = try macRepository.load()

        XCTAssertEqual(phoneUpload.upload.uploadedCount, 1)
        XCTAssertGreaterThanOrEqual(macDownload.download.appliedCount, 1)
        XCTAssertEqual(macDownload.download.waitingCount, 0)
        XCTAssertEqual(restoredMac.days[today]?.reviewSummary, "手机端补写复盘")
        XCTAssertNotNil(try SQLiteSyncRepository(databaseURL: macURL).metadata(for: "localFirst.sync.lastResult"))
    }

    private func commitClassification(
        on engine: SuntraceEngine,
        chainID: TaskChainID,
        interactionID: UUID,
        decisionID: UUID,
        now: Date
    ) throws {
        let plan = try engine.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .new(name: "项目", colorHex: "#2A6FDB"),
                    labels: [
                        .new(name: "同步", colorHex: "#0E9488"),
                        .new(name: "复盘", colorHex: "#7C5CFF")
                    ]
                )
            ),
            source: .userDirect,
            interactionID: interactionID,
            now: now
        )
        _ = try engine.commitClassification(
            plan,
            confirmation: .user(decisionID: decisionID),
            now: now
        )
    }

    private func makeDatabaseURL(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("suntrace-local-first-\(name)-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func makeFolderURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("suntrace-local-first-folder-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
