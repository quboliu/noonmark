@testable import NoonmarkCore
@testable import NoonmarkStorage
import NoonmarkSync
import XCTest

final class ICloudDriveLocalFirstSyncLiveTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let today = LocalDate("2026-07-05")

    func testTwoSQLiteStoresSyncThroughRealICloudDriveEndpoint() async throws {
        guard ProcessInfo.processInfo.environment["NOONMARK_LIVE_ICLOUD_SYNC"] == "1" else {
            throw XCTSkip("Set NOONMARK_LIVE_ICLOUD_SYNC=1 to run the live iCloud Drive sync test.")
        }

        let repositoryName = "Noonmark-E2E/LiveTests/\(UUID().uuidString)"
        let rootURL = try ICloudDriveSyncTransport.defaultRootURL(repositoryName: repositoryName)
        XCTAssertTrue(rootURL.path.contains("Mobile Documents") || rootURL.path.contains("CloudDocs"))
        addTeardownBlock {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: rootURL.path) {
                try fileManager.removeItem(at: rootURL)
            }
            XCTAssertFalse(
                fileManager.fileExists(atPath: rootURL.path),
                "live iCloud test repository must be removed"
            )
        }

        let macURL = makeDatabaseURL("icloud-mac")
        let phoneURL = makeDatabaseURL("icloud-phone")
        let macRepository = SQLiteEngineRepository(databaseURL: macURL)
        let phoneRepository = SQLiteEngineRepository(databaseURL: phoneURL)
        let macDevice = SyncDeviceID("icloud-mac")

        let macEngine = NoonmarkEngine()
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
        try phoneRepository.save(NoonmarkEngine().snapshot())

        let macSync = SQLiteLocalFirstSyncCoordinator(
            databaseURL: macURL,
            transport: ICloudDriveSyncTransport(rootURL: rootURL)
        )
        let phoneSync = SQLiteLocalFirstSyncCoordinator(
            databaseURL: phoneURL,
            transport: ICloudDriveSyncTransport(rootURL: rootURL)
        )

        let macResult = try await syncUntilConfirmed(
            macSync,
            now: now.addingTimeInterval(10)
        )
        XCTAssertGreaterThan(macResult.upload.uploadedCount, 0)
        XCTAssertFalse(try repositoryHeadFiles(rootURL).isEmpty)

        let phoneResult = try await syncUntilConfirmed(
            phoneSync,
            now: now.addingTimeInterval(20)
        )
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
        XCTAssertNotNil(
            try SQLiteSyncRepository(databaseURL: phoneURL).metadata(
                for: SQLiteLocalFirstSyncCoordinator.lastStatusMetadataKey
            )
        )
    }

    func testImportedDataPackageRoundTripsThroughIsolatedICloudDriveEndpoint()
        async throws
    {
        let environment = ProcessInfo.processInfo.environment
        guard environment["NOONMARK_LIVE_ICLOUD_SYNC"] == "1" else {
            throw XCTSkip(
                "Set NOONMARK_LIVE_ICLOUD_SYNC=1 to run the live iCloud Drive sync test."
            )
        }
        let packagePath = try XCTUnwrap(
            environment["NOONMARK_LIVE_ICLOUD_PACKAGE_PATH"],
            "NOONMARK_LIVE_ICLOUD_PACKAGE_PATH is required when live iCloud sync is enabled."
        )
        guard packagePath.isEmpty == false else {
            XCTFail(
                "NOONMARK_LIVE_ICLOUD_PACKAGE_PATH must not be empty when live iCloud sync is enabled."
            )
            return
        }

        let packageURL = URL(fileURLWithPath: packagePath)
        let importedSnapshot = try NoonmarkDataPackage.read(
            from: packageURL
        )
        let repositoryName =
            "Noonmark-E2E/LiveTests/ImportedDataPackage-\(UUID().uuidString)"
        let rootURL = try ICloudDriveSyncTransport.defaultRootURL(
            repositoryName: repositoryName
        )
        XCTAssertTrue(
            rootURL.path.contains("Mobile Documents")
                || rootURL.path.contains("CloudDocs")
        )
        XCTAssertFalse(
            rootURL.path.hasSuffix("Noonmark/SyncRepository")
        )
        addTeardownBlock {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: rootURL.path) {
                try fileManager.removeItem(at: rootURL)
            }
            XCTAssertFalse(
                fileManager.fileExists(atPath: rootURL.path),
                "imported-package iCloud repository must be removed"
            )
        }

        let sourceURL = makeDatabaseURL("icloud-import-source")
        let targetURL = makeDatabaseURL("icloud-import-target")
        let sourceRepository = SQLiteEngineRepository(
            databaseURL: sourceURL
        )
        let targetRepository = SQLiteEngineRepository(
            databaseURL: targetURL
        )
        let sourceIdentity = SyncDeviceIdentity(
            deviceID: SyncDeviceID("icloud-import-source"),
            createdAt: now
        )
        try sourceRepository.replaceForDataImport(
            importedSnapshot,
            preserving: sourceIdentity
        )
        try targetRepository.save(NoonmarkEngine().snapshot())

        let sourceCoordinator = SQLiteLocalFirstSyncCoordinator(
            databaseURL: sourceURL,
            transport: ICloudDriveSyncTransport(rootURL: rootURL)
        )
        let targetCoordinator = SQLiteLocalFirstSyncCoordinator(
            databaseURL: targetURL,
            transport: ICloudDriveSyncTransport(rootURL: rootURL)
        )
        let sourceResult = try await syncUntilConfirmed(
            sourceCoordinator,
            now: now.addingTimeInterval(10)
        )
        let targetResult = try await syncUntilConfirmed(
            targetCoordinator,
            now: now.addingTimeInterval(20)
        )
        let restored = try targetRepository.load().snapshot()

        XCTAssertGreaterThan(sourceResult.upload.uploadedCount, 0)
        XCTAssertGreaterThan(targetResult.download.appliedCount, 0)
        XCTAssertEqual(targetResult.download.waitingCount, 0)
        XCTAssertEqual(targetResult.download.conflictCount, 0)
        XCTAssertEqual(restored.days, importedSnapshot.days)
        XCTAssertEqual(
            restored.taskCycleSeries,
            importedSnapshot.taskCycleSeries
        )
        XCTAssertEqual(restored.chains, importedSnapshot.chains)
        XCTAssertEqual(restored.definitions, importedSnapshot.definitions)
        XCTAssertEqual(restored.traces, importedSnapshot.traces)
        XCTAssertEqual(restored.subtasks, importedSnapshot.subtasks)
        XCTAssertEqual(
            restored.classifications,
            importedSnapshot.classifications
        )
        XCTAssertEqual(
            AppPreferencesEnvelope(
                preferences: restored.preferences
            ),
            AppPreferencesEnvelope(
                preferences: importedSnapshot.preferences
            )
        )
        XCTAssertFalse(try repositoryHeadFiles(rootURL).isEmpty)

        let sourceSyncRepository = SQLiteSyncRepository(
            databaseURL: sourceURL
        )
        let manifestMetadata = try XCTUnwrap(
            sourceSyncRepository.metadata(
                for: SQLiteLocalFirstSyncCoordinator
                    .baselineManifestMetadataKey
            )
        )
        XCTAssertEqual(
            try SQLiteSyncBaselineManifest.decode(
                manifestMetadata
            ).state,
            .established
        )
        XCTAssertEqual(
            try SQLiteLocalFirstSyncCoordinator.timestamps(
                in: sourceSyncRepository
            )?.lastEffectiveSyncedAt,
            sourceResult.syncedAt
        )
    }

    private func commitClassification(
        on engine: NoonmarkEngine,
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

    private func syncUntilConfirmed(
        _ coordinator: SQLiteLocalFirstSyncCoordinator,
        now: Date
    ) async throws -> SQLiteLocalFirstSyncResult {
        let deadline = Date().addingTimeInterval(60)
        var attempt = 0
        while true {
            let result = try await coordinator.sync(
                now: now.addingTimeInterval(TimeInterval(attempt))
            )
            if result.isAwaitingUploadConfirmation == false {
                return result
            }
            guard Date() < deadline else {
                XCTFail("iCloud did not confirm batch and covering head upload")
                return result
            }
            attempt += 1
            try await Task.sleep(for: .seconds(1))
        }
    }

    private func repositoryHeadFiles(_ rootURL: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: rootURL.appendingPathComponent("heads"),
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
    }

    private func makeDatabaseURL(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("noonmark-\(name)-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
