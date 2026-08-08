import CryptoKit
import Foundation

/// Privacy-safe classification of why a current-record merge was rejected.
/// Raw values are stable diagnostic tokens; they never carry record identity,
/// entity content, timestamps, or free text.
public enum SyncRecordMergeFailureReason: String, CaseIterable, Equatable, Sendable {
    /// Two records share one record ID but disagree on entity type, entity ID,
    /// or operation, so no canonical header exists.
    case inconsistentRecordHeaders
    /// The record or one merge side violates its content or mutation clock
    /// invariant (non-finite clock, content clock before creation, terminal
    /// clock outside the content window, or mutation clock bit mismatch).
    case invalidContentClock
    /// A task cycle series disagrees on stable identity (id, start date,
    /// creation clock) or reuses a revision/fact identity with new content.
    case taskCycleSeriesIdentityCollision
    /// A task chain disagrees on its creation clock or cycle membership.
    case taskChainIdentityCollision
    /// A task definition disagrees on chain, sequence, or creation clock.
    case taskDefinitionIdentityCollision
    /// A day trace disagrees on chain, creation clock, continuation, or
    /// carry-over identity.
    case dayTraceIdentityCollision
    /// Reactivation witnesses are attached to a non-chain record or fail
    /// witness validation.
    case invalidReactivationWitnesses
    /// Note entries violate entry-level invariants.
    case invalidNoteEntries
    /// The same note entry identity appears with two different creation clocks.
    case noteEntryCreatedAtCollision
    /// A record payload cannot be decoded or fails payload-level validation.
    case invalidRecordPayload
    /// The rejection cause did not carry a more specific typed reason.
    case unknown
}

public enum SyncRecordTransportError: Error, Equatable, Sendable {
    case immutableRecordCollision(recordID: SyncRecordID)
    case invalidCurrentRecordMerge(
        recordID: SyncRecordID,
        reason: SyncRecordMergeFailureReason
    )
    case invalidFrontier
    case frontierDidNotAdvance
    case repositoryFormatMismatch
    case producerFork(producerID: String, sequence: UInt64)
    case missingBatch(producerID: String, sequence: UInt64)
    case invalidBatchHash(producerID: String, sequence: UInt64)
}

extension SyncRecordTransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .immutableRecordCollision(recordID):
            "Immutable sync record collision for id \(recordID.rawValue)"
        case let .invalidCurrentRecordMerge(recordID, reason):
            "Current sync records cannot be merged for id \(recordID.rawValue)"
                + " (reason: \(reason.rawValue))"
        case .invalidFrontier:
            "The sync frontier is invalid for this endpoint."
        case .frontierDidNotAdvance:
            "The sync endpoint returned more changes without advancing its frontier."
        case .repositoryFormatMismatch:
            "The sync repository uses an incompatible format."
        case let .producerFork(producerID, sequence):
            "The sync producer \(producerID) forked at sequence \(sequence)."
        case let .missingBatch(producerID, sequence):
            "The sync producer \(producerID) is missing sequence \(sequence)."
        case let .invalidBatchHash(producerID, sequence):
            "The sync producer \(producerID) failed hash validation at sequence \(sequence)."
        }
    }
}

public struct SyncTransportPosition: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let contentHash: String

    public init(sequence: UInt64, contentHash: String) {
        self.sequence = sequence
        self.contentHash = contentHash
    }
}

public struct SyncTransportFrontier: Codable, Equatable, Sendable {
    public static let origin = SyncTransportFrontier(positions: [:])

    public let positions: [String: SyncTransportPosition]

    public init(positions: [String: SyncTransportPosition]) {
        self.positions = positions
    }

    public func position(for producerID: String) -> SyncTransportPosition? {
        positions[producerID]
    }

    public func advancing(
        producerID: String,
        to position: SyncTransportPosition
    ) -> Self {
        var advanced = positions
        advanced[producerID] = position
        return Self(positions: advanced)
    }
}

public struct SyncTransportBatchReference: Codable, Equatable, Sendable {
    public let producerID: String
    public let sequence: UInt64
    public let contentHash: String
    /// Repository-relative artifact paths only. Absolute user paths must never
    /// cross the transport or diagnostic boundary.
    public let artifactPaths: [String]

    public init(
        producerID: String,
        sequence: UInt64,
        contentHash: String,
        artifactPaths: [String] = []
    ) {
        self.producerID = producerID
        self.sequence = sequence
        self.contentHash = contentHash
        self.artifactPaths = artifactPaths
    }
}

