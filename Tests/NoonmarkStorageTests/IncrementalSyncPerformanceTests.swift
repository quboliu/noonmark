@testable import NoonmarkCore
@testable import NoonmarkStorage
@testable import NoonmarkSync
import Foundation
import XCTest

final class IncrementalSyncPerformanceTests: XCTestCase {
    func testSteadyStateSQLiteDownloadOpensOnlyUnseenBatches()
        async throws
    {
        let shortHistory = try await measureSteadyStateAccess(
            historyCount: 128
        )
        let longHistory = try await measureSteadyStateAccess(
            historyCount: 256
        )

        XCTAssertEqual(
            shortHistory.unchanged,
            longHistory.unchanged,
            "Zero-change access must not grow with historical batches."
        )
        XCTAssertEqual(
            shortHistory.incremental,
            longHistory.incremental,
            "One unseen batch must cost the same after history doubles."
        )
        XCTAssertEqual(
            shortHistory.unchanged,
            .init(heads: 1, batches: 0, bytes: 0)
        )
        XCTAssertEqual(shortHistory.incremental.heads, 1)
        XCTAssertEqual(shortHistory.incremental.batches, 1)
        XCTAssertGreaterThan(shortHistory.incremental.bytes, 0)
    }

    private func measureSteadyStateAccess(
        historyCount: Int
    ) async throws -> SteadyStateAccesses {
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
            if page.fetchedCount == 0 {
                break
            }
        }
        let bootstrapAccess = await measuredTransport.access()
        XCTAssertEqual(
            bootstrapAccess.batches,
            historyCount + (historyCount - 1) / 100,
            "Each full incremental page reads one successor hash anchor."
        )
        XCTAssertEqual(
            try SQLiteEngineRepository(databaseURL: targetDatabase)
                .load().snapshot().preferences.theme,
            .coolGray
        )

        await measuredTransport.resetAccess()
        let unchanged = try await downloader.downloadAndMerge()
        let unchangedAccess = await measuredTransport.access()
        XCTAssertEqual(unchanged.fetchedCount, 0)
        XCTAssertEqual(unchangedAccess.batches, 0)
        XCTAssertEqual(unchangedAccess.bytes, 0)

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

        await measuredTransport.resetAccess()
        let incremental = try await downloader.downloadAndMerge()
        let incrementalAccess = await measuredTransport.access()
        XCTAssertEqual(incremental.fetchedCount, 1)
        XCTAssertEqual(incrementalAccess.batches, 1)
        XCTAssertGreaterThan(incrementalAccess.bytes, 0)
        XCTAssertEqual(
            try SQLiteEngineRepository(databaseURL: targetDatabase)
                .load().snapshot().preferences.theme,
            .warmPaper
        )
        return SteadyStateAccesses(
            unchanged: unchangedAccess,
            incremental: incrementalAccess
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

private struct SteadyStateAccesses: Equatable {
    let unchanged: SteadyStateAccess
    let incremental: SteadyStateAccess
}

private struct SteadyStateAccess: Equatable {
    let heads: Int
    let batches: Int
    let bytes: Int64
}

private actor MeasuringIncrementalTransport: SyncRecordTransport {
    private let base: LocalFolderSyncTransport
    nonisolated let frontierNamespace: String
    private var openedHeads = 0
    private var openedBatches = 0
    private var openedBytes: Int64 = 0

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
        openedHeads += page.observedProducerCount
        openedBatches += page.openedBatchCount
        openedBytes += page.openedByteCount
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

    func access() -> SteadyStateAccess {
        SteadyStateAccess(
            heads: openedHeads,
            batches: openedBatches,
            bytes: openedBytes
        )
    }

    func resetAccess() {
        openedHeads = 0
        openedBatches = 0
        openedBytes = 0
    }
}
