import Foundation

public struct DiagnosticSessionID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct DiagnosticOperationID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct DiagnosticIncidentID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var shortCode: String {
        String(rawValue.uuidString.prefix(8)).uppercased()
    }
}

public struct DiagnosticOperationCorrelation: Equatable, Sendable {
    public let operationID: DiagnosticOperationID
    public let incidentID: DiagnosticIncidentID

    public init(
        operationID: DiagnosticOperationID,
        incidentID: DiagnosticIncidentID
    ) {
        self.operationID = operationID
        self.incidentID = incidentID
    }
}

public enum DiagnosticCategory: String, Codable, CaseIterable, Sendable {
    case lifecycle
    case mutation
    case persistence
    case sync
    case transport
    case diagnostics
}

public enum DiagnosticSeverity: String, Codable, CaseIterable, Sendable {
    case debug
    case information
    case notice
    case error
    case fault
}

public enum DiagnosticEventCode: String, Codable, CaseIterable, Sendable {
    case sessionStarted
    case cleanShutdown
    case previousSessionInterrupted
    case operationStarted
    case operationStage
    case operationHeartbeat
    case operationSucceeded
    case operationFailed
    case mutationRejected
    case persistenceFailed
    case persistenceCheckpoint
    case persistedSyncFailureLoaded
    case recordsDropped
    case corruptRecordExcluded
    case oversizedEventDropped
    case oversizedMetricPayloadDropped

    public var isTerminal: Bool {
        self == .operationSucceeded || self == .operationFailed
    }
}

public enum DiagnosticOperationKind: String, Codable, CaseIterable, Sendable {
    case appSession
    case localFirstSync
    case taskMutation
    case persistence
    case diagnosticExport
    case metricCollection
}

public enum DiagnosticEndpoint: String, Codable, CaseIterable, Sendable {
    case none
    case localFolder
    case iCloudDrive
    case cloudKit
}

public enum DiagnosticOperationStage: String, Codable, CaseIterable, Sendable {
    case launch
    case localLoad
    case transportPrepare
    case transportLockWait
    case transportLockAcquired
    case transportLockReleased
    case transportFetch
    case baselinePrepare
    case baselineCoverageGap
    case baselineRecovery
    case upload
    case downloadMerge
    case catchUpUpload
    case finalFetch
    case coverageAndStability
    case successMetadata
    case installMergedState
    case persistenceCommit
    case exportSnapshot
    case exportWrite
}

public enum DiagnosticErrorDomain: String, Codable, CaseIterable, Sendable {
    case cocoa
    case posix
    case url
    case sqlite
    case cloudKit
    case syncProtocol
    case domainValidation
    case diagnostics
    case unknown
}

public enum DiagnosticMutationContext: String, Codable, CaseIterable, Sendable {
    case task
    case note
    case preferences
    case undo
    case redo
    case dailyReview
    case provider
}

public enum DiagnosticMutationRejectionReason: String, Codable, CaseIterable, Sendable {
    case exclusiveOperationInProgress
    case pendingApplicationRecovery
    case invalidNaturalDay
    case persistenceFailure
    case domainRule
    case unknown
}

public enum DiagnosticPersistenceComponent: String, Codable, CaseIterable, Sendable {
    case zhulongApplicationJournal
}

public enum DiagnosticPersistenceOperation: String, Codable, CaseIterable, Sendable {
    case prepare
    case clear
}

public enum DiagnosticPersistencePhase: String, Codable, CaseIterable, Sendable {
    case temporaryOpen
    case temporaryPermissions
    case temporaryWrite
    case temporaryFullSync
    case temporaryFileSync
    case temporaryClose
    case replacement
    case removal
    case directoryOpen
    case directorySync
    case directoryClose
    case observation
    case authentication
    case temporaryCleanup
    case complete
}

