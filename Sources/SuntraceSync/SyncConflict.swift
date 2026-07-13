import CryptoKit
import Foundation
import SuntraceCore

public enum SyncConflictType: String, Codable, Hashable, Sendable {
    case historicalTraceMutation
    case historicalSubtaskMutation
    case taskDefinitionMutation
    case duplicateActiveTrace
    case missingParent
    case invalidReference
    case unsupportedDelete
    case invalidRecordPayload
    case classificationCommitRejected
    case classificationSnapshotMutation
    case traceClassificationEventRejected
}

public enum SyncConflictResolution: String, Codable, Hashable, Sendable {
    case unresolved
    case keepLocal
    case acceptRemote
    case copyAsNew
    case ignored
}

public struct SyncConflict: Codable, Equatable, Sendable {
    public var id: UUID
    public var type: SyncConflictType
    public var entityType: SyncEntityType
    public var entityID: String
    public var localRecordID: SyncRecordID?
    public var remoteRecord: SyncRecord
    public var detectedAt: Date
    public var message: String
    public var resolution: SyncConflictResolution

    public init(
        id: UUID? = nil,
        type: SyncConflictType,
        entityType: SyncEntityType,
        entityID: String,
        localRecordID: SyncRecordID? = nil,
        remoteRecord: SyncRecord,
        detectedAt: Date = Date(),
        message: String,
        resolution: SyncConflictResolution = .unresolved
    ) {
        self.id = id ?? Self.canonicalEvidenceID(
            type: type,
            entityType: entityType,
            entityID: entityID,
            localRecordID: localRecordID,
            remoteRecord: remoteRecord
        )
        self.type = type
        self.entityType = entityType
        self.entityID = entityID
        self.localRecordID = localRecordID
        self.remoteRecord = remoteRecord
        self.detectedAt = detectedAt
        self.message = message
        self.resolution = resolution
    }

    public var remoteRecordID: SyncRecordID { remoteRecord.id }

    public var canonicalEvidenceID: UUID {
        Self.canonicalEvidenceID(
            type: type,
            entityType: entityType,
            entityID: entityID,
            localRecordID: localRecordID,
            remoteRecord: remoteRecord
        )
    }

    private static func canonicalEvidenceID(
        type: SyncConflictType,
        entityType: SyncEntityType,
        entityID: String,
        localRecordID: SyncRecordID?,
        remoteRecord: SyncRecord
    ) -> UUID {
        var evidence = Data()
        func append(_ value: Data) {
            var count = UInt64(value.count).bigEndian
            withUnsafeBytes(of: &count) { evidence.append(contentsOf: $0) }
            evidence.append(value)
        }
        func append(_ value: String) {
            append(Data(value.utf8))
        }

        append("noonmark.sync-conflict.canonical-evidence.v1")
        append(type.rawValue)
        append(entityType.rawValue)
        append(entityID)
        if let localRecordID {
            append(Data([1]))
            append(localRecordID.rawValue)
        } else {
            append(Data([0]))
        }
        append(remoteRecord.id.rawValue)
        append(remoteRecord.entityType.rawValue)
        append(remoteRecord.entityID)
        append(remoteRecord.operation.rawValue)
        var modifiedAtBits = remoteRecord.modifiedAt.timeIntervalSinceReferenceDate
            .bitPattern.bigEndian
        withUnsafeBytes(of: &modifiedAtBits) { append(Data($0)) }
        append(remoteRecord.modifiedByDeviceID.rawValue)
        append(remoteRecord.payload)

        var bytes = Array(SHA256.hash(data: evidence).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        let value = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
        guard let id = UUID(uuidString: value) else {
            preconditionFailure("canonical sync conflict digest did not form a UUID")
        }
        return id
    }
}

public enum SyncTerminalRecordIdentity: Hashable, Sendable {
    case classificationCommit(UUID)
    case traceClassificationEvent(UUID)

    public init?(record: SyncRecord) {
        guard let id = UUID(uuidString: record.entityID),
              id.uuidString == record.entityID
        else { return nil }
        switch record.entityType {
        case .classificationCommit
        where record.id.rawValue == "classification-commit:\(record.entityID)":
            self = .classificationCommit(id)
        case .traceClassificationEvent
        where record.id.rawValue == "trace-classification-event:\(record.entityID)":
            self = .traceClassificationEvent(id)
        default:
            return nil
        }
    }

    public var entityType: SyncEntityType {
        switch self {
        case .classificationCommit:
            .classificationCommit
        case .traceClassificationEvent:
            .traceClassificationEvent
        }
    }

    public var entityID: String {
        switch self {
        case let .classificationCommit(id), let .traceClassificationEvent(id):
            id.uuidString
        }
    }
}

public struct SyncTerminalRejection: Equatable, Sendable {
    public let identity: SyncTerminalRecordIdentity
    public let conflict: SyncConflict

    public init?(conflict: SyncConflict) {
        guard conflict.entityType.requiresImmutableRecordPayload,
              conflict.entityType == conflict.remoteRecord.entityType,
              conflict.entityID == conflict.remoteRecord.entityID,
              let identity = SyncTerminalRecordIdentity(record: conflict.remoteRecord)
        else { return nil }
        self.identity = identity
        self.conflict = conflict
    }
}

public struct SyncMergeResult: Equatable, Sendable {
    public var snapshot: SuntraceSnapshot
    public var appliedRecordIDs: [SyncRecordID]
    public var waitingRecords: [SyncWaitingRecord]
    public var conflicts: [SyncConflict]

    public init(
        snapshot: SuntraceSnapshot,
        appliedRecordIDs: [SyncRecordID],
        waitingRecords: [SyncWaitingRecord] = [],
        conflicts: [SyncConflict]
    ) {
        self.snapshot = snapshot
        self.appliedRecordIDs = appliedRecordIDs
        self.waitingRecords = waitingRecords
        self.conflicts = conflicts
    }
}

/// 尚未满足依赖的远端记录。它不是冲突，也不是已应用；调用端必须保存完整记录，
/// 并在依赖事实到达后重新验证。
public struct SyncWaitingRecord: Equatable, Sendable {
    public let record: SyncRecord
    public let dependencies: [ClassificationCommitDependency]

    public init(
        record: SyncRecord,
        dependencies: [ClassificationCommitDependency]
    ) {
        self.record = record
        self.dependencies = dependencies
    }

    public var remoteRecordID: SyncRecordID { record.id }
    public var entityID: String { record.entityID }
}
