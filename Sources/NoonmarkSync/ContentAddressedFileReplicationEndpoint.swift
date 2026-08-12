import CryptoKit
import Foundation

public enum FileReplicationEndpointError: Error, Equatable, Sendable {
    case generationMismatch
    case invalidObject
    case missingObject
    case objectNotMaterialized(relativeKey: String)
    case invalidCursor
    case announcementGap(
        producerID: UUID,
        missingSequence: UInt64,
        highestObservedSequence: UInt64
    )
    case producerFork(producerID: UUID, sequence: UInt64)
}

public enum ReplicationFileReadPolicy: Sendable {
    case direct
    case coordinated
}

public actor ContentAddressedFileReplicationEndpoint:
    ReplicationEndpoint
{
    private struct Head: Codable {
        let formatVersion: Int
        let generationID: UUID
        let producerID: UUID
        let tipSequence: UInt64
        let sealDigest: ReplicationDigest
        let announcementDigest: ReplicationDigest
    }

    private struct Chunk: Codable {
        let formatVersion: Int
        let records: [SyncRecord]
    }

    private struct Root: Codable {
        let formatVersion: Int
        let generationID: UUID
        let producerID: UUID
        let sequence: UInt64
        let previousSealDigest: ReplicationDigest?
        let basedOnResolutionID: ReplicationDigest?
        let resolutionManifest: ReplicationForkResolutionManifest?
        let chunkDigests: [ReplicationDigest]
        let recordCount: Int
    }

    private struct Seal: Codable {
        let formatVersion: Int
        let generationID: UUID
        let producerID: UUID
        let sequence: UInt64
        let rootDigest: ReplicationDigest
    }

    private struct Announcement: Codable {
        let formatVersion: Int
        let generationID: UUID
        let producerID: UUID
        let sequence: UInt64
        let previousSealDigest: ReplicationDigest?
        let rootDigest: ReplicationDigest
        let sealDigest: ReplicationDigest
    }

    private struct PublicationHeader {
        let announcement: Announcement
        let announcementDigest: ReplicationDigest
        let root: Root
        let openedByteCount: Int64
    }

    public nonisolated let rootURL: URL
    public nonisolated let generationID: UUID
    public nonisolated let namespace: String
    public nonisolated let repositoryWasCreated: Bool

    private let fileManager: FileManager
    private let fileReadPolicy: ReplicationFileReadPolicy
    private let fileDataReader: @Sendable (URL) throws -> Data
    private let filePublisher: AppendOnlyFilePublisher
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public nonisolated static func openCleanRepository(
        rootURL: URL,
        fileReadPolicy: ReplicationFileReadPolicy = .direct,
        generationID: @Sendable () -> UUID = UUID.init
    ) throws -> ContentAddressedFileReplicationEndpoint {
        let result = try FileReplicationRepositoryBootstrap.openOrCreateWithStatus(
            at: rootURL,
            generationID: generationID
        )
        return ContentAddressedFileReplicationEndpoint(
            rootURL: rootURL,
            generationID: result.descriptor.generationID,
            fileReadPolicy: fileReadPolicy,
            repositoryWasCreated: result.createdRepository
        )
    }

    init(
        rootURL: URL,
        generationID: UUID,
        fileReadPolicy: ReplicationFileReadPolicy = .direct,
        repositoryWasCreated: Bool = false,
        writeByteLimitForTesting: Int? = nil,
        fileDataReader: @escaping @Sendable (URL) throws -> Data = {
            try Data(contentsOf: $0)
        }
    ) {
        self.rootURL = rootURL
        self.generationID = generationID
        self.repositoryWasCreated = repositoryWasCreated
        fileManager = FileManager()
        self.fileReadPolicy = fileReadPolicy
        self.fileDataReader = fileDataReader
        filePublisher = AppendOnlyFilePublisher(
            rootURL: rootURL,
            writeByteLimitForTesting: writeByteLimitForTesting
        )
        namespace = "replication-v2-" + SHA256.hash(
            data: Data(
                (rootURL.standardizedFileURL.path
                    + "#" + generationID.uuidString.lowercased()).utf8
            )
        ).map { String(format: "%02x", $0) }.joined()
        encoder = ReplicationPublicationBuilder.canonicalEncoder()
        decoder = ReplicationPublicationBuilder.canonicalDecoder()
    }

    public func publish(
        sealed publication: SealedReplicationPublication
    ) async throws -> ReplicationPublicationReceipt {
        try Task.checkCancellation()
        guard publication.reference.generationID == generationID,
              publication.reference.hasValidChainShape,
              publication.objects.isEmpty == false
        else {
            throw FileReplicationEndpointError.generationMismatch
        }
        try prepareRepository()
        for object in publication.objects {
            try validate(object)
        }
        if try publicationAlreadyExistsExactly(publication) {
            return receipt(for: publication)
        }
        try validatePublishPredecessor(publication.reference)
        for object in publication.objects {
            try Task.checkCancellation()
            try publishImmutable(
                data: object.bytes,
                to: try objectURL(for: object.reference)
            )
        }
        return receipt(for: publication)
    }

    public func observe(
        pending receipts: [ReplicationPublicationReceipt]
    ) async throws -> [ReplicationPublicationObservation] {
        try prepareRepository()
        return try receipts.map { receipt in
            try Task.checkCancellation()
            guard receipt.reference.generationID == generationID else {
                throw FileReplicationEndpointError.generationMismatch
            }
            for object in receipt.objects {
                let data = try readExactObject(object)
                guard Int64(data.count) == object.byteCount else {
                    return ReplicationPublicationObservation(
                        reference: receipt.reference,
                        state: .blockedCorruption
                    )
                }
            }
            return ReplicationPublicationObservation(
                reference: receipt.reference,
                state: .confirmed
            )
        }
    }

    public func read(
        after cursor: ReplicationReadCursor,
        budget: ReplicationReadBudget
    ) async throws -> ReplicationReadPage {
        guard budget.maximumPublications > 0,
              budget.maximumBytes > 0
        else {
            throw FileReplicationEndpointError.invalidCursor
        }
        try prepareRepository()
        let heads: [Head]
        do {
            heads = try observedHeads(resolving: cursor)
        } catch let error as FileReplicationEndpointError {
            guard case let .producerFork(producerID, sequence) = error else {
                throw error
            }
            let evidence = try readForkEvidence(
                producerID: producerID,
                sequence: sequence
            )
            let resolutionBaselines = try readResolutionBaselines(
                for: evidence.resolutionID,
                excluding: producerID,
                budget: budget
            )
            return ReplicationReadPage(
                publications: [],
                resolutionBaselines: resolutionBaselines.publications,
                cursor: cursor,
                hasMore: false,
                openedByteCount: resolutionBaselines.openedByteCount,
                state: .blockedProducerFork(evidence)
            )
        }
        try validate(cursor: cursor, against: heads)
        var nextCursor = cursor
        var publications: [ReceivedReplicationPublication] = []
        var openedByteCount: Int64 = 0

        producerLoop: for head in heads {
            var sequence = cursor.position(for: head.producerID)?.sequence ?? 0
            var previousSealDigest = cursor.position(
                for: head.producerID
            )?.sealDigest
            while sequence < head.tipSequence {
                try Task.checkCancellation()
                let nextSequence = sequence + 1
                let (publication, bytes) = try readPublication(
                    producerID: head.producerID,
                    sequence: nextSequence,
                    expectedPreviousSealDigest: previousSealDigest
                )
                if publications.isEmpty == false,
                   publications.count >= budget.maximumPublications
                       || openedByteCount + bytes > budget.maximumBytes
                {
                    break producerLoop
                }
                publications.append(publication)
                openedByteCount = min(Int64.max, openedByteCount + bytes)
                let watermark = ReplicationSelfWatermark(
                    sequence: nextSequence,
                    sealDigest: publication.reference.sealDigest
                )
                nextCursor = nextCursor.advancing(
                    producerID: head.producerID,
                    to: watermark
                )
                sequence = nextSequence
                previousSealDigest = watermark.sealDigest
                if publications.count >= budget.maximumPublications
                    || openedByteCount >= budget.maximumBytes
                {
                    break producerLoop
                }
            }
        }
        let hasMore = heads.contains { head in
            (nextCursor.position(for: head.producerID)?.sequence ?? 0)
                < head.tipSequence
        }
        return ReplicationReadPage(
            publications: publications,
            cursor: nextCursor,
            hasMore: hasMore,
            openedByteCount: openedByteCount,
            state: .stable
        )
    }

    public func cancelAndJoin() async {}
}

