import MetricKit
@testable import NoonmarkDiagnostics
import XCTest

final class MetricKitDiagnosticSubscriberTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs = []
    }

    func testDiagnosticSummaryKeepsOnlySafeTypedCountsAndInterval() {
        let intervalStart = Date(timeIntervalSince1970: 1_800_000_000)
        let intervalEnd = intervalStart.addingTimeInterval(3600)

        let summary = MetricKitPayloadSummary(
            kind: .diagnostic,
            intervalStart: intervalStart,
            intervalEnd: intervalEnd,
            crashCount: 2,
            hangCount: 3,
            cpuExceptionCount: 4,
            diskWriteExceptionCount: 5,
            rawJSONByteCount: 6144
        )

        XCTAssertEqual(summary.kind, .diagnostic)
        XCTAssertEqual(summary.intervalStart, intervalStart)
        XCTAssertEqual(summary.intervalEnd, intervalEnd)
        XCTAssertEqual(summary.crashCount, 2)
        XCTAssertEqual(summary.hangCount, 3)
        XCTAssertEqual(summary.cpuExceptionCount, 4)
        XCTAssertEqual(summary.diskWriteExceptionCount, 5)
        XCTAssertEqual(summary.rawJSONByteCount, 6144)
    }

    func testSummaryNormalizesNegativeScalarsAndReversedInterval() {
        let intervalStart = Date(timeIntervalSince1970: 1_800_000_000)

        let summary = MetricKitPayloadSummary(
            kind: .diagnostic,
            intervalStart: intervalStart,
            intervalEnd: intervalStart.addingTimeInterval(-1),
            crashCount: -1,
            hangCount: -2,
            cpuExceptionCount: -3,
            diskWriteExceptionCount: -4,
            rawJSONByteCount: -5
        )

        XCTAssertEqual(summary.intervalEnd, intervalStart)
        XCTAssertEqual(summary.crashCount, 0)
        XCTAssertEqual(summary.hangCount, 0)
        XCTAssertEqual(summary.cpuExceptionCount, 0)
        XCTAssertEqual(summary.diskWriteExceptionCount, 0)
        XCTAssertEqual(summary.rawJSONByteCount, 0)
    }

    func testCacheRetainsSafeSummaryAndExactNumericJSON() async throws {
        let recorder = try makeRecorder(
            named: "raw",
            maximumMetricPayloadBytes: 1024
        )
        let rawJSON = Data(#"{"metrics":[{"count":7}]}"#.utf8)
        let summary = makeSummary(rawJSONByteCount: 1)

        recorder.cacheMetricKitPayload(
            summary,
            rawJSON: rawJSON,
            receivedAt: summary.intervalEnd
        )
        await recorder.flush()

        let package = try await recorder.snapshotPackage()
        let attachment = try XCTUnwrap(package.metricAttachments.first)
        XCTAssertEqual(attachment.summary.rawJSONByteCount, rawJSON.count)
        XCTAssertEqual(attachment.sanitizedJSON, rawJSON)
        XCTAssertEqual(attachment.redactionVersion, 1)
    }

    func testOversizedRawJSONIsDiscardedWholeButSummaryRemains() async throws {
        let recorder = try makeRecorder(
            named: "oversized",
            maximumMetricPayloadBytes: 32
        )
        let rawJSON = Data(repeating: 0x41, count: 33)
        let summary = makeSummary(rawJSONByteCount: rawJSON.count)

        recorder.cacheMetricKitPayload(
            summary,
            rawJSON: rawJSON,
            receivedAt: summary.intervalEnd
        )
        await recorder.flush()

        let package = try await recorder.snapshotPackage()
        let attachment = try XCTUnwrap(package.metricAttachments.first)
        XCTAssertEqual(attachment.summary, summary)
        XCTAssertNil(attachment.sanitizedJSON)
        XCTAssertEqual(package.manifest.oversizedMetricPayloadCount, 1)
    }

    func testMetricJSONRedactsArbitraryStringsBeforeDiskAndExport() async throws {
        let recorder = try makeRecorder(
            named: "privacy",
            maximumMetricPayloadBytes: 4096
        )
        let privateKey = "PRIVATE-TASK-TITLE-KEY-7Q9X"
        let privateUUID = "00000000-0000-0000-0000-000000000099"
        let canaries = [
            "PRIVATE-TASK-TITLE-7Q9X",
            "Bearer secret-access-token",
            "/Users/private-user/Documents/Noonmark.sqlite",
            "owner@example.invalid",
            "https://example.invalid/sync?token=private",
            privateKey,
            privateUUID
        ]
        let rawJSON = try JSONSerialization.data(
            withJSONObject: [
                "message": canaries.joined(separator: " "),
                privateKey: 42,
                "userUUID": privateUUID,
                "binaryName": "NoonmarkMacApp",
                "binaryUUID": "00000000-0000-0000-0000-000000000001",
                "sampleCount": 7
            ],
            options: [.sortedKeys]
        )
        let summary = makeSummary(rawJSONByteCount: rawJSON.count)

        recorder.cacheMetricKitPayload(
            summary,
            rawJSON: rawJSON,
            receivedAt: summary.intervalEnd
        )
        await recorder.flush()

        let package = try await recorder.snapshotPackage()
        let attachment = try XCTUnwrap(package.metricAttachments.first)
        let sanitizedJSON = try XCTUnwrap(attachment.sanitizedJSON)
        let exportedText = String(
            decoding: try JSONEncoder().encode(package),
            as: UTF8.self
        )
        let diskText = try diagnosticFileText(
            in: recorderRoot(named: "privacy")
        )
        for canary in canaries {
            XCTAssertFalse(String(decoding: sanitizedJSON, as: UTF8.self).contains(canary))
            XCTAssertFalse(exportedText.contains(canary))
            XCTAssertFalse(diskText.contains(canary))
        }
        XCTAssertTrue(
            String(decoding: sanitizedJSON, as: UTF8.self)
                .contains("NoonmarkMacApp")
        )
        XCTAssertTrue(
            String(decoding: sanitizedJSON, as: UTF8.self)
                .contains("00000000-0000-0000-0000-000000000001")
        )
    }

    func testSubscriptionLifecycleIsIdempotent() throws {
        let recorder = try makeRecorder(
            named: "subscription",
            maximumMetricPayloadBytes: 1024
        )
        let manager = MetricKitManagerSpy()
        let subscriber = MetricKitDiagnosticSubscriber(
            recorder: recorder,
            manager: manager
        )

        subscriber.start()
        subscriber.start()
        subscriber.stop()
        subscriber.stop()

        XCTAssertEqual(manager.addCount, 1)
        XCTAssertEqual(manager.removeCount, 1)
    }

    func testImplementsMetricKitCallbackSelectorsAvailableInCurrentSDK() throws {
        let subscriber = MetricKitDiagnosticSubscriber(
            recorder: try makeRecorder(
                named: "selectors",
                maximumMetricPayloadBytes: 1024
            ),
            manager: MetricKitManagerSpy()
        )

        #if compiler(>=6.2)
        XCTAssertTrue(
            subscriber.responds(
                to: NSSelectorFromString("didReceiveMetricPayloads:")
            )
        )
        #else
        XCTAssertFalse(
            subscriber.responds(
                to: NSSelectorFromString("didReceiveMetricPayloads:")
            )
        )
        #endif
        XCTAssertTrue(
            subscriber.responds(
                to: NSSelectorFromString("didReceiveDiagnosticPayloads:")
            )
        )
    }

    func testBothPayloadKindsBecomeTypedSummaries() async throws {
        let recorder = try makeRecorder(
            named: "callbacks",
            maximumMetricPayloadBytes: 1024
        )
        let subscriber = MetricKitDiagnosticSubscriber(
            recorder: recorder,
            manager: MetricKitManagerSpy()
        )
        let intervalStart = Date(timeIntervalSince1970: 1_800_000_000)
        let intervalEnd = intervalStart.addingTimeInterval(3600)
        let metricJSON = Data(#"{"metricCount":1}"#.utf8)
        let diagnosticJSON = Data(#"{"diagnosticCount":2}"#.utf8)

        subscriber.ingestMetricPayload(
            intervalStart: intervalStart,
            intervalEnd: intervalEnd,
            rawJSON: metricJSON,
            receivedAt: intervalEnd
        )
        subscriber.ingestDiagnosticPayload(
            intervalStart: intervalStart,
            intervalEnd: intervalEnd,
            counts: MetricKitDiagnosticCounts(
                crash: 1,
                hang: 2,
                cpuException: 3,
                diskWriteException: 4
            ),
            rawJSON: diagnosticJSON,
            receivedAt: intervalEnd.addingTimeInterval(1)
        )
        await recorder.flush()

        let attachments = try await recorder.snapshotPackage()
            .metricAttachments
        XCTAssertEqual(attachments.count, 2)
        XCTAssertEqual(
            attachments.map(\.summary.kind).sorted(by: {
                $0.rawValue < $1.rawValue
            }),
            [.diagnostic, .metric]
        )
        let diagnostic = try XCTUnwrap(
            attachments.first { $0.summary.kind == .diagnostic }
        )
        XCTAssertEqual(diagnostic.summary.crashCount, 1)
        XCTAssertEqual(diagnostic.summary.hangCount, 2)
        XCTAssertEqual(diagnostic.summary.cpuExceptionCount, 3)
        XCTAssertEqual(diagnostic.summary.diskWriteExceptionCount, 4)
        XCTAssertEqual(diagnostic.sanitizedJSON, diagnosticJSON)
        let metric = try XCTUnwrap(
            attachments.first { $0.summary.kind == .metric }
        )
        XCTAssertEqual(metric.summary.crashCount, 0)
        XCTAssertEqual(metric.summary.hangCount, 0)
        XCTAssertEqual(metric.summary.cpuExceptionCount, 0)
        XCTAssertEqual(metric.summary.diskWriteExceptionCount, 0)
        XCTAssertEqual(metric.sanitizedJSON, metricJSON)
    }

    private func makeRecorder(
        named name: String,
        maximumMetricPayloadBytes: Int
    ) throws -> LocalDiagnosticRecorder {
        let rootURL = recorderRoot(named: name)
        temporaryURLs.append(rootURL)
        return try LocalDiagnosticRecorder(
            rootURL: rootURL,
            appIdentity: .testFixture,
            configuration: DiagnosticStorageConfiguration(
                maximumPersistentBytes: 96 * 1024,
                eventSegmentCount: 2,
                eventSegmentPayloadBytes: 8 * 1024,
                maximumEventBytes: 2 * 1024,
                metricCacheBytes: 8 * 1024,
                maximumMetricPayloadBytes: maximumMetricPayloadBytes,
                maximumQueuedEvents: 16,
                maximumQueuedBytes: 8 * 1024
            ),
            unifiedLoggingEnabled: false,
            now: { Date(timeIntervalSince1970: 1_800_010_000) }
        )
    }

    private func recorderRoot(named name: String) -> URL {
        if let existing = temporaryURLs.first(where: {
            $0.lastPathComponent.hasPrefix("noonmark-metrickit-\(name)-")
        }) {
            return existing
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noonmark-metrickit-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
    }

    private func diagnosticFileText(in rootURL: URL) throws -> String {
        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        var data = Data()
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                data.append(try Data(contentsOf: url))
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func makeSummary(rawJSONByteCount: Int) -> MetricKitPayloadSummary {
        let intervalStart = Date(timeIntervalSince1970: 1_800_000_000)
        return MetricKitPayloadSummary(
            kind: .diagnostic,
            intervalStart: intervalStart,
            intervalEnd: intervalStart.addingTimeInterval(3600),
            crashCount: 1,
            hangCount: 2,
            cpuExceptionCount: 3,
            diskWriteExceptionCount: 4,
            rawJSONByteCount: rawJSONByteCount
        )
    }
}

private final class MetricKitManagerSpy: MetricKitManaging {
    private(set) var addCount = 0
    private(set) var removeCount = 0

    func add(_ subscriber: any MXMetricManagerSubscriber) {
        addCount += 1
    }

    func remove(_ subscriber: any MXMetricManagerSubscriber) {
        removeCount += 1
    }
}
