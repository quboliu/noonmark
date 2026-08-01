import Foundation

public protocol DiagnosticFailureProviding: Error {
    var diagnosticFailure: DiagnosticFailure { get }
}

public enum DiagnosticFailureClassifier {
    public static func classify(_ error: Error) -> DiagnosticFailure {
        if let provider = error as? any DiagnosticFailureProviding {
            return provider.diagnosticFailure
        }
        var visited: Set<ObjectIdentifier> = []
        return classify(error as NSError, depth: 0, visited: &visited)
    }

    private static func classify(
        _ error: NSError,
        depth: Int,
        visited: inout Set<ObjectIdentifier>
    ) -> DiagnosticFailure {
        let recognized: DiagnosticFailure? = switch error.domain {
        case NSCocoaErrorDomain:
            DiagnosticFailure(domain: .cocoa, code: error.code)
        case NSPOSIXErrorDomain:
            DiagnosticFailure(domain: .posix, code: error.code)
        case NSURLErrorDomain:
            DiagnosticFailure(domain: .url, code: error.code)
        case "CKErrorDomain":
            DiagnosticFailure(domain: .cloudKit, code: error.code)
        default:
            nil
        }
        if let recognized {
            return recognized
        }

        let identity = ObjectIdentifier(error)
        guard depth < 4,
              visited.insert(identity).inserted,
              let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        else {
            return DiagnosticFailure(domain: .unknown, code: 0)
        }
        return classify(underlying, depth: depth + 1, visited: &visited)
    }
}