private extension ContentAddressedFileReplicationEndpoint {
    func publicationAlreadyExistsExactly(
        _ publication: SealedReplicationPublication
    ) throws -> Bool {
        for object in publication.objects {
            let url = try objectURL(for: object.reference)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(
                atPath: url.path,
                isDirectory: &isDirectory
            ) else {
                return false
            }
            guard isDirectory.boolValue == false else {
                throw FileReplicationEndpointError.invalidObject
            }
            let observed = try readData(at: url)
            guard Int64(observed.count) == object.reference.byteCount,
                  observed == object.bytes,
                  try ReplicationPublicationBuilder.digest(observed)
                  == object.reference.digest
            else {
                throw FileReplicationEndpointError.invalidObject
            }
        }
        return true
    }

    func receipt(
        for publication: SealedReplicationPublication
    ) -> ReplicationPublicationReceipt {
        ReplicationPublicationReceipt(
            reference: publication.reference,
            objects: publication.objects.map(\.reference)
        )
    }

    func validate(_ object: ReplicationImmutableObject) throws {
        guard object.reference.byteCount == Int64(object.bytes.count),
              try ReplicationPublicationBuilder.digest(object.bytes)
              == object.reference.digest,
              object.reference.relativeKey.hasPrefix("v2/"),
              object.reference.relativeKey.contains(
                  object.reference.digest.rawValue
              )
        else {
            throw FileReplicationEndpointError.invalidObject
        }
        _ = try objectURL(for: object.reference)
    }

