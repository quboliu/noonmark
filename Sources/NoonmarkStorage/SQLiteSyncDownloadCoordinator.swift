import Foundation
import NoonmarkCore
import NoonmarkSync

public struct SQLiteSyncDownloadResult: Codable, Equatable, Sendable {
    public var fetchedCount: Int
    public var appliedCount: Int
    public var waitingCount: Int
    public var conflictCount: Int

    public init(
        fetchedCount: Int,
        appliedCount: Int,
        waitingCount: Int,
        conflictCount: Int
    ) {
        self.fetchedCount = fetchedCount
        self.appliedCount = appliedCount
        self.waitingCount = waitingCount
        self.conflictCount = conflictCount
    }
}

struct SQLiteSyncDownloadObservation {
    var result: SQLiteSyncDownloadResult
    var fetchedRecords: [SyncRecord]
    var hasMoreRemoteChanges: Bool
}

struct SQLiteReplicationForkApplyResult {
    let result: SQLiteSyncDownloadResult
    let closed: Bool
    let conflicts: [SyncConflict]
}

private struct SQLiteSyncDownloadDisposition {
    let result: SQLiteSyncDownloadResult
    let committed: Bool
    let conflicts: [SyncConflict]
}

public final class SQLiteSyncDownloadCoordinator {
    private let engineRepository: SQLiteEngineRepository
    private let syncRepository: SQLiteSyncRepository
    private let transport: SyncRecordTransport
    private let merger: SyncRecordMerger
    private let auditEntryIDGenerator: () -> UUID

    public convenience init(
        databaseURL: URL,
        transport: SyncRecordTransport,
        merger: SyncRecordMerger = SyncRecordMerger()
    ) {
        self.init(
            databaseURL: databaseURL,
            transport: transport,
            merger: merger,
            auditEntryIDGenerator: UUID.init
        )
    }

    init(
        databaseURL: URL,
        transport: SyncRecordTransport,
        merger: SyncRecordMerger = SyncRecordMerger(),
        auditEntryIDGenerator: @escaping () -> UUID
    ) {
        self.engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        self.syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        self.transport = transport
        self.merger = merger
        self.auditEntryIDGenerator = auditEntryIDGenerator
    }

    public func downloadAndMerge(detectedAt: Date = Date()) async throws -> SQLiteSyncDownloadResult {
        try await downloadAndMergeObservingRecords(
            detectedAt: detectedAt
        ).result
    }

    func downloadAndMergeObservingRecords(
        detectedAt: Date,
        limit: Int = 100
    ) async throws -> SQLiteSyncDownloadObservation {
        try Task.checkCancellation()
        let frontier = try loadFrontier()
        let page = try await transport.pull(
            after: frontier,
            limit: max(limit, 1)
        )
        try Task.checkCancellation()
        let observation = try downloadAndMergeObservingPage(
            page,
            detectedAt: detectedAt
        )
        try Task.checkCancellation()
        try await transport.acknowledge(page.frontier)
        return observation
    }

    func downloadAndMergeObservingPage(
        _ page: SyncTransportChangePage,
        detectedAt: Date
    ) throws -> SQLiteSyncDownloadObservation {
        let pending = try syncRepository.pendingDownloads()
        let terminalRejections = try syncRepository
            .terminalRejectionEvidence()
        return try downloadAndMergeObservation(
            pending: pending,
            terminalRejections: terminalRejections,
            fetchedRecords: page.records,
            detectedAt: detectedAt,
            frontierMetadata: try frontierMetadata(
                page.frontier,
                updatedAt: detectedAt
            ),
            hasMoreRemoteChanges: page.hasMore
        )
    }

    func downloadAndMergeObservingRecords(
        fetchedRecords: [SyncRecord],
        detectedAt: Date
    ) throws -> SQLiteSyncDownloadObservation {
        let pending = try syncRepository.pendingDownloads()
        let terminalRejections = try syncRepository
            .terminalRejectionEvidence()
        return try downloadAndMergeObservation(
            pending: pending,
            terminalRejections: terminalRejections,
            fetchedRecords: fetchedRecords,
            detectedAt: detectedAt,
            frontierMetadata: nil,
            hasMoreRemoteChanges: false
        )
    }

