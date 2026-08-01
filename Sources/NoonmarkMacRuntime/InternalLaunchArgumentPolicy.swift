/// Defines the application identities allowed to consume Noonmark's internal
/// launch arguments.
///
/// Build configuration is deliberately irrelevant: both Debug and Release
/// production bundles receive only their executable argument. This keeps test
/// controls unavailable unless the process is packaged with an explicitly
/// authorized nonproduction identity.
public enum InternalLaunchArgumentPolicy {
    public static let e2eBundleIdentifier = NoonmarkRuntimeProfile.e2e
        .bundleIdentifier

    public static func permitsInternalArguments(
        bundleIdentifier: String?
    ) -> Bool {
        guard let profile = try? NoonmarkRuntimeProfile.resolve(
            bundleIdentifier: bundleIdentifier
        ) else { return false }
        return profile.permitsInternalLaunchArguments
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
