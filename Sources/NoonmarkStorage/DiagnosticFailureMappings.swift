import NoonmarkDiagnostics
import SQLite3

extension SQLiteRepositoryError: DiagnosticFailureProviding {
    public var diagnosticFailure: DiagnosticFailure {
        let code: Int = switch self {
        case .transientContention:
            Int(SQLITE_BUSY)
        case let .openFailed(_, sqliteCode):
            sqliteCode.map(Int.init) ?? -1002
        case let .prepareFailed(_, sqliteCode):
            sqliteCode.map(Int.init) ?? -1003
        case let .executeFailed(_, sqliteCode):
            sqliteCode.map(Int.init) ?? -1004
        case let .stepFailed(_, sqliteCode):
            sqliteCode.map(Int.init) ?? -1005
        case .invalidStoredValue:
            -1006
        case let .backupFailed(_, sqliteCode):
            sqliteCode.map(Int.init) ?? -1007
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