    func downloadAndMergeReplicationRecords(
        _ fetchedRecords: [SyncRecord],
        detectedAt: Date,
        cursorMetadata: SyncMetadataEntry,
        expectedReplicationControl: LocalFirstReplicationControl? = nil
    ) throws -> SQLiteSyncDownloadResult {
        let pending = try syncRepository.pendingDownloads()
        let terminalRejections = try syncRepository
            .terminalRejectionEvidence()
        return try downloadAndMergeObservation(
            pending: pending,
            terminalRejections: terminalRejections,
            fetchedRecords: fetchedRecords,
            detectedAt: detectedAt,
            frontierMetadata: cursorMetadata,
            hasMoreRemoteChanges: false,
            expectedReplicationControl: expectedReplicationControl
        ).result
    }

    func downloadAndMergeReplicationFork(
        _ evidence: ReplicationForkEvidence,
        detectedAt: Date,
        cursorMetadata: SyncMetadataEntry,
        expectedReplicationControl: LocalFirstReplicationControl? = nil
    ) throws -> SQLiteReplicationForkApplyResult {
        let pending = try syncRepository.pendingDownloads()
        let terminalRejections = try syncRepository
            .terminalRejectionEvidence()
        let disposition = try downloadAndMerge(
            pending: pending,
            terminalRejections: terminalRejections,
            fetchedRecords: evidence.branches.flatMap(\.records),
            detectedAt: detectedAt,
            frontierMetadata: cursorMetadata,
            closingForkResolutionID: evidence.resolutionID,
            forkConflictDecisionCommit: nil,
            expectedReplicationControl: expectedReplicationControl
        )
        return SQLiteReplicationForkApplyResult(
            result: disposition.result,
            closed: disposition.committed,
            conflicts: disposition.conflicts
        )
    }

