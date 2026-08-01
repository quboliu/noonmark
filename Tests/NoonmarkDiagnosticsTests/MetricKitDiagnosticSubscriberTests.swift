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

    func testCacheRetainsSafeSummaryAndExactRawJSON() async throws {
        let recorder = try makeRecorder(
            named: "raw",
            maximumMetricPayloadBytes: 1024
        )
        let rawJSON = Data(#"{"metrics":[{"private":"opaque"}]}"#.utf8)
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
        XCTAssertEqual(attachment.rawJSON, rawJSON)
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
        XCTAssertNil(attachment.rawJSON)
        XCTAssertEqual(package.manifest.oversizedMetricPayloadCount, 1)
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

    func testImplementsBothMetricKitCallbackSelectors() throws {
        let subscriber = MetricKitDiagnosticSubscriber(
            recorder: try makeRecorder(
                named: "selectors",
                maximumMetricPayloadBytes: 1024
            ),
            manager: MetricKitManagerSpy()
        )

        XCTAssertTrue(
            subscriber.responds(
                to: NSSelectorFromString("didReceiveMetricPayloads:")
            )
        )
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
        let metricJSON = Data(#"{"privateMetric":"opaque"}"#.utf8)
        let diagnosticJSON = Data(#"{"privateDiagnostic":"opaque"}"#.utf8)

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
        XCTAssertEqual(diagnostic.rawJSON, diagnosticJSON)
        let metric = try XCTUnwrap(
            attachments.first { $0.summary.kind == .metric }
        )
        XCTAssertEqual(metric.summary.crashCount, 0)
        XCTAssertEqual(metric.summary.hangCount, 0)
        XCTAssertEqual(metric.summary.cpuExceptionCount, 0)
        XCTAssertEqual(metric.summary.diskWriteExceptionCount, 0)
        XCTAssertEqual(metric.rawJSON, metricJSON)
    }

    private func makeRecorder(
        named name: String,
        maximumMetricPayloadBytes: Int
    ) throws -> LocalDiagnosticRecorder {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noonmark-metrickit-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
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
            )
        )
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
