import CryptoKit
import Foundation

public enum ReplicationProtocolError: Error, Equatable, Sendable {
    case invalidDigest
    case invalidPublication
}

public enum ReplicationForkResolutionDecision:
    String,
    Codable,
    Equatable,
    Sendable
{
    case keepCurrent
    case acceptRemote
    case copyAsNew
}

public struct ReplicationForkResolutionResultReference:
    Codable,
    Equatable,
    Sendable
{
    public let entityType: SyncEntityType
    public let entityID: String

    public init(entityType: SyncEntityType, entityID: String) {
        self.entityType = entityType
        self.entityID = entityID
    }
}

public struct ReplicationForkResolutionOutcome:
    Codable,
    Equatable,
    Sendable
{
    public let conflictID: UUID
    public let decision: ReplicationForkResolutionDecision
    public let resultReference: ReplicationForkResolutionResultReference?

    public init(
        conflictID: UUID,
        decision: ReplicationForkResolutionDecision,
        resultReference: ReplicationForkResolutionResultReference?
    ) {
        self.conflictID = conflictID
        self.decision = decision
        self.resultReference = resultReference
    }
}

public struct ReplicationForkResolutionManifest:
    Codable,
    Equatable,
    Sendable
{
    public let resolutionID: ReplicationDigest
    public let decidedAt: Date?
    public let outcomes: [ReplicationForkResolutionOutcome]

    public init(
        resolutionID: ReplicationDigest,
        decidedAt: Date?,
        outcomes: [ReplicationForkResolutionOutcome]
    ) {
        self.resolutionID = resolutionID
        self.decidedAt = decidedAt
        self.outcomes = outcomes.sorted {
            $0.conflictID.uuidString < $1.conflictID.uuidString
        }
    }
}

public struct ReplicationDigest:
    Codable,
    Hashable,
    RawRepresentable,
    Sendable
{
    public let rawValue: String

    public init?(rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public init(validating rawValue: String) throws {
        guard Self.isValid(rawValue) else {
            throw ReplicationProtocolError.invalidDigest
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(validating: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func isValid(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }
}

public struct ReplicationPublicationReference:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let generationID: UUID
    public let producerID: UUID
    public let sequence: UInt64
    public let previousSealDigest: ReplicationDigest?
    public let rootDigest: ReplicationDigest
    public let sealDigest: ReplicationDigest
    public let announcementDigest: ReplicationDigest
    public let basedOnResolutionID: ReplicationDigest?

    public init(
        generationID: UUID,
        producerID: UUID,
        sequence: UInt64,
        previousSealDigest: ReplicationDigest?,
        rootDigest: ReplicationDigest,
        sealDigest: ReplicationDigest,
        announcementDigest: ReplicationDigest,
        basedOnResolutionID: ReplicationDigest? = nil
    ) {
        self.generationID = generationID
        self.producerID = producerID
        self.sequence = sequence
        self.previousSealDigest = previousSealDigest
        self.rootDigest = rootDigest
        self.sealDigest = sealDigest
        self.announcementDigest = announcementDigest
        self.basedOnResolutionID = basedOnResolutionID
    }

    public var hasValidChainShape: Bool {
        sequence > 0
            && sequence <= UInt64(Int64.max)
            && ((sequence == 1) == (previousSealDigest == nil))
    }
}

public struct ReplicationSelfWatermark:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let sequence: UInt64
    public let sealDigest: ReplicationDigest

    public init(
        sequence: UInt64,
        sealDigest: ReplicationDigest
    ) {
        self.sequence = sequence
        self.sealDigest = sealDigest
    }
}

public struct ReplicationResolvedForkPosition:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let forkSequence: UInt64
    public let resolutionID: ReplicationDigest

    public init(
        forkSequence: UInt64,
        resolutionID: ReplicationDigest
    ) {
        self.forkSequence = forkSequence
        self.resolutionID = resolutionID
    }
}

public enum ReplicationObjectKind:
    String,
    Codable,
    CaseIterable,
    Hashable,
    Sendable
{
    case chunk
    case root
    case seal
    case announcement
}

public struct ReplicationObjectReference:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let kind: ReplicationObjectKind
    public let relativeKey: String
    public let digest: ReplicationDigest
    public let byteCount: Int64

    public init(
        kind: ReplicationObjectKind,
        relativeKey: String,
        digest: ReplicationDigest,
        byteCount: Int64
    ) {
        self.kind = kind
        self.relativeKey = relativeKey
        self.digest = digest
        self.byteCount = byteCount
    }
}

