import Foundation

public enum SyncRecordTransportError: Error, Equatable, Sendable {
    case immutableRecordCollision(recordID: SyncRecordID)
    case invalidCurrentRecordMerge(recordID: SyncRecordID)
}

extension SyncRecordTransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .immutableRecordCollision(recordID):
            "Immutable sync record collision for id \(recordID.rawValue)"
        case let .invalidCurrentRecordMerge(recordID):
            "Current sync records cannot be merged for id \(recordID.rawValue)"
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

extension SyncRecord {
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
