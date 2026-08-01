import Foundation
import OSLog

struct AppleDiagnosticLogger {
    private let lifecycle: Logger
    private let mutation: Logger
    private let persistence: Logger
    private let sync: Logger
    private let transport: Logger
    private let diagnostics: Logger

    init(subsystem: String = DiagnosticSubsystemIdentity.current) {
        lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
        mutation = Logger(subsystem: subsystem, category: "mutation")
        persistence = Logger(subsystem: subsystem, category: "persistence")
        sync = Logger(subsystem: subsystem, category: "sync")
        transport = Logger(subsystem: subsystem, category: "transport")
        diagnostics = Logger(subsystem: subsystem, category: "diagnostics")
    }

    func record(_ event: EvidenceEvent) {
        let message = DiagnosticUnifiedLogMessage.render(event)
        logger(for: event.category).log(
            level: event.severity.osLogType,
            "\(message, privacy: .public)"
        )
    }

    private func logger(for category: DiagnosticCategory) -> Logger {
        switch category {
        case .lifecycle:
            lifecycle
        case .mutation:
            mutation
        case .persistence:
            persistence
        case .sync:
            sync
        case .transport:
            transport
        case .diagnostics:
            diagnostics
        }
    }
}

enum DiagnosticUnifiedLogMessage {
    static func render(_ event: EvidenceEvent) -> String {
        var fields = ["event=\(event.code.rawValue)"]
        append("operation", event.operationID?.rawValue.uuidString, to: &fields)
        append("incident", event.incidentID?.shortCode, to: &fields)
        append("kind", event.operationKind?.rawValue, to: &fields)
        append("endpoint", event.endpoint?.rawValue, to: &fields)
        append("stage", event.stage?.rawValue, to: &fields)
        append("error_domain", event.failure?.domain.rawValue, to: &fields)
        append("error_code", event.failure?.code, to: &fields)
        append(
            "detail_error_domain",
            event.failureDetail?.domain.rawValue,
            to: &fields
        )
        append("detail_error_code", event.failureDetail?.code, to: &fields)
        append("duration_ms", event.durationMilliseconds, to: &fields)
        append("attempt", event.progress?.attempt, to: &fields)
        append("records", event.progress?.recordCount, to: &fields)
        append("files", event.progress?.fileCount, to: &fields)
        append("bytes", event.progress?.byteCount, to: &fields)
        append("pending", event.progress?.pendingCount, to: &fields)
        append("applied", event.progress?.appliedCount, to: &fields)
        append("conflicts", event.progress?.conflictCount, to: &fields)
        append("mutation", event.mutationContext?.rawValue, to: &fields)
        append(
            "rejection",
            event.mutationRejectionReason?.rawValue,
            to: &fields
        )
        append(
            "persistence_component",
            event.persistenceComponent?.rawValue,
            to: &fields
        )
        append(
            "persistence_operation",
            event.persistenceOperation?.rawValue,
            to: &fields
        )
        append(
            "persistence_phase",
            event.persistencePhase?.rawValue,
            to: &fields
        )
        append(
            "persistence_resolution",
            event.persistenceResolution?.rawValue,
            to: &fields
        )
        return fields.joined(separator: " ")
    }

    private static func append(
        _ key: String,
        _ value: (some Any)?,
        to fields: inout [String]
    ) {
        guard let value else { return }
        fields.append("\(key)=\(value)")
    }
}

public enum DiagnosticEvidenceTextRenderer {
    public static func render(_ events: [EvidenceEvent]) -> String {
        events.map(DiagnosticUnifiedLogMessage.render)
            .joined(separator: "\n")
    }
}

private extension DiagnosticSeverity {
    var osLogType: OSLogType {
        switch self {
        case .debug:
            .debug
        case .information:
            .info
        case .notice:
            .default
        case .error:
            .error
        case .fault:
            .fault
        }
    }
}
