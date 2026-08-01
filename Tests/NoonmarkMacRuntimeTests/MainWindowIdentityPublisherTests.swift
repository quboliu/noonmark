import Darwin
import Foundation
@testable import NoonmarkMacRuntime
import XCTest

final class MainWindowIdentityPublisherTests: XCTestCase {
    private let launchToken = "6A6678CF-8ED9-4451-BE2B-299D1B165C18"

    func testProductionNeverPreparesAWindowIdentityPublisher() throws {
        let inaccessibleCanary = URL(
            fileURLWithPath: "/path-that-must-not-be-opened/production"
        )

        let publisher = try MainWindowIdentityPublisher.prepare(
            profile: .production,
            bundleIdentifier: NoonmarkRuntimeProfile.production.bundleIdentifier,
            processArguments: ["NoonmarkMacApp", "--e2e-main-window-identity-url", "/tmp/canary"],
            applicationSupportBaseURL: inaccessibleCanary,
            homeDirectoryURL: inaccessibleCanary
        )

        XCTAssertNil(publisher)
    }

    func testE2EPublishesOneOwnerOnlyExactIdentityAtomically() throws {
        let fixture = try makeFixture(named: "e2e")
        let identityURL = fixture.runtimeEvidenceURL
            .appendingPathComponent(MainWindowIdentityPublisher.identityFileName)
        let publisher = try XCTUnwrap(
            MainWindowIdentityPublisher.prepare(
                profile: .e2e,
                bundleIdentifier: NoonmarkRuntimeProfile.e2e.bundleIdentifier,
                processArguments: [
                    "NoonmarkMacAppE2E",
                    MainWindowIdentityPublisher.e2eIdentityURLArgument,
                    identityURL.path,
                    MainWindowIdentityPublisher.e2eLaunchTokenArgument,
                    launchToken
                ],
                applicationSupportBaseURL: fixture.applicationSupportURL,
                homeDirectoryURL: fixture.rootURL
            )
        )

        try publisher.publish(
            processIdentifier: getpid(),
            bundleIdentifier: NoonmarkRuntimeProfile.e2e.bundleIdentifier,
            windowNumber: 41,
            title: "晷迹 · Day Todo — 7月5日"
        )

        let object = try exactJSONObject(at: identityURL)
        XCTAssertEqual(
            Set(object.keys),
            [
                "schema_version", "profile", "launch_token",
                "process_identifier", "bundle_identifier", "window_number",
                "title"
            ]
        )
        XCTAssertEqual(object["schema_version"] as? Int, 1)
        XCTAssertEqual(object["profile"] as? String, "e2e")
        XCTAssertEqual(object["launch_token"] as? String, launchToken)
        XCTAssertEqual(object["process_identifier"] as? Int, Int(getpid()))
        XCTAssertEqual(
            object["bundle_identifier"] as? String,
            NoonmarkRuntimeProfile.e2e.bundleIdentifier
        )
        XCTAssertEqual(object["window_number"] as? Int, 41)
        XCTAssertEqual(object["title"] as? String, "晷迹 · Day Todo — 7月5日")
        try assertOwnerOnlyRegularFile(at: identityURL)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                atPath: fixture.runtimeEvidenceURL.path
            ).allSatisfy { $0.hasSuffix(".tmp") == false }
        )
    }

    func testDMGValidationConsumesOnlyTheExactOwnerOnlyRequestSchema() throws {
        let fixture = try makeFixture(named: "dmg-valid")
        let requestURL = fixture.runtimeEvidenceURL
            .appendingPathComponent(MainWindowIdentityPublisher.requestFileName)
        try writeOwnerOnly(
            [
                "schema_version": 1,
                "profile": "dmg-validation",
                "launch_token": launchToken
            ],
            to: requestURL
        )
        let selectedProfileURL = NoonmarkRuntimeProfile.dmgValidation
            .applicationSupportRootURL(baseURL: fixture.applicationSupportURL)
        let protectedRoots = [
            NoonmarkRuntimeProfile.production.applicationSupportRootURL(
                baseURL: fixture.applicationSupportURL
            ),
            fixture.rootURL.appendingPathComponent(
                "Library/Mobile Documents/com~apple~CloudDocs/Noonmark/SyncRepository"
            )
        ]
        XCTAssertNoThrow(
            try NoonmarkRuntimeProfile.dmgValidation
                .validateInternalPathOverride(
                    selectedProfileURL,
                    protectedProductionRoots: protectedRoots
                )
        )

        let publisher = try XCTUnwrap(
            MainWindowIdentityPublisher.prepare(
                profile: .dmgValidation,
                bundleIdentifier: NoonmarkRuntimeProfile.dmgValidation.bundleIdentifier,
                processArguments: ["NoonmarkMacAppDMGValidation"],
                applicationSupportBaseURL: fixture.applicationSupportURL,
                homeDirectoryURL: fixture.rootURL
            )
        )
        XCTAssertEqual(publisher.launchToken, launchToken)

        try publisher.publish(
            processIdentifier: getpid(),
            bundleIdentifier: NoonmarkRuntimeProfile.dmgValidation.bundleIdentifier,
            windowNumber: 73,
            title: "晷迹 · Noonmark"
        )

        let identityURL = fixture.runtimeEvidenceURL
            .appendingPathComponent(MainWindowIdentityPublisher.identityFileName)
        let object = try exactJSONObject(at: identityURL)
        XCTAssertEqual(object["profile"] as? String, "dmg-validation")
        XCTAssertEqual(object["launch_token"] as? String, launchToken)
        XCTAssertEqual(object["window_number"] as? Int, 73)
        try assertOwnerOnlyRegularFile(at: identityURL)
    }

    func testDMGValidationRejectsUnknownRequestFieldsAndUnsafeRequestFiles() throws {
        for fixtureName in ["unknown-field", "world-readable", "hard-link"] {
            let fixture = try makeFixture(named: fixtureName)
            let requestURL = fixture.runtimeEvidenceURL
                .appendingPathComponent(MainWindowIdentityPublisher.requestFileName)
            var object: [String: Any] = [
                "schema_version": 1,
                "profile": "dmg-validation",
                "launch_token": launchToken
            ]
            if fixtureName == "unknown-field" {
                object["unexpected"] = true
            }
            try writeOwnerOnly(object, to: requestURL)
            if fixtureName == "world-readable" {
                XCTAssertEqual(chmod(requestURL.path, 0o644), 0)
            } else if fixtureName == "hard-link" {
                XCTAssertEqual(
                    link(
                        requestURL.path,
                        requestURL.appendingPathExtension("alias").path
                    ),
                    0
                )
            }

            XCTAssertThrowsError(
                try MainWindowIdentityPublisher.prepare(
                    profile: .dmgValidation,
                    bundleIdentifier: NoonmarkRuntimeProfile.dmgValidation.bundleIdentifier,
                    processArguments: ["NoonmarkMacAppDMGValidation"],
                    applicationSupportBaseURL: fixture.applicationSupportURL,
                    homeDirectoryURL: fixture.rootURL
                )
            )
        }
    }

    func testDMGValidationRejectsDuplicateKeysAndNoncanonicalRequestBytes() throws {
        let duplicateFixture = try makeFixture(named: "duplicate-key")
        let duplicateRequestURL = duplicateFixture.runtimeEvidenceURL
            .appendingPathComponent(MainWindowIdentityPublisher.requestFileName)
        let duplicateJSON = "{\"launch_token\":\"\(launchToken)\","
            + "\"profile\":\"dmg-validation\",\"schema_version\":1,"
            + "\"schema_version\":1}"
        try writeOwnerOnlyData(Data(duplicateJSON.utf8), to: duplicateRequestURL)
        XCTAssertThrowsError(
            try MainWindowIdentityPublisher.prepare(
                profile: .dmgValidation,
                bundleIdentifier: NoonmarkRuntimeProfile.dmgValidation.bundleIdentifier,
                processArguments: ["NoonmarkMacAppDMGValidation"],
                applicationSupportBaseURL: duplicateFixture.applicationSupportURL,
                homeDirectoryURL: duplicateFixture.rootURL
            )
        )

        let whitespaceFixture = try makeFixture(named: "noncanonical-whitespace")
        let whitespaceRequestURL = whitespaceFixture.runtimeEvidenceURL
            .appendingPathComponent(MainWindowIdentityPublisher.requestFileName)
        let whitespaceJSON = " {\"launch_token\":\"\(launchToken)\","
            + "\"profile\":\"dmg-validation\",\"schema_version\":1}\n"
        try writeOwnerOnlyData(Data(whitespaceJSON.utf8), to: whitespaceRequestURL)
        XCTAssertThrowsError(
            try MainWindowIdentityPublisher.prepare(
                profile: .dmgValidation,
                bundleIdentifier: NoonmarkRuntimeProfile.dmgValidation.bundleIdentifier,
                processArguments: ["NoonmarkMacAppDMGValidation"],
                applicationSupportBaseURL: whitespaceFixture.applicationSupportURL,
                homeDirectoryURL: whitespaceFixture.rootURL
            )
        )
    }

    func testDMGValidationRejectsNoncanonicalTokensAndNeverFollowsRequestSymlinks() throws {
        for invalidToken in [
            launchToken.lowercased(),
            "6A6678CF-8ED9-4451-BE2B-299D1B165C1",
            "6A6678CF-8ED9-4451-BE2B-299D1B165C18\n"
        ] {
            let fixture = try makeFixture(named: UUID().uuidString)
            let requestURL = fixture.runtimeEvidenceURL
                .appendingPathComponent(MainWindowIdentityPublisher.requestFileName)
            try writeOwnerOnly(
                [
                    "schema_version": 1,
                    "profile": "dmg-validation",
                    "launch_token": invalidToken
                ],
                to: requestURL
            )
            XCTAssertThrowsError(
                try MainWindowIdentityPublisher.prepare(
                    profile: .dmgValidation,
                    bundleIdentifier: NoonmarkRuntimeProfile.dmgValidation.bundleIdentifier,
                    processArguments: ["NoonmarkMacAppDMGValidation"],
                    applicationSupportBaseURL: fixture.applicationSupportURL,
                    homeDirectoryURL: fixture.rootURL
                )
            )
        }

        let fixture = try makeFixture(named: "symlink")
        let externalRequestURL = fixture.rootURL
            .appendingPathComponent("external-request.json")
        try writeOwnerOnly(
            [
                "schema_version": 1,
                "profile": "dmg-validation",
                "launch_token": launchToken
            ],
            to: externalRequestURL
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.runtimeEvidenceURL
                .appendingPathComponent(MainWindowIdentityPublisher.requestFileName),
            withDestinationURL: externalRequestURL
        )
        XCTAssertThrowsError(
            try MainWindowIdentityPublisher.prepare(
                profile: .dmgValidation,
                bundleIdentifier: NoonmarkRuntimeProfile.dmgValidation.bundleIdentifier,
                processArguments: ["NoonmarkMacAppDMGValidation"],
                applicationSupportBaseURL: fixture.applicationSupportURL,
                homeDirectoryURL: fixture.rootURL
            )
        )
    }

    func testE2ERejectsExactAndDescendantProductionDestinationsWithoutWriting() throws {
        let fixture = try makeFixture(named: "production-destination")
        let productionRoot = NoonmarkRuntimeProfile.production
            .applicationSupportRootURL(baseURL: fixture.applicationSupportURL)
        try FileManager.default.createDirectory(
            at: productionRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(chmod(productionRoot.path, 0o700), 0)

        let rejectedURLs = [
            productionRoot,
            productionRoot.appendingPathComponent(
                MainWindowIdentityPublisher.identityFileName
            ),
            productionRoot.appendingPathComponent(
                "RuntimeEvidence/\(MainWindowIdentityPublisher.identityFileName)"
            )
        ]
        for rejectedURL in rejectedURLs {
            let existedBefore = FileManager.default.fileExists(
                atPath: rejectedURL.path
            )
            XCTAssertThrowsError(
                try MainWindowIdentityPublisher.prepare(
                    profile: .e2e,
                    bundleIdentifier: NoonmarkRuntimeProfile.e2e.bundleIdentifier,
                    processArguments: [
                        "NoonmarkMacAppE2E",
                        MainWindowIdentityPublisher.e2eIdentityURLArgument,
                        rejectedURL.path,
                        MainWindowIdentityPublisher.e2eLaunchTokenArgument,
                        launchToken
                    ],
                    applicationSupportBaseURL: fixture.applicationSupportURL,
                    homeDirectoryURL: fixture.rootURL
                ),
                "expected production destination rejection: \(rejectedURL.path)"
            )
            XCTAssertEqual(
                FileManager.default.fileExists(atPath: rejectedURL.path),
                existedBefore
            )
        }
    }

    func testE2ENeverFollowsAnIdentityDestinationSymlinkAncestor() throws {
        let fixture = try makeFixture(named: "e2e-symlink-ancestor")
        let externalDirectory = fixture.rootURL.appendingPathComponent(
            "external-evidence",
            isDirectory: true
        )
        let aliasDirectory = fixture.rootURL.appendingPathComponent(
            "evidence-alias",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: externalDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(chmod(externalDirectory.path, 0o700), 0)
        try FileManager.default.createSymbolicLink(
            at: aliasDirectory,
            withDestinationURL: externalDirectory
        )
        let identityURL = aliasDirectory.appendingPathComponent(
            MainWindowIdentityPublisher.identityFileName
        )

        XCTAssertThrowsError(
            try MainWindowIdentityPublisher.prepare(
                profile: .e2e,
                bundleIdentifier: NoonmarkRuntimeProfile.e2e.bundleIdentifier,
                processArguments: [
                    "NoonmarkMacAppE2E",
                    MainWindowIdentityPublisher.e2eIdentityURLArgument,
                    identityURL.path,
                    MainWindowIdentityPublisher.e2eLaunchTokenArgument,
                    launchToken
                ],
                applicationSupportBaseURL: fixture.applicationSupportURL,
                homeDirectoryURL: fixture.rootURL
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: externalDirectory.appendingPathComponent(
                    MainWindowIdentityPublisher.identityFileName
                ).path
            )
        )
    }

    func testDMGValidationRejectsSameInodeRequestMutationBetweenIdentityAndOpen() throws {
        let fixture = try makeFixture(named: "same-inode-mutation")
        let requestURL = fixture.runtimeEvidenceURL
            .appendingPathComponent(MainWindowIdentityPublisher.requestFileName)
        try writeOwnerOnly(
            [
                "schema_version": 1,
                "profile": "dmg-validation",
                "launch_token": launchToken
            ],
            to: requestURL
        )
        let replacementToken = "14B2D2B9-0FBF-4B7B-9944-A8D18B5A2D6B"
        let replacementData = try JSONSerialization.data(
            withJSONObject: [
                "schema_version": 1,
                "profile": "dmg-validation",
                "launch_token": replacementToken
            ],
            options: [.sortedKeys]
        )
        XCTAssertEqual(
            replacementData.count,
            try Data(contentsOf: requestURL).count
        )

        XCTAssertThrowsError(
            try MainWindowIdentityPublisher.prepare(
                .init(
                    profile: .dmgValidation,
                    bundleIdentifier: NoonmarkRuntimeProfile.dmgValidation
                        .bundleIdentifier,
                    processArguments: ["NoonmarkMacAppDMGValidation"],
                    applicationSupportBaseURL:
                        fixture.applicationSupportURL,
                    homeDirectoryURL: fixture.rootURL
                ),
                requestIdentityCapturedHook: {
                    usleep(2000)
                    let handle = try FileHandle(forWritingTo: requestURL)
                    try handle.write(contentsOf: replacementData)
                    try handle.synchronize()
                    try handle.close()
                }
            )
        )
    }

    private struct Fixture {
        let rootURL: URL
        let applicationSupportURL: URL
        let runtimeEvidenceURL: URL
    }

    private func makeFixture(named name: String) throws -> Fixture {
        let rootURL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
                "noonmark-main-window-identity-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
        let applicationSupportURL = rootURL
            .appendingPathComponent("Application Support", isDirectory: true)
        let profileURL = applicationSupportURL.appendingPathComponent(
            NoonmarkRuntimeProfile.dmgValidation.applicationSupportDirectoryName,
            isDirectory: true
        )
        let runtimeEvidenceURL = profileURL.appendingPathComponent(
            MainWindowIdentityPublisher.runtimeEvidenceDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: runtimeEvidenceURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(chmod(runtimeEvidenceURL.path, 0o700), 0)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: rootURL)
        }
        return Fixture(
            rootURL: rootURL,
            applicationSupportURL: applicationSupportURL,
            runtimeEvidenceURL: runtimeEvidenceURL
        )
    }

    private func writeOwnerOnly(
        _ object: [String: Any],
        to url: URL
    ) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        try writeOwnerOnlyData(data, to: url)
    }

    private func writeOwnerOnlyData(_ data: Data, to url: URL) throws {
        try data.write(to: url)
        XCTAssertEqual(chmod(url.path, 0o600), 0)
    }

    private func exactJSONObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func assertOwnerOnlyRegularFile(at url: URL) throws {
        var information = stat()
        XCTAssertEqual(lstat(url.path, &information), 0)
        XCTAssertEqual(information.st_mode & mode_t(S_IFMT), mode_t(S_IFREG))
        XCTAssertEqual(information.st_uid, geteuid())
        XCTAssertEqual(information.st_nlink, 1)
        XCTAssertEqual(information.st_mode & mode_t(0o777), mode_t(0o600))
    }
}
