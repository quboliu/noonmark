import Foundation
import NoonmarkCore
import NoonmarkSync
import SQLite3

public struct SyncPendingDownloadRecord: Equatable, Sendable {
    public let record: SyncRecord
    public let generationID: UUID
    public let dependencies: [SyncRecordDependency]
    public let firstSeenAt: Date
    public let lastAttemptedAt: Date
    public let attemptCount: Int

    public init(
        record: SyncRecord,
        generationID: UUID,
        dependencies: [SyncRecordDependency],
        firstSeenAt: Date,
        lastAttemptedAt: Date,
        attemptCount: Int
    ) {
        self.record = record
        self.generationID = generationID
        self.dependencies = dependencies
        self.firstSeenAt = firstSeenAt
        self.lastAttemptedAt = lastAttemptedAt
        self.attemptCount = attemptCount
    }
}

struct SQLiteSyncDownloadCommit {
    let sourceSnapshot: NoonmarkSnapshot
    let snapshot: NoonmarkSnapshot
    let observedEngineGeneration: SQLiteEngineSnapshotGeneration
    let conflicts: [SyncConflict]
    let waiting: [SyncWaitingRecord]
    let terminal: [SyncPendingDownloadRecord]
    let observedPending: [SyncPendingDownloadRecord]
    let auditEntries: [SyncAuditLogEntry]
    let metadata: SyncMetadataEntry
    let frontierMetadata: SyncMetadataEntry?
    let forkResolutionTransition: SQLiteReplicationForkTransition?
    let forkConflictDecisionCommit: SQLiteReplicationForkDecisionCommit?
    let expectedReplicationControl: LocalFirstReplicationControl?
    let attemptedAt: Date
}

struct SQLiteReplicationForkTransition {
    let resolutionID: ReplicationDigest
    let expectedState: ReplicationForkResolutionState
    let newState: ReplicationForkResolutionState
}

public enum ReplicationForkConflictDecision:
    String,
    Codable,
    Equatable,
    Sendable
{
    case keepCurrent
    case acceptRemote
    case copyAsNew

    static func allowedDecisions(
        for conflict: SyncConflict
    ) -> [ReplicationForkConflictDecision] {
        switch (conflict.type, conflict.entityType) {
        case (.taskDefinitionMutation, .taskDefinition):
            [.keepCurrent, .acceptRemote, .copyAsNew]
        case (.historicalTraceMutation, .dayTrace),
             (.duplicateActiveTrace, .dayTrace),
             (.historicalSubtaskMutation, .subtask):
            [.keepCurrent, .copyAsNew]
        default:
            [.keepCurrent]
        }
    }
}

public struct ReplicationForkConflictDecisionSelection:
    Codable,
    Equatable,
    Sendable
{
    public let conflictID: UUID
    public let decision: ReplicationForkConflictDecision

    public init(
        conflictID: UUID,
        decision: ReplicationForkConflictDecision
    ) {
        self.conflictID = conflictID
        self.decision = decision
    }
}

public struct ReplicationForkDecisionResultReference:
    Codable,
    Equatable,
    Sendable
{
    public let entityType: SyncEntityType
    public let entityID: String

    public init(entityType: SyncEntityType, entityID: String) {
        self.entityType = entityType
        self.entityID = entityID
    }
}

struct SQLiteReplicationForkDecisionOutcome {
    let selection: ReplicationForkConflictDecisionSelection
    let resultReference: ReplicationForkDecisionResultReference?
}

struct SQLiteReplicationForkDecisionCommit {
    let resolutionID: ReplicationDigest
    let observedEngineGeneration: SQLiteEngineSnapshotGeneration
    let outcomes: [SQLiteReplicationForkDecisionOutcome]
}

public struct SQLiteReplicationForkConflict: Equatable, Sendable {
    public let conflict: SyncConflict
    public let decision: ReplicationForkConflictDecision?
    public let decidedAt: Date?
    public let resultReference: ReplicationForkDecisionResultReference?

    public init(
        conflict: SyncConflict,
        decision: ReplicationForkConflictDecision?,
        decidedAt: Date?,
        resultReference: ReplicationForkDecisionResultReference? = nil
    ) {
        self.conflict = conflict
        self.decision = decision
        self.decidedAt = decidedAt
        self.resultReference = resultReference
    }
}

public struct SQLiteReplicationForkConflictSet: Equatable, Sendable {
    public let resolutionID: ReplicationDigest
    public let conflicts: [SQLiteReplicationForkConflict]

    let observedEngineGeneration: SQLiteEngineSnapshotGeneration
}

enum LocalFirstReplicationPolicy: String, Codable, Equatable, Sendable {
    case enabled
    case disabled
}

struct LocalFirstReplicationControl: Codable, Equatable, Sendable {
    let policy: LocalFirstReplicationPolicy
    let generation: UInt64
    let updatedAt: Date
}

public final class SQLiteSyncRepository {
    public static let transportProducerEpochMetadataKey =
        "sync.transport.producerEpoch.v1"
    static let localFirstReplicationControlMetadataKey =
        "localFirst.replication.v2.control"

    private let databaseURL: URL
    private let storeRuntime: SQLiteStoreRuntime

