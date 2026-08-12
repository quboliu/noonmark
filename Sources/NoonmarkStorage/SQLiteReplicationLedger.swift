import Foundation
import NoonmarkSync
import SQLite3

public struct SQLiteSealedLocalPublication: Equatable, Sendable {
    public let publication: SealedReplicationPublication
    public let journalEntryIDs: [UUID]

    public var reference: ReplicationPublicationReference {
        publication.reference
    }

    public init(
        publication: SealedReplicationPublication,
        journalEntryIDs: [UUID]
    ) {
        self.publication = publication
        self.journalEntryIDs = journalEntryIDs
    }
}

public struct SQLiteReplicationLedgerSnapshot: Equatable, Sendable {
    public let confirmedSequences: [UInt64]
    public let selfWatermark: ReplicationSelfWatermark?

    public init(
        confirmedSequences: [UInt64],
        selfWatermark: ReplicationSelfWatermark?
    ) {
        self.confirmedSequences = confirmedSequences
        self.selfWatermark = selfWatermark
    }
}

public struct SQLiteReplicationCleanCutAuthority: Equatable, Sendable {
    public let generationID: UUID
    public let producerID: UUID
    public let baselineSequence: UInt64

    public init(
        generationID: UUID,
        producerID: UUID,
        baselineSequence: UInt64
    ) {
        self.generationID = generationID
        self.producerID = producerID
        self.baselineSequence = baselineSequence
    }
}

public struct SQLiteReplicationOutboxSnapshot: Equatable, Sendable {
    public let pendingCount: Int
    public let confirmedCount: Int

    public init(pendingCount: Int, confirmedCount: Int) {
        self.pendingCount = pendingCount
        self.confirmedCount = confirmedCount
    }
}

public enum ReplicationForkResolutionState:
    String,
    Codable,
    Equatable,
    Sendable
{
    case detected
    case branchesValidated
    case branchesApplied
    case domainConflictsResolved
    case closed
}

public struct SQLiteReplicationForkResolution: Equatable, Sendable {
    public let resolutionID: ReplicationDigest
    public let state: ReplicationForkResolutionState
    public let evidence: ReplicationForkEvidence

    public init(
        resolutionID: ReplicationDigest,
        state: ReplicationForkResolutionState,
        evidence: ReplicationForkEvidence
    ) {
        self.resolutionID = resolutionID
        self.state = state
        self.evidence = evidence
    }
}

public final class SQLiteReplicationLedger {
    typealias Database = OpaquePointer
    typealias Statement = OpaquePointer

    private static let activeProducerEpochMetadataKey =
        "localFirst.replication.v2.activeProducerEpoch"

