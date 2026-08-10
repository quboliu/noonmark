@testable import NoonmarkSync
import Darwin
import NoonmarkCore
import NoonmarkDiagnostics
import XCTest

final class LocalFolderSyncTransportDiagnosticsTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs = []
    }

    func testPushWaitsForLocalPublisherLockAndReportsSafeProgress() async throws {
        let rootURL = makeFolderURL()
        let epochID = UUID(
            uuidString: "D0000000-0000-0000-0000-000000000001"
        )!
        let firstRecord = try SyncRecordMapper().record(
            for: AppPreferencesEnvelope(
                theme: .coolGray,
                language: .chinese,
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            modifiedBy: SyncDeviceID("diagnostics-fixture")
        )
        try await LocalFolderSyncTransport(
            rootURL: rootURL,
            producerEpochID: epochID
        ).pushAccepting([firstRecord])
        let secondRecord = try SyncRecordMapper().record(
            for: AppPreferencesEnvelope(
                theme: .warmPaper,
                language: .english,
                updatedAt: Date(timeIntervalSince1970: 1_800_000_001)
            ),
            modifiedBy: SyncDeviceID("diagnostics-fixture")
        )

        let lockHolder = try RepositoryLockHolder(rootURL: rootURL)
        defer { try? lockHolder.release() }
        let lockWaitObserved = expectation(
            description: "transport entered repository lock wait"
        )
        let recorder = StageObservingDiagnosticRecorder(
            stage: .transportLockWait,
            expectation: lockWaitObserved
        )
        let operation = recorder.startOperation(
            kind: .localFirstSync,
            endpoint: .iCloudDrive
        )
        let pushTask = Task {
            try await LocalFolderSyncTransport(
                rootURL: rootURL,
                producerEpochID: epochID,
                diagnosticOperation: operation
            ).pushAccepting([secondRecord])
        }

        await fulfillment(of: [lockWaitObserved], timeout: 1)
        try lockHolder.release()
        try await pushTask.value

        let events = recorder.snapshot().map(\.event)
        let wait = try XCTUnwrap(events.first {
            $0.stage == .transportLockWait
        })
        XCTAssertNil(wait.progress)
        let acquired = try XCTUnwrap(events.first {
            $0.stage == .transportLockAcquired
        })
        XCTAssertNotNil(acquired.durationMilliseconds)
        let uploadEvidence = try XCTUnwrap(events.last {
            $0.stage == .upload && $0.progress != nil
        })
        XCTAssertEqual(uploadEvidence.progress?.recordCount, 1)
        XCTAssertGreaterThanOrEqual(
            uploadEvidence.progress?.fileCount ?? 0,
            2
        )
        XCTAssertGreaterThan(
            uploadEvidence.progress?.byteCount ?? 0,
            0
        )
        XCTAssertFalse(
            DiagnosticEvidenceTextRenderer.render(events)
                .contains(rootURL.path)
        )
    }

    func testCancellingPushWhileWaitingForRepositoryLockDoesNotPublish() async throws {
        let rootURL = makeFolderURL()
        let epochID = UUID(
            uuidString: "D0000000-0000-0000-0000-000000000002"
        )!
        let record = try SyncRecordMapper().record(
            for: AppPreferencesEnvelope(
                theme: .warmPaper,
                language: .english,
                updatedAt: Date(timeIntervalSince1970: 1_800_000_002)
            ),
            modifiedBy: SyncDeviceID("cancellation-fixture")
        )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let lockHolder = try RepositoryLockHolder(rootURL: rootURL)
        defer { try? lockHolder.release() }
        let lockWaitObserved = expectation(
            description: "transport entered cancellable repository lock wait"
        )
        let recorder = StageObservingDiagnosticRecorder(
            stage: .transportLockWait,
            expectation: lockWaitObserved
        )
        let operation = recorder.startOperation(
            kind: .localFirstSync,
            endpoint: .iCloudDrive
        )
        let transport = LocalFolderSyncTransport(
            rootURL: rootURL,
            producerEpochID: epochID,
            diagnosticOperation: operation
        )
        let pushTask = Task {
            try await transport.pushAccepting([record])
        }

        await fulfillment(of: [lockWaitObserved], timeout: 1)
        pushTask.cancel()

        do {
            _ = try await pushTask.value
            XCTFail("cancelled lock wait published a batch")
        } catch is CancellationError {
            // Expected: user-requested stop must not enter the critical section.
        } catch {
            XCTFail("unexpected cancellation error: \(type(of: error))")
        }
        let stages = recorder.snapshot().compactMap(\.event.stage)
        XCTAssertTrue(stages.contains(.transportLockWait))
        XCTAssertFalse(stages.contains(.transportLockAcquired))
        let snapshots = try await transport.fetchSnapshots()
        XCTAssertTrue(snapshots.isEmpty)
    }

    func testPushRecordsSafeBatchCountsAndBytesWithoutRepositoryPath() async throws {
        let rootURL = makeFolderURL()
        let record = try SyncRecordMapper().record(
            for: AppPreferencesEnvelope(
                theme: .warmPaper,
                language: .english,
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            modifiedBy: SyncDeviceID("diagnostics-fixture")
        )
        let recorder = InMemoryDiagnosticRecorder()
        let operation = recorder.startOperation(
            kind: .localFirstSync,
            endpoint: .localFolder
        )

        try await LocalFolderSyncTransport(
            rootURL: rootURL,
            diagnosticOperation: operation
        ).pushAccepting([record])

        let events = recorder.snapshot().map(\.event)
        let upload = try XCTUnwrap(events.last {
            $0.stage == .upload && $0.progress != nil
        })
        XCTAssertEqual(upload.progress?.recordCount, 1)
        XCTAssertGreaterThanOrEqual(upload.progress?.fileCount ?? 0, 1)
        XCTAssertGreaterThan(upload.progress?.byteCount ?? 0, 0)
        XCTAssertNotNil(upload.durationMilliseconds)
        XCTAssertFalse(
            DiagnosticEvidenceTextRenderer.render(events)
                .contains(rootURL.path)
        )
    }

    private func makeFolderURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noonmark-transport-diagnostics-\(UUID().uuidString)",
                isDirectory: true
            )
        temporaryURLs.append(url)
        return url
    }
}

