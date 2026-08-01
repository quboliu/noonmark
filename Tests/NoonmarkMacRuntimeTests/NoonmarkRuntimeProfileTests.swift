import Foundation
import NoonmarkDiagnostics
import NoonmarkMacRuntime
import XCTest

final class NoonmarkRuntimeProfileTests: XCTestCase {
    func testEverySignedBundleIdentityResolvesToItsExactRuntimeScope() throws {
        let expected: [(NoonmarkRuntimeProfile, String, String, String, String, String)] = [
            (
                .production,
                "app.noonmark.mac",
                "noonmark",
                "Noonmark/SyncRepository",
                "app.noonmark.zhulong.provider",
                "app.noonmark.zhulong.sidecar-key"
            ),
            (
                .development,
                "app.noonmark.mac.development",
                "noonmark-development",
                "Noonmark-Development/SyncRepository",
                "app.noonmark.zhulong.provider.development",
                "app.noonmark.zhulong.sidecar-key.development"
            ),
            (
                .e2e,
                "app.noonmark.mac.e2e",
                "noonmark-e2e",
                "Noonmark-E2E/SyncRepository",
                "app.noonmark.zhulong.provider.e2e",
                "app.noonmark.zhulong.sidecar-key.e2e"
            ),
            (
                .demo,
                "app.noonmark.mac.demo",
                "noonmark-demo",
                "Noonmark-Demo/SyncRepository",
                "app.noonmark.zhulong.provider.demo",
                "app.noonmark.zhulong.sidecar-key.demo"
            ),
            (
                .audit,
                "app.noonmark.mac.audit",
                "noonmark-audit",
                "Noonmark-Audit/SyncRepository",
                "app.noonmark.zhulong.provider.audit",
                "app.noonmark.zhulong.sidecar-key.audit"
            ),
            (
                .dmgValidation,
                "app.noonmark.mac.dmg-validation",
                "noonmark-dmg-validation",
                "Noonmark-DMGValidation/SyncRepository",
                "app.noonmark.zhulong.provider.dmg-validation",
                "app.noonmark.zhulong.sidecar-key.dmg-validation"
            )
        ]

        XCTAssertEqual(NoonmarkRuntimeProfile.allCases.count, expected.count)
        for (profile, bundleIdentifier, dataDirectory, repository, providerService, sidecarService) in expected {
            XCTAssertEqual(
                try NoonmarkRuntimeProfile.resolve(bundleIdentifier: bundleIdentifier),
                profile
            )
            XCTAssertEqual(profile.bundleIdentifier, bundleIdentifier)
            XCTAssertEqual(profile.applicationSupportDirectoryName, dataDirectory)
            XCTAssertEqual(profile.iCloudRepositoryName, repository)
            XCTAssertEqual(profile.providerKeychainService, providerService)
            XCTAssertEqual(profile.sidecarKeychainService, sidecarService)
        }
    }

    func testRuntimeScopesArePairwiseDistinctAndNonproductionNeverNestsUnderProduction() {
        let profiles = NoonmarkRuntimeProfile.allCases

        XCTAssertEqual(Set(profiles.map(\.bundleIdentifier)).count, profiles.count)
        XCTAssertEqual(Set(profiles.map(\.applicationSupportDirectoryName)).count, profiles.count)
        XCTAssertEqual(Set(profiles.map(\.iCloudRepositoryName)).count, profiles.count)
        XCTAssertEqual(Set(profiles.map(\.providerKeychainService)).count, profiles.count)
        XCTAssertEqual(Set(profiles.map(\.sidecarKeychainService)).count, profiles.count)

        for profile in profiles where profile != .production {
            XCTAssertFalse(
                profile.applicationSupportDirectoryName.hasPrefix(
                    NoonmarkRuntimeProfile.production.applicationSupportDirectoryName + "/"
                )
            )
            XCTAssertFalse(
                profile.iCloudRepositoryName.hasPrefix(
                    NoonmarkRuntimeProfile.production.iCloudRepositoryName + "/"
                )
            )
        }
    }

