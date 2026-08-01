import Foundation
import NoonmarkMacRuntime

/// The sole bridge from process arguments into the application target.
///
/// Unknown identities fail closed. Internal switches are visible only to
/// profiles that explicitly opt into them.
enum AppLaunchArguments {
    private static let runtimeProfileResult = Result {
        try NoonmarkRuntimeProfile.resolve(
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
    }

    static var runtimeProfile: NoonmarkRuntimeProfile {
        get throws {
            try runtimeProfileResult.get()
        }
    }

    static var validatedRuntimeProfile: NoonmarkRuntimeProfile {
        do {
            return try runtimeProfile
        } catch {
            preconditionFailure(
                "Noonmark runtime identity must be signed into the bundle: \(error)"
            )
        }
    }

    static let values = InternalLaunchArgumentPolicy.visibleArguments(
        bundleIdentifier: Bundle.main.bundleIdentifier,
        processArguments: CommandLine.arguments
    )

    static let permitsInternalArguments = InternalLaunchArgumentPolicy
        .permitsInternalArguments(
            bundleIdentifier: Bundle.main.bundleIdentifier
        )

    static func validateRuntimeDataIsolation(
        fileManager: FileManager = .default
    ) throws {
        let profile = try runtimeProfile
        guard profile != .production else { return }

        let applicationSupportBase = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support",
                isDirectory: true
            )
        let productionApplicationSupportRoot = NoonmarkRuntimeProfile
            .production
            .applicationSupportRootURL(baseURL: applicationSupportBase)
        let productionICloudRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Mobile Documents/com~apple~CloudDocs",
                isDirectory: true
            )
            .appendingPathComponent(
                NoonmarkRuntimeProfile.production.iCloudRepositoryName,
                isDirectory: true
            )
        var protectedRoots = [
            productionApplicationSupportRoot,
            productionICloudRoot
        ]

        let selectedApplicationSupportRoot = profile
            .applicationSupportRootURL(baseURL: applicationSupportBase)
        let selectedICloudRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Mobile Documents/com~apple~CloudDocs",
                isDirectory: true
            )
            .appendingPathComponent(
                profile.iCloudRepositoryName,
                isDirectory: true
            )
        var selectedRoots = [
            selectedApplicationSupportRoot,
            selectedICloudRoot
        ]
        if let ubiquitousContainer = fileManager
            .url(forUbiquityContainerIdentifier: nil)
        {
            let documentsRoot = ubiquitousContainer.appendingPathComponent(
                "Documents",
                isDirectory: true
            )
            protectedRoots.append(
                documentsRoot.appendingPathComponent(
                    NoonmarkRuntimeProfile.production.iCloudRepositoryName,
                    isDirectory: true
                )
            )
            selectedRoots.append(
                documentsRoot.appendingPathComponent(
                    profile.iCloudRepositoryName,
                    isDirectory: true
                )
            )
        }
        for selectedRoot in selectedRoots {
            try profile.validateInternalPathOverride(
                selectedRoot,
                protectedProductionRoots: protectedRoots
            )
        }

        for flag in [
            "--data-url",
            "--sync-folder-url",
            MainWindowIdentityPublisher.e2eIdentityURLArgument
        ] {
            guard let path = value(after: flag), path.isEmpty == false else {
                continue
            }
            try profile.validateInternalPathOverride(
                URL(fileURLWithPath: path),
                protectedProductionRoots: protectedRoots
            )
        }
    }

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