    func prepareRepository() throws {
        for relativePath in [
            "v2/objects",
            "v2/announcements/\(generationID.uuidString.lowercased())",
        ] {
            try filePublisher.ensureDirectory(relativePath)
        }
    }

    var v2URL: URL {
        rootURL.appendingPathComponent("v2", isDirectory: true)
    }

    var objectsURL: URL {
        v2URL.appendingPathComponent("objects", isDirectory: true)
    }

    var announcementsURL: URL {
        v2URL.appendingPathComponent(
            "announcements",
            isDirectory: true
        ).appendingPathComponent(
            generationID.uuidString.lowercased(),
            isDirectory: true
        )
    }

    func objectURL(
        kind: ReplicationObjectKind,
        digest: ReplicationDigest
    ) -> URL {
        objectsURL.appendingPathComponent(
            kind.rawValue,
            isDirectory: true
        ).appendingPathComponent("\(digest.rawValue).json")
    }

    func objectURL(
        for reference: ReplicationObjectReference
    ) throws -> URL {
        guard reference.relativeKey.isEmpty == false,
              reference.relativeKey.hasPrefix("/") == false,
              reference.relativeKey.split(separator: "/").allSatisfy({
                  $0 != "." && $0 != ".."
              })
        else {
            throw FileReplicationEndpointError.invalidObject
        }
        let root = rootURL.standardizedFileURL
        let url = root.appendingPathComponent(
            reference.relativeKey
        ).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else {
            throw FileReplicationEndpointError.invalidObject
        }
        return url
    }

    func announcementSequenceURL(
        producerID: UUID,
        sequence: UInt64
    ) -> URL {
        announcementsURL.appendingPathComponent(
            producerID.uuidString.lowercased(),
            isDirectory: true
        ).appendingPathComponent(
            String(format: "%020llu", sequence),
            isDirectory: true
        )
    }

    func validatePublishPredecessor(
        _ reference: ReplicationPublicationReference
    ) throws {
        let head = try observedAnnouncementHead(
            producerID: reference.producerID
        )
        if let head,
           head.tipSequence == reference.sequence
        {
            // Let an exact retry proceed, and let a different digest publish
            // its immutable announcement before the authoritative scan fails
            // closed. The competing artifact is required fork evidence.
            return
        }
        if reference.sequence == 1 {
            guard head == nil else {
                throw FileReplicationEndpointError.producerFork(
                    producerID: reference.producerID,
                    sequence: reference.sequence
                )
            }
            return
        }
        guard let head,
              head.tipSequence + 1 == reference.sequence,
              head.sealDigest == reference.previousSealDigest
        else {
            throw FileReplicationEndpointError.producerFork(
                producerID: reference.producerID,
                sequence: reference.sequence
            )
        }
    }

