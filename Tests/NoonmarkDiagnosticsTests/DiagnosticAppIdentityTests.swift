import XCTest
@testable import NoonmarkDiagnostics

final class DiagnosticAppIdentityTests: XCTestCase {
    func testCanonicalizesReleaseIdentityWithoutLosingUniversalBinarySlices() {
        let armUUID = "00000000-0000-0000-0000-000000000001"
        let intelUUID = "00000000-0000-0000-0000-000000000002"
        let identity = DiagnosticAppIdentity(
            version: "1.2.3",
            build: "45",
            commitSHA: String(repeating: "A", count: 40),
            buildDate: "2026-07-31T22:30:00Z",
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
        XCTAssertNil(identity.darwinVersion)
        XCTAssertNil(identity.binarySHA256Scope)
    }
}
