@testable import SuntraceCore
@testable import SuntraceStorage
import SuntraceSync
import XCTest

final class ICloudDriveLocalFirstSyncLiveTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let today = LocalDate("2026-07-05")

    func testTwoSQLiteStoresSyncThroughRealICloudDriveEndpoint() async throws {
        guard ProcessInfo.processInfo.environment["SUNTRACE_LIVE_ICLOUD_SYNC"] == "1" else {
            throw XCTSkip("Set SUNTRACE_LIVE_ICLOUD_SYNC=1 to run the live iCloud Drive sync test.")
        }

        let repositoryName = "NoonmarkLiveTests/\(UUID().uuidString)"
        let rootURL = try ICloudDriveSyncTransport.defaultRootURL(repositoryName: repositoryName)
        XCTAssertTrue(rootURL.path.contains("Mobile Documents") || rootURL.path.contains("CloudDocs"))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let macURL = makeDatabaseURL("icloud-mac")
        let phoneURL = makeDatabaseURL("icloud-phone")
        let macRepository = SQLiteEngineRepository(databaseURL: macURL)
        let phoneRepository = SQLiteEngineRepository(databaseURL: phoneURL)
        let macDevice = SyncDeviceID("icloud-mac")

        let macEngine = SuntraceEngine()
        let chainID = try macEngine.createPoolTask(title: "真实 iCloud 同步测试", now: now)
        let traceID = try macEngine.scheduleFromPool(chainID: chainID, date: today, today: today, now: now)
        try macRepository.save(macEngine.snapshot(), recordingChangesFor: macDevice, changedAt: now)
        let decisionID = UUID(uuidString: "42000000-0000-0000-0000-000000000002")!
        try commitClassification(
            on: macEngine,
            chainID: chainID,
            interactionID: UUID(uuidString: "42000000-0000-0000-0000-000000000001")!,
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
            transport: ICloudDriveSyncTransport(rootURL: rootURL)
        )
        let phoneSync = SQLiteLocalFirstSyncCoordinator(
            databaseURL: phoneURL,
            transport: ICloudDriveSyncTransport(rootURL: rootURL)
        )

        let macResult = try await macSync.sync(now: now.addingTimeInterval(10))
        XCTAssertGreaterThan(macResult.upload.uploadedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("refs/latest").path))

        let phoneResult = try await phoneSync.sync(now: now.addingTimeInterval(20))
        let restoredPhone = try phoneRepository.load()

        XCTAssertGreaterThan(phoneResult.download.appliedCount, 0)
        XCTAssertEqual(phoneResult.download.waitingCount, 0)
        XCTAssertEqual(phoneResult.download.conflictCount, 0)
        XCTAssertEqual(restoredPhone.getDayTodo(date: today).traces.first?.id, traceID)
        let phoneClassification = restoredPhone.snapshot().classifications
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
        XCTAssertEqual(current.category?.decisionID, decisionID)
        XCTAssertTrue(current.labels.allSatisfy { $0.source == .userDirect })
        XCTAssertNotNil(try SQLiteSyncRepository(databaseURL: phoneURL).metadata(for: "localFirst.sync.lastResult"))
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
            .appendingPathComponent("suntrace-\(name)-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
