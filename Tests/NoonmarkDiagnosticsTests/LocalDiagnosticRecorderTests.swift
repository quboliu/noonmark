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
            maximumPersistentBytes: 96 * 1024,
            eventSegmentCount: 2,
            eventSegmentPayloadBytes: 16 * 1024,
            maximumEventBytes: 2 * 1024,
            metricCacheBytes: 8 * 1024,
            maximumMetricPayloadBytes: 4 * 1024,
            retentionInterval: 7 * 24 * 60 * 60,
            maximumQueuedEvents: 32,
            maximumQueuedBytes: 32 * 1024
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
                    byteCount: Int64(attempt * 1024)
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
        XCTAssertLessThanOrEqual(receipt.byteCount, 8 * 1024 * 1024)
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

    func testRelaunchRestoresExactPersistedSyncFailureCorrelation() async throws {
        let rootURL = temporaryDirectory(named: "failure-correlation")
        let failedAt = Date().addingTimeInterval(-30)
        let failure = DiagnosticFailure(domain: .syncProtocol, code: 7)
        var recorder: LocalDiagnosticRecorder? = try LocalDiagnosticRecorder(
            rootURL: rootURL,
            appIdentity: .testFixture
        )
        let operation = try XCTUnwrap(recorder).startOperation(
            kind: .localFirstSync,
            endpoint: .iCloudDrive,
            at: failedAt.addingTimeInterval(-5)
        )
        operation.stage(
            .transportFetch,
            at: failedAt.addingTimeInterval(-4)
        )
        let incidentID = operation.fail(
            failure,
            detail: DiagnosticFailure(domain: .posix, code: 60),
            at: failedAt
        )
        await recorder?.flush()
        recorder = nil

        let relaunched = try LocalDiagnosticRecorder(
            rootURL: rootURL,
            appIdentity: .testFixture
        )
        let correlation = await relaunched
            .persistedSyncFailureCorrelation(
                failure: failure,
                failedAt: failedAt
            )

        XCTAssertEqual(correlation?.operationID, operation.id)
        XCTAssertEqual(correlation?.incidentID, incidentID)
        let wrongTimestampCorrelation = await relaunched
            .persistedSyncFailureCorrelation(
                failure: failure,
                failedAt: failedAt.addingTimeInterval(0.001)
            )
        XCTAssertNil(wrongTimestampCorrelation)
        let wrongFailureCorrelation = await relaunched
            .persistedSyncFailureCorrelation(
                failure: DiagnosticFailure(
                    domain: .syncProtocol,
                    code: 6
                ),
                failedAt: failedAt
            )
        XCTAssertNil(wrongFailureCorrelation)
    }

    func testPersistedSyncFailureCorrelationRejectsAmbiguousExactMatches()
        async throws
    {
        let rootURL = temporaryDirectory(named: "ambiguous-correlation")
        let failedAt = Date().addingTimeInterval(-30)
        let failure = DiagnosticFailure(domain: .syncProtocol, code: 7)
        let recorder = try LocalDiagnosticRecorder(
            rootURL: rootURL,
            appIdentity: .testFixture
        )
        for _ in 0 ..< 2 {
            recorder.startOperation(
                kind: .localFirstSync,
                endpoint: .iCloudDrive,
                at: failedAt.addingTimeInterval(-5)
            ).fail(failure, at: failedAt)
        }
        await recorder.flush()

        let correlation = await recorder.persistedSyncFailureCorrelation(
            failure: failure,
            failedAt: failedAt
        )

        XCTAssertNil(correlation)
    }

    func testExportIncludesActiveOperationMarkerForInProgressSync() async throws {
        let rootURL = temporaryDirectory(named: "active-sync")
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let recorder = try LocalDiagnosticRecorder(
            rootURL: rootURL,
            appIdentity: .testFixture
        )
        let operation = recorder.startOperation(
            kind: .localFirstSync,
            endpoint: .iCloudDrive,
            at: startedAt
        )
        operation.stage(
            .transportFetch,
            progress: DiagnosticProgress(attempt: 2, recordCount: 17),
            at: startedAt.addingTimeInterval(5)
        )

        let package = try await recorder.snapshotPackage()

        let active = try XCTUnwrap(
            package.activeOperations.first { $0.id == operation.id }
        )
        XCTAssertEqual(active.startedAt, startedAt)
        XCTAssertEqual(active.updatedAt, startedAt.addingTimeInterval(5))
        XCTAssertEqual(active.endpoint, .iCloudDrive)
        XCTAssertEqual(active.lastStage, .transportFetch)
        XCTAssertEqual(active.lastProgress?.attempt, 2)
        XCTAssertEqual(active.lastProgress?.recordCount, 17)
        XCTAssertEqual(package.manifest.activeOperationCount, 1)
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

    func testRelaunchExcludesCorruptSegmentLineAndReportsPartialCollection() async throws {
        let rootURL = temporaryDirectory(named: "corrupt")
        var recorder: LocalDiagnosticRecorder? = try LocalDiagnosticRecorder(
            rootURL: rootURL,
            appIdentity: .testFixture
        )
        recorder?.startSession(at: Date(timeIntervalSince1970: 1_800_000_000))
        await recorder?.flush()
        recorder = nil

        let segmentURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.hasPrefix("events-") }
        )
        let handle = try FileHandle(forWritingTo: segmentURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{corrupt-record}\n".utf8))
        try handle.close()

        let relaunched = try LocalDiagnosticRecorder(
            rootURL: rootURL,
            appIdentity: .testFixture
        )
        let package = try await relaunched.snapshotPackage()

        XCTAssertEqual(package.manifest.corruptRecordCount, 1)
        XCTAssertTrue(package.manifest.collectionWasPartial)
        XCTAssertFalse(
            String(
                decoding: try Data(contentsOf: segmentURL),
                as: UTF8.self
            ).contains("corrupt-record")
        )
    }

    func testTinyMetricStormNeverCrossesAllocatedCapAtAnyWriteObservation() async throws {
        let rootURL = temporaryDirectory(named: "metric-cap")
        let maximumPersistentBytes: Int64 = 64 * 1024
        let recorder = try LocalDiagnosticRecorder(
            rootURL: rootURL,
            appIdentity: .testFixture,
            configuration: DiagnosticStorageConfiguration(
                maximumPersistentBytes: maximumPersistentBytes,
                eventSegmentCount: 2,
                eventSegmentPayloadBytes: 4 * 1024,
                maximumEventBytes: 1024,
                metricCacheBytes: 64 * 1024,
                maximumMetricPayloadBytes: 1024,
                maximumQueuedEvents: 16,
                maximumQueuedBytes: 8 * 1024
            )
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        recorder.startSession(at: start)

        for index in 0 ..< 400 {
            let json = Data("{\"sampleCount\":\(index)}".utf8)
            recorder.cacheMetricKitPayload(
                MetricKitPayloadSummary(
                    kind: .diagnostic,
                    intervalStart: start,
                    intervalEnd: start.addingTimeInterval(1),
                    crashCount: 0,
                    hangCount: 1,
                    cpuExceptionCount: 0,
                    diskWriteExceptionCount: 0,
                    rawJSONByteCount: json.count
                ),
                rawJSON: json,
                receivedAt: start.addingTimeInterval(Double(index))
            )
        }
        await recorder.flush()

        let health = await recorder.health()
        XCTAssertLessThanOrEqual(
            health.maximumObservedAllocatedBytes,
            maximumPersistentBytes
        )
        XCTAssertLessThanOrEqual(
            health.allocatedBytes,
            maximumPersistentBytes
        )
        XCTAssertGreaterThan(health.metricPayloadCount, 0)
    }

    func testMillionEventQueueStormRetainsOperationCapsuleAndReportsDrops() async throws {
        let rootURL = temporaryDirectory(named: "queue-storm")
        let recorder = try LocalDiagnosticRecorder(
            rootURL: rootURL,
            appIdentity: .testFixture,
            configuration: DiagnosticStorageConfiguration(
                maximumPersistentBytes: 96 * 1024,
                eventSegmentCount: 2,
                eventSegmentPayloadBytes: 8 * 1024,
                maximumEventBytes: 2 * 1024,
                metricCacheBytes: 0,
                maximumMetricPayloadBytes: 0,
                maximumQueuedEvents: 4,
                maximumQueuedBytes: 4 * 1024
            ),
            unifiedLoggingEnabled: false
        )
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let finishedAt = startedAt.addingTimeInterval(60)
        let operation = recorder.startOperation(
            kind: .localFirstSync,
            endpoint: .iCloudDrive,
            at: startedAt
        )

        for attempt in 0 ..< 1_000_000 {
            operation.stage(
                .coverageAndStability,
                progress: DiagnosticProgress(attempt: attempt)
            )
        }
        let incidentID = operation.fail(
            DiagnosticFailure(domain: .syncProtocol, code: 7),
            detail: DiagnosticFailure(domain: .posix, code: 60),
            at: finishedAt
        )
        await recorder.flush()

        let package = try await recorder.snapshotPackage()
        let operationEvents = package.records.filter {
            $0.event.operationID == operation.id
        }
        XCTAssertTrue(
            operationEvents.contains {
                $0.event.code == .operationFailed
                    && $0.event.incidentID == incidentID
                    && $0.event.failureDetail
                    == DiagnosticFailure(domain: .posix, code: 60)
            }
        )
        let capsule = try XCTUnwrap(
            package.operationCapsules.first {
                $0.operationID == operation.id
            }
        )
        XCTAssertEqual(capsule.startedAt, startedAt)
        XCTAssertEqual(capsule.finishedAt, finishedAt)
        XCTAssertEqual(capsule.endpoint, .iCloudDrive)
        XCTAssertEqual(capsule.outcome, .failed)
        XCTAssertEqual(capsule.incidentID, incidentID)
        XCTAssertEqual(
            capsule.failure,
            DiagnosticFailure(domain: .syncProtocol, code: 7)
        )
        XCTAssertGreaterThan(package.manifest.droppedRecordCount, 0)
        XCTAssertTrue(package.manifest.collectionWasPartial)
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
