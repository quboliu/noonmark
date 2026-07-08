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
        let projectTagID = try macEngine.createTaskTag(name: "项目", colorHex: "#0E9488", now: now)
        let reviewTagID = try macEngine.createTaskTag(name: "复盘", colorHex: "#7C5CFF", now: now)
        try macEngine.setTaskTagAssignment(chainID: chainID, slot: .tagI, tagID: projectTagID, now: now)
        try macEngine.setTaskTagAssignment(chainID: chainID, slot: .tagII, tagID: reviewTagID, now: now)
        let traceID = try macEngine.scheduleFromPool(chainID: chainID, date: today, today: today, now: now)
        try macRepository.save(macEngine.snapshot(), recordingChangesFor: macDevice, changedAt: now)
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
        XCTAssertEqual(restoredPhone.getDayTodo(date: today).traces.first?.id, traceID)
        XCTAssertEqual(Set(restoredPhone.preferences.taskTags.map(\.name)), ["项目", "复盘"])
        XCTAssertEqual(restoredPhone.chains[chainID]?.tagAssignments.map(\.tagID), [projectTagID, reviewTagID])
        XCTAssertEqual(restoredPhone.chains[chainID]?.tagAssignments.map(\.slot), [.tagI, .tagII])
        XCTAssertNotNil(try SQLiteSyncRepository(databaseURL: phoneURL).metadata(for: "localFirst.sync.lastResult"))
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
