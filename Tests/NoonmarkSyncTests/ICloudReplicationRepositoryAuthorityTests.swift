@testable import NoonmarkSync
import XCTest

final class ICloudReplicationRepositoryAuthorityTests: XCTestCase {
    func testIndependentMirrorsDeriveOneCanonicalGenerationAndMarker()
        throws
    {
        let scope = "Noonmark/SyncRepository"
        let firstGeneration = try ICloudReplicationRepositoryAuthority
            .generationID(for: scope)
        let secondGeneration = try ICloudReplicationRepositoryAuthority
            .generationID(for: scope)
        let otherProfileGeneration = try ICloudReplicationRepositoryAuthority
            .generationID(for: "Noonmark-E2E/SyncRepository")
        let firstRoot = makeRepositoryURL()
        let secondRoot = makeRepositoryURL()

        let first = try FileReplicationRepositoryBootstrap
            .openOrCreateWithStatus(
                at: firstRoot,
                generationID: { firstGeneration }
            )
        let second = try FileReplicationRepositoryBootstrap
            .openOrCreateWithStatus(
                at: secondRoot,
                generationID: { secondGeneration }
            )
        let firstMarker = try Data(
            contentsOf: firstRoot.appendingPathComponent(
                FileReplicationRepositoryBootstrap.markerFilename
            )
        )
        let secondMarker = try Data(
            contentsOf: secondRoot.appendingPathComponent(
                FileReplicationRepositoryBootstrap.markerFilename
            )
        )

        XCTAssertEqual(firstGeneration, secondGeneration)
        XCTAssertEqual(
            firstGeneration.uuidString,
            "BF18A4AA-4BAC-8313-B38D-9C64AFF32B74"
        )
        XCTAssertNotEqual(firstGeneration, otherProfileGeneration)
        XCTAssertEqual(first.descriptor, second.descriptor)
        XCTAssertEqual(firstMarker, secondMarker)
    }

    func testExistingLocalAuthorityRemainsThePreferredGeneration() throws {
        let existing = UUID(
            uuidString: "97000000-0000-0000-0000-000000000003"
        )!

        XCTAssertEqual(
            try ICloudReplicationRepositoryAuthority.generationID(
                for: "Noonmark/SyncRepository",
                preferred: existing
            ),
            existing
        )
    }

    func testPreferredGenerationDoesNotBypassRepositoryScopeValidation() {
        let existing = UUID(
            uuidString: "97000000-0000-0000-0000-000000000003"
        )!

        XCTAssertThrowsError(
            try ICloudReplicationRepositoryAuthority.generationID(
                for: "",
                preferred: existing
            )
        ) { error in
            XCTAssertEqual(
                error as? ICloudReplicationRepositoryAuthorityError,
                .invalidRepositoryScope
            )
        }
    }

    func testExactMarkerConflictVersionsRemainOneAuthority() throws {
        let marker = try markerData(
            generationID: UUID(
                uuidString: "97000000-0000-0000-0000-000000000001"
            )!
        )

        XCTAssertNoThrow(
            try ICloudReplicationRepositoryAuthority.validateMarkerVersions(
                current: marker,
                conflicts: [marker, marker]
            )
        )
    }

    func testDivergentMarkerConflictVersionFailsClosed() throws {
        let current = try markerData(
            generationID: UUID(
                uuidString: "97000000-0000-0000-0000-000000000001"
            )!
        )
        let conflict = try markerData(
            generationID: UUID(
                uuidString: "97000000-0000-0000-0000-000000000002"
            )!
        )

        XCTAssertThrowsError(
            try ICloudReplicationRepositoryAuthority.validateMarkerVersions(
                current: current,
                conflicts: [conflict]
            )
        ) { error in
            XCTAssertEqual(
                error as? ICloudReplicationRepositoryAuthorityError,
                .divergentMarkerVersion
            )
        }
    }

    func testDivergentNonlocalMarkerVersionFailsClosed() async throws {
        let currentID = UUID(
            uuidString: "97000000-0000-0000-0000-000000000001"
        )!
        let current = try markerData(generationID: currentID)
        let nonlocal = try markerData(
            generationID: UUID(
                uuidString: "97000000-0000-0000-0000-000000000002"
            )!
        )
        let root = makeRepositoryURL()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let markerURL = root.appendingPathComponent(
            FileReplicationRepositoryBootstrap.markerFilename
        )
        try current.write(to: markerURL, options: [.withoutOverwriting])

        do {
            try await ICloudReplicationRepositoryAuthority
                .validateMarkerVersions(
                    at: markerURL,
                    expected: ReplicationRepositoryDescriptor(
                        formatVersion: FileReplicationRepositoryBootstrap
                            .formatVersion,
                        generationID: currentID
                    ),
                    nonlocalVersionData: { _ in [nonlocal] }
                )
            XCTFail("a divergent non-local marker must fail closed")
        } catch {
            XCTAssertEqual(
                error as? ICloudReplicationRepositoryAuthorityError,
                .divergentMarkerVersion
            )
        }
    }

    private func markerData(generationID: UUID) throws -> Data {
        try ReplicationPublicationBuilder.canonicalEncoder().encode(
            ReplicationRepositoryDescriptor(
                formatVersion: FileReplicationRepositoryBootstrap
                    .formatVersion,
                generationID: generationID
            )
        )
    }

    private func makeRepositoryURL() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "noonmark-icloud-authority-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