    private static func resultReferenceIsValid(
        for outcome: SQLiteReplicationForkDecisionOutcome
    ) -> Bool {
        switch outcome.selection.decision {
        case .keepCurrent:
            outcome.resultReference == nil
        case .acceptRemote:
            outcome.resultReference?.entityType == .taskDefinition
                && outcome.resultReference.flatMap {
                    UUID(uuidString: $0.entityID)
                } != nil
        case .copyAsNew:
            outcome.resultReference?.entityType == .taskChain
                && outcome.resultReference.flatMap {
                    UUID(uuidString: $0.entityID)
                } != nil
        }
    }

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
        storeRuntime = SQLiteStoreRuntime.shared(for: databaseURL)
    }

    func loadOrInstallLocalFirstReplicationControl(
        installedAt: Date
    ) throws -> LocalFirstReplicationControl {
        guard installedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication control installation time is invalid"
            )
        }
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try applySchema(on: database)
        let writeLease = storeRuntime.acquireWriteLease()
        defer { writeLease.release() }
        try execute("BEGIN IMMEDIATE TRANSACTION", on: database)
        do {
            if let stored = try localFirstReplicationControl(from: database) {
                try execute("COMMIT", on: database)
                return stored
            }
            let installed = LocalFirstReplicationControl(
                policy: .enabled,
                generation: 1,
                updatedAt: installedAt
            )
            try saveMetadata(
                SyncMetadataEntry(
                    key: Self.localFirstReplicationControlMetadataKey,
                    value: try ReplicationPublicationBuilder
                        .canonicalEncoder().encode(installed),
                    updatedAt: installedAt
                ),
                into: database
            )
            guard try localFirstReplicationControl(from: database)
                == installed
            else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "replication control was not installed exactly"
                )
            }
            try execute("COMMIT", on: database)
            return installed
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    func transitionLocalFirstReplicationControl(
        expectedGeneration: UInt64,
        policy: LocalFirstReplicationPolicy,
        updatedAt: Date
    ) throws -> LocalFirstReplicationControl {
        guard expectedGeneration > 0,
              expectedGeneration < UInt64.max,
              updatedAt.timeIntervalSinceReferenceDate.isFinite
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication control transition is invalid"
            )
        }
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try applySchema(on: database)
        let writeLease = storeRuntime.acquireWriteLease()
        defer { writeLease.release() }
        try execute("BEGIN IMMEDIATE TRANSACTION", on: database)
        do {
            guard let observed = try localFirstReplicationControl(
                from: database
            ), observed.generation == expectedGeneration else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "replication control generation changed"
                )
            }
            let replacement = LocalFirstReplicationControl(
                policy: policy,
                generation: expectedGeneration + 1,
                updatedAt: updatedAt
            )
            try saveMetadata(
                SyncMetadataEntry(
                    key: Self.localFirstReplicationControlMetadataKey,
                    value: try ReplicationPublicationBuilder
                        .canonicalEncoder().encode(replacement),
                    updatedAt: updatedAt
                ),
                into: database
            )
            guard try localFirstReplicationControl(from: database)
                == replacement
            else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "replication control transition did not commit exactly"
                )
            }
            try execute("COMMIT", on: database)
            return replacement
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    func localFirstReplicationControl() throws -> LocalFirstReplicationControl {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try applySchema(on: database)
        guard let control = try localFirstReplicationControl(from: database)
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication control is missing"
            )
        }
        return control
    }

    public func saveDeviceIdentity(_ identity: SyncDeviceIdentity) throws {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        let sql = """
        INSERT INTO sync_device_identity(id, device_id, display_name, created_at)
        VALUES (1, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            device_id = excluded.device_id,
            display_name = excluded.display_name,
            created_at = excluded.created_at
        """
        try run(sql, on: database) { statement in
            bind(identity.deviceID.rawValue, to: 1, in: statement)
            bind(identity.displayName, to: 2, in: statement)
            bind(identity.createdAt, to: 3, in: statement)
        }
    }

    public func loadDeviceIdentity() throws -> SyncDeviceIdentity? {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        return try query(
            "SELECT device_id, display_name, created_at FROM sync_device_identity WHERE id = 1",
            on: database
        ) { statement in
            SyncDeviceIdentity(
                deviceID: SyncDeviceID(try nonemptyString(statement, 0)),
                displayName: try optionalString(statement, 1),
                createdAt: try date(statement, 2)
            )
        }.first
    }

    public func saveMetadata(_ entry: SyncMetadataEntry) throws {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        try saveMetadata(entry, into: database)
    }

    func saveMetadata(
        _ entry: SyncMetadataEntry,
        expectedReplicationControl: LocalFirstReplicationControl
    ) throws {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try applySchema(on: database)
        let writeLease = storeRuntime.acquireWriteLease()
        defer { writeLease.release() }
        try execute("BEGIN IMMEDIATE TRANSACTION", on: database)
        do {
            try assertLocalFirstReplicationControl(
                expectedReplicationControl,
                in: database
            )
            try saveMetadata(entry, into: database)
            try execute("COMMIT", on: database)
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    public func saveMetadata(_ entries: [SyncMetadataEntry]) throws {
        guard entries.isEmpty == false else { return }
        try validateMetadataBatch(entries)
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        let writeLease = storeRuntime.acquireWriteLease()
        defer { writeLease.release() }
        try execute("BEGIN IMMEDIATE TRANSACTION", on: database)
        do {
            for entry in entries {
                try saveMetadata(entry, into: database)
            }
            try execute("COMMIT", on: database)
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    func saveMetadata(
        _ entries: [SyncMetadataEntry],
        expectedReplicationControl: LocalFirstReplicationControl
    ) throws {
        guard entries.isEmpty == false else { return }
        try validateMetadataBatch(entries)
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try applySchema(on: database)
        let writeLease = storeRuntime.acquireWriteLease()
        defer { writeLease.release() }
        try execute("BEGIN IMMEDIATE TRANSACTION", on: database)
        do {
            try assertLocalFirstReplicationControl(
                expectedReplicationControl,
                in: database
            )
            for entry in entries {
                try saveMetadata(entry, into: database)
            }
            try execute("COMMIT", on: database)
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    public func removeMetadata(for key: String) throws {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        try run(
            "DELETE FROM sync_metadata WHERE key = ?",
            on: database
        ) { statement in
            bind(key, to: 1, in: statement)
        }
    }

    func saveMetadataIfJournalIsFullyUploaded(
        _ entries: [SyncMetadataEntry]
    ) throws -> Bool {
        guard entries.isEmpty == false else { return true }
        try validateMetadataBatch(entries)
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        let writeLease = storeRuntime.acquireWriteLease()
        defer { writeLease.release() }
        try execute("BEGIN IMMEDIATE TRANSACTION", on: database)
        do {
            let unfinishedCount = try query(
                """
                SELECT count(*)
                FROM change_journal
                WHERE sync_state IN (
                    'pendingUpload', 'publishedLocal',
                    'blockedUserAttention', 'blockedCorruption'
                )
                """,
                on: database
            ) { statement in
                Int(sqlite3_column_int64(statement, 0))
            }.first ?? 0
            guard unfinishedCount == 0 else {
                try execute("COMMIT", on: database)
                return false
            }
            for entry in entries {
                try saveMetadata(entry, into: database)
            }
            try execute("COMMIT", on: database)
            return true
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    public func metadata(for key: String) throws -> SyncMetadataEntry? {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        return try query(
            "SELECT key, value, updated_at FROM sync_metadata WHERE key = ?",
            on: database
        ) { statement in
            bind(key, to: 1, in: statement)
        } row: { statement in
            SyncMetadataEntry(
                key: try nonemptyString(statement, 0),
                value: data(statement, 1),
                updatedAt: try date(statement, 2)
            )
        }.first
    }

    /// Returns the installation-local transport epoch. Data-package import
    /// clears sync metadata, so imported facts can never inherit another
    /// installation's producer chain identity.
    public func loadOrCreateTransportProducerEpochID() throws -> UUID {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        let writeLease = storeRuntime.acquireWriteLease()
        defer { writeLease.release() }
        try execute("BEGIN IMMEDIATE TRANSACTION", on: database)
        do {
            let storedValues: [Data] = try query(
                "SELECT value FROM sync_metadata WHERE key = ?",
                on: database
            ) { statement in
                bind(
                    Self.transportProducerEpochMetadataKey,
                    to: 1,
                    in: statement
                )
            } row: { statement in
                data(statement, 0)
            }
            if let stored = storedValues.first {
                guard let value = String(data: stored, encoding: .utf8),
                      let epochID = UUID(uuidString: value),
                      epochID.uuidString.lowercased() == value
                else {
                    throw SQLiteRepositoryError.invalidStoredValue(
                        "transport producer epoch is invalid"
                    )
                }
                try execute("COMMIT", on: database)
                return epochID
            }
            let epochID = UUID()
            try saveMetadata(
                SyncMetadataEntry(
                    key: Self.transportProducerEpochMetadataKey,
                    value: Data(epochID.uuidString.lowercased().utf8)
                ),
                into: database
            )
            try execute("COMMIT", on: database)
            return epochID
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    public func appendJournalEntry(_ entry: SyncJournalEntry) throws {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        let writeLease = storeRuntime.acquireWriteLease()
        defer { writeLease.release() }
        try execute("BEGIN IMMEDIATE TRANSACTION", on: database)
        do {
            try SQLiteJournalCAS.insertOrValidateExact(entry, into: database)
            try execute("COMMIT", on: database)
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    func saveBaselineJournal(
        _ entries: [SyncJournalEntry],
        manifestMetadata: SyncMetadataEntry
    ) throws {
        guard entries.isEmpty == false,
              Set(entries.map(\.id)).count == entries.count
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "sync baseline journal is empty or contains duplicate ids"
            )
        }
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        let writeLease = storeRuntime.acquireWriteLease()
        defer { writeLease.release() }
        try execute("BEGIN IMMEDIATE TRANSACTION", on: database)
        do {
            for entry in entries {
                try SQLiteJournalCAS.insertOrValidateExact(
                    entry,
                    into: database
                )
            }
            try saveMetadata(manifestMetadata, into: database)
            try execute("COMMIT", on: database)
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    public func journalEntries(state: SyncChangeState? = nil, limit: Int? = nil) throws -> [SyncJournalEntry] {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        let entries = try journalEntries(
            state: state,
            from: database
        )
        guard let limit, limit >= 0 else { return entries }
        return Array(entries.prefix(limit))
    }

    private func journalEntries(
        state: SyncChangeState? = nil,
        from database: Database?
    ) throws -> [SyncJournalEntry] {
        let projection = """
        SELECT id, entity_type, entity_id, operation, changed_at, changed_at_bits,
            device_id, sync_state, retry_count, last_error, record_payload,
            transport_receipt
        FROM change_journal
        """
        let entries: [SyncJournalEntry] = if let state {
            try query(
                projection + " WHERE sync_state = ?",
                on: database
            ) { statement in
                bind(state.rawValue, to: 1, in: statement)
            } row: { statement in
                try journalEntry(from: statement)
            }
        } else {
            try query(projection, on: database) { statement in
                try journalEntry(from: statement)
            }
        }
        return entries.sorted(by: journalEntryComesBefore)
    }

    func unsealedReplicationOutboxEntries(
        generationID: UUID
    ) throws -> [SyncJournalEntry] {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try applySchema(on: database)
        let entries = try query(
            """
            SELECT j.id, j.entity_type, j.entity_id, j.operation,
                j.changed_at, j.changed_at_bits, j.device_id, j.sync_state,
                j.retry_count, j.last_error, j.record_payload,
                j.transport_receipt
            FROM sync_replication_outbox o
            JOIN change_journal j ON j.id = o.journal_id
            LEFT JOIN sync_replication_publication_journal p
              ON p.generation_id = o.generation_id
             AND p.journal_id = o.journal_id
            WHERE o.generation_id = ?
              AND o.confirmed_at_bits IS NULL
              AND p.journal_id IS NULL
            """,
            on: database
        ) { statement in
            bind(generationID, to: 1, in: statement)
        } row: { statement in
            try journalEntry(from: statement)
        }
        return entries.sorted(by: journalEntryComesBefore)
    }

    func pendingReplicationOutboxEntryIDs(
        generationID: UUID
    ) throws -> [UUID] {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try applySchema(on: database)
        return try query(
            """
            SELECT journal_id
            FROM sync_replication_outbox
            WHERE generation_id = ? AND confirmed_at_bits IS NULL
            ORDER BY captured_at_bits, journal_id
            """,
            on: database
        ) { statement in
            bind(generationID, to: 1, in: statement)
        } row: { statement in
            guard let value = sqlite3_column_text(statement, 0),
                  let id = UUID(uuidString: String(cString: value))
            else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "replication outbox journal identity is invalid"
                )
            }
            return id
        }
    }

    func unfinishedJournalEntryCount() throws -> Int {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        return try query(
            """
            SELECT COUNT(*)
            FROM change_journal
            WHERE sync_state IN (
                'pendingUpload', 'publishedLocal',
                'blockedUserAttention', 'blockedCorruption'
            )
            """,
            on: database
        ) { statement in
            try int(statement, 0)
        }.first ?? 0
    }

    private func journalEntryComesBefore(
        _ lhs: SyncJournalEntry,
        _ rhs: SyncJournalEntry
    ) -> Bool {
        if lhs.changedAt != rhs.changedAt {
            return lhs.changedAt < rhs.changedAt
        }
        let lhsOrder = lhs.entityType.dependencyOrder
        let rhsOrder = rhs.entityType.dependencyOrder
        if lhsOrder != rhsOrder {
            return lhsOrder < rhsOrder
        }
        if lhs.entityID != rhs.entityID {
            return lhs.entityID < rhs.entityID
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    public func markJournalEntriesUploaded(_ ids: [UUID]) throws {
        try updateJournalEntries(ids) { database, id in
            try run(
                """
                UPDATE change_journal
                SET sync_state = 'uploaded', last_error = NULL
                WHERE id = ?
                """,
                on: database
            ) { statement in
                bind(id, to: 1, in: statement)
            }
        }
    }

    /// Commits one transport-confirmed local publication as a single durable
    /// fact. The journal transition and the local producer frontier must never
    /// be observable independently: the current SQLite snapshot already
    /// contains these records, so a later pull can safely start after their
    /// confirmed immutable batches without downloading its own publication.
    func commitConfirmedUpload(
        _ ids: [UUID],
        receipt: SyncTransportPushReceipt,
        expectedStoredReceipt: Data? = nil,
        frontierNamespace: String,
        confirmedAt: Date = Date()
    ) throws {
        guard ids.isEmpty == false else { return }
        guard Set(ids).count == ids.count,
              frontierNamespace.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty == false
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "confirmed sync upload identity is invalid"
            )
        }
        let canonicalReceipt = try Self.canonicalReceiptData(receipt)
        if let expectedStoredReceipt {
            guard expectedStoredReceipt == canonicalReceipt,
                  receipt.confirmation == .awaitingUploadConfirmation
            else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "confirmed sync receipt does not match durable evidence"
                )
            }
        } else {
            guard receipt.confirmation == .confirmed else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "immediate sync confirmation is invalid"
                )
            }
        }
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        let writeLease = storeRuntime.acquireWriteLease()
        defer { writeLease.release() }
        try execute("BEGIN IMMEDIATE TRANSACTION", on: database)
        do {
            for id in ids {
                if let expectedStoredReceipt {
                    try run(
                        """
                        UPDATE change_journal
                        SET sync_state = 'uploaded', last_error = NULL
                        WHERE id = ? AND sync_state = 'publishedLocal'
                          AND transport_receipt = ?
                        """,
                        on: database
                    ) { statement in
                        bind(id, to: 1, in: statement)
                        bind(expectedStoredReceipt, to: 2, in: statement)
                    }
                } else {
                    try run(
                        """
                        UPDATE change_journal
                        SET sync_state = 'uploaded', last_error = NULL
                        WHERE id = ? AND sync_state = 'pendingUpload'
                          AND transport_receipt IS NULL
                        """,
                        on: database
                    ) { statement in
                        bind(id, to: 1, in: statement)
                    }
                }
                guard sqlite3_changes(database) == 1 else {
                    throw SQLiteRepositoryError.invalidStoredValue(
                        "confirmed sync entry is not uploadable"
                    )
                }
            }
            let key = Self.frontierMetadataKey(
                namespace: frontierNamespace
            )
            let current = try loadFrontier(
                metadataKey: key,
                from: database
            )
            let localProducerID = try storedTransportProducerID(
                from: database
            )
            let advanced = try frontier(
                current,
                advancingPast: receipt.batches,
                localProducerID: localProducerID
            )
            if advanced != current {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                try saveMetadata(
                    SyncMetadataEntry(
                        key: key,
                        value: try encoder.encode(advanced),
                        updatedAt: confirmedAt
                    ),
                    into: database
                )
            }
            try execute("COMMIT", on: database)
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    /// Repairs the exact v0.2.6 durable shape: a pending baseline whose rows
    /// are already uploaded and still retain canonical iCloud receipts, while
    /// the local producer frontier was never committed. Every authorization
    /// fact is revalidated in one SQLite snapshot before the frontier moves.
    func recoverConfirmedBaselineFrontier(
        _ manifest: SQLiteSyncBaselineManifest,
        frontierNamespace: String,
        recoveredAt: Date
    ) throws -> Int {
        guard manifest.state == .pending,
              manifest.transportNamespace == frontierNamespace,
              frontierNamespace.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty == false,
              recoveredAt.timeIntervalSinceReferenceDate.isFinite
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "confirmed baseline recovery identity is invalid"
            )
        }
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        let writeLease = storeRuntime.acquireWriteLease()
        defer { writeLease.release() }
        try execute("BEGIN IMMEDIATE TRANSACTION", on: database)
        do {
            let allEntries = try journalEntries(from: database)
            guard manifest.validate(against: allEntries) else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "confirmed baseline no longer matches its journal evidence"
                )
            }
            let expectedIDs = manifest.expectedJournalEntryIDs
            let expectedEntries = allEntries.filter {
                expectedIDs.contains($0.id)
            }
            guard expectedEntries.count == expectedIDs.count,
                  expectedEntries.allSatisfy({ $0.state == .uploaded })
            else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "confirmed baseline journal state is invalid"
                )
            }
            guard let localProducerID = try storedTransportProducerID(
                from: database
            ) else {
                try execute("COMMIT", on: database)
                return 0
            }

            guard expectedEntries.allSatisfy({
                $0.transportReceipt != nil
            }) else {
                // Older direct-confirmation releases did not retain the
                // receipt. With no complete immutable-batch evidence, keep
                // the origin/previous frontier and let the ordinary pull
                // prove remote state instead of guessing past it.
                try execute("COMMIT", on: database)
                return 0
            }
            var batches: [SyncTransportBatchReference] = []
            var localSequencesByEntry: [UUID: Set<UInt64>] = [:]
            for entry in expectedEntries {
                guard let receiptData = entry.transportReceipt else {
                    throw SQLiteRepositoryError.invalidStoredValue(
                        "confirmed baseline receipt is missing"
                    )
                }
                let receipt = try Self.decodeCanonicalReceipt(receiptData)
                guard receipt.confirmation == .awaitingUploadConfirmation else {
                    throw SQLiteRepositoryError.invalidStoredValue(
                        "confirmed baseline receipt state is invalid"
                    )
                }
                batches.append(contentsOf: receipt.batches)
                localSequencesByEntry[entry.id] = Set(
                    receipt.batches.compactMap {
                        $0.producerID == localProducerID
                            ? $0.sequence
                            : nil
                    }
                )
            }
            let key = Self.frontierMetadataKey(
                namespace: frontierNamespace
            )
            let current = try loadFrontier(
                metadataKey: key,
                from: database
            )
            let advanced = try frontier(
                current,
                advancingPast: batches,
                localProducerID: localProducerID
            )
            guard advanced != current,
                  let advancedPosition = advanced.position(
                      for: localProducerID
                  )
            else {
                try execute("COMMIT", on: database)
                return 0
            }
            let previousSequence = current.position(
                for: localProducerID
            )?.sequence ?? 0
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try saveMetadata(
                SyncMetadataEntry(
                    key: key,
                    value: try encoder.encode(advanced),
                    updatedAt: recoveredAt
                ),
                into: database
            )
            let recoveredEntryCount = localSequencesByEntry.values.filter {
                $0.contains(where: {
                    $0 > previousSequence
                        && $0 <= advancedPosition.sequence
                })
            }.count
            try execute("COMMIT", on: database)
            return recoveredEntryCount
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    public func markJournalEntriesPublishedLocal(
        _ ids: [UUID],
        receipt: Data
    ) throws {
        guard receipt.isEmpty == false else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "published sync receipt is empty"
            )
        }
        try updateJournalEntries(ids) { database, id in
            try run(
                """
                UPDATE change_journal
                SET sync_state = 'publishedLocal',
                    transport_receipt = ?, last_error = NULL
                WHERE id = ? AND sync_state = 'pendingUpload'
                """,
                on: database
            ) { statement in
                bind(receipt, to: 1, in: statement)
                bind(id, to: 2, in: statement)
            }
            guard sqlite3_changes(database) == 1 else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "sync outbox entry cannot enter publishedLocal"
                )
            }
        }
    }

    static func frontierMetadataKey(namespace: String) -> String {
        "generic.download.frontier.\(namespace)"
    }

    private func loadFrontier(
        metadataKey: String,
        from database: Database?
    ) throws -> SyncTransportFrontier {
        let values: [Data] = try query(
            "SELECT value FROM sync_metadata WHERE key = ?",
            on: database
        ) { statement in
            bind(metadataKey, to: 1, in: statement)
        } row: { statement in
            data(statement, 0)
        }
        guard let value = values.first else { return .origin }
        do {
            return try JSONDecoder().decode(
                SyncTransportFrontier.self,
                from: value
            )
        } catch {
            throw SQLiteRepositoryError.invalidStoredValue(
                "sync transport frontier is invalid"
            )
        }
    }

    private func frontier(
        _ current: SyncTransportFrontier,
        advancingPast batches: [SyncTransportBatchReference],
        localProducerID: String?
    ) throws -> SyncTransportFrontier {
        guard let localProducerID else { return current }
        let localBatches = batches.filter {
            $0.producerID == localProducerID
        }
        guard localBatches.isEmpty == false else { return current }
        let hashBySequence = try confirmedBatchHashes(
            localBatches,
            localProducerID: localProducerID
        )
        let existing = current.position(for: localProducerID)
        try validate(
            existingLocalPosition: existing,
            against: hashBySequence
        )
        guard existing?.sequence != UInt64.max else { return current }

        let nextSequence = (existing?.sequence ?? 0) + 1
        let advancingSequences = hashBySequence.keys
            .filter { $0 >= nextSequence }
            .sorted()
        guard advancingSequences.isEmpty == false else { return current }
        try validateContiguous(
            advancingSequences,
            startingAt: nextSequence
        )

        var advanced = current
        for sequence in advancingSequences {
            guard let contentHash = hashBySequence[sequence] else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "confirmed sync batch evidence disappeared"
                )
            }
            advanced = advanced.advancing(
                producerID: localProducerID,
                to: SyncTransportPosition(
                    sequence: sequence,
                    contentHash: contentHash
                )
            )
        }
        return advanced
    }

    private func confirmedBatchHashes(
        _ localBatches: [SyncTransportBatchReference],
        localProducerID: String
    ) throws -> [UInt64: String] {
        var hashBySequence: [UInt64: String] = [:]
        for batch in localBatches {
            guard batch.producerID == localProducerID,
                  batch.sequence > 0,
                  Self.isSHA256Hex(batch.contentHash)
            else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "confirmed sync batch reference is invalid"
                )
            }
            if let existing = hashBySequence[batch.sequence] {
                guard existing == batch.contentHash else {
                    throw SQLiteRepositoryError.invalidStoredValue(
                        "confirmed sync batch sequence has conflicting hashes"
                    )
                }
            } else {
                hashBySequence[batch.sequence] = batch.contentHash
            }
        }
        return hashBySequence
    }

    private func validate(
        existingLocalPosition: SyncTransportPosition?,
        against hashBySequence: [UInt64: String]
    ) throws {
        guard let existingLocalPosition else { return }
        guard existingLocalPosition.sequence > 0,
              Self.isSHA256Hex(existingLocalPosition.contentHash)
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "durable local sync frontier is invalid"
            )
        }
        if let repeatedHash = hashBySequence[
            existingLocalPosition.sequence
        ] {
            guard repeatedHash == existingLocalPosition.contentHash else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "confirmed sync batch conflicts with the durable frontier"
                )
            }
        }
    }

    private func validateContiguous(
        _ sequences: [UInt64],
        startingAt firstExpectedSequence: UInt64
    ) throws {
        var expectedSequence = firstExpectedSequence
        for sequence in sequences {
            guard sequence == expectedSequence else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "confirmed sync batch sequence is not contiguous"
                )
            }
            if expectedSequence < UInt64.max {
                expectedSequence += 1
            } else {
                break
            }
        }
    }

    private static func canonicalReceiptData(
        _ receipt: SyncTransportPushReceipt
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(receipt)
    }

    private static func decodeCanonicalReceipt(
        _ data: Data
    ) throws -> SyncTransportPushReceipt {
        let receipt: SyncTransportPushReceipt
        do {
            receipt = try JSONDecoder().decode(
                SyncTransportPushReceipt.self,
                from: data
            )
        } catch {
            throw SQLiteRepositoryError.invalidStoredValue(
                "sync transport receipt is invalid"
            )
        }
        guard try canonicalReceiptData(receipt) == data else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "sync transport receipt is not canonical"
            )
        }
        return receipt
    }

    private func storedTransportProducerID(
        from database: Database?
    ) throws -> String? {
        let values: [Data] = try query(
            "SELECT value FROM sync_metadata WHERE key = ?",
            on: database
        ) { statement in
            bind(Self.transportProducerEpochMetadataKey, to: 1, in: statement)
        } row: { statement in
            data(statement, 0)
        }
        guard let value = values.first else { return nil }
        guard let producerID = String(data: value, encoding: .utf8),
              let uuid = UUID(uuidString: producerID),
              uuid.uuidString.lowercased() == producerID
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "transport producer epoch is invalid"
            )
        }
        return producerID
    }

    private static func isSHA256Hex(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
        }
    }

    public func markJournalEntriesBlockedUserAttention(
        _ ids: [UUID],
        error: String
    ) throws {
        try updateJournalEntries(ids) { database, id in
            try run(
                """
                UPDATE change_journal
                SET sync_state = 'blockedUserAttention',
                    retry_count = retry_count + 1,
                    last_error = ?
                WHERE id = ?
                  AND sync_state IN ('pendingUpload', 'publishedLocal')
                """,
                on: database
            ) { statement in
                bind(error, to: 1, in: statement)
                bind(id, to: 2, in: statement)
            }
            guard sqlite3_changes(database) == 1 else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "sync outbox entry cannot enter blockedUserAttention"
                )
            }
        }
    }

    /// A user-triggered retry is the explicit acknowledgement that an
    /// account, Drive, or permission problem may have been repaired. Automatic
    /// timers must not call this method and spin on the same blocked evidence.
    public func requeueJournalEntriesBlockedForUserAttention() throws {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        try run(
            """
            UPDATE change_journal
            SET sync_state = 'pendingUpload', last_error = NULL,
                transport_receipt = NULL
            WHERE sync_state = 'blockedUserAttention'
            """,
            on: database
        ) { _ in }
    }

    func requeueJournalEntriesForBaselineRecovery(
        _ ids: Set<UUID>
    ) throws {
        let orderedIDs = ids.sorted {
            $0.uuidString < $1.uuidString
        }
        try updateJournalEntries(orderedIDs) { database, id in
            try run(
                """
                UPDATE change_journal
                SET sync_state = 'pendingUpload', last_error = NULL,
                    transport_receipt = NULL
                WHERE id = ?
                """,
                on: database
            ) { statement in
                bind(id, to: 1, in: statement)
            }
            guard sqlite3_changes(database) == 1 else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "sync baseline journal entry is missing"
                )
            }
        }
    }

    public func markJournalEntryBlockedCorruption(
        _ id: UUID,
        error: String
    ) throws {
        try updateJournalEntries([id]) { database, id in
            try run(
                """
                UPDATE change_journal
                SET sync_state = 'blockedCorruption',
                    retry_count = retry_count + 1,
                    last_error = ?, transport_receipt = NULL
                WHERE id = ?
                """,
                on: database
            ) { statement in
                bind(error, to: 1, in: statement)
                bind(id, to: 2, in: statement)
            }
        }
    }

    func requeueJournalEntriesBlockedCorruption(
        _ ids: [UUID]
    ) throws {
        try updateJournalEntries(ids) { database, id in
            try run(
                """
                UPDATE change_journal
                SET sync_state = 'pendingUpload', last_error = NULL,
                    transport_receipt = NULL
                WHERE id = ?
                  AND sync_state = 'blockedCorruption'
                """,
                on: database
            ) { statement in
                bind(id, to: 1, in: statement)
            }
            guard sqlite3_changes(database) == 1 else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "sync corruption block cannot be requeued"
                )
            }
        }
    }

    public func pendingDownloads() throws -> [SyncPendingDownloadRecord] {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        try execute("BEGIN DEFERRED TRANSACTION", on: database)
        do {
            let pending = try pendingDownloads(from: database)
            try execute("COMMIT", on: database)
            return pending
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    func reconcilePendingDownloads(
        waiting: [SyncWaitingRecord],
        terminal: [SyncPendingDownloadRecord],
        attemptedAt: Date
    ) throws {
        try validatePendingDownloadReconciliation(
            waiting: waiting,
            terminal: terminal,
            attemptedAt: attemptedAt
        )

        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        let writeLease = storeRuntime.acquireWriteLease()
        defer { writeLease.release() }
        try execute("BEGIN IMMEDIATE TRANSACTION", on: database)
        do {
            try reconcilePendingDownloads(
                waiting: waiting,
                terminal: terminal,
                observedPending: nil,
                attemptedAt: attemptedAt,
                into: database
            )
            try execute("COMMIT", on: database)
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    func commitDownloadedMerge(_ commit: SQLiteSyncDownloadCommit) throws -> Int {
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        try engineRepository.validateSnapshotForPersistence(commit.snapshot)
        try validatePendingDownloadReconciliation(
            waiting: commit.waiting,
            terminal: commit.terminal,
            attemptedAt: commit.attemptedAt
        )
        try validateObservedPendingTokens(commit.observedPending)
        let preparedConflicts: [(conflict: SyncConflict, remotePayload: Data)] = try commit.conflicts.map {
            ($0, try validatedConflictRemotePayload($0))
        }

        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        let writeLease = storeRuntime.acquireWriteLease()
        defer { writeLease.release() }
        try execute("BEGIN IMMEDIATE TRANSACTION", on: database)
        do {
            if let expected = commit.expectedReplicationControl {
                try assertLocalFirstReplicationControl(
                    expected,
                    in: database
                )
            }
            if let decisionCommit = commit.forkConflictDecisionCommit {
                guard commit.forkResolutionTransition?.resolutionID
                    == decisionCommit.resolutionID,
                    commit.forkResolutionTransition?.expectedState
                    == .branchesValidated,
                    commit.forkResolutionTransition?.newState == .closed,
                    decisionCommit.observedEngineGeneration
                    == commit.observedEngineGeneration,
                    Set(decisionCommit.outcomes.map {
                        $0.selection.conflictID
                    }).count == decisionCommit.outcomes.count,
                    decisionCommit.outcomes.allSatisfy({
                        Self.resultReferenceIsValid(for: $0)
                    }),
                    let conflictSet = try replicationForkConflictSet(
                        resolutionID: decisionCommit.resolutionID,
                        generation: decisionCommit
                            .observedEngineGeneration,
                        from: database
                    ),
                    conflictSet.conflicts.allSatisfy({
                        $0.decision == nil && $0.decidedAt == nil
                    }),
                    Set(conflictSet.conflicts.map(\.conflict.id))
                    == Set(
                        decisionCommit.outcomes.map {
                            $0.selection.conflictID
                        }
                    )
                else {
                    throw SQLiteRepositoryError.invalidStoredValue(
                        "fork conflict decision lost its exact persistence fence"
                    )
                }
                let conflictByID = Dictionary(
                    uniqueKeysWithValues: conflictSet.conflicts.map {
                        ($0.conflict.id, $0.conflict)
                    }
                )
                guard decisionCommit.outcomes.allSatisfy({ outcome in
                    conflictByID[outcome.selection.conflictID]
                        .map {
                            ReplicationForkConflictDecision.allowedDecisions(
                                for: $0
                            ).contains(outcome.selection.decision)
                        } ?? false
                }) else {
                    throw SQLiteRepositoryError.invalidStoredValue(
                        "fork conflict decision is not executable for its evidence"
                    )
                }
            }
            try engineRepository.compareAndAdvanceEngineSnapshotGeneration(
                observed: commit.observedEngineGeneration,
                in: database
            )
            try engineRepository.persistValidatedSnapshot(
                commit.snapshot,
                changedFrom: commit.sourceSnapshot,
                into: database
            )
            for prepared in preparedConflicts {
                try saveConflict(
                    prepared.conflict,
                    remotePayload: prepared.remotePayload,
                    into: database
                )
                if let terminal = SyncTerminalRejection(conflict: prepared.conflict) {
                    try saveTerminalRejection(terminal, into: database)
                }
            }
            try reconcilePendingDownloads(
                waiting: commit.waiting,
                terminal: commit.terminal,
                observedPending: commit.observedPending,
                attemptedAt: commit.attemptedAt,
                into: database
            )
            for entry in commit.auditEntries {
                try appendAuditLog(entry, into: database)
            }
            try saveMetadata(commit.metadata, into: database)
            if let frontierMetadata = commit.frontierMetadata {
                try saveMetadata(frontierMetadata, into: database)
            }
            if let decisionCommit = commit.forkConflictDecisionCommit {
                for outcome in decisionCommit.outcomes {
                    let selection = outcome.selection
                    try run(
                        """
                        UPDATE sync_replication_fork_conflicts
                        SET decision = ?, decided_at_bits = ?,
                            result_entity_type = ?, result_entity_id = ?
                        WHERE resolution_id = ? AND engine_epoch = ?
                          AND engine_revision = ? AND conflict_id = ?
                          AND decision = 'unresolved'
                          AND decided_at_bits IS NULL
                        """,
                        on: database
                    ) { statement in
                        bind(selection.decision.rawValue, to: 1, in: statement)
                        bindExactDate(commit.attemptedAt, to: 2, in: statement)
                        bind(
                            outcome.resultReference?.entityType.rawValue,
                            to: 3,
                            in: statement
                        )
                        bind(
                            outcome.resultReference?.entityID,
                            to: 4,
                            in: statement
                        )
                        bind(
                            decisionCommit.resolutionID.rawValue,
                            to: 5,
                            in: statement
                        )
                        bind(
                            decisionCommit.observedEngineGeneration.epoch
                                .uuidString.lowercased(),
                            to: 6,
                            in: statement
                        )
                        guard let revision = Int64(
                            exactly: decisionCommit
                                .observedEngineGeneration.revision
                        ) else {
                            throw SQLiteRepositoryError.invalidStoredValue(
                                "fork conflict decision revision is invalid"
                            )
                        }
                        bind(revision, to: 7, in: statement)
                        bind(selection.conflictID, to: 8, in: statement)
                    }
                    guard sqlite3_changes(database) == 1 else {
                        throw SQLiteRepositoryError.invalidStoredValue(
                            "fork conflict decision did not update exact evidence"
                        )
                    }
                }
            }
            if let transition = commit.forkResolutionTransition {
                try run(
                    """
                    UPDATE sync_replication_fork_resolutions
                    SET state = ?, updated_at_bits = ?
                    WHERE resolution_id = ? AND state = ?
                    """,
                    on: database
                ) { statement in
                    bind(transition.newState.rawValue, to: 1, in: statement)
                    bindExactDate(commit.attemptedAt, to: 2, in: statement)
                    bind(transition.resolutionID.rawValue, to: 3, in: statement)
                    bind(
                        transition.expectedState.rawValue,
                        to: 4,
                        in: statement
                    )
                }
                guard sqlite3_changes(database) == 1 else {
                    throw SQLiteRepositoryError.invalidStoredValue(
                        "fork resolution changed before merge commit"
                    )
                }
            }
            let durableWaitingCount = try pendingDownloads(from: database).count
            try execute("COMMIT", on: database)
            return durableWaitingCount
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    public func saveConflict(_ conflict: SyncConflict) throws {
        let remotePayload = try validatedConflictRemotePayload(conflict)
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        let writeLease = storeRuntime.acquireWriteLease()
        defer { writeLease.release() }
        try execute("BEGIN IMMEDIATE TRANSACTION", on: database)
        do {
            try saveConflict(conflict, remotePayload: remotePayload, into: database)
            if let terminal = SyncTerminalRejection(conflict: conflict) {
                try saveTerminalRejection(terminal, into: database)
            }
            try execute("COMMIT", on: database)
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    public func unresolvedConflicts() throws -> [SyncConflict] {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        return try query(
            """
            SELECT id, conflict_type, entity_type, entity_id, local_record_id,
                remote_record_id, remote_payload, detected_at, resolution, message
            FROM sync_conflicts
            WHERE resolution = 'unresolved'
            ORDER BY detected_at, id
            """,
            on: database,
            row: conflict(from:)
        )
    }

    func recordReplicationForkConflictSet(
        resolutionID: ReplicationDigest,
        conflicts: [SyncConflict],
        observedEngineGeneration: SQLiteEngineSnapshotGeneration,
        recordedAt: Date,
        expectedReplicationControl: LocalFirstReplicationControl? = nil
    ) throws -> SQLiteReplicationForkConflictSet {
        guard conflicts.isEmpty == false,
              recordedAt.timeIntervalSinceReferenceDate.isFinite,
              let engineRevision = Int64(
                  exactly: observedEngineGeneration.revision
              ),
              Set(conflicts.map(\.id)).count == conflicts.count,
              conflicts.allSatisfy({
                  $0.id == $0.canonicalEvidenceID
                      && $0.resolution == .unresolved
              })
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication fork conflict set is invalid"
            )
        }
        let ordered = conflicts.sorted {
            $0.id.uuidString < $1.id.uuidString
        }
        let prepared = try ordered.map {
            ($0, try validatedConflictRemotePayload($0))
        }
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        let writeLease = storeRuntime.acquireWriteLease()
        defer { writeLease.release() }
        try execute("BEGIN IMMEDIATE TRANSACTION", on: database)
        do {
            if let expectedReplicationControl {
                try assertLocalFirstReplicationControl(
                    expectedReplicationControl,
                    in: database
                )
            }
            let resolutionState: [String] = try query(
                """
                SELECT state
                FROM sync_replication_fork_resolutions
                WHERE resolution_id = ?
                """,
                on: database
            ) { statement in
                bind(resolutionID.rawValue, to: 1, in: statement)
            } row: { statement in
                try string(statement, 0)
            }
            guard resolutionState == [
                ReplicationForkResolutionState.branchesValidated.rawValue
            ] else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "replication fork conflict set lacks validated evidence"
                )
            }
            let generationMatches: [Int] = try query(
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
                bind(engineRevision, to: 2, in: statement)
            } row: { _ in 1 }
            guard generationMatches == [1] else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "engine snapshot generation changed before fork conflict persistence"
                )
            }
            if let existing = try replicationForkConflictSet(
                resolutionID: resolutionID,
                generation: observedEngineGeneration,
                from: database
            ) {
                guard existing.conflicts.map(\.conflict.id)
                    == ordered.map(\.id)
                else {
                    throw SQLiteRepositoryError.invalidStoredValue(
                        "replication fork conflict set changed within one engine generation"
                    )
                }
                try execute("COMMIT", on: database)
                return existing
            }
            for (conflict, remotePayload) in prepared {
                try saveConflict(
                    conflict,
                    remotePayload: remotePayload,
                    into: database
                )
                try run(
                    """
                    INSERT INTO sync_replication_fork_conflicts(
                        resolution_id, conflict_id, engine_epoch,
                        engine_revision, decision, decided_at_bits,
                        recorded_at_bits
                    ) VALUES (?, ?, ?, ?, 'unresolved', NULL, ?)
                    """,
                    on: database
                ) { statement in
                    bind(resolutionID.rawValue, to: 1, in: statement)
                    bind(conflict.id, to: 2, in: statement)
                    bind(
                        observedEngineGeneration.epoch.uuidString
                            .lowercased(),
                        to: 3,
                        in: statement
                    )
                    bind(engineRevision, to: 4, in: statement)
                    bindExactDate(recordedAt, to: 5, in: statement)
                }
            }
            guard let stored = try replicationForkConflictSet(
                resolutionID: resolutionID,
                generation: observedEngineGeneration,
                from: database
            ), stored.conflicts.map(\.conflict.id) == ordered.map(\.id) else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "replication fork conflict set was not stored exactly"
                )
            }
            try execute("COMMIT", on: database)
            return stored
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    public func replicationForkConflictSet(
        resolutionID: ReplicationDigest
    ) throws -> SQLiteReplicationForkConflictSet? {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try applySchema(on: database)
        guard let generation = try latestReplicationForkConflictGeneration(
            resolutionID: resolutionID,
            from: database
        ) else { return nil }
        return try replicationForkConflictSet(
            resolutionID: resolutionID,
            generation: generation,
            from: database
        )
    }

    public func latestReplicationForkConflictSet(
        generationID: UUID
    ) throws -> SQLiteReplicationForkConflictSet? {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try applySchema(on: database)
        let resolutionIDs: [ReplicationDigest] = try query(
            """
            SELECT DISTINCT r.resolution_id
            FROM sync_replication_fork_resolutions r
            JOIN sync_replication_fork_conflicts c
              ON c.resolution_id = r.resolution_id
            WHERE r.generation_id = ? AND r.state = 'branchesValidated'
              AND c.decision = 'unresolved'
            ORDER BY r.detected_at_bits DESC, r.resolution_id DESC
            LIMIT 1
            """,
            on: database
        ) { statement in
            bind(generationID, to: 1, in: statement)
        } row: { statement in
            try replicationDigest(statement, 0)
        }
        guard let resolutionID = resolutionIDs.first,
              let generation = try latestReplicationForkConflictGeneration(
                  resolutionID: resolutionID,
                  from: database
              )
        else { return nil }
        return try replicationForkConflictSet(
            resolutionID: resolutionID,
            generation: generation,
            from: database
        )
    }

    public func terminalRejections() throws -> [SyncTerminalRejection] {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        try execute("BEGIN DEFERRED TRANSACTION", on: database)
        do {
            let rejections = try terminalRejections(from: database)
            try execute("COMMIT", on: database)
            return rejections
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    /// Every exact conflict variant for an immutable identity which has reached
    /// terminal state. The one-row terminal ledger remains the deterministic
    /// anchor, while this evidence set preserves all provider facts needed to
    /// terminate descendants after a restart.
    public func terminalRejectionEvidence() throws -> [SyncTerminalRejection] {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        try execute("BEGIN DEFERRED TRANSACTION", on: database)
        do {
            let rejections = try terminalRejectionEvidence(from: database)
            try execute("COMMIT", on: database)
            return rejections
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    public func resolveConflict(id: UUID, resolution: SyncConflictResolution, resolvedAt: Date = Date()) throws {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        try run(
            "UPDATE sync_conflicts SET resolution = ?, resolved_at = ? WHERE id = ?",
            on: database
        ) { statement in
            bind(resolution.rawValue, to: 1, in: statement)
            bind(resolvedAt, to: 2, in: statement)
            bind(id, to: 3, in: statement)
        }
    }

    public func appendAuditLog(_ entry: SyncAuditLogEntry) throws {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        try appendAuditLog(entry, into: database)
    }

    public func auditLog(limit: Int = 100) throws -> [SyncAuditLogEntry] {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        return try query(
            """
            SELECT id, direction, entity_type, entity_id,
                source_evidence_id, canonical_evidence_id,
                action, created_at, message
            FROM sync_audit_log
            ORDER BY created_at DESC, id
            LIMIT ?
            """,
            on: database
        ) { statement in
            bind(limit, to: 1, in: statement)
        } row: { statement in
            try auditEntry(from: statement)
        }
    }

    func assertLocalFirstReplicationControl(
        _ expected: LocalFirstReplicationControl,
        in database: OpaquePointer?
    ) throws {
        guard try localFirstReplicationControl(from: database) == expected else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication control generation fence changed"
            )
        }
    }
}

private extension SQLiteSyncRepository {
    typealias Database = OpaquePointer
    typealias Statement = OpaquePointer

    struct PendingDependencyRow {
        let recordID: SyncRecordID
        let dependency: SyncRecordDependency
    }

    static func string(from date: Date) -> String {
        SQLiteISO8601DateCodec.string(from: date)
    }

    static func date(from string: String) -> Date? {
        SQLiteISO8601DateCodec.date(from: string)
    }

    func openDatabase() throws -> Database? {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var database: Database?
        let openResult = sqlite3_open(databaseURL.path, &database)
        guard openResult == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite open error"
            let sqliteCode = sqliteDiagnosticCode(database) ?? openResult
            sqlite3_close(database)
            throw SQLiteRepositoryError.openFailed(
                message,
                sqliteCode: sqliteCode
            )
        }
        return database
    }

    func applySchema(on database: Database?) throws {
        try storeRuntime.prepare(database)
    }

    func validatePendingDownloadReconciliation(
        waiting: [SyncWaitingRecord],
        terminal: [SyncPendingDownloadRecord],
        attemptedAt: Date
    ) throws {
        let waitingIDs = waiting.map(\.remoteRecordID)
        let terminalIDs = terminal.map(\.record.id)
        guard Set(waitingIDs).count == waitingIDs.count else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "pending download reconciliation contains duplicate record IDs"
            )
        }
        guard Set(terminalIDs).count == terminalIDs.count else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "pending download reconciliation contains duplicate terminal tokens"
            )
        }
        guard Set(terminalIDs).isDisjoint(with: waitingIDs) else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "a pending download cannot be waiting and terminal"
            )
        }
        guard waiting.allSatisfy({ waitingRecordIsCurrent($0) }) else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "only valid current sync records can wait for download dependencies"
            )
        }
        guard waiting.allSatisfy({ $0.dependencies.isEmpty == false }) else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "a pending download must declare at least one dependency"
            )
        }
        guard dateIsFinite(attemptedAt),
              waiting.allSatisfy({ dateIsFinite($0.record.modifiedAt) }),
              terminal.allSatisfy(pendingDownloadTokenIsValid)
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "pending download reconciliation contains invalid exact dates or terminal tokens"
            )
        }
    }

    func reconcilePendingDownloads(
        waiting: [SyncWaitingRecord],
        terminal: [SyncPendingDownloadRecord],
        observedPending: [SyncPendingDownloadRecord]?,
        attemptedAt: Date,
        into database: Database?
    ) throws {
        let storedByID = Dictionary(
            uniqueKeysWithValues: try pendingDownloads(from: database).map {
                ($0.record.id, $0)
            }
        )
        let observedByID = observedPending.map {
            Dictionary(uniqueKeysWithValues: $0.map {
                ($0.record.id, $0)
            })
        }
        if let observedByID {
            let reconciledIDs = Set(waiting.map(\.remoteRecordID)).union(
                terminal.map(\.record.id)
            )
            for (recordID, observed) in observedByID
            where reconciledIDs.contains(recordID) == false {
                guard let stored = storedByID[recordID],
                      pendingDownloadTokensMatch(stored, observed)
                else {
                    throw SQLiteRepositoryError.invalidStoredValue(
                        "retained pending download changed after the merge snapshot was read"
                    )
                }
            }
        }
        for pending in waiting {
            if let observedByID {
                let stored = storedByID[pending.record.id]
                if let observed = observedByID[pending.record.id] {
                    guard let stored,
                          pendingDownloadTokensMatch(stored, observed)
                    else {
                        throw SQLiteRepositoryError.invalidStoredValue(
                            "pending download changed after the merge snapshot was read"
                        )
                    }
                } else if stored != nil {
                    throw SQLiteRepositoryError.invalidStoredValue(
                        "pending download was inserted after the merge snapshot was read"
                    )
                }
            }
            try upsertPendingDownload(
                pending,
                stored: storedByID[pending.record.id],
                attemptedAt: attemptedAt,
                into: database
            )
        }
        for observed in terminal.sorted(by: {
            $0.record.id.rawValue < $1.record.id.rawValue
        }) {
            guard let stored = storedByID[observed.record.id],
                  pendingDownloadTokensMatch(stored, observed)
            else {
                continue
            }
            try run(
                "DELETE FROM sync_pending_download_records WHERE record_id = ?",
                on: database
            ) { statement in
                bind(observed.record.id.rawValue, to: 1, in: statement)
            }
        }
    }

    func validateObservedPendingTokens(
        _ observed: [SyncPendingDownloadRecord]
    ) throws {
        guard Set(observed.map(\.record.id)).count == observed.count,
              observed.allSatisfy(pendingDownloadTokenIsValid)
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "observed pending download tokens are invalid or duplicated"
            )
        }
    }

    func validatedConflictRemotePayload(_ conflict: SyncConflict) throws -> Data {
        guard conflict.remoteRecord.entityType == conflict.entityType,
              conflict.remoteRecord.entityID == conflict.entityID,
              conflict.id == conflict.canonicalEvidenceID
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "sync conflict canonical evidence identity mismatch"
            )
        }
        return try canonicalConflictRecordData(conflict.remoteRecord)
    }

    func saveConflict(
        _ conflict: SyncConflict,
        remotePayload: Data,
        into database: Database?
    ) throws {
        try run(
            """
            INSERT INTO sync_conflicts(
                id, conflict_type, entity_type, entity_id, local_record_id, remote_record_id,
                local_payload, remote_payload, detected_at, resolved_at, resolution, message
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO NOTHING
            """,
            on: database
        ) { statement in
            bind(conflict.id, to: 1, in: statement)
            bind(conflict.type.rawValue, to: 2, in: statement)
            bind(conflict.entityType.rawValue, to: 3, in: statement)
            bind(conflict.entityID, to: 4, in: statement)
            bind(conflict.localRecordID?.rawValue, to: 5, in: statement)
            bind(conflict.remoteRecordID.rawValue, to: 6, in: statement)
            bind(nil as Data?, to: 7, in: statement)
            bind(remotePayload, to: 8, in: statement)
            bind(conflict.detectedAt, to: 9, in: statement)
            bind(nil as Date?, to: 10, in: statement)
            bind(conflict.resolution.rawValue, to: 11, in: statement)
            bind(conflict.message, to: 12, in: statement)
        }
        guard let stored = try storedConflict(id: conflict.id, from: database),
              stored.type == conflict.type,
              stored.entityType == conflict.entityType,
              stored.entityID == conflict.entityID,
              stored.localRecordID == conflict.localRecordID,
              stored.remoteRecordID == conflict.remoteRecordID,
              stored.remoteRecord.exactlyMatches(conflict.remoteRecord)
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "sync conflict identity collided with different canonical evidence"
            )
        }
    }

    func saveTerminalRejection(
        _ rejection: SyncTerminalRejection,
        into database: Database?
    ) throws {
        guard rejection.conflict.id == rejection.conflict.canonicalEvidenceID,
              rejection.identity.entityType == rejection.conflict.entityType,
              rejection.identity.entityID == rejection.conflict.entityID
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "terminal rejection identity does not match its conflict evidence"
            )
        }
        try run(
            """
            INSERT INTO sync_terminal_rejections(entity_type, entity_id, conflict_id)
            VALUES (?, ?, ?)
            ON CONFLICT(entity_type, entity_id) DO UPDATE SET
                conflict_id = CASE
                    WHEN excluded.conflict_id < sync_terminal_rejections.conflict_id
                        THEN excluded.conflict_id
                    ELSE sync_terminal_rejections.conflict_id
                END
            """,
            on: database
        ) { statement in
            bind(rejection.identity.entityType.rawValue, to: 1, in: statement)
            bind(rejection.identity.entityID, to: 2, in: statement)
            bind(rejection.conflict.id, to: 3, in: statement)
        }
        let storedConflictIDs = try query(
            """
            SELECT conflict_id
            FROM sync_terminal_rejections
            WHERE entity_type = ? AND entity_id = ?
            """,
            on: database
        ) { statement in
            bind(rejection.identity.entityType.rawValue, to: 1, in: statement)
            bind(rejection.identity.entityID, to: 2, in: statement)
        } row: { statement in
            try uuid(statement, 0)
        }
        guard storedConflictIDs.count == 1,
              let storedConflictID = storedConflictIDs.first,
              let storedConflict = try storedConflict(
                  id: storedConflictID,
                  from: database
              ),
              let storedRejection = SyncTerminalRejection(
                  conflict: storedConflict
              ),
              storedRejection.identity == rejection.identity,
              storedConflictID.uuidString <= rejection.conflict.id.uuidString
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "terminal immutable record identity has no deterministic evidence anchor"
            )
        }
    }

    func appendAuditLog(_ entry: SyncAuditLogEntry, into database: Database?) throws {
        try run(
            """
            INSERT INTO sync_audit_log(
                id, direction, entity_type, entity_id,
                source_evidence_id, canonical_evidence_id,
                action, created_at, message
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            on: database
        ) { statement in
            bind(entry.id, to: 1, in: statement)
            bind(entry.direction.rawValue, to: 2, in: statement)
            bind(entry.entityType.rawValue, to: 3, in: statement)
            bind(entry.entityID, to: 4, in: statement)
            bind(entry.sourceEvidenceID?.rawValue, to: 5, in: statement)
            bind(entry.canonicalEvidenceID?.rawValue, to: 6, in: statement)
            bind(entry.action, to: 7, in: statement)
            bind(entry.createdAt, to: 8, in: statement)
            bind(entry.message, to: 9, in: statement)
        }
    }

    private func validateMetadataBatch(
        _ entries: [SyncMetadataEntry]
    ) throws {
        guard Set(entries.map(\.key)).count == entries.count else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "sync metadata batch contains duplicate keys"
            )
        }
    }

    func saveMetadata(_ entry: SyncMetadataEntry, into database: Database?) throws {
        try run(
            """
            INSERT INTO sync_metadata(key, value, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
                value = excluded.value,
                updated_at = excluded.updated_at
            """,
            on: database
        ) { statement in
            bind(entry.key, to: 1, in: statement)
            bind(entry.value, to: 2, in: statement)
            bind(entry.updatedAt, to: 3, in: statement)
        }
    }

    func localFirstReplicationControl(
        from database: Database?
    ) throws -> LocalFirstReplicationControl? {
        let values: [Data] = try query(
            "SELECT value FROM sync_metadata WHERE key = ?",
            on: database
        ) { statement in
            bind(Self.localFirstReplicationControlMetadataKey, to: 1, in: statement)
        } row: { statement in
            data(statement, 0)
        }
        guard let value = values.first else { return nil }
        let control: LocalFirstReplicationControl
        do {
            control = try ReplicationPublicationBuilder.canonicalDecoder()
                .decode(LocalFirstReplicationControl.self, from: value)
        } catch {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication control is invalid"
            )
        }
        guard control.generation > 0,
              control.updatedAt.timeIntervalSinceReferenceDate.isFinite,
              try ReplicationPublicationBuilder.canonicalEncoder()
              .encode(control) == value
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication control is not canonical"
            )
        }
        return control
    }

    func pendingDownloads(from database: Database?) throws -> [SyncPendingDownloadRecord] {
        let dependencyRows = try query(
            """
            SELECT record_id, dependency_kind, dependency_id
            FROM sync_pending_download_dependencies
            ORDER BY record_id, dependency_kind, dependency_id
            """,
            on: database,
            row: pendingDependencyRow(from:)
        )
        let dependenciesByRecordID = Dictionary(
            grouping: dependencyRows,
            by: \.recordID
        ).mapValues { $0.map(\.dependency) }

        let pending = try query(
            """
            SELECT record_id, generation_id, entity_type, entity_id, operation, modified_at_bits,
                modified_by_device_id, payload, reactivation_witnesses, first_seen_at_bits,
                last_attempted_at_bits, attempt_count
            FROM sync_pending_download_records
            ORDER BY record_id
            """,
            on: database
        ) { statement in
            let recordID = try syncRecordID(statement, 0)
            let generationID = try uuid(statement, 1)
            guard let entityType = SyncEntityType(rawValue: try string(statement, 2)) else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "invalid pending download entity type"
                )
            }
            guard let operation = SyncOperation(rawValue: try string(statement, 4)),
                  operation == .upsert
            else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "invalid pending download operation"
                )
            }
            let record = SyncRecord(
                id: recordID,
                entityType: entityType,
                entityID: try string(statement, 3),
                operation: operation,
                modifiedAt: try exactDate(statement, 5),
                modifiedByDeviceID: SyncDeviceID(try nonemptyString(statement, 6)),
                payload: data(statement, 7),
                reactivationWitnesses: try reactivationWitnesses(
                    from: data(statement, 8)
                )
            )
            guard waitingRecordIsCurrent(record) else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "pending download payload is not a valid current sync record"
                )
            }
            let firstSeenAt = try exactDate(statement, 9)
            let lastAttemptedAt = try exactDate(statement, 10)
            let attemptCount = try int(statement, 11)
            guard lastAttemptedAt >= firstSeenAt, attemptCount >= 1 else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "pending download attempt metadata is invalid"
                )
            }
            guard let dependencies = dependenciesByRecordID[recordID],
                  dependencies.isEmpty == false
            else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "pending download has no dependencies"
                )
            }
            return SyncPendingDownloadRecord(
                record: record,
                generationID: generationID,
                dependencies: dependencies,
                firstSeenAt: firstSeenAt,
                lastAttemptedAt: lastAttemptedAt,
                attemptCount: attemptCount
            )
        }
        return pending.sorted {
            if $0.firstSeenAt != $1.firstSeenAt {
                return $0.firstSeenAt < $1.firstSeenAt
            }
            return $0.record.id.rawValue < $1.record.id.rawValue
        }
    }

    func upsertPendingDownload(
        _ waiting: SyncWaitingRecord,
        stored: SyncPendingDownloadRecord?,
        attemptedAt: Date,
        into database: Database?
    ) throws {
        if let stored {
            guard waiting.record.id == stored.record.id
            else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "pending download replacement changed record identity: \(waiting.record.id.rawValue)"
                )
            }
            guard attemptedAt >= stored.lastAttemptedAt else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "pending download attempt time moved backwards"
                )
            }
            let witnesses = try canonicalReactivationWitnessesData(
                waiting.record.reactivationWitnesses
            )
            try run(
                """
                UPDATE sync_pending_download_records
                SET entity_type = ?, entity_id = ?, operation = ?,
                    modified_at_bits = ?, modified_by_device_id = ?, payload = ?,
                    reactivation_witnesses = ?, last_attempted_at_bits = ?,
                    attempt_count = attempt_count + 1
                WHERE record_id = ?
                """,
                on: database
            ) { statement in
                bind(waiting.record.entityType.rawValue, to: 1, in: statement)
                bind(waiting.record.entityID, to: 2, in: statement)
                bind(waiting.record.operation.rawValue, to: 3, in: statement)
                bindExactDate(waiting.record.modifiedAt, to: 4, in: statement)
                bind(waiting.record.modifiedByDeviceID.rawValue, to: 5, in: statement)
                bind(waiting.record.payload, to: 6, in: statement)
                bind(witnesses, to: 7, in: statement)
                bindExactDate(attemptedAt, to: 8, in: statement)
                bind(waiting.record.id.rawValue, to: 9, in: statement)
            }
        } else {
            let witnesses = try canonicalReactivationWitnessesData(
                waiting.record.reactivationWitnesses
            )
            try run(
                """
                INSERT INTO sync_pending_download_records(
                    record_id, generation_id, entity_type, entity_id, operation, modified_at_bits,
                    modified_by_device_id, payload, reactivation_witnesses, first_seen_at_bits,
                    last_attempted_at_bits, attempt_count
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
                """,
                on: database
            ) { statement in
                bind(waiting.record.id.rawValue, to: 1, in: statement)
                bind(UUID(), to: 2, in: statement)
                bind(waiting.record.entityType.rawValue, to: 3, in: statement)
                bind(waiting.record.entityID, to: 4, in: statement)
                bind(waiting.record.operation.rawValue, to: 5, in: statement)
                bindExactDate(waiting.record.modifiedAt, to: 6, in: statement)
                bind(waiting.record.modifiedByDeviceID.rawValue, to: 7, in: statement)
                bind(waiting.record.payload, to: 8, in: statement)
                bind(witnesses, to: 9, in: statement)
                bindExactDate(attemptedAt, to: 10, in: statement)
                bindExactDate(attemptedAt, to: 11, in: statement)
            }
        }

        try run(
            "DELETE FROM sync_pending_download_dependencies WHERE record_id = ?",
            on: database
        ) { statement in
            bind(waiting.record.id.rawValue, to: 1, in: statement)
        }
        for dependency in Set(waiting.dependencies).sorted(by: dependencySort) {
            let fact = dependencyFact(dependency)
            try run(
                """
                INSERT INTO sync_pending_download_dependencies(
                    record_id, dependency_kind, dependency_id
                )
                VALUES (?, ?, ?)
                """,
                on: database
            ) { statement in
                bind(waiting.record.id.rawValue, to: 1, in: statement)
                bind(fact.kind, to: 2, in: statement)
                bind(fact.id, to: 3, in: statement)
            }
        }
    }

    func pendingDependencyRow(from statement: Statement?) throws -> PendingDependencyRow {
        let recordID = try syncRecordID(statement, 0)
        let kind = try string(statement, 1)
        let rawID = try string(statement, 2)
        return PendingDependencyRow(
            recordID: recordID,
            dependency: try pendingDependency(kind: kind, rawID: rawID)
        )
    }

    func pendingDependency(
        kind: String,
        rawID: String
    ) throws -> SyncRecordDependency {
        switch kind {
        case "day":
            return .day(try pendingDependencyLocalDate(rawID))
        case "classificationRevision":
            guard let revision = UInt64(rawID), revision.description == rawID else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "invalid pending classification revision dependency"
                )
            }
            return .classificationRevision(revision)
        case "currentSnapshotIntegrity":
            guard rawID == "snapshot" else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "invalid pending current snapshot integrity dependency"
                )
            }
            return .currentSnapshotIntegrity
        default:
            return try pendingUUIDDependency(kind: kind, rawID: rawID)
        }
    }

    func pendingDependencyLocalDate(_ rawValue: String) throws -> LocalDate {
        let parts = rawValue.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              (1 ... 12).contains(month),
              (1 ... 31).contains(day),
              String(format: "%04d-%02d-%02d", year, month, day) == rawValue
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "invalid pending day dependency identity"
            )
        }
        return LocalDate(year: year, month: month, day: day)
    }

    func pendingUUIDDependency(
        kind: String,
        rawID: String
    ) throws -> SyncRecordDependency {
        let supportedKinds: Set = [
            "taskChain", "taskDefinition", "dayTrace", "subtask",
            "category", "label", "classificationEvent",
            "classificationCommit"
        ]
        guard supportedKinds.contains(kind) else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "invalid pending download dependency kind"
            )
        }
        let id = try pendingDependencyUUID(rawID, kind: kind)
        switch kind {
        case "taskChain":
            return .taskChain(TaskChainID(id))
        case "taskDefinition":
            return .taskDefinition(TaskDefinitionID(id))
        case "dayTrace":
            return .dayTrace(DayTraceID(id))
        case "subtask":
            return .subtask(SubtaskID(id))
        case "category":
            return .category(TaskCategoryID(id))
        case "label":
            return .label(TaskLabelID(id))
        case "classificationEvent":
            return .classificationEvent(id)
        case "classificationCommit":
            return .classificationCommit(id)
        default:
            throw SQLiteRepositoryError.invalidStoredValue(
                "invalid pending download dependency kind"
            )
        }
    }

    func pendingDependencyUUID(_ rawID: String, kind: String) throws -> UUID {
        guard let id = UUID(uuidString: rawID), id.uuidString == rawID else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "invalid pending \(kind) dependency identity"
            )
        }
        return id
    }

    func dependencyFact(
        _ dependency: SyncRecordDependency
    ) -> (kind: String, id: String) {
        let fact = dependency.sqliteFact
        return (fact.kind, fact.id)
    }

    func dependencySort(
        _ lhs: SyncRecordDependency,
        _ rhs: SyncRecordDependency
    ) -> Bool {
        let lhsFact = dependencyFact(lhs)
        let rhsFact = dependencyFact(rhs)
        return (lhsFact.kind, lhsFact.id) < (rhsFact.kind, rhsFact.id)
    }

    func waitingRecordIsCurrent(_ waiting: SyncWaitingRecord) -> Bool {
        waitingRecordIsCurrent(waiting.record)
    }

    func waitingRecordIsCurrent(_ record: SyncRecord) -> Bool {
        guard record.operation == .upsert,
              record.payload.isEmpty == false
        else { return false }
        guard let payload = try? SyncRecordMapper().payload(from: record) else {
            return false
        }
        switch payload {
        case .day, .taskCycleSeries, .taskChain, .taskDefinition, .dayTrace, .subtask,
             .ideaEntry, .appPreferences, .classificationBaseline,
             .classificationCommit,
             .traceClassificationEvent:
            return true
        }
    }

    func pendingDownloadTokenIsValid(_ pending: SyncPendingDownloadRecord) -> Bool {
        waitingRecordIsCurrent(pending.record)
            && pending.dependencies.isEmpty == false
            && Set(pending.dependencies).count == pending.dependencies.count
            && dateIsFinite(pending.record.modifiedAt)
            && dateIsFinite(pending.firstSeenAt)
            && dateIsFinite(pending.lastAttemptedAt)
            && pending.lastAttemptedAt >= pending.firstSeenAt
            && (1 ... Int(Int32.max)).contains(pending.attemptCount)
    }

    func pendingDownloadTokensMatch(
        _ stored: SyncPendingDownloadRecord,
        _ observed: SyncPendingDownloadRecord
    ) -> Bool {
        stored.generationID == observed.generationID
            && stored.record.exactlyMatches(observed.record)
            && stored.dependencies == observed.dependencies
            && exactDateBits(stored.firstSeenAt) == exactDateBits(observed.firstSeenAt)
            && exactDateBits(stored.lastAttemptedAt) == exactDateBits(observed.lastAttemptedAt)
            && stored.attemptCount == observed.attemptCount
    }

    func dateIsFinite(_ value: Date) -> Bool {
        value.timeIntervalSinceReferenceDate.isFinite
    }

    func canonicalReactivationWitnessesData(
        _ witnesses: [Data]
    ) throws -> Data {
        try JSONEncoder().encode(witnesses)
    }

    func reactivationWitnesses(from canonicalData: Data) throws -> [Data] {
        do {
            let witnesses = try JSONDecoder().decode([Data].self, from: canonicalData)
            guard try canonicalReactivationWitnessesData(witnesses) == canonicalData,
                  witnesses == canonicalWitnesses(witnesses)
            else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "pending download reactivation witnesses are not canonical"
                )
            }
            return witnesses
        } catch let error as SQLiteRepositoryError {
            throw error
        } catch {
            throw SQLiteRepositoryError.invalidStoredValue(
                "pending download reactivation witnesses are invalid"
            )
        }
    }

    func canonicalWitnesses(_ witnesses: [Data]) -> [Data] {
        var unique: [Data] = []
        for witness in witnesses.sorted(by: { $0.lexicographicallyPrecedes($1) })
        where unique.last != witness {
            unique.append(witness)
        }
        return unique
    }

    func exactDateBits(_ value: Date) -> UInt64 {
        value.timeIntervalSinceReferenceDate.bitPattern
    }

    func execute(_ sql: String, on database: Database?) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteRepositoryError.executeFailed(
                "sync repository writerDepth=\(storeRuntime.writerLeaseDepth): \(lastError(database)) in \(sqlSummary(sql))",
                sqliteCode: sqliteDiagnosticCode(database)
            )
        }
    }

    func prepare(_ sql: String, on database: Database?) throws -> Statement? {
        var statement: Statement?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
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

    func run(_ sql: String, on database: Database?, bind: (Statement?) throws -> Void) throws {
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

    func query<T>(_ sql: String, on database: Database?, bind: (Statement?) throws -> Void = { _ in }, row: (Statement?) throws -> T) throws -> [T] {
        let statement = try prepare(sql, on: database)
        defer { sqlite3_finalize(statement) }
        try bind(statement)

        var rows: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                return rows
            }
            guard result == SQLITE_ROW else {
                throw SQLiteRepositoryError.stepFailed(
                    lastError(database),
                    sqliteCode: sqliteDiagnosticCode(database)
                )
            }
            rows.append(try row(statement))
        }
    }

    func updateJournalEntries(_ ids: [UUID], update: (Database?, UUID) throws -> Void) throws {
        guard ids.isEmpty == false else { return }
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        let writeLease = storeRuntime.acquireWriteLease()
        defer { writeLease.release() }
        try execute("BEGIN IMMEDIATE TRANSACTION", on: database)
        do {
            for id in ids {
                try update(database, id)
            }
            try execute("COMMIT", on: database)
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    func bind(_ value: String?, to index: Int32, in statement: Statement?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        _ = value.withCString { bytes in
            sqlite3_bind_text64(
                statement,
                index,
                bytes,
                UInt64(value.utf8.count),
                SQLITE_TRANSIENT,
                UInt8(SQLITE_UTF8)
            )
        }
    }

    func bind(_ value: Int, to index: Int32, in statement: Statement?) {
        sqlite3_bind_int(statement, index, Int32(value))
    }

    func bind(_ value: Int64, to index: Int32, in statement: Statement?) {
        sqlite3_bind_int64(statement, index, value)
    }

    func bind(_ value: UUID, to index: Int32, in statement: Statement?) {
        bind(value.uuidString, to: index, in: statement)
    }

    func bind(_ value: Date?, to index: Int32, in statement: Statement?) {
        bind(value.map(Self.string(from:)), to: index, in: statement)
    }

    func bind(_ value: Data?, to index: Int32, in statement: Statement?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        _ = value.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(value.count), SQLITE_TRANSIENT)
        }
    }

    func bindExactDate(_ value: Date, to index: Int32, in statement: Statement?) {
        bind(
            Int64(bitPattern: value.timeIntervalSinceReferenceDate.bitPattern),
            to: index,
            in: statement
        )
    }

    func string(_ statement: Statement?, _ index: Int32) throws -> String {
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT,
              let value = sqlite3_column_text(statement, index)
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "column \(index) is not UTF-8 text"
            )
        }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard let result = String(
            bytes: UnsafeBufferPointer(start: value, count: count),
            encoding: .utf8
        ) else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "column \(index) is not valid UTF-8 text"
            )
        }
        return result
    }

    func nonemptyString(_ statement: Statement?, _ index: Int32) throws -> String {
        let value = try string(statement, index)
        guard value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw SQLiteRepositoryError.invalidStoredValue("column \(index) is empty")
        }
        return value
    }

    func syncRecordID(_ statement: Statement?, _ index: Int32) throws -> SyncRecordID {
        SyncRecordID(try nonemptyString(statement, index))
    }

    func optionalString(_ statement: Statement?, _ index: Int32) throws -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return try string(statement, index)
    }

    func optionalNonemptyString(
        _ statement: Statement?,
        _ index: Int32
    ) throws -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return try nonemptyString(statement, index)
    }

    func optionalSyncRecordID(
        _ statement: Statement?,
        _ index: Int32
    ) throws -> SyncRecordID? {
        try optionalNonemptyString(statement, index).map(SyncRecordID.init)
    }

    func int(_ statement: Statement?, _ index: Int32) throws -> Int {
        guard sqlite3_column_type(statement, index) == SQLITE_INTEGER else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "column \(index) is not an integer"
            )
        }
        let value = sqlite3_column_int64(statement, index)
        guard value >= Int64(Int32.min), value <= Int64(Int32.max) else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "integer at column \(index) is outside the supported range"
            )
        }
        return Int(value)
    }

    func uuid(_ statement: Statement?, _ index: Int32) throws -> UUID {
        guard let uuid = UUID(uuidString: try string(statement, index)) else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid UUID at column \(index)")
        }
        return uuid
    }

    func date(_ statement: Statement?, _ index: Int32) throws -> Date {
        guard let date = Self.date(from: try string(statement, index)) else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid date at column \(index)")
        }
        return date
    }

    func exactDate(_ statement: Statement?, _ index: Int32) throws -> Date {
        guard sqlite3_column_type(statement, index) == SQLITE_INTEGER else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "exact date at column \(index) is not an integer bit pattern"
            )
        }
        let seconds = Double(
            bitPattern: UInt64(bitPattern: sqlite3_column_int64(statement, index))
        )
        guard seconds.isFinite else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "invalid exact date at column \(index)"
            )
        }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    func data(_ statement: Statement?, _ index: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }

    func optionalData(_ statement: Statement?, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return data(statement, index)
    }

    func journalEntry(from statement: Statement?) throws -> SyncJournalEntry {
        guard let entityType = SyncEntityType(rawValue: try string(statement, 1)) else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid sync entity type")
        }
        guard let operation = SyncOperation(rawValue: try string(statement, 3)) else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid sync operation")
        }
        guard let state = SyncChangeState(rawValue: try string(statement, 7)) else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid sync state")
        }
        let changedAtProjection = try string(statement, 4)
        let changedAt = try exactDate(statement, 5)
        guard Self.string(from: changedAt) == changedAtProjection else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "sync journal changedAt projection does not match its exact bits"
            )
        }
        let recordPayload = optionalData(statement, 10)
        guard SyncJournalEntry.hasValidJournalPayloadShape(
            entityType: entityType,
            recordPayload: recordPayload
        ) else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "sync journal payload invariant is invalid"
            )
        }
        return SyncJournalEntry(
            id: try uuid(statement, 0),
            entityType: entityType,
            entityID: try string(statement, 2),
            operation: operation,
            changedAt: changedAt,
            deviceID: SyncDeviceID(try nonemptyString(statement, 6)),
            state: state,
            retryCount: try int(statement, 8),
            lastError: try optionalString(statement, 9),
            recordPayload: recordPayload,
            transportReceipt: optionalData(statement, 11)
        )
    }

    func storedConflict(id: UUID, from database: Database?) throws -> SyncConflict? {
        try query(
            """
            SELECT id, conflict_type, entity_type, entity_id, local_record_id,
                remote_record_id, remote_payload, detected_at, resolution, message
            FROM sync_conflicts
            WHERE id = ?
            """,
            on: database
        ) { statement in
            bind(id, to: 1, in: statement)
        } row: { statement in
            try conflict(from: statement)
        }.first
    }

    func terminalRejections(from database: Database?) throws -> [SyncTerminalRejection] {
        try query(
            """
            SELECT conflict.id, conflict.conflict_type, conflict.entity_type,
                conflict.entity_id, conflict.local_record_id, conflict.remote_record_id,
                conflict.remote_payload, conflict.detected_at, conflict.resolution,
                conflict.message, terminal.entity_type, terminal.entity_id
            FROM sync_terminal_rejections terminal
            JOIN sync_conflicts conflict ON conflict.id = terminal.conflict_id
            ORDER BY terminal.entity_type, terminal.entity_id
            """,
            on: database,
            row: { statement in
                let conflict = try conflict(from: statement)
                let storedEntityType = try string(statement, 10)
                let storedEntityID = try string(statement, 11)
                guard let rejection = SyncTerminalRejection(conflict: conflict),
                      rejection.identity.entityType.rawValue == storedEntityType,
                      rejection.identity.entityID == storedEntityID
                else {
                    throw SQLiteRepositoryError.invalidStoredValue(
                        "terminal rejection ledger does not match its conflict evidence"
                    )
                }
                return rejection
            }
        )
    }

    func terminalRejectionEvidence(
        from database: Database?
    ) throws -> [SyncTerminalRejection] {
        let candidates: [SyncTerminalRejection?] = try query(
            """
            SELECT conflict.id, conflict.conflict_type, conflict.entity_type,
                conflict.entity_id, conflict.local_record_id, conflict.remote_record_id,
                conflict.remote_payload, conflict.detected_at, conflict.resolution,
                conflict.message, terminal.entity_type, terminal.entity_id
            FROM sync_terminal_rejections terminal
            JOIN sync_conflicts conflict
                ON conflict.entity_type = terminal.entity_type
                AND conflict.entity_id = terminal.entity_id
            ORDER BY terminal.entity_type, terminal.entity_id, conflict.id
            """,
            on: database,
            row: { statement in
                let conflict = try conflict(from: statement)
                let storedEntityType = try string(statement, 10)
                let storedEntityID = try string(statement, 11)
                guard conflict.entityType.rawValue == storedEntityType,
                      conflict.entityID == storedEntityID
                else {
                    throw SQLiteRepositoryError.invalidStoredValue(
                        "terminal provider evidence does not match its stored entity"
                    )
                }
                // The terminal ledger anchors one canonical immutable fact per
                // logical identity, while `sync_conflicts` keeps every remote
                // variant. A malformed variant can share the logical columns
                // but cannot be a terminal identity itself; it must remain a
                // conflict without poisoning later downloads of this identity.
                return SyncTerminalRejection(conflict: conflict)
            }
        )
        return candidates.compactMap { $0 }
    }

    func latestReplicationForkConflictGeneration(
        resolutionID: ReplicationDigest,
        from database: Database?
    ) throws -> SQLiteEngineSnapshotGeneration? {
        try query(
            """
            SELECT engine_epoch, engine_revision
            FROM sync_replication_fork_conflicts
            WHERE resolution_id = ?
            ORDER BY rowid DESC
            LIMIT 1
            """,
            on: database
        ) { statement in
            bind(resolutionID.rawValue, to: 1, in: statement)
        } row: { statement in
            SQLiteEngineSnapshotGeneration(
                epoch: try uuid(statement, 0),
                revision: try nonnegativeUInt64(statement, 1)
            )
        }.first
    }

    func nonnegativeUInt64(
        _ statement: Statement?,
        _ index: Int32
    ) throws -> UInt64 {
        guard sqlite3_column_type(statement, index) == SQLITE_INTEGER else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication fork conflict engine revision is not an integer"
            )
        }
        let value = sqlite3_column_int64(statement, index)
        guard value >= 0 else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication fork conflict engine revision is negative"
            )
        }
        return UInt64(value)
    }

    func replicationDigest(
        _ statement: Statement?,
        _ index: Int32
    ) throws -> ReplicationDigest {
        guard let digest = ReplicationDigest(
            rawValue: try string(statement, index)
        ) else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication fork conflict resolution ID is invalid"
            )
        }
        return digest
    }

    func replicationForkConflictSet(
        resolutionID: ReplicationDigest,
        generation: SQLiteEngineSnapshotGeneration,
        from database: Database?
    ) throws -> SQLiteReplicationForkConflictSet? {
        let rows: [SQLiteReplicationForkConflict] = try query(
            """
            SELECT conflict.id, conflict.conflict_type,
                conflict.entity_type, conflict.entity_id,
                conflict.local_record_id, conflict.remote_record_id,
                conflict.remote_payload, conflict.detected_at,
                conflict.resolution, conflict.message,
                fork.decision, fork.decided_at_bits,
                fork.result_entity_type, fork.result_entity_id
            FROM sync_replication_fork_conflicts fork
            JOIN sync_conflicts conflict ON conflict.id = fork.conflict_id
            WHERE fork.resolution_id = ? AND fork.engine_epoch = ?
              AND fork.engine_revision = ?
            ORDER BY fork.conflict_id
            """,
            on: database
        ) { statement in
            bind(resolutionID.rawValue, to: 1, in: statement)
            bind(generation.epoch.uuidString.lowercased(), to: 2, in: statement)
            guard let revision = Int64(exactly: generation.revision) else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "replication fork conflict engine revision is invalid"
                )
            }
            bind(revision, to: 3, in: statement)
        } row: { statement in
            let rawDecision = try string(statement, 10)
            let decision: ReplicationForkConflictDecision?
            switch rawDecision {
            case "unresolved":
                decision = nil
            default:
                guard let decoded = ReplicationForkConflictDecision(
                    rawValue: rawDecision
                ) else {
                    throw SQLiteRepositoryError.invalidStoredValue(
                        "replication fork conflict decision is invalid"
                    )
                }
                decision = decoded
            }
            let decidedAt: Date? = if sqlite3_column_type(statement, 11) == SQLITE_NULL {
                nil
            } else {
                try exactDate(statement, 11)
            }
            guard (decision == nil) == (decidedAt == nil) else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "replication fork conflict decision time is inconsistent"
                )
            }
            let resultReference: ReplicationForkDecisionResultReference?
            if sqlite3_column_type(statement, 12) == SQLITE_NULL,
               sqlite3_column_type(statement, 13) == SQLITE_NULL
            {
                resultReference = nil
            } else {
                guard let entityType = SyncEntityType(
                    rawValue: try string(statement, 12)
                ) else {
                    throw SQLiteRepositoryError.invalidStoredValue(
                        "replication fork decision result type is invalid"
                    )
                }
                resultReference = ReplicationForkDecisionResultReference(
                    entityType: entityType,
                    entityID: try string(statement, 13)
                )
            }
            let decodedConflict = try conflict(from: statement)
            let outcome = decision.map {
                SQLiteReplicationForkDecisionOutcome(
                    selection: ReplicationForkConflictDecisionSelection(
                        conflictID: decodedConflict.id,
                        decision: $0
                    ),
                    resultReference: resultReference
                )
            }
            guard outcome.map(Self.resultReferenceIsValid(for:)) ?? (resultReference == nil)
            else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "replication fork decision result reference is inconsistent"
                )
            }
            return SQLiteReplicationForkConflict(
                conflict: decodedConflict,
                decision: decision,
                decidedAt: decidedAt,
                resultReference: resultReference
            )
        }
        guard rows.isEmpty == false else { return nil }
        return SQLiteReplicationForkConflictSet(
            resolutionID: resolutionID,
            conflicts: rows,
            observedEngineGeneration: generation
        )
    }

    func conflict(from statement: Statement?) throws -> SyncConflict {
        guard let type = SyncConflictType(rawValue: try string(statement, 1)) else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid sync conflict type")
        }
        guard let entityType = SyncEntityType(rawValue: try string(statement, 2)) else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid sync conflict entity type")
        }
        let entityID = try string(statement, 3)
        let remoteRecordID = try syncRecordID(statement, 5)
        let remoteRecord = try conflictRemoteRecord(
            from: data(statement, 6),
            expectedID: remoteRecordID,
            entityType: entityType,
            entityID: entityID
        )
        guard let resolution = SyncConflictResolution(rawValue: try string(statement, 8)) else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid sync conflict resolution")
        }
        let conflict = SyncConflict(
            id: try uuid(statement, 0),
            type: type,
            entityType: entityType,
            entityID: entityID,
            localRecordID: try optionalSyncRecordID(statement, 4),
            remoteRecord: remoteRecord,
            detectedAt: try date(statement, 7),
            message: try optionalString(statement, 9) ?? "Stored sync conflict",
            resolution: resolution
        )
        guard conflict.id == conflict.canonicalEvidenceID else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "stored sync conflict identity does not match canonical evidence"
            )
        }
        return conflict
    }

    func canonicalConflictRecordData(_ record: SyncRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(record)
    }

    func conflictRemoteRecord(
        from data: Data,
        expectedID: SyncRecordID,
        entityType: SyncEntityType,
        entityID: String
    ) throws -> SyncRecord {
        do {
            let record = try JSONDecoder().decode(SyncRecord.self, from: data)
            guard try canonicalConflictRecordData(record) == data,
                  record.id == expectedID,
                  record.entityType == entityType,
                  record.entityID == entityID
            else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "sync conflict remote evidence identity mismatch"
                )
            }
            return record
        } catch let error as SQLiteRepositoryError {
            throw error
        } catch {
            throw SQLiteRepositoryError.invalidStoredValue(
                "sync conflict remote evidence is not canonical"
            )
        }
    }

    func auditEntry(from statement: Statement?) throws -> SyncAuditLogEntry {
        guard let direction = SyncAuditDirection(rawValue: try string(statement, 1)) else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid sync audit direction")
        }
        guard let entityType = SyncEntityType(rawValue: try string(statement, 2)) else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid sync audit entity type")
        }
        return SyncAuditLogEntry(
            id: try uuid(statement, 0),
            direction: direction,
            entityType: entityType,
            entityID: try string(statement, 3),
            sourceEvidenceID: try evidenceID(statement, 4),
            canonicalEvidenceID: try evidenceID(statement, 5),
            action: try nonemptyString(statement, 6),
            createdAt: try date(statement, 7),
            message: try optionalString(statement, 8)
        )
    }

    func evidenceID(
        _ statement: Statement?,
        _ index: Int32
    ) throws -> SyncRecordEvidenceID? {
        guard let rawValue = try optionalString(statement, index) else {
            return nil
        }
        guard let evidenceID = SyncRecordEvidenceID(rawValue: rawValue) else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "sync audit evidence ID is not lowercase SHA-256"
            )
        }
        return evidenceID
    }

    func lastError(_ database: Database?) -> String {
        database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite error"
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