    func testProductionIsTheOnlyNonResettableScope() {
        XCTAssertFalse(NoonmarkRuntimeProfile.production.isResettable)
        for profile in NoonmarkRuntimeProfile.allCases where profile != .production {
            XCTAssertTrue(profile.isResettable)
        }
    }

    func testOnlyE2EAndDemoMayConsumeInternalLaunchArguments() {
        XCTAssertTrue(NoonmarkRuntimeProfile.e2e.permitsInternalLaunchArguments)
        XCTAssertTrue(NoonmarkRuntimeProfile.demo.permitsInternalLaunchArguments)
        XCTAssertTrue(NoonmarkRuntimeProfile.e2e.permitsFixedNaturalDayArguments)
        XCTAssertTrue(NoonmarkRuntimeProfile.demo.permitsFixedNaturalDayArguments)

        for profile in [
            NoonmarkRuntimeProfile.production,
            .development,
            .audit,
            .dmgValidation
        ] {
            XCTAssertFalse(profile.permitsInternalLaunchArguments)
            XCTAssertFalse(profile.permitsFixedNaturalDayArguments)
        }
    }

    func testUnknownMissingAndLookalikeBundleIdentitiesFailClosed() {
        XCTAssertThrowsError(
            try NoonmarkRuntimeProfile.resolve(bundleIdentifier: nil)
        ) { error in
            XCTAssertEqual(error as? NoonmarkRuntimeProfileResolutionError, .missingBundleIdentifier)
        }

        for bundleIdentifier in [
            "",
            "app.noonmark.mac.e2e.debug",
            "app.noonmark.mac.e2e-malicious",
            "app.noonmark.mac.dmgvalidation",
            "APP.NOONMARK.MAC"
        ] {
            XCTAssertThrowsError(
                try NoonmarkRuntimeProfile.resolve(bundleIdentifier: bundleIdentifier)
            ) { error in
                XCTAssertEqual(
                    error as? NoonmarkRuntimeProfileResolutionError,
                    .unknownBundleIdentifier(bundleIdentifier)
                )
            }
        }
    }

    func testProfileBuildsLocalURLsOnlyBelowItsOwnApplicationSupportRoot() {
        let applicationSupport = URL(fileURLWithPath: "/Users/example/Library/Application Support")

        for profile in NoonmarkRuntimeProfile.allCases {
            let root = profile.applicationSupportRootURL(baseURL: applicationSupport)
            XCTAssertEqual(
                root.path,
                applicationSupport
                    .appendingPathComponent(profile.applicationSupportDirectoryName)
                    .path
            )
            XCTAssertEqual(
                profile.databaseURL(baseURL: applicationSupport).path,
                root.appendingPathComponent("Noonmark.sqlite").path
            )
            XCTAssertEqual(
                profile.localSyncRepositoryURL(baseURL: applicationSupport).path,
                root.appendingPathComponent("sync-repository").path
            )
        }
    }

    func testNonproductionOverrideAcceptsAnUnrelatedIsolatedPath() throws {
        let productionRoots = [
            URL(fileURLWithPath: "/Users/example/Library/Application Support/noonmark"),
            URL(fileURLWithPath: "/Users/example/Library/Mobile Documents/com~apple~CloudDocs/Noonmark/SyncRepository")
        ]

        XCTAssertNoThrow(
            try NoonmarkRuntimeProfile.e2e.validateInternalPathOverride(
                URL(fileURLWithPath: "/private/tmp/noonmark-e2e/Noonmark.sqlite"),
                protectedProductionRoots: productionRoots
            )
        )
        XCTAssertNoThrow(
            try NoonmarkRuntimeProfile.demo.validateInternalPathOverride(
                URL(fileURLWithPath: "/workspace/artifacts/interactive-demo"),
                protectedProductionRoots: productionRoots
            )
        )
    }

