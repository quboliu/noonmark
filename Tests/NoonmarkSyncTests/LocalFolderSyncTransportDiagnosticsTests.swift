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

    func testFetchRecordsLockWaitAndSafeRepositoryProgress() async throws {
        let rootURL = makeFolderURL()
        let record = try SyncRecordMapper().record(
            for: AppPreferencesEnvelope(
                theme: .coolGray,
                language: .chinese,
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            modifiedBy: SyncDeviceID("diagnostics-fixture")
        )
        try await LocalFolderSyncTransport(rootURL: rootURL).push([record])

        let descriptor = try lockRepository(at: rootURL)
        defer { close(descriptor) }
        let recorder = InMemoryDiagnosticRecorder()
        let operation = recorder.startOperation(
            kind: .localFirstSync,
            endpoint: .iCloudDrive
        )
        let fetchTask = Task {
            try await LocalFolderSyncTransport(
                rootURL: rootURL,
                diagnosticOperation: operation
            ).fetchAll()
        }

        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        let fetched = try await fetchTask.value
        XCTAssertEqual(fetched, [record])

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
        let fetchedEvidence = try XCTUnwrap(events.last {
            $0.stage == .transportFetch && $0.progress != nil
        })
        XCTAssertEqual(fetchedEvidence.progress?.recordCount, 1)
        XCTAssertGreaterThanOrEqual(
            fetchedEvidence.progress?.fileCount ?? 0,
            1
        )
        XCTAssertGreaterThan(
            fetchedEvidence.progress?.byteCount ?? 0,
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
        ).push([record])

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

    private func lockRepository(at rootURL: URL) throws -> Int32 {
        let lockURL = rootURL.appendingPathComponent(".repository.lock")
        let descriptor = lockURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return open(
                path,
                O_CREAT | O_RDWR,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return descriptor
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
