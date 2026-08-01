@testable import NoonmarkDiagnostics
import XCTest

private let metricExportFixtureNow = Date(timeIntervalSince1970: 1_800_010_000)

final class MetricKitExportEnvelopeTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs = []
    }

    func testSnapshotRebuildsTamperedMetricJSONThroughCurrentFixedSchema() async throws {
        let (recorder, rootURL) = try makeRecorder(named: "tampered-envelope")
        let summary = makeSummary(kind: .metric)
        recorder.cacheMetricKitPayload(
            summary,
            rawJSON: Data(#"{"sampleCount":7}"#.utf8),
            receivedAt: summary.intervalEnd
        )
        await recorder.flush()

        let metricURL = try XCTUnwrap(try metricURLs(in: rootURL).first)
        var envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: metricURL)
            ) as? [String: Any]
        )
        let canary = "PRIVATE-CANARY-METRIC-ENVELOPE-7Q9X"
        let tamperedJSON = try JSONSerialization.data(
            withJSONObject: [
                "binaryName": "NoonmarkMacApp",
                "sampleCount": canary,
                "unknownField": canary
            ],
            options: [.sortedKeys]
        )
        envelope["sanitizedJSON"] = tamperedJSON.base64EncodedString()
        try JSONSerialization.data(
            withJSONObject: envelope,
            options: [.sortedKeys]
        ).write(to: metricURL, options: .atomic)

        let snapshot = try await recorder.snapshotPackage()
        let snapshotAttachment = try XCTUnwrap(
            snapshot.metricAttachments.first
        )
        try assertDefensivelySanitized(
            snapshotAttachment,
            excludes: canary
        )

        let exportURL = rootURL
            .deletingLastPathComponent()
            .appendingPathComponent("tampered.noonmarkdiagnostics")
        temporaryURLs.append(exportURL)
        _ = try await recorder.export(to: exportURL)
        let exported = try JSONDecoder().decode(
            DiagnosticExportPackage.self,
            from: Data(contentsOf: exportURL)
        )
        try assertDefensivelySanitized(
            XCTUnwrap(exported.metricAttachments.first),
            excludes: canary
        )
    }

    func testSnapshotCountsCorruptMetricEnvelopeAndKeepsValidMetric() async throws {
        let (recorder, rootURL) = try makeRecorder(named: "corrupt-envelope")
        let validSummary = makeSummary(kind: .diagnostic)
        recorder.cacheMetricKitPayload(
            validSummary,
            rawJSON: Data(#"{"diagnosticCount":2}"#.utf8),
            receivedAt: validSummary.intervalEnd
        )
        await recorder.flush()

        let metricsDirectory = rootURL.appendingPathComponent(
            "metrics",
            isDirectory: true
        )
        let corruptURL = metricsDirectory.appendingPathComponent(
            "metric-corrupt.json"
        )
        try Data("{corrupt-metric-envelope}".utf8).write(
            to: corruptURL
        )
        try FileManager.default.setAttributes(
            [.modificationDate: metricExportFixtureNow],
            ofItemAtPath: corruptURL.path
        )

        let snapshot = try await recorder.snapshotPackage()

        XCTAssertEqual(snapshot.metricAttachments.count, 1)
        XCTAssertEqual(snapshot.metricAttachments.first?.summary, validSummary)
        XCTAssertEqual(snapshot.manifest.metricPayloadCount, 1)
        XCTAssertEqual(snapshot.manifest.corruptRecordCount, 1)
        XCTAssertTrue(snapshot.manifest.collectionWasPartial)

        let repeatedSnapshot = try await recorder.snapshotPackage()
        XCTAssertEqual(repeatedSnapshot.metricAttachments.count, 1)
        XCTAssertEqual(repeatedSnapshot.manifest.corruptRecordCount, 1)
    }

    func testCorruptMetricRetentionKeepsCutoffInclusiveAndExpiresOneSecondEarlier() async throws {
        let now = Date(timeIntervalSince1970: 1_800_604_800)
        let cutoff = now.addingTimeInterval(-(7 * 24 * 60 * 60))
        let (recorder, rootURL) = try makeRecorder(
            named: "corrupt-retention-boundary",
            now: now
        )
        let validSummary = makeSummary(kind: .metric)
        recorder.cacheMetricKitPayload(
            validSummary,
            rawJSON: Data(#"{"metricCount":1}"#.utf8),
            receivedAt: validSummary.intervalEnd
        )
        await recorder.flush()

        let metricsDirectory = rootURL.appendingPathComponent(
            "metrics",
            isDirectory: true
        )
        let cutoffURL = metricsDirectory.appendingPathComponent(
            "metric-corrupt-at-cutoff.json"
        )
        let expiredURL = metricsDirectory.appendingPathComponent(
            "metric-corrupt-before-cutoff.json"
        )
        try Data("{corrupt-at-cutoff}".utf8).write(to: cutoffURL)
        try Data("{corrupt-before-cutoff}".utf8).write(to: expiredURL)
        try FileManager.default.setAttributes(
            [.modificationDate: cutoff],
            ofItemAtPath: cutoffURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: cutoff.addingTimeInterval(-1)],
            ofItemAtPath: expiredURL.path
        )

        let snapshot = try await recorder.snapshotPackage()

        XCTAssertEqual(snapshot.metricAttachments.count, 1)
        XCTAssertEqual(snapshot.manifest.corruptRecordCount, 1)
        XCTAssertTrue(snapshot.manifest.collectionWasPartial)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cutoffURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: expiredURL.path))
    }

    func testSnapshotRejectsTamperedMetricSummaryDatesCountsAndByteCount() async throws {
        let (recorder, rootURL) = try makeRecorder(named: "tampered-summary")
        for _ in 0 ..< 4 {
            let summary = makeSummary(kind: .diagnostic)
            recorder.cacheMetricKitPayload(
                summary,
                rawJSON: Data(#"{"diagnosticCount":2}"#.utf8),
                receivedAt: summary.intervalEnd
            )
        }
        await recorder.flush()

        let urls = try metricURLs(in: rootURL).sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
        XCTAssertEqual(urls.count, 4)
        try mutateSummary(at: urls[0]) { summary in
            let intervalEnd = try XCTUnwrap(
                summary["intervalEnd"] as? NSNumber
            )
            summary["intervalStart"] = intervalEnd.doubleValue + 1
        }
        try mutateSummary(at: urls[1]) { summary in
            summary["crashCount"] = -1
        }
        try mutateSummary(at: urls[2]) { summary in
            summary["hangCount"] = 1_000_000_001
        }
        try mutateSummary(at: urls[3]) { summary in
            summary["rawJSONByteCount"] = 1_073_741_825
        }
        for url in urls {
            try FileManager.default.setAttributes(
                [.modificationDate: metricExportFixtureNow],
                ofItemAtPath: url.path
            )
        }

        let snapshot = try await recorder.snapshotPackage()

        XCTAssertTrue(snapshot.metricAttachments.isEmpty)
        XCTAssertEqual(snapshot.manifest.corruptRecordCount, 4)
        XCTAssertTrue(snapshot.manifest.collectionWasPartial)
    }

    func testSnapshotRejectsFutureTimeAndCountsBackdatedInvalidFieldsByFileTime() async throws {
        let now = metricExportFixtureNow
        let cutoff = now.addingTimeInterval(-(7 * 24 * 60 * 60))
        let (recorder, rootURL) = try makeRecorder(
            named: "tampered-time",
            now: now
        )
        for _ in 0 ..< 2 {
            let summary = makeSummary(kind: .diagnostic)
            recorder.cacheMetricKitPayload(
                summary,
                rawJSON: Data(#"{"diagnosticCount":2}"#.utf8),
                receivedAt: summary.intervalEnd
            )
        }
        await recorder.flush()

        let urls = try metricURLs(in: rootURL).sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
        XCTAssertEqual(urls.count, 2)
        try mutateEnvelope(at: urls[0]) { envelope in
            envelope["receivedAt"] = try encodedDateValue(
                now.addingTimeInterval(301)
            )
        }
        try mutateEnvelope(at: urls[1]) { envelope in
            envelope["receivedAt"] = try encodedDateValue(
                cutoff.addingTimeInterval(-1)
            )
            var summary = try XCTUnwrap(
                envelope["summary"] as? [String: Any]
            )
            summary["crashCount"] = -1
            envelope["summary"] = summary
        }
        for url in urls {
            try FileManager.default.setAttributes(
                [.modificationDate: now],
                ofItemAtPath: url.path
            )
        }

        let snapshot = try await recorder.snapshotPackage()

        XCTAssertTrue(snapshot.metricAttachments.isEmpty)
        XCTAssertEqual(snapshot.manifest.corruptRecordCount, 2)
        XCTAssertTrue(snapshot.manifest.collectionWasPartial)
    }

    func testCorruptMetricRemovalFailureIsCurrentEvidenceNotRepeatedHistoricalLoss() async throws {
        let (recorder, rootURL) = try makeRecorder(
            named: "corrupt-removal-failure"
        )
        let validSummary = makeSummary(kind: .metric)
        recorder.cacheMetricKitPayload(
            validSummary,
            rawJSON: Data(#"{"metricCount":1}"#.utf8),
            receivedAt: validSummary.intervalEnd
        )
        await recorder.flush()

        let metricsDirectory = rootURL.appendingPathComponent(
            "metrics",
            isDirectory: true
        )
        let corruptURL = metricsDirectory.appendingPathComponent(
            "metric-corrupt-read-only.json"
        )
        try Data("{corrupt-read-only}".utf8).write(to: corruptURL)
        try FileManager.default.setAttributes(
            [.modificationDate: metricExportFixtureNow],
            ofItemAtPath: corruptURL.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: metricsDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: metricsDirectory.path
            )
        }

        let first = try await recorder.snapshotPackage()
        let second = try await recorder.snapshotPackage()

        XCTAssertEqual(first.manifest.corruptRecordCount, 1)
        XCTAssertEqual(second.manifest.corruptRecordCount, 1)
        XCTAssertTrue(first.manifest.collectionWasPartial)
        XCTAssertTrue(second.manifest.collectionWasPartial)
        XCTAssertTrue(FileManager.default.fileExists(atPath: corruptURL.path))
        let failedRemovalHealth = await recorder.health()
        XCTAssertTrue(failedRemovalHealth.fileSinkDisabled)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: metricsDirectory.path
        )
        let recovered = try await recorder.snapshotPackage()
        XCTAssertEqual(recovered.manifest.corruptRecordCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptURL.path))
    }

    func testSnapshotNeverFollowsMetricSymlinkOutsideDiagnosticRoot() async throws {
        let now = Date()
        let (recorder, rootURL) = try makeRecorder(
            named: "symlink",
            now: now
        )
        for kind in [MetricKitPayloadKind.metric, .diagnostic] {
            let summary = makeSummary(kind: kind, endingAt: now)
            recorder.cacheMetricKitPayload(
                summary,
                rawJSON: Data(#"{"sampleCount":7}"#.utf8),
                receivedAt: summary.intervalEnd
            )
        }
        await recorder.flush()

        let metricURLs = try metricURLs(in: rootURL).sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
        XCTAssertEqual(metricURLs.count, 2)
        let symlinkURL = metricURLs[0]
        let outsideURL = rootURL.deletingLastPathComponent()
            .appendingPathComponent(
                "outside-metric-\(UUID().uuidString).json"
            )
        temporaryURLs.append(outsideURL)
        try FileManager.default.copyItem(at: symlinkURL, to: outsideURL)
        let canary = "PRIVATE-CANARY-OUTSIDE-SYMLINK-7Q9X"
        try mutateEnvelope(at: outsideURL) { envelope in
            envelope["sanitizedJSON"] = try JSONSerialization.data(
                withJSONObject: ["sampleCount": canary],
                options: [.sortedKeys]
            ).base64EncodedString()
        }
        try FileManager.default.removeItem(at: symlinkURL)
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: outsideURL
        )

        let snapshot = try await recorder.snapshotPackage()

        XCTAssertEqual(snapshot.metricAttachments.count, 1)
        XCTAssertEqual(snapshot.manifest.corruptRecordCount, 1)
        XCTAssertTrue(snapshot.manifest.collectionWasPartial)
        XCTAssertFalse(FileManager.default.fileExists(atPath: symlinkURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideURL.path))
        for attachment in snapshot.metricAttachments {
            let sanitizedJSON = try XCTUnwrap(attachment.sanitizedJSON)
            let sanitizedText = try XCTUnwrap(
                String(data: sanitizedJSON, encoding: .utf8)
            )
            XCTAssertFalse(
                sanitizedText.contains(canary)
            )
        }
    }

    func testMetricsDirectorySymlinkNeverEscapesDiagnosticOwnershipBoundary() async throws {
        let (recorder, rootURL) = try makeRecorder(
            named: "metrics-directory-symlink"
        )
        let externalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noonmark-external-metrics-\(UUID().uuidString)",
                isDirectory: true
            )
        temporaryURLs.append(externalURL)
        try FileManager.default.createDirectory(
            at: externalURL,
            withIntermediateDirectories: true
        )
        let canaryURL = externalURL.appendingPathComponent(
            "metric-external-canary.json"
        )
        let canary = Data("PRIVATE-EXTERNAL-METRICS-CANARY".utf8)
        try canary.write(to: canaryURL)
        try FileManager.default.setAttributes(
            [.modificationDate: metricExportFixtureNow],
            ofItemAtPath: canaryURL.path
        )
        let metricsURL = rootURL.appendingPathComponent(
            "metrics",
            isDirectory: true
        )
        func installMetricsSymlink() throws {
            try FileManager.default.createSymbolicLink(
                at: metricsURL,
                withDestinationURL: externalURL
            )
        }
        func assertExternalCanaryUnchanged() throws {
            XCTAssertEqual(try Data(contentsOf: canaryURL), canary)
        }

        try installMetricsSymlink()
        let snapshot = try await recorder.snapshotPackage()
        XCTAssertTrue(snapshot.metricAttachments.isEmpty)
        XCTAssertEqual(snapshot.manifest.corruptRecordCount, 1)
        XCTAssertTrue(snapshot.manifest.collectionWasPartial)
        try assertExternalCanaryUnchanged()
        XCTAssertFalse(FileManager.default.fileExists(atPath: metricsURL.path))

        try installMetricsSymlink()
        _ = try await recorder.preview()
        try assertExternalCanaryUnchanged()

        try installMetricsSymlink()
        let exportURL = rootURL.deletingLastPathComponent()
            .appendingPathComponent(
                "metrics-directory-symlink.noonmarkdiagnostics"
            )
        temporaryURLs.append(exportURL)
        _ = try await recorder.export(to: exportURL)
        try assertExternalCanaryUnchanged()

        try installMetricsSymlink()
        try await recorder.clear()
        try assertExternalCanaryUnchanged()
        XCTAssertFalse(FileManager.default.fileExists(atPath: metricsURL.path))
    }

    func testRuntimeMetricsDirectoryReplacementNeverRedirectsManagedIO() async throws {
        let (recorder, rootURL) = try makeRecorder(
            named: "metrics-directory-runtime-replacement"
        )
        let summary = makeSummary(kind: .metric)
        recorder.cacheMetricKitPayload(
            summary,
            rawJSON: Data(#"{"metricCount":1}"#.utf8),
            receivedAt: summary.intervalEnd
        )
        await recorder.flush()
        _ = try await recorder.snapshotPackage()

        let templateMetricURL = try XCTUnwrap(
            try metricURLs(in: rootURL).first
        )

        let metricsURL = rootURL.appendingPathComponent(
            "metrics",
            isDirectory: true
        )
        let displacedMetricsURL = rootURL.appendingPathComponent(
            "displaced-metrics",
            isDirectory: true
        )
        let replacementURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noonmark-replacement-metrics-\(UUID().uuidString)",
                isDirectory: true
            )
        temporaryURLs.append(replacementURL)
        try FileManager.default.createDirectory(
            at: replacementURL,
            withIntermediateDirectories: true
        )
        let canary = "EXTERNAL-RUNTIME-METRIC-\(UUID().uuidString)"
        let replacementCanaryURL = replacementURL.appendingPathComponent(
            "metric-\(UUID().uuidString).json"
        )
        try FileManager.default.copyItem(
            at: templateMetricURL,
            to: replacementCanaryURL
        )
        try mutateEnvelope(at: replacementCanaryURL) { envelope in
            envelope["sanitizedJSON"] = try JSONSerialization.data(
                withJSONObject: ["binaryName": canary],
                options: [.sortedKeys]
            ).base64EncodedString()
        }
        try FileManager.default.moveItem(
            at: metricsURL,
            to: displacedMetricsURL
        )
        try FileManager.default.moveItem(at: replacementURL, to: metricsURL)
        let installedCanaryURL = metricsURL.appendingPathComponent(
            replacementCanaryURL.lastPathComponent
        )
        let canaryFingerprint = try DiagnosticFileFingerprint(
            at: installedCanaryURL
        )

        recorder.cacheMetricKitPayload(
            summary,
            rawJSON: Data(#"{"metricCount":2}"#.utf8),
            receivedAt: summary.intervalEnd
        )
        await recorder.flush()
        try XCTAssertDiagnosticFileUnchanged(
            at: installedCanaryURL,
            from: canaryFingerprint,
            "external metric changed after flush"
        )

        let snapshot = try await recorder.snapshotPackage()
        XCTAssertFalse(package(snapshot, containsSanitizedMetricToken: canary))
        try XCTAssertDiagnosticFileUnchanged(
            at: installedCanaryURL,
            from: canaryFingerprint,
            "external metric changed after snapshot"
        )

        let exportURL = rootURL.deletingLastPathComponent()
            .appendingPathComponent(
                "metrics-runtime-replacement.noonmarkdiagnostics"
            )
        temporaryURLs.append(exportURL)
        _ = try await recorder.export(to: exportURL)
        let exported = try JSONDecoder().decode(
            DiagnosticExportPackage.self,
            from: Data(contentsOf: exportURL)
        )
        XCTAssertFalse(package(exported, containsSanitizedMetricToken: canary))
        try XCTAssertDiagnosticFileUnchanged(
            at: installedCanaryURL,
            from: canaryFingerprint,
            "external metric changed after export"
        )

        try await recorder.clear()
        try XCTAssertDiagnosticFileUnchanged(
            at: installedCanaryURL,
            from: canaryFingerprint,
            "external metric changed after clear"
        )
    }

    func testSnapshotRejectsMetricHardLinkWithoutReadingOrMutatingExternalTarget() async throws {
        let (recorder, rootURL) = try makeRecorder(named: "metric-hard-link")
        let summary = makeSummary(kind: .metric)
        recorder.cacheMetricKitPayload(
            summary,
            rawJSON: Data(#"{"metricCount":1}"#.utf8),
            receivedAt: summary.intervalEnd
        )
        await recorder.flush()

        let templateMetricURL = try XCTUnwrap(
            try metricURLs(in: rootURL).first
        )
        let externalURL = rootURL.deletingLastPathComponent()
            .appendingPathComponent(
                "external-hard-link-target-\(UUID().uuidString).json"
            )
        temporaryURLs.append(externalURL)
        try FileManager.default.copyItem(at: templateMetricURL, to: externalURL)
        let canary = "EXTERNAL-HARD-LINK-\(UUID().uuidString)"
        try mutateEnvelope(at: externalURL) { envelope in
            envelope["sanitizedJSON"] = try JSONSerialization.data(
                withJSONObject: ["binaryName": canary],
                options: [.sortedKeys]
            ).base64EncodedString()
        }
        try FileManager.default.setAttributes(
            [.modificationDate: metricExportFixtureNow],
            ofItemAtPath: externalURL.path
        )
        let hardLinkURL = rootURL
            .appendingPathComponent("metrics", isDirectory: true)
            .appendingPathComponent("metric-\(UUID().uuidString).json")
        try FileManager.default.linkItem(at: externalURL, to: hardLinkURL)
        let externalFingerprint = try DiagnosticFileFingerprint(at: externalURL)

        let snapshot = try await recorder.snapshotPackage()

        XCTAssertEqual(snapshot.metricAttachments.count, 1)
        XCTAssertEqual(snapshot.manifest.corruptRecordCount, 1)
        XCTAssertTrue(snapshot.manifest.collectionWasPartial)
        XCTAssertFalse(package(snapshot, containsSanitizedMetricToken: canary))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hardLinkURL.path))
        try XCTAssertDiagnosticFileUnchanged(
            at: externalURL,
            from: externalFingerprint
        )
    }

    func testSnapshotRejectsMetricFIFOWithoutBlocking() async throws {
        let (recorder, rootURL) = try makeRecorder(named: "metric-fifo")
        let summary = makeSummary(kind: .metric)
        recorder.cacheMetricKitPayload(
            summary,
            rawJSON: Data(#"{"metricCount":1}"#.utf8),
            receivedAt: summary.intervalEnd
        )
        await recorder.flush()

        let fifoURL = rootURL
            .appendingPathComponent("metrics", isDirectory: true)
            .appendingPathComponent("metric-\(UUID().uuidString).json")
        try createDiagnosticFIFO(at: fifoURL)
        try FileManager.default.setAttributes(
            [.modificationDate: metricExportFixtureNow],
            ofItemAtPath: fifoURL.path
        )

        let snapshot = try await recorder.snapshotPackage()

        XCTAssertEqual(snapshot.metricAttachments.count, 1)
        XCTAssertEqual(snapshot.manifest.corruptRecordCount, 1)
        XCTAssertTrue(snapshot.manifest.collectionWasPartial)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fifoURL.path))
    }

    func testMetricReaderRejectsFileReplacedAfterIdentityCapture() async throws {
        let (recorder, rootURL) = try makeRecorder(
            named: "metric-file-identity-replacement"
        )
        let summary = makeSummary(kind: .metric)
        recorder.cacheMetricKitPayload(
            summary,
            rawJSON: Data(#"{"metricCount":1}"#.utf8),
            receivedAt: summary.intervalEnd
        )
        await recorder.flush()

        let metricURL = try XCTUnwrap(try metricURLs(in: rootURL).first)
        let parkedURL = metricURL.deletingLastPathComponent()
            .appendingPathComponent("parked-original.json")
        let replacementURL = metricURL.deletingLastPathComponent()
            .appendingPathComponent("prepared-replacement.json")
        try FileManager.default.copyItem(at: metricURL, to: replacementURL)
        let canary = "REPLACED-AFTER-IDENTITY-\(UUID().uuidString)"
        try mutateEnvelope(at: replacementURL) { envelope in
            envelope["sanitizedJSON"] = try JSONSerialization.data(
                withJSONObject: ["binaryName": canary],
                options: [.sortedKeys]
            ).base64EncodedString()
        }
        let metricsDirectory = try XCTUnwrap(
            try DiagnosticOwnedDirectory.openRoot(
                at: metricURL.deletingLastPathComponent(),
                permissions: 0o700,
                fileManager: .default
            )
        )
        var didSwap = false

        let result = MetricKitExportEnvelopeReader.read(
            from: [metricURL.lastPathComponent],
            in: metricsDirectory,
            policy: MetricKitExportEnvelopeReadPolicy(
                cutoff: metricExportFixtureNow.addingTimeInterval(-3600),
                now: metricExportFixtureNow,
                maximumStoredEnvelopeBytes: 8 * 1024,
                maximumSanitizedJSONBytes: 4 * 1024
            ),
            identityCapturedHook: {
                guard didSwap == false else { return }
                didSwap = true
                try FileManager.default.moveItem(at: metricURL, to: parkedURL)
                try FileManager.default.moveItem(
                    at: replacementURL,
                    to: metricURL
                )
            }
        )

        XCTAssertTrue(didSwap)
        XCTAssertTrue(result.attachments.isEmpty)
        XCTAssertEqual(result.exclusions.count, 1)
        XCTAssertFalse(
            result.attachments.contains { attachment in
                guard let data = attachment.sanitizedJSON,
                      let text = String(data: data, encoding: .utf8)
                else { return false }
                return text.contains(canary)
            }
        )
    }

    func testFirstMetricAccessNeverAdoptsRuntimeReplacementDirectory() async throws {
        let (recorder, rootURL) = try makeRecorder(
            named: "first-metric-access-directory-replacement"
        )
        let metricsURL = rootURL.appendingPathComponent(
            "metrics",
            isDirectory: true
        )
        if FileManager.default.fileExists(atPath: metricsURL.path) == false {
            try FileManager.default.createDirectory(
                at: metricsURL,
                withIntermediateDirectories: false
            )
        }
        let displacedURL = rootURL.appendingPathComponent(
            "displaced-empty-metrics",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: metricsURL, to: displacedURL)
        let replacementURL = rootURL.appendingPathComponent(
            "prepared-external-metrics",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: replacementURL,
            withIntermediateDirectories: false
        )
        let canary = "FIRST-ACCESS-EXTERNAL-\(UUID().uuidString)"
        let canaryURL = replacementURL.appendingPathComponent(
            "metric-\(UUID().uuidString).json"
        )
        let sanitizedJSON = try JSONSerialization.data(
            withJSONObject: ["binaryName": canary],
            options: [.sortedKeys]
        )
        let stored = MetricKitStoredPayload(
            receivedAt: metricExportFixtureNow,
            summary: makeSummary(kind: .metric),
            sanitizedJSON: sanitizedJSON,
            redactionVersion: MetricKitJSONSanitizer.redactionVersion
        )
        try JSONEncoder().encode(stored).write(to: canaryURL)
        try FileManager.default.moveItem(at: replacementURL, to: metricsURL)
        let installedCanaryURL = metricsURL.appendingPathComponent(
            canaryURL.lastPathComponent
        )
        let fingerprint = try DiagnosticFileFingerprint(at: installedCanaryURL)

        let snapshot = try await recorder.snapshotPackage()
        XCTAssertFalse(package(snapshot, containsSanitizedMetricToken: canary))
        try XCTAssertDiagnosticFileUnchanged(
            at: installedCanaryURL,
            from: fingerprint,
            "external metric changed after first snapshot"
        )

        let exportURL = rootURL.deletingLastPathComponent()
            .appendingPathComponent(
                "first-access-replacement.noonmarkdiagnostics"
            )
        temporaryURLs.append(exportURL)
        _ = try await recorder.export(to: exportURL)
        let exported = try JSONDecoder().decode(
            DiagnosticExportPackage.self,
            from: Data(contentsOf: exportURL)
        )
        XCTAssertFalse(package(exported, containsSanitizedMetricToken: canary))
        try XCTAssertDiagnosticFileUnchanged(
            at: installedCanaryURL,
            from: fingerprint,
            "external metric changed after export"
        )

        try await recorder.clear()
        try XCTAssertDiagnosticFileUnchanged(
            at: installedCanaryURL,
            from: fingerprint,
            "external metric changed after clear"
        )
    }

    private func package(
        _ package: DiagnosticExportPackage,
        containsSanitizedMetricToken token: String
    ) -> Bool {
        package.metricAttachments.contains { attachment in
            guard let data = attachment.sanitizedJSON,
                  let text = String(data: data, encoding: .utf8)
            else { return false }
            return text.contains(token)
        }
    }

    private func assertDefensivelySanitized(
        _ attachment: DiagnosticMetricAttachment,
        excludes canary: String
    ) throws {
        let data = try XCTUnwrap(attachment.sanitizedJSON)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains(canary))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["binaryName"] as? String, "NoonmarkMacApp")
        XCTAssertEqual(object["sampleCount"] as? String, "<redacted>")
        XCTAssertNil(object["unknownField"])
        XCTAssertEqual(
            attachment.redactionVersion,
            DiagnosticSchemaVersion.metricRedaction
        )
    }

    private func mutateSummary(
        at url: URL,
        mutation: (inout [String: Any]) throws -> Void
    ) throws {
        try mutateEnvelope(at: url) { envelope in
            var summary = try XCTUnwrap(
                envelope["summary"] as? [String: Any]
            )
            try mutation(&summary)
            envelope["summary"] = summary
        }
    }

    private func mutateEnvelope(
        at url: URL,
        mutation: (inout [String: Any]) throws -> Void
    ) throws {
        var envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: url)
            ) as? [String: Any]
        )
        try mutation(&envelope)
        try JSONSerialization.data(
            withJSONObject: envelope,
            options: [.sortedKeys]
        ).write(to: url, options: .atomic)
    }

    private func encodedDateValue(_ date: Date) throws -> Any {
        try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(date),
            options: [.fragmentsAllowed]
        )
    }

    private func makeRecorder(
        named name: String,
        now: Date = metricExportFixtureNow
    ) throws -> (LocalDiagnosticRecorder, URL) {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noonmark-metric-export-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
        temporaryURLs.append(rootURL)
        let recorder = try LocalDiagnosticRecorder(
            rootURL: rootURL,
            appIdentity: .testFixture,
            configuration: DiagnosticStorageConfiguration(
                maximumPersistentBytes: 96 * 1024,
                eventSegmentCount: 2,
                eventSegmentPayloadBytes: 8 * 1024,
                maximumEventBytes: 2 * 1024,
                metricCacheBytes: 8 * 1024,
                maximumMetricPayloadBytes: 4 * 1024,
                maximumQueuedEvents: 16,
                maximumQueuedBytes: 8 * 1024
            ),
            unifiedLoggingEnabled: false,
            now: { now }
        )
        return (recorder, rootURL)
    }

    private func metricURLs(in rootURL: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: rootURL.appendingPathComponent("metrics", isDirectory: true),
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("metric-")
                && $0.pathExtension == "json"
        }
    }

    private func makeSummary(
        kind: MetricKitPayloadKind,
        endingAt intervalEnd: Date = metricExportFixtureNow
    ) -> MetricKitPayloadSummary {
        return MetricKitPayloadSummary(
            kind: kind,
            intervalStart: intervalEnd.addingTimeInterval(-3600),
            intervalEnd: intervalEnd,
            crashCount: kind == .diagnostic ? 1 : 0,
            hangCount: kind == .diagnostic ? 2 : 0,
            cpuExceptionCount: kind == .diagnostic ? 3 : 0,
            diskWriteExceptionCount: kind == .diagnostic ? 4 : 0,
            rawJSONByteCount: kind == .diagnostic ? 21 : 17
        )
    }
}