    func testProductionProfileCannotAuthorizeAnInternalPathOverride() {
        XCTAssertThrowsError(
            try NoonmarkRuntimeProfile.production.validateInternalPathOverride(
                URL(fileURLWithPath: "/private/tmp/noonmark"),
                protectedProductionRoots: [
                    URL(fileURLWithPath: "/Users/example/Library/Application Support/noonmark")
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkRuntimePathOverrideError,
                .productionProfileOverrideForbidden
            )
        }
    }

    func testOverrideRejectsEveryProductionPathOverlapDirection() {
        let productionRoot = URL(
            fileURLWithPath: "/Users/example/Library/Application Support/noonmark"
        )
        let rejected = [
            productionRoot,
            productionRoot.appendingPathComponent("Noonmark.sqlite"),
            productionRoot.appendingPathComponent("nested/../Noonmark.sqlite"),
            productionRoot.deletingLastPathComponent(),
            URL(fileURLWithPath: "/Users/example/Library/Application Support/NOONMARK")
        ]

        for candidate in rejected {
            XCTAssertThrowsError(
                try NoonmarkRuntimeProfile.e2e.validateInternalPathOverride(
                    candidate,
                    protectedProductionRoots: [productionRoot]
                ),
                "expected production overlap rejection for \(candidate.path)"
            ) { error in
                XCTAssertEqual(
                    error as? NoonmarkRuntimePathOverrideError,
                    .productionScopeOverlap
                )
            }
        }
    }

    func testOverrideRejectsAnExistingSymlinkIntoProductionScope() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let productionRoot = fixtureRoot
            .appendingPathComponent("production", isDirectory: true)
        let aliasRoot = fixtureRoot
            .appendingPathComponent("test-alias", isDirectory: true)
        try FileManager.default.createDirectory(
            at: productionRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: aliasRoot,
            withDestinationURL: productionRoot
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }

        XCTAssertThrowsError(
            try NoonmarkRuntimeProfile.demo.validateInternalPathOverride(
                aliasRoot.appendingPathComponent("Noonmark.sqlite"),
                protectedProductionRoots: [productionRoot]
            )
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkRuntimePathOverrideError,
                .productionScopeOverlap
            )
        }
    }

    func testOverrideRejectsLexicalProductionOverlapBeforeResolvingCandidateSymlink() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let unrelatedTarget = fixtureRoot
            .appendingPathComponent("unrelated-target", isDirectory: true)
        let protectedProductionRoot = fixtureRoot
            .appendingPathComponent("production-canary", isDirectory: true)
        try FileManager.default.createDirectory(
            at: unrelatedTarget,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: protectedProductionRoot,
            withDestinationURL: unrelatedTarget
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }

        XCTAssertThrowsError(
            try NoonmarkRuntimeProfile.e2e.validateInternalPathOverride(
                protectedProductionRoot,
                protectedProductionRoots: [protectedProductionRoot]
            )
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkRuntimePathOverrideError,
                .productionScopeOverlap
            )
        }
    }

    func testLexicalProductionOverlapDoesNotDependOnDescendantExistence() throws {
        let fixtureRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
                "noonmark-lexical-overlap-\(UUID().uuidString)",
                isDirectory: true
            )
        let productionRoot = fixtureRoot.appendingPathComponent(
            "production",
            isDirectory: true
        )
        let missingDescendant = productionRoot.appendingPathComponent(
            "RuntimeEvidence/main-window-identity.json"
        )
        try FileManager.default.createDirectory(
            at: productionRoot,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }

        XCTAssertThrowsError(
            try NoonmarkRuntimeProfile.e2e.validateInternalPathOverride(
                missingDescendant,
                protectedProductionRoots: [productionRoot]
            )
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkRuntimePathOverrideError,
                .productionScopeOverlap
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: missingDescendant.path)
        )
    }

    func testLexicalProductionComparisonAllowsOnlyTruePathComponentSiblings() {
        let applicationSupport = URL(
            fileURLWithPath: "/Users/example/Library/Application Support",
            isDirectory: true
        )
        let productionRoot = applicationSupport.appendingPathComponent(
            "noonmark",
            isDirectory: true
        )
        for siblingName in [
            "noonmark-development",
            "noonmark-e2e",
            "noonmark-dmg-validation"
        ] {
            XCTAssertNoThrow(
                try NoonmarkRuntimeProfile.e2e.validateInternalPathOverride(
                    applicationSupport.appendingPathComponent(
                        siblingName,
                        isDirectory: true
                    ),
                    protectedProductionRoots: [productionRoot]
                )
            )
        }
    }

    func testFilesystemRootIsRejectedAsAProductionScopeAncestor() {
        let productionRoot = URL(
            fileURLWithPath: "/Users/example/Library/Application Support/noonmark",
            isDirectory: true
        )

        XCTAssertThrowsError(
            try NoonmarkRuntimeProfile.e2e.validateInternalPathOverride(
                URL(fileURLWithPath: "/", isDirectory: true),
                protectedProductionRoots: [productionRoot]
            )
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkRuntimePathOverrideError,
                .productionScopeOverlap
            )
        }
    }

    func testOverrideRejectsEveryExistingCandidateSymlinkWithoutFollowingItsTarget() throws {
        let fixtureRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let unrelatedTarget = fixtureRoot
            .appendingPathComponent("unrelated-target", isDirectory: true)
        let candidateAlias = fixtureRoot
            .appendingPathComponent("candidate-alias", isDirectory: true)
        let protectedProductionRoot = fixtureRoot
            .appendingPathComponent("production-canary", isDirectory: true)
        try FileManager.default.createDirectory(
            at: unrelatedTarget,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: candidateAlias,
            withDestinationURL: unrelatedTarget
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }

        XCTAssertThrowsError(
            try NoonmarkRuntimeProfile.demo.validateInternalPathOverride(
                candidateAlias.appendingPathComponent("Noonmark.sqlite"),
                protectedProductionRoots: [protectedProductionRoot]
            )
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkRuntimePathOverrideError,
                .productionScopeOverlap
            )
        }
    }

    func testOverrideRejectsNonFileURLsAndAnEmptyProtectionSet() {
        XCTAssertThrowsError(
            try NoonmarkRuntimeProfile.e2e.validateInternalPathOverride(
                URL(string: "https://example.com/Noonmark.sqlite")!,
                protectedProductionRoots: [URL(fileURLWithPath: "/production")]
            )
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkRuntimePathOverrideError,
                .nonFileURL
            )
        }
        XCTAssertThrowsError(
            try NoonmarkRuntimeProfile.e2e.validateInternalPathOverride(
                URL(fileURLWithPath: "/private/tmp/noonmark-e2e.sqlite"),
                protectedProductionRoots: []
            )
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkRuntimePathOverrideError,
                .missingProductionScope
            )
        }
    }

    func testRuntimeIsolationFailuresHaveStableTypedDiagnosticCodes() {
        let expected: [(any DiagnosticFailureProviding, Int)] = [
            (NoonmarkRuntimeProfileResolutionError.missingBundleIdentifier, 701),
            (
                NoonmarkRuntimeProfileResolutionError
                    .unknownBundleIdentifier("app.example.unknown"),
                702
            ),
            (
                NoonmarkRuntimePathOverrideError
                    .productionProfileOverrideForbidden,
                711
            ),
            (NoonmarkRuntimePathOverrideError.productionScopeOverlap, 712),
            (NoonmarkRuntimePathOverrideError.nonFileURL, 713),
            (NoonmarkRuntimePathOverrideError.missingProductionScope, 714)
        ]

        for (error, code) in expected {
            XCTAssertEqual(
                error.diagnosticFailure,
                DiagnosticFailure(domain: .domainValidation, code: code)
            )
        }
    }
}
