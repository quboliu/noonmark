import Foundation

enum MetricKitJSONSanitizer {
    static let redactionVersion = DiagnosticSchemaVersion.metricRedaction

    private static let safeKeys: Set<String> = [
        "address",
        "appbuildversion",
        "applicationbuildversion",
        "applicationlaunchmetrics",
        "applicationresponsivenessmetrics",
        "applicationtimemetrics",
        "applicationversion",
        "averagevalue",
        "binaryimages",
        "binaryname",
        "binaryuuid",
        "bundleidentifier",
        "callstackrootframes",
        "callstacks",
        "callstacktree",
        "count",
        "cpuexceptiondiagnostics",
        "cpumetrics",
        "crashdiagnostics",
        "diagnosticcount",
        "diagnosticmetadata",
        "diskiometrics",
        "diskwriteexceptiondiagnostics",
        "displaymetrics",
        "duration",
        "exceptioncode",
        "exceptiontype",
        "gpumetrics",
        "hangdiagnostics",
        "histogram",
        "histogrammedapplicationhangtime",
        "histogrammedapplicationresumetime",
        "histogrammedtime",
        "histogrammedtimetofirstdraw",
        "latestapplicationversion",
        "memorymetrics",
        "metadata",
        "metriccount",
        "metrics",
        "networktransfermetrics",
        "offsetintobinarytextsegment",
        "pid",
        "samplecount",
        "signal",
        "signpostmetrics",
        "standarddeviation",
        "subframes",
        "terminationreason",
        "threadattributed",
        "timestampbegin",
        "timestampend",
        "totalcount",
        "unit",
        "value",
        "version",
        "virtualmemoryregioninfo"
    ]

    static func sanitize(_ data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        )
        let sanitized = sanitize(object, valueKey: nil)
        return try JSONSerialization.data(
            withJSONObject: sanitized,
            options: [.fragmentsAllowed, .sortedKeys]
        )
    }

    private static func sanitize(_ value: Any, valueKey: String?) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            var result: [String: Any] = [:]
            for (index, pair) in dictionary.sorted(by: {
                $0.key < $1.key
            }).enumerated() {
                let key = safeKey(pair.key) ?? "redacted_key_\(index)"
                result[key] = sanitize(pair.value, valueKey: key)
            }
            return result
        case let array as [Any]:
            return array.map { sanitize($0, valueKey: valueKey) }
        case let string as String:
            return safeSystemString(string, key: valueKey)
                ?? "<redacted>"
        default:
            return value
        }
    }

    private static func safeKey(_ value: String) -> String? {
        guard value.isEmpty == false,
              value.utf8.count <= 128,
              safeKeys.contains(value.lowercased()),
              value.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII
                      && (CharacterSet.alphanumerics.contains(scalar)
                          || "._-".unicodeScalars.contains(scalar))
              })
        else { return nil }
        return value
    }

    private static func safeSystemString(
        _ value: String,
        key: String?
    ) -> String? {
        guard let key else { return nil }
        let normalizedKey = key.lowercased()
        if normalizedKey == "binaryuuid",
           let uuid = UUID(uuidString: value),
           uuid.uuidString.caseInsensitiveCompare(value) == .orderedSame
        {
            return uuid.uuidString.uppercased()
        }
        if normalizedKey == "binaryname",
           value.isEmpty == false,
           value.utf8.count <= 128,
           value.unicodeScalars.allSatisfy({ scalar in
               scalar.isASCII
                   && (CharacterSet.alphanumerics.contains(scalar)
                       || "._+-".unicodeScalars.contains(scalar))
           })
        {
            return value
        }
        if normalizedKey == "bundleidentifier",
           value.utf8.count <= 128,
           value.hasPrefix("app.noonmark.") || value.hasPrefix("com.apple.")
        {
            return value
        }
        return nil
    }
}
