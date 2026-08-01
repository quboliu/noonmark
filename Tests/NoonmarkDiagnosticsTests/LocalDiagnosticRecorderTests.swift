@testable import NoonmarkDiagnostics
import XCTest

final class LocalDiagnosticRecorderTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs = []
    }

    func testPersistentEvidenceStaysWithinAllocatedByteCapAndExportsKnownSchema() async throws {
        let rootURL = temporaryDirectory(named: "bounded")
        let exportURL = temporaryFile(named: "bounded.noonmarkdiagnostics")
        let configuration = DiagnosticStorageConfiguration(
            maximumPersistentBytes: 96 * 1_024,
            eventSegmentCount: 2,
            eventSegmentPayloadBytes: 16 * 1_024,
            maximumEventBytes: 2 * 1_024,
            metricCacheBytes: 8 * 1_024,
            maximumMetricPayloadBytes: 4 * 1_024,
            retentionInterval: 7 * 24 * 60 * 60,
            maximumQueuedEvents: 32,
            maximumQueuedBytes: 32 * 1_024
        )
        let recorder = try LocalDiagnosticRecorder(
            rootURL: rootURL,
            appIdentity: .testFixture,
            configuration: configuration
        )
        recorder.startSession(at: Date(timeIntervalSince1970: 1_800_000_000))

        for attempt in 0 ..< 500 {
            let operation = recorder.startOperation(
                kind: .localFirstSync,
                endpoint: .iCloudDrive,
                at: Date(timeIntervalSince1970: 1_800_000_001 + Double(attempt))
            )
            operation.stage(
                .coverageAndStability,
                progress: DiagnosticProgress(
                    attempt: attempt,
                    recordCount: attempt * 10,
                    byteCount: Int64(attempt * 1_024)
                )
            )
            operation.succeed()
        }

        await recorder.flush()
        let health = await recorder.health()
        XCTAssertLessThanOrEqual(
            health.allocatedBytes,
            configuration.maximumPersistentBytes
        )
        XCTAssertGreaterThan(health.recordCount, 0)

        let preview = try await recorder.preview()
        XCTAssertEqual(preview.schemaVersion, RecordedEvidence.currentSchemaVersion)
        XCTAssertEqual(preview.allocatedBytes, health.allocatedBytes)

        let receipt = try await recorder.export(to: exportURL)
        XCTAssertLessThanOrEqual(receipt.byteCount, 8 * 1_024 * 1_024)
        XCTAssertFalse(receipt.sha256.isEmpty)

        let package = try JSONDecoder().decode(
            DiagnosticExportPackage.self,
            from: Data(contentsOf: exportURL)
        )
        XCTAssertEqual(package.manifest.appIdentity, .testFixture)
        XCTAssertEqual(package.manifest.recordCount, package.records.count)
        XCTAssertTrue(
            package.operationCapsules.contains {
                $0.outcome == .succeeded
            }
        )
    }

    func testNewSessionRecordsPreviousInterruptedOperationWithoutGuessingCause() async throws {
        let rootURL = temporaryDirectory(named: "interrupted")
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var recorder: LocalDiagnosticRecorder? = try LocalDiagnosticRecorder(
            rootURL: rootURL,
            appIdentity: .testFixture
        )
        let operation = try XCTUnwrap(recorder).startOperation(
            kind: .localFirstSync,
            endpoint: .iCloudDrive,
            at: startedAt
        )
        operation.stage(.transportLockWait, at: startedAt.addingTimeInterval(5))
        await recorder?.flush()
        recorder = nil

        let relaunched = try LocalDiagnosticRecorder(
            rootURL: rootURL,
            appIdentity: .testFixture
        )
        relaunched.startSession(at: startedAt.addingTimeInterval(30))
        await relaunched.flush()

        let package = try await relaunched.snapshotPackage()
        let interruption = try XCTUnwrap(
            package.records.last {
                $0.event.code == .previousSessionInterrupted
            }
        )
        XCTAssertEqual(interruption.event.operationID, operation.id)
        XCTAssertEqual(interruption.event.stage, .transportLockWait)
        XCTAssertNil(interruption.event.failure)
        XCTAssertNil(interruption.event.incidentID)
    }

    func testClearRemovesOnlyManagedDiagnosticEvidence() async throws {
        let parentURL = temporaryDirectory(named: "clear")
        try FileManager.default.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true
        )
        let rootURL = parentURL.appendingPathComponent(
            "Diagnostics",
            isDirectory: true
        )
        let businessURL = parentURL.appendingPathComponent("noonmark.sqlite")
        try Data("business-fact".utf8).write(to: businessURL)
        let recorder = try LocalDiagnosticRecorder(
            rootURL: rootURL,
            appIdentity: .testFixture
        )
        recorder.startSession()
        await recorder.flush()

        try await recorder.clear()

        XCTAssertEqual(
            try String(contentsOf: businessURL, encoding: .utf8),
            "business-fact"
        )
        let health = await recorder.health()
        XCTAssertEqual(health.recordCount, 0)
    }

    private func temporaryDirectory(named name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noonmark-diagnostics-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
        temporaryURLs.append(url)
        return url
    }

    private func temporaryFile(named name: String) -> URL {
        let directory = temporaryDirectory(named: "export")
        return directory.appendingPathComponent(name)
    }
}