private final class StageObservingDiagnosticRecorder:
    DiagnosticRecording,
    @unchecked Sendable
{
    let sessionID: DiagnosticSessionID

    private let recorder: InMemoryDiagnosticRecorder
    private let stage: DiagnosticOperationStage
    private let expectation: XCTestExpectation
    private let lock = NSLock()
    private var didObserveStage = false

    init(
        stage: DiagnosticOperationStage,
        expectation: XCTestExpectation
    ) {
        let recorder = InMemoryDiagnosticRecorder()
        self.recorder = recorder
        sessionID = recorder.sessionID
        self.stage = stage
        self.expectation = expectation
    }

    func record(_ event: EvidenceEvent, at timestamp: Date) {
        recorder.record(event, at: timestamp)
        guard event.stage == stage else { return }
        lock.lock()
        defer { lock.unlock() }
        guard didObserveStage == false else { return }
        didObserveStage = true
        expectation.fulfill()
    }

    func snapshot() -> [RecordedEvidence] {
        recorder.snapshot()
    }
}

private final class RepositoryLockHolder {
    private let process: Process
    private let releaseInput: FileHandle
    private var released = false

    init(rootURL: URL) throws {
        let lockURL = rootURL.appendingPathComponent(".repository.lock")
        let input = Pipe()
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [
            "-e",
            "use Fcntl qw(:flock); $| = 1; open my $lock, '>>', $ARGV[0] or exit 2; flock($lock, LOCK_EX) or exit 3; print STDOUT '1'; read(STDIN, my $release, 1);",
            lockURL.path,
        ]
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        guard output.fileHandleForReading.readData(ofLength: 1) == Data([49]) else {
            process.terminate()
            process.waitUntilExit()
            throw POSIXError(.EIO)
        }
        self.process = process
        releaseInput = input.fileHandleForWriting
    }

    deinit {
        try? release()
    }

    func release() throws {
        guard released == false else { return }
        releaseInput.write(Data([1]))
        releaseInput.closeFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw POSIXError(.EIO)
        }
        released = true
    }
}