    private func observedHeads(
        resolving cursor: ReplicationReadCursor = .origin
    ) throws -> [Head] {
        let producerURLs = try fileManager.contentsOfDirectory(
            at: announcementsURL,
            includingPropertiesForKeys: nil
        )
        var result: [Head] = []
        var observedResolvedProducers: Set<UUID> = []
        for url in producerURLs {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(
                atPath: url.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                throw FileReplicationEndpointError.invalidObject
            }
            let producerName = url.lastPathComponent
            guard let producerID = UUID(uuidString: producerName),
                  producerID.uuidString.lowercased() == producerName
            else {
                throw FileReplicationEndpointError.invalidObject
            }
            let head: Head?
            do {
                head = try observedAnnouncementHead(
                    producerID: producerID
                )
            } catch let error as FileReplicationEndpointError {
                guard case let .producerFork(
                    forkedProducerID,
                    sequence
                ) = error else {
                    throw error
                }
                let evidence = try readForkEvidence(
                    producerID: forkedProducerID,
                    sequence: sequence
                )
                guard let resolved = cursor.resolvedForks[
                    forkedProducerID
                ],
                    resolved.forkSequence == evidence.sequence,
                    resolved.resolutionID == evidence.resolutionID
                else {
                    throw error
                }
                observedResolvedProducers.insert(forkedProducerID)
                continue
            }
            if let head {
                result.append(head)
            }
        }
        guard observedResolvedProducers
            == Set(cursor.resolvedForks.keys)
        else {
            throw FileReplicationEndpointError.invalidCursor
        }
        return result.sorted {
            $0.producerID.uuidString < $1.producerID.uuidString
        }
    }

    private func observedAnnouncementHead(
        producerID: UUID
    ) throws -> Head? {
        let producerURL = announcementsURL.appendingPathComponent(
            producerID.uuidString.lowercased(),
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: producerURL.path) else {
            return nil
        }
        let directories = try observedAnnouncementDirectories(
            at: producerURL,
            producerID: producerID
        )
        let announcements = try readAnnouncements(
            from: directories,
            producerID: producerID
        )
        var sequence: UInt64 = 1
        var previousSeal: ReplicationDigest?
        var tip: (Announcement, ReplicationDigest)?
        while let next = announcements[sequence] {
            guard next.0.previousSealDigest == previousSeal else {
                throw FileReplicationEndpointError.producerFork(
                    producerID: producerID,
                    sequence: sequence
                )
            }
            tip = next
            previousSeal = next.0.sealDigest
            sequence += 1
        }
        guard let tip else { return nil }
        return Head(
            formatVersion: ReplicationPublicationBuilder.formatVersion,
            generationID: generationID,
            producerID: producerID,
            tipSequence: tip.0.sequence,
            sealDigest: tip.0.sealDigest,
            announcementDigest: tip.1
        )
    }

