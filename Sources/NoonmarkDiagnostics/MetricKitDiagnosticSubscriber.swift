import Foundation
import MetricKit

public enum MetricKitPayloadKind: String, Codable, CaseIterable, Sendable {
    case metric
    case diagnostic
}

public struct MetricKitPayloadSummary: Codable, Equatable, Sendable {
    public let kind: MetricKitPayloadKind
    public let intervalStart: Date
    public let intervalEnd: Date
    public let crashCount: Int
    public let hangCount: Int
    public let cpuExceptionCount: Int
    public let diskWriteExceptionCount: Int
    public let rawJSONByteCount: Int

    public init(
        kind: MetricKitPayloadKind,
        intervalStart: Date,
        intervalEnd: Date,
        crashCount: Int,
        hangCount: Int,
        cpuExceptionCount: Int,
        diskWriteExceptionCount: Int,
        rawJSONByteCount: Int
    ) {
        self.kind = kind
        self.intervalStart = intervalStart
        self.intervalEnd = max(intervalStart, intervalEnd)
        self.crashCount = max(0, crashCount)
        self.hangCount = max(0, hangCount)
        self.cpuExceptionCount = max(0, cpuExceptionCount)
        self.diskWriteExceptionCount = max(0, diskWriteExceptionCount)
        self.rawJSONByteCount = max(0, rawJSONByteCount)
    }
}

protocol MetricKitManaging: AnyObject {
    func add(_ subscriber: any MXMetricManagerSubscriber)
    func remove(_ subscriber: any MXMetricManagerSubscriber)
}

extension MXMetricManager: MetricKitManaging {}

struct MetricKitDiagnosticCounts: Equatable {
    let crash: Int
    let hang: Int
    let cpuException: Int
    let diskWriteException: Int
}

public final class MetricKitDiagnosticSubscriber: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    private let recorder: LocalDiagnosticRecorder
    private let manager: any MetricKitManaging
    private let now: @Sendable () -> Date
    private let stateLock = NSLock()
    private var isStarted = false

    public init(recorder: LocalDiagnosticRecorder) {
        self.recorder = recorder
        manager = MXMetricManager.shared
        now = { Date() }
        super.init()
    }

    init(
        recorder: LocalDiagnosticRecorder,
        manager: any MetricKitManaging,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.recorder = recorder
        self.manager = manager
        self.now = now
        super.init()
    }

    deinit {
        stop()
    }

    public func start() {
        stateLock.lock()
        guard isStarted == false else {
            stateLock.unlock()
            return
        }
        manager.add(self)
        isStarted = true
        stateLock.unlock()
    }

    public func stop() {
        stateLock.lock()
        guard isStarted else {
            stateLock.unlock()
            return
        }
        manager.remove(self)
        isStarted = false
        stateLock.unlock()
    }

    public func didReceive(_ payloads: [MXMetricPayload]) {
        let receivedAt = now()
        for payload in payloads {
            ingestMetricPayload(
                intervalStart: payload.timeStampBegin,
                intervalEnd: payload.timeStampEnd,
                rawJSON: payload.jsonRepresentation(),
                receivedAt: receivedAt
            )
        }
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let receivedAt = now()
        for payload in payloads {
            ingestDiagnosticPayload(
                intervalStart: payload.timeStampBegin,
                intervalEnd: payload.timeStampEnd,
                counts: MetricKitDiagnosticCounts(
                    crash: payload.crashDiagnostics?.count ?? 0,
                    hang: payload.hangDiagnostics?.count ?? 0,
                    cpuException:
                    payload.cpuExceptionDiagnostics?.count ?? 0,
                    diskWriteException:
                    payload.diskWriteExceptionDiagnostics?.count ?? 0
                ),
                rawJSON: payload.jsonRepresentation(),
                receivedAt: receivedAt
            )
        }
    }

    func ingestMetricPayload(
        intervalStart: Date,
        intervalEnd: Date,
        rawJSON: Data,
        receivedAt: Date
    ) {
        recorder.cacheMetricKitPayload(
            MetricKitPayloadSummary(
                kind: .metric,
                intervalStart: intervalStart,
                intervalEnd: intervalEnd,
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

    func ingestDiagnosticPayload(
        intervalStart: Date,
        intervalEnd: Date,
        counts: MetricKitDiagnosticCounts,
        rawJSON: Data,
        receivedAt: Date
    ) {
        recorder.cacheMetricKitPayload(
            MetricKitPayloadSummary(
                kind: .diagnostic,
                intervalStart: intervalStart,
                intervalEnd: intervalEnd,
                crashCount: counts.crash,
                hangCount: counts.hang,
                cpuExceptionCount: counts.cpuException,
                diskWriteExceptionCount: counts.diskWriteException,
                rawJSONByteCount: rawJSON.count
            ),
            rawJSON: rawJSON,
            receivedAt: receivedAt
        )
    }
}
