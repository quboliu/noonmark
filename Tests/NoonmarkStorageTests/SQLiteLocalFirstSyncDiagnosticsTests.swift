import NoonmarkCore
import NoonmarkDiagnostics
@testable import NoonmarkStorage
import NoonmarkSync
import XCTest

final class SQLiteLocalFirstSyncDiagnosticsTests: XCTestCase {
    private var databaseURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in databaseURLs {
            try? FileManager.default.removeItem(at: url)
        }
        databaseURLs = []
    }

    func testSuccessfulSyncRecordsEveryFixedPointStageAndTerminalSummary()
        async throws
    {
        let databaseURL = makeDatabaseURL("success")
        let engine = NoonmarkEngine()
        _ = try engine.createPoolTask(
            title: "diagnostic baseline fixture",
            now: Date(timeIntervalSince1970: 1_799_999_999)
        )
        try SQLiteEngineRepository(databaseURL: databaseURL)
            .save(engine.snapshot())
        try SQLiteSyncRepository(databaseURL: databaseURL)
            .saveDeviceIdentity(
                SyncDeviceIdentity(
                    deviceID: SyncDeviceID("diagnostic-baseline-device"),
                    createdAt: Date(timeIntervalSince1970: 1_799_999_999)
                )
            )
        let recorder = InMemoryDiagnosticRecorder()
        let operation = recorder.startOperation(
            kind: .localFirstSync,
            endpoint: .iCloudDrive
        )

        _ = try await SQLiteLocalFirstSyncCoordinator(
            databaseURL: databaseURL,
            transport: InMemorySyncTransport(),
            diagnosticOperation: operation
        ).sync(now: Date(timeIntervalSince1970: 1_800_000_000))

        let events = recorder.snapshot().map(\.event)
        let stages = events.compactMap(\.stage)
        for expected in [
            DiagnosticOperationStage.localLoad,
            .transportFetch,
            .baselinePrepare,
            .baselineCoverageGap,
            .upload,
            .downloadMerge,
            .catchUpUpload,
            .finalFetch,
            .coverageAndStability,
            .successMetadata
        ] {
            XCTAssertTrue(stages.contains(expected), "missing \(expected)")
        }
        XCTAssertEqual(events.last?.code, .operationSucceeded)
        XCTAssertEqual(
            events.last?.progress?.conflictCount,
            0
        )
    }

    func testTransportFailureRecordsLastExactStageAndTypedFailure() async throws {
        let databaseURL = makeDatabaseURL("transport-failure")
        try SQLiteEngineRepository(databaseURL: databaseURL)
            .save(NoonmarkEngine().snapshot())
        let recorder = InMemoryDiagnosticRecorder()
        let operation = recorder.startOperation(
            kind: .localFirstSync,
            endpoint: .iCloudDrive
        )

        do {
            _ = try await SQLiteLocalFirstSyncCoordinator(
                databaseURL: databaseURL,
                transport: FailingFetchTransport(),
                diagnosticOperation: operation
            ).sync(now: Date(timeIntervalSince1970: 1_800_000_000))
            XCTFail("transport failure must remain visible")
        } catch {
            XCTAssertEqual(error as? FailingFetchTransport.Failure, .offline)
        }

        let terminal = try XCTUnwrap(
            recorder.snapshot().map(\.event).last
        )
        XCTAssertEqual(terminal.code, .operationFailed)
        XCTAssertEqual(terminal.stage, .transportFetch)
        XCTAssertEqual(terminal.failure?.domain, .syncProtocol)
        XCTAssertEqual(terminal.failure?.code, 7)
        XCTAssertEqual(terminal.failureDetail?.domain, .unknown)
        XCTAssertEqual(terminal.failureDetail?.code, 0)
        XCTAssertNotNil(terminal.incidentID)
    }

    func testAppCanOwnSuccessUntilMergedStateIsInstalled() async throws {
        let databaseURL = makeDatabaseURL("caller-owned-success")
        try SQLiteEngineRepository(databaseURL: databaseURL)
            .save(NoonmarkEngine().snapshot())
        let recorder = InMemoryDiagnosticRecorder()
        let operation = recorder.startOperation(
            kind: .localFirstSync,
            endpoint: .iCloudDrive
        )

        _ = try await SQLiteLocalFirstSyncCoordinator(
            databaseURL: databaseURL,
            transport: InMemorySyncTransport(),
            diagnosticOperation: operation,
            completesDiagnosticOperationOnSuccess: false
        ).sync(now: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertFalse(
            recorder.snapshot().contains { $0.event.code.isTerminal }
        )
        XCTAssertEqual(
            recorder.snapshot().last?.event.stage,
            .successMetadata
        )

        operation.stage(.installMergedState)
        operation.succeed()

        XCTAssertEqual(
            recorder.snapshot().suffix(2).map(\.event.code),
            [.operationStage, .operationSucceeded]
        )
    }

    func testMergeRejectionSurfacesTypedReasonSubcode() async throws {
        let databaseURL = makeDatabaseURL("merge-rejection")
        let baselineNow = Date(timeIntervalSince1970: 1_799_999_900)
        let engine = NoonmarkEngine()
        _ = try engine.createPoolTask(
            title: "merge rejection fixture",
            now: baselineNow
        )
        try SQLiteEngineRepository(databaseURL: databaseURL)
            .save(engine.snapshot())
        try SQLiteSyncRepository(databaseURL: databaseURL)
            .saveDeviceIdentity(
                SyncDeviceIdentity(
                    deviceID: SyncDeviceID("merge-rejection-device"),
                    createdAt: baselineNow
                )
            )
        let remote = InMemorySyncTransport()
        _ = try await SQLiteLocalFirstSyncCoordinator(
            databaseURL: databaseURL,
            transport: remote
        ).sync(now: Date(timeIntervalSince1970: 1_799_999_999))

        _ = try engine.createPoolTask(
            title: "pending poison upload",
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try SQLiteEngineRepository(databaseURL: databaseURL)
            .save(engine.snapshot())
        let recorder = InMemoryDiagnosticRecorder()
        let operation = recorder.startOperation(
            kind: .localFirstSync,
            endpoint: .iCloudDrive
        )

        do {
            _ = try await SQLiteLocalFirstSyncCoordinator(
                databaseURL: databaseURL,
                transport: FailingPushTransport(remote: remote),
                diagnosticOperation: operation
            ).sync(now: Date(timeIntervalSince1970: 1_800_000_100))
            XCTFail("merge rejection must fail the sync operation")
        } catch {
            XCTAssertEqual(
                error as? SyncRecordTransportError,
                .invalidCurrentRecordMerge(
                    recordID: FailingPushTransport.rejectedRecordID,
                    reason: .invalidContentClock
                )
            )
        }

        let terminal = try XCTUnwrap(
            recorder.snapshot().map(\.event).last
        )
        XCTAssertEqual(terminal.code, .operationFailed)
        XCTAssertEqual(terminal.failure?.domain, .syncProtocol)
        XCTAssertEqual(terminal.failure?.code, 7)
        XCTAssertEqual(terminal.failureDetail?.domain, .syncProtocol)
        XCTAssertEqual(terminal.failureDetail?.code, 251)
        XCTAssertNotNil(terminal.incidentID)
    }

    private func makeDatabaseURL(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noonmark-sync-diagnostics-\(name)-\(UUID().uuidString).sqlite"
            )
        databaseURLs.append(url)
        return url
    }
}

private actor FailingFetchTransport: SyncRecordTransport {
    enum Failure: Error, Equatable {
        case offline
    }

    func pushAccepting(
        _: [SyncRecord]
    ) async throws -> SyncTransportPushReceipt {
        fixturePushReceipt()
    }

    func pull(
        after _: SyncTransportFrontier,
        limit _: Int
    ) async throws -> SyncTransportChangePage {
        throw Failure.offline
    }
}

private actor FailingPushTransport: SyncRecordTransport {
    static let rejectedRecordID = SyncRecordID("day:2026-08-04")

    private let remote: InMemorySyncTransport

    init(remote: InMemorySyncTransport) {
        self.remote = remote
    }

    func pushAccepting(
        _: [SyncRecord]
    ) async throws -> SyncTransportPushReceipt {
        throw SyncRecordTransportError.invalidCurrentRecordMerge(
            recordID: Self.rejectedRecordID,
            reason: .invalidContentClock
        )
    }

    func pull(
        after frontier: SyncTransportFrontier,
        limit: Int
    ) async throws -> SyncTransportChangePage {
        try await remote.pull(after: frontier, limit: limit)
    }
}
