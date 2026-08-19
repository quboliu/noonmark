@testable import NoonmarkSync
import CryptoKit
import Darwin
import XCTest

final class ReplicationRepositoryBootstrapTests: XCTestCase {
    func testNonemptyLegacyRepositoryIsRejectedWithoutChangingInventory()
        throws
    {
        let root = makeRepositoryURL()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let legacy = root.appendingPathComponent("heads.json")
        try Data("legacy-v1".utf8).write(to: legacy)
        let before = try inventory(root)

        XCTAssertThrowsError(
            try FileReplicationRepositoryBootstrap.openOrCreate(
                at: root
            )
        ) { error in
            XCTAssertEqual(
                error as? ReplicationRepositoryBootstrapError,
                .legacyRepositoryRequiresManualReset
            )
        }

        XCTAssertEqual(try inventory(root), before)
    }

    func testEmptyRepositoryCreatesOneCanonicalMarkerAndReopensExactly()
        throws
    {
        let root = makeRepositoryURL()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let generationID = UUID(
            uuidString: "91000000-0000-0000-0000-000000000001"
        )!

        let creation = try FileReplicationRepositoryBootstrap.openOrCreateWithStatus(
            at: root,
            generationID: { generationID }
        )
        let created = creation.descriptor
        let afterCreate = try inventory(root)
        let reopening = try FileReplicationRepositoryBootstrap.openOrCreateWithStatus(
            at: root,
            generationID: {
                XCTFail("an existing marker must own the generation")
                return UUID()
            }
        )
        let reopened = reopening.descriptor

        XCTAssertEqual(
            created,
            ReplicationRepositoryDescriptor(
                formatVersion: 1,
                generationID: generationID
            )
        )
        XCTAssertEqual(reopened, created)
        XCTAssertTrue(creation.createdRepository)
        XCTAssertFalse(reopening.createdRepository)
        XCTAssertEqual(try inventory(root), afterCreate)
        XCTAssertEqual(
            afterCreate.map(\.relativePath),
            [FileReplicationRepositoryBootstrap.markerFilename, "v2"]
        )
    }

    func testConcurrentInitializationAdoptsTheSingleWinningMarker()
        async throws
    {
        let root = makeRepositoryURL()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let first = UUID(
            uuidString: "92000000-0000-0000-0000-000000000001"
        )!
        let second = UUID(
            uuidString: "92000000-0000-0000-0000-000000000002"
        )!

        async let left = Task.detached {
            try FileReplicationRepositoryBootstrap.openOrCreate(
                at: root,
                generationID: { first }
            )
        }.value
        async let right = Task.detached {
            try FileReplicationRepositoryBootstrap.openOrCreate(
                at: root,
                generationID: { second }
            )
        }.value
        let results = try await [left, right]

        XCTAssertEqual(results[0], results[1])
        XCTAssertTrue([first, second].contains(results[0].generationID))
        XCTAssertEqual(
            try inventory(root).map(\.relativePath),
            [FileReplicationRepositoryBootstrap.markerFilename, "v2"]
        )
    }

