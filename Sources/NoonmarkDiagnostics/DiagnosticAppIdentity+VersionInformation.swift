public extension DiagnosticAppIdentity {
    var versionSummary: String {
        "\(version) (\(build)) · \(buildArchitecture)"
    }

    var versionInformationText: String {
        [
            "Version: \(version) (\(build)) [\(buildArchitecture)]",
            "Commit: \(versionInformationValue(commitSHA))",
            "Date: \(versionInformationValue(buildDate))",
            "Runtime: \(versionInformationValue(runtime))",
            "Minimum OS: \(minimumOSVersion.map { "macOS \($0)" } ?? "unknown")",
            "Mach-O UUID: \(versionInformationValue(binaryUUID))",
            "Binary SHA256: \(versionInformationValue(binarySHA256))",
            "Binary SHA256 Scope: \(versionInformationValue(binarySHA256Scope?.rawValue))",
            "OS: Darwin \(versionInformationValue(darwinVersion)) (\(architecture))",
            "Diagnostics: schema \(DiagnosticSchemaVersion.evidence), redaction \(DiagnosticSchemaVersion.metricRedaction)"
        ].joined(separator: "\n")
    }

    private func versionInformationValue(_ value: String?) -> String {
        guard let value, value.isEmpty == false else { return "unknown" }
        return value
    }
}
