import Foundation

public enum CloudKitSyncPersistenceError: Error, Equatable, Sendable {
    case duplicateRecordID(SyncRecordID)
    case invalidSnapshot
    case inactiveLease
}

extension CloudKitSyncPersistenceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .duplicateRecordID(recordID):
            "CloudKit mirror contains duplicate record id \(recordID.rawValue)."
        case .invalidSnapshot:
            "CloudKit sync state is corrupted or cannot be decoded."
        case .inactiveLease:
            "CloudKit sync persistence was invalidated before this operation."
        }
    }
}

public final class CloudKitSyncPersistenceLease: @unchecked Sendable {
    private let lock = NSLock()
    private var isActive = true

    public init() {}

    public func invalidate() {
        lock.lock()
        isActive = false
        lock.unlock()
    }

    public func withActiveAccess<Result>(
        _ operation: () throws -> Result
    ) throws -> Result {
        lock.lock()
        defer { lock.unlock() }
        guard isActive else {
            throw CloudKitSyncPersistenceError.inactiveLease
        }
        return try operation()
    }
}

public struct CloudKitMirroredSyncRecord: Codable, Equatable, Sendable {
    public let record: SyncRecord
    public let serverRecordSystemFields: Data?

    public init(
        record: SyncRecord,
        serverRecordSystemFields: Data?
    ) {
        self.record = record
        self.serverRecordSystemFields = serverRecordSystemFields
    }
}

public struct CloudKitSyncInboxEntry: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let record: SyncRecord

    public init(sequence: UInt64, record: SyncRecord) {
        self.sequence = sequence
        self.record = record
    }
}

public enum CloudKitSyncEnvironment: String, Codable, Equatable, Sendable {
    case development = "Development"
    case production = "Production"
}

public struct CloudKitSyncScopeIdentity: Codable, Equatable, Sendable {
    public let containerIdentifier: String
    public let zoneName: String
    public let environment: CloudKitSyncEnvironment

    public init(
        containerIdentifier: String,
        zoneName: String,
        environment: CloudKitSyncEnvironment
    ) {
        self.containerIdentifier = containerIdentifier
        self.zoneName = zoneName
        self.environment = environment
    }
}

public enum CloudKitSyncBlockReason: Codable, Equatable, Sendable {
    case recordZoneDeleted
    case unexpectedRemoteRecordDeletion(String)
}

public struct CloudKitSyncPersistenceSnapshot: Codable, Equatable, Sendable {
    public static let empty = CloudKitSyncPersistenceSnapshot(
        scope: nil,
        engineState: nil,
        accountRecordName: nil,
        zoneIsProvisioned: false,
        blockReason: nil,
        nextInboxSequence: 1,
        inbox: [],
        canonicalRecords: []
    )

    public let scope: CloudKitSyncScopeIdentity?
    public let engineState: Data?
    public let accountRecordName: String?
    public let zoneIsProvisioned: Bool
    public let blockReason: CloudKitSyncBlockReason?
    public let nextInboxSequence: UInt64
    public let inbox: [CloudKitSyncInboxEntry]
    public let records: [CloudKitMirroredSyncRecord]

    public init(
        scope: CloudKitSyncScopeIdentity? = nil,
        engineState: Data? = nil,
        accountRecordName: String? = nil,
        zoneIsProvisioned: Bool = false,
        blockReason: CloudKitSyncBlockReason? = nil,
        nextInboxSequence: UInt64 = 1,
        inbox: [CloudKitSyncInboxEntry] = [],
        records: [CloudKitMirroredSyncRecord] = []
    ) throws {
        let canonicalInbox = try Self.canonicalInbox(
            inbox,
            nextSequence: nextInboxSequence
        )
        self.init(
            scope: scope,
            engineState: engineState,
            accountRecordName: accountRecordName,
            zoneIsProvisioned: zoneIsProvisioned,
            blockReason: blockReason,
            nextInboxSequence: nextInboxSequence,
            inbox: canonicalInbox,
            canonicalRecords: try Self.canonicalRecords(records)
        )
    }

    private init(
        scope: CloudKitSyncScopeIdentity?,
        engineState: Data?,
        accountRecordName: String?,
        zoneIsProvisioned: Bool,
        blockReason: CloudKitSyncBlockReason?,
        nextInboxSequence: UInt64,
        inbox: [CloudKitSyncInboxEntry],
        canonicalRecords: [CloudKitMirroredSyncRecord]
    ) {
        self.scope = scope
        self.engineState = engineState
        self.accountRecordName = accountRecordName
        self.zoneIsProvisioned = zoneIsProvisioned
        self.blockReason = blockReason
        self.nextInboxSequence = nextInboxSequence
        self.inbox = inbox
        records = canonicalRecords
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            scope: try container.decodeIfPresent(
                CloudKitSyncScopeIdentity.self,
                forKey: .scope
            ),
            engineState: try container.decodeIfPresent(
                Data.self,
                forKey: .engineState
            ),
            accountRecordName: try container.decodeIfPresent(
                String.self,
                forKey: .accountRecordName
            ),
            zoneIsProvisioned: try container.decode(
                Bool.self,
                forKey: .zoneIsProvisioned
            ),
            blockReason: try container.decodeIfPresent(
                CloudKitSyncBlockReason.self,
                forKey: .blockReason
            ),
            nextInboxSequence: try container.decodeIfPresent(
                UInt64.self,
                forKey: .nextInboxSequence
            ) ?? 1,
            inbox: try container.decodeIfPresent(
                [CloudKitSyncInboxEntry].self,
                forKey: .inbox
            ) ?? [],
            records: try container.decode(
                [CloudKitMirroredSyncRecord].self,
                forKey: .records
            )
        )
    }

    private static func canonicalInbox(
        _ inbox: [CloudKitSyncInboxEntry],
        nextSequence: UInt64
    ) throws -> [CloudKitSyncInboxEntry] {
        let ordered = inbox.sorted { $0.sequence < $1.sequence }
        let isContiguous = zip(ordered, ordered.dropFirst()).allSatisfy {
            previous,
            next in
            previous.sequence < UInt64.max
                && previous.sequence + 1 == next.sequence
        }
        let endsAtNextSequence = if let last = ordered.last {
            last.sequence < UInt64.max
                && last.sequence + 1 == nextSequence
        } else {
            true
        }
        guard nextSequence > 0,
              Set(ordered.map(\.sequence)).count == ordered.count,
              ordered.allSatisfy({
                  $0.sequence > 0 && $0.sequence < nextSequence
              }),
              isContiguous,
              endsAtNextSequence
        else {
            throw CloudKitSyncPersistenceError.invalidSnapshot
        }
        return ordered
    }

    private static func canonicalRecords(
        _ records: [CloudKitMirroredSyncRecord]
    ) throws -> [CloudKitMirroredSyncRecord] {
        var seen: Set<SyncRecordID> = []
        for mirrored in records {
            guard seen.insert(mirrored.record.id).inserted else {
                throw CloudKitSyncPersistenceError.duplicateRecordID(
                    mirrored.record.id
                )
            }
        }
        return records.sorted {
            Data($0.record.id.rawValue.utf8).lexicographicallyPrecedes(
                Data($1.record.id.rawValue.utf8)
            )
        }
    }
}

public protocol CloudKitSyncPersistence: Sendable {
    func load() async throws -> CloudKitSyncPersistenceSnapshot
    func save(_ snapshot: CloudKitSyncPersistenceSnapshot) async throws
}
