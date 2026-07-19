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
        let pending = try syncRepository.pendingDownloads()
        let terminalRejections = try syncRepository.terminalRejectionEvidence()
        let fetchedRecords = try await transport.fetchAll()
        let records = combinedRecords(
            pending: pending.map(\.record),
            fetched: fetchedRecords
        )
        guard records.isEmpty == false else {
            try syncRepository.saveMetadata(
                try downloadMetadata(fetchedCount: 0, detectedAt: detectedAt)
            )
            return SQLiteSyncDownloadResult(
                fetchedCount: 0,
                appliedCount: 0,
                waitingCount: 0,
                conflictCount: 0
            )
        }

        let observedEngine = try engineRepository.loadObservedSnapshot()
        let currentSnapshot = try ValidatedSyncSnapshot(
            observedEngine.snapshot
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
        let durableWaitingCount = try syncRepository.commitDownloadedMerge(
            SQLiteSyncDownloadCommit(
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
                attemptedAt: detectedAt
            )
        )

        return SQLiteSyncDownloadResult(
            fetchedCount: fetchedRecords.count,
            appliedCount: mergeResult.appliedRecordIDs.count,
            waitingCount: durableWaitingCount,
            conflictCount: mergeResult.conflicts.count
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
        if existing == incoming { return }
        if existing.canonicalEvidenceID == sourceID {
            index[sourceID] = incoming
            return
        }
        if incoming.canonicalEvidenceID == sourceID { return }
        throw SQLiteRepositoryError.invalidStoredValue(
            "sync evidence source has contradictory canonical provenance"
        )
    }
}