    func resolveReplicationForkConflicts(
        _ evidence: ReplicationForkEvidence,
        decisions: [ReplicationForkConflictDecisionSelection],
        decidedAt: Date,
        cursorMetadata: SyncMetadataEntry,
        repairBaselineRecords: [SyncRecord] = [],
        expectedManifest: ReplicationForkResolutionManifest? = nil,
        expectedReplicationControl: LocalFirstReplicationControl? = nil
    ) throws -> SQLiteReplicationForkApplyResult {
        guard decidedAt.timeIntervalSinceReferenceDate.isFinite,
              decisions.isEmpty == false,
              Set(decisions.map(\.conflictID)).count == decisions.count,
              repairBaselineRecords.isEmpty == (expectedManifest == nil),
              expectedManifest?.resolutionID == evidence.resolutionID
                  || expectedManifest == nil,
              expectedManifest?.decidedAt?
                  .timeIntervalSinceReferenceDate.bitPattern
                  == decidedAt.timeIntervalSinceReferenceDate.bitPattern
                  || expectedManifest == nil,
              let conflictSet = try syncRepository
                  .replicationForkConflictSet(
                      resolutionID: evidence.resolutionID
                  )
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication fork conflict decision input is invalid"
            )
        }
        let expectedConflictIDs = conflictSet.conflicts.map(\.conflict.id)
        guard conflictSet.conflicts.allSatisfy({
            $0.decision == nil && $0.decidedAt == nil
        }), Set(decisions.map(\.conflictID)) == Set(expectedConflictIDs),
            decisions.count == expectedConflictIDs.count
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication fork conflict decisions do not cover the exact set"
            )
        }
        let branchRecords = evidence.branches.flatMap(\.records)
        let branchEvidence = Set(branchRecords.map(SyncRecordEvidenceID.init))
        let observedEngine = try engineRepository.loadObservedSnapshot()
        guard observedEngine.generation
            == conflictSet.observedEngineGeneration
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "engine snapshot changed before fork conflict decision"
            )
        }
        let decisionResolution = try ReplicationForkDecisionResolver()
            .resolve(
                snapshot: observedEngine.snapshot,
                conflictSet: conflictSet,
                evidence: evidence,
                decisions: decisions,
                decidedAt: decidedAt
            )
        if let expectedManifest {
            let actualOutcomes = decisionResolution.outcomes.map { outcome in
                ReplicationForkResolutionOutcome(
                    conflictID: outcome.selection.conflictID,
                    decision: protocolDecision(
                        from: outcome.selection.decision
                    ),
                    resultReference: outcome.resultReference.map {
                        ReplicationForkResolutionResultReference(
                            entityType: $0.entityType,
                            entityID: $0.entityID
                        )
                    }
                )
            }.sorted {
                $0.conflictID.uuidString < $1.conflictID.uuidString
            }
            guard actualOutcomes == expectedManifest.outcomes else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "replication fork manifest does not match deterministic replay"
                )
            }
        }
        guard decisionResolution.rejectedEvidence.isSubset(of: branchEvidence)
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication fork conflict is not bound to branch evidence"
            )
        }
        let acceptedRecords = branchRecords.filter {
            decisionResolution.rejectedEvidence.contains(
                SyncRecordEvidenceID(record: $0)
            )
                == false
        } + repairBaselineRecords
        let pending = try syncRepository.pendingDownloads()
        let terminalRejections = try syncRepository
            .terminalRejectionEvidence()
        let disposition = try downloadAndMerge(
            pending: pending,
            terminalRejections: terminalRejections,
            fetchedRecords: acceptedRecords,
            detectedAt: decidedAt,
            frontierMetadata: cursorMetadata,
            closingForkResolutionID: evidence.resolutionID,
            forkConflictDecisionCommit: SQLiteReplicationForkDecisionCommit(
                resolutionID: evidence.resolutionID,
                observedEngineGeneration: conflictSet
                    .observedEngineGeneration,
                outcomes: decisionResolution.outcomes
            ),
            decisionBaseSnapshot: decisionResolution.baseSnapshot,
            decisionObservedEngine: observedEngine,
            expectedReplicationControl: expectedReplicationControl
        )
        return SQLiteReplicationForkApplyResult(
            result: disposition.result,
            closed: disposition.committed,
            conflicts: disposition.conflicts
        )
    }

    private func protocolDecision(
        from decision: ReplicationForkConflictDecision
    ) -> ReplicationForkResolutionDecision {
        switch decision {
        case .keepCurrent: .keepCurrent
        case .acceptRemote: .acceptRemote
        case .copyAsNew: .copyAsNew
        }
    }

    private func downloadAndMergeObservation(
        pending: [SyncPendingDownloadRecord],
        terminalRejections: [SyncTerminalRejection],
        fetchedRecords: [SyncRecord],
        detectedAt: Date,
        frontierMetadata: SyncMetadataEntry?,
        hasMoreRemoteChanges: Bool,
        expectedReplicationControl: LocalFirstReplicationControl? = nil
    ) throws -> SQLiteSyncDownloadObservation {
        let disposition = try downloadAndMerge(
            pending: pending,
            terminalRejections: terminalRejections,
            fetchedRecords: fetchedRecords,
            detectedAt: detectedAt,
            frontierMetadata: frontierMetadata,
            closingForkResolutionID: nil,
            forkConflictDecisionCommit: nil,
            expectedReplicationControl: expectedReplicationControl
        )
        return SQLiteSyncDownloadObservation(
            result: disposition.result,
            fetchedRecords: fetchedRecords,
            hasMoreRemoteChanges: hasMoreRemoteChanges
        )
    }

    private func downloadAndMerge(
        pending: [SyncPendingDownloadRecord],
        terminalRejections: [SyncTerminalRejection],
        fetchedRecords: [SyncRecord],
        detectedAt: Date,
        frontierMetadata: SyncMetadataEntry?,
        closingForkResolutionID: ReplicationDigest?,
        forkConflictDecisionCommit: SQLiteReplicationForkDecisionCommit?,
        decisionBaseSnapshot: NoonmarkSnapshot? = nil,
        decisionObservedEngine: SQLiteObservedEngineSnapshot? = nil,
        expectedReplicationControl: LocalFirstReplicationControl? = nil
    ) throws -> SQLiteSyncDownloadDisposition {
        let records = combinedRecords(
            pending: pending.map(\.record),
            fetched: fetchedRecords
        )
        if closingForkResolutionID != nil,
           records.isEmpty,
           forkConflictDecisionCommit == nil
        {
            throw SQLiteRepositoryError.invalidStoredValue(
                "fork branch graph contains no mergeable records"
            )
        }
        if records.isEmpty, let forkConflictDecisionCommit {
            guard closingForkResolutionID
                == forkConflictDecisionCommit.resolutionID,
                let frontierMetadata
            else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "empty fork decision lacks exact resolution metadata"
                )
            }
            let observedEngine = try decisionObservedEngine
                ?? engineRepository.loadObservedSnapshot()
            guard observedEngine.generation
                == forkConflictDecisionCommit.observedEngineGeneration
            else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "engine snapshot changed before fork conflict decision"
                )
            }
            _ = try syncRepository.commitDownloadedMerge(
                SQLiteSyncDownloadCommit(
                    sourceSnapshot: observedEngine.snapshot,
                    snapshot: decisionBaseSnapshot
                        ?? observedEngine.snapshot,
                    observedEngineGeneration: observedEngine.generation,
                    conflicts: [],
                    waiting: [],
                    terminal: [],
                    observedPending: pending,
                    auditEntries: [],
                    metadata: try downloadMetadata(
                        fetchedCount: 0,
                        detectedAt: detectedAt
                    ),
                    frontierMetadata: frontierMetadata,
                    forkResolutionTransition: SQLiteReplicationForkTransition(
                        resolutionID: forkConflictDecisionCommit.resolutionID,
                        expectedState: .branchesValidated,
                        newState: .closed
                    ),
                    forkConflictDecisionCommit: forkConflictDecisionCommit,
                    expectedReplicationControl: expectedReplicationControl,
                    attemptedAt: detectedAt
                )
            )
            return SQLiteSyncDownloadDisposition(
                result: SQLiteSyncDownloadResult(
                    fetchedCount: 0,
                    appliedCount: forkConflictDecisionCommit.outcomes.filter {
                        $0.selection.decision != .keepCurrent
                    }.count,
                    waitingCount: 0,
                    conflictCount: 0
                ),
                committed: true,
                conflicts: []
            )
        }
        guard records.isEmpty == false else {
            var metadata = [
                try downloadMetadata(
                    fetchedCount: 0,
                    detectedAt: detectedAt
                )
            ]
            if let frontierMetadata {
                metadata.append(frontierMetadata)
            }
            if let expectedReplicationControl {
                try syncRepository.saveMetadata(
                    metadata,
                    expectedReplicationControl: expectedReplicationControl
                )
            } else {
                try syncRepository.saveMetadata(metadata)
            }
            return SQLiteSyncDownloadDisposition(
                result: SQLiteSyncDownloadResult(
                    fetchedCount: 0,
                    appliedCount: 0,
                    waitingCount: 0,
                    conflictCount: 0
                ),
                committed: true,
                conflicts: []
            )
        }

        let observedEngine = try decisionObservedEngine
            ?? engineRepository.loadObservedSnapshot()
        if let forkConflictDecisionCommit,
           observedEngine.generation
           != forkConflictDecisionCommit.observedEngineGeneration
        {
            throw SQLiteRepositoryError.invalidStoredValue(
                "engine snapshot changed before fork conflict decision"
            )
        }
        let currentSnapshot = try ValidatedSyncSnapshot(
            decisionBaseSnapshot ?? observedEngine.snapshot
        )
        let mergeResult = try mergeToFixedPoint(
            records: records,
            into: currentSnapshot,
            knownTerminalRejections: terminalRejections,
            detectedAt: detectedAt
        )

        var outcomesByEvidence: [
            SyncRecordEvidenceID: SyncRecordMergeOutcome
        ] = [:]
        for outcome in mergeResult.outcomes {
            guard outcomesByEvidence.updateValue(
                outcome,
                forKey: outcome.evidence.id
            ) == nil else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "merge returned duplicate exact evidence outcomes"
                )
            }
        }
        let waitingRecordIDs = Set(
            mergeResult.waitingRecords.map(\.remoteRecordID)
        )
        let terminalPending = try pending.filter { observed in
            let evidenceID = SyncRecordEvidenceID(record: observed.record)
            guard let outcome = outcomesByEvidence[evidenceID] else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "merge omitted an observed pending evidence outcome"
                )
            }
            // A newer exact variant may replace this observed pending fact while
            // retaining the same logical record ID. In that case the old exact
            // outcome is terminal, but the durable row is an atomic replacement,
            // not a delete followed by an unrelated insert.
            return outcome.disposition != .waiting
                && waitingRecordIDs.contains(observed.record.id) == false
        }
        let projectedResult = SQLiteSyncDownloadResult(
            fetchedCount: fetchedRecords.count,
            appliedCount: mergeResult.appliedRecordIDs.count
                + (forkConflictDecisionCommit?.outcomes.filter {
                    $0.selection.decision != .keepCurrent
                }.count ?? 0),
            waitingCount: mergeResult.waitingRecords.count,
            conflictCount: mergeResult.conflicts.count
        )
        if closingForkResolutionID != nil,
           mergeResult.waitingRecords.isEmpty == false
            || mergeResult.conflicts.isEmpty == false
        {
            if let closingForkResolutionID,
               mergeResult.conflicts.isEmpty == false
            {
                _ = try syncRepository.recordReplicationForkConflictSet(
                    resolutionID: closingForkResolutionID,
                    conflicts: mergeResult.conflicts,
                    observedEngineGeneration: observedEngine.generation,
                    recordedAt: detectedAt,
                    expectedReplicationControl: expectedReplicationControl
                )
            }
            return SQLiteSyncDownloadDisposition(
                result: projectedResult,
                committed: false,
                conflicts: mergeResult.conflicts
            )
        }
        let durableWaitingCount = try syncRepository.commitDownloadedMerge(
            SQLiteSyncDownloadCommit(
                sourceSnapshot: observedEngine.snapshot,
                snapshot: mergeResult.snapshot,
                observedEngineGeneration: observedEngine.generation,
                conflicts: mergeResult.conflicts,
                waiting: mergeResult.waitingRecords,
                terminal: terminalPending,
                observedPending: pending,
                auditEntries: auditLogs(
                    outcomes: mergeResult.outcomes,
                    detectedAt: detectedAt
                ),
                metadata: try downloadMetadata(
                    fetchedCount: fetchedRecords.count,
                    detectedAt: detectedAt
                ),
                frontierMetadata: frontierMetadata,
                forkResolutionTransition: closingForkResolutionID.map {
                    SQLiteReplicationForkTransition(
                        resolutionID: $0,
                        expectedState: .branchesValidated,
                        newState: .closed
                    )
                },
                forkConflictDecisionCommit: forkConflictDecisionCommit,
                expectedReplicationControl: expectedReplicationControl,
                attemptedAt: detectedAt
            )
        )

        return SQLiteSyncDownloadDisposition(
            result: SQLiteSyncDownloadResult(
                fetchedCount: fetchedRecords.count,
                appliedCount: mergeResult.appliedRecordIDs.count
                    + (forkConflictDecisionCommit?.outcomes.filter {
                        $0.selection.decision != .keepCurrent
                    }.count ?? 0),
                waitingCount: durableWaitingCount,
                conflictCount: mergeResult.conflicts.count
            ),
            committed: true,
            conflicts: mergeResult.conflicts
        )
    }

    private var frontierMetadataKey: String {
        SQLiteSyncRepository.frontierMetadataKey(
            namespace: transport.frontierNamespace
        )
    }

    private func loadFrontier() throws -> SyncTransportFrontier {
        guard let metadata = try syncRepository.metadata(
            for: frontierMetadataKey
        ) else { return .origin }
        do {
            return try JSONDecoder().decode(
                SyncTransportFrontier.self,
                from: metadata.value
            )
        } catch {
            throw SQLiteRepositoryError.invalidStoredValue(
                "sync transport frontier is invalid"
            )
        }
    }

    private func frontierMetadata(
        _ frontier: SyncTransportFrontier,
        updatedAt: Date
    ) throws -> SyncMetadataEntry {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SyncMetadataEntry(
            key: frontierMetadataKey,
            value: try encoder.encode(frontier),
            updatedAt: updatedAt
        )
    }

    private func combinedRecords(
        pending: [SyncRecord],
        fetched: [SyncRecord]
    ) -> [SyncRecord] {
        // Snapshot-aware same-ID semantics belong to SyncRecordMerger. Storage
        // deliberately preserves every fetched and durable-pending candidate
        // until that deep merge seam has the current snapshot context.
        pending + fetched
    }

    private func mergeToFixedPoint(
        records: [SyncRecord],
        into snapshot: ValidatedSyncSnapshot,
        knownTerminalRejections: [SyncTerminalRejection],
        detectedAt: Date
    ) throws -> SyncMergeResult {
        var terminalRejections = knownTerminalRejections
        var result = merger.merge(
            records: records,
            into: snapshot,
            knownTerminalRejections: terminalRejections,
            detectedAt: detectedAt
        )
        let initialOutcomes = result.outcomes
        var appliedRecordIDs = result.appliedRecordIDs
        var appliedEvidenceIDs = Set(result.appliedEvidenceIDs)
        var conflicts = result.conflicts
        var outcomesByEvidence: [SyncRecordEvidenceID: SyncRecordMergeOutcome] = [:]
        for outcome in result.outcomes {
            outcomesByEvidence[outcome.evidence.id] = outcome
        }
        var provenanceByCanonical: [
            SyncRecordEvidenceID: SyncRecordProvenanceGroup
        ] = [:]
        for provenance in result.provenanceGroups {
            try mergeProvenance(provenance, into: &provenanceByCanonical)
        }

        while result.waitingRecords.isEmpty == false && result.appliedRecordIDs.isEmpty == false {
            terminalRejections.append(contentsOf: result.conflicts.compactMap {
                SyncTerminalRejection(conflict: $0)
            })
            let nextSnapshot = try ValidatedSyncSnapshot(result.snapshot)
            result = merger.merge(
                records: result.waitingRecords.map(\.record),
                into: nextSnapshot,
                knownTerminalRejections: terminalRejections,
                detectedAt: detectedAt
            )
            appliedRecordIDs.append(contentsOf: result.appliedRecordIDs)
            appliedEvidenceIDs.formUnion(result.appliedEvidenceIDs)
            conflicts.append(contentsOf: result.conflicts)
            for outcome in result.outcomes {
                outcomesByEvidence[outcome.evidence.id] = outcome
            }
            for provenance in result.provenanceGroups {
                try mergeProvenance(provenance, into: &provenanceByCanonical)
            }
        }

        let projectedOutcomes = try SQLiteSyncOutcomeProjector.project(
            initialOutcomes: initialOutcomes,
            latestOutcomesByEvidence: outcomesByEvidence,
            provenanceGroups: Array(provenanceByCanonical.values)
        )
        return SyncMergeResult(
            snapshot: result.snapshot,
            appliedRecordIDs: appliedRecordIDs,
            appliedEvidenceIDs: appliedEvidenceIDs.sorted {
                $0.rawValue < $1.rawValue
            },
            waitingRecords: result.waitingRecords,
            conflicts: conflicts,
            outcomes: projectedOutcomes,
            provenanceGroups: provenanceByCanonical.values.sorted {
                $0.canonicalEvidenceID.rawValue
                    < $1.canonicalEvidenceID.rawValue
            }
        )
    }

    private func mergeProvenance(
        _ incoming: SyncRecordProvenanceGroup,
        into index: inout [
            SyncRecordEvidenceID: SyncRecordProvenanceGroup
        ]
    ) throws {
        guard let existing = index[incoming.canonicalEvidenceID] else {
            index[incoming.canonicalEvidenceID] = incoming
            return
        }
        guard existing.canonicalRecord.exactlyMatches(incoming.canonicalRecord)
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "one canonical evidence digest names different records"
            )
        }
        index[incoming.canonicalEvidenceID] = SyncRecordProvenanceGroup(
            canonicalRecord: existing.canonicalRecord,
            contributingEvidenceIDs: existing.contributingEvidenceIDs
                + incoming.contributingEvidenceIDs,
            supersededEvidenceIDs: existing.supersededEvidenceIDs
                + incoming.supersededEvidenceIDs
        )
    }

    private func auditLogs(
        outcomes: [SyncRecordMergeOutcome],
        detectedAt: Date
    ) -> [SyncAuditLogEntry] {
        outcomes.sorted {
            $0.evidence.id.rawValue < $1.evidence.id.rawValue
        }.map { outcome in
            let message: String? = switch outcome.disposition {
            case .merged:
                nil
            case .ignored:
                "remote exact evidence did not change the local snapshot"
            case .waiting:
                outcome.dependencies.map(dependencyDescription)
                    .joined(separator: ", ")
            case .conflict:
                outcome.conflictID.map {
                    "remote exact evidence conflicted (\($0.uuidString))"
                } ?? "remote exact evidence conflicted"
            }
            return auditLog(
                outcome: outcome,
                detectedAt: detectedAt,
                message: message
            )
        }
    }

    private func dependencyDescription(
        _ dependency: SyncRecordDependency
    ) -> String {
        dependency.sqliteFact.auditDescription
    }

    private func auditLog(
        outcome: SyncRecordMergeOutcome,
        detectedAt: Date,
        message: String?
    ) -> SyncAuditLogEntry {
        let record = outcome.evidence.record
        return SyncAuditLogEntry(
            id: auditEntryIDGenerator(),
            direction: .download,
            entityType: record.entityType,
            entityID: record.entityID,
            sourceEvidenceID: outcome.evidence.id,
            canonicalEvidenceID: outcome.canonicalEvidenceID,
            action: outcome.disposition.rawValue,
            createdAt: detectedAt,
            message: message
        )
    }

    private func downloadMetadata(
        fetchedCount: Int,
        detectedAt: Date
    ) throws -> SyncMetadataEntry {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let metadata = SyncDownloadMetadata(lastFetchedAt: detectedAt, fetchedCount: fetchedCount)
        return SyncMetadataEntry(
            key: "generic.download.lastFetch",
            value: try encoder.encode(metadata),
            updatedAt: detectedAt
        )
    }
}

