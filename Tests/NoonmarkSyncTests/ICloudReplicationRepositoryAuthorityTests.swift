@testable import NoonmarkSync
import XCTest

final class ICloudReplicationRepositoryAuthorityTests: XCTestCase {
    func testIndependentMirrorsDeriveOneCanonicalGenerationAndMarker()
        throws
    {
        let scope = "Noonmark/SyncRepository"
        let firstRoot = makeRepositoryURL()
        let secondRoot = makeRepositoryURL()
        let first = try ICloudReplicationRepositoryAuthority.openRepository(
            at: firstRoot,
            scope: scope,
            existingGenerationID: nil
        )
        let second = try ICloudReplicationRepositoryAuthority.openRepository(
            at: secondRoot,
            scope: scope,
            existingGenerationID: nil
        )
        let otherProfileGeneration = try ICloudReplicationRepositoryAuthority
            .generationID(for: "Noonmark-E2E/SyncRepository")
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

        XCTAssertEqual(first.descriptor, second.descriptor)
        XCTAssertEqual(
            first.descriptor.generationID.uuidString,
            "BF18A4AA-4BAC-8313-B38D-9C64AFF32B74"
        )
        XCTAssertNotEqual(
            first.descriptor.generationID,
            otherProfileGeneration
        )
        XCTAssertEqual(firstMarker, secondMarker)
    }

    func testExistingRandomAuthorityRequiresItsVisibleMarkerWithoutWriting() {
        let existing = UUID(
            uuidString: "97000000-0000-0000-0000-000000000003"
        )!
        let root = makeRepositoryURL()

        XCTAssertThrowsError(
            try ICloudReplicationRepositoryAuthority.openRepository(
                at: root,
                scope: "Noonmark/SyncRepository",
                existingGenerationID: existing
            )
        ) { error in
            XCTAssertEqual(
                error as? ICloudReplicationRepositoryAuthorityError,
                .existingAuthorityMarkerUnavailable
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testExistingRandomAuthorityKeepsAnEmptyMirrorUntouched() throws {
        let existing = UUID(
            uuidString: "97000000-0000-0000-0000-000000000003"
        )!
        let root = makeRepositoryURL()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        XCTAssertThrowsError(
            try ICloudReplicationRepositoryAuthority.openRepository(
                at: root,
                scope: "Noonmark/SyncRepository",
                existingGenerationID: existing
            )
        ) { error in
            XCTAssertEqual(
                error as? ICloudReplicationRepositoryAuthorityError,
                .existingAuthorityMarkerUnavailable
            )
        }
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .isEmpty
        )
    }

    func testExistingRandomAuthorityDoesNotPromoteAVisibleStage() throws {
        let existing = UUID(
            uuidString: "97000000-0000-0000-0000-000000000003"
        )!
        let root = makeRepositoryURL()
        let stage = root.appendingPathComponent(
            "v2/staging/markers/97000000-0000-0000-0000-000000000004.stage"
        )
        try FileManager.default.createDirectory(
            at: stage.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let stageData = try markerData(generationID: existing)
        try stageData.write(to: stage, options: [.withoutOverwriting])

        XCTAssertThrowsError(
            try ICloudReplicationRepositoryAuthority.openRepository(
                at: root,
                scope: "Noonmark/SyncRepository",
                existingGenerationID: existing
            )
        ) { error in
            XCTAssertEqual(
                error as? ICloudReplicationRepositoryAuthorityError,
                .existingAuthorityMarkerUnavailable
            )
        }
        XCTAssertEqual(try Data(contentsOf: stage), stageData)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    FileReplicationRepositoryBootstrap.markerFilename
                ).path
            )
        )
    }

    func testExistingRandomAuthorityAdoptsItsVisibleMarker() throws {
        let existing = UUID(
            uuidString: "97000000-0000-0000-0000-000000000003"
        )!
        let root = makeRepositoryURL()
        _ = try FileReplicationRepositoryBootstrap.openOrCreate(
            at: root,
            generationID: { existing }
        )

        let result = try ICloudReplicationRepositoryAuthority.openRepository(
            at: root,
            scope: "Noonmark/SyncRepository",
            existingGenerationID: existing
        )

        XCTAssertEqual(result.descriptor.generationID, existing)
        XCTAssertFalse(result.createdRepository)
    }