public enum DiagnosticPersistenceResolution: String, Codable, CaseIterable, Sendable {
    case committed
    case recoveredCommitted
    case notCommitted
    case unresolved
    case fileSyncFallback
    case cleanupFailure
    case temporaryCleanupCommitted
    case fenceResolved
}

public struct DiagnosticFailure: Codable, Equatable, Sendable {
    public let domain: DiagnosticErrorDomain
    public let code: Int

    public init(domain: DiagnosticErrorDomain, code: Int) {
        self.domain = domain
        self.code = code
    }
}

public struct DiagnosticProgress: Codable, Equatable, Sendable {
    public let attempt: Int?
    public let recordCount: Int?
    public let fileCount: Int?
    public let byteCount: Int64?
    public let pendingCount: Int?
    public let appliedCount: Int?
    public let conflictCount: Int?

    public init(
        attempt: Int? = nil,
        recordCount: Int? = nil,
        fileCount: Int? = nil,
        byteCount: Int64? = nil,
        pendingCount: Int? = nil,
        appliedCount: Int? = nil,
        conflictCount: Int? = nil
    ) {
        self.attempt = attempt.map { max(0, $0) }
        self.recordCount = recordCount.map { max(0, $0) }
        self.fileCount = fileCount.map { max(0, $0) }
        self.byteCount = byteCount.map { max(0, $0) }
        self.pendingCount = pendingCount.map { max(0, $0) }
        self.appliedCount = appliedCount.map { max(0, $0) }
        self.conflictCount = conflictCount.map { max(0, $0) }
    }
}

public struct EvidenceEvent: Codable, Equatable, Sendable {
    public let code: DiagnosticEventCode
    public let category: DiagnosticCategory
    public let severity: DiagnosticSeverity
    public let operationID: DiagnosticOperationID?
    public let incidentID: DiagnosticIncidentID?
    public let operationKind: DiagnosticOperationKind?
    public let endpoint: DiagnosticEndpoint?
    public let stage: DiagnosticOperationStage?
    public let progress: DiagnosticProgress?
    public let failure: DiagnosticFailure?
    public let failureDetail: DiagnosticFailure?
    public let durationMilliseconds: Int64?
    public let mutationContext: DiagnosticMutationContext?
    public let mutationRejectionReason: DiagnosticMutationRejectionReason?
    public let persistenceComponent: DiagnosticPersistenceComponent?
    public let persistenceOperation: DiagnosticPersistenceOperation?
    public let persistencePhase: DiagnosticPersistencePhase?
    public let persistenceResolution: DiagnosticPersistenceResolution?

    private init(
        code: DiagnosticEventCode,
        category: DiagnosticCategory,
        severity: DiagnosticSeverity,
        operationID: DiagnosticOperationID? = nil,
        incidentID: DiagnosticIncidentID? = nil,
        operationKind: DiagnosticOperationKind? = nil,
        endpoint: DiagnosticEndpoint? = nil,
        stage: DiagnosticOperationStage? = nil,
        progress: DiagnosticProgress? = nil,
        failure: DiagnosticFailure? = nil,
        failureDetail: DiagnosticFailure? = nil,
        durationMilliseconds: Int64? = nil,
        mutationContext: DiagnosticMutationContext? = nil,
        mutationRejectionReason: DiagnosticMutationRejectionReason? = nil,
        persistenceComponent: DiagnosticPersistenceComponent? = nil,
        persistenceOperation: DiagnosticPersistenceOperation? = nil,
        persistencePhase: DiagnosticPersistencePhase? = nil,
        persistenceResolution: DiagnosticPersistenceResolution? = nil
    ) {
        self.code = code
        self.category = category
        self.severity = severity
        self.operationID = operationID
        self.incidentID = incidentID
        self.operationKind = operationKind
        self.endpoint = endpoint
        self.stage = stage
        self.progress = progress
        self.failure = failure
        self.failureDetail = failureDetail
        self.durationMilliseconds = durationMilliseconds
        self.mutationContext = mutationContext
        self.mutationRejectionReason = mutationRejectionReason
        self.persistenceComponent = persistenceComponent
        self.persistenceOperation = persistenceOperation
        self.persistencePhase = persistencePhase
        self.persistenceResolution = persistenceResolution
    }

