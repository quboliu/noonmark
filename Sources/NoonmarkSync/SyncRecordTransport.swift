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
}

extension SyncRecordTransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .immutableRecordCollision(recordID):
            "Immutable sync record collision for id \(recordID.rawValue)"
        case let .invalidCurrentRecordMerge(recordID, reason):
            "Current sync records cannot be merged for id \(recordID.rawValue)"
                + " (reason: \(reason.rawValue))"
        }
    }
}

public protocol SyncRecordTransport: Sendable {
    func push(_ records: [SyncRecord]) async throws
    func fetchAll() async throws -> [SyncRecord]
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
        if order != .equivalent { return order }
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
    if lhs < rhs { return .before }
    if lhs > rhs { return .after }
    return .equivalent
}

private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> SyncRecordLWWOrder {
    if lhs < rhs { return .before }
    if lhs > rhs { return .after }
    return .equivalent
}

private func compareUTF8(_ lhs: String, _ rhs: String) -> SyncRecordLWWOrder {
    compareBytes(Data(lhs.utf8), Data(rhs.utf8))
}

private func compareBytes(_ lhs: Data, _ rhs: Data) -> SyncRecordLWWOrder {
    if lhs == rhs { return .equivalent }
    return lhs.lexicographicallyPrecedes(rhs) ? .before : .after
}