    func testBootstrapWaitsForActiveMarkerPublicationBeforeInspectingTree()
        async throws
    {
        let root = makeRepositoryURL()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let rootDescriptor = open(
            root.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        )
        XCTAssertGreaterThanOrEqual(rootDescriptor, 0)
        guard rootDescriptor >= 0 else {
            return
        }
        defer {
            close(rootDescriptor)
        }

        var lockResult: Int32
        repeat {
            lockResult = flock(rootDescriptor, LOCK_EX)
        } while lockResult != 0 && errno == EINTR
        XCTAssertEqual(lockResult, 0)
        guard lockResult == 0 else {
            return
        }
        var rootIsLocked = true
        defer {
            if rootIsLocked {
                _ = flock(rootDescriptor, LOCK_UN)
            }
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(
                "v2/staging/markers",
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )
        let winnerID = UUID(
            uuidString: "92000000-0000-0000-0000-000000000004"
        )!
        let losingID = UUID(
            uuidString: "92000000-0000-0000-0000-000000000005"
        )!
        let markerData = try ReplicationPublicationBuilder
            .canonicalEncoder().encode(
                ReplicationRepositoryDescriptor(
                    formatVersion: FileReplicationRepositoryBootstrap
                        .formatVersion,
                    generationID: winnerID
                )
            )
        let lockAttempted = DispatchSemaphore(value: 0)
        let opener = Task.detached {
            try FileReplicationRepositoryBootstrap.openOrCreateWithStatus(
                at: root,
                generationID: { losingID },
                markerWriteByteLimitForTesting: nil,
                bootstrapLockAttemptForTesting: {
                    lockAttempted.signal()
                }
            ).descriptor
        }
        XCTAssertEqual(lockAttempted.wait(timeout: .now() + 2), .success)

        let publicationResult = try AppendOnlyFilePublisher(
            rootURL: root
        ).publish(
            markerData,
            to: FileReplicationRepositoryBootstrap.markerFilename,
            stagingArea: "markers"
        )
        XCTAssertEqual(flock(rootDescriptor, LOCK_UN), 0)
        rootIsLocked = false
        let opened = try await opener.value

        XCTAssertEqual(publicationResult, .published)
        XCTAssertEqual(opened.generationID, winnerID)
        XCTAssertEqual(
            try inventory(root).map(\.relativePath),
            [FileReplicationRepositoryBootstrap.markerFilename, "v2"]
        )
    }

    func testInterruptedMarkerWriteLeavesFinalAbsentAndRetryFailsClosed()
        throws
    {
        let root = makeRepositoryURL()
        let generationID = UUID(
            uuidString: "92000000-0000-0000-0000-000000000003"
        )!
        XCTAssertThrowsError(
            try FileReplicationRepositoryBootstrap.openOrCreateWithStatus(
                at: root,
                generationID: { generationID },
                markerWriteByteLimitForTesting: 5
            )
        ) { error in
            XCTAssertEqual(
                error as? ReplicationRepositoryBootstrapError,
                .cannotCreateMarker
            )
        }
        let marker = root.appendingPathComponent(
            FileReplicationRepositoryBootstrap.markerFilename
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let interruptedStages = try regularFiles(
            in: root.appendingPathComponent("v2/staging/markers")
        )
        XCTAssertEqual(interruptedStages.count, 1)
        XCTAssertEqual(try Data(contentsOf: interruptedStages[0]).count, 5)

        let inventoryBeforeRetry = try inventory(root)
        XCTAssertThrowsError(
            try FileReplicationRepositoryBootstrap.openOrCreateWithStatus(
                at: root,
                generationID: { generationID }
            )
        ) { error in
            XCTAssertEqual(
                error as? ReplicationRepositoryBootstrapError,
                .markerPublicationInProgress
            )
        }
        XCTAssertEqual(try Data(contentsOf: interruptedStages[0]).count, 5)
        XCTAssertEqual(try inventory(root), inventoryBeforeRetry)
    }

    func testExactRemoteMarkerStageCanFinishTheSameBootstrap() throws {
        let root = makeRepositoryURL()
        let generationID = UUID(
            uuidString: "92000000-0000-0000-0000-000000000006"
        )!
        let markerData = try canonicalMarkerData(generationID: generationID)
        let stage = try markerStageURL(root: root)
        try markerData.write(to: stage, options: [.withoutOverwriting])

        let result = try FileReplicationRepositoryBootstrap
            .openOrCreateWithStatus(
                at: root,
                generationID: { generationID }
            )

        XCTAssertEqual(result.descriptor.generationID, generationID)
        XCTAssertTrue(result.createdRepository)
        XCTAssertEqual(
            try Data(
                contentsOf: root.appendingPathComponent(
                    FileReplicationRepositoryBootstrap.markerFilename
                )
            ),
            markerData
        )
        XCTAssertEqual(try Data(contentsOf: stage), markerData)
    }

    func testPartialRemoteMarkerStageReportsInProgressWithoutWriting()
        throws
    {
        let root = makeRepositoryURL()
        let generationID = UUID(
            uuidString: "92000000-0000-0000-0000-000000000007"
        )!
        let stage = try markerStageURL(root: root)
        try canonicalMarkerData(generationID: generationID).prefix(5)
            .write(to: stage, options: [.withoutOverwriting])
        let before = try inventory(root)

        XCTAssertThrowsError(
            try FileReplicationRepositoryBootstrap.openOrCreate(
                at: root,
                generationID: { generationID }
            )
        ) { error in
            XCTAssertEqual(
                error as? ReplicationRepositoryBootstrapError,
                .markerPublicationInProgress
            )
        }

        XCTAssertEqual(try inventory(root), before)
    }

    func testDivergentRemoteMarkerStageFailsClosedWithoutWriting() throws {
        let root = makeRepositoryURL()
        let proposedGenerationID = UUID(
            uuidString: "92000000-0000-0000-0000-000000000008"
        )!
        let divergentGenerationID = UUID(
            uuidString: "92000000-0000-0000-0000-000000000009"
        )!
        let stage = try markerStageURL(root: root)
        try canonicalMarkerData(generationID: divergentGenerationID)
            .write(to: stage, options: [.withoutOverwriting])
        let before = try inventory(root)

        XCTAssertThrowsError(
            try FileReplicationRepositoryBootstrap.openOrCreate(
                at: root,
                generationID: { proposedGenerationID }
            )
        ) { error in
            XCTAssertEqual(
                error as? ReplicationRepositoryBootstrapError,
                .legacyRepositoryRequiresManualReset
            )
        }

        XCTAssertEqual(try inventory(root), before)
    }

    func testMalformedMarkerFailsClosedWithoutRepairOrReplacement() throws {
        let root = makeRepositoryURL()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let marker = root.appendingPathComponent(
            FileReplicationRepositoryBootstrap.markerFilename
        )
        try Data("{\"formatVersion\":1}".utf8).write(to: marker)
        let before = try inventory(root)

        XCTAssertThrowsError(
            try FileReplicationRepositoryBootstrap.openOrCreate(at: root)
        ) { error in
            XCTAssertEqual(
                error as? ReplicationRepositoryBootstrapError,
                .invalidMarker
            )
        }

        XCTAssertEqual(try inventory(root), before)
    }

    func testMarkedRepositoryRejectsUnknownNestedObjectWithoutWriting() throws {
        let root = makeRepositoryURL()
        _ = try FileReplicationRepositoryBootstrap.openOrCreate(at: root)
        let unknownParent = root.appendingPathComponent(
            "v2/objects/chunk",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: unknownParent,
            withIntermediateDirectories: true
        )
        let unknown = unknownParent.appendingPathComponent("legacy.bin")
        try Data("legacy".utf8).write(to: unknown)
        let before = try Data(contentsOf: unknown)

        XCTAssertThrowsError(
            try FileReplicationRepositoryBootstrap.openOrCreate(at: root)
        ) { error in
            XCTAssertEqual(
                error as? ReplicationRepositoryBootstrapError,
                .legacyRepositoryRequiresManualReset
            )
        }

        XCTAssertEqual(try Data(contentsOf: unknown), before)
    }

    func testMarkedRepositoryRejectsNestedSymlinkWithoutTouchingItsTarget() throws {
        let root = makeRepositoryURL()
        _ = try FileReplicationRepositoryBootstrap.openOrCreate(at: root)
        let target = makeRepositoryURL()
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true
        )
        let sentinel = target.appendingPathComponent("sentinel")
        try Data("existing".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("v2/objects"),
            withDestinationURL: target
        )

        XCTAssertThrowsError(
            try FileReplicationRepositoryBootstrap.openOrCreate(at: root)
        ) { error in
            XCTAssertEqual(
                error as? ReplicationRepositoryBootstrapError,
                .legacyRepositoryRequiresManualReset
            )
        }

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: target.path),
            ["sentinel"]
        )
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("existing".utf8))
    }

    func testMarkedRepositoryRejectsDanglingNestedSymlinkWithoutWriting() throws {
        let root = makeRepositoryURL()
        _ = try FileReplicationRepositoryBootstrap.openOrCreate(at: root)
        let missingTarget = root.deletingLastPathComponent()
            .appendingPathComponent("missing-\(UUID().uuidString)")
        let link = root.appendingPathComponent("v2/objects")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: missingTarget
        )

        XCTAssertThrowsError(
            try FileReplicationRepositoryBootstrap.openOrCreate(at: root)
        ) { error in
            XCTAssertEqual(
                error as? ReplicationRepositoryBootstrapError,
                .legacyRepositoryRequiresManualReset
            )
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path) == false)
        var information = stat()
        XCTAssertEqual(lstat(link.path, &information), 0)
        XCTAssertEqual(information.st_mode & mode_t(S_IFMT), mode_t(S_IFLNK))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingTarget.path))
    }
}