    public static func sessionStarted() -> Self {
        Self(
            code: .sessionStarted,
            category: .lifecycle,
            severity: .notice
        )
    }

    public static func cleanShutdown() -> Self {
        Self(
            code: .cleanShutdown,
            category: .lifecycle,
            severity: .notice
        )
    }

    public static func previousSessionInterrupted(
        operation: DiagnosticActiveOperation
    ) -> Self {
        Self(
            code: .previousSessionInterrupted,
            category: operation.kind.category,
            severity: .error,
            operationID: operation.id,
            operationKind: operation.kind,
            endpoint: operation.endpoint,
            stage: operation.lastStage,
            progress: operation.lastProgress,
            durationMilliseconds: max(
                0,
                Int64(
                    operation.updatedAt
                        .timeIntervalSince(operation.startedAt) * 1000
                )
            )
        )
    }

    public static func operationStarted(
        id: DiagnosticOperationID,
        kind: DiagnosticOperationKind,
        endpoint: DiagnosticEndpoint
    ) -> Self {
        Self(
            code: .operationStarted,
            category: kind.category,
            severity: .notice,
            operationID: id,
            operationKind: kind,
            endpoint: endpoint
        )
    }

    public static func operationStage(
        id: DiagnosticOperationID,
        kind: DiagnosticOperationKind,
        stage: DiagnosticOperationStage,
        progress: DiagnosticProgress?,
        durationMilliseconds: Int64? = nil
    ) -> Self {
        Self(
            code: .operationStage,
            category: kind.category,
            severity: .information,
            operationID: id,
            operationKind: kind,
            stage: stage,
            progress: progress,
            durationMilliseconds: durationMilliseconds.map { max(0, $0) }
        )
    }

    public static func operationHeartbeat(
        id: DiagnosticOperationID,
        kind: DiagnosticOperationKind,
        stage: DiagnosticOperationStage,
        progress: DiagnosticProgress?,
        durationMilliseconds: Int64
    ) -> Self {
        Self(
            code: .operationHeartbeat,
            category: kind.category,
            severity: .information,
            operationID: id,
            operationKind: kind,
            stage: stage,
            progress: progress,
            durationMilliseconds: max(0, durationMilliseconds)
        )
    }

    public static func operationSucceeded(
        id: DiagnosticOperationID,
        kind: DiagnosticOperationKind,
        endpoint: DiagnosticEndpoint,
        durationMilliseconds: Int64,
        progress: DiagnosticProgress?
    ) -> Self {
        Self(
            code: .operationSucceeded,
            category: kind.category,
            severity: .notice,
            operationID: id,
            operationKind: kind,
            endpoint: endpoint,
            progress: progress,
            durationMilliseconds: max(0, durationMilliseconds)
        )
    }

    public static func operationFailed(
        id: DiagnosticOperationID,
        incidentID: DiagnosticIncidentID,
        kind: DiagnosticOperationKind,
        endpoint: DiagnosticEndpoint,
        failure: DiagnosticFailure,
        failureDetail: DiagnosticFailure? = nil,
        durationMilliseconds: Int64,
        stage: DiagnosticOperationStage?
    ) -> Self {
        Self(
            code: .operationFailed,
            category: kind.category,
            severity: .error,
            operationID: id,
            incidentID: incidentID,
            operationKind: kind,
            endpoint: endpoint,
            stage: stage,
            failure: failure,
            failureDetail: failureDetail,
            durationMilliseconds: max(0, durationMilliseconds)
        )
    }