public struct ReplicationImmutableObject: Codable, Equatable, Sendable {
    public let reference: ReplicationObjectReference
    public let bytes: Data

    public init(
        reference: ReplicationObjectReference,
        bytes: Data
    ) {
        self.reference = reference
        self.bytes = bytes
    }
}

public struct SealedReplicationPublication: Codable, Equatable, Sendable {
    public let reference: ReplicationPublicationReference
    public let objects: [ReplicationImmutableObject]
    public let records: [SyncRecord]
    public let resolutionManifest: ReplicationForkResolutionManifest?

    public init(
        reference: ReplicationPublicationReference,
        objects: [ReplicationImmutableObject],
        records: [SyncRecord],
        resolutionManifest: ReplicationForkResolutionManifest? = nil
    ) {
        self.reference = reference
        self.objects = objects
        self.records = records
        self.resolutionManifest = resolutionManifest
    }
}

public struct ReplicationPublicationReceipt:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let reference: ReplicationPublicationReference
    public let objects: [ReplicationObjectReference]

    public init(
        reference: ReplicationPublicationReference,
        objects: [ReplicationObjectReference]
    ) {
        self.reference = reference
        self.objects = objects
    }
}

public enum ReplicationPublicationObservationState:
    String,
    Codable,
    Equatable,
    Sendable
{
    case confirmed
    case awaiting
    case blockedUserAttention
    case blockedCorruption
}

public struct ReplicationPublicationObservation: Equatable, Sendable {
    public let reference: ReplicationPublicationReference
    public let state: ReplicationPublicationObservationState

    public init(
        reference: ReplicationPublicationReference,
        state: ReplicationPublicationObservationState
    ) {
        self.reference = reference
        self.state = state
    }
}

public struct ReplicationReadCursor: Codable, Equatable, Sendable {
    public static let origin = Self(positions: [:], resolvedForks: [:])

    public let positions: [UUID: ReplicationSelfWatermark]
    public let resolvedForks: [UUID: ReplicationResolvedForkPosition]

    public init(
        positions: [UUID: ReplicationSelfWatermark],
        resolvedForks: [UUID: ReplicationResolvedForkPosition] = [:]
    ) {
        self.positions = positions
        self.resolvedForks = resolvedForks
    }

    public func position(for producerID: UUID) -> ReplicationSelfWatermark? {
        positions[producerID]
    }

    public func advancing(
        producerID: UUID,
        to watermark: ReplicationSelfWatermark
    ) -> Self {
        var advanced = positions
        advanced[producerID] = watermark
        return Self(
            positions: advanced,
            resolvedForks: resolvedForks
        )
    }

    public func resolving(_ evidence: ReplicationForkEvidence) -> Self {
        var advanced = positions
        advanced.removeValue(forKey: evidence.producerID)
        var resolved = resolvedForks
        resolved[evidence.producerID] = ReplicationResolvedForkPosition(
            forkSequence: evidence.sequence,
            resolutionID: evidence.resolutionID
        )
        return Self(positions: advanced, resolvedForks: resolved)
    }
}

public struct ReplicationReadBudget: Equatable, Sendable {
    public let maximumPublications: Int
    public let maximumBytes: Int64

    public init(
        maximumPublications: Int,
        maximumBytes: Int64
    ) {
        self.maximumPublications = maximumPublications
        self.maximumBytes = maximumBytes
    }
}

public struct ReceivedReplicationPublication: Codable, Equatable, Sendable {
    public let reference: ReplicationPublicationReference
    public let records: [SyncRecord]
    public let resolutionManifest: ReplicationForkResolutionManifest?