private struct SyncDownloadMetadata: Codable {
    var lastFetchedAt: Date
    var fetchedCount: Int
}

enum SQLiteSyncOutcomeProjector {
    private struct Edge: Equatable {
        let canonicalEvidenceID: SyncRecordEvidenceID
        let contributes: Bool
    }

    static func project(
        initialOutcomes: [SyncRecordMergeOutcome],
        latestOutcomesByEvidence: [
            SyncRecordEvidenceID: SyncRecordMergeOutcome
        ],
        provenanceGroups: [SyncRecordProvenanceGroup]
    ) throws -> [SyncRecordMergeOutcome] {
        let lineage = try lineageIndex(provenanceGroups)
        return try initialOutcomes.map { initial in
            var currentID = initial.evidence.id
            var latest = latestOutcomesByEvidence[currentID] ?? initial
            var contributes = true
            var visited: Set<SyncRecordEvidenceID> = []

            while let edge = lineage[currentID] {
                guard visited.insert(currentID).inserted else {
                    throw SQLiteRepositoryError.invalidStoredValue(
                        "sync evidence provenance contains a cycle"
                    )
                }
                contributes = contributes && edge.contributes
                guard edge.canonicalEvidenceID != currentID else { break }
                currentID = edge.canonicalEvidenceID
                if let next = latestOutcomesByEvidence[currentID] {
                    latest = next
                }
            }

            return SyncRecordMergeOutcome(
                evidence: initial.evidence,
                canonicalEvidenceID: currentID,
                disposition: contributes ? latest.disposition : .ignored,
                dependencies: contributes ? latest.dependencies : [],
                conflictID: contributes ? latest.conflictID : nil
            )
        }.sorted {
            $0.evidence.id.rawValue < $1.evidence.id.rawValue
        }
    }

