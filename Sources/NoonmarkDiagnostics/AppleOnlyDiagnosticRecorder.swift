import Foundation

/// Fail-open recorder used when the bounded file sink cannot be initialised.
/// It preserves the same typed API and writes only allow-listed evidence to
/// Apple Unified Logging; it never owns or writes an application file.
public final class AppleOnlyDiagnosticRecorder: DiagnosticRecording, Sendable {
    public let sessionID: DiagnosticSessionID

    private let logger: AppleDiagnosticLogger

    public init(
        sessionID: DiagnosticSessionID = DiagnosticSessionID(),
        subsystem: String = Bundle.main.bundleIdentifier ?? "app.noonmark.mac"
    ) {
        self.sessionID = sessionID
        logger = AppleDiagnosticLogger(subsystem: subsystem)
    }

    public func record(_ event: EvidenceEvent, at timestamp: Date) {
        _ = timestamp
        logger.record(event)
    }
}
