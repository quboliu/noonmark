import NoonmarkDiagnostics

extension SQLiteRepositoryError: DiagnosticFailureProviding {
    public var diagnosticFailure: DiagnosticFailure {
        let code = switch self {
        case .transientContention: 1
        case .openFailed: 2
        case .prepareFailed: 3
        case .executeFailed: 4
        case .stepFailed: 5
        case .invalidStoredValue: 6
        case .backupFailed: 7
        }
        return DiagnosticFailure(domain: .sqlite, code: code)
    }
}

extension NoonmarkDataRootProcessLeaseError: DiagnosticFailureProviding {
    public var diagnosticFailure: DiagnosticFailure {
        switch self {
        case .alreadyHeld:
            DiagnosticFailure(domain: .domainValidation, code: 21)
        case .invalidDataRoot:
            DiagnosticFailure(domain: .domainValidation, code: 22)
        case .invalidLockFile:
            DiagnosticFailure(domain: .domainValidation, code: 23)
        case let .posixFailure(_, code, _):
            DiagnosticFailure(domain: .posix, code: Int(code))
        }
    }
}
