import Foundation

public enum ZhulongErrorKind: String, Equatable, Sendable {
    case none
    case posix
    case cocoa
    case internalFailure
    case other
}

public struct ZhulongErrorTelemetry: Equatable, Sendable {
    public let kind: ZhulongErrorKind
    public let code: Int?

    public init(_ error: (any Error)?) {
        guard let error else {
            kind = .none
            code = nil
            return
        }
        if error is any ZhulongInternalTelemetryError {
            kind = .internalFailure
            code = nil
            return
        }
        let nsError = error as NSError
        switch nsError.domain {
        case NSPOSIXErrorDomain:
            kind = .posix
            code = nsError.code
        case NSCocoaErrorDomain:
            kind = .cocoa
            code = nsError.code
        default:
            kind = .other
            code = nil
        }
    }
}

protocol ZhulongInternalTelemetryError: Error {}