    func testExistingRandomAuthorityRejectsAMarkerDirectoryAsInvalid()
        throws
    {
        let existing = UUID(
            uuidString: "97000000-0000-0000-0000-000000000003"
        )!
        let root = makeRepositoryURL()
        let markerURL = root.appendingPathComponent(
            FileReplicationRepositoryBootstrap.markerFilename,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: markerURL,
            withIntermediateDirectories: true
        )
        let inventoryBefore = try FileManager.default.contentsOfDirectory(
            atPath: root.path
        )

        XCTAssertThrowsError(
            try ICloudReplicationRepositoryAuthority.openRepository(
                at: root,
                scope: "Noonmark/SyncRepository",
                existingGenerationID: existing
            )
        ) { error in
            XCTAssertEqual(
                error as? ReplicationRepositoryBootstrapError,
                .invalidMarker
            )
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path),
            inventoryBefore
        )
    }

    func testExistingDerivedAuthorityCanRecreateAnEmptyRepository() throws {
        let scope = "Noonmark/SyncRepository"
        let existing = try ICloudReplicationRepositoryAuthority.generationID(
            for: scope
        )
        let root = makeRepositoryURL()

        let result = try ICloudReplicationRepositoryAuthority.openRepository(
            at: root,
            scope: scope,
            existingGenerationID: existing
        )

        XCTAssertEqual(result.descriptor.generationID, existing)
        XCTAssertTrue(result.createdRepository)
    }

    func testExistingDerivedAuthorityRejectsADifferentVisibleMarker()
        throws
    {
        let scope = "Noonmark/SyncRepository"
        let existing = try ICloudReplicationRepositoryAuthority.generationID(
            for: scope
        )
        let different = UUID(
            uuidString: "97000000-0000-0000-0000-000000000004"
        )!
        let root = makeRepositoryURL()
        _ = try FileReplicationRepositoryBootstrap.openOrCreate(
            at: root,
            generationID: { different }
        )
        let markerURL = root.appendingPathComponent(
            FileReplicationRepositoryBootstrap.markerFilename
        )
        let markerBefore = try Data(contentsOf: markerURL)

        XCTAssertThrowsError(
            try ICloudReplicationRepositoryAuthority.openRepository(
                at: root,
                scope: scope,
                existingGenerationID: existing
            )
        ) { error in
            XCTAssertEqual(
                error as? ICloudReplicationRepositoryAuthorityError,
                .divergentMarkerVersion
            )
        }
        XCTAssertEqual(try Data(contentsOf: markerURL), markerBefore)
    }

    func testMissingAuthorityRejectsAVisibleRandomMarkerWithoutWriting()
        throws
    {
        let scope = "Noonmark/SyncRepository"
        let randomGenerationID = UUID(
            uuidString: "97000000-0000-0000-0000-000000000005"
        )!
        let root = makeRepositoryURL()
        _ = try FileReplicationRepositoryBootstrap.openOrCreate(
            at: root,
            generationID: { randomGenerationID }
        )
        let markerURL = root.appendingPathComponent(
            FileReplicationRepositoryBootstrap.markerFilename
        )
        let markerBefore = try Data(contentsOf: markerURL)
        let inventoryBefore = try FileManager.default.contentsOfDirectory(
            atPath: root.path
        ).sorted()

        XCTAssertThrowsError(
            try ICloudReplicationRepositoryAuthority.openRepository(
                at: root,
                scope: scope,
                existingGenerationID: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? ICloudReplicationRepositoryAuthorityError,
                .divergentMarkerVersion
            )
        }
        XCTAssertEqual(try Data(contentsOf: markerURL), markerBefore)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .sorted(),
            inventoryBefore
        )
    }

    func testInvalidScopeIsRejectedBeforeRepositoryAccess() {
        let root = makeRepositoryURL()

        for scope in ["", "Noonmark\u{0}SyncRepository"] {
            XCTAssertThrowsError(
                try ICloudReplicationRepositoryAuthority.openRepository(
                    at: root,
                    scope: scope,
                    existingGenerationID: UUID()
                )
            ) { error in
                XCTAssertEqual(
                    error as? ICloudReplicationRepositoryAuthorityError,
                    .invalidRepositoryScope
                )
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
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
        let operation = AuthorityGuardOperationRecorder()
        let session = ICloudMarkerAuthorityObservationSession(
            initialSnapshot: ICloudMarkerVersionSnapshot(
                current: current,
                conflicts: [nonlocal]
            ),
            snapshot: {
                ICloudMarkerVersionSnapshot(current: current, conflicts: [])
            },
            finish: { false }
        )

        do {
            try await ICloudReplicationRepositoryAuthority
                .withValidatedMarkerAuthority(
                    expected: ReplicationRepositoryDescriptor(
                        formatVersion: FileReplicationRepositoryBootstrap
                            .formatVersion,
                        generationID: currentID
                    ),
                    observationSession: session
                ) {
                    await operation.recordRun()
                }
            XCTFail("a divergent non-local marker must fail closed")
        } catch {
            XCTAssertEqual(
                error as? ICloudReplicationRepositoryAuthorityError,
                .divergentMarkerVersion
            )
        }
        let operationDidRun = await operation.didRun()
        XCTAssertFalse(operationDidRun)
    }

    func testAuthorityGuardFailsAfterInventoryChangesDuringOperation()
        async throws
    {
        let marker = try markerData(
            generationID: UUID(
                uuidString: "97000000-0000-0000-0000-000000000001"
            )!
        )
        let operation = AuthorityGuardOperationRecorder()
        let session = ICloudMarkerAuthorityObservationSession(
            initialSnapshot: ICloudMarkerVersionSnapshot(
                current: marker,
                conflicts: []
            ),
            snapshot: {
                ICloudMarkerVersionSnapshot(current: marker, conflicts: [])
            },
            finish: { true }
        )

        do {
            _ = try await ICloudReplicationRepositoryAuthority
                .withValidatedMarkerAuthority(
                    expected: try descriptor(from: marker),
                    observationSession: session
                ) {
                    await operation.recordRun()
                    return 42
                }
            XCTFail("a changed version inventory must fail closed")
        } catch {
            XCTAssertEqual(
                error as? ICloudReplicationRepositoryAuthorityError,
                .divergentMarkerVersion
            )
        }
        let operationDidRun = await operation.didRun()
        XCTAssertTrue(operationDidRun)
    }

    func testAuthorityGuardRejectsMarkerChangedDuringOperation()
        async throws
    {
        let current = try markerData(
            generationID: UUID(
                uuidString: "97000000-0000-0000-0000-000000000001"
            )!
        )
        let changed = try markerData(
            generationID: UUID(
                uuidString: "97000000-0000-0000-0000-000000000002"
            )!
        )
        let session = ICloudMarkerAuthorityObservationSession(
            initialSnapshot: ICloudMarkerVersionSnapshot(
                current: current,
                conflicts: []
            ),
            snapshot: {
                ICloudMarkerVersionSnapshot(current: changed, conflicts: [])
            },
            finish: { false }
        )

        do {
            _ = try await ICloudReplicationRepositoryAuthority
                .withValidatedMarkerAuthority(
                    expected: try descriptor(from: current),
                    observationSession: session
                ) {
                    42
                }
            XCTFail("a changed marker must fail closed")
        } catch {
            XCTAssertEqual(
                error as? ICloudReplicationRepositoryAuthorityError,
                .divergentMarkerVersion
            )
        }
    }

    func testAuthorityGuardReturnsOnlyAfterStablePostValidation()
        async throws
    {
        let marker = try markerData(
            generationID: UUID(
                uuidString: "97000000-0000-0000-0000-000000000001"
            )!
        )
        let session = ICloudMarkerAuthorityObservationSession(
            initialSnapshot: ICloudMarkerVersionSnapshot(
                current: marker,
                conflicts: [marker]
            ),
            snapshot: {
                ICloudMarkerVersionSnapshot(
                    current: marker,
                    conflicts: [marker]
                )
            },
            finish: { false }
        )

        let result = try await ICloudReplicationRepositoryAuthority
            .withValidatedMarkerAuthority(
                expected: try descriptor(from: marker),
                observationSession: session
            ) {
                42
            }

        XCTAssertEqual(result, 42)
    }

    func testAuthorityGuardPostValidatesWhenOperationThrows()
        async throws
    {
        let marker = try markerData(
            generationID: UUID(
                uuidString: "97000000-0000-0000-0000-000000000001"
            )!
        )
        let snapshots = AuthorityGuardSnapshotRecorder()
        let session = ICloudMarkerAuthorityObservationSession(
            initialSnapshot: ICloudMarkerVersionSnapshot(
                current: marker,
                conflicts: []
            ),
            snapshot: {
                snapshots.record()
                return ICloudMarkerVersionSnapshot(
                    current: marker,
                    conflicts: []
                )
            },
            finish: { false }
        )

        do {
            let _: Int = try await ICloudReplicationRepositoryAuthority
                .withValidatedMarkerAuthority(
                    expected: try descriptor(from: marker),
                    observationSession: session
                ) {
                    throw AuthorityGuardTestError.operationFailed
                }
            XCTFail("the operation error must be rethrown after post-validation")
        } catch {
            XCTAssertEqual(
                error as? AuthorityGuardTestError,
                .operationFailed
            )
        }
        XCTAssertEqual(snapshots.count, 1)
    }

    func testAuthorityGuardPrefersPostValidationFailureOverOperationError()
        async throws
    {
        let current = try markerData(
            generationID: UUID(
                uuidString: "97000000-0000-0000-0000-000000000001"
            )!
        )
        let changed = try markerData(
            generationID: UUID(
                uuidString: "97000000-0000-0000-0000-000000000002"
            )!
        )
        let session = ICloudMarkerAuthorityObservationSession(
            initialSnapshot: ICloudMarkerVersionSnapshot(
                current: current,
                conflicts: []
            ),
            snapshot: {
                ICloudMarkerVersionSnapshot(
                    current: changed,
                    conflicts: []
                )
            },
            finish: { false }
        )

        do {
            let _: Int = try await ICloudReplicationRepositoryAuthority
                .withValidatedMarkerAuthority(
                    expected: try descriptor(from: current),
                    observationSession: session
                ) {
                    throw AuthorityGuardTestError.operationFailed
                }
            XCTFail("authority divergence must outrank the operation error")
        } catch {
            XCTAssertEqual(
                error as? ICloudReplicationRepositoryAuthorityError,
                .divergentMarkerVersion
            )
        }
    }

    func testLocalPreflightRejectsAnUnexpectedCanonicalCurrentMarker()
        throws
    {
        let root = makeRepositoryURL()
        let opened = try FileReplicationRepositoryBootstrap
            .openOrCreateWithStatus(
                at: root,
                generationID: {
                    UUID(
                        uuidString: "97000000-0000-0000-0000-000000000001"
                    )!
                }
            )
        let markerURL = root.appendingPathComponent(
            FileReplicationRepositoryBootstrap.markerFilename
        )
        let markerBefore = try Data(contentsOf: markerURL)
        let unexpected = ReplicationRepositoryDescriptor(
            formatVersion: FileReplicationRepositoryBootstrap.formatVersion,
            generationID: UUID(
                uuidString: "97000000-0000-0000-0000-000000000002"
            )!
        )

        XCTAssertThrowsError(
            try ICloudReplicationRepositoryAuthority
                .validateLocallyAvailableMarkerVersions(
                    at: markerURL,
                    expected: unexpected
                )
        ) { error in
            XCTAssertEqual(
                error as? ICloudReplicationRepositoryAuthorityError,
                .divergentMarkerVersion
            )
        }
        XCTAssertEqual(
            opened.descriptor.generationID.uuidString,
            "97000000-0000-0000-0000-000000000001"
        )
        XCTAssertEqual(try Data(contentsOf: markerURL), markerBefore)
    }

    func testNativePresenterGuardSpansOperationAndBalancesRegistration()
        async throws
    {
        let root = makeRepositoryURL()
        let opened = try FileReplicationRepositoryBootstrap
            .openOrCreateWithStatus(at: root)
        let markerURL = root.appendingPathComponent(
            FileReplicationRepositoryBootstrap.markerFilename
        ).standardizedFileURL
        let presenterCount = {
            NSFileCoordinator.filePresenters.filter {
                $0.presentedItemURL?.standardizedFileURL == markerURL
            }.count
        }
        XCTAssertEqual(presenterCount(), 0)

        let countDuringOperation = try await
            ICloudReplicationRepositoryAuthority
                .withValidatedMarkerAuthority(
                    at: markerURL,
                    expected: opened.descriptor,
                    nonlocalVersionLoader: { _, completion in
                        completion(.success([]))
                    },
                    operation: { presenterCount() }
                )

        XCTAssertEqual(countDuringOperation, 1)
        XCTAssertEqual(presenterCount(), 0)
    }

    func testUnavailableNativeNonlocalInventoryFailsClosedAndUnregisters()
        async throws
    {
        let root = makeRepositoryURL()
        let opened = try FileReplicationRepositoryBootstrap
            .openOrCreateWithStatus(at: root)
        let markerURL = root.appendingPathComponent(
            FileReplicationRepositoryBootstrap.markerFilename
        ).standardizedFileURL

        do {
            _ = try await ICloudReplicationRepositoryAuthority
                .withValidatedMarkerAuthority(
                    at: markerURL,
                    expected: opened.descriptor
                ) {
                    42
                }
            XCTFail("unavailable non-local inventory must fail closed")
        } catch {
            XCTAssertEqual(
                error as? ICloudReplicationRepositoryAuthorityError,
                .unavailableMarkerVersion
            )
        }
        XCTAssertFalse(
            NSFileCoordinator.filePresenters.contains {
                $0.presentedItemURL?.standardizedFileURL == markerURL
            }
        )
    }

    func testNativePresenterRejectsMarkerChangedAfterFinalSnapshotRead()
        async throws
    {
        let root = makeRepositoryURL()
        let opened = try FileReplicationRepositoryBootstrap
            .openOrCreateWithStatus(
                at: root,
                generationID: {
                    UUID(
                        uuidString: "97000000-0000-0000-0000-000000000001"
                    )!
                }
            )
        let markerURL = root.appendingPathComponent(
            FileReplicationRepositoryBootstrap.markerFilename
        ).standardizedFileURL
        let replacement = try markerData(
            generationID: UUID(
                uuidString: "97000000-0000-0000-0000-000000000002"
            )!
        )
        let loader = MarkerChangingNonlocalVersionLoader(
            markerURL: markerURL,
            replacement: replacement
        )

        do {
            _ = try await ICloudReplicationRepositoryAuthority
                .withValidatedMarkerAuthority(
                    at: markerURL,
                    expected: opened.descriptor,
                    nonlocalVersionLoader: loader.load
                ) {
                    42
                }
            XCTFail("a marker change inside the final observation must fail")
        } catch {
            XCTAssertEqual(
                error as? ICloudReplicationRepositoryAuthorityError,
                .divergentMarkerVersion
            )
        }
        XCTAssertEqual(loader.invocationCount, 2)
        XCTAssertEqual(try Data(contentsOf: markerURL), replacement)
        XCTAssertFalse(
            NSFileCoordinator.filePresenters.contains {
                $0.presentedItemURL?.standardizedFileURL == markerURL
            }
        )
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

    private func descriptor(
        from data: Data
    ) throws -> ReplicationRepositoryDescriptor {
        try ReplicationPublicationBuilder.canonicalDecoder().decode(
            ReplicationRepositoryDescriptor.self,
            from: data
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

private actor AuthorityGuardOperationRecorder {
    private var operationDidRun = false

    func recordRun() {
        operationDidRun = true
    }

    func didRun() -> Bool {
        operationDidRun
    }
}

private enum AuthorityGuardTestError: Error, Equatable {
    case operationFailed
}

private final class AuthorityGuardSnapshotRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshotCount = 0

    var count: Int {
        lock.withLock { snapshotCount }
    }

    func record() {
        lock.withLock {
            snapshotCount += 1
        }
    }
}

private final class MarkerChangingNonlocalVersionLoader: @unchecked Sendable {
    private let lock = NSLock()
    private let markerURL: URL
    private let replacement: Data
    private var count = 0

    init(markerURL: URL, replacement: Data) {
        self.markerURL = markerURL
        self.replacement = replacement
    }

    var invocationCount: Int {
        lock.withLock { count }
    }

    func load(
        _: URL,
        completion: @escaping @Sendable (
            ICloudMarkerNonlocalVersionResult
        ) -> Void
    ) {
        let invocation = lock.withLock {
            count += 1
            return count
        }
        guard invocation == 2 else {
            completion(.success([]))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var coordinationError: NSError?
            var writeFailed = false
            NSFileCoordinator().coordinate(
                writingItemAt: markerURL,
                options: [],
                error: &coordinationError
            ) { coordinatedURL in
                do {
                    try replacement.write(to: coordinatedURL)
                } catch {
                    writeFailed = true
                }
            }
            if coordinationError == nil, writeFailed == false {
                completion(.success([]))
            } else {
                completion(.unavailable)
            }
        }
    }
}
