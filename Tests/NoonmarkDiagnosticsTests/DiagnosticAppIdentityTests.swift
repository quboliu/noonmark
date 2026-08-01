@testable import NoonmarkDiagnostics
import XCTest

final class DiagnosticAppIdentityTests: XCTestCase {
    func testVersionInformationTextUsesStableEvidenceOrder() {
        let armUUID = "00000000-0000-0000-0000-000000000001"
        let intelUUID = "00000000-0000-0000-0000-000000000002"
        let identity = DiagnosticAppIdentity(
            version: "0.1.0",
            build: "1",
            commitSHA: String(repeating: "a", count: 40),
            buildDate: "2026-07-31T14:15:16Z",
            runtime: "Swift-native",
            minimumOSVersion: "14.0",
            buildArchitecture: "Universal",
            operatingSystemMajorVersion: 15,
            operatingSystemMinorVersion: 6,
            operatingSystemPatchVersion: 1,
            darwinVersion: "25.6.0",
            architecture: "arm64",
            binaryUUID: "x86_64:\(intelUUID),arm64:\(armUUID)",
            binarySHA256: String(repeating: "b", count: 64),
            binarySHA256Scope: .linkedBeforeBundleSigning
        )

        XCTAssertEqual(
            identity.versionInformationText,
            """
            Version: 0.1.0 (1) [Universal]
            Commit: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            Date: 2026-07-31T14:15:16Z
            Runtime: Swift-native
            Minimum OS: macOS 14.0
            Mach-O UUID: arm64:00000000-0000-0000-0000-000000000001,x86_64:00000000-0000-0000-0000-000000000002
            Binary SHA256: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
            Binary SHA256 Scope: linked-before-bundle-signing
            OS: Darwin 25.6.0 (arm64)
            Diagnostics: schema 1, redaction 1
            """
        )
    }

    func testVersionInformationMakesMissingEvidenceExplicit() {
        let identity = DiagnosticAppIdentity(
            version: "0.1.0",
            build: "1",
            buildArchitecture: "",
            operatingSystemMajorVersion: 15,
            operatingSystemMinorVersion: 6,
            architecture: "arm64"
        )

        XCTAssertEqual(
            identity.versionInformationText,
            """
            Version: 0.1.0 (1) [unknown]
            Commit: unknown
            Date: unknown
            Runtime: unknown
            Minimum OS: unknown
            Mach-O UUID: unknown
            Binary SHA256: unknown
            Binary SHA256 Scope: unknown
            OS: Darwin unknown (arm64)
            Diagnostics: schema 1, redaction 1
            """
        )
    }

    func testCanonicalizesReleaseIdentityWithoutLosingUniversalBinarySlices() {
        let armUUID = "00000000-0000-0000-0000-000000000001"
        let intelUUID = "00000000-0000-0000-0000-000000000002"
        let identity = DiagnosticAppIdentity(
            version: "1.2.3",
            build: "45",
            commitSHA: String(repeating: "A", count: 40),
            buildDate: "2026-07-31T22:30:00Z",
            runtime: "Swift-native",
            minimumOSVersion: "14.0",
            buildArchitecture: "Universal",
            operatingSystemMajorVersion: 15,
            operatingSystemMinorVersion: 6,
            operatingSystemPatchVersion: 1,
            darwinVersion: "24.6.0",
            architecture: "arm64",
            binaryUUID: "x86_64:\(intelUUID),arm64:\(armUUID)",
            binarySHA256: String(repeating: "B", count: 64),
            binarySHA256Scope: .linkedBeforeBundleSigning
        )

        XCTAssertEqual(identity.commitSHA, String(repeating: "a", count: 40))
        XCTAssertEqual(identity.buildDate, "2026-07-31T22:30:00Z")
        XCTAssertEqual(identity.runtime, "Swift-native")
        XCTAssertEqual(identity.minimumOSVersion, "14.0")
        XCTAssertEqual(identity.buildArchitecture, "Universal")
        XCTAssertEqual(identity.operatingSystemPatchVersion, 1)
        XCTAssertEqual(identity.darwinVersion, "24.6.0")
        XCTAssertEqual(
            identity.binaryUUID,
            "arm64:\(armUUID),x86_64:\(intelUUID)"
        )
        XCTAssertEqual(
            identity.binarySHA256,
            String(repeating: "b", count: 64)
        )
        XCTAssertEqual(
            identity.binarySHA256Scope,
            .linkedBeforeBundleSigning
        )
    }

    func testRejectsAmbiguousOrUnverifiableReleaseIdentityFields() {
        let uuid = "00000000-0000-0000-0000-000000000001"
        let identity = DiagnosticAppIdentity(
            version: "1.2.3",
            build: "45",
            commitSHA: "not-a-full-commit",
            buildDate: "2026-99-99",
            runtime: "Electron 42",
            minimumOSVersion: "/Users/private/minimum",
            buildArchitecture: "Universal",
            operatingSystemMajorVersion: 15,
            operatingSystemMinorVersion: 6,
            operatingSystemPatchVersion: 0,
            darwinVersion: "/Users/private/kernel",
            architecture: "arm64",
            binaryUUID: "arm64:\(uuid),arm64:\(uuid)",
            binarySHA256: "not-a-sha",
            binarySHA256Scope: .linkedBeforeBundleSigning
        )

        XCTAssertNil(identity.commitSHA)
        XCTAssertNil(identity.buildDate)
        XCTAssertNil(identity.runtime)
        XCTAssertNil(identity.minimumOSVersion)
        XCTAssertNil(identity.darwinVersion)
        XCTAssertNil(identity.binaryUUID)
        XCTAssertNil(identity.binarySHA256)
    }

    func testDecodesLegacyIdentityWithoutInventingReleaseEvidence() throws {
        let data = Data(
            #"{"architecture":"arm64","binarySHA256":null,"binaryUUID":null,"build":"1","operatingSystemMajorVersion":14,"operatingSystemMinorVersion":0,"version":"0.1.0"}"#.utf8
        )

        let identity = try JSONDecoder().decode(
            DiagnosticAppIdentity.self,
            from: data
        )

        XCTAssertEqual(identity.version, "0.1.0")
        XCTAssertEqual(identity.build, "1")
        XCTAssertEqual(identity.buildArchitecture, "arm64")
        XCTAssertEqual(identity.operatingSystemPatchVersion, 0)
        XCTAssertNil(identity.commitSHA)
        XCTAssertNil(identity.buildDate)
        XCTAssertNil(identity.runtime)
        XCTAssertNil(identity.minimumOSVersion)
        XCTAssertNil(identity.darwinVersion)
        XCTAssertNil(identity.binarySHA256Scope)
    }
}