    public init(
        reference: ReplicationPublicationReference,
        records: [SyncRecord],
        resolutionManifest: ReplicationForkResolutionManifest? = nil
    ) {
        self.reference = reference
        self.records = records
        self.resolutionManifest = resolutionManifest
    }
}

public struct ReplicationForkEvidence: Equatable, Sendable {
    private struct Identity: Codable {
        let formatVersion: Int
        let generationID: UUID
        let producerID: UUID
        let forkSequence: UInt64
        let branchReferences: [ReplicationPublicationReference]
    }

    public let resolutionID: ReplicationDigest
    public let generationID: UUID
    public let producerID: UUID
    public let sequence: UInt64
    public let commonPrefix: ReplicationSelfWatermark?
    public let branches: [ReceivedReplicationPublication]

    public init(branches: [ReceivedReplicationPublication]) throws {
        let ordered = branches.sorted {
            if $0.reference.sequence != $1.reference.sequence {
                return $0.reference.sequence < $1.reference.sequence
            }
            return $0.reference.sealDigest.rawValue
                < $1.reference.sealDigest.rawValue
        }
        guard let first = ordered.first,
              ordered.count >= 2,
              Set(ordered.map(\.reference)).count == ordered.count,
              Set(ordered.map(\.reference.sealDigest)).count == ordered.count,
              ordered.allSatisfy({ branch in
                  branch.reference.hasValidChainShape
                      && branch.reference.generationID
                      == first.reference.generationID
                      && branch.reference.producerID
                      == first.reference.producerID
              })
        else {
            throw ReplicationProtocolError.invalidPublication
        }
        let forkSequence = first.reference.sequence
        let roots = ordered.filter {
            $0.reference.sequence == forkSequence
        }
        guard roots.count >= 2,
              Set(roots.map(\.reference.previousSealDigest)).count == 1
        else {
            throw ReplicationProtocolError.invalidPublication
        }
        let previousSealDigest = roots[0].reference.previousSealDigest
        if forkSequence == 1 {
            guard previousSealDigest == nil else {
                throw ReplicationProtocolError.invalidPublication
            }
            commonPrefix = nil
        } else {
            guard let previousSealDigest else {
                throw ReplicationProtocolError.invalidPublication
            }
            commonPrefix = ReplicationSelfWatermark(
                sequence: forkSequence - 1,
                sealDigest: previousSealDigest
            )
        }
        let publicationsBySequence = Dictionary(
            grouping: ordered,
            by: { $0.reference.sequence }
        )
        guard let lastSequence = ordered.last?.reference.sequence else {
            throw ReplicationProtocolError.invalidPublication
        }
        if lastSequence > forkSequence {
            for currentSequence in (forkSequence + 1) ... lastSequence {
                guard let current = publicationsBySequence[currentSequence],
                      let predecessors = publicationsBySequence[
                          currentSequence - 1
                      ],
                      current.isEmpty == false
                else {
                    throw ReplicationProtocolError.invalidPublication
                }
                let predecessorSeals = Set(
                    predecessors.map(\.reference.sealDigest)
                )
                guard current.allSatisfy({ publication in
                    guard let previous = publication.reference
                        .previousSealDigest
                    else { return false }
                    return predecessorSeals.contains(previous)
                }) else {
                    throw ReplicationProtocolError.invalidPublication
                }
            }
        }
        generationID = first.reference.generationID
        producerID = first.reference.producerID
        sequence = forkSequence
        self.branches = ordered
        let identity = Identity(
            formatVersion: ReplicationPublicationBuilder.formatVersion,
            generationID: generationID,
            producerID: producerID,
            forkSequence: sequence,
            branchReferences: ordered.map(\.reference)
        )
        resolutionID = try ReplicationPublicationBuilder.digest(
            ReplicationPublicationBuilder.canonicalEncoder().encode(identity)
        )
    }
}

public enum ReplicationReadState: Equatable, Sendable {
    case stable
    case awaitingMaterialization
    case blockedProducerFork(ReplicationForkEvidence)
}

public struct ReplicationReadPage: Equatable, Sendable {
    public let publications: [ReceivedReplicationPublication]
    public let resolutionBaselines: [ReceivedReplicationPublication]
    public let cursor: ReplicationReadCursor
    public let hasMore: Bool
    public let openedByteCount: Int64
    public let state: ReplicationReadState

