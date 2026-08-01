import Foundation

public enum DiagnosticFailureClassifier {
    public static func classify(_ error: Error) -> DiagnosticFailure {
        let nsError = error as NSError
        return switch nsError.domain {
        case NSCocoaErrorDomain:
            DiagnosticFailure(domain: .cocoa, code: nsError.code)
        case NSPOSIXErrorDomain:
            DiagnosticFailure(domain: .posix, code: nsError.code)
        case NSURLErrorDomain:
            DiagnosticFailure(domain: .url, code: nsError.code)
        case "CKErrorDomain":
            DiagnosticFailure(domain: .cloudKit, code: nsError.code)
        default:
            DiagnosticFailure(domain: .unknown, code: 0)
        }
    }
}
