@testable import NoonmarkCore
@testable import NoonmarkStorage
@testable import NoonmarkSync
import Foundation
import XCTest

final class IncrementalSyncPerformanceTests: XCTestCase {
    func testSteadyStateSQLiteDownloadOpensOnlyUnseenBatches()
        async throws
    {
        let fixtureRoot = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let sourceDatabase = fixtureRoot.appendingPathComponent(
            "source.sqlite"
        )
        let targetDatabase = fixtureRoot.appendingPathComponent(
            "target.sqlite"
        )
        let repositoryRoot = fixtureRoot.appendingPathComponent(
            "SyncRepository",
            isDirectory: true
        )
        let sourceEpoch = try XCTUnwrap(
            UUID(uuidString: "A0000000-0000-0000-0000-000000000001")
        )
        let targetEpoch = try XCTUnwrap(
            UUID(uuidString: "B0000000-0000-0000-0000-000000000002")
        )
        let sourceTransport = LocalFolderSyncTransport(
            rootURL: repositoryRoot,
            producerEpochID: sourceEpoch
        )
        let sourceEngine = NoonmarkEngine()
        let sourceRepository = SQLiteEngineRepository(
            databaseURL: sourceDatabase
        )
        let sourceSyncRepository = SQLiteSyncRepository(
            databaseURL: sourceDatabase
        )
        let writer = SyncDeviceID("incremental-source")
        try sourceRepository.save(sourceEngine.snapshot())

        let historyCount = 128
        let start = Date(timeIntervalSinceReferenceDate: 100_000)
        for index in 0 ..< historyCount {
            try sourceEngine.updateTheme(
                index.isMultiple(of: 2) ? .warmPaper : .coolGray,
                writerID: writer.rawValue,
                now: start.addingTimeInterval(Double(index + 1))
            )
            try sourceRepository.save(
                sourceEngine.snapshot(),
                recordingChangesFor: writer,
                changedAt: start.addingTimeInterval(Double(index + 1))
            )
        }
        let uploader = SQLiteSyncUploadCoordinator(
            databaseURL: sourceDatabase,
            transport: sourceTransport
        )
        while try sourceSyncRepository.journalEntries(
            state: .pendingUpload
        ).isEmpty == false {
            let result = try await uploader.uploadPending(limit: 1)
            XCTAssertEqual(result.failedCount, 0)
            XCTAssertEqual(result.uploadedCount, 1)
        }

        try SQLiteEngineRepository(databaseURL: targetDatabase).save(
            NoonmarkEngine().snapshot()
        )
        let measuredTransport = MeasuringIncrementalTransport(
            base: LocalFolderSyncTransport(
                rootURL: repositoryRoot,
                producerEpochID: targetEpoch
            ),
            frontierNamespace: LocalFolderSyncTransport.frontierNamespace(
                for: repositoryRoot
            )
        )
        let downloader = SQLiteSyncDownloadCoordinator(
            databaseURL: targetDatabase,
            transport: measuredTransport
        )
        while true {
            let page = try await downloader.downloadAndMerge()
            if page.fetchedCount == 0 { break }
        }
        let bootstrapOpened = await measuredTransport.openedBatchCount()
        XCTAssertEqual(bootstrapOpened, historyCount)
        XCTAssertEqual(
            try SQLiteEngineRepository(databaseURL: targetDatabase)
                .load().snapshot().preferences.theme,
            .coolGray
        )

        await measuredTransport.resetOpenedBatchCount()
        let unchanged = try await downloader.downloadAndMerge()
        let unchangedOpened = await measuredTransport.openedBatchCount()
        XCTAssertEqual(unchanged.fetchedCount, 0)
        XCTAssertEqual(unchangedOpened, 0)

        let incrementalDate = start.addingTimeInterval(
            Double(historyCount + 1)
        )
        try sourceEngine.updateTheme(
            .warmPaper,
            writerID: writer.rawValue,
            now: incrementalDate
        )
        try sourceRepository.save(
            sourceEngine.snapshot(),
            recordingChangesFor: writer,
            changedAt: incrementalDate
        )
        let incrementalUpload = try await uploader.uploadPending(limit: 1)
        XCTAssertEqual(incrementalUpload.uploadedCount, 1)
        XCTAssertEqual(incrementalUpload.failedCount, 0)

        let incremental = try await downloader.downloadAndMerge()
        let incrementalOpened = await measuredTransport.openedBatchCount()
        XCTAssertEqual(incremental.fetchedCount, 1)
        XCTAssertEqual(incrementalOpened, 1)
        XCTAssertEqual(
            try SQLiteEngineRepository(databaseURL: targetDatabase)
                .load().snapshot().preferences.theme,
            .warmPaper
        )
    }

    private func makeFixture() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noonmark-incremental-symptom-\(UUID().uuidString)",
                isDirectory: true
            )
    }
}

private actor MeasuringIncrementalTransport: SyncRecordTransport {
    private let base: LocalFolderSyncTransport
    nonisolated let frontierNamespace: String
    private var openedBatches = 0

    init(
        base: LocalFolderSyncTransport,
        frontierNamespace: String
    ) {
        self.base = base
        self.frontierNamespace = frontierNamespace
    }

    func pushAccepting(
        _ records: [SyncRecord]
    ) async throws -> SyncTransportPushReceipt {
        try await base.pushAccepting(records)
    }

    func pull(
        after frontier: SyncTransportFrontier,
        limit: Int
    ) async throws -> SyncTransportChangePage {
        let page = try await base.pull(after: frontier, limit: limit)
        openedBatches += page.openedBatchCount
        return page
    }

    func confirmationStatus(
        for receipt: SyncTransportPushReceipt
    ) async throws -> SyncTransportConfirmation {
        try await base.confirmationStatus(for: receipt)
    }

    func acknowledge(
        _ frontier: SyncTransportFrontier
    ) async throws {
        try await base.acknowledge(frontier)
    }

    func openedBatchCount() -> Int {
        openedBatches
    }

    func resetOpenedBatchCount() {
        openedBatches = 0
    }
}