    public static func mutationRejected(
        context: DiagnosticMutationContext,
        reason: DiagnosticMutationRejectionReason,
        operationID: DiagnosticOperationID?,
        incidentID: DiagnosticIncidentID,
        failure: DiagnosticFailure? = nil
    ) -> Self {
        Self(
            code: .mutationRejected,
            category: .mutation,
            severity: .error,
            operationID: operationID,
            incidentID: incidentID,
            failure: failure,
            mutationContext: context,
            mutationRejectionReason: reason
        )
    }

    public static func persistenceFailed(
        failure: DiagnosticFailure,
        incidentID: DiagnosticIncidentID
    ) -> Self {
        Self(
            code: .persistenceFailed,
            category: .persistence,
            severity: .error,
            incidentID: incidentID,
            failure: failure
        )
    }

    public static func persistenceCheckpoint(
        component: DiagnosticPersistenceComponent,
        operation: DiagnosticPersistenceOperation,
        phase: DiagnosticPersistencePhase,
        resolution: DiagnosticPersistenceResolution,
        failure: DiagnosticFailure?
    ) -> Self {
        let severity: DiagnosticSeverity = switch resolution {
        case .notCommitted, .unresolved, .cleanupFailure:
            .error
        case .recoveredCommitted, .fileSyncFallback,
             .temporaryCleanupCommitted, .fenceResolved:
            .notice
        case .committed:
            .information
        }
        return Self(
            code: .persistenceCheckpoint,
            category: .persistence,
            severity: severity,
            failure: failure,
            persistenceComponent: component,
            persistenceOperation: operation,
            persistencePhase: phase,
            persistenceResolution: resolution
        )
    }

    public static func persistedSyncFailureLoaded(
        failure: DiagnosticFailure,
        operationID: DiagnosticOperationID? = nil,
        incidentID: DiagnosticIncidentID? = nil
    ) -> Self {
        Self(
            code: .persistedSyncFailureLoaded,
            category: .sync,
            severity: .error,
            operationID: operationID,
            incidentID: incidentID,
            failure: failure
        )
    }

    static func recordsDropped(count: Int) -> Self {
        Self(
            code: .recordsDropped,
            category: .diagnostics,
            severity: .error,
            progress: DiagnosticProgress(recordCount: count)
        )
    }

    static func corruptRecordExcluded(count: Int) -> Self {
        Self(
            code: .corruptRecordExcluded,
            category: .diagnostics,
            severity: .error,
            progress: DiagnosticProgress(recordCount: count)
        )
    }

    static func oversizedEventDropped(byteCount: Int64) -> Self {
        Self(
            code: .oversizedEventDropped,
            category: .diagnostics,
            severity: .error,
            progress: DiagnosticProgress(byteCount: byteCount)
        )
    }

    static func oversizedMetricPayloadDropped(byteCount: Int64) -> Self {
        Self(
            code: .oversizedMetricPayloadDropped,
            category: .diagnostics,
            severity: .error,
            progress: DiagnosticProgress(byteCount: byteCount)
        )
    }
}

public struct RecordedEvidence: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let sequence: UInt64
    public let eventID: UUID
    public let timestamp: Date
    public let sessionID: DiagnosticSessionID
    public let event: EvidenceEvent

    public init(
        schemaVersion: Int = currentSchemaVersion,
        sequence: UInt64,
        eventID: UUID = UUID(),
        timestamp: Date,
        sessionID: DiagnosticSessionID,
        event: EvidenceEvent
    ) {
        self.schemaVersion = schemaVersion
        self.sequence = sequence
        self.eventID = eventID
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.event = event
    }
}

extension DiagnosticOperationKind {
    var category: DiagnosticCategory {
        switch self {
        case .appSession:
            .lifecycle
        case .localFirstSync:
            .sync
        case .taskMutation:
            .mutation
        case .persistence:
            .persistence
        case .diagnosticExport, .metricCollection:
            .diagnostics
        }
    }
}
