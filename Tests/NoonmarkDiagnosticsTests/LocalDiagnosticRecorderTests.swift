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

    @MainActor
    func testPreparationRunsRecorderInitializationOutsideMainThread() async throws {
        let rootURL = temporaryDirectory(named: "async-preparation")
        let observation = RecorderInitializationThreadObservation()

        _ = try await LocalDiagnosticRecorder.prepare(
            rootURL: rootURL,
            appIdentity: .testFixture,
            initializationObserver: {
                observation.record(isMainThread: Thread.isMainThread)
            }
        )

        XCTAssertFalse(try XCTUnwrap(observation.wasMainThread))
    }

    @MainActor
    func testDefaultIdentityResolutionRunsOutsideMainThread() async throws {
        let rootURL = temporaryDirectory(named: "default-identity-preparation")
        let observation = RecorderInitializationThreadObservation()

        _ = try await LocalDiagnosticRecorder.prepare(
            rootURL: rootURL,
            currentAppIdentityObserver: {
                observation.record(isMainThread: Thread.isMainThread)
            }
        )

        XCTAssertFalse(try XCTUnwrap(observation.wasMainThread))
    }

    @MainActor
    func testPreparationFailureStaysTypedAndRunsOutsideMainThread() async throws {
        let rootURL = temporaryDirectory(named: "async-preparation-failure")
        try Data("not-a-directory".utf8).write(to: rootURL)
        let observation = RecorderInitializationThreadObservation()

        do {
            _ = try await LocalDiagnosticRecorder.prepare(
                rootURL: rootURL,
                appIdentity: .testFixture,
                initializationObserver: {
                    observation.record(isMainThread: Thread.isMainThread)
                }
            )
            XCTFail("Expected recorder preparation to reject a file root")
        } catch {
            XCTAssertEqual(error as? DiagnosticStorageError, .invalidRoot)
            XCTAssertEqual(
                (error as? any DiagnosticFailureProviding)?
                    .diagnosticFailure,
                DiagnosticFailure(domain: .diagnostics, code: 1)
            )
        }
        XCTAssertFalse(try XCTUnwrap(observation.wasMainThread))
    }

    func testPersistentEvidenceStaysWithinAllocatedByteCapAndExportsKnownSchema() async throws {
        XCTAssertEqual(
            DiagnosticStorageConfiguration.production.maximumPersistentBytes,
            4 * 1024 * 1024
        )
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
        let incidentID = DiagnosticIncidentID()
        recorder?.record(
            .mutationRejected(
                context: .task,
                reason: .exclusiveOperationInProgress,
                operationID: operation.id,
                incidentID: incidentID
            ),
            at: startedAt.addingTimeInterval(10)
        )
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
        XCTAssertEqual(interruption.event.incidentID, incidentID)
        XCTAssertEqual(interruption.event.stage, .transportLockWait)
        XCTAssertNil(interruption.event.failure)
        let interruptedCapsule = try XCTUnwrap(
            package.operationCapsules.last {
                $0.operationID == operation.id
                    && $0.outcome == .interrupted
            }
        )
        XCTAssertEqual(interruptedCapsule.incidentID, incidentID)
        let recoveredInterruption = await relaunched
            .latestInterruptedOperation(kind: .localFirstSync)
        XCTAssertEqual(recoveredInterruption, interruptedCapsule)
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

    func testInitializerRejectsDiagnosticRootSymlinkWithoutTouchingExternalFiles() throws {
        let parentURL = temporaryDirectory(named: "root-symlink-parent")
        let externalURL = temporaryDirectory(named: "root-symlink-external")
        try FileManager.default.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: externalURL,
            withIntermediateDirectories: true
        )
        let canaryURL = externalURL.appendingPathComponent("index.json")
        let canary = Data("EXTERNAL-DIAGNOSTIC-ROOT-CANARY".utf8)
        try canary.write(to: canaryURL)
        let diagnosticRootURL = parentURL.appendingPathComponent(
            "Diagnostics",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: diagnosticRootURL,
            withDestinationURL: externalURL
        )

        XCTAssertThrowsError(
            try LocalDiagnosticRecorder(
                rootURL: diagnosticRootURL,
                appIdentity: .testFixture,
                configuration: .production,
                unifiedLoggingEnabled: false
            )
        ) { error in
            XCTAssertEqual(error as? DiagnosticStorageError, .invalidRoot)
        }
        XCTAssertEqual(try Data(contentsOf: canaryURL), canary)
    }

    func testInitializerRejectsDiagnosticRootThroughAncestorSymlinkWithoutTouchingExternalDirectory() throws {
        let parentURL = temporaryDirectory(named: "root-ancestor-symlink-parent")
        let externalURL = temporaryDirectory(named: "root-ancestor-symlink-external")
        try FileManager.default.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: externalURL,
            withIntermediateDirectories: true
        )
        let canaryURL = externalURL.appendingPathComponent("canary.txt")
        let canary = Data("EXTERNAL-ANCESTOR-CANARY".utf8)
        try canary.write(to: canaryURL)
        let redirectedAncestorURL = parentURL.appendingPathComponent(
            "redirected",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: redirectedAncestorURL,
            withDestinationURL: externalURL
        )
        let unexpectedExternalDirectoryURL = externalURL
            .appendingPathComponent("nested", isDirectory: true)
        let diagnosticRootURL = redirectedAncestorURL
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)

        XCTAssertThrowsError(
            try LocalDiagnosticRecorder(
                rootURL: diagnosticRootURL,
                appIdentity: .testFixture,
                configuration: .production,
                unifiedLoggingEnabled: false
            )
        ) { error in
            XCTAssertEqual(error as? DiagnosticStorageError, .invalidRoot)
        }
        XCTAssertEqual(try Data(contentsOf: canaryURL), canary)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: unexpectedExternalDirectoryURL.path
            )
        )
    }

    func testRuntimeRootReplacementNeverRedirectsManagedIOToExternalDirectory() async throws {
        let parentURL = temporaryDirectory(named: "root-runtime-parent")
        let externalURL = temporaryDirectory(named: "root-runtime-external")
        try FileManager.default.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: externalURL.appendingPathComponent("metrics"),
            withIntermediateDirectories: true
        )
        let rootURL = parentURL.appendingPathComponent(
            "Diagnostics",
            isDirectory: true
        )
        let recorder = try LocalDiagnosticRecorder(
            rootURL: rootURL,
            appIdentity: .testFixture,
            configuration: .production,
            unifiedLoggingEnabled: false
        )
        recorder.startSession()
        await recorder.flush()

        let indexCanaryURL = externalURL.appendingPathComponent("index.json")
        let eventCanaryURL = externalURL.appendingPathComponent("events-00.ndjson")
        let metricCanaryURL = externalURL
            .appendingPathComponent("metrics")
            .appendingPathComponent("metric-external-canary.json")
        let externalEventID = UUID()
        var externalEventData = try JSONEncoder().encode(
            RecordedEvidence(
                sequence: 9999,
                eventID: externalEventID,
                timestamp: Date(),
                sessionID: DiagnosticSessionID(),
                event: .cleanShutdown()
            )
        )
        externalEventData.append(0x0A)
        let canaries = [
            indexCanaryURL: Data("EXTERNAL-INDEX-CANARY".utf8),
            eventCanaryURL: externalEventData,
            metricCanaryURL: Data("EXTERNAL-METRIC-CANARY".utf8)
        ]
        for (url, data) in canaries {
            try data.write(to: url)
        }
        let canaryFingerprints = try Dictionary(
            uniqueKeysWithValues: canaries.keys.map {
                ($0, try DiagnosticFileFingerprint(at: $0))
            }
        )
        func assertCanariesUnchanged(after stage: String) throws {
            for (url, fingerprint) in canaryFingerprints {
                try XCTAssertDiagnosticFileUnchanged(
                    at: url,
                    from: fingerprint,
                    "external canary changed after \(stage)"
                )
            }
        }
        let displacedRootURL = parentURL.appendingPathComponent(
            "DisplacedDiagnostics",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: rootURL, to: displacedRootURL)
        try FileManager.default.createSymbolicLink(
            at: rootURL,
            withDestinationURL: externalURL
        )

        recorder.record(.cleanShutdown())
        let summary = MetricKitPayloadSummary(
            kind: .diagnostic,
            intervalStart: Date(),
            intervalEnd: Date(),
            crashCount: 0,
            hangCount: 1,
            cpuExceptionCount: 0,
            diskWriteExceptionCount: 0,
            rawJSONByteCount: 2
        )
        recorder.cacheMetricKitPayload(
            summary,
            rawJSON: Data("{}".utf8),
            receivedAt: Date()
        )
        await recorder.flush()
        try assertCanariesUnchanged(after: "flush")

        let snapshot = try await recorder.snapshotPackage()
        XCTAssertFalse(snapshot.records.contains { $0.eventID == externalEventID })
        let snapshotText = try XCTUnwrap(
            String(
                data: JSONEncoder().encode(snapshot),
                encoding: .utf8
            )
        )
        XCTAssertFalse(snapshotText.contains(externalEventID.uuidString))
        try assertCanariesUnchanged(after: "snapshot")

        let exportURL = temporaryFile(named: "runtime-root.noonmarkdiagnostics")
        _ = try await recorder.export(to: exportURL)
        let exportText = try XCTUnwrap(
            String(
                data: Data(contentsOf: exportURL),
                encoding: .utf8
            )
        )
        XCTAssertFalse(exportText.contains(externalEventID.uuidString))
        try assertCanariesUnchanged(after: "export")

        try await recorder.clear()
        try assertCanariesUnchanged(after: "clear")
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
        let start = Date(timeIntervalSince1970: 1_800_000_000)
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
            ),
            unifiedLoggingEnabled: false,
            now: { start.addingTimeInterval(400) }
        )
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

    func testSevenDayRetentionExpiresEveryDiagnosticMediumAndCounterWindow() async throws {
        let rootURL = temporaryDirectory(named: "all-media-retention")
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let retentionInterval: TimeInterval = 7 * 24 * 60 * 60
        let configuration = DiagnosticStorageConfiguration(
            maximumPersistentBytes: 128 * 1024,
            eventSegmentCount: 2,
            eventSegmentPayloadBytes: 8 * 1024,
            maximumEventBytes: 2 * 1024,
            metricCacheBytes: 16 * 1024,
            maximumMetricPayloadBytes: 256,
            retentionInterval: retentionInterval,
            maximumQueuedEvents: 16,
            maximumQueuedBytes: 16 * 1024
        )
        var recorder: LocalDiagnosticRecorder? = try LocalDiagnosticRecorder(
            rootURL: rootURL,
            appIdentity: .testFixture,
            configuration: configuration,
            unifiedLoggingEnabled: false,
            now: { base.addingTimeInterval(6) }
        )
        recorder?.startSession(at: base)
        let active = try XCTUnwrap(recorder).startOperation(
            kind: .localFirstSync,
            endpoint: .iCloudDrive,
            at: base.addingTimeInterval(1)
        )
        active.stage(.transportFetch, at: base.addingTimeInterval(2))
        let failed = try XCTUnwrap(recorder).startOperation(
            kind: .persistence,
            at: base.addingTimeInterval(3)
        )
        failed.fail(
            DiagnosticFailure(domain: .posix, code: 28),
            at: base.addingTimeInterval(4)
        )
        let metricJSON = Data(#"{"sampleCount":1}"#.utf8)
        recorder?.cacheMetricKitPayload(
            MetricKitPayloadSummary(
                kind: .diagnostic,
                intervalStart: base,
                intervalEnd: base.addingTimeInterval(5),
                crashCount: 1,
                hangCount: 0,
                cpuExceptionCount: 0,
                diskWriteExceptionCount: 0,
                rawJSONByteCount: metricJSON.count
            ),
            rawJSON: metricJSON,
            receivedAt: base.addingTimeInterval(5)
        )
        let oversizedJSON = Data(repeating: 0x41, count: 257)
        recorder?.cacheMetricKitPayload(
            MetricKitPayloadSummary(
                kind: .metric,
                intervalStart: base,
                intervalEnd: base.addingTimeInterval(6),
                crashCount: 0,
                hangCount: 0,
                cpuExceptionCount: 0,
                diskWriteExceptionCount: 0,
                rawJSONByteCount: oversizedJSON.count
            ),
            rawJSON: oversizedJSON,
            receivedAt: base.addingTimeInterval(6)
        )
        await recorder?.flush()

        let initial = try await XCTUnwrap(recorder).snapshotPackage()
        XCTAssertFalse(initial.records.isEmpty)
        XCTAssertEqual(initial.activeOperations.map(\.id), [active.id])
        XCTAssertEqual(initial.operationCapsules.map(\.operationID), [failed.id])
        XCTAssertEqual(initial.metricAttachments.count, 2)
        XCTAssertEqual(initial.manifest.oversizedMetricPayloadCount, 1)
        recorder = nil

        let abandonedAtomicWrite = rootURL.appendingPathComponent(
            ".events-00.ndjson.tmp"
        )
        try Data(repeating: 0x41, count: 4 * 1024).write(
            to: abandonedAtomicWrite
        )

        let expiredNow = base.addingTimeInterval(retentionInterval + 60)
        var relaunched: LocalDiagnosticRecorder? = try LocalDiagnosticRecorder(
            rootURL: rootURL,
            appIdentity: .testFixture,
            configuration: configuration,
            unifiedLoggingEnabled: false,
            now: { expiredNow }
        )
        let expired: DiagnosticExportPackage
        let health: DiagnosticHealth
        do {
            let activeRecorder = try XCTUnwrap(relaunched)
            expired = try await activeRecorder.snapshotPackage()
            health = await activeRecorder.health()
        }

        XCTAssertTrue(expired.records.isEmpty)
        XCTAssertTrue(expired.activeOperations.isEmpty)
        XCTAssertTrue(expired.operationCapsules.isEmpty)
        XCTAssertTrue(expired.metricAttachments.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: abandonedAtomicWrite.path)
        )
        XCTAssertLessThanOrEqual(
            health.allocatedBytes,
            configuration.maximumPersistentBytes
        )
        XCTAssertLessThanOrEqual(
            health.maximumObservedAllocatedBytes,
            configuration.maximumPersistentBytes
        )
        relaunched = nil

        let counterExpiryNow = base.addingTimeInterval(
            retentionInterval + 24 * 60 * 60 + 60
        )
        let counterExpired = try LocalDiagnosticRecorder(
            rootURL: rootURL,
            appIdentity: .testFixture,
            configuration: configuration,
            unifiedLoggingEnabled: false,
            now: { counterExpiryNow }
        )
        let finalPackage = try await counterExpired.snapshotPackage()
        XCTAssertEqual(finalPackage.manifest.oversizedMetricPayloadCount, 0)
    }

    func testAllCriticalQueueAndDiskStormPreservesFailedOperationCapsuleAndReportsLoss() async throws {
        let rootURL = temporaryDirectory(named: "all-critical-storm")
        let maximumPersistentBytes: Int64 = 64 * 1024
        let recorder = try LocalDiagnosticRecorder(
            rootURL: rootURL,
            appIdentity: .testFixture,
            configuration: DiagnosticStorageConfiguration(
                maximumPersistentBytes: maximumPersistentBytes,
                eventSegmentCount: 2,
                eventSegmentPayloadBytes: 4 * 1024,
                maximumEventBytes: 2 * 1024,
                metricCacheBytes: 0,
                maximumMetricPayloadBytes: 0,
                maximumQueuedEvents: 4,
                maximumQueuedBytes: 4 * 1024
            ),
            unifiedLoggingEnabled: false
        )
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let noise = EvidenceEvent.mutationRejected(
            context: .task,
            reason: .domainRule,
            operationID: nil,
            incidentID: DiagnosticIncidentID()
        )

        for batch in 0 ..< 16 {
            for offset in 0 ..< 8 {
                recorder.record(
                    noise,
                    at: startedAt.addingTimeInterval(
                        Double(batch * 8 + offset)
                    )
                )
            }
            await recorder.flush()
        }

        let operation = recorder.startOperation(
            kind: .localFirstSync,
            endpoint: .iCloudDrive,
            at: startedAt.addingTimeInterval(1000)
        )
        for _ in 0 ..< 20000 {
            recorder.record(noise, at: startedAt.addingTimeInterval(1001))
        }
        let failure = DiagnosticFailure(domain: .posix, code: 28)
        let incidentID = operation.fail(
            failure,
            at: startedAt.addingTimeInterval(1002)
        )
        for _ in 0 ..< 20000 {
            recorder.record(noise, at: startedAt.addingTimeInterval(1003))
        }
        await recorder.flush()

        for index in 0 ..< 16 {
            let timestamp = startedAt.addingTimeInterval(Double(2000 + index))
            let successful = recorder.startOperation(
                kind: .persistence,
                at: timestamp
            )
            successful.succeed(at: timestamp.addingTimeInterval(0.5))
            await recorder.flush()
        }

        let package = try await recorder.snapshotPackage()
        let health = await recorder.health()
        let capsule = try XCTUnwrap(
            package.operationCapsules.first {
                $0.operationID == operation.id
            }
        )
        XCTAssertEqual(capsule.incidentID, incidentID)
        XCTAssertEqual(capsule.endpoint, .iCloudDrive)
        XCTAssertEqual(capsule.startedAt, startedAt.addingTimeInterval(1000))
        XCTAssertEqual(capsule.finishedAt, startedAt.addingTimeInterval(1002))
        XCTAssertEqual(capsule.outcome, .failed)
        XCTAssertEqual(capsule.failure, failure)
        XCTAssertGreaterThan(package.manifest.droppedCriticalRecordCount, 0)
        XCTAssertGreaterThan(
            package.manifest.compactedCriticalEvidenceCount,
            0
        )
        XCTAssertTrue(package.manifest.collectionWasPartial)
        XCTAssertLessThanOrEqual(
            health.maximumObservedAllocatedBytes,
            maximumPersistentBytes
        )
        XCTAssertLessThanOrEqual(
            health.allocatedBytes,
            maximumPersistentBytes
        )
    }

    func testRetentionKeepsRecordExactlyAtCutoffAndRemovesOneSecondOlderRecord() async throws {
        let rootURL = temporaryDirectory(named: "record-cutoff")
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let retentionInterval: TimeInterval = 7 * 24 * 60 * 60
        let configuration = DiagnosticStorageConfiguration(
            retentionInterval: retentionInterval
        )
        var recorder: LocalDiagnosticRecorder? = try LocalDiagnosticRecorder(
            rootURL: rootURL,
            appIdentity: .testFixture,
            configuration: configuration,
            unifiedLoggingEnabled: false,
            now: { base }
        )
        recorder?.record(.sessionStarted(), at: base)
        recorder?.record(
            .cleanShutdown(),
            at: base.addingTimeInterval(1)
        )
        await recorder?.flush()
        recorder = nil

        let boundaryNow = base.addingTimeInterval(retentionInterval + 1)
        let relaunched = try LocalDiagnosticRecorder(
            rootURL: rootURL,
            appIdentity: .testFixture,
            configuration: configuration,
            unifiedLoggingEnabled: false,
            now: { boundaryNow }
        )
        let package = try await relaunched.snapshotPackage()
        let health = await relaunched.health()

        XCTAssertEqual(package.records.count, 1)
        XCTAssertEqual(package.records.first?.event.code, .cleanShutdown)
        XCTAssertEqual(package.records.first?.timestamp, base.addingTimeInterval(1))
        XCTAssertLessThanOrEqual(
            health.maximumObservedAllocatedBytes,
            configuration.maximumPersistentBytes
        )
        XCTAssertLessThanOrEqual(
            health.allocatedBytes,
            configuration.maximumPersistentBytes
        )
    }

    func testLossLedgerExpiresOldDayWithoutErasingRecentPartialEvidence() async throws {
        let rootURL = temporaryDirectory(named: "loss-ledger-window")
        let day: TimeInterval = 24 * 60 * 60
        let seed: TimeInterval = 1_800_000_000
        let base = Date(
            timeIntervalSince1970: seed
                - seed.truncatingRemainder(dividingBy: day)
        )
        let configuration = DiagnosticStorageConfiguration(
            maximumPersistentBytes: 128 * 1024,
            eventSegmentCount: 2,
            eventSegmentPayloadBytes: 8 * 1024,
            maximumEventBytes: 2 * 1024,
            metricCacheBytes: 16 * 1024,
            maximumMetricPayloadBytes: 8,
            retentionInterval: 7 * day,
            maximumQueuedEvents: 16,
            maximumQueuedBytes: 16 * 1024
        )
        let oversizedJSON = Data(repeating: 0x41, count: 9)

        var oldRecorder: LocalDiagnosticRecorder? = try LocalDiagnosticRecorder(
            rootURL: rootURL,
            appIdentity: .testFixture,
            configuration: configuration,
            unifiedLoggingEnabled: false,
            now: { base }
        )
        cacheOversizedMetric(
            on: try XCTUnwrap(oldRecorder),
            rawJSON: oversizedJSON,
            receivedAt: base
        )
        await oldRecorder?.flush()
        oldRecorder = nil

        let recentAt = base.addingTimeInterval(6 * day + day / 2)
        var recentRecorder: LocalDiagnosticRecorder? = try LocalDiagnosticRecorder(
            rootURL: rootURL,
            appIdentity: .testFixture,
            configuration: configuration,
            unifiedLoggingEnabled: false,
            now: { recentAt }
        )
        cacheOversizedMetric(
            on: try XCTUnwrap(recentRecorder),
            rawJSON: oversizedJSON,
            receivedAt: recentAt
        )
        await recentRecorder?.flush()
        recentRecorder = nil

        let finalNow = base.addingTimeInterval(8 * day)
        let finalRecorder = try LocalDiagnosticRecorder(
            rootURL: rootURL,
            appIdentity: .testFixture,
            configuration: configuration,
            unifiedLoggingEnabled: false,
            now: { finalNow }
        )
        let package = try await finalRecorder.snapshotPackage()

        XCTAssertEqual(package.manifest.oversizedMetricPayloadCount, 1)
        XCTAssertTrue(package.manifest.collectionWasPartial)
        XCTAssertEqual(package.metricAttachments.count, 1)
        XCTAssertEqual(package.metricAttachments.first?.receivedAt, recentAt)
    }

    func testLossLedgerDropsPartialCutoffDayAndFutureBucketsFailClosed() async throws {
        let rootURL = temporaryDirectory(named: "loss-ledger-boundaries")
        let day: TimeInterval = 24 * 60 * 60
        let seed: TimeInterval = 1_800_000_000
        let utcDayStart = Date(
            timeIntervalSince1970: seed
                - seed.truncatingRemainder(dividingBy: day)
        )
        let cutoff = utcDayStart.addingTimeInterval(day / 2)
        let finalNow = cutoff.addingTimeInterval(7 * day)
        let configuration = DiagnosticStorageConfiguration(
            maximumPersistentBytes: 128 * 1024,
            eventSegmentCount: 2,
            eventSegmentPayloadBytes: 8 * 1024,
            maximumEventBytes: 2 * 1024,
            metricCacheBytes: 32 * 1024,
            maximumMetricPayloadBytes: 8,
            retentionInterval: 7 * day,
            maximumQueuedEvents: 16,
            maximumQueuedBytes: 16 * 1024
        )
        let oversizedJSON = Data(repeating: 0x41, count: 9)
        let boundaryTimes = [
            cutoff.addingTimeInterval(-1),
            cutoff.addingTimeInterval(1),
            utcDayStart.addingTimeInterval(day)
        ]

        var futureRecorder: LocalDiagnosticRecorder? = try LocalDiagnosticRecorder(
            rootURL: rootURL,
            appIdentity: .testFixture,
            configuration: configuration,
            unifiedLoggingEnabled: false,
            now: { finalNow.addingTimeInterval(day) }
        )
        cacheOversizedMetric(
            on: try XCTUnwrap(futureRecorder),
            rawJSON: oversizedJSON,
            receivedAt: finalNow.addingTimeInterval(day)
        )
        await futureRecorder?.flush()
        futureRecorder = nil

        for timestamp in boundaryTimes {
            var recorder: LocalDiagnosticRecorder? = try LocalDiagnosticRecorder(
                rootURL: rootURL,
                appIdentity: .testFixture,
                configuration: configuration,
                unifiedLoggingEnabled: false,
                now: { timestamp }
            )
            cacheOversizedMetric(
                on: try XCTUnwrap(recorder),
                rawJSON: oversizedJSON,
                receivedAt: timestamp
            )
            await recorder?.flush()
            recorder = nil
        }

        let finalRecorder = try LocalDiagnosticRecorder(
            rootURL: rootURL,
            appIdentity: .testFixture,
            configuration: configuration,
            unifiedLoggingEnabled: false,
            now: { finalNow }
        )
        let package = try await finalRecorder.snapshotPackage()

        XCTAssertEqual(package.manifest.oversizedMetricPayloadCount, 1)
        XCTAssertTrue(package.manifest.collectionWasPartial)
    }

    func testLossLedgerRejectsNonMidnightUTCDayStartInsteadOfNormalizingIt() async throws {
        let rootURL = temporaryDirectory(named: "loss-ledger-non-midnight")
        let day: TimeInterval = 24 * 60 * 60
        let seed: TimeInterval = 1_800_000_000
        let utcDayStart = Date(
            timeIntervalSince1970: seed
                - seed.truncatingRemainder(dividingBy: day)
        )
        let now = utcDayStart.addingTimeInterval(day / 2)
        let configuration = DiagnosticStorageConfiguration(
            maximumMetricPayloadBytes: 8
        )
        var recorder: LocalDiagnosticRecorder? = try LocalDiagnosticRecorder(
            rootURL: rootURL,
            appIdentity: .testFixture,
            configuration: configuration,
            unifiedLoggingEnabled: false,
            now: { now }
        )
        cacheOversizedMetric(
            on: try XCTUnwrap(recorder),
            rawJSON: Data(repeating: 0x41, count: 9),
            receivedAt: now
        )
        await recorder?.flush()
        recorder = nil

        let indexURL = rootURL.appendingPathComponent("index.json")
        var index = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: indexURL)
            ) as? [String: Any]
        )
        var buckets = try XCTUnwrap(
            index["lossBuckets"] as? [[String: Any]]
        )
        XCTAssertEqual(buckets.count, 1)
        buckets[0]["utcDayStart"] = try encodedDateValue(
            utcDayStart.addingTimeInterval(60)
        )
        index["lossBuckets"] = buckets
        try JSONSerialization.data(
            withJSONObject: index,
            options: [.sortedKeys]
        ).write(to: indexURL, options: .atomic)

        let relaunched = try LocalDiagnosticRecorder(
            rootURL: rootURL,
            appIdentity: .testFixture,
            configuration: configuration,
            unifiedLoggingEnabled: false,
            now: { now }
        )
        let package = try await relaunched.snapshotPackage()

        XCTAssertEqual(package.manifest.oversizedMetricPayloadCount, 0)
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

    private func cacheOversizedMetric(
        on recorder: LocalDiagnosticRecorder,
        rawJSON: Data,
        receivedAt: Date
    ) {
        recorder.cacheMetricKitPayload(
            MetricKitPayloadSummary(
                kind: .diagnostic,
                intervalStart: receivedAt,
                intervalEnd: receivedAt,
                crashCount: 0,
                hangCount: 0,
                cpuExceptionCount: 0,
                diskWriteExceptionCount: 0,
                rawJSONByteCount: rawJSON.count
            ),
            rawJSON: rawJSON,
            receivedAt: receivedAt
        )
    }

    private func encodedDateValue(_ date: Date) throws -> Any {
        try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(date),
            options: [.fragmentsAllowed]
        )
    }

    private func temporaryFile(named name: String) -> URL {
        let directory = temporaryDirectory(named: "export")
        return directory.appendingPathComponent(name)
    }
}

private final class RecorderInitializationThreadObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var storedWasMainThread: Bool?

    var wasMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return storedWasMainThread
    }

    func record(isMainThread: Bool) {
        lock.lock()
        storedWasMainThread = isMainThread
        lock.unlock()
    }
}
