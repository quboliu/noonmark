import Foundation

public struct DiagnosticRecordingBootstrap: Sendable {
    public let recorder: any DiagnosticRecording
    public let localRecorder: LocalDiagnosticRecorder?

    private init(
        recorder: any DiagnosticRecording,
        localRecorder: LocalDiagnosticRecorder?
    ) {
        self.recorder = recorder
        self.localRecorder = localRecorder
    }

    public static func prepare(
        rootURL: URL,
        configuration: DiagnosticStorageConfiguration = .production,
        sessionID: DiagnosticSessionID = DiagnosticSessionID()
    ) async -> DiagnosticRecordingBootstrap {
        await prepare(
            localRecorder: {
                try await LocalDiagnosticRecorder.prepare(
                    rootURL: rootURL,
                    configuration: configuration,
                    sessionID: sessionID
                )
            },
            fallbackRecorder: {
                AppleOnlyDiagnosticRecorder(sessionID: sessionID)
            }
        )
    }

    public static func prepare(
        rootURL: URL,
        appIdentity: DiagnosticAppIdentity,
        configuration: DiagnosticStorageConfiguration = .production,
        sessionID: DiagnosticSessionID = DiagnosticSessionID()
    ) async -> DiagnosticRecordingBootstrap {
        await prepare(
            localRecorder: {
                try await LocalDiagnosticRecorder.prepare(
                    rootURL: rootURL,
                    appIdentity: appIdentity,
                    configuration: configuration,
                    sessionID: sessionID
                )
            },
            fallbackRecorder: {
                AppleOnlyDiagnosticRecorder(sessionID: sessionID)
            }
        )
    }

    static func prepare(
        localRecorder: @escaping @Sendable () async throws -> LocalDiagnosticRecorder,
        fallbackRecorder: @escaping @Sendable () -> any DiagnosticRecording
    ) async -> DiagnosticRecordingBootstrap {
        do {
            let recorder = try await localRecorder()
            return DiagnosticRecordingBootstrap(
                recorder: recorder,
                localRecorder: recorder
            )
        } catch {
            let recorder = fallbackRecorder()
            recorder.record(.sessionStarted())
            let operation = recorder.startOperation(kind: .persistence)
            operation.fail(diagnosticFailure(for: error))
            return DiagnosticRecordingBootstrap(
                recorder: recorder,
                localRecorder: nil
            )
        }
    }

    private static func diagnosticFailure(
        for error: any Error
    ) -> DiagnosticFailure {
        if let provider = error as? any DiagnosticFailureProviding {
            return provider.diagnosticFailure
        }
        let systemError = error as NSError
        return DiagnosticSystemFailureMapper.map(
            domain: systemError.domain,
            code: systemError.code
        )
    }
}