private extension ReplicationRepositoryBootstrapTests {
    struct InventoryEntry: Equatable {
        let relativePath: String
        let byteCount: Int
        let digest: String
    }

    func makeRepositoryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "noonmark-replication-bootstrap-tests-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    func inventory(_ root: URL) throws -> [InventoryEntry] {
        guard FileManager.default.fileExists(atPath: root.path) else {
            return []
        }
        let children = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        )
        return try children.sorted { $0.path < $1.path }.map { url in
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey]
            )
            let data = values.isRegularFile == true
                ? try Data(contentsOf: url)
                : Data()
            return InventoryEntry(
                relativePath: url.lastPathComponent,
                byteCount: data.count,
                digest: SHA256.hash(data: data).map {
                    String(format: "%02x", $0)
                }.joined()
            )
        }
    }

    func regularFiles(in root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        return try enumerator.compactMap { item in
            guard let url = item as? URL else { return nil }
            return try url.resourceValues(forKeys: [.isRegularFileKey])
                .isRegularFile == true ? url : nil
        }
    }

    func canonicalMarkerData(generationID: UUID) throws -> Data {
        try ReplicationPublicationBuilder.canonicalEncoder().encode(
            ReplicationRepositoryDescriptor(
                formatVersion: FileReplicationRepositoryBootstrap
                    .formatVersion,
                generationID: generationID
            )
        )
    }

    func markerStageURL(root: URL) throws -> URL {
        let markers = root.appendingPathComponent(
            "v2/staging/markers",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: markers,
            withIntermediateDirectories: true
        )
        return markers.appendingPathComponent(
            "93000000-0000-0000-0000-000000000001.stage"
        )
    }
}