    private let databaseURL: URL
    private let storeRuntime: SQLiteStoreRuntime
    private let syncRepository: SQLiteSyncRepository

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
        storeRuntime = SQLiteStoreRuntime.shared(for: databaseURL)
        syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
    }

    public func cleanCutAuthority()
        throws -> SQLiteReplicationCleanCutAuthority?
    {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try storeRuntime.prepare(database)
        return try cleanCutAuthority(from: database)
    }

    public func outboxSnapshot(
        generationID: UUID
    ) throws -> SQLiteReplicationOutboxSnapshot {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try storeRuntime.prepare(database)
        let counts = try query(
            """
            SELECT
                SUM(CASE WHEN confirmed_at_bits IS NULL THEN 1 ELSE 0 END),
                SUM(CASE WHEN confirmed_at_bits IS NOT NULL THEN 1 ELSE 0 END)
            FROM sync_replication_outbox
            WHERE generation_id = ?
            """,
            on: database
        ) { statement in
            bind(generationID, to: 1, in: statement)
        } row: { statement in
            (
                Int(sqlite3_column_int64(statement, 0)),
                Int(sqlite3_column_int64(statement, 1))
            )
        }
        guard counts.count == 1, let count = counts.first else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication outbox count is missing or duplicated"
            )
        }
        return SQLiteReplicationOutboxSnapshot(
            pendingCount: count.0,
            confirmedCount: count.1
        )
    }

    func cleanCutBaselineIsConfirmed() throws -> Bool {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try storeRuntime.prepare(database)
        return try cleanCutBaselineIsConfirmed(from: database)
    }

    func producerBaselineIsConfirmed(
        generationID: UUID,
        producerID: UUID
    ) throws -> Bool {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try storeRuntime.prepare(database)
        let values = try query(
            """
            SELECT 1
            FROM sync_replication_publications p
            JOIN sync_replication_confirmations c
              ON c.generation_id = p.generation_id
             AND c.producer_id = p.producer_id
             AND c.sequence = p.sequence
             AND c.seal_digest = p.seal_digest
            WHERE p.generation_id = ? AND p.producer_id = ?
              AND p.sequence = 1
            """,
            on: database
        ) { statement in
            bind(generationID, to: 1, in: statement)
            bind(producerID, to: 2, in: statement)
        } row: { _ in true }
        guard values.count <= 1 else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication producer baseline confirmation is duplicated"
            )
        }
        return values == [true]
    }

    func installCleanCutAuthorityAndBaseline(
        _ publication: SealedReplicationPublication,
        observedEngineGeneration: SQLiteEngineSnapshotGeneration,
        installedAt: Date
    ) throws {
        let reference = publication.reference
        guard reference.sequence == 1,
              reference.previousSealDigest == nil,
              reference.basedOnResolutionID == nil,
              publication.resolutionManifest == nil,
              publication.records.isEmpty == false,
              installedAt.timeIntervalSinceReferenceDate.isFinite
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "clean-cut replication baseline is invalid"
            )
        }
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try storeRuntime.prepare(database)
        let writeLease = storeRuntime.acquireWriteLease()
        defer { writeLease.release() }
        try execute("BEGIN IMMEDIATE TRANSACTION", on: database)
        do {
            if let existing = try cleanCutAuthority(from: database) {
                guard existing.generationID == reference.generationID,
                      existing.producerID == reference.producerID,
                      existing.baselineSequence == 1,
                      try storedPublication(
                          generationID: reference.generationID,
                          producerID: reference.producerID,
                          sequence: 1,
                          sealDigest: reference.sealDigest,
                          from: database
                      ) == reference
                else {
                    throw SQLiteRepositoryError.invalidStoredValue(
                        "clean-cut replication authority already differs"
                    )
                }
                try execute("COMMIT", on: database)
                return
            }
            let generationMatches = try query(
                """
                SELECT 1
                FROM engine_snapshot_generation
                WHERE id = 1 AND epoch = ? AND revision = ?
                """,
                on: database
            ) { statement in
                bind(
                    observedEngineGeneration.epoch.uuidString.lowercased(),
                    to: 1,
                    in: statement
                )
                try bind(observedEngineGeneration.revision, to: 2, in: statement)
            } row: { _ in 1 }
            guard generationMatches == [1],
                  try replicationPublicationCount(from: database) == 0,
                  try activeProducerID(from: database) == nil
            else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "clean-cut replication baseline lost its empty authority fence"
                )
            }
            try discardLegacySyncRuntimeEvidence(from: database)
            try insertOrValidate(
                SQLiteSealedLocalPublication(
                    publication: publication,
                    journalEntryIDs: []
                ),
                sealedAt: installedAt,
                into: database
            )
            try run(
                """
                INSERT INTO sync_metadata(key, value, updated_at)
                VALUES (?, ?, ?)
                """,
                on: database
            ) { statement in
                bind(Self.activeProducerEpochMetadataKey, to: 1, in: statement)
                bind(
                    Data(reference.producerID.uuidString.lowercased().utf8),
                    to: 2,
                    in: statement
                )
                bind(
                    SQLiteISO8601DateCodec.string(from: installedAt),
                    to: 3,
                    in: statement
                )
            }
            try run(
                """
                INSERT INTO sync_replication_authority(
                    id, generation_id, producer_id, baseline_sequence,
                    baseline_seal_digest, installed_at_bits
                ) VALUES (1, ?, ?, 1, ?, ?)
                """,
                on: database
            ) { statement in
                bind(reference.generationID, to: 1, in: statement)
                bind(reference.producerID, to: 2, in: statement)
                bind(reference.sealDigest.rawValue, to: 3, in: statement)
                bindExactDate(installedAt, to: 4, in: statement)
            }
            guard try cleanCutAuthority(from: database)
                == SQLiteReplicationCleanCutAuthority(
                    generationID: reference.generationID,
                    producerID: reference.producerID,
                    baselineSequence: 1
                )
            else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "clean-cut replication authority was not installed"
                )
            }
            try execute("COMMIT", on: database)
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    /// V1 download evidence has no repository-generation identity. Keeping it
    /// past the V2 authority boundary would let a first V2 reconcile consume
    /// records, conflicts, or cursors from an unrelated repository. The purge
    /// is intentionally inside the same transaction as authority installation:
    /// domain facts, device identity, settings, and the now-inert V1 journal
    /// remain untouched.
    private func discardLegacySyncRuntimeEvidence(
        from database: OpaquePointer?
    ) throws {
        for statement in [
            "DELETE FROM sync_pending_download_dependencies",
            "DELETE FROM sync_pending_download_records",
            "DELETE FROM sync_terminal_rejections",
            "DELETE FROM sync_conflicts",
            "DELETE FROM sync_audit_log",
            "DELETE FROM sync_metadata",
        ] {
            try execute(statement, on: database)
        }
    }

    public func loadOrInstallActiveProducerID(
        suggestedProducerID: UUID,
        installedAt: Date
    ) throws -> UUID {
        guard installedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "active replication producer installation time is invalid"
            )
        }
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try storeRuntime.prepare(database)
        let writeLease = storeRuntime.acquireWriteLease()
        defer { writeLease.release() }
        try execute("BEGIN IMMEDIATE TRANSACTION", on: database)
        do {
            if let stored = try activeProducerID(from: database) {
                try execute("COMMIT", on: database)
                return stored
            }
            try run(
                """
                INSERT INTO sync_metadata(key, value, updated_at)
                VALUES (?, ?, ?)
                """,
                on: database
            ) { statement in
                bind(
                    Self.activeProducerEpochMetadataKey,
                    to: 1,
                    in: statement
                )
                bind(
                    Data(
                        suggestedProducerID.uuidString.lowercased().utf8
                    ),
                    to: 2,
                    in: statement
                )
                bind(
                    SQLiteISO8601DateCodec.string(from: installedAt),
                    to: 3,
                    in: statement
                )
            }
            guard try activeProducerID(from: database)
                == suggestedProducerID
            else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "active replication producer was not installed"
                )
            }
            try execute("COMMIT", on: database)
            return suggestedProducerID
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    func rotateActiveProducerAndSealBaseline(
        retiringProducerID: UUID,
        replacementProducerID: UUID,
        publication: SQLiteSealedLocalPublication,
        sealedAt: Date,
        expectedReplicationControl: LocalFirstReplicationControl? = nil
    ) throws {
        let reference = publication.reference
        guard retiringProducerID != replacementProducerID,
              reference.producerID == replacementProducerID,
              reference.sequence == 1,
              reference.previousSealDigest == nil,
              sealedAt.timeIntervalSinceReferenceDate.isFinite
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication producer rotation input is invalid"
            )
        }
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try storeRuntime.prepare(database)
        let writeLease = storeRuntime.acquireWriteLease()
        defer { writeLease.release() }
        try execute("BEGIN IMMEDIATE TRANSACTION", on: database)
        do {
            if let expectedReplicationControl {
                try syncRepository.assertLocalFirstReplicationControl(
                    expectedReplicationControl,
                    in: database
                )
            }
            guard try activeProducerID(from: database)
                == retiringProducerID
            else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "replication producer rotation lost its active epoch fence"
                )
            }
            if let resolutionID = reference.basedOnResolutionID {
                guard let resolution = try forkResolution(
                    resolutionID: resolutionID,
                    from: database
                ), resolution.state == .closed,
                    resolution.evidence.generationID
                    == reference.generationID,
                    resolution.evidence.producerID == retiringProducerID
                else {
                    throw SQLiteRepositoryError.invalidStoredValue(
                        "replication producer rotation lacks exact closed fork evidence"
                    )
                }
            }
            guard try publications(
                generationID: reference.generationID,
                producerID: replacementProducerID,
                sequence: 1,
                from: database
            ).isEmpty
            else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "replication producer replacement chain is not empty"
                )
            }
            try insertOrValidate(
                publication,
                sealedAt: sealedAt,
                into: database
            )
            if let authority = try cleanCutAuthority(from: database),
               authority.generationID == reference.generationID,
               authority.producerID == retiringProducerID,
               try cleanCutBaselineIsConfirmed(from: database) == false
            {
                guard reference.basedOnResolutionID == nil else {
                    throw SQLiteRepositoryError.invalidStoredValue(
                        "an unconfirmed clean-cut baseline cannot rotate through a fork repair"
                    )
                }
                try run(
                    """
                    UPDATE sync_replication_authority
                    SET producer_id = ?, baseline_sequence = 1,
                        baseline_seal_digest = ?, installed_at_bits = ?
                    WHERE id = 1 AND generation_id = ? AND producer_id = ?
                    """,
                    on: database
                ) { statement in
                    bind(replacementProducerID, to: 1, in: statement)
                    bind(reference.sealDigest.rawValue, to: 2, in: statement)
                    bindExactDate(sealedAt, to: 3, in: statement)
                    bind(reference.generationID, to: 4, in: statement)
                    bind(retiringProducerID, to: 5, in: statement)
                }
                guard sqlite3_changes(database) == 1,
                      try cleanCutAuthority(from: database)
                      == SQLiteReplicationCleanCutAuthority(
                          generationID: reference.generationID,
                          producerID: replacementProducerID,
                          baselineSequence: 1
                      )
                else {
                    throw SQLiteRepositoryError.invalidStoredValue(
                        "clean-cut baseline authority did not follow recovery rotation"
                    )
                }
            }
            try run(
                """
                UPDATE sync_metadata
                SET value = ?, updated_at = ?
                WHERE key = ? AND value = ?
                """,
                on: database
            ) { statement in
                bind(
                    Data(
                        replacementProducerID.uuidString.lowercased().utf8
                    ),
                    to: 1,
                    in: statement
                )
                bind(
                    SQLiteISO8601DateCodec.string(from: sealedAt),
                    to: 2,
                    in: statement
                )
                bind(
                    Self.activeProducerEpochMetadataKey,
                    to: 3,
                    in: statement
                )
                bind(
                    Data(retiringProducerID.uuidString.lowercased().utf8),
                    to: 4,
                    in: statement
                )
            }
            guard sqlite3_changes(database) == 1,
                  try activeProducerID(from: database)
                  == replacementProducerID
            else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "replication producer rotation did not commit its epoch"
                )
            }
            try execute("COMMIT", on: database)
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    func cleanCutBaselineIsConfirmed(
        from database: OpaquePointer?
    ) throws -> Bool {
        let values = try query(
            """
            SELECT 1
            FROM sync_replication_authority a
            JOIN sync_replication_confirmations c
              ON c.generation_id = a.generation_id
             AND c.producer_id = a.producer_id
             AND c.sequence = a.baseline_sequence
             AND c.seal_digest = a.baseline_seal_digest
            WHERE a.id = 1
            """,
            on: database
        ) { _ in true }
        guard values.count <= 1 else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "clean-cut baseline confirmation is duplicated"
            )
        }
        return values == [true]
    }

    func recordSealedLocalPublications(
        _ publications: [SQLiteSealedLocalPublication],
        sealedAt: Date,
        expectedReplicationControl: LocalFirstReplicationControl? = nil
    ) throws {
        guard publications.isEmpty == false,
              sealedAt.timeIntervalSinceReferenceDate.isFinite
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "sealed replication publication input is invalid"
            )
        }
        let ordered = publications.sorted {
            let left = $0.reference
            let right = $1.reference
            if left.generationID != right.generationID {
                return left.generationID.uuidString < right.generationID.uuidString
            }
            if left.producerID != right.producerID {
                return left.producerID.uuidString < right.producerID.uuidString
            }
            return left.sequence < right.sequence
        }
        guard Set(ordered.map(\.reference)).count == ordered.count,
              ordered.allSatisfy({
                  $0.reference.hasValidChainShape
                      && Set($0.journalEntryIDs).count
                      == $0.journalEntryIDs.count
                      && ($0.reference.basedOnResolutionID == nil
                          ? $0.journalEntryIDs.isEmpty == false
                          : $0.journalEntryIDs.isEmpty)
              })
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "sealed replication publications are invalid or duplicated"
            )
        }

        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try storeRuntime.prepare(database)
        let writeLease = storeRuntime.acquireWriteLease()
        defer { writeLease.release() }
        try execute("BEGIN IMMEDIATE TRANSACTION", on: database)
        do {
            if let expectedReplicationControl {
                try syncRepository.assertLocalFirstReplicationControl(
                    expectedReplicationControl,
                    in: database
                )
            }
            for publication in ordered {
                try insertOrValidate(
                    publication,
                    sealedAt: sealedAt,
                    into: database
                )
            }
            try execute("COMMIT", on: database)
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    func recordConfirmation(
        for reference: ReplicationPublicationReference,
        confirmedAt: Date,
        expectedReplicationControl: LocalFirstReplicationControl? = nil
    ) throws -> SQLiteReplicationLedgerSnapshot {
        guard reference.hasValidChainShape,
              confirmedAt.timeIntervalSinceReferenceDate.isFinite
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication confirmation is invalid"
            )
        }
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try storeRuntime.prepare(database)
        let writeLease = storeRuntime.acquireWriteLease()
        defer { writeLease.release() }
        try execute("BEGIN IMMEDIATE TRANSACTION", on: database)
        do {
            if let expectedReplicationControl {
                try syncRepository.assertLocalFirstReplicationControl(
                    expectedReplicationControl,
                    in: database
                )
            }
            guard try storedPublication(
                generationID: reference.generationID,
                producerID: reference.producerID,
                sequence: reference.sequence,
                sealDigest: reference.sealDigest,
                from: database
            ) == reference else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "confirmation does not match a sealed local publication"
                )
            }
            try run(
                """
                INSERT INTO sync_replication_confirmations(
                    generation_id, producer_id, sequence, seal_digest,
                    confirmed_at_bits
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(generation_id, producer_id, sequence, seal_digest)
                DO NOTHING
                """,
                on: database
            ) { statement in
                bind(reference.generationID, to: 1, in: statement)
                bind(reference.producerID, to: 2, in: statement)
                try bind(reference.sequence, to: 3, in: statement)
                bind(reference.sealDigest.rawValue, to: 4, in: statement)
                bindExactDate(confirmedAt, to: 5, in: statement)
            }
            try advanceLongestConfirmedPrefix(
                generationID: reference.generationID,
                producerID: reference.producerID,
                updatedAt: confirmedAt,
                in: database
            )
            let snapshot = try snapshot(
                generationID: reference.generationID,
                producerID: reference.producerID,
                from: database
            )
            try execute("COMMIT", on: database)
            return snapshot
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    public func pendingLocalPublications(
        generationID: UUID,
        producerID: UUID
    ) throws -> [SealedReplicationPublication] {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try storeRuntime.prepare(database)
        return try query(
            """
            SELECT p.sealed_publication
            FROM sync_replication_publications p
            LEFT JOIN sync_replication_confirmations c
              ON c.generation_id = p.generation_id
             AND c.producer_id = p.producer_id
             AND c.sequence = p.sequence
             AND c.seal_digest = p.seal_digest
            WHERE p.generation_id = ? AND p.producer_id = ?
              AND c.sequence IS NULL
            ORDER BY p.sequence
            """,
            on: database
        ) { statement in
            bind(generationID, to: 1, in: statement)
            bind(producerID, to: 2, in: statement)
        } row: { statement in
            try sealedPublication(statement, 0)
        }
    }

    public func latestSealedReference(
        generationID: UUID,
        producerID: UUID
    ) throws -> ReplicationPublicationReference? {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try storeRuntime.prepare(database)
        return try query(
            """
            SELECT sequence, previous_seal_digest, root_digest, seal_digest,
                announcement_digest, based_on_resolution_id
            FROM sync_replication_publications
            WHERE generation_id = ? AND producer_id = ?
            ORDER BY sequence DESC
            LIMIT 1
            """,
            on: database
        ) { statement in
            bind(generationID, to: 1, in: statement)
            bind(producerID, to: 2, in: statement)
        } row: { statement in
            ReplicationPublicationReference(
                generationID: generationID,
                producerID: producerID,
                sequence: try uint64(statement, 0),
                previousSealDigest: try optionalDigest(statement, 1),
                rootDigest: try digest(statement, 2),
                sealDigest: try digest(statement, 3),
                announcementDigest: try digest(statement, 4),
                basedOnResolutionID: try optionalDigest(statement, 5)
            )
        }.first
    }

    public func sealedJournalEntryIDs(
        generationID: UUID,
        producerID: UUID
    ) throws -> Set<UUID> {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try storeRuntime.prepare(database)
        return Set(try query(
            """
            SELECT journal_id
            FROM sync_replication_publication_journal
            WHERE generation_id = ? AND producer_id = ?
            """,
            on: database
        ) { statement in
            bind(generationID, to: 1, in: statement)
            bind(producerID, to: 2, in: statement)
        } row: { statement in
            try uuid(statement, 0)
        })
    }

    public func snapshot(
        generationID: UUID,
        producerID: UUID
    ) throws -> SQLiteReplicationLedgerSnapshot {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try storeRuntime.prepare(database)
        try execute("BEGIN DEFERRED TRANSACTION", on: database)
        do {
            let result = try snapshot(
                generationID: generationID,
                producerID: producerID,
                from: database
            )
            try execute("COMMIT", on: database)
            return result
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    func recordValidatedForkEvidence(
        _ evidence: ReplicationForkEvidence,
        detectedAt: Date,
        expectedReplicationControl: LocalFirstReplicationControl? = nil
    ) throws -> SQLiteReplicationForkResolution {
        guard detectedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "fork detection time is invalid"
            )
        }
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try storeRuntime.prepare(database)
        let writeLease = storeRuntime.acquireWriteLease()
        defer { writeLease.release() }
        try execute("BEGIN IMMEDIATE TRANSACTION", on: database)
        do {
            if let expectedReplicationControl {
                try syncRepository.assertLocalFirstReplicationControl(
                    expectedReplicationControl,
                    in: database
                )
            }
            if let stored = try forkResolution(
                resolutionID: evidence.resolutionID,
                from: database
            ) {
                guard stored.evidence == evidence else {
                    throw SQLiteRepositoryError.invalidStoredValue(
                        "fork resolution identity collision"
                    )
                }
                try execute("COMMIT", on: database)
                return stored
            }
            let branchEvidence = try ReplicationPublicationBuilder
                .canonicalEncoder().encode(evidence.branches)
            try run(
                """
                INSERT INTO sync_replication_fork_resolutions(
                    resolution_id, generation_id, producer_id,
                    fork_sequence, common_prefix_sequence,
                    common_prefix_seal_digest, state, branch_evidence,
                    detected_at_bits, updated_at_bits
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                on: database
            ) { statement in
                bind(evidence.resolutionID.rawValue, to: 1, in: statement)
                bind(evidence.generationID, to: 2, in: statement)
                bind(evidence.producerID, to: 3, in: statement)
                try bind(evidence.sequence, to: 4, in: statement)
                try bind(
                    evidence.commonPrefix?.sequence,
                    to: 5,
                    in: statement
                )
                bind(
                    evidence.commonPrefix?.sealDigest.rawValue,
                    to: 6,
                    in: statement
                )
                bind(
                    ReplicationForkResolutionState.branchesValidated.rawValue,
                    to: 7,
                    in: statement
                )
                bind(branchEvidence, to: 8, in: statement)
                bindExactDate(detectedAt, to: 9, in: statement)
                bindExactDate(detectedAt, to: 10, in: statement)
            }
            guard let inserted = try forkResolution(
                resolutionID: evidence.resolutionID,
                from: database
            ) else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "fork resolution was not persisted"
                )
            }
            try execute("COMMIT", on: database)
            return inserted
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    public func forkResolution(
        resolutionID: ReplicationDigest
    ) throws -> SQLiteReplicationForkResolution? {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try storeRuntime.prepare(database)
        return try forkResolution(
            resolutionID: resolutionID,
            from: database
        )
    }

    public func closedForkResolutionsAwaitingBaseline(
        generationID: UUID,
        producerID: UUID
    ) throws -> [SQLiteReplicationForkResolution] {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try storeRuntime.prepare(database)
        let resolutionIDs: [ReplicationDigest] = try query(
            """
            SELECT r.resolution_id
            FROM sync_replication_fork_resolutions r
            WHERE r.generation_id = ? AND r.state = 'closed'
              AND NOT EXISTS (
                SELECT 1
                FROM sync_replication_publications p
                WHERE p.generation_id = r.generation_id
                  AND p.producer_id = ?
                  AND p.based_on_resolution_id = r.resolution_id
              )
            ORDER BY r.detected_at_bits, r.resolution_id
            """,
            on: database
        ) { statement in
            bind(generationID, to: 1, in: statement)
            bind(producerID, to: 2, in: statement)
        } row: { statement in
            try digest(statement, 0)
        }
        return try resolutionIDs.map { resolutionID in
            guard let resolution = try forkResolution(
                resolutionID: resolutionID,
                from: database
            ) else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "closed fork resolution disappeared during baseline scan"
                )
            }
            return resolution
        }
    }
}

private extension SQLiteReplicationLedger {
    func cleanCutAuthority(
        from database: Database?
    ) throws -> SQLiteReplicationCleanCutAuthority? {
        let values = try query(
            """
            SELECT generation_id, producer_id, baseline_sequence
            FROM sync_replication_authority
            WHERE id = 1
            """,
            on: database
        ) { statement in
            SQLiteReplicationCleanCutAuthority(
                generationID: try uuid(statement, 0),
                producerID: try uuid(statement, 1),
                baselineSequence: try uint64(statement, 2)
            )
        }
        guard values.count <= 1 else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "clean-cut replication authority is duplicated"
            )
        }
        return values.first
    }

    func replicationPublicationCount(
        from database: Database?
    ) throws -> Int {
        let values = try query(
            "SELECT COUNT(*) FROM sync_replication_publications",
            on: database
        ) { statement in
            guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "replication publication count is not an integer"
                )
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
        guard values.count == 1, let value = values.first else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication publication count is missing or duplicated"
            )
        }
        return value
    }

    func activeProducerID(from database: Database?) throws -> UUID? {
        let values: [Data] = try query(
            "SELECT value FROM sync_metadata WHERE key = ?",
            on: database
        ) { statement in
            bind(
                Self.activeProducerEpochMetadataKey,
                to: 1,
                in: statement
            )
        } row: { statement in
            try data(statement, 0)
        }
        guard let stored = values.first else { return nil }
        guard let value = String(data: stored, encoding: .utf8),
              let producerID = UUID(uuidString: value),
              producerID.uuidString.lowercased() == value
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "active replication producer epoch is invalid"
            )
        }
        return producerID
    }

    func forkResolution(
        resolutionID: ReplicationDigest,
        from database: Database?
    ) throws -> SQLiteReplicationForkResolution? {
        try query(
            """
            SELECT generation_id, producer_id, fork_sequence,
                common_prefix_sequence, common_prefix_seal_digest,
                state, branch_evidence
            FROM sync_replication_fork_resolutions
            WHERE resolution_id = ?
            """,
            on: database
        ) { statement in
            bind(resolutionID.rawValue, to: 1, in: statement)
        } row: { statement in
            let generationID = try uuid(statement, 0)
            let producerID = try uuid(statement, 1)
            let sequence = try uint64(statement, 2)
            let commonPrefixSequence = try optionalUInt64(statement, 3)
            let commonPrefixSealDigest = try optionalDigest(statement, 4)
            guard let state = ReplicationForkResolutionState(
                rawValue: try string(statement, 5)
            ) else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "fork resolution state is invalid"
                )
            }
            let branches: [ReceivedReplicationPublication]
            do {
                branches = try ReplicationPublicationBuilder
                    .canonicalDecoder().decode(
                        [ReceivedReplicationPublication].self,
                        from: try data(statement, 6)
                    )
            } catch let error as SQLiteRepositoryError {
                throw error
            } catch {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "fork branch evidence cannot be decoded"
                )
            }
            let evidence = try ReplicationForkEvidence(branches: branches)
            guard evidence.resolutionID == resolutionID,
                  evidence.generationID == generationID,
                  evidence.producerID == producerID,
                  evidence.sequence == sequence,
                  evidence.commonPrefix?.sequence == commonPrefixSequence,
                  evidence.commonPrefix?.sealDigest
                  == commonPrefixSealDigest
            else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "fork resolution evidence does not match its ledger key"
                )
            }
            return SQLiteReplicationForkResolution(
                resolutionID: resolutionID,
                state: state,
                evidence: evidence
            )
        }.first
    }

    func insertOrValidate(
        _ publication: SQLiteSealedLocalPublication,
        sealedAt: Date,
        into database: Database?
    ) throws {
        let reference = publication.reference
        let sealedData = try encode(publication.publication)
        if let resolutionID = reference.basedOnResolutionID {
            guard let resolution = try forkResolution(
                resolutionID: resolutionID,
                from: database
            ), resolution.state == .closed,
                resolution.evidence.generationID == reference.generationID
            else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "repair baseline is not bound to a closed resolution"
                )
            }
        }
        let sameSequence = try publications(
            generationID: reference.generationID,
            producerID: reference.producerID,
            sequence: reference.sequence,
            from: database
        )
        guard sameSequence.isEmpty || sameSequence == [reference] else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "local replication producer forked at a sealed sequence"
            )
        }
        if reference.sequence > 1 {
            let predecessor = try publications(
                generationID: reference.generationID,
                producerID: reference.producerID,
                sequence: reference.sequence - 1,
                from: database
            )
            guard predecessor.count == 1,
                  predecessor[0].sealDigest == reference.previousSealDigest
            else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "sealed replication publication has no exact predecessor"
                )
            }
        }
        try run(
            """
            INSERT INTO sync_replication_publications(
                generation_id, producer_id, sequence,
                previous_seal_digest, root_digest, seal_digest,
                announcement_digest, based_on_resolution_id,
                sealed_at_bits, sealed_publication
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(generation_id, producer_id, sequence, seal_digest)
            DO NOTHING
            """,
            on: database
        ) { statement in
            bind(reference.generationID, to: 1, in: statement)
            bind(reference.producerID, to: 2, in: statement)
            try bind(reference.sequence, to: 3, in: statement)
            bind(reference.previousSealDigest?.rawValue, to: 4, in: statement)
            bind(reference.rootDigest.rawValue, to: 5, in: statement)
            bind(reference.sealDigest.rawValue, to: 6, in: statement)
            bind(reference.announcementDigest.rawValue, to: 7, in: statement)
            bind(reference.basedOnResolutionID?.rawValue, to: 8, in: statement)
            bindExactDate(sealedAt, to: 9, in: statement)
            bind(sealedData, to: 10, in: statement)
        }
        guard try storedPublication(
            generationID: reference.generationID,
            producerID: reference.producerID,
            sequence: reference.sequence,
            sealDigest: reference.sealDigest,
            from: database
        ) == reference else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "sealed replication publication collided with different evidence"
            )
        }
        guard try storedSealedPublication(
            generationID: reference.generationID,
            producerID: reference.producerID,
            sequence: reference.sequence,
            sealDigest: reference.sealDigest,
            from: database
        ) == publication.publication else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "sealed replication bytes collided with different evidence"
            )
        }
        for journalID in publication.journalEntryIDs {
            let isMapped = try journalIsMapped(
                id: journalID,
                to: reference,
                in: database
            )
            if let authority = try cleanCutAuthority(from: database) {
                guard authority.generationID == reference.generationID,
                      try outboxEntryIsPending(
                          id: journalID,
                          generationID: reference.generationID,
                          from: database
                      ) || isMapped
                else {
                    throw SQLiteRepositoryError.invalidStoredValue(
                        "sealed publication outbox entry is not pending"
                    )
                }
            } else {
                let state = try journalState(id: journalID, from: database)
                guard state == "pendingUpload" || isMapped else {
                    throw SQLiteRepositoryError.invalidStoredValue(
                        "sealed publication journal is not pending"
                    )
                }
            }
            try run(
                """
                INSERT INTO sync_replication_publication_journal(
                    generation_id, producer_id, sequence, seal_digest,
                    journal_id
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(generation_id, producer_id, journal_id)
                DO NOTHING
                """,
                on: database
            ) { statement in
                bind(reference.generationID, to: 1, in: statement)
                bind(reference.producerID, to: 2, in: statement)
                try bind(reference.sequence, to: 3, in: statement)
                bind(reference.sealDigest.rawValue, to: 4, in: statement)
                bind(journalID, to: 5, in: statement)
            }
            guard try journalIsMapped(
                id: journalID,
                to: reference,
                in: database
            ) else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "sealed publication journal collided with another publication"
                )
            }
        }
    }

    func advanceLongestConfirmedPrefix(
        generationID: UUID,
        producerID: UUID,
        updatedAt: Date,
        in database: Database?
    ) throws {
        var watermark = try selfWatermark(
            generationID: generationID,
            producerID: producerID,
            from: database
        )
        while true {
            let nextSequence = (watermark?.sequence ?? 0) + 1
            let confirmed = try confirmedPublications(
                generationID: generationID,
                producerID: producerID,
                sequence: nextSequence,
                from: database
            )
            guard confirmed.isEmpty == false else { break }
            guard confirmed.count == 1 else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "confirmed replication sequence contains a fork"
                )
            }
            let next = confirmed[0]
            guard next.previousSealDigest == watermark?.sealDigest else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "confirmed replication chain does not match its watermark"
                )
            }
            watermark = ReplicationSelfWatermark(
                sequence: next.sequence,
                sealDigest: next.sealDigest
            )
        }
        guard let watermark else { return }
        try run(
            """
            INSERT INTO sync_replication_self_watermarks(
                generation_id, producer_id, sequence, seal_digest,
                updated_at_bits
            ) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(generation_id, producer_id) DO UPDATE SET
                sequence = excluded.sequence,
                seal_digest = excluded.seal_digest,
                updated_at_bits = excluded.updated_at_bits
            WHERE excluded.sequence >= sync_replication_self_watermarks.sequence
            """,
            on: database
        ) { statement in
            bind(generationID, to: 1, in: statement)
            bind(producerID, to: 2, in: statement)
            try bind(watermark.sequence, to: 3, in: statement)
            bind(watermark.sealDigest.rawValue, to: 4, in: statement)
            bindExactDate(updatedAt, to: 5, in: statement)
        }
        let journalIDs: [UUID] = try query(
            """
            SELECT journal_id
            FROM sync_replication_publication_journal
            WHERE generation_id = ? AND producer_id = ?
              AND sequence <= ?
            ORDER BY sequence, journal_id
            """,
            on: database
        ) { statement in
            bind(generationID, to: 1, in: statement)
            bind(producerID, to: 2, in: statement)
            try bind(watermark.sequence, to: 3, in: statement)
        } row: { statement in
            try uuid(statement, 0)
        }
        if let authority = try cleanCutAuthority(from: database) {
            guard authority.generationID == generationID else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "confirmed replication generation differs from authority"
                )
            }
            for journalID in journalIDs {
                try run(
                    """
                    UPDATE sync_replication_outbox
                    SET confirmed_at_bits = COALESCE(confirmed_at_bits, ?)
                    WHERE generation_id = ? AND journal_id = ?
                    """,
                    on: database
                ) { statement in
                    bindExactDate(updatedAt, to: 1, in: statement)
                    bind(generationID, to: 2, in: statement)
                    bind(journalID, to: 3, in: statement)
                }
                guard sqlite3_changes(database) == 1 else {
                    throw SQLiteRepositoryError.invalidStoredValue(
                        "confirmed replication outbox changed before watermark commit"
                    )
                }
            }
        } else {
            for journalID in journalIDs {
                try run(
                    """
                    UPDATE change_journal
                    SET sync_state = 'uploaded', last_error = NULL
                    WHERE id = ? AND sync_state IN ('pendingUpload', 'uploaded')
                    """,
                    on: database
                ) { statement in
                    bind(journalID, to: 1, in: statement)
                }
                guard sqlite3_changes(database) == 1 else {
                    throw SQLiteRepositoryError.invalidStoredValue(
                        "confirmed replication journal changed before watermark commit"
                    )
                }
            }
        }
    }

    func snapshot(
        generationID: UUID,
        producerID: UUID,
        from database: Database?
    ) throws -> SQLiteReplicationLedgerSnapshot {
        let sequences: [UInt64] = try query(
            """
            SELECT sequence
            FROM sync_replication_confirmations
            WHERE generation_id = ? AND producer_id = ?
            ORDER BY sequence
            """,
            on: database
        ) { statement in
            bind(generationID, to: 1, in: statement)
            bind(producerID, to: 2, in: statement)
        } row: { statement in
            try uint64(statement, 0)
        }
        return SQLiteReplicationLedgerSnapshot(
            confirmedSequences: sequences,
            selfWatermark: try selfWatermark(
                generationID: generationID,
                producerID: producerID,
                from: database
            )
        )
    }

    func selfWatermark(
        generationID: UUID,
        producerID: UUID,
        from database: Database?
    ) throws -> ReplicationSelfWatermark? {
        try query(
            """
            SELECT sequence, seal_digest
            FROM sync_replication_self_watermarks
            WHERE generation_id = ? AND producer_id = ?
            """,
            on: database
        ) { statement in
            bind(generationID, to: 1, in: statement)
            bind(producerID, to: 2, in: statement)
        } row: { statement in
            ReplicationSelfWatermark(
                sequence: try uint64(statement, 0),
                sealDigest: try digest(statement, 1)
            )
        }.first
    }

    func publications(
        generationID: UUID,
        producerID: UUID,
        sequence: UInt64,
        from database: Database?
    ) throws -> [ReplicationPublicationReference] {
        try query(
            """
            SELECT previous_seal_digest, root_digest, seal_digest,
                announcement_digest, based_on_resolution_id
            FROM sync_replication_publications
            WHERE generation_id = ? AND producer_id = ? AND sequence = ?
            ORDER BY seal_digest
            """,
            on: database
        ) { statement in
            bind(generationID, to: 1, in: statement)
            bind(producerID, to: 2, in: statement)
            try bind(sequence, to: 3, in: statement)
        } row: { statement in
            ReplicationPublicationReference(
                generationID: generationID,
                producerID: producerID,
                sequence: sequence,
                previousSealDigest: try optionalDigest(statement, 0),
                rootDigest: try digest(statement, 1),
                sealDigest: try digest(statement, 2),
                announcementDigest: try digest(statement, 3),
                basedOnResolutionID: try optionalDigest(statement, 4)
            )
        }
    }

    func confirmedPublications(
        generationID: UUID,
        producerID: UUID,
        sequence: UInt64,
        from database: Database?
    ) throws -> [ReplicationPublicationReference] {
        try query(
            """
            SELECT p.previous_seal_digest, p.root_digest, p.seal_digest,
                p.announcement_digest, p.based_on_resolution_id
            FROM sync_replication_publications p
            JOIN sync_replication_confirmations c
              ON c.generation_id = p.generation_id
             AND c.producer_id = p.producer_id
             AND c.sequence = p.sequence
             AND c.seal_digest = p.seal_digest
            WHERE p.generation_id = ? AND p.producer_id = ?
              AND p.sequence = ?
            ORDER BY p.seal_digest
            """,
            on: database
        ) { statement in
            bind(generationID, to: 1, in: statement)
            bind(producerID, to: 2, in: statement)
            try bind(sequence, to: 3, in: statement)
        } row: { statement in
            ReplicationPublicationReference(
                generationID: generationID,
                producerID: producerID,
                sequence: sequence,
                previousSealDigest: try optionalDigest(statement, 0),
                rootDigest: try digest(statement, 1),
                sealDigest: try digest(statement, 2),
                announcementDigest: try digest(statement, 3),
                basedOnResolutionID: try optionalDigest(statement, 4)
            )
        }
    }

    func storedPublication(
        generationID: UUID,
        producerID: UUID,
        sequence: UInt64,
        sealDigest: ReplicationDigest,
        from database: Database?
    ) throws -> ReplicationPublicationReference? {
        try publications(
            generationID: generationID,
            producerID: producerID,
            sequence: sequence,
            from: database
        ).first { $0.sealDigest == sealDigest }
    }

    func storedSealedPublication(
        generationID: UUID,
        producerID: UUID,
        sequence: UInt64,
        sealDigest: ReplicationDigest,
        from database: Database?
    ) throws -> SealedReplicationPublication? {
        try query(
            """
            SELECT sealed_publication
            FROM sync_replication_publications
            WHERE generation_id = ? AND producer_id = ?
              AND sequence = ? AND seal_digest = ?
            """,
            on: database
        ) { statement in
            bind(generationID, to: 1, in: statement)
            bind(producerID, to: 2, in: statement)
            try bind(sequence, to: 3, in: statement)
            bind(sealDigest.rawValue, to: 4, in: statement)
        } row: { statement in
            try sealedPublication(statement, 0)
        }.first
    }

    func journalState(
        id: UUID,
        from database: Database?
    ) throws -> String? {
        try query(
            "SELECT sync_state FROM change_journal WHERE id = ?",
            on: database
        ) { statement in
            bind(id, to: 1, in: statement)
        } row: { statement in
            try string(statement, 0)
        }.first
    }

    func outboxEntryIsPending(
        id: UUID,
        generationID: UUID,
        from database: Database?
    ) throws -> Bool {
        try query(
            """
            SELECT 1
            FROM sync_replication_outbox
            WHERE generation_id = ? AND journal_id = ?
              AND confirmed_at_bits IS NULL
            """,
            on: database
        ) { statement in
            bind(generationID, to: 1, in: statement)
            bind(id, to: 2, in: statement)
        } row: { _ in true }.first ?? false
    }

    func journalIsMapped(
        id: UUID,
        to reference: ReplicationPublicationReference,
        in database: Database?
    ) throws -> Bool {
        try query(
            """
            SELECT 1
            FROM sync_replication_publication_journal
            WHERE generation_id = ? AND producer_id = ?
              AND sequence = ? AND seal_digest = ? AND journal_id = ?
            """,
            on: database
        ) { statement in
            bind(reference.generationID, to: 1, in: statement)
            bind(reference.producerID, to: 2, in: statement)
            try bind(reference.sequence, to: 3, in: statement)
            bind(reference.sealDigest.rawValue, to: 4, in: statement)
            bind(id, to: 5, in: statement)
        } row: { _ in true }.first ?? false
    }

    func openDatabase() throws -> Database? {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var database: Database?
        let result = sqlite3_open(databaseURL.path, &database)
        guard result == SQLITE_OK else {
            let message = database.map {
                String(cString: sqlite3_errmsg($0))
            } ?? "unknown sqlite open error"
            let code = sqliteDiagnosticCode(database) ?? result
            sqlite3_close(database)
            throw SQLiteRepositoryError.openFailed(
                message,
                sqliteCode: code
            )
        }
        return database
    }

    func execute(_ sql: String, on database: Database?) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteRepositoryError.executeFailed(
                "replication ledger writerDepth=\(storeRuntime.writerLeaseDepth): \(lastError(database)) in \(sqlSummary(sql))",
                sqliteCode: sqliteDiagnosticCode(database)
            )
        }
    }

    func prepare(_ sql: String, on database: Database?) throws -> Statement? {
        var statement: Statement?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil)
            == SQLITE_OK
        else {
            throw SQLiteRepositoryError.prepareFailed(
                lastError(database),
                sqliteCode: sqliteDiagnosticCode(database)
            )
        }
        return statement
    }

    func sqlSummary(_ sql: String) -> String {
        sql.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { $0.isEmpty == false }) ?? "SQLite statement"
    }

    func run(
        _ sql: String,
        on database: Database?,
        bind: (Statement?) throws -> Void
    ) throws {
        let writeLease = storeRuntime.acquireWriteLease()
        defer { writeLease.release() }
        let statement = try prepare(sql, on: database)
        defer { sqlite3_finalize(statement) }
        try bind(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteRepositoryError.stepFailed(
                lastError(database),
                sqliteCode: sqliteDiagnosticCode(database)
            )
        }
    }

    func query<Value>(
        _ sql: String,
        on database: Database?,
        bind: (Statement?) throws -> Void = { _ in },
        row: (Statement?) throws -> Value
    ) throws -> [Value] {
        let statement = try prepare(sql, on: database)
        defer { sqlite3_finalize(statement) }
        try bind(statement)
        var values: [Value] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_DONE:
                return values
            case SQLITE_ROW:
                values.append(try row(statement))
            default:
                throw SQLiteRepositoryError.stepFailed(
                    lastError(database),
                    sqliteCode: sqliteDiagnosticCode(database)
                )
            }
        }
    }

    func bind(
        _ value: String?,
        to index: Int32,
        in statement: Statement?
    ) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    func bind(_ value: UUID, to index: Int32, in statement: Statement?) {
        bind(value.uuidString, to: index, in: statement)
    }

    func bind(_ value: Data, to index: Int32, in statement: Statement?) {
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement,
                index,
                bytes.baseAddress,
                Int32(value.count),
                SQLITE_TRANSIENT
            )
        }
    }

    func bind(_ value: UInt64, to index: Int32, in statement: Statement?) throws {
        guard value <= UInt64(Int64.max) else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication sequence exceeds SQLite integer range"
            )
        }
        sqlite3_bind_int64(statement, index, Int64(value))
    }

    func bind(
        _ value: UInt64?,
        to index: Int32,
        in statement: Statement?
    ) throws {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        try bind(value, to: index, in: statement)
    }

    func bindExactDate(_ value: Date, to index: Int32, in statement: Statement?) {
        sqlite3_bind_int64(
            statement,
            index,
            Int64(bitPattern: value.timeIntervalSinceReferenceDate.bitPattern)
        )
    }

    func string(_ statement: Statement?, _ index: Int32) throws -> String {
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT,
              let bytes = sqlite3_column_text(statement, index)
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication ledger column is not text"
            )
        }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard let value = String(
            bytes: UnsafeBufferPointer(start: bytes, count: count),
            encoding: .utf8
        ) else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication ledger column is not UTF-8"
            )
        }
        return value
    }

    func optionalString(
        _ statement: Statement?,
        _ index: Int32
    ) throws -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return try string(statement, index)
    }

    func data(_ statement: Statement?, _ index: Int32) throws -> Data {
        guard sqlite3_column_type(statement, index) == SQLITE_BLOB,
              let bytes = sqlite3_column_blob(statement, index)
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication ledger column is not a blob"
            )
        }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0 else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication ledger blob is empty"
            )
        }
        return Data(bytes: bytes, count: count)
    }

    func uuid(_ statement: Statement?, _ index: Int32) throws -> UUID {
        guard let value = UUID(uuidString: try string(statement, index)) else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication ledger UUID is invalid"
            )
        }
        return value
    }

    func uint64(_ statement: Statement?, _ index: Int32) throws -> UInt64 {
        guard sqlite3_column_type(statement, index) == SQLITE_INTEGER else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication ledger sequence is not an integer"
            )
        }
        let value = sqlite3_column_int64(statement, index)
        guard value > 0 else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication ledger sequence is invalid"
            )
        }
        return UInt64(value)
    }

    func optionalUInt64(
        _ statement: Statement?,
        _ index: Int32
    ) throws -> UInt64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return try uint64(statement, index)
    }

    func digest(
        _ statement: Statement?,
        _ index: Int32
    ) throws -> ReplicationDigest {
        try ReplicationDigest(validating: string(statement, index))
    }

    func optionalDigest(
        _ statement: Statement?,
        _ index: Int32
    ) throws -> ReplicationDigest? {
        try optionalString(statement, index).map {
            try ReplicationDigest(validating: $0)
        }
    }

    func encode(_ publication: SealedReplicationPublication) throws -> Data {
        try ReplicationPublicationBuilder.canonicalEncoder().encode(
            publication
        )
    }

    func sealedPublication(
        _ statement: Statement?,
        _ index: Int32
    ) throws -> SealedReplicationPublication {
        guard sqlite3_column_type(statement, index) == SQLITE_BLOB,
              let bytes = sqlite3_column_blob(statement, index)
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "sealed replication publication is not a blob"
            )
        }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0 else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "sealed replication publication is empty"
            )
        }
        do {
            return try ReplicationPublicationBuilder.canonicalDecoder().decode(
                SealedReplicationPublication.self,
                from: Data(bytes: bytes, count: count)
            )
        } catch {
            throw SQLiteRepositoryError.invalidStoredValue(
                "sealed replication publication cannot be decoded"
            )
        }
    }

    func lastError(_ database: Database?) -> String {
        database.map { String(cString: sqlite3_errmsg($0)) }
            ?? "unknown sqlite error"
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)
