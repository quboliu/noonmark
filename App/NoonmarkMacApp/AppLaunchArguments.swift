import Foundation
import NoonmarkMacRuntime

/// The sole bridge from process arguments into the application target.
///
/// Production, Audit, unbundled, and any future bundle identities see only
/// the executable path. Internal switches are visible exclusively to the
/// dedicated E2E bundle.
enum AppLaunchArguments {
    static let values = InternalLaunchArgumentPolicy.visibleArguments(
        bundleIdentifier: Bundle.main.bundleIdentifier,
        processArguments: CommandLine.arguments
    )

    static let permitsInternalArguments = InternalLaunchArgumentPolicy
        .permitsInternalArguments(
            bundleIdentifier: Bundle.main.bundleIdentifier
        )

    static func contains(_ argument: String) -> Bool {
        values.contains(argument)
    }

    static func value(after flag: String) -> String? {
        guard let index = values.firstIndex(of: flag) else { return nil }
        let valueIndex = values.index(after: index)
        guard values.indices.contains(valueIndex) else { return nil }
        return values[valueIndex]
    }
}