public enum SyncTransportConfirmation: String, Codable, Equatable, Sendable {
    case confirmed
    case awaitingUploadConfirmation
    case blockedUserAttention
    case blockedCorruption
}

public struct SyncTransportPushReceipt: Codable, Equatable, Sendable {
    public let batches: [SyncTransportBatchReference]
    public let confirmation: SyncTransportConfirmation

    public init(
        batches: [SyncTransportBatchReference],
        confirmation: SyncTransportConfirmation
    ) {
        self.batches = batches
        self.confirmation = confirmation
    }

    public func replacingConfirmation(
        _ confirmation: SyncTransportConfirmation
    ) -> Self {
        Self(batches: batches, confirmation: confirmation)
    }
}

public struct SyncTransportChangePage: Equatable, Sendable {
    public let records: [SyncRecord]
    public let frontier: SyncTransportFrontier
    public let hasMore: Bool
    public let batches: [SyncTransportBatchReference]
    public let observedProducerCount: Int
    public let openedBatchCount: Int
    public let openedByteCount: Int64

    public init(
        records: [SyncRecord],
        frontier: SyncTransportFrontier,
        hasMore: Bool,
        batches: [SyncTransportBatchReference] = [],
        observedProducerCount: Int = 0,
        openedBatchCount: Int = 0,
        openedByteCount: Int64 = 0
    ) {
        self.records = records
        self.frontier = frontier
        self.hasMore = hasMore
        self.batches = batches
        self.observedProducerCount = observedProducerCount
        self.openedBatchCount = openedBatchCount
        self.openedByteCount = openedByteCount
    }
}

public protocol SyncRecordTransport: Sendable {
    /// Stable local namespace used to isolate durable apply frontiers when the
    /// configured endpoint changes. It must not expose a user path or account.
    var frontierNamespace: String { get }
    func push(_ records: [SyncRecord]) async throws
    func pushAccepting(
        _ records: [SyncRecord]
    ) async throws -> SyncTransportPushReceipt
    func pull(
        after frontier: SyncTransportFrontier,
        limit: Int
    ) async throws -> SyncTransportChangePage
    func confirmationStatus(
        for receipt: SyncTransportPushReceipt
    ) async throws -> SyncTransportConfirmation
    func acknowledge(
        _ frontier: SyncTransportFrontier
    ) async throws
    func fetchAll() async throws -> [SyncRecord]
}

public extension SyncRecordTransport {
    var frontierNamespace: String {
        String(reflecting: Self.self)
    }

    func confirmationStatus(
        for receipt: SyncTransportPushReceipt
    ) async throws -> SyncTransportConfirmation {
        receipt.confirmation
    }

    func acknowledge(_: SyncTransportFrontier) async throws {}

    func push(_ records: [SyncRecord]) async throws {
        _ = try await pushAccepting(records)
    }

    func pushAccepting(
        _ records: [SyncRecord]
    ) async throws -> SyncTransportPushReceipt {
        try await push(records)
        return SyncTransportPushReceipt(
            batches: [],
            confirmation: .confirmed
        )
    }