    private static func lineageIndex(
        _ groups: [SyncRecordProvenanceGroup]
    ) throws -> [SyncRecordEvidenceID: Edge] {
        var result: [SyncRecordEvidenceID: Edge] = [:]
        for group in groups {
            for sourceID in group.contributingEvidenceIDs {
                try insert(
                    Edge(
                        canonicalEvidenceID: group.canonicalEvidenceID,
                        contributes: true
                    ),
                    for: sourceID,
                    into: &result
                )
            }
            for sourceID in group.supersededEvidenceIDs {
                try insert(
                    Edge(
                        canonicalEvidenceID: group.canonicalEvidenceID,
                        contributes: false
                    ),
                    for: sourceID,
                    into: &result
                )
            }
        }
        return result
    }

    private static func insert(
        _ incoming: Edge,
        for sourceID: SyncRecordEvidenceID,
        into index: inout [SyncRecordEvidenceID: Edge]
    ) throws {
        guard let existing = index[sourceID] else {
            index[sourceID] = incoming
            return
        }
        if existing == incoming {
            return
        }
        if existing.canonicalEvidenceID == sourceID {
            index[sourceID] = incoming
            return
        }
        if incoming.canonicalEvidenceID == sourceID {
            return
        }
        throw SQLiteRepositoryError.invalidStoredValue(
            "sync evidence source has contradictory canonical provenance"
        )
    }
}
