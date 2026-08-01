import NoonmarkDiagnostics

public struct RecordedStartupFailure: DiagnosticFailureProviding, Sendable {
    public let diagnosticFailure: DiagnosticFailure
    public let diagnosticIncidentID: DiagnosticIncidentID

    public init(
        diagnosticFailure: DiagnosticFailure,
        diagnosticIncidentID: DiagnosticIncidentID
    ) {
        self.diagnosticFailure = diagnosticFailure
        self.diagnosticIncidentID = diagnosticIncidentID
    }
}

public enum StartupFailureIncidentResolver {
    public static func resolve(
        for error: any Error,
        recordUnrecordedFailure: () -> DiagnosticIncidentID
    ) -> DiagnosticIncidentID {
        if let recordedFailure = error as? RecordedStartupFailure {
            return recordedFailure.diagnosticIncidentID
        }
        return recordUnrecordedFailure()
    }
}