    /// Compatibility seam for deterministic test transports. Shipping
    /// transports implement `pull` directly; the production coordinator never
    /// calls `fetchAll`.
    func pull(
        after frontier: SyncTransportFrontier,
        limit _: Int
    ) async throws -> SyncTransportChangePage {
        let producerID = "compatibility-snapshot"
        guard frontier.positions.keys.allSatisfy({ $0 == producerID }) else {
            throw SyncRecordTransportError.invalidFrontier
        }
        let records = try await fetchAll()
        let evidence = records.map {
            SyncRecordEvidenceID(record: $0).rawValue
        }.sorted().joined(separator: "\u{0}")
        let contentHash = SHA256.hash(data: Data(evidence.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
        if let position = frontier.position(for: producerID),
           position.contentHash == contentHash
        {
            return SyncTransportChangePage(
                records: [],
                frontier: frontier,
                hasMore: false,
                observedProducerCount: 1
            )
        }
        let previousSequence = frontier.position(
            for: producerID
        )?.sequence ?? 0
        let (sequence, overflow) = previousSequence
            .addingReportingOverflow(1)
        guard overflow == false else {
            throw SyncRecordTransportError.invalidFrontier
        }
        let advanced = frontier.advancing(
            producerID: producerID,
            to: SyncTransportPosition(
                sequence: sequence,
                contentHash: contentHash
            )
        )
        return SyncTransportChangePage(
            records: records,
            frontier: advanced,
            hasMore: false,
            observedProducerCount: 1,
            openedBatchCount: records.isEmpty ? 0 : 1
        )
    }

    /// Explicit bootstrap/debug helper. Steady-state coordinators must persist
    /// and reuse the frontier returned by `pull` instead of calling this API.
    func fetchAll() async throws -> [SyncRecord] {
        var frontier = SyncTransportFrontier.origin
        var fetched: [SyncRecord] = []
        while true {
            let page = try await pull(after: frontier, limit: 512)
            fetched.append(contentsOf: page.records)
            if page.hasMore == false {
                break
            }
            guard page.frontier != frontier else {
                throw SyncRecordTransportError.frontierDidNotAdvance
            }
            frontier = page.frontier
        }
        return try CurrentSyncRecordMerger().prepareTransportBatch(
            existingRecords: [],
            incomingRecords: fetched
        ).records
    }
}

/// Ordinary current records use this total order for monotonic LWW replacement.
/// `modifiedAt` is compared first. Exact-time ties compare the timestamp bit pattern,
/// device ID, entity type, entity ID, operation, payload, then record ID by raw UTF-8
/// bytes so every transport reaches the same winner without locale or process state.
public enum SyncRecordLWWOrder: Int, Equatable, Sendable {
    case before = -1
    case equivalent = 0
    case after = 1
}

public extension SyncRecord {
    func currentRecordLWWOrder(comparedTo other: SyncRecord) -> SyncRecordLWWOrder {
        let secondsOrder = compareFiniteSeconds(
            modifiedAt.timeIntervalSinceReferenceDate,
            other.modifiedAt.timeIntervalSinceReferenceDate
        )
        guard secondsOrder == .equivalent else { return secondsOrder }

        let bitPatternOrder = compare(
            modifiedAt.timeIntervalSinceReferenceDate.bitPattern,
            other.modifiedAt.timeIntervalSinceReferenceDate.bitPattern
        )
        guard bitPatternOrder == .equivalent else { return bitPatternOrder }

        for order in [
            compareUTF8(modifiedByDeviceID.rawValue, other.modifiedByDeviceID.rawValue),
            compareUTF8(entityType.rawValue, other.entityType.rawValue),
            compareUTF8(entityID, other.entityID),
            compareUTF8(operation.rawValue, other.operation.rawValue),
            compareBytes(payload, other.payload),
            compareDataArrays(
                reactivationWitnesses,
                other.reactivationWitnesses
            ),
            compareUTF8(id.rawValue, other.id.rawValue)
        ] where order != .equivalent {
            return order
        }
        return .equivalent
    }
}

private func compareDataArrays(
    _ lhs: [Data],
    _ rhs: [Data]
) -> SyncRecordLWWOrder {
    for (left, right) in zip(lhs, rhs) {
        let order = compareBytes(left, right)
        if order != .equivalent {
            return order
        }
    }
    return compare(lhs.count, rhs.count)
}

public extension SyncRecord {
    /// Compares every record fact, including the exact timestamp bit pattern.
    func exactlyMatches(_ other: SyncRecord) -> Bool {
        self == other
            && modifiedAt.timeIntervalSinceReferenceDate.bitPattern
                == other.modifiedAt.timeIntervalSinceReferenceDate.bitPattern
    }
}

private func compareFiniteSeconds(_ lhs: Double, _ rhs: Double) -> SyncRecordLWWOrder {
    if lhs < rhs {
        return .before
    }
    if lhs > rhs {
        return .after
    }
    return .equivalent
}

private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> SyncRecordLWWOrder {
    if lhs < rhs {
        return .before
    }
    if lhs > rhs {
        return .after
    }
    return .equivalent
}

private func compareUTF8(_ lhs: String, _ rhs: String) -> SyncRecordLWWOrder {
    compareBytes(Data(lhs.utf8), Data(rhs.utf8))
}

private func compareBytes(_ lhs: Data, _ rhs: Data) -> SyncRecordLWWOrder {
    if lhs == rhs {
        return .equivalent
    }
    return lhs.lexicographicallyPrecedes(rhs) ? .before : .after
}