    public init(
        publications: [ReceivedReplicationPublication],
        resolutionBaselines: [ReceivedReplicationPublication] = [],
        cursor: ReplicationReadCursor,
        hasMore: Bool,
        openedByteCount: Int64,
        state: ReplicationReadState
    ) {
        self.publications = publications
        self.resolutionBaselines = resolutionBaselines
        self.cursor = cursor
        self.hasMore = hasMore
        self.openedByteCount = openedByteCount
        self.state = state
    }
}

public protocol ReplicationEndpoint: Sendable {
    var namespace: String { get }

    func publish(
        sealed publication: SealedReplicationPublication
    ) async throws -> ReplicationPublicationReceipt

    func observe(
        pending receipts: [ReplicationPublicationReceipt]
    ) async throws -> [ReplicationPublicationObservation]

    func read(
        after cursor: ReplicationReadCursor,
        budget: ReplicationReadBudget
    ) async throws -> ReplicationReadPage

    func cancelAndJoin() async
}

public struct ReplicationPublicationBuilder: Sendable {
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

    public static let formatVersion = 2

    public let maximumRecordsPerChunk: Int

    public init(maximumRecordsPerChunk: Int = 128) {
        self.maximumRecordsPerChunk = maximumRecordsPerChunk
    }

    public func seal(
        records: [SyncRecord],
        generationID: UUID,
        producerID: UUID,
        sequence: UInt64,
        previousSealDigest: ReplicationDigest?,
        basedOnResolutionID: ReplicationDigest? = nil,
        resolutionManifest: ReplicationForkResolutionManifest? = nil
    ) throws -> SealedReplicationPublication {
        guard maximumRecordsPerChunk > 0,
              records.isEmpty == false,
              sequence > 0,
              sequence <= UInt64(Int64.max),
              (sequence == 1) == (previousSealDigest == nil),
              try Self.resolutionManifestIsValid(
                  resolutionManifest,
                  basedOnResolutionID: basedOnResolutionID
              )
        else {
            throw ReplicationProtocolError.invalidPublication
        }
        let currentRecords = try CurrentSyncRecordMerger()
            .prepareTransportBatch(
                existingRecords: [],
                incomingRecords: records
            ).records
        let canonicalRecords = currentRecords.sorted {
            SyncRecordEvidenceID(record: $0).rawValue
                < SyncRecordEvidenceID(record: $1).rawValue
        }
        let encoder = Self.canonicalEncoder()
        var objects: [ReplicationImmutableObject] = []
        var chunkDigests: [ReplicationDigest] = []
        var start = 0
        while start < canonicalRecords.count {
            let end = min(
                start + maximumRecordsPerChunk,
                canonicalRecords.count
            )
            let data = try encoder.encode(
                Chunk(
                    formatVersion: Self.formatVersion,
                    records: Array(canonicalRecords[start ..< end])
                )
            )
            let object = try Self.object(
                kind: .chunk,
                data: data
            )
            objects.append(object)
            chunkDigests.append(object.reference.digest)
            start = end
        }
        let rootData = try encoder.encode(
            Root(
                formatVersion: Self.formatVersion,
                generationID: generationID,
                producerID: producerID,
                sequence: sequence,
                previousSealDigest: previousSealDigest,
                basedOnResolutionID: basedOnResolutionID,
                resolutionManifest: resolutionManifest,
                chunkDigests: chunkDigests,
                recordCount: canonicalRecords.count
            )
        )
        let rootObject = try Self.object(kind: .root, data: rootData)
        objects.append(rootObject)
        let sealData = try encoder.encode(
            Seal(
                formatVersion: Self.formatVersion,
                generationID: generationID,
                producerID: producerID,
                sequence: sequence,
                rootDigest: rootObject.reference.digest
            )
        )
        let sealObject = try Self.object(kind: .seal, data: sealData)
        objects.append(sealObject)
        let announcementData = try encoder.encode(
            Announcement(
                formatVersion: Self.formatVersion,
                generationID: generationID,
                producerID: producerID,
                sequence: sequence,
                previousSealDigest: previousSealDigest,
                rootDigest: rootObject.reference.digest,
                sealDigest: sealObject.reference.digest
            )
        )
        let announcementObject = try Self.announcementObject(
            data: announcementData,
            generationID: generationID,
            producerID: producerID,
            sequence: sequence
        )
        objects.append(announcementObject)
        let reference = ReplicationPublicationReference(
            generationID: generationID,
            producerID: producerID,
            sequence: sequence,
            previousSealDigest: previousSealDigest,
            rootDigest: rootObject.reference.digest,
            sealDigest: sealObject.reference.digest,
            announcementDigest: announcementObject.reference.digest,
            basedOnResolutionID: basedOnResolutionID
        )
        return SealedReplicationPublication(
            reference: reference,
            objects: objects,
            records: canonicalRecords,
            resolutionManifest: resolutionManifest
        )
    }

