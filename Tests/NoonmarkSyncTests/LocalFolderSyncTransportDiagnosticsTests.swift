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
        let recorder = InMemoryDiagnosticRecorder()
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

        try await Task.sleep(for: .milliseconds(40))
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
        XCTAssertGreaterThanOrEqual(
            acquired.durationMilliseconds ?? 0,
            20
        )
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
