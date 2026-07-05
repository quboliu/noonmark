import Foundation

public enum SuntraceError: Error, Equatable, Sendable {
    case notFound(String)
    case invalidTitle
    case chainAbandoned
    case immutableHistory
    case activeTraceAlreadyExists
    case noActiveTrace
    case invalidTransition(String)
    case lockedDay
    case futurePlanCannotComplete
    case historicalCompletionCannotBeUndone
}

