@testable import NoonmarkCore
@testable import NoonmarkSync
import XCTest

final class ContentAddressedFileReplicationEndpointTests: XCTestCase {
    private let generationID = UUID(
        uuidString: "81000000-0000-0000-0000-000000000001"
    )!
    private let producerID = UUID(
        uuidString: "82000000-0000-0000-0000-000000000001"
    )!

    func testPublicCleanOpenRejectsLegacyRepositoryWithoutWritingV2Objects()
        throws
    {
        let rootURL = makeRepositoryURL()
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let legacyURL = rootURL.appendingPathComponent("legacy-head.json")
        try Data("legacy".utf8).write(to: legacyURL)
        let before = try FileManager.default.contentsOfDirectory(
            atPath: rootURL.path
        ).sorted()

        XCTAssertThrowsError(
            try ContentAddressedFileReplicationEndpoint.openCleanRepository(
                rootURL: rootURL
            )
        ) { error in
            XCTAssertEqual(
                error as? ReplicationRepositoryBootstrapError,
                .legacyRepositoryRequiresManualReset
            )
        }

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: rootURL.path)
                .sorted(),
            before
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: rootURL.appendingPathComponent("v2").path
            )
        )
    }

    func testSealedPublicationRoundTripsThroughImmutableContentAddressedObjects()
        async throws
    {
        let rootURL = makeRepositoryURL()
        let records = [
            try preferenceRecord(index: 1),
            try preferenceRecord(index: 2),
        ]
        let publication = try ReplicationPublicationBuilder(
            maximumRecordsPerChunk: 1
        ).seal(
            records: records,
            generationID: generationID,
            producerID: producerID,
            sequence: 1,
            previousSealDigest: nil
        )
        let endpoint = ContentAddressedFileReplicationEndpoint(
            rootURL: rootURL,
            generationID: generationID
        )

        let receipt = try await endpoint.publish(sealed: publication)
        let observations = try await endpoint.observe(pending: [receipt])
        let stagesAfterFirstPublish = try stagedFiles(in: rootURL)
        _ = try await endpoint.publish(sealed: publication)

        XCTAssertEqual(
            observations,
            [
                ReplicationPublicationObservation(
                    reference: publication.reference,
                    state: .confirmed
                ),
            ]
        )
        XCTAssertEqual(receipt.reference, publication.reference)
        XCTAssertEqual(receipt.objects.count, 4)
        XCTAssertEqual(
            try stagedFiles(in: rootURL),
            stagesAfterFirstPublish
        )
        XCTAssertTrue(receipt.objects.allSatisfy { object in
            object.relativeKey.contains(object.digest.rawValue)
                && object.relativeKey.contains("heads/") == false
        })

        let restarted = ContentAddressedFileReplicationEndpoint(
            rootURL: rootURL,
            generationID: generationID
        )
        let page = try await restarted.read(
            after: .origin,
            budget: ReplicationReadBudget(
                maximumPublications: 10,
                maximumBytes: 1_000_000
            )
        )

        XCTAssertEqual(page.publications.count, 1)
        XCTAssertEqual(page.publications[0].reference, publication.reference)
        XCTAssertEqual(page.publications[0].records, publication.records)
        XCTAssertEqual(
            page.cursor.position(for: producerID),
            ReplicationSelfWatermark(
                sequence: 1,
                sealDigest: publication.reference.sealDigest
            )
        )
        XCTAssertFalse(page.hasMore)
    }

    func testICloudEndpointChecksMarkerAuthorityBeforeEveryRemoteOperation()
        async throws
    {
        let rootURL = makeRepositoryURL()
        let publication = try publication(sequence: 1)
        let expectedError = ICloudReplicationRepositoryAuthorityError
            .divergentMarkerVersion
        let endpoint = ICloudDriveReplicationEndpoint(
            rootURL: rootURL,
            generationID: generationID,
            repositoryAuthorityValidation: {
                throw expectedError
            },
            downloadRequest: { _ in }
        )

        await XCTAssertThrowsErrorAsync({
            try await endpoint.publish(sealed: publication)
        }) { error in
            XCTAssertEqual(
                error as? ICloudReplicationRepositoryAuthorityError,
                expectedError
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.path))

        let receipt = ReplicationPublicationReceipt(
            reference: publication.reference,
            objects: publication.objects.map(\.reference)
        )
        await XCTAssertThrowsErrorAsync({
            try await endpoint.observe(pending: [receipt])
        }) { error in
            XCTAssertEqual(
                error as? ICloudReplicationRepositoryAuthorityError,
                expectedError
            )
        }
        await XCTAssertThrowsErrorAsync({
            try await endpoint.read(
                after: .origin,
                budget: ReplicationReadBudget(
                    maximumPublications: 1,
                    maximumBytes: 1
                )
            )
        }) { error in
            XCTAssertEqual(
                error as? ICloudReplicationRepositoryAuthorityError,
                expectedError
            )
        }
    }

    func testFirstPublicationLargerThanByteBudgetStillAdvancesCursor()
        async throws
    {
        let rootURL = makeRepositoryURL()
        let publication = try publication(sequence: 1)
        let endpoint = ContentAddressedFileReplicationEndpoint(
            rootURL: rootURL,
            generationID: generationID
        )
        _ = try await endpoint.publish(sealed: publication)

        let page = try await endpoint.read(
            after: .origin,
            budget: ReplicationReadBudget(
                maximumPublications: 1,
                maximumBytes: 1
            )
        )

        XCTAssertEqual(page.publications.map(\.reference), [publication.reference])
        XCTAssertEqual(
            page.cursor.position(for: producerID)?.sequence,
            publication.reference.sequence
        )
        XCTAssertGreaterThan(page.openedByteCount, 1)
        XCTAssertFalse(page.hasMore)
    }

    func testExactPublishRetryDoesNotCreateAnotherPermanentStage()
        async throws
    {
        let rootURL = makeRepositoryURL()
        let publication = try publication(sequence: 1)
        let endpoint = ContentAddressedFileReplicationEndpoint(
            rootURL: rootURL,
            generationID: generationID
        )

        let firstReceipt = try await endpoint.publish(sealed: publication)
        let stagesAfterFirstPublish = Set(try stagedFiles(in: rootURL))
        let retryReceipt = try await endpoint.publish(sealed: publication)

        XCTAssertEqual(firstReceipt, retryReceipt)
        XCTAssertEqual(stagesAfterFirstPublish.count, firstReceipt.objects.count)
        XCTAssertEqual(
            Set(try stagedFiles(in: rootURL)),
            stagesAfterFirstPublish
        )
    }

    func testExactAncestorRetryRemainsIdempotentAfterDescendantPublication()
        async throws
    {
        let rootURL = makeRepositoryURL()
        let first = try publication(sequence: 1, recordIndex: 1)
        let second = try publication(
            sequence: 2,
            previousSealDigest: first.reference.sealDigest,
            recordIndex: 2
        )
        let endpoint = ContentAddressedFileReplicationEndpoint(
            rootURL: rootURL,
            generationID: generationID
        )

        let firstReceipt = try await endpoint.publish(sealed: first)
        let secondReceipt = try await endpoint.publish(sealed: second)
        let stagesBeforeRetry = Set(try stagedFiles(in: rootURL))
        let bytesBeforeRetry = try Dictionary(
            uniqueKeysWithValues: (firstReceipt.objects + secondReceipt.objects)
                .map { object in
                    (
                        object.relativeKey,
                        try Data(
                            contentsOf: rootURL.appendingPathComponent(
                                object.relativeKey
                            )
                        )
                    )
                }
        )

        let retryReceipt = try await endpoint.publish(sealed: first)
        let page = try await endpoint.read(
            after: .origin,
            budget: ReplicationReadBudget(
                maximumPublications: 10,
                maximumBytes: 1_000_000
            )
        )

        XCTAssertEqual(retryReceipt, firstReceipt)
        XCTAssertEqual(Set(try stagedFiles(in: rootURL)), stagesBeforeRetry)
        XCTAssertEqual(page.publications.map(\.reference), [
            first.reference,
            second.reference,
        ])
        for (relativeKey, bytes) in bytesBeforeRetry {
            XCTAssertEqual(
                try Data(
                    contentsOf: rootURL.appendingPathComponent(relativeKey)
                ),
                bytes
            )
        }
    }

    func testRepairPublicationRequiresAnExactlyBoundCanonicalManifest()
        async throws
    {
        let resolutionID = digest(repeating: "a")
        let otherResolutionID = digest(repeating: "b")
        let builder = ReplicationPublicationBuilder()
        let records = [try preferenceRecord(index: 31)]
        XCTAssertThrowsError(
            try builder.seal(
                records: records,
                generationID: generationID,
                producerID: producerID,
                sequence: 1,
                previousSealDigest: nil,
                basedOnResolutionID: resolutionID
            )
        )
        XCTAssertThrowsError(
            try builder.seal(
                records: records,
                generationID: generationID,
                producerID: producerID,
                sequence: 1,
                previousSealDigest: nil,
                resolutionManifest: ReplicationForkResolutionManifest(
                    resolutionID: resolutionID,
                    decidedAt: nil,
                    outcomes: []
                )
            )
        )
        XCTAssertThrowsError(
            try builder.seal(
                records: records,
                generationID: generationID,
                producerID: producerID,
                sequence: 1,
                previousSealDigest: nil,
                basedOnResolutionID: resolutionID,
                resolutionManifest: ReplicationForkResolutionManifest(
                    resolutionID: otherResolutionID,
                    decidedAt: nil,
                    outcomes: []
                )
            )
        )

        let manifest = ReplicationForkResolutionManifest(
            resolutionID: resolutionID,
            decidedAt: nil,
            outcomes: []
        )
        let publication = try builder.seal(
            records: records,
            generationID: generationID,
            producerID: producerID,
            sequence: 1,
            previousSealDigest: nil,
            basedOnResolutionID: resolutionID,
            resolutionManifest: manifest
        )
        let endpoint = ContentAddressedFileReplicationEndpoint(
            rootURL: makeRepositoryURL(),
            generationID: generationID
        )
        _ = try await endpoint.publish(sealed: publication)
        let page = try await endpoint.read(
            after: .origin,
            budget: ReplicationReadBudget(
                maximumPublications: 1,
                maximumBytes: 1_000_000
            )
        )

        XCTAssertEqual(
            page.publications.first?.resolutionManifest,
            manifest
        )
    }

    func testImmutableAnnouncementNeedsNoMutableHeadBeforeOrAfterRestart()
        async throws
    {
        let rootURL = makeRepositoryURL()
        let publication = try publication(sequence: 1)
        let endpoint = ContentAddressedFileReplicationEndpoint(
            rootURL: rootURL,
            generationID: generationID
        )
        _ = try await endpoint.publish(sealed: publication)
        let headURL = rootURL.appendingPathComponent(
            "v2/heads",
            isDirectory: true
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: headURL.path))

        let restarted = ContentAddressedFileReplicationEndpoint(
            rootURL: rootURL,
            generationID: generationID
        )
        let page = try await restarted.read(
            after: .origin,
            budget: ReplicationReadBudget(
                maximumPublications: 10,
                maximumBytes: 1_000_000
            )
        )

        XCTAssertEqual(page.publications.map(\.reference), [publication.reference])
        XCTAssertFalse(FileManager.default.fileExists(atPath: headURL.path))
    }

    func testPublishRejectsASequenceWithoutItsExactPredecessor() async throws {
        let endpoint = ContentAddressedFileReplicationEndpoint(
            rootURL: makeRepositoryURL(),
            generationID: generationID
        )
        let orphan = try publication(
            sequence: 2,
            previousSealDigest: digest(repeating: "a")
        )

        do {
            _ = try await endpoint.publish(sealed: orphan)
            XCTFail("a producer must not publish beyond a missing predecessor")
        } catch let error as FileReplicationEndpointError {
            XCTAssertEqual(
                error,
                .producerFork(producerID: producerID, sequence: 2)
            )
        }
    }

    func testAnnouncementGapCannotBeReportedAsAStableChainEnd()
        async throws
    {
        let rootURL = makeRepositoryURL()
        let first = try publication(sequence: 1, recordIndex: 1)
        let second = try publication(
            sequence: 2,
            previousSealDigest: first.reference.sealDigest,
            recordIndex: 2
        )
        let third = try publication(
            sequence: 3,
            previousSealDigest: second.reference.sealDigest,
            recordIndex: 3
        )
        try seedImmutable(first, into: rootURL)
        try seedImmutable(third, into: rootURL)
        let endpoint = ContentAddressedFileReplicationEndpoint(
            rootURL: rootURL,
            generationID: generationID
        )

        do {
            _ = try await endpoint.read(
                after: .origin,
                budget: ReplicationReadBudget(
                    maximumPublications: 10,
                    maximumBytes: 1_000_000
                )
            )
            XCTFail("an observed successor must make a missing sequence explicit")
        } catch let error as FileReplicationEndpointError {
            XCTAssertEqual(
                error,
                .announcementGap(
                    producerID: producerID,
                    missingSequence: 2,
                    highestObservedSequence: 3
                )
            )
        }
    }

    func testICloudAnnouncementGapRequestsTheExactMissingSequence()
        async throws
    {
        let rootURL = makeRepositoryURL()
        let first = try publication(sequence: 1, recordIndex: 1)
        let second = try publication(
            sequence: 2,
            previousSealDigest: first.reference.sealDigest,
            recordIndex: 2
        )
        let third = try publication(
            sequence: 3,
            previousSealDigest: second.reference.sealDigest,
            recordIndex: 3
        )
        try seedImmutable(first, into: rootURL)
        try seedImmutable(third, into: rootURL)
        let missingSequenceURL = rootURL.appendingPathComponent(
            "v2/announcements/\(generationID.uuidString.lowercased())/\(producerID.uuidString.lowercased())/00000000000000000002",
            isDirectory: true
        )
        let requests = DownloadRequestRecorder()
        let announcement = try XCTUnwrap(
            second.objects.first { $0.reference.kind == .announcement }
        )
        let seal = try XCTUnwrap(
            second.objects.first { $0.reference.kind == .seal }
        )
        let root = try XCTUnwrap(
            second.objects.first { $0.reference.kind == .root }
        )
        let chunks = second.objects.filter { $0.reference.kind == .chunk }
        let expectedObjectRequests = [seal, root] + chunks
        let endpoint = ICloudDriveReplicationEndpoint(
            rootURL: rootURL,
            generationID: generationID,
            downloadRequest: { url in
                requests.record(url)
                let object = if url == missingSequenceURL {
                    announcement
                } else {
                    try XCTUnwrap(second.objects.first {
                        rootURL.appendingPathComponent(
                            $0.reference.relativeKey
                        ) == url
                    })
                }
                let objectURL = rootURL.appendingPathComponent(
                    object.reference.relativeKey
                )
                try FileManager.default.createDirectory(
                    at: objectURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try object.bytes.write(
                    to: objectURL,
                    options: [.withoutOverwriting]
                )
            }
        )

        let budget = ReplicationReadBudget(
            maximumPublications: 10,
            maximumBytes: 1_000_000
        )
        let expectedRequests = [missingSequenceURL]
            + expectedObjectRequests.map {
                rootURL.appendingPathComponent($0.reference.relativeKey)
            }
        for expectedRequest in expectedRequests {
            let page = try await endpoint.read(
                after: .origin,
                budget: budget
            )
            XCTAssertEqual(page.state, .awaitingMaterialization)
            XCTAssertTrue(page.hasMore)
            XCTAssertEqual(page.cursor, .origin)
            XCTAssertTrue(page.publications.isEmpty)
            XCTAssertEqual(requests.snapshot().last, expectedRequest)
        }

        let materializedPage = try await endpoint.read(
            after: .origin,
            budget: budget
        )
        XCTAssertEqual(requests.snapshot(), expectedRequests)
        XCTAssertEqual(
            materializedPage.publications.map(\.reference),
            [first.reference, second.reference, third.reference]
        )
        XCTAssertEqual(
            materializedPage.cursor.position(for: producerID)?.sequence,
            3
        )
        XCTAssertEqual(materializedPage.state, .stable)
        XCTAssertFalse(materializedPage.hasMore)
    }

    func testICloudReadTimeMissingObjectRequestsExactMaterializationTarget()
        async throws
    {
        let rootURL = makeRepositoryURL()
        let first = try publication(sequence: 1, recordIndex: 1)
        try seedImmutable(first, into: rootURL)
        let seal = try XCTUnwrap(
            first.objects.first { $0.reference.kind == .seal }
        )
        let sealURL = rootURL.appendingPathComponent(
            seal.reference.relativeKey
        )
        let reader = TransientMissingFileReader(targetURL: sealURL)
        let requests = DownloadRequestRecorder()
        let endpoint = ICloudDriveReplicationEndpoint(
            rootURL: rootURL,
            generationID: generationID,
            fileDataReader: { url in
                try reader.read(url)
            },
            downloadRequest: { url in
                requests.record(url)
            }
        )
        let budget = ReplicationReadBudget(
            maximumPublications: 10,
            maximumBytes: 1_000_000
        )

        let awaitingPage = try await endpoint.read(
            after: .origin,
            budget: budget
        )

        XCTAssertEqual(awaitingPage.state, .awaitingMaterialization)
        XCTAssertTrue(awaitingPage.hasMore)
        XCTAssertEqual(awaitingPage.cursor, .origin)
        XCTAssertTrue(awaitingPage.publications.isEmpty)
        XCTAssertEqual(requests.snapshot(), [sealURL])

        let materializedPage = try await endpoint.read(
            after: .origin,
            budget: budget
        )

        XCTAssertEqual(requests.snapshot(), [sealURL])
        XCTAssertEqual(
            materializedPage.publications.map(\.reference),
            [first.reference]
        )
        XCTAssertEqual(materializedPage.state, .stable)
        XCTAssertFalse(materializedPage.hasMore)
    }

    func testMaterializedInternalSequenceDirectoryWithoutAnnouncementCannotCloseChain()
        async throws
    {
        let rootURL = makeRepositoryURL()
        let first = try publication(sequence: 1, recordIndex: 1)
        let second = try publication(
            sequence: 2,
            previousSealDigest: first.reference.sealDigest,
            recordIndex: 2
        )
        let third = try publication(
            sequence: 3,
            previousSealDigest: second.reference.sealDigest,
            recordIndex: 3
        )
        try seedImmutable(first, into: rootURL)
        try seedImmutable(third, into: rootURL)
        let incompleteSequenceURL = rootURL.appendingPathComponent(
            "v2/announcements/\(generationID.uuidString.lowercased())/\(producerID.uuidString.lowercased())/00000000000000000002",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: incompleteSequenceURL,
            withIntermediateDirectories: true
        )
        let endpoint = ContentAddressedFileReplicationEndpoint(
            rootURL: rootURL,
            generationID: generationID
        )

        do {
            _ = try await endpoint.read(
                after: .origin,
                budget: ReplicationReadBudget(
                    maximumPublications: 10,
                    maximumBytes: 1_000_000
                )
            )
            XCTFail("an observed sequence directory needs one announcement")
        } catch let error as FileReplicationEndpointError {
            XCTAssertEqual(
                error,
                .announcementGap(
                    producerID: producerID,
                    missingSequence: 2,
                    highestObservedSequence: 3
                )
            )
        }
    }

    func testEmptyTerminalSequenceDirectoryIsNotAPublicationPromise()
        async throws
    {
        let rootURL = makeRepositoryURL()
        let first = try publication(sequence: 1, recordIndex: 1)
        try seedImmutable(first, into: rootURL)
        let orphanDirectoryURL = rootURL.appendingPathComponent(
            "v2/announcements/\(generationID.uuidString.lowercased())/\(producerID.uuidString.lowercased())/00000000000000000003",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: orphanDirectoryURL,
            withIntermediateDirectories: true
        )
        let endpoint = ContentAddressedFileReplicationEndpoint(
            rootURL: rootURL,
            generationID: generationID
        )

        let page = try await endpoint.read(
            after: .origin,
            budget: ReplicationReadBudget(
                maximumPublications: 10,
                maximumBytes: 1_000_000
            )
        )

        XCTAssertEqual(page.publications.map(\.reference), [first.reference])
        XCTAssertEqual(page.state, .stable)
        XCTAssertFalse(page.hasMore)
    }

    func testSameSequenceDifferentDigestPreservesForkEvidenceAndFailsClosed()
        async throws
    {
        let rootURL = makeRepositoryURL()
        let endpoint = ContentAddressedFileReplicationEndpoint(
            rootURL: rootURL,
            generationID: generationID
        )
        let first = try publication(sequence: 1, recordIndex: 1)
        let fork = try publication(sequence: 1, recordIndex: 2)
        _ = try await endpoint.publish(sealed: first)

        _ = try await endpoint.publish(sealed: fork)

        let sequenceURL = rootURL.appendingPathComponent(
            "v2/announcements/\(generationID.uuidString.lowercased())/\(producerID.uuidString.lowercased())/00000000000000000001",
            isDirectory: true
        )
        let evidence = try FileManager.default.contentsOfDirectory(
            at: sequenceURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        XCTAssertEqual(evidence.count, 2)

        let firstPage = try await endpoint.read(
            after: .origin,
            budget: ReplicationReadBudget(
                maximumPublications: 10,
                maximumBytes: 1_000_000
            )
        )
        guard case let .blockedProducerFork(firstForkEvidence) =
            firstPage.state
        else {
            return XCTFail("fork read must return validated branch evidence")
        }
        XCTAssertEqual(
            firstForkEvidence.branches.map(\.reference),
            [first.reference, fork.reference].sorted {
                $0.sealDigest.rawValue < $1.sealDigest.rawValue
            }
        )

        let reversedEndpoint = ContentAddressedFileReplicationEndpoint(
            rootURL: makeRepositoryURL(),
            generationID: generationID
        )
        _ = try await reversedEndpoint.publish(sealed: fork)
        _ = try await reversedEndpoint.publish(sealed: first)
        let reversedPage = try await reversedEndpoint.read(
            after: .origin,
            budget: ReplicationReadBudget(
                maximumPublications: 10,
                maximumBytes: 1_000_000
            )
        )
        guard case let .blockedProducerFork(reversedForkEvidence) =
            reversedPage.state
        else {
            return XCTFail("reverse-order fork must return branch evidence")
        }
        XCTAssertEqual(reversedForkEvidence, firstForkEvidence)
    }

    func testForkEvidenceClosureChangesWhenTheForkedProducerAddsDescendants()
        async throws
    {
        let rootURL = makeRepositoryURL()
        let endpoint = ContentAddressedFileReplicationEndpoint(
            rootURL: rootURL,
            generationID: generationID
        )
        let first = try publication(sequence: 1, recordIndex: 1)
        let fork = try publication(sequence: 1, recordIndex: 2)
        _ = try await endpoint.publish(sealed: first)
        try seedImmutable(fork, into: rootURL)
        let firstDescendant = try publication(
            sequence: 2,
            previousSealDigest: first.reference.sealDigest,
            recordIndex: 3
        )
        try seedImmutable(firstDescendant, into: rootURL)

        let firstObservation = try await endpoint.read(
            after: .origin,
            budget: ReplicationReadBudget(
                maximumPublications: 10,
                maximumBytes: 1_000_000
            )
        )
        guard case let .blockedProducerFork(firstEvidence) =
            firstObservation.state
        else {
            return XCTFail("fork descendants must remain actionable evidence")
        }
        XCTAssertEqual(
            firstEvidence.branches.map(\.reference),
            [first.reference, fork.reference, firstDescendant.reference]
                .sorted(by: replicationReferenceComesBefore)
        )

        let forkDescendant = try publication(
            sequence: 2,
            previousSealDigest: fork.reference.sealDigest,
            recordIndex: 4
        )
        try seedImmutable(forkDescendant, into: rootURL)
        let secondObservation = try await endpoint.read(
            after: .origin,
            budget: ReplicationReadBudget(
                maximumPublications: 10,
                maximumBytes: 1_000_000
            )
        )
        guard case let .blockedProducerFork(secondEvidence) =
            secondObservation.state
        else {
            return XCTFail("new fork descendants must reopen fork evidence")
        }
        XCTAssertNotEqual(secondEvidence.resolutionID, firstEvidence.resolutionID)
        XCTAssertEqual(
            secondEvidence.branches.map(\.reference),
            [
                first.reference,
                fork.reference,
                firstDescendant.reference,
                forkDescendant.reference,
            ].sorted(by: replicationReferenceComesBefore)
        )
    }

    func testEndpointNeverCreatesMutableHeadsOrReplacesImmutableObjects()
        async throws
    {
        let rootURL = makeRepositoryURL()
        let endpoint = ContentAddressedFileReplicationEndpoint(
            rootURL: rootURL,
            generationID: generationID
        )
        let first = try publication(sequence: 1, recordIndex: 1)
        let second = try ReplicationPublicationBuilder().seal(
            records: [try preferenceRecord(index: 2)],
            generationID: generationID,
            producerID: producerID,
            sequence: 2,
            previousSealDigest: first.reference.sealDigest
        )
        let firstReceipt = try await endpoint.publish(sealed: first)
        let firstBytes: [String: Data] = try Dictionary(
            uniqueKeysWithValues: firstReceipt.objects.map {
            object in
            (
                object.relativeKey,
                try Data(contentsOf: rootURL.appendingPathComponent(object.relativeKey))
            )
        }
        )

        _ = try await endpoint.publish(sealed: second)

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: rootURL.appendingPathComponent("v2/heads").path
            )
        )
        for (relativeKey, bytes) in firstBytes {
            XCTAssertEqual(
                try Data(contentsOf: rootURL.appendingPathComponent(relativeKey)),
                bytes
            )
        }
        let page = try await endpoint.read(
            after: .origin,
            budget: ReplicationReadBudget(
                maximumPublications: 10,
                maximumBytes: 1_000_000
            )
        )
        XCTAssertEqual(page.publications.map(\.reference), [
            first.reference,
            second.reference,
        ])
    }

    func testRetryCompletesEveryInterruptedImmutablePublicationPrefixWithoutReplacingBytes()
        async throws
    {
        let publication = try publication(sequence: 1)
        XCTAssertEqual(
            publication.objects.map(\.reference.kind),
            [.chunk, .root, .seal, .announcement]
        )

        for completedObjectCount in 1 ... publication.objects.count {
            let rootURL = makeRepositoryURL()
            let completedObjects = publication.objects.prefix(
                completedObjectCount
            )
            for object in completedObjects {
                let url = rootURL.appendingPathComponent(
                    object.reference.relativeKey
                )
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try object.bytes.write(to: url, options: [.withoutOverwriting])
            }
            let bytesBeforeRetry = try Dictionary(
                uniqueKeysWithValues: completedObjects.map { object in
                    (
                        object.reference.relativeKey,
                        try Data(
                            contentsOf: rootURL.appendingPathComponent(
                                object.reference.relativeKey
                            )
                        )
                    )
                }
            )

            let restarted = ContentAddressedFileReplicationEndpoint(
                rootURL: rootURL,
                generationID: generationID
            )
            let receipt = try await restarted.publish(sealed: publication)
            let observation = try await restarted.observe(
                pending: [receipt]
            )
            let page = try await restarted.read(
                after: .origin,
                budget: ReplicationReadBudget(
                    maximumPublications: 1,
                    maximumBytes: 1_000_000
                )
            )

            XCTAssertEqual(
                observation.map(\.state),
                [.confirmed],
                "failed after \(completedObjectCount) immutable objects"
            )
            XCTAssertEqual(
                page.publications.map(\.reference),
                [publication.reference],
                "failed after \(completedObjectCount) immutable objects"
            )
            for (relativeKey, bytes) in bytesBeforeRetry {
                XCTAssertEqual(
                    try Data(
                        contentsOf: rootURL.appendingPathComponent(relativeKey)
                    ),
                    bytes,
                    "retry replaced \(relativeKey)"
                )
            }
        }
    }

    func testInterruptedStagingWriteNeverExposesAPartialFinalObject()
        async throws
    {
        let rootURL = makeRepositoryURL()
        let publication = try publication(sequence: 1)
        let interrupted = ContentAddressedFileReplicationEndpoint(
            rootURL: rootURL,
            generationID: generationID,
            writeByteLimitForTesting: 5
        )

        do {
            _ = try await interrupted.publish(sealed: publication)
            XCTFail("an interrupted staging write must fail publication")
        } catch {
            XCTAssertEqual(
                error as? AppendOnlyFilePublicationError,
                .injectedWriteInterruption
            )
        }
        for object in publication.objects {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: rootURL.appendingPathComponent(
                        object.reference.relativeKey
                    ).path
                )
            )
        }
        let interruptedStages = try stagedFiles(in: rootURL)
        XCTAssertEqual(interruptedStages.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: interruptedStages[0]),
            Data(publication.objects[0].bytes.prefix(5))
        )

        let restarted = ContentAddressedFileReplicationEndpoint(
            rootURL: rootURL,
            generationID: generationID
        )
        let receipt = try await restarted.publish(sealed: publication)
        let observations = try await restarted.observe(
            pending: [receipt]
        )
        XCTAssertEqual(
            observations.map(\.state),
            [.confirmed]
        )
        XCTAssertEqual(
            try Data(contentsOf: interruptedStages[0]),
            Data(publication.objects[0].bytes.prefix(5))
        )
        for object in publication.objects {
            XCTAssertEqual(
                try Data(
                    contentsOf: rootURL.appendingPathComponent(
                        object.reference.relativeKey
                    )
                ),
                object.bytes
            )
        }
    }

    private func publication(
        sequence: UInt64,
        previousSealDigest: ReplicationDigest? = nil,
        recordIndex: Int = 1
    ) throws -> SealedReplicationPublication {
        try ReplicationPublicationBuilder(
            maximumRecordsPerChunk: 1
        ).seal(
            records: [try preferenceRecord(index: recordIndex)],
            generationID: generationID,
            producerID: producerID,
            sequence: sequence,
            previousSealDigest: previousSealDigest
        )
    }

    private func digest(repeating character: Character) -> ReplicationDigest {
        ReplicationDigest(rawValue: String(repeating: character, count: 64))!
    }

    private func preferenceRecord(index: Int) throws -> SyncRecord {
        try SyncRecordMapper().record(
            for: AppPreferencesEnvelope(
                theme: index.isMultiple(of: 2) ? .coolGray : .warmPaper,
                language: index.isMultiple(of: 2) ? .english : .chinese,
                updatedAt: Date(
                    timeIntervalSinceReferenceDate: Double(index)
                )
            ),
            modifiedBy: SyncDeviceID("replication-endpoint-\(index)")
        )
    }

    private func seedImmutable(
        _ publication: SealedReplicationPublication,
        into rootURL: URL
    ) throws {
        for object in publication.objects {
            let url = rootURL.appendingPathComponent(
                object.reference.relativeKey
            )
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try object.bytes.write(to: url, options: [.withoutOverwriting])
        }
    }

    private func stagedFiles(in rootURL: URL) throws -> [URL] {
        let stagingURL = rootURL.appendingPathComponent(
            "v2/staging",
            isDirectory: true
        )
        guard let enumerator = FileManager.default.enumerator(
            at: stagingURL,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        return try enumerator.compactMap { item in
            guard let url = item as? URL else { return nil }
            return try url.resourceValues(forKeys: [.isRegularFileKey])
                .isRegularFile == true ? url : nil
        }
    }

    private func replicationReferenceComesBefore(
        _ lhs: ReplicationPublicationReference,
        _ rhs: ReplicationPublicationReference
    ) -> Bool {
        if lhs.sequence != rhs.sequence {
            return lhs.sequence < rhs.sequence
        }
        return lhs.sealDigest.rawValue < rhs.sealDigest.rawValue
    }

    private func makeRepositoryURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noonmark-content-addressed-endpoint-\(UUID().uuidString)",
                isDirectory: true
            )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> some Any,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

private final class DownloadRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func record(_ url: URL) {
        lock.withLock {
            urls.append(url)
        }
    }

    func snapshot() -> [URL] {
        lock.withLock { urls }
    }
}

private final class TransientMissingFileReader: @unchecked Sendable {
    private let lock = NSLock()
    private let targetURL: URL
    private var didFail = false

    init(targetURL: URL) {
        self.targetURL = targetURL
    }

    func read(_ url: URL) throws -> Data {
        let mustFail = lock.withLock {
            guard url == targetURL, didFail == false else { return false }
            didFail = true
            return true
        }
        if mustFail {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return try Data(contentsOf: url)
    }
}
