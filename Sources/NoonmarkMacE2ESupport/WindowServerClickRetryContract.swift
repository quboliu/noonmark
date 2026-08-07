public enum WindowServerClickFailurePhase: Equatable, Sendable {
    case unknown
    case beforeMouseDown
    case afterMouseDown
}

public protocol WindowServerClickPhasedFailure: Error {
    var clickFailurePhase: WindowServerClickFailurePhase { get }
}

public enum WindowServerClickRetryContract {
    public static func failurePhase(
        for error: Error
    ) -> WindowServerClickFailurePhase {
        (error as? any WindowServerClickPhasedFailure)?.clickFailurePhase
            ?? .unknown
    }

    public static func shouldRetry(
        failurePhase: WindowServerClickFailurePhase,
        attemptIndex: Int,
        maximumAttempts: Int
    ) -> Bool {
        guard failurePhase == .beforeMouseDown,
              attemptIndex >= 0,
              maximumAttempts > 0
        else {
            return false
        }
        return attemptIndex + 1 < maximumAttempts
    }
}
