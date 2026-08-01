import Foundation

/// A bundle identity whose data-bearing resources are isolated from every
/// other Noonmark runtime. Code-sign authenticity is verified by the build
/// and DMG evidence gates rather than inferred from this string.
///
/// The bundle identifier is the authority. Build configuration, environment
/// variables, and launch arguments cannot promote a process into production.
public enum NoonmarkRuntimeProfile: String, CaseIterable, Sendable {
    case production
    case development
    case e2e
    case demo
    case audit
    case dmgValidation = "dmg-validation"

    public static func resolve(
        bundleIdentifier: String?
    ) throws -> NoonmarkRuntimeProfile {
        guard let bundleIdentifier else {
            throw NoonmarkRuntimeProfileResolutionError.missingBundleIdentifier
        }
        guard let profile = allCases.first(where: {
            $0.bundleIdentifier == bundleIdentifier
        }) else {
            throw NoonmarkRuntimeProfileResolutionError
                .unknownBundleIdentifier(bundleIdentifier)
        }
        return profile
    }

    public var bundleIdentifier: String {
        switch self {
        case .production:
            "app.noonmark.mac"
        case .development:
            "app.noonmark.mac.development"
        case .e2e:
            "app.noonmark.mac.e2e"
        case .demo:
            "app.noonmark.mac.demo"
        case .audit:
            "app.noonmark.mac.audit"
        case .dmgValidation:
            "app.noonmark.mac.dmg-validation"
        }
    }

    public var applicationSupportDirectoryName: String {
        switch self {
        case .production:
            "noonmark"
        case .development:
            "noonmark-development"
        case .e2e:
            "noonmark-e2e"
        case .demo:
            "noonmark-demo"
        case .audit:
            "noonmark-audit"
        case .dmgValidation:
            "noonmark-dmg-validation"
        }
    }

    public var iCloudRepositoryName: String {
        switch self {
        case .production:
            "Noonmark/SyncRepository"
        case .development:
            "Noonmark-Development/SyncRepository"
        case .e2e:
            "Noonmark-E2E/SyncRepository"
        case .demo:
            "Noonmark-Demo/SyncRepository"
        case .audit:
            "Noonmark-Audit/SyncRepository"
        case .dmgValidation:
            "Noonmark-DMGValidation/SyncRepository"
        }
    }

    public var providerKeychainService: String {
        switch self {
        case .production:
            "app.noonmark.zhulong.provider"
        case .development:
            "app.noonmark.zhulong.provider.development"
        case .e2e:
            "app.noonmark.zhulong.provider.e2e"
        case .demo:
            "app.noonmark.zhulong.provider.demo"
        case .audit:
            "app.noonmark.zhulong.provider.audit"
        case .dmgValidation:
            "app.noonmark.zhulong.provider.dmg-validation"
        }
    }

    public var sidecarKeychainService: String {
        switch self {
        case .production:
            "app.noonmark.zhulong.sidecar-key"
        case .development:
            "app.noonmark.zhulong.sidecar-key.development"
        case .e2e:
            "app.noonmark.zhulong.sidecar-key.e2e"
        case .demo:
            "app.noonmark.zhulong.sidecar-key.demo"
        case .audit:
            "app.noonmark.zhulong.sidecar-key.audit"
        case .dmgValidation:
            "app.noonmark.zhulong.sidecar-key.dmg-validation"
        }
    }

    public var isResettable: Bool {
        self != .production
    }

    public var permitsInternalLaunchArguments: Bool {
        self == .e2e || self == .demo
    }

    public var permitsFixedNaturalDayArguments: Bool {
        self == .e2e || self == .demo
    }

    public func applicationSupportRootURL(baseURL: URL) -> URL {
        baseURL.appendingPathComponent(
            applicationSupportDirectoryName,
            isDirectory: true
        )
    }

    public func databaseURL(baseURL: URL) -> URL {
        applicationSupportRootURL(baseURL: baseURL)
            .appendingPathComponent("Noonmark.sqlite", isDirectory: false)
    }

    public func localSyncRepositoryURL(baseURL: URL) -> URL {
        applicationSupportRootURL(baseURL: baseURL)
            .appendingPathComponent("sync-repository", isDirectory: true)
    }

    /// Proves that an internal test/demo path cannot alias, contain, or sit
    /// below a production-owned root. The comparison is deliberately
    /// case-insensitive so it remains conservative on the default macOS file
    /// system, and resolves existing symlinks before checking ancestry.
    public func validateInternalPathOverride(
        _ candidateURL: URL,
        protectedProductionRoots: [URL]
    ) throws {
        guard self != .production else {
            throw NoonmarkRuntimePathOverrideError
                .productionProfileOverrideForbidden
        }
        guard candidateURL.isFileURL,
              protectedProductionRoots.allSatisfy(\.isFileURL)
        else {
            throw NoonmarkRuntimePathOverrideError.nonFileURL
        }
        guard protectedProductionRoots.isEmpty == false else {
            throw NoonmarkRuntimePathOverrideError.missingProductionScope
        }

        let candidatePath = Self.resolvedComparisonPath(for: candidateURL)
        for protectedRoot in protectedProductionRoots {
            // Production roots are lexical canaries. A nonproduction process
            // must not stat or traverse them merely to prove isolation.
            let protectedPath = Self.lexicalComparisonPath(
                for: protectedRoot
            )
            if Self.isSameOrDescendant(candidatePath, of: protectedPath)
                || Self.isSameOrDescendant(protectedPath, of: candidatePath)
            {
                throw NoonmarkRuntimePathOverrideError
                    .productionScopeOverlap
            }
        }
    }

    private static func resolvedComparisonPath(for url: URL) -> String {
        var existingAncestor = url.standardizedFileURL
        var missingSuffix: [String] = []
        let fileManager = FileManager.default

        while fileManager.fileExists(atPath: existingAncestor.path) == false,
              existingAncestor.path != "/"
        {
            missingSuffix.insert(
                existingAncestor.lastPathComponent,
                at: 0
            )
            let parent = existingAncestor.deletingLastPathComponent()
            guard parent.path != existingAncestor.path else { break }
            existingAncestor = parent
        }

        let resolvedAncestor = existingAncestor
            .resolvingSymlinksInPath()
            .standardizedFileURL
        return missingSuffix.reduce(resolvedAncestor) { partialURL, component in
            partialURL.appendingPathComponent(component)
        }
            .path
            .precomposedStringWithCanonicalMapping
    }

    private static func lexicalComparisonPath(for url: URL) -> String {
        url.standardizedFileURL.path.precomposedStringWithCanonicalMapping
    }

    private static func isSameOrDescendant(
        _ candidatePath: String,
        of rootPath: String
    ) -> Bool {
        let candidate = candidatePath.lowercased()
        let root = rootPath.lowercased()
        return candidate == root || candidate.hasPrefix(root + "/")
    }
}

public enum NoonmarkRuntimeProfileResolutionError: Error, Equatable, Sendable {
    case missingBundleIdentifier
    case unknownBundleIdentifier(String)
}

public enum NoonmarkRuntimePathOverrideError: Error, Equatable, Sendable {
    case productionProfileOverrideForbidden
    case productionScopeOverlap
    case nonFileURL
    case missingProductionScope
}