    private func observedAnnouncementDirectories(
        at producerURL: URL,
        producerID: UUID
    ) throws -> [(sequence: UInt64, url: URL)] {
        let sequenceURLs = try fileManager.contentsOfDirectory(
            at: producerURL,
            includingPropertiesForKeys: nil
        )
        var directories: [UInt64: URL] = [:]
        for sequenceURL in sequenceURLs {
            var isDirectory: ObjCBool = false
            let name = sequenceURL.lastPathComponent
            guard fileManager.fileExists(
                atPath: sequenceURL.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue,
                name.count == 20,
                let sequence = UInt64(name),
                sequence > 0,
                name == String(format: "%020llu", sequence),
                directories[sequence] == nil
            else {
                throw FileReplicationEndpointError.invalidObject
            }
            directories[sequence] = sequenceURL
        }
        let orderedSequences = directories.keys.sorted()
        return try orderedSequences.map { sequence in
            guard let url = directories[sequence] else {
                throw FileReplicationEndpointError.invalidObject
            }
            return (sequence, url)
        }
    }

    private func readAnnouncements(
        from directories: [(sequence: UInt64, url: URL)],
        producerID: UUID
    ) throws -> [UInt64: (Announcement, ReplicationDigest)] {
        var announcements: [UInt64: (Announcement, ReplicationDigest)] = [:]
        for directory in directories {
            let files = try fileManager.contentsOfDirectory(
                at: directory.url,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }
            if files.isEmpty {
                continue
            }
            guard files.count == 1 else {
                throw FileReplicationEndpointError.producerFork(
                    producerID: producerID,
                    sequence: directory.sequence
                )
            }
            let file = files[0]
            guard let digest = ReplicationDigest(
                rawValue: file.deletingPathExtension().lastPathComponent
            ) else {
                throw FileReplicationEndpointError.invalidObject
            }
            let value: Announcement
            do {
                value = try decoder.decode(
                    Announcement.self,
                    from: readAndValidate(url: file, digest: digest)
                )
            } catch let error as FileReplicationEndpointError {
                throw error
            } catch {
                throw FileReplicationEndpointError.invalidObject
            }
            guard value.formatVersion
                    == ReplicationPublicationBuilder.formatVersion,
                  value.generationID == generationID,
                  value.producerID == producerID,
                  value.sequence == directory.sequence
            else {
                throw FileReplicationEndpointError.invalidObject
            }
            announcements[directory.sequence] = (value, digest)
        }
        let sequences = announcements.keys.sorted()
        if let highestObservedSequence = sequences.last {
            var expectedSequence: UInt64 = 1
            for sequence in sequences {
                guard sequence == expectedSequence else {
                    throw FileReplicationEndpointError.announcementGap(
                        producerID: producerID,
                        missingSequence: expectedSequence,
                        highestObservedSequence: highestObservedSequence
                    )
                }
                if sequence != highestObservedSequence {
                    expectedSequence += 1
                }
            }
        }
        return announcements
    }

    private func validate(
        cursor: ReplicationReadCursor,
        against heads: [Head]
    ) throws {
        guard Set(cursor.positions.keys).isDisjoint(
            with: cursor.resolvedForks.keys
        ) else {
            throw FileReplicationEndpointError.invalidCursor
        }
        let byProducer = Dictionary(
            uniqueKeysWithValues: heads.map { ($0.producerID, $0) }
        )
        for (producerID, position) in cursor.positions {
            guard let head = byProducer[producerID],
                  position.sequence > 0,
                  position.sequence <= head.tipSequence
            else {
                throw FileReplicationEndpointError.invalidCursor
            }
            if position.sequence == head.tipSequence,
               position.sealDigest != head.sealDigest
            {
                throw FileReplicationEndpointError.producerFork(
                    producerID: producerID,
                    sequence: position.sequence
                )
            }
        }
    }

    func readForkEvidence(
        producerID: UUID,
        sequence: UInt64
    ) throws -> ReplicationForkEvidence {
        let producerURL = announcementsURL.appendingPathComponent(
            producerID.uuidString.lowercased(),
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: producerURL.path) else {
            throw FileReplicationEndpointError.objectNotMaterialized(
                relativeKey: try relativeKey(for: producerURL)
            )
        }
        let sequenceURLs = try fileManager.contentsOfDirectory(
            at: producerURL,
            includingPropertiesForKeys: nil
        ).filter { url in
            guard url.lastPathComponent.count == 20,
                  let observedSequence = UInt64(url.lastPathComponent)
            else { return false }
            return observedSequence >= sequence
        }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
        guard let firstSequenceURL = sequenceURLs.first,
              UInt64(firstSequenceURL.lastPathComponent) == sequence
        else {
            throw FileReplicationEndpointError.invalidObject
        }
        var branches: [ReceivedReplicationPublication] = []
        for sequenceURL in sequenceURLs {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(
                atPath: sequenceURL.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue,
                let observedSequence = UInt64(
                    sequenceURL.lastPathComponent
                )
            else {
                throw FileReplicationEndpointError.invalidObject
            }
            let files = try fileManager.contentsOfDirectory(
                at: sequenceURL,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }.sorted {
                $0.lastPathComponent < $1.lastPathComponent
            }
            guard files.isEmpty == false else {
                throw FileReplicationEndpointError.invalidObject
            }
            for url in files {
                let announcement = try decodedAnnouncement(
                    at: url,
                    producerID: producerID,
                    sequence: observedSequence
                ).announcement
                branches.append(
                    try readPublication(
                        announcementURL: url,
                        producerID: producerID,
                        sequence: observedSequence,
                        expectedPreviousSealDigest: announcement
                            .previousSealDigest
                    ).0
                )
            }
        }
        return try ReplicationForkEvidence(branches: branches)
    }

    func readPublication(
        producerID: UUID,
        sequence: UInt64,
        expectedPreviousSealDigest: ReplicationDigest?
    ) throws -> (ReceivedReplicationPublication, Int64) {
        let directory = announcementSequenceURL(
            producerID: producerID,
            sequence: sequence
        )
        guard fileManager.fileExists(atPath: directory.path) else {
            throw FileReplicationEndpointError.objectNotMaterialized(
                relativeKey: try relativeKey(for: directory)
            )
        }
        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        guard files.count == 1 else {
            throw FileReplicationEndpointError.producerFork(
                producerID: producerID,
                sequence: sequence
            )
        }
        return try readPublication(
            announcementURL: files[0],
            producerID: producerID,
            sequence: sequence,
            expectedPreviousSealDigest: expectedPreviousSealDigest
        )
    }

    func readPublication(
        announcementURL: URL,
        producerID: UUID,
        sequence: UInt64,
        expectedPreviousSealDigest: ReplicationDigest?
    ) throws -> (ReceivedReplicationPublication, Int64) {
        let header = try readPublicationHeader(
            announcementURL: announcementURL,
            producerID: producerID,
            sequence: sequence,
            expectedPreviousSealDigest: expectedPreviousSealDigest
        )
        let announcement = header.announcement
        let root = header.root
        var records: [SyncRecord] = []
        var openedBytes = header.openedByteCount
        for chunkDigest in root.chunkDigests {
            let data = try readAndValidate(
                url: objectURL(kind: .chunk, digest: chunkDigest),
                digest: chunkDigest
            )
            let chunk: Chunk
            do {
                chunk = try decoder.decode(Chunk.self, from: data)
            } catch {
                throw FileReplicationEndpointError.invalidObject
            }
            guard chunk.formatVersion
                    == ReplicationPublicationBuilder.formatVersion,
                  chunk.records.isEmpty == false
            else {
                throw FileReplicationEndpointError.invalidObject
            }
            records.append(contentsOf: chunk.records)
            openedBytes = min(Int64.max, openedBytes + Int64(data.count))
        }
        guard records.count == root.recordCount else {
            throw FileReplicationEndpointError.invalidObject
        }
        let reference = ReplicationPublicationReference(
            generationID: generationID,
            producerID: producerID,
            sequence: sequence,
            previousSealDigest: expectedPreviousSealDigest,
            rootDigest: announcement.rootDigest,
            sealDigest: announcement.sealDigest,
            announcementDigest: header.announcementDigest,
            basedOnResolutionID: root.basedOnResolutionID
        )
        return (
            ReceivedReplicationPublication(
                reference: reference,
                records: records,
                resolutionManifest: root.resolutionManifest
            ),
            openedBytes
        )
    }

    private func readPublicationHeader(
        announcementURL: URL,
        producerID: UUID,
        sequence: UInt64,
        expectedPreviousSealDigest: ReplicationDigest?
    ) throws -> PublicationHeader {
        let decoded = try decodedAnnouncement(
            at: announcementURL,
            producerID: producerID,
            sequence: sequence
        )
        let announcement = decoded.announcement
        guard announcement.previousSealDigest
                == expectedPreviousSealDigest
        else {
            throw FileReplicationEndpointError.producerFork(
                producerID: producerID,
                sequence: sequence
            )
        }
        let sealData = try readAndValidate(
            url: objectURL(kind: .seal, digest: announcement.sealDigest),
            digest: announcement.sealDigest
        )
        let seal: Seal
        do {
            seal = try decoder.decode(Seal.self, from: sealData)
        } catch {
            throw FileReplicationEndpointError.invalidObject
        }
        guard seal.formatVersion
                == ReplicationPublicationBuilder.formatVersion,
              seal.generationID == generationID,
              seal.producerID == producerID,
              seal.sequence == sequence,
              seal.rootDigest == announcement.rootDigest
        else {
            throw FileReplicationEndpointError.invalidObject
        }
        let rootData = try readAndValidate(
            url: objectURL(kind: .root, digest: seal.rootDigest),
            digest: seal.rootDigest
        )
        let root: Root
        do {
            root = try decoder.decode(Root.self, from: rootData)
        } catch {
            throw FileReplicationEndpointError.invalidObject
        }
        guard root.formatVersion
                == ReplicationPublicationBuilder.formatVersion,
              root.generationID == generationID,
              root.producerID == producerID,
              root.sequence == sequence,
              root.previousSealDigest == expectedPreviousSealDigest,
              try ReplicationPublicationBuilder.resolutionManifestIsValid(
                  root.resolutionManifest,
                  basedOnResolutionID: root.basedOnResolutionID
              ),
              root.chunkDigests.isEmpty == false
        else {
            throw FileReplicationEndpointError.invalidObject
        }
        return PublicationHeader(
            announcement: announcement,
            announcementDigest: decoded.digest,
            root: root,
            openedByteCount: Int64(
                decoded.data.count + sealData.count + rootData.count
            )
        )
    }

    func readResolutionBaselines(
        for resolutionID: ReplicationDigest,
        excluding forkedProducerID: UUID,
        budget: ReplicationReadBudget
    ) throws -> (
        publications: [ReceivedReplicationPublication],
        openedByteCount: Int64
    ) {
        let producerURLs = try fileManager.contentsOfDirectory(
            at: announcementsURL,
            includingPropertiesForKeys: nil
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var candidates: [(
            announcementURL: URL,
            producerID: UUID,
            sequence: UInt64,
            previousSealDigest: ReplicationDigest?,
            reference: ReplicationPublicationReference,
            manifest: ReplicationForkResolutionManifest
        )] = []
        var openedByteCount: Int64 = 0
        for producerURL in producerURLs {
            let producerName = producerURL.lastPathComponent
            guard let producerID = UUID(uuidString: producerName),
                  producerID.uuidString.lowercased() == producerName
            else {
                throw FileReplicationEndpointError.invalidObject
            }
            guard producerID != forkedProducerID else { continue }
            let head: Head?
            do {
                head = try observedAnnouncementHead(producerID: producerID)
            } catch let error as FileReplicationEndpointError {
                if case .producerFork = error {
                    continue
                }
                throw error
            }
            guard let head else { continue }
            for sequence in stride(
                from: head.tipSequence,
                through: UInt64(1),
                by: -1
            ) {
                let directory = announcementSequenceURL(
                    producerID: producerID,
                    sequence: sequence
                )
                let files = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil
                ).filter { $0.pathExtension == "json" }
                guard files.count == 1 else {
                    throw FileReplicationEndpointError.producerFork(
                        producerID: producerID,
                        sequence: sequence
                    )
                }
                let decoded = try decodedAnnouncement(
                    at: files[0],
                    producerID: producerID,
                    sequence: sequence
                )
                let announcement = decoded.announcement
                let header = try readPublicationHeader(
                    announcementURL: files[0],
                    producerID: producerID,
                    sequence: sequence,
                    expectedPreviousSealDigest: announcement
                        .previousSealDigest
                )
                openedByteCount = min(
                    Int64.max,
                    openedByteCount + header.openedByteCount
                )
                guard let manifest = header.root.resolutionManifest,
                      manifest.resolutionID == resolutionID
                else { continue }
                candidates.append(
                    (
                        announcementURL: files[0],
                        producerID: producerID,
                        sequence: sequence,
                        previousSealDigest: announcement.previousSealDigest,
                        reference: ReplicationPublicationReference(
                            generationID: generationID,
                            producerID: producerID,
                            sequence: sequence,
                            previousSealDigest: announcement
                                .previousSealDigest,
                            rootDigest: announcement.rootDigest,
                            sealDigest: announcement.sealDigest,
                            announcementDigest: decoded.digest,
                            basedOnResolutionID: header.root
                                .basedOnResolutionID
                        ),
                        manifest: manifest
                    )
                )
            }
        }
        guard openedByteCount <= budget.maximumBytes else {
            return ([], openedByteCount)
        }
        var distinctManifests: [(
            announcementURL: URL,
            producerID: UUID,
            sequence: UInt64,
            previousSealDigest: ReplicationDigest?,
            reference: ReplicationPublicationReference,
            manifest: ReplicationForkResolutionManifest
        )] = []
        for candidate in candidates {
            guard distinctManifests.contains(where: {
                $0.manifest == candidate.manifest
            }) == false else { continue }
            distinctManifests.append(candidate)
        }
        guard distinctManifests.count <= budget.maximumPublications else {
            return ([], openedByteCount)
        }
        if distinctManifests.count > 1 {
            return (
                distinctManifests.map {
                    ReceivedReplicationPublication(
                        reference: $0.reference,
                        records: [],
                        resolutionManifest: $0.manifest
                    )
                },
                openedByteCount
            )
        }
        guard let candidate = distinctManifests.first else {
            return ([], openedByteCount)
        }
        let (publication, publicationBytes) = try readPublication(
            announcementURL: candidate.announcementURL,
            producerID: candidate.producerID,
            sequence: candidate.sequence,
            expectedPreviousSealDigest: candidate.previousSealDigest
        )
        openedByteCount = min(
            Int64.max,
            openedByteCount + publicationBytes
        )
        return (
            [publication],
            openedByteCount
        )
    }

    private func decodedAnnouncement(
        at url: URL,
        producerID: UUID,
        sequence: UInt64
    ) throws -> (
        announcement: Announcement,
        digest: ReplicationDigest,
        data: Data
    ) {
        guard let digest = ReplicationDigest(
            rawValue: url.deletingPathExtension().lastPathComponent
        ) else {
            throw FileReplicationEndpointError.invalidObject
        }
        let data = try readAndValidate(url: url, digest: digest)
        let announcement: Announcement
        do {
            announcement = try decoder.decode(Announcement.self, from: data)
        } catch {
            throw FileReplicationEndpointError.invalidObject
        }
        guard announcement.formatVersion
                == ReplicationPublicationBuilder.formatVersion,
              announcement.generationID == generationID,
              announcement.producerID == producerID,
              announcement.sequence == sequence
        else {
            throw FileReplicationEndpointError.invalidObject
        }
        return (announcement, digest, data)
    }

    func readExactObject(
        _ reference: ReplicationObjectReference
    ) throws -> Data {
        let url = try objectURL(for: reference)
        return try readAndValidate(url: url, digest: reference.digest)
    }

    func readAndValidate(
        url: URL,
        digest: ReplicationDigest
    ) throws -> Data {
        guard fileManager.fileExists(atPath: url.path) else {
            throw FileReplicationEndpointError.objectNotMaterialized(
                relativeKey: try relativeKey(for: url)
            )
        }
        let data = try readData(at: url)
        guard try ReplicationPublicationBuilder.digest(data) == digest else {
            throw FileReplicationEndpointError.invalidObject
        }
        return data
    }

    func publishImmutable(data: Data, to url: URL) throws {
        let rootPath = rootURL.standardizedFileURL.path + "/"
        let destinationPath = url.standardizedFileURL.path
        guard destinationPath.hasPrefix(rootPath) else {
            throw FileReplicationEndpointError.invalidObject
        }
        do {
            _ = try filePublisher.publish(
                data,
                to: String(destinationPath.dropFirst(rootPath.count)),
                stagingArea: "objects"
            )
        } catch AppendOnlyFilePublicationError
            .destinationContainsDifferentBytes
        {
            throw FileReplicationEndpointError.invalidObject
        }
    }

    func readData(at url: URL) throws -> Data {
        guard fileReadPolicy == .coordinated else {
            do {
                return try fileDataReader(url)
            } catch {
                if Self.isMissingFile(error) {
                    throw FileReplicationEndpointError
                        .objectNotMaterialized(
                            relativeKey: try relativeKey(for: url)
                        )
                }
                throw error
            }
        }
        var coordinatedData: Data?
        var readError: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            do {
                coordinatedData = try fileDataReader(coordinatedURL)
            } catch {
                readError = error
            }
        }
        if let coordinationError {
            if Self.isMissingFile(coordinationError) {
                throw FileReplicationEndpointError.objectNotMaterialized(
                    relativeKey: try relativeKey(for: url)
                )
            }
            throw coordinationError
        }
        if let readError {
            if Self.isMissingFile(readError) {
                throw FileReplicationEndpointError.objectNotMaterialized(
                    relativeKey: try relativeKey(for: url)
                )
            }
            throw readError
        }
        guard let coordinatedData else {
            throw FileReplicationEndpointError.objectNotMaterialized(
                relativeKey: try relativeKey(for: url)
            )
        }
        return coordinatedData
    }

    func relativeKey(for url: URL) throws -> String {
        let rootPath = rootURL.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else {
            throw FileReplicationEndpointError.invalidObject
        }
        let relativeKey = String(path.dropFirst(rootPath.count))
        guard relativeKey.isEmpty == false else {
            throw FileReplicationEndpointError.invalidObject
        }
        return relativeKey
    }

    static func isMissingFile(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == NSFileNoSuchFileError
                || nsError.code == CocoaError.fileReadNoSuchFile.rawValue
        }
        return nsError.domain == NSPOSIXErrorDomain
            && nsError.code == POSIXErrorCode.ENOENT.rawValue
    }
}
