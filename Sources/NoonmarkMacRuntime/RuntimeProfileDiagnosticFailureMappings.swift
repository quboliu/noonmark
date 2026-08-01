import NoonmarkDiagnostics

extension NoonmarkRuntimeProfileResolutionError: DiagnosticFailureProviding {
    public var diagnosticFailure: DiagnosticFailure {
        let code = switch self {
        case .missingBundleIdentifier: 701
        case .unknownBundleIdentifier: 702
        }
        return DiagnosticFailure(domain: .domainValidation, code: code)
    }
}

extension NoonmarkRuntimePathOverrideError: DiagnosticFailureProviding {
    public var diagnosticFailure: DiagnosticFailure {
        let code = switch self {
        case .productionProfileOverrideForbidden: 711
        case .productionScopeOverlap: 712
        case .nonFileURL: 713
        case .missingProductionScope: 714
        }
        return DiagnosticFailure(domain: .domainValidation, code: code)
    }
}
