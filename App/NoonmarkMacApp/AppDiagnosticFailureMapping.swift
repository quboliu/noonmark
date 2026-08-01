import Foundation
import NoonmarkDiagnostics

enum AppDiagnosticFailureMapping {
    static func map(_ error: any Error) -> DiagnosticFailure {
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