    static func resolutionManifestIsValid(
        _ manifest: ReplicationForkResolutionManifest?,
        basedOnResolutionID: ReplicationDigest?
    ) throws -> Bool {
        guard (manifest == nil) == (basedOnResolutionID == nil) else {
            return false
        }
        guard let manifest, let basedOnResolutionID else { return true }
        guard manifest.resolutionID == basedOnResolutionID,
              Set(manifest.outcomes.map(\.conflictID)).count
              == manifest.outcomes.count,
              manifest.outcomes == manifest.outcomes.sorted(by: {
                  $0.conflictID.uuidString < $1.conflictID.uuidString
              }),
              (manifest.outcomes.isEmpty
                  ? manifest.decidedAt == nil
                  : manifest.decidedAt?.timeIntervalSinceReferenceDate
                      .isFinite == true)
        else { return false }
        return manifest.outcomes.allSatisfy { outcome in
            switch outcome.decision {
            case .keepCurrent:
                outcome.resultReference == nil
            case .acceptRemote:
                outcome.resultReference?.entityType == .taskDefinition
                    && outcome.resultReference.flatMap {
                        UUID(uuidString: $0.entityID)
                    } != nil
            case .copyAsNew:
                outcome.resultReference?.entityType == .taskChain
                    && outcome.resultReference.flatMap {
                        UUID(uuidString: $0.entityID)
                    } != nil
            }
        }
    }

    private static func object(
        kind: ReplicationObjectKind,
        data: Data
    ) throws -> ReplicationImmutableObject {
        let digest = try digest(data)
        return ReplicationImmutableObject(
            reference: ReplicationObjectReference(
                kind: kind,
                relativeKey: "v2/objects/\(kind.rawValue)/\(digest.rawValue).json",
                digest: digest,
                byteCount: Int64(data.count)
            ),
            bytes: data
        )
    }

    private static func announcementObject(
        data: Data,
        generationID: UUID,
        producerID: UUID,
        sequence: UInt64
    ) throws -> ReplicationImmutableObject {
        let digest = try digest(data)
        let sequenceName = String(format: "%020llu", sequence)
        let relativeKey = [
            "v2",
            "announcements",
            generationID.uuidString.lowercased(),
            producerID.uuidString.lowercased(),
            sequenceName,
            "\(digest.rawValue).json",
        ].joined(separator: "/")
        return ReplicationImmutableObject(
            reference: ReplicationObjectReference(
                kind: .announcement,
                relativeKey: relativeKey,
                digest: digest,
                byteCount: Int64(data.count)
            ),
            bytes: data
        )
    }

    static func digest(_ data: Data) throws -> ReplicationDigest {
        try ReplicationDigest(
            validating: SHA256.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined()
        )
    }

    public static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(
                date.timeIntervalSinceReferenceDate.bitPattern
            )
        }
        return encoder
    }

    public static func canonicalDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let seconds = Double(
                bitPattern: try container.decode(UInt64.self)
            )
            guard seconds.isFinite else {
                throw ReplicationProtocolError.invalidPublication
            }
            return Date(timeIntervalSinceReferenceDate: seconds)
        }
        return decoder
    }
}
