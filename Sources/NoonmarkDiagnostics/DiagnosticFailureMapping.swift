import Foundation

public protocol DiagnosticFailureProviding: Error {
    var diagnosticFailure: DiagnosticFailure { get }
}

public enum DiagnosticSystemFailureMapper {
    public static func map(
        domain: String,
        code: Int
    ) -> DiagnosticFailure {
        switch domain {
        case NSCocoaErrorDomain:
            DiagnosticFailure(domain: .cocoa, code: code)
        case NSPOSIXErrorDomain:
            DiagnosticFailure(domain: .posix, code: code)
        case NSURLErrorDomain:
            DiagnosticFailure(domain: .url, code: code)
        case "CKErrorDomain":
            DiagnosticFailure(domain: .cloudKit, code: code)
        default:
            DiagnosticFailure(domain: .unknown, code: 0)
        }
    }
}
