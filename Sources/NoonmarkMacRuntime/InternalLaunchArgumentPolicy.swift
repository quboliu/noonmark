/// Defines the only application identity allowed to consume Noonmark's
/// internal launch arguments.
///
/// Build configuration is deliberately irrelevant: both Debug and Release
/// production bundles receive only their executable argument. This keeps test
/// controls unavailable unless the process is packaged with the dedicated E2E
/// bundle identity.
public enum InternalLaunchArgumentPolicy {
    public static let e2eBundleIdentifier = "app.noonmark.mac.e2e"

    public static func permitsInternalArguments(
        bundleIdentifier: String?
    ) -> Bool {
        bundleIdentifier == e2eBundleIdentifier
    }

    public static func visibleArguments(
        bundleIdentifier: String?,
        processArguments: [String]
    ) -> [String] {
        guard permitsInternalArguments(bundleIdentifier: bundleIdentifier)
        else {
            return Array(processArguments.prefix(1))
        }
        return processArguments
    }
}
