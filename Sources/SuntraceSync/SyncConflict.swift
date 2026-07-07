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
    public var remoteRecordID: SyncRecordID
    public var detectedAt: Date
    public var message: String
    public var resolution: SyncConflictResolution

    public init(
        id: UUID = UUID(),
        type: SyncConflictType,
        entityType: SyncEntityType,
        entityID: String,
        localRecordID: SyncRecordID? = nil,
        remoteRecordID: SyncRecordID,
        detectedAt: Date = Date(),
        message: String,
        resolution: SyncConflictResolution = .unresolved
    ) {
        self.id = id
        self.type = type
        self.entityType = entityType
        self.entityID = entityID
        self.localRecordID = localRecordID
        self.remoteRecordID = remoteRecordID
        self.detectedAt = detectedAt
        self.message = message
        self.resolution = resolution
    }
}

public struct SyncMergeResult: Equatable, Sendable {
    public var snapshot: SuntraceSnapshot
    public var appliedRecordIDs: [SyncRecordID]
    public var conflicts: [SyncConflict]

    public init(snapshot: SuntraceSnapshot, appliedRecordIDs: [SyncRecordID], conflicts: [SyncConflict]) {
        self.snapshot = snapshot
        self.appliedRecordIDs = appliedRecordIDs
        self.conflicts = conflicts
    }
}
