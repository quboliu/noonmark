import Darwin
import Foundation
import NoonmarkCore
import NoonmarkSync
import SQLite3

enum SQLiteJournalCAS {
    private static let insertSQL = """
    INSERT INTO change_journal(
        id, entity_type, entity_id, operation, changed_at, changed_at_bits,
        device_id, sync_state, retry_count, last_error, record_payload
    )
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO NOTHING
    """

    private static let exactMatchSQL = """
    SELECT 1
    FROM change_journal
    WHERE id IS ?
      AND entity_type IS ?
      AND entity_id IS ?
      AND operation IS ?
      AND changed_at IS ?
      AND changed_at_bits IS ?
      AND device_id IS ?
      AND sync_state IS ?
      AND retry_count IS ?
      AND last_error IS ?
      AND record_payload IS ?
    """

    static func insertOrValidateExact(
        _ entry: SyncJournalEntry,
        into database: OpaquePointer?
    ) throws {
        guard entry.changedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "sync journal changedAt must be finite"
            )
        }
        let insert = try prepare(insertSQL, on: database)
        defer { sqlite3_finalize(insert) }
        bind(entry, to: insert)
        guard sqlite3_step(insert) == SQLITE_DONE else {
            throw SQLiteRepositoryError.stepFailed(lastError(database))
        }

        let match = try prepare(exactMatchSQL, on: database)
        defer { sqlite3_finalize(match) }
        bind(entry, to: match)
        switch sqlite3_step(match) {
        case SQLITE_ROW:
            return
        case SQLITE_DONE:
            throw SQLiteRepositoryError.invalidStoredValue(
                "sync journal identity collision: \(entry.id.uuidString)"
            )
        default:
            throw SQLiteRepositoryError.stepFailed(lastError(database))
        }
    }

    private static func prepare(
        _ sql: String,
        on database: OpaquePointer?
    ) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteRepositoryError.prepareFailed(lastError(database))
        }
        return statement
    }

    private static func bind(_ entry: SyncJournalEntry, to statement: OpaquePointer?) {
        bind(entry.id.uuidString, to: 1, in: statement)
        bind(entry.entityType.rawValue, to: 2, in: statement)
        bind(entry.entityID, to: 3, in: statement)
        bind(entry.operation.rawValue, to: 4, in: statement)
        bind(string(from: entry.changedAt), to: 5, in: statement)
        sqlite3_bind_int64(
            statement,
            6,
            Int64(bitPattern: entry.changedAt.timeIntervalSinceReferenceDate.bitPattern)
        )
        bind(entry.deviceID.rawValue, to: 7, in: statement)
        bind(entry.state.rawValue, to: 8, in: statement)
        sqlite3_bind_int(statement, 9, Int32(entry.retryCount))
        bind(entry.lastError, to: 10, in: statement)
        bind(entry.recordPayload, to: 11, in: statement)
    }

    private static func bind(
        _ value: String?,
        to index: Int32,
        in statement: OpaquePointer?
    ) {
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

    private static func bind(
        _ value: Data?,
        to index: Int32,
        in statement: OpaquePointer?
    ) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        _ = value.withUnsafeBytes { buffer in
            sqlite3_bind_blob(
                statement,
                index,
                buffer.baseAddress,
                Int32(value.count),
                SQLITE_TRANSIENT
            )
        }
    }

    private static func string(from date: Date) -> String {
        SQLiteISO8601DateCodec.string(from: date)
    }

    private static func lastError(_ database: OpaquePointer?) -> String {
        database.map { String(cString: sqlite3_errmsg($0)) }
            ?? "unknown sqlite error"
    }
}

private struct SQLiteClassificationSourceRecord {
    let kind: String
    let sessionID: UUID?
    let draftID: UUID?
    let draftVersion: Int?
    let evidenceID: UUID?
    let fromChainID: TaskChainID?
    let reason: String?
}

private enum SQLiteClassificationSelectionSide: String, Hashable {
    case before
    case after
}

private struct SQLiteClassificationSelectionKey: Hashable {
    let recordID: UUID
    let changePosition: Int
    let side: SQLiteClassificationSelectionSide
}

private struct SQLiteClassificationChangeKey: Hashable {
    let recordID: UUID
    let position: Int
}

private struct SQLiteClassificationSelectionItemRow {
    let position: Int
    let item: ClassificationPlanItem
}

private struct SQLiteClassificationChangeRow {
    let recordID: UUID
    let position: Int
    let kind: String
    let chainID: TaskChainID?
    let itemKind: ClassificationItemKind?
    let itemID: String?
    let beforeName: String?
    let afterName: String?
    let name: String?
    let beforeLifecycle: ClassificationLifecycle?
    let afterLifecycle: ClassificationLifecycle?
    let beforeApproval: CategoryPresentationApproval?
    let afterApproval: CategoryPresentationApproval?
}

private struct SQLiteClassificationManagementChangeRow {
    let recordID: UUID
    let position: Int
    let kind: String
    let itemKind: ClassificationItemKind
    let itemID: String
    let name: String
    var colorHex: String?
    var targetID: String?
    var targetName: String?
    var sourceLifecycle: ClassificationLifecycle?
    var lifecycle: ClassificationLifecycle?
    var migratedRelationCount: Int?
    var deduplicatedRelationCount: Int?
    var currentRelationCount: Int?
    var relationHistoryCount: Int?
    var historicalEventCount: Int?
    var mergeSourceCount: Int?
    var mergeTargetCount: Int?
}

private struct SQLiteClassificationChangeRecordRow {
    let sequence: Int
    let id: UUID
    let planID: UUID
    let interactionID: UUID
    let source: ClassificationSource
    let decisionID: UUID?
    let committedAt: Date
    let revision: UInt64
}

private struct SQLiteTraceClassificationEvent {
    let sequence: Int
    let snapshot: TraceClassificationSnapshot
}

private enum SQLiteClassificationKind: String {
    case category
    case label
}

private struct SQLiteClassificationItemKey: Hashable {
    let kind: SQLiteClassificationKind
    let itemID: UUID
}

private struct SQLiteClassificationItemMetadata {
    let canonicalKey: String
    let canonicalKeyVersion: String
    let lifecycle: ClassificationLifecycle
}

private struct SQLiteClassificationNameVersion {
    let item: SQLiteClassificationItemKey
    let sequence: Int
    let version: ClassificationNameVersion
}

private struct SQLiteClassificationItemExactTime: Equatable {
    let createdAt: Date
    let updatedAt: Date
}

private struct SQLiteClassificationNameVersionExactTime: Equatable {
    let item: SQLiteClassificationItemKey
    let validFrom: Date
    let validUntil: Date?
}

private struct SQLiteNameVersionStatements {
    let insert: String
    let close: String
    let exactInsert: String
    let exactClose: String
}

private struct SQLiteClassificationNoticeRecord {
    let kind: String
    let duplicateName: String?
    let itemKind: String?
    let inputName: String?
    let currentName: String?
    let matchedHistoricalAlias: Int?
}

private struct SQLiteClassificationReceiptRow {
    let interactionID: UUID
    let planID: UUID
    let revision: UInt64
    let notices: [ClassificationNotice]
}

private struct SQLiteClassificationReceiptMetadata {
    let changeRecordID: UUID
    let decisionID: UUID?
    let integrityDigest: String
}

private struct SQLiteClassificationRecordFinalization {
    let changeCount: Int
    let noticeCount: Int
}

private struct SQLiteClassificationRelationKey: Hashable {
    let kind: ClassificationItemKind
    let chainID: TaskChainID
    let itemID: String
}

private struct SQLiteClassificationRelationFact {
    let key: SQLiteClassificationRelationKey
    let source: ClassificationSource
    let decisionID: UUID?
    let createdAt: Date
    let updatedAt: Date
    let revision: UInt64
}

private struct SQLiteClassificationRelationTransition {
    let incomingChainStates: Set<TaskChainID>
    let incomingFacts: [SQLiteClassificationRelationKey: SQLiteClassificationRelationFact]
    let storedFacts: [SQLiteClassificationRelationKey: SQLiteClassificationRelationFact]
    let storedChainStates: Set<TaskChainID>

    var removedKeys: Set<SQLiteClassificationRelationKey> {
        Set(storedFacts.keys).subtracting(incomingFacts.keys)
    }
}

private enum SQLiteAuditSequenceProjection {
    case changeRecord
    case relationHistory

    var tableName: String {
        switch self {
        case .changeRecord:
            "classification_change_records"
        case .relationHistory:
            "classification_relation_history"
        }
    }

    var identityColumn: String {
        switch self {
        case .changeRecord:
            "record_id"
        case .relationHistory:
            "history_id"
        }
    }

    var sequenceColumn: String {
        switch self {
        case .changeRecord:
            "record_sequence"
        case .relationHistory:
            "history_sequence"
        }
    }
}

private struct SQLiteClassificationChangeLoadContext {
    let recordRows: [SQLiteClassificationChangeRecordRow]
    let selectionRowsByKey: [SQLiteClassificationSelectionKey: [SQLiteClassificationSelectionItemRow]]
    let changeRowsByRecordID: [UUID: [SQLiteClassificationChangeRow]]
    let managementRowsByRecordID: [UUID: [SQLiteClassificationManagementChangeRow]]
    let noticesByRecordID: [UUID: [ClassificationNotice]]
    let impactChainIDs: [SQLiteClassificationChangeKey: [UUID]]
    let impactTraceIDs: [SQLiteClassificationChangeKey: [UUID]]
    let impactEventIDs: [SQLiteClassificationChangeKey: [UUID]]
    let finalizationsByRecordID: [UUID: SQLiteClassificationRecordFinalization]
    let planDigestsByRecordID: [UUID: String]
    let integrityDigestsByRecordID: [UUID: String]
    var consumedSelectionKeys: Set<SQLiteClassificationSelectionKey> = []
    var consumedImpactKeys: Set<SQLiteClassificationChangeKey> = []
}

struct SQLiteEngineSnapshotGeneration: Equatable {
    let epoch: UUID
    let revision: UInt64
}

struct SQLiteObservedEngineSnapshot: Equatable {
    let snapshot: NoonmarkSnapshot
    let generation: SQLiteEngineSnapshotGeneration
}

public final class SQLiteEngineRepository {
    private let databaseURL: URL
    private let journalEntryIDGenerator: () -> UUID
    private let storeRuntime: SQLiteStoreRuntime

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
        journalEntryIDGenerator = UUID.init
        storeRuntime = SQLiteStoreRuntime.shared(for: databaseURL)
    }

    public func finalizeForTermination() throws {
        try storeRuntime.finalizeForTermination()
    }

    init(databaseURL: URL, journalEntryIDGenerator: @escaping () -> UUID) {
        self.databaseURL = databaseURL
        self.journalEntryIDGenerator = journalEntryIDGenerator
        storeRuntime = SQLiteStoreRuntime.shared(for: databaseURL)
    }

    public func save(_ engine: NoonmarkEngine) throws {
        try save(engine.snapshot())
    }

    public func save(_ snapshot: NoonmarkSnapshot) throws {
        try save(snapshot, changedFrom: nil)
    }

    public func save(
        _ snapshot: NoonmarkSnapshot,
        changedFrom sourceSnapshot: NoonmarkSnapshot
    ) throws {
        try save(snapshot, changedFrom: Optional(sourceSnapshot))
    }

    private func save(
        _ snapshot: NoonmarkSnapshot,
        changedFrom sourceSnapshot: NoonmarkSnapshot?
    ) throws {
        try validateSnapshotForPersistence(snapshot)
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        try execute("BEGIN IMMEDIATE TRANSACTION", on: database)
        do {
            let oldSnapshot = try authoritativeSourceSnapshot(
                proposed: sourceSnapshot,
                from: database
            )
            try advanceEngineSnapshotGeneration(in: database)
            try persistValidatedSnapshot(
                snapshot,
                changedFrom: oldSnapshot,
                into: database
            )
            try execute("COMMIT", on: database)
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    public func replaceForDataImport(
        _ snapshot: NoonmarkSnapshot,
        preserving deviceIdentity: SyncDeviceIdentity?
    ) throws {
        try validateSnapshotForPersistence(snapshot)
        let stagedURL = databaseURL.deletingLastPathComponent()
            .appendingPathComponent(".noonmark-import-\(UUID().uuidString).sqlite")
        defer { removeDatabaseFiles(at: stagedURL) }

        let stagedRepository = SQLiteEngineRepository(databaseURL: stagedURL)
        try stagedRepository.save(snapshot)
        if let deviceIdentity {
            let stagedSyncRepository = SQLiteSyncRepository(
                databaseURL: stagedURL
            )
            try stagedSyncRepository.saveDeviceIdentity(deviceIdentity)
            let baselineCreatedAt = Date()
            let baselineEntries = try SyncSnapshotBaselineBuilder()
                .journalEntries(
                    from: snapshot,
                    modifiedBy: deviceIdentity.deviceID,
                    createdAt: baselineCreatedAt
                )
            let manifest = SQLiteSyncBaselineManifest(
                createdAt: baselineCreatedAt,
                entries: baselineEntries
            )
            try stagedSyncRepository.saveBaselineJournal(
                baselineEntries,
                manifestMetadata: try manifest.metadata(
                    key: SQLiteLocalFirstSyncCoordinator
                        .baselineManifestMetadataKey,
                    updatedAt: baselineCreatedAt
                )
            )
        }
        _ = try stagedRepository.load()

        try replaceDatabaseContents(from: stagedRepository)
    }

    public func save(
        _ snapshot: NoonmarkSnapshot,
        changedFrom sourceSnapshot: NoonmarkSnapshot? = nil,
        recordingChangesFor deviceID: SyncDeviceID,
        changedAt: Date
    ) throws {
        guard changedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "engine mutation changedAt must be finite"
            )
        }
        try validateSnapshotForPersistence(snapshot)
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        try execute("BEGIN IMMEDIATE TRANSACTION", on: database)
        do {
            let oldSnapshot = try authoritativeSourceSnapshot(
                proposed: sourceSnapshot,
                from: database
            )
            var journalEntries = try SyncSnapshotDiffer().journalEntries(
                from: oldSnapshot,
                to: snapshot,
                changedAt: changedAt,
                deviceID: deviceID
            )
            for index in journalEntries.indices {
                journalEntries[index].id = journalEntryIDGenerator()
            }
            try advanceEngineSnapshotGeneration(in: database)
            try persistValidatedSnapshot(
                snapshot,
                changedFrom: oldSnapshot,
                into: database
            )
            try appendJournalEntries(journalEntries, into: database)
            try execute("COMMIT", on: database)
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    public func save(
        _ snapshot: NoonmarkSnapshot,
        changedFrom sourceSnapshot: NoonmarkSnapshot? = nil,
        classificationCommitBoundaries: [NoonmarkSnapshot],
        recordingChangesFor deviceID: SyncDeviceID,
        changedAt: Date
    ) throws {
        try saveWithAutomaticClassificationMutation(
            snapshot,
            changedFrom: sourceSnapshot,
            classificationCommitBoundaries:
            classificationCommitBoundaries,
            recordingChangesFor: deviceID,
            changedAt: changedAt
        ) { _ in }
    }

    public func save(
        _ snapshot: NoonmarkSnapshot,
        changedFrom sourceSnapshot: NoonmarkSnapshot? = nil,
        recordingChangesFor deviceID: SyncDeviceID,
        changedAt: Date,
        enqueuingAutomaticClassificationJobs jobs: [AutomaticClassificationJobEnqueue]
    ) throws {
        try saveWithAutomaticClassificationMutation(
            snapshot,
            changedFrom: sourceSnapshot,
            recordingChangesFor: deviceID,
            changedAt: changedAt
        ) { database in
            for job in jobs {
                try SQLiteAutomaticClassificationJobSQL.enqueue(job, into: database)
            }
        }
    }

    public func save(
        _ snapshot: NoonmarkSnapshot,
        changedFrom sourceSnapshot: NoonmarkSnapshot? = nil,
        classificationCommitBoundaries: [NoonmarkSnapshot],
        recordingChangesFor deviceID: SyncDeviceID,
        changedAt: Date,
        enqueuingAutomaticClassificationJobs jobs: [
            AutomaticClassificationJobEnqueue
        ],
        applyingAutomaticClassificationJobMutations mutations: [
            AutomaticClassificationJobMutation
        ],
        automaticClassificationTransitionAt transitionAt: Date
    ) throws {
        try SQLiteAutomaticClassificationJobSQL.validateDate(
            transitionAt,
            label: "automatic classification reconciliation transitionAt"
        )
        try saveWithAutomaticClassificationMutation(
            snapshot,
            changedFrom: sourceSnapshot,
            classificationCommitBoundaries:
            classificationCommitBoundaries,
            recordingChangesFor: deviceID,
            changedAt: changedAt
        ) { database in
            for mutation in mutations {
                switch mutation {
                case let .replace(fence, replacement):
                    try SQLiteAutomaticClassificationJobSQL.replace(
                        fence,
                        with: replacement,
                        now: transitionAt,
                        in: database
                    )
                case let .invalidateChain(chainID):
                    _ = try SQLiteAutomaticClassificationJobSQL
                        .invalidateJobs(
                            forChain: chainID,
                            now: transitionAt,
                            in: database
                        )
                case let .supersedeChain(chainID):
                    _ = try SQLiteAutomaticClassificationJobSQL
                        .supersedeJobs(
                            forChain: chainID,
                            now: transitionAt,
                            in: database
                        )
                case let .restoreEligibility(fence, replacement):
                    try SQLiteAutomaticClassificationJobSQL
                        .restoreEligibility(
                            fence,
                            with: replacement,
                            in: database
                        )
                case let .cancelForUndo(chainID):
                    _ = try SQLiteAutomaticClassificationJobSQL
                        .cancelJobs(
                            forUndoneChain: chainID,
                            now: transitionAt,
                            in: database
                        )
                case let .requeueCancelledByUndo(redo):
                    try SQLiteAutomaticClassificationJobSQL
                        .requeueCancelledByUndo(
                            redo,
                            in: database
                        )
                }
            }
            for job in jobs {
                try SQLiteAutomaticClassificationJobSQL.enqueue(
                    job,
                    into: database
                )
            }
        }
    }

    public func save(
        _ snapshot: NoonmarkSnapshot,
        changedFrom sourceSnapshot: NoonmarkSnapshot? = nil,
        recordingChangesFor deviceID: SyncDeviceID,
        changedAt: Date,
        enqueuingAutomaticClassificationJobs jobs: [AutomaticClassificationJobEnqueue],
        applyingAutomaticClassificationJobMutations mutations: [
            AutomaticClassificationJobMutation
        ],
        automaticClassificationTransitionAt transitionAt: Date
    ) throws {
        try SQLiteAutomaticClassificationJobSQL.validateDate(
            transitionAt,
            label: "automatic classification reconciliation transitionAt"
        )
        try saveWithAutomaticClassificationMutation(
            snapshot,
            changedFrom: sourceSnapshot,
            recordingChangesFor: deviceID,
            changedAt: changedAt
        ) { database in
            for mutation in mutations {
                switch mutation {
                case let .replace(fence, replacement):
                    try SQLiteAutomaticClassificationJobSQL.replace(
                        fence,
                        with: replacement,
                        now: transitionAt,
                        in: database
                    )
                case let .invalidateChain(chainID):
                    _ = try SQLiteAutomaticClassificationJobSQL.invalidateJobs(
                        forChain: chainID,
                        now: transitionAt,
                        in: database
                    )
                case let .supersedeChain(chainID):
                    _ = try SQLiteAutomaticClassificationJobSQL.supersedeJobs(
                        forChain: chainID,
                        now: transitionAt,
                        in: database
                    )
                case let .restoreEligibility(fence, replacement):
                    try SQLiteAutomaticClassificationJobSQL.restoreEligibility(
                        fence,
                        with: replacement,
                        in: database
                    )
                case let .cancelForUndo(chainID):
                    _ = try SQLiteAutomaticClassificationJobSQL.cancelJobs(
                        forUndoneChain: chainID,
                        now: transitionAt,
                        in: database
                    )
                case let .requeueCancelledByUndo(redo):
                    try SQLiteAutomaticClassificationJobSQL.requeueCancelledByUndo(
                        redo,
                        in: database
                    )
                }
            }
            for job in jobs {
                try SQLiteAutomaticClassificationJobSQL.enqueue(job, into: database)
            }
        }
    }

    public func save(
        _ snapshot: NoonmarkSnapshot,
        recordingChangesFor deviceID: SyncDeviceID,
        changedAt: Date,
        completingAutomaticClassificationJob claim: AutomaticClassificationJobClaim,
        automaticClassificationTransitionAt transitionAt: Date
    ) throws {
        try SQLiteAutomaticClassificationJobSQL.validateDate(
            transitionAt,
            label: "automatic classification completion transitionAt"
        )
        try saveWithAutomaticClassificationMutation(
            snapshot,
            recordingChangesFor: deviceID,
            changedAt: changedAt
        ) { database in
            try SQLiteAutomaticClassificationJobSQL.complete(
                claim,
                now: transitionAt,
                in: database
            )
        }
    }

    public func save(
        _ snapshot: NoonmarkSnapshot,
        recordingChangesFor deviceID: SyncDeviceID,
        changedAt: Date,
        cancellingAutomaticClassificationJobsForUndoneChain chainID: TaskChainID,
        automaticClassificationTransitionAt transitionAt: Date
    ) throws {
        try SQLiteAutomaticClassificationJobSQL.validateDate(
            transitionAt,
            label: "automatic classification cancellation transitionAt"
        )
        try saveWithAutomaticClassificationMutation(
            snapshot,
            recordingChangesFor: deviceID,
            changedAt: changedAt
        ) { database in
            _ = try SQLiteAutomaticClassificationJobSQL.cancelJobs(
                forUndoneChain: chainID,
                now: transitionAt,
                in: database
            )
        }
    }

    public func save(
        _ snapshot: NoonmarkSnapshot,
        recordingChangesFor deviceID: SyncDeviceID,
        changedAt: Date,
        supersedingAutomaticClassificationJobsForChain chainID: TaskChainID,
        automaticClassificationTransitionAt transitionAt: Date
    ) throws {
        try SQLiteAutomaticClassificationJobSQL.validateDate(
            transitionAt,
            label: "automatic classification supersede transitionAt"
        )
        try saveWithAutomaticClassificationMutation(
            snapshot,
            recordingChangesFor: deviceID,
            changedAt: changedAt
        ) { database in
            _ = try SQLiteAutomaticClassificationJobSQL.supersedeJobs(
                forChain: chainID,
                now: transitionAt,
                in: database
            )
        }
    }

    public func save(
        _ snapshot: NoonmarkSnapshot,
        recordingChangesFor deviceID: SyncDeviceID,
        changedAt: Date,
        requeuingAutomaticClassificationJobForRedo redo: AutomaticClassificationJobRedo
    ) throws {
        try saveWithAutomaticClassificationMutation(
            snapshot,
            recordingChangesFor: deviceID,
            changedAt: changedAt
        ) { database in
            try SQLiteAutomaticClassificationJobSQL.requeueCancelledByUndo(
                redo,
                in: database
            )
        }
    }

    private func saveWithAutomaticClassificationMutation(
        _ snapshot: NoonmarkSnapshot,
        changedFrom sourceSnapshot: NoonmarkSnapshot? = nil,
        classificationCommitBoundaries: [NoonmarkSnapshot]? = nil,
        recordingChangesFor deviceID: SyncDeviceID,
        changedAt: Date,
        mutation: (OpaquePointer?) throws -> Void
    ) throws {
        guard changedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "engine mutation changedAt must be finite"
            )
        }
        try validateSnapshotForPersistence(snapshot)
        let journalBoundaries =
            classificationCommitBoundaries ?? [snapshot]
        guard journalBoundaries.isEmpty == false,
              journalBoundaries.last == snapshot
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "classification commit boundaries must end at the final snapshot"
            )
        }
        // The final boundary is `snapshot`, which was validated above.
        // Validate only the preceding explicit classification boundaries so
        // the common single-boundary save does not repeat a full integrity
        // traversal of the same snapshot.
        for boundary in journalBoundaries.dropLast() {
            try validateSnapshotForPersistence(boundary)
        }
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        try execute("BEGIN IMMEDIATE TRANSACTION", on: database)
        do {
            let oldSnapshot = try authoritativeSourceSnapshot(
                proposed: sourceSnapshot,
                from: database
            )
            var journalEntries: [SyncJournalEntry] = []
            var precedingSnapshot = oldSnapshot
            for boundary in journalBoundaries {
                let entries = try SyncSnapshotDiffer().journalEntries(
                    from: precedingSnapshot,
                    to: boundary,
                    changedAt: changedAt,
                    deviceID: deviceID
                )
                if classificationCommitBoundaries != nil {
                    guard entries.filter({
                        $0.entityType == .classificationCommit
                    }).count == 1 else {
                        throw SQLiteRepositoryError.invalidStoredValue(
                            "each classification persistence boundary must contain exactly one commit"
                        )
                    }
                }
                journalEntries.append(contentsOf: entries)
                precedingSnapshot = boundary
            }
            for index in journalEntries.indices {
                journalEntries[index].id = journalEntryIDGenerator()
            }
            try advanceEngineSnapshotGeneration(in: database)
            try persistValidatedSnapshot(
                snapshot,
                changedFrom: oldSnapshot,
                into: database
            )
            try appendJournalEntries(journalEntries, into: database)
            try mutation(database)
            try execute("COMMIT", on: database)
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    func validateSnapshotForPersistence(_ snapshot: NoonmarkSnapshot) throws {
        try snapshot.validateIntegrity()
    }

    /// Resolves a differential-write baseline from the transaction's actual
    /// SQLite snapshot. A caller-provided snapshot is only a hint: in-memory
    /// domain setup, undo, or another committed writer may have moved ahead of
    /// durable storage. Trusting that hint without comparison can omit parent
    /// rows and either lose data silently or violate a child-table foreign key.
    func authoritativeSourceSnapshot(
        proposed sourceSnapshot: NoonmarkSnapshot?,
        from database: OpaquePointer?
    ) throws -> NoonmarkSnapshot {
        let storedSnapshot = try loadSnapshot(from: database)
        guard let sourceSnapshot,
              sourceSnapshot == storedSnapshot
        else {
            return storedSnapshot
        }
        return sourceSnapshot
    }

    func persistValidatedSnapshot(
        _ snapshot: NoonmarkSnapshot,
        changedFrom oldSnapshot: NoonmarkSnapshot,
        into database: OpaquePointer?
    ) throws {
        if try (
            snapshot.preferences != oldSnapshot.preferences
                || hasMaterializedPreferences(in: database) == false
        ) {
            try upsert(snapshot.preferences, into: database)
        }
        try upsert(
            changedValues(
                snapshot.days,
                from: oldSnapshot.days,
                identifiedBy: \.id
            ),
            into: database
        )
        if snapshot.classifications != oldSnapshot.classifications {
            // Tombstones reference immutable change records. Persist that
            // audit root first, then release deleted identities before a new
            // identity claims any of their aliases.
            try insertClassificationChangeRecords(
                snapshot.classifications,
                into: database
            )
            try insertClassificationDeletionTombstonesAndPurgeCatalog(
                snapshot.classifications,
                into: database
            )
            try upsertClassificationCatalog(
                snapshot.classifications,
                into: database
            )
        }
        try upsert(
            changedValues(
                snapshot.taskCycleSeries,
                from: oldSnapshot.taskCycleSeries,
                identifiedBy: \.id
            ),
            into: database
        )
        try upsert(
            changedValues(
                snapshot.chains,
                from: oldSnapshot.chains,
                identifiedBy: \.id
            ),
            into: database
        )
        try upsert(
            changedValues(
                snapshot.definitions,
                from: oldSnapshot.definitions,
                identifiedBy: \.id
            ),
            into: database
        )
        try upsert(
            changedValues(
                snapshot.traces,
                from: oldSnapshot.traces,
                identifiedBy: \.id
            ),
            into: database
        )
        try upsert(
            changedValues(
                snapshot.subtasks,
                from: oldSnapshot.subtasks,
                identifiedBy: \.id
            ),
            into: database
        )
        if snapshot.classifications != oldSnapshot.classifications {
            try upsertClassificationRelations(
                snapshot.classifications,
                chainIDs: snapshot.chains.map(\.id),
                into: database
            )
            try insertClassificationRelationHistory(
                snapshot.classifications,
                into: database
            )
            try insertClassificationSnapshotEvents(
                snapshot.classifications,
                into: database
            )
            try upsertClassificationRevision(
                snapshot.classifications.revision,
                into: database
            )
            try insertClassificationMerges(
                snapshot.classifications,
                into: database
            )
            try insertClassificationReceipts(
                snapshot.classifications,
                into: database
            )
        }
    }

    func hasMaterializedPreferences(
        in database: OpaquePointer?
    ) throws -> Bool {
        try query(
            """
            SELECT 1
            FROM app_preferences
            WHERE id = 1
            LIMIT 1
            """,
            on: database
        ) { _ in true }.first ?? false
    }

    func changedValues<Value: Equatable>(
        _ incoming: [Value],
        from stored: [Value],
        identifiedBy identity: (Value) -> some Hashable
    ) -> [Value] {
        let storedByID = Dictionary(
            uniqueKeysWithValues: stored.map {
                (identity($0), $0)
            }
        )
        return incoming.filter {
            storedByID[identity($0)] != $0
        }
    }

    func compareAndAdvanceEngineSnapshotGeneration(
        observed: SQLiteEngineSnapshotGeneration,
        in database: OpaquePointer?
    ) throws {
        try run(
            """
            UPDATE engine_snapshot_generation
            SET revision = revision + 1
            WHERE id = 1 AND epoch = ? AND revision = ?
                AND revision < 9223372036854775807
            """,
            on: database
        ) { statement in
            bind(observed.epoch.uuidString.lowercased(), to: 1, in: statement)
            try bind(observed.revision, to: 2, in: statement)
        }
        guard sqlite3_changes(database) == 1 else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "engine snapshot generation changed before merge commit"
            )
        }
    }

    public func load() throws -> NoonmarkEngine {
        try NoonmarkEngine(snapshot: loadObservedSnapshot().snapshot)
    }

    func loadObservedSnapshot() throws -> SQLiteObservedEngineSnapshot {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        try execute("BEGIN DEFERRED TRANSACTION", on: database)
        do {
            // The first SELECT establishes SQLite's read snapshot. Generation and
            // every entity table are therefore observed from one database state.
            let generation = try engineSnapshotGeneration(from: database)
            let snapshot = try loadSnapshot(from: database)
            _ = try NoonmarkEngine(snapshot: snapshot)
            try execute("COMMIT", on: database)
            return SQLiteObservedEngineSnapshot(
                snapshot: snapshot,
                generation: generation
            )
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }
}

public enum SQLiteRepositoryError: Error, Equatable {
    case transientContention
    case openFailed(String)
    case prepareFailed(String)
    case executeFailed(String)
    case stepFailed(String)
    case invalidStoredValue(String)
    case backupFailed(String)

    public var isTransientContention: Bool {
        if case .transientContention = self {
            return true
        }
        return false
    }
}

extension SQLiteRepositoryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .transientContention:
            return "SQLite is temporarily busy; retry later."
        case let .openFailed(message):
            return "SQLite open failed: \(message)"
        case let .prepareFailed(message):
            return "SQLite prepare failed: \(message)"
        case let .executeFailed(message):
            return "SQLite execute failed: \(message)"
        case let .stepFailed(message):
            return "SQLite step failed: \(message)"
        case let .invalidStoredValue(message):
            return "SQLite stored value is invalid: \(message)"
        case let .backupFailed(message):
            return "SQLite backup failed: \(message)"
        }
    }
}

private extension SQLiteEngineRepository {
    typealias Database = OpaquePointer
    typealias Statement = OpaquePointer

    static func string(from date: Date) -> String {
        SQLiteISO8601DateCodec.string(from: date)
    }

    static func date(from string: String) -> Date? {
        SQLiteISO8601DateCodec.date(from: string)
    }

    func plannedSubtasksJSON(_ plannedSubtasks: [PlannedSubtask]) throws -> String? {
        guard plannedSubtasks.isEmpty == false else { return nil }
        let data = try ExactDateJSONCoding.encoder(
            nonFiniteDateDescription: "domain JSON date must be finite"
        ).encode(plannedSubtasks)
        guard let string = String(data: data, encoding: .utf8) else {
            throw SQLiteRepositoryError.invalidStoredValue("planned subtasks JSON encoding failed")
        }
        return string
    }

    func plannedSubtasks(from json: String?) throws -> [PlannedSubtask] {
        guard let json, json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return []
        }
        guard let data = json.data(using: .utf8) else {
            throw SQLiteRepositoryError.invalidStoredValue("planned subtasks JSON is not UTF-8")
        }
        return try ExactDateJSONCoding.decoder(
            nonFiniteDateDescription: "domain JSON date must be finite"
        ).decode([PlannedSubtask].self, from: data)
    }

    func noteEntriesJSON(_ noteEntries: [TaskNoteEntry]) throws -> String {
        let data = try ExactDateJSONCoding.encoder(
            nonFiniteDateDescription: "domain JSON date must be finite"
        ).encode(noteEntries)
        guard let string = String(data: data, encoding: .utf8) else {
            throw SQLiteRepositoryError.invalidStoredValue("task note entries JSON encoding failed")
        }
        return string
    }

    func noteEntries(from json: String) throws -> [TaskNoteEntry] {
        guard let data = json.data(using: .utf8) else {
            throw SQLiteRepositoryError.invalidStoredValue("task note entries JSON is not UTF-8")
        }
        do {
            return try ExactDateJSONCoding.decoder(
                nonFiniteDateDescription: "domain JSON date must be finite"
            ).decode([TaskNoteEntry].self, from: data)
        } catch {
            throw SQLiteRepositoryError.invalidStoredValue(
                "invalid task note entries JSON: \(error.localizedDescription)"
            )
        }
    }

    func taskCycleMembershipJSON(
        _ membership: TaskCycleMembership?
    ) throws -> String? {
        guard let membership else { return nil }
        return try taskCycleDomainJSON(
            membership,
            description: "task cycle membership"
        )
    }

    func taskCycleCancellationFactsJSON(
        _ facts: [TaskCycleCancellationFact]
    ) throws -> String {
        try taskCycleDomainJSON(
            facts,
            description: "task cycle cancellation facts"
        )
    }

    func taskCycleScheduleJSON(
        _ schedule: TaskCycleSchedule
    ) throws -> String {
        try taskCycleDomainJSON(
            schedule,
            description: "task cycle schedule"
        )
    }

    func taskCycleSchedule(
        from json: String
    ) throws -> TaskCycleSchedule {
        try taskCycleDomainValue(
            TaskCycleSchedule.self,
            from: json,
            description: "task cycle schedule"
        )
    }

    func taskCycleEndConditionJSON(
        _ endCondition: TaskCycleEndCondition
    ) throws -> String {
        try taskCycleDomainJSON(
            endCondition,
            description: "task cycle end condition"
        )
    }

    func taskCycleEndCondition(
        from json: String
    ) throws -> TaskCycleEndCondition {
        try taskCycleDomainValue(
            TaskCycleEndCondition.self,
            from: json,
            description: "task cycle end condition"
        )
    }

    func taskCyclePlanRevisionsJSON(
        _ revisions: [TaskCyclePlanRevision]
    ) throws -> String {
        try taskCycleDomainJSON(
            revisions,
            description: "task cycle plan revisions"
        )
    }

    func taskCyclePlanRevisions(
        from json: String
    ) throws -> [TaskCyclePlanRevision] {
        try taskCycleDomainValue(
            [TaskCyclePlanRevision].self,
            from: json,
            description: "task cycle plan revisions"
        )
    }

    func taskCycleClassificationRevisionsJSON(
        _ revisions: [TaskCycleClassificationRevision]
    ) throws -> String {
        try taskCycleDomainJSON(
            revisions,
            description: "task cycle classification revisions"
        )
    }

    func taskCycleClassificationRevisions(
        from json: String
    ) throws -> [TaskCycleClassificationRevision] {
        try taskCycleDomainValue(
            [TaskCycleClassificationRevision].self,
            from: json,
            description: "task cycle classification revisions"
        )
    }

    func taskCyclePlannedSubtasksJSON(
        _ subtasks: [PlannedSubtask]
    ) throws -> String {
        try taskCycleDomainJSON(
            subtasks,
            description: "task cycle planned subtasks"
        )
    }

    func taskCyclePlannedSubtasks(
        from json: String
    ) throws -> [PlannedSubtask] {
        try taskCycleDomainValue(
            [PlannedSubtask].self,
            from: json,
            description: "task cycle planned subtasks"
        )
    }

    func taskCycleLabelIDsJSON(
        _ labelIDs: Set<TaskLabelID>
    ) throws -> String {
        try taskCycleDomainJSON(
            labelIDs.sorted { $0.description < $1.description },
            description: "task cycle label IDs"
        )
    }

    func taskCycleLabelIDs(
        from json: String
    ) throws -> Set<TaskLabelID> {
        Set(
            try taskCycleDomainValue(
                [TaskLabelID].self,
                from: json,
                description: "task cycle label IDs"
            )
        )
    }

    func taskCycleDomainJSON(
        _ value: some Encodable,
        description: String
    ) throws -> String {
        let data = try ExactDateJSONCoding.encoder(
            nonFiniteDateDescription: "domain JSON date must be finite"
        ).encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "\(description) JSON encoding failed"
            )
        }
        return string
    }

    func taskCycleDomainValue<Value: Decodable>(
        _ type: Value.Type,
        from json: String,
        description: String
    ) throws -> Value {
        guard let data = json.data(using: .utf8) else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "\(description) JSON is not UTF-8"
            )
        }
        do {
            return try ExactDateJSONCoding.decoder(
                nonFiniteDateDescription: "domain JSON date must be finite"
            ).decode(type, from: data)
        } catch {
            throw SQLiteRepositoryError.invalidStoredValue(
                "invalid \(description) JSON: \(error.localizedDescription)"
            )
        }
    }

    func taskCycleCancellationFacts(
        from json: String
    ) throws -> [TaskCycleCancellationFact] {
        try taskCycleDomainValue(
            [TaskCycleCancellationFact].self,
            from: json,
            description: "task cycle cancellation facts"
        )
    }

    func taskCycleMembership(
        from json: String?
    ) throws -> TaskCycleMembership? {
        guard let json else { return nil }
        return try taskCycleDomainValue(
            TaskCycleMembership.self,
            from: json,
            description: "task cycle membership"
        )
    }

    func validateClassificationStateIntegrity(_ state: TaskClassificationState) throws {
        do {
            let data = try JSONEncoder().encode(state)
            _ = try JSONDecoder().decode(TaskClassificationState.self, from: data)
        } catch {
            throw SQLiteRepositoryError.invalidStoredValue(
                "classification state integrity validation failed: \(error.localizedDescription)"
            )
        }
    }

    func openDatabase() throws -> Database? {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var database: Database?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite open error"
            sqlite3_close(database)
            throw SQLiteRepositoryError.openFailed(message)
        }
        guard sqlite3_exec(database, "PRAGMA foreign_keys = ON", nil, nil, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "foreign key setup failed"
            sqlite3_close(database)
            throw SQLiteRepositoryError.openFailed(message)
        }
        return database
    }

    func replaceDatabaseContents(from sourceRepository: SQLiteEngineRepository) throws {
        let source = try sourceRepository.openDatabase()
        defer { sqlite3_close(source) }
        let destination = try openDatabase()
        defer { sqlite3_close(destination) }
        sqlite3_busy_timeout(destination, 5000)

        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw SQLiteRepositoryError.backupFailed(lastError(destination))
        }
        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw SQLiteRepositoryError.backupFailed(
                "step=\(stepResult) finish=\(finishResult): \(lastError(destination))"
            )
        }
    }

    func removeDatabaseFiles(at url: URL) {
        for path in [url.path, url.path + "-wal", url.path + "-shm"] {
            path.withCString { pointer in
                _ = unlink(pointer)
            }
        }
    }

    func applySchema(on database: Database?) throws {
        try storeRuntime.prepare(database)
    }

    func engineSnapshotGeneration(
        from database: Database?
    ) throws -> SQLiteEngineSnapshotGeneration {
        let rows = try query(
            """
            SELECT epoch, revision
            FROM engine_snapshot_generation
            WHERE id = 1
            """,
            on: database
        ) { statement in
            guard sqlite3_column_type(statement, 1) == SQLITE_INTEGER else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "engine snapshot revision is not an integer"
                )
            }
            return SQLiteEngineSnapshotGeneration(
                epoch: try uuid(statement, 0),
                revision: try uint64(statement, 1)
            )
        }
        guard rows.count == 1, let generation = rows.first else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "engine snapshot generation row is missing or duplicated"
            )
        }
        return generation
    }

    func advanceEngineSnapshotGeneration(
        in database: Database?
    ) throws {
        try run(
            """
            UPDATE engine_snapshot_generation
            SET revision = revision + 1
            WHERE id = 1 AND revision < 9223372036854775807
            """,
            on: database
        ) { _ in }
        guard sqlite3_changes(database) == 1 else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "engine snapshot generation is missing or exhausted"
            )
        }
    }

    func execute(_ sql: String, on database: Database?) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteRepositoryError.executeFailed(lastError(database))
        }
    }

    func prepare(_ sql: String, on database: Database?) throws -> Statement? {
        var statement: Statement?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteRepositoryError.prepareFailed(lastError(database))
        }
        return statement
    }

    func run(_ sql: String, on database: Database?, bind: (Statement?) throws -> Void) throws {
        let statement = try prepare(sql, on: database)
        defer { sqlite3_finalize(statement) }
        try bind(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteRepositoryError.stepFailed("\(lastError(database)) in \(sqlSummary(sql))")
        }
    }

    func sqlSummary(_ sql: String) -> String {
        for line in sql.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty == false {
                return trimmed
            }
        }
        return "SQL statement"
    }

    func query<T>(_ sql: String, on database: Database?, row: (Statement?) throws -> T) throws -> [T] {
        let statement = try prepare(sql, on: database)
        defer { sqlite3_finalize(statement) }

        return try readRows(
            from: statement,
            database: database,
            sql: sql,
            row: row
        )
    }

    func query<T>(
        _ sql: String,
        on database: Database?,
        bind: (Statement?) throws -> Void,
        row: (Statement?) throws -> T
    ) throws -> [T] {
        let statement = try prepare(sql, on: database)
        defer { sqlite3_finalize(statement) }

        try bind(statement)
        return try readRows(
            from: statement,
            database: database,
            sql: sql,
            row: row
        )
    }

    func readRows<T>(
        from statement: Statement?,
        database: Database?,
        sql: String,
        row: (Statement?) throws -> T
    ) throws -> [T] {
        var rows: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                return rows
            }
            guard result == SQLITE_ROW else {
                throw SQLiteRepositoryError.stepFailed(
                    "\(lastError(database)) in \(sqlSummary(sql))"
                )
            }
            rows.append(try row(statement))
        }
    }

    func bind(_ value: String?, to index: Int32, in statement: Statement?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    func bind(_ value: Int?, to index: Int32, in statement: Statement?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, Int64(value))
    }

    func bind(_ value: UInt64, to index: Int32, in statement: Statement?) throws {
        guard let storedValue = Int64(exactly: value) else {
            throw SQLiteRepositoryError.invalidStoredValue("classification revision exceeds SQLite INTEGER range")
        }
        sqlite3_bind_int64(statement, index, storedValue)
    }

    func bind(_ value: LocalDate, to index: Int32, in statement: Statement?) {
        bind(value.description, to: index, in: statement)
    }

    func bind(_ value: Date?, to index: Int32, in statement: Statement?) {
        bind(value.map(Self.string(from:)), to: index, in: statement)
    }

    func bindExactDate(
        _ value: Date?,
        to index: Int32,
        in statement: Statement?
    ) throws {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        let seconds = value.timeIntervalSinceReferenceDate
        guard seconds.isFinite else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "domain date must be finite"
            )
        }
        sqlite3_bind_int64(statement, index, Int64(bitPattern: seconds.bitPattern))
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

    func bindClassificationChangeDate(_ value: Date, to index: Int32, in statement: Statement?) {
        sqlite3_bind_double(statement, index, value.timeIntervalSinceReferenceDate)
    }

    func bind(_ value: UUID, to index: Int32, in statement: Statement?) {
        bind(value.uuidString, to: index, in: statement)
    }

    func string(_ statement: Statement?, _ index: Int32) throws -> String {
        guard let value = sqlite3_column_text(statement, index) else {
            throw SQLiteRepositoryError.invalidStoredValue("column \(index) is NULL")
        }
        return String(cString: value)
    }

    func optionalString(_ statement: Statement?, _ index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    func int(_ statement: Statement?, _ index: Int32) -> Int {
        Int(sqlite3_column_int64(statement, index))
    }

    func optionalInt(_ statement: Statement?, _ index: Int32) -> Int? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : int(statement, index)
    }

    func strictOptionalInt(_ statement: Statement?, _ index: Int32) throws -> Int? {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL:
            return nil
        case SQLITE_INTEGER:
            return int(statement, index)
        default:
            throw SQLiteRepositoryError.invalidStoredValue("column \(index) is not an integer")
        }
    }

    func uint64(_ statement: Statement?, _ index: Int32) throws -> UInt64 {
        let value = sqlite3_column_int64(statement, index)
        guard value >= 0 else {
            throw SQLiteRepositoryError.invalidStoredValue("negative classification revision")
        }
        return UInt64(value)
    }

    func uuid(_ statement: Statement?, _ index: Int32) throws -> UUID {
        guard let uuid = UUID(uuidString: try string(statement, index)) else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid UUID at column \(index)")
        }
        return uuid
    }

    func optionalUUID(_ statement: Statement?, _ index: Int32) throws -> UUID? {
        guard let raw = optionalString(statement, index) else { return nil }
        guard let uuid = UUID(uuidString: raw) else {
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

    func optionalDate(_ statement: Statement?, _ index: Int32) throws -> Date? {
        guard let raw = optionalString(statement, index) else { return nil }
        guard let date = Self.date(from: raw) else {
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

    func optionalExactDate(
        _ statement: Statement?,
        textIndex: Int32,
        bitsIndex: Int32
    ) throws -> Date? {
        let textIsNull = sqlite3_column_type(statement, textIndex) == SQLITE_NULL
        let bitsIsNull = sqlite3_column_type(statement, bitsIndex) == SQLITE_NULL
        guard textIsNull == bitsIsNull else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "date projection and exact bit pattern disagree"
            )
        }
        guard textIsNull == false else { return nil }
        return try validatedExactDate(
            statement,
            textIndex: textIndex,
            bitsIndex: bitsIndex
        )
    }

    func validatedExactDate(
        _ statement: Statement?,
        textIndex: Int32,
        bitsIndex: Int32
    ) throws -> Date {
        let projected = try string(statement, textIndex)
        let exact = try exactDate(statement, bitsIndex)
        guard projected == Self.string(from: exact) else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "date projection does not match exact bit pattern"
            )
        }
        return exact
    }

    func classificationChangeDate(_ statement: Statement?, _ index: Int32) throws -> Date {
        let columnType = sqlite3_column_type(statement, index)
        guard columnType == SQLITE_FLOAT || columnType == SQLITE_INTEGER else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid classification change date")
        }
        let timeInterval = sqlite3_column_double(statement, index)
        guard timeInterval.isFinite else {
            throw SQLiteRepositoryError.invalidStoredValue("non-finite classification change date")
        }
        return Date(timeIntervalSinceReferenceDate: timeInterval)
    }

    func lastError(_ database: Database?) -> String {
        database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite error"
    }
}

private extension SQLiteEngineRepository {
    func loadSnapshot(from database: Database?) throws -> NoonmarkSnapshot {
        return NoonmarkSnapshot(
            days: try loadDays(from: database),
            taskCycleSeries: try loadTaskCycleSeries(from: database),
            chains: try loadChains(from: database),
            definitions: try loadDefinitions(from: database),
            traces: try loadTraces(from: database),
            subtasks: try loadSubtasks(from: database),
            preferences: try loadPreferences(from: database),
            classifications: try loadTaskClassifications(from: database)
        )
    }

    func upsert(_ days: [Day], into database: Database?) throws {
        let sql = """
        INSERT INTO days(
            id, date, locked_at, locked_at_bits,
            review_summary, review_unfinished_reason, review_tomorrow_note,
            created_at, created_at_bits, updated_at, updated_at_bits
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(date) DO UPDATE SET
            id = excluded.id,
            locked_at = excluded.locked_at,
            locked_at_bits = excluded.locked_at_bits,
            review_summary = excluded.review_summary,
            review_unfinished_reason = excluded.review_unfinished_reason,
            review_tomorrow_note = excluded.review_tomorrow_note,
            created_at = excluded.created_at,
            created_at_bits = excluded.created_at_bits,
            updated_at = excluded.updated_at,
            updated_at_bits = excluded.updated_at_bits
        """
        for day in days {
            try run(sql, on: database) { statement in
                bind(day.id.rawValue, to: 1, in: statement)
                bind(day.date, to: 2, in: statement)
                bind(day.lockedAt, to: 3, in: statement)
                try bindExactDate(day.lockedAt, to: 4, in: statement)
                bind(day.reviewSummary, to: 5, in: statement)
                bind(day.reviewUnfinishedReason, to: 6, in: statement)
                bind(day.reviewTomorrowNote, to: 7, in: statement)
                bind(day.createdAt, to: 8, in: statement)
                try bindExactDate(day.createdAt, to: 9, in: statement)
                bind(day.updatedAt, to: 10, in: statement)
                try bindExactDate(day.updatedAt, to: 11, in: statement)
            }
        }
    }

    func upsert(
        _ seriesValues: [TaskCycleSeries],
        into database: Database?
    ) throws {
        let sql = """
        INSERT INTO task_cycle_series(
            id, title, description_text, start_date, end_date, schedule,
            end_condition_json, plan_revisions_json, planned_subtasks_json,
            category_id, label_ids_json,
            classification_revisions_json, cancellation_facts_json,
            created_at, created_at_bits, updated_at, updated_at_bits
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title = excluded.title,
            description_text = excluded.description_text,
            start_date = excluded.start_date,
            end_date = excluded.end_date,
            schedule = excluded.schedule,
            end_condition_json = excluded.end_condition_json,
            plan_revisions_json = excluded.plan_revisions_json,
            planned_subtasks_json = excluded.planned_subtasks_json,
            category_id = excluded.category_id,
            label_ids_json = excluded.label_ids_json,
            classification_revisions_json =
                excluded.classification_revisions_json,
            cancellation_facts_json = excluded.cancellation_facts_json,
            created_at = excluded.created_at,
            created_at_bits = excluded.created_at_bits,
            updated_at = excluded.updated_at,
            updated_at_bits = excluded.updated_at_bits
        """
        for series in seriesValues {
            try run(sql, on: database) { statement in
                bind(series.id.rawValue, to: 1, in: statement)
                bind(series.title, to: 2, in: statement)
                bind(series.descriptionText, to: 3, in: statement)
                bind(series.startDate, to: 4, in: statement)
                bind(series.endDate, to: 5, in: statement)
                bind(
                    try taskCycleScheduleJSON(series.schedule),
                    to: 6,
                    in: statement
                )
                bind(
                    try taskCycleEndConditionJSON(series.endCondition),
                    to: 7,
                    in: statement
                )
                bind(
                    try taskCyclePlanRevisionsJSON(series.planRevisions),
                    to: 8,
                    in: statement
                )
                bind(
                    try taskCyclePlannedSubtasksJSON(
                        series.plannedSubtasks
                    ),
                    to: 9,
                    in: statement
                )
                bind(
                    series.categoryID?.rawValue.uuidString,
                    to: 10,
                    in: statement
                )
                bind(
                    try taskCycleLabelIDsJSON(series.labelIDs),
                    to: 11,
                    in: statement
                )
                bind(
                    try taskCycleClassificationRevisionsJSON(
                        series.classificationRevisions
                    ),
                    to: 12,
                    in: statement
                )
                bind(
                    try taskCycleCancellationFactsJSON(
                        series.cancellationFacts
                    ),
                    to: 13,
                    in: statement
                )
                bind(series.createdAt, to: 14, in: statement)
                try bindExactDate(series.createdAt, to: 15, in: statement)
                bind(series.updatedAt, to: 16, in: statement)
                try bindExactDate(series.updatedAt, to: 17, in: statement)
            }
        }
    }

    func upsert(_ chains: [TaskChain], into database: Database?) throws {
        let chainSQL = """
        INSERT INTO task_chains(
            id, state, cycle_membership_json, note_entries_json,
            created_at, created_at_bits, updated_at, updated_at_bits
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            state = excluded.state,
            cycle_membership_json = excluded.cycle_membership_json,
            note_entries_json = excluded.note_entries_json,
            created_at = excluded.created_at,
            created_at_bits = excluded.created_at_bits,
            updated_at = excluded.updated_at,
            updated_at_bits = excluded.updated_at_bits
        """
        for chain in chains {
            try run(chainSQL, on: database) { statement in
                bind(chain.id.rawValue, to: 1, in: statement)
                bind(chain.state.rawValue, to: 2, in: statement)
                bind(
                    try taskCycleMembershipJSON(chain.cycleMembership),
                    to: 3,
                    in: statement
                )
                bind(try noteEntriesJSON(chain.noteEntries), to: 4, in: statement)
                bind(chain.createdAt, to: 5, in: statement)
                try bindExactDate(chain.createdAt, to: 6, in: statement)
                bind(chain.updatedAt, to: 7, in: statement)
                try bindExactDate(chain.updatedAt, to: 8, in: statement)
            }
        }
    }

    func upsert(_ definitions: [TaskDefinition], into database: Database?) throws {
        let sql = """
        INSERT INTO task_definitions(
            id, chain_id, sequence, title, description_text, planned_subtasks_json,
            created_at, created_at_bits,
            content_updated_at, content_updated_at_bits,
            superseded_at, superseded_at_bits, superseded_by_definition_id
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            chain_id = excluded.chain_id,
            sequence = excluded.sequence,
            title = excluded.title,
            description_text = excluded.description_text,
            planned_subtasks_json = excluded.planned_subtasks_json,
            created_at = excluded.created_at,
            created_at_bits = excluded.created_at_bits,
            content_updated_at = excluded.content_updated_at,
            content_updated_at_bits = excluded.content_updated_at_bits,
            superseded_at = excluded.superseded_at,
            superseded_at_bits = excluded.superseded_at_bits,
            superseded_by_definition_id = excluded.superseded_by_definition_id
        """
        for definition in definitions {
            try run(sql, on: database) { statement in
                bind(definition.id.rawValue, to: 1, in: statement)
                bind(definition.chainID.rawValue, to: 2, in: statement)
                bind(definition.sequence, to: 3, in: statement)
                bind(definition.title, to: 4, in: statement)
                bind(definition.descriptionText, to: 5, in: statement)
                bind(try plannedSubtasksJSON(definition.plannedSubtasks), to: 6, in: statement)
                bind(definition.createdAt, to: 7, in: statement)
                try bindExactDate(definition.createdAt, to: 8, in: statement)
                bind(definition.contentUpdatedAt, to: 9, in: statement)
                try bindExactDate(definition.contentUpdatedAt, to: 10, in: statement)
                bind(definition.supersededAt, to: 11, in: statement)
                try bindExactDate(definition.supersededAt, to: 12, in: statement)
                bind(nil as String?, to: 13, in: statement)
            }
        }

        let relationSQL = """
        UPDATE task_definitions
        SET superseded_by_definition_id = ?
        WHERE id = ?
        """
        for definition in definitions {
            try run(relationSQL, on: database) { statement in
                bind(definition.supersededByDefinitionID?.rawValue.uuidString, to: 1, in: statement)
                bind(definition.id.rawValue, to: 2, in: statement)
            }
        }
    }

    func upsert(_ traces: [DayTrace], into database: Database?) throws {
        let storedPendingTraceIDs = Set(
            try query(
                "SELECT id FROM day_traces WHERE status = 'pending'",
                on: database
            ) { statement in
                DayTraceID(try uuid(statement, 0))
            }
        )
        // A snapshot can atomically transfer the one pending slot from one
        // trace to another. SQLite checks the partial unique index after each
        // row, so persist existing pending traces that leave that slot before
        // persisting the incoming pending trace. Keep every other trace in the
        // validated snapshot order so first-save foreign-key dependencies do
        // not change.
        let outgoingPendingTraces = traces.filter {
            storedPendingTraceIDs.contains($0.id) && $0.status != .pending
        }
        let remainingTraces = traces.filter {
            storedPendingTraceIDs.contains($0.id) == false || $0.status == .pending
        }
        let sql = """
        INSERT INTO day_traces(
            id, chain_id, definition_id, date, status, priority, pin_order, continuation_seq, description_text, note_entries_json,
            manual_progress_percent, carried_from_trace_id, changed_to_trace_id,
            created_at, created_at_bits, content_updated_at, content_updated_at_bits,
            completed_at, completed_at_bits, settled_at, settled_at_bits,
            draft_cancellation_id, draft_cancelled_on
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            chain_id = excluded.chain_id,
            definition_id = excluded.definition_id,
            date = excluded.date,
            status = excluded.status,
            priority = excluded.priority,
            pin_order = excluded.pin_order,
            continuation_seq = excluded.continuation_seq,
            description_text = excluded.description_text,
            note_entries_json = excluded.note_entries_json,
            manual_progress_percent = excluded.manual_progress_percent,
            carried_from_trace_id = excluded.carried_from_trace_id,
            changed_to_trace_id = excluded.changed_to_trace_id,
            created_at = excluded.created_at,
            created_at_bits = excluded.created_at_bits,
            content_updated_at = excluded.content_updated_at,
            content_updated_at_bits = excluded.content_updated_at_bits,
            completed_at = excluded.completed_at,
            completed_at_bits = excluded.completed_at_bits,
            settled_at = excluded.settled_at,
            settled_at_bits = excluded.settled_at_bits,
            draft_cancellation_id = excluded.draft_cancellation_id,
            draft_cancelled_on = excluded.draft_cancelled_on
        """
        for trace in outgoingPendingTraces + remainingTraces {
            try run(sql, on: database) { statement in
                bind(trace.id.rawValue, to: 1, in: statement)
                bind(trace.chainID.rawValue, to: 2, in: statement)
                bind(trace.definitionID.rawValue, to: 3, in: statement)
                bind(trace.date, to: 4, in: statement)
                bind(trace.status.rawValue, to: 5, in: statement)
                bind(trace.priority, to: 6, in: statement)
                bind(trace.pinOrder, to: 7, in: statement)
                bind(trace.continuationSeq, to: 8, in: statement)
                bind(trace.descriptionText, to: 9, in: statement)
                bind(try noteEntriesJSON(trace.noteEntries), to: 10, in: statement)
                bind(trace.manualProgressPercent, to: 11, in: statement)
                bind(trace.carriedFromTraceID?.rawValue.uuidString, to: 12, in: statement)
                bind(nil as String?, to: 13, in: statement)
                bind(trace.createdAt, to: 14, in: statement)
                try bindExactDate(trace.createdAt, to: 15, in: statement)
                bind(trace.contentUpdatedAt, to: 16, in: statement)
                try bindExactDate(trace.contentUpdatedAt, to: 17, in: statement)
                bind(trace.completedAt, to: 18, in: statement)
                try bindExactDate(trace.completedAt, to: 19, in: statement)
                bind(trace.settledAt, to: 20, in: statement)
                try bindExactDate(trace.settledAt, to: 21, in: statement)
                bind(trace.draftCancellationID?.uuidString, to: 22, in: statement)
                bind(trace.draftCancelledOn?.description, to: 23, in: statement)
            }
        }

        let relationSQL = """
        UPDATE day_traces
        SET changed_to_trace_id = ?
        WHERE id = ?
        """
        for trace in traces {
            try run(relationSQL, on: database) { statement in
                bind(trace.changedToTraceID?.rawValue.uuidString, to: 1, in: statement)
                bind(trace.id.rawValue, to: 2, in: statement)
            }
        }
    }

    func upsert(_ subtasks: [Subtask], into database: Database?) throws {
        let sql = """
        INSERT INTO subtasks(
            id, lineage_id, trace_id, title, status, difficulty, position,
            carried_from_subtask_id,
            created_at, created_at_bits,
            updated_at, updated_at_bits,
            completed_at, completed_at_bits,
            settled_at, settled_at_bits,
            draft_cancellation_id
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            lineage_id = excluded.lineage_id,
            trace_id = excluded.trace_id,
            title = excluded.title,
            status = excluded.status,
            difficulty = excluded.difficulty,
            position = excluded.position,
            carried_from_subtask_id = excluded.carried_from_subtask_id,
            created_at = excluded.created_at,
            created_at_bits = excluded.created_at_bits,
            updated_at = excluded.updated_at,
            updated_at_bits = excluded.updated_at_bits,
            completed_at = excluded.completed_at,
            completed_at_bits = excluded.completed_at_bits,
            settled_at = excluded.settled_at,
            settled_at_bits = excluded.settled_at_bits,
            draft_cancellation_id = excluded.draft_cancellation_id
        """
        for subtask in subtasks {
            try run(sql, on: database) { statement in
                bind(subtask.id.rawValue, to: 1, in: statement)
                bind(subtask.lineageID.rawValue, to: 2, in: statement)
                bind(subtask.traceID.rawValue, to: 3, in: statement)
                bind(subtask.title, to: 4, in: statement)
                bind(subtask.status.rawValue, to: 5, in: statement)
                bind(subtask.difficulty.rawValue, to: 6, in: statement)
                bind(subtask.position, to: 7, in: statement)
                bind(nil as String?, to: 8, in: statement)
                bind(subtask.createdAt, to: 9, in: statement)
                try bindExactDate(subtask.createdAt, to: 10, in: statement)
                bind(subtask.updatedAt, to: 11, in: statement)
                try bindExactDate(subtask.updatedAt, to: 12, in: statement)
                bind(subtask.completedAt, to: 13, in: statement)
                try bindExactDate(subtask.completedAt, to: 14, in: statement)
                bind(subtask.settledAt, to: 15, in: statement)
                try bindExactDate(subtask.settledAt, to: 16, in: statement)
                bind(
                    subtask.draftCancellationID?.uuidString,
                    to: 17,
                    in: statement
                )
            }
        }

        let relationSQL = """
        UPDATE subtasks
        SET carried_from_subtask_id = ?
        WHERE id = ?
        """
        for subtask in subtasks {
            try run(relationSQL, on: database) { statement in
                bind(subtask.carriedFromSubtaskID?.rawValue.uuidString, to: 1, in: statement)
                bind(subtask.id.rawValue, to: 2, in: statement)
            }
        }
    }

    func upsertClassificationCatalog(
        _ classifications: TaskClassificationState,
        into database: Database?
    ) throws {
        let exactTimeSQL = """
        INSERT INTO classification_item_exact_times(kind, item_id, created_at, updated_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(kind, item_id) DO UPDATE SET
            created_at = excluded.created_at,
            updated_at = excluded.updated_at
        """
        let categorySQL = """
        INSERT INTO task_categories(id, name, color_hex, presentation_approval, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            color_hex = excluded.color_hex,
            presentation_approval = excluded.presentation_approval,
            created_at = excluded.created_at,
            updated_at = excluded.updated_at
        """
        for category in classifications.categories.values.sorted(by: { $0.id.description < $1.id.description }) {
            try run(categorySQL, on: database) { statement in
                bind(category.id.rawValue, to: 1, in: statement)
                bind(category.name, to: 2, in: statement)
                bind(category.colorHex, to: 3, in: statement)
                bind(category.presentationApproval.rawValue, to: 4, in: statement)
                bind(category.createdAt, to: 5, in: statement)
                bind(category.updatedAt, to: 6, in: statement)
            }
            try run(exactTimeSQL, on: database) { statement in
                bind(ClassificationItemKind.category.rawValue, to: 1, in: statement)
                bind(category.id.rawValue, to: 2, in: statement)
                bindClassificationChangeDate(category.createdAt, to: 3, in: statement)
                bindClassificationChangeDate(category.updatedAt, to: 4, in: statement)
            }
        }

        let labelSQL = """
        INSERT INTO task_labels(id, name, color_hex, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            color_hex = excluded.color_hex,
            created_at = excluded.created_at,
            updated_at = excluded.updated_at
        """
        for label in classifications.labels.values.sorted(by: { $0.id.description < $1.id.description }) {
            try run(labelSQL, on: database) { statement in
                bind(label.id.rawValue, to: 1, in: statement)
                bind(label.name, to: 2, in: statement)
                bind(label.colorHex, to: 3, in: statement)
                bind(label.createdAt, to: 4, in: statement)
                bind(label.updatedAt, to: 5, in: statement)
            }
            try run(exactTimeSQL, on: database) { statement in
                bind(ClassificationItemKind.label.rawValue, to: 1, in: statement)
                bind(label.id.rawValue, to: 2, in: statement)
                bindClassificationChangeDate(label.createdAt, to: 3, in: statement)
                bindClassificationChangeDate(label.updatedAt, to: 4, in: statement)
            }
        }
        try upsertClassificationMetadataAndNameVersions(classifications, into: database)
    }

    func upsertClassificationMetadataAndNameVersions(
        _ classifications: TaskClassificationState,
        into database: Database?
    ) throws {
        let metadataSQL = """
        INSERT INTO classification_item_metadata(
            kind, item_id, canonical_key, canonical_key_version, lifecycle
        )
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(kind, item_id) DO UPDATE SET
            canonical_key = excluded.canonical_key,
            canonical_key_version = excluded.canonical_key_version,
            lifecycle = excluded.lifecycle
        """
        var versionCollections: [(item: SQLiteClassificationItemKey, versions: [ClassificationNameVersion])] = []

        for category in classifications.categories.values.sorted(by: { $0.id.description < $1.id.description }) {
            let item = SQLiteClassificationItemKey(kind: .category, itemID: category.id.rawValue)
            try run(metadataSQL, on: database) { statement in
                bind(item.kind.rawValue, to: 1, in: statement)
                bind(item.itemID, to: 2, in: statement)
                bind(category.canonicalKey, to: 3, in: statement)
                bind(category.canonicalKeyVersion, to: 4, in: statement)
                bind(category.lifecycle.rawValue, to: 5, in: statement)
            }
            versionCollections.append((item, category.nameVersions))
        }
        for label in classifications.labels.values.sorted(by: { $0.id.description < $1.id.description }) {
            let item = SQLiteClassificationItemKey(kind: .label, itemID: label.id.rawValue)
            try run(metadataSQL, on: database) { statement in
                bind(item.kind.rawValue, to: 1, in: statement)
                bind(item.itemID, to: 2, in: statement)
                bind(label.canonicalKey, to: 3, in: statement)
                bind(label.canonicalKeyVersion, to: 4, in: statement)
                bind(label.lifecycle.rawValue, to: 5, in: statement)
            }
            versionCollections.append((item, label.nameVersions))
        }

        try upsertClassificationNameVersions(versionCollections, into: database)
    }

    func upsertClassificationNameVersions(
        _ versionCollections: [(item: SQLiteClassificationItemKey, versions: [ClassificationNameVersion])],
        into database: Database?
    ) throws {
        let storedByItem = try loadClassificationNameVersionRows(from: database)
        let storedByVersionID = Dictionary(
            uniqueKeysWithValues: storedByItem.values.flatMap { rows in
                rows.map { ($0.version.id, $0) }
            }
        )
        let statements = SQLiteNameVersionStatements(
            insert: """
            INSERT INTO classification_name_versions(
                version_id, kind, item_id, version_sequence, name,
                canonical_key, canonical_key_version, valid_from, valid_until
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            close: """
            UPDATE classification_name_versions
            SET valid_until = ?
            WHERE version_id = ?
            """,
            exactInsert: """
            INSERT INTO classification_name_version_exact_times(
                version_id, kind, item_id, valid_from, valid_until
            )
            VALUES (?, ?, ?, ?, ?)
            """,
            exactClose: """
            UPDATE classification_name_version_exact_times
            SET valid_until = ?
            WHERE version_id = ?
            """
        )

        for collection in versionCollections {
            try upsertClassificationNameVersionCollection(
                collection,
                storedRows: storedByItem[collection.item] ?? [],
                storedByVersionID: storedByVersionID,
                statements: statements,
                into: database
            )
        }
    }

    func upsertClassificationNameVersionCollection(
        _ collection: (item: SQLiteClassificationItemKey, versions: [ClassificationNameVersion]),
        storedRows: [SQLiteClassificationNameVersion],
        storedByVersionID: [UUID: SQLiteClassificationNameVersion],
        statements: SQLiteNameVersionStatements,
        into database: Database?
    ) throws {
        guard collection.versions.isEmpty == false else {
            throw SQLiteRepositoryError.invalidStoredValue("classification item has no name version")
        }
        let incomingIDs = Set(collection.versions.map(\.id))
        let storedIDs = Set(storedRows.map(\.version.id))
        guard storedIDs.isSubset(of: incomingIDs) else {
            throw SQLiteRepositoryError.invalidStoredValue("classification name versions cannot be removed")
        }

        for (sequence, version) in collection.versions.enumerated() {
            if let stored = storedByVersionID[version.id] {
                guard stored.item == collection.item else {
                    throw SQLiteRepositoryError.invalidStoredValue(
                        "classification name version is immutable: \(version.id.uuidString)"
                    )
                }
                try reconcileStoredClassificationNameVersion(
                    stored,
                    with: version,
                    sequence: sequence,
                    statements: statements,
                    in: database
                )
            } else {
                try insertClassificationNameVersion(
                    version,
                    for: collection.item,
                    sequence: sequence,
                    statements: statements,
                    into: database
                )
            }
        }
    }

    func reconcileStoredClassificationNameVersion(
        _ stored: SQLiteClassificationNameVersion,
        with version: ClassificationNameVersion,
        sequence: Int,
        statements: SQLiteNameVersionStatements,
        in database: Database?
    ) throws {
        guard stored.sequence == sequence,
              classificationNameVersionFactsAreEqual(stored.version, version)
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "classification name version is immutable: \(version.id.uuidString)"
            )
        }
        switch (stored.version.validUntil, version.validUntil) {
        case (nil, nil):
            break
        case let (nil, validUntil?):
            try run(statements.close, on: database) { statement in
                bind(validUntil, to: 1, in: statement)
                bind(version.id, to: 2, in: statement)
            }
            try run(statements.exactClose, on: database) { statement in
                bindClassificationChangeDate(validUntil, to: 1, in: statement)
                bind(version.id, to: 2, in: statement)
            }
        case let (storedValidUntil?, validUntil?) where storedValidUntil == validUntil:
            break
        default:
            throw SQLiteRepositoryError.invalidStoredValue(
                "classification name version validity is immutable: \(version.id.uuidString)"
            )
        }
    }

    func insertClassificationNameVersion(
        _ version: ClassificationNameVersion,
        for item: SQLiteClassificationItemKey,
        sequence: Int,
        statements: SQLiteNameVersionStatements,
        into database: Database?
    ) throws {
        try run(statements.insert, on: database) { statement in
            bind(version.id, to: 1, in: statement)
            bind(item.kind.rawValue, to: 2, in: statement)
            bind(item.itemID, to: 3, in: statement)
            bind(sequence, to: 4, in: statement)
            bind(version.name, to: 5, in: statement)
            bind(version.canonicalKey, to: 6, in: statement)
            bind(version.canonicalKeyVersion, to: 7, in: statement)
            bind(version.validFrom, to: 8, in: statement)
            bind(version.validUntil, to: 9, in: statement)
        }
        try run(statements.exactInsert, on: database) { statement in
            bind(version.id, to: 1, in: statement)
            bind(item.kind.rawValue, to: 2, in: statement)
            bind(item.itemID, to: 3, in: statement)
            bindClassificationChangeDate(version.validFrom, to: 4, in: statement)
            if let validUntil = version.validUntil {
                bindClassificationChangeDate(validUntil, to: 5, in: statement)
            } else {
                sqlite3_bind_null(statement, 5)
            }
        }
    }

    func upsertClassificationRelations(
        _ classifications: TaskClassificationState,
        chainIDs: [TaskChainID],
        into database: Database?
    ) throws {
        let transition = try classificationRelationTransition(
            classifications,
            chainIDs: chainIDs,
            from: database
        )
        if try classificationRelationRevisionIsIdempotent(
            classifications.revision,
            transition: transition,
            in: database
        ) {
            return
        }
        try validateRemovedClassificationRelations(classifications, transition: transition)
        try deleteClassificationRelations(transition.removedKeys, from: database)
        try insertClassificationChainStates(transition, into: database)
        try reconcileCurrentClassificationRelations(transition, in: database)
    }

    func classificationRelationTransition(
        _ classifications: TaskClassificationState,
        chainIDs: [TaskChainID],
        from database: Database?
    ) throws -> SQLiteClassificationRelationTransition {
        let knownChainIDs = Set(chainIDs)
        let incomingChainStates = Set(classifications.currentByChainID.keys)
        guard incomingChainStates.isSubset(of: knownChainIDs) else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "current classification belongs to an unknown task chain"
            )
        }
        let incomingFacts = try currentClassificationRelationFacts(in: classifications)
        let storedFacts = try loadCurrentClassificationRelationFacts(from: database)
        let storedRelationKeys = try loadStoredCurrentClassificationRelationKeys(from: database)
        guard Set(storedFacts.keys) == storedRelationKeys else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "stored current classification relations and provenance are inconsistent"
            )
        }
        let storedChainStates = Set(
            try query(
                "SELECT chain_id FROM classification_current_chain_states ORDER BY chain_id",
                on: database
            ) { statement in
                TaskChainID(try uuid(statement, 0))
            }
        )
        guard storedRelationKeys.allSatisfy({ storedChainStates.contains($0.chainID) }),
              storedChainStates.isSubset(of: incomingChainStates)
        else {
            throw SQLiteRepositoryError.invalidStoredValue("current classification chain state cannot be removed")
        }

        return SQLiteClassificationRelationTransition(
            incomingChainStates: incomingChainStates,
            incomingFacts: incomingFacts,
            storedFacts: storedFacts,
            storedChainStates: storedChainStates
        )
    }

    func classificationRelationRevisionIsIdempotent(
        _ incomingRevision: UInt64,
        transition: SQLiteClassificationRelationTransition,
        in database: Database?
    ) throws -> Bool {
        let hasStoredRevision = try classificationRevisionIsStored(in: database)
        let storedRevision = try loadClassificationRevision(from: database)
        guard hasStoredRevision == false || incomingRevision >= storedRevision else {
            throw SQLiteRepositoryError.invalidStoredValue("classification revision cannot move backwards")
        }
        if hasStoredRevision, incomingRevision == storedRevision {
            guard transition.incomingChainStates == transition.storedChainStates,
                  classificationRelationFactMapsAreEqual(transition.incomingFacts, transition.storedFacts)
            else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "current classification changed without advancing its revision"
                )
            }
            return true
        }
        return false
    }

    func validateRemovedClassificationRelations(
        _ classifications: TaskClassificationState,
        transition: SQLiteClassificationRelationTransition
    ) throws {
        for key in transition.removedKeys {
            guard let fact = transition.storedFacts[key],
                  classifications.relationHistory.contains(where: {
                      classificationRelationHistory($0, closes: fact)
                  })
            else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "current classification relation was removed without append-only history"
                )
            }
        }
    }

    func deleteClassificationRelations(
        _ keys: Set<SQLiteClassificationRelationKey>,
        from database: Database?
    ) throws {
        let deleteFactSQL = """
        DELETE FROM classification_current_relation_facts
        WHERE kind = ? AND chain_id = ? AND item_id = ?
        """
        for key in keys.sorted(by: classificationRelationKeyOrder) {
            try run(deleteFactSQL, on: database) { statement in
                bind(key.kind.rawValue, to: 1, in: statement)
                bind(key.chainID.rawValue, to: 2, in: statement)
                bind(key.itemID, to: 3, in: statement)
            }
            switch key.kind {
            case .category:
                try run(
                    "DELETE FROM task_chain_categories WHERE chain_id = ? AND category_id = ?",
                    on: database
                ) { statement in
                    bind(key.chainID.rawValue, to: 1, in: statement)
                    bind(key.itemID, to: 2, in: statement)
                }
            case .label:
                try run(
                    "DELETE FROM task_chain_label_relations WHERE chain_id = ? AND label_id = ?",
                    on: database
                ) { statement in
                    bind(key.chainID.rawValue, to: 1, in: statement)
                    bind(key.itemID, to: 2, in: statement)
                }
            }
        }
    }

    func insertClassificationChainStates(
        _ transition: SQLiteClassificationRelationTransition,
        into database: Database?
    ) throws {
        let insertChainStateSQL = "INSERT INTO classification_current_chain_states(chain_id) VALUES (?)"
        for chainID in transition.incomingChainStates.subtracting(transition.storedChainStates).sorted(by: {
            $0.description < $1.description
        }) {
            try run(insertChainStateSQL, on: database) { statement in
                bind(chainID.rawValue, to: 1, in: statement)
            }
        }
    }

    func reconcileCurrentClassificationRelations(
        _ transition: SQLiteClassificationRelationTransition,
        in database: Database?
    ) throws {
        for key in transition.incomingFacts.keys.sorted(by: classificationRelationKeyOrder) {
            guard let incoming = transition.incomingFacts[key] else { continue }
            if let stored = transition.storedFacts[key] {
                guard incoming.revision >= stored.revision else {
                    throw SQLiteRepositoryError.invalidStoredValue(
                        "current classification relation revision cannot move backwards"
                    )
                }
                if incoming.revision == stored.revision {
                    guard classificationRelationFactsAreEqual(incoming, stored) else {
                        throw SQLiteRepositoryError.invalidStoredValue(
                            "current classification relation content conflicts at the same revision"
                        )
                    }
                } else {
                    try updateCurrentClassificationRelationFact(incoming, in: database)
                }
                continue
            }

            switch key.kind {
            case .category:
                try run(
                    "INSERT INTO task_chain_categories(chain_id, category_id) VALUES (?, ?)",
                    on: database
                ) { statement in
                    bind(key.chainID.rawValue, to: 1, in: statement)
                    bind(key.itemID, to: 2, in: statement)
                }
            case .label:
                try run(
                    "INSERT INTO task_chain_label_relations(chain_id, label_id) VALUES (?, ?)",
                    on: database
                ) { statement in
                    bind(key.chainID.rawValue, to: 1, in: statement)
                    bind(key.itemID, to: 2, in: statement)
                }
            }
            try insertCurrentClassificationRelationFact(incoming, into: database)
        }
    }

    func currentClassificationRelationFacts(
        in classifications: TaskClassificationState
    ) throws -> [SQLiteClassificationRelationKey: SQLiteClassificationRelationFact] {
        var facts: [SQLiteClassificationRelationKey: SQLiteClassificationRelationFact] = [:]
        for (chainID, current) in classifications.currentByChainID {
            if let category = current.category {
                let categoryID = category.categoryID
                guard classifications.categories[categoryID]?.lifecycle != .merged,
                      classifications.categoryDeletionTombstones[categoryID] == nil,
                      category.revision <= classifications.revision
                else {
                    throw SQLiteRepositoryError.invalidStoredValue("invalid current task category relation")
                }
                let key = SQLiteClassificationRelationKey(
                    kind: .category,
                    chainID: chainID,
                    itemID: categoryID.description
                )
                facts[key] = SQLiteClassificationRelationFact(
                    key: key,
                    source: category.source,
                    decisionID: category.decisionID,
                    createdAt: category.createdAt,
                    updatedAt: category.updatedAt,
                    revision: category.revision
                )
            }
            for label in current.labels {
                let labelID = label.labelID
                guard classifications.labels[labelID]?.lifecycle != .merged,
                      classifications.labelDeletionTombstones[labelID] == nil,
                      label.revision <= classifications.revision
                else {
                    throw SQLiteRepositoryError.invalidStoredValue("invalid current task label relation")
                }
                let key = SQLiteClassificationRelationKey(
                    kind: .label,
                    chainID: chainID,
                    itemID: labelID.description
                )
                guard facts[key] == nil else {
                    throw SQLiteRepositoryError.invalidStoredValue("duplicate current task label relation")
                }
                facts[key] = SQLiteClassificationRelationFact(
                    key: key,
                    source: label.source,
                    decisionID: label.decisionID,
                    createdAt: label.createdAt,
                    updatedAt: label.updatedAt,
                    revision: label.revision
                )
            }
        }
        return facts
    }

    func loadStoredCurrentClassificationRelationKeys(
        from database: Database?
    ) throws -> Set<SQLiteClassificationRelationKey> {
        let categoryKeys = try query(
            "SELECT chain_id, category_id FROM task_chain_categories ORDER BY chain_id",
            on: database
        ) { statement in
            SQLiteClassificationRelationKey(
                kind: .category,
                chainID: TaskChainID(try uuid(statement, 0)),
                itemID: TaskCategoryID(try uuid(statement, 1)).description
            )
        }
        let labelKeys = try query(
            "SELECT chain_id, label_id FROM task_chain_label_relations ORDER BY chain_id, label_id",
            on: database
        ) { statement in
            SQLiteClassificationRelationKey(
                kind: .label,
                chainID: TaskChainID(try uuid(statement, 0)),
                itemID: TaskLabelID(try uuid(statement, 1)).description
            )
        }
        return Set(categoryKeys + labelKeys)
    }

    func insertCurrentClassificationRelationFact(
        _ fact: SQLiteClassificationRelationFact,
        into database: Database?
    ) throws {
        let sql = """
        INSERT INTO classification_current_relation_facts(
            kind, chain_id, item_id,
            source_kind, source_session_id, source_draft_id, source_draft_version,
            source_evidence_id, source_from_chain_id, source_reason,
            decision_id, created_at, updated_at, revision
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        try run(sql, on: database) { statement in
            try bindCurrentClassificationRelationFact(fact, to: statement)
        }
    }

    func updateCurrentClassificationRelationFact(
        _ fact: SQLiteClassificationRelationFact,
        in database: Database?
    ) throws {
        let source = classificationSourceStorage(fact.source)
        let sql = """
        UPDATE classification_current_relation_facts
        SET source_kind = ?, source_session_id = ?, source_draft_id = ?,
            source_draft_version = ?, source_evidence_id = ?, source_from_chain_id = ?,
            source_reason = ?, decision_id = ?,
            created_at = ?, updated_at = ?, revision = ?
        WHERE kind = ? AND chain_id = ? AND item_id = ?
        """
        try run(sql, on: database) { statement in
            bind(source.kind, to: 1, in: statement)
            bind(source.sessionID?.uuidString, to: 2, in: statement)
            bind(source.draftID?.uuidString, to: 3, in: statement)
            bind(source.draftVersion, to: 4, in: statement)
            bind(source.evidenceID?.uuidString, to: 5, in: statement)
            bind(source.fromChainID?.rawValue.uuidString, to: 6, in: statement)
            bind(source.reason, to: 7, in: statement)
            bind(fact.decisionID?.uuidString, to: 8, in: statement)
            bindClassificationChangeDate(fact.createdAt, to: 9, in: statement)
            bindClassificationChangeDate(fact.updatedAt, to: 10, in: statement)
            try bind(fact.revision, to: 11, in: statement)
            bind(fact.key.kind.rawValue, to: 12, in: statement)
            bind(fact.key.chainID.rawValue, to: 13, in: statement)
            bind(fact.key.itemID, to: 14, in: statement)
        }
    }

    func bindCurrentClassificationRelationFact(
        _ fact: SQLiteClassificationRelationFact,
        to statement: Statement?
    ) throws {
        bind(fact.key.kind.rawValue, to: 1, in: statement)
        bind(fact.key.chainID.rawValue, to: 2, in: statement)
        bind(fact.key.itemID, to: 3, in: statement)
        _ = bindClassificationSource(fact.source, startingAt: 4, in: statement)
        bind(fact.decisionID?.uuidString, to: 11, in: statement)
        bindClassificationChangeDate(fact.createdAt, to: 12, in: statement)
        bindClassificationChangeDate(fact.updatedAt, to: 13, in: statement)
        try bind(fact.revision, to: 14, in: statement)
    }

    func classificationRevisionIsStored(in database: Database?) throws -> Bool {
        try query("SELECT COUNT(*) FROM classification_state WHERE id = 1", on: database) { statement in
            int(statement, 0)
        }.first == 1
    }

    func classificationRelationFactMapsAreEqual(
        _ lhs: [SQLiteClassificationRelationKey: SQLiteClassificationRelationFact],
        _ rhs: [SQLiteClassificationRelationKey: SQLiteClassificationRelationFact]
    ) -> Bool {
        lhs.count == rhs.count && lhs.allSatisfy { key, value in
            rhs[key].map { classificationRelationFactsAreEqual(value, $0) } ?? false
        }
    }

    func classificationRelationFactsAreEqual(
        _ lhs: SQLiteClassificationRelationFact,
        _ rhs: SQLiteClassificationRelationFact
    ) -> Bool {
        lhs.key == rhs.key
            && lhs.source == rhs.source
            && lhs.decisionID == rhs.decisionID
            && lhs.createdAt == rhs.createdAt
            && lhs.updatedAt == rhs.updatedAt
            && lhs.revision == rhs.revision
    }

    func classificationRelationHistory(
        _ history: ClassificationRelationHistoryEntry,
        closes fact: SQLiteClassificationRelationFact
    ) -> Bool {
        history.kind == fact.key.kind
            && history.chainID == fact.key.chainID
            && history.itemID == fact.key.itemID
            && history.originSource == fact.source
            && history.originDecisionID == fact.decisionID
            && history.createdAt == fact.createdAt
            && history.createdRevision == fact.revision
            && history.removedRevision > fact.revision
    }

    func classificationRelationKeyOrder(
        _ lhs: SQLiteClassificationRelationKey,
        _ rhs: SQLiteClassificationRelationKey
    ) -> Bool {
        if lhs.kind != rhs.kind {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        if lhs.chainID != rhs.chainID {
            return lhs.chainID.description < rhs.chainID.description
        }
        return lhs.itemID < rhs.itemID
    }

    func stageClassificationAuditSequenceProjection(
        _ projection: SQLiteAuditSequenceProjection,
        canonicalCount: Int,
        storedCount: Int,
        in database: Database?
    ) throws {
        guard canonicalCount <= Int.max - storedCount else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "classification audit sequence projection exceeds the supported range"
            )
        }
        guard storedCount > 0 else { return }
        try run(
            """
            UPDATE \(projection.tableName)
            SET \(projection.sequenceColumn) = \(projection.sequenceColumn) + ?
            """,
            on: database
        ) { statement in
            bind(canonicalCount, to: 1, in: statement)
        }
    }

    func restoreClassificationAuditSequenceProjection(
        _ projection: SQLiteAuditSequenceProjection,
        canonicalIDs: [UUID],
        storedIDs: Set<UUID>,
        in database: Database?
    ) throws {
        let sql = """
        UPDATE \(projection.tableName)
        SET \(projection.sequenceColumn) = ?
        WHERE \(projection.identityColumn) = ?
        """
        for (sequence, id) in canonicalIDs.enumerated() where storedIDs.contains(id) {
            try run(sql, on: database) { statement in
                bind(sequence, to: 1, in: statement)
                bind(id, to: 2, in: statement)
            }
        }
    }

    func insertClassificationRelationHistory(
        _ classifications: TaskClassificationState,
        into database: Database?
    ) throws {
        let incoming = classifications.relationHistory
        try validateClassificationRelationHistory(incoming, in: classifications)

        let stored = try loadClassificationRelationHistory(from: database)
        let incomingByID = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })
        let storedByID = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
        try validateStoredClassificationRelationHistory(stored, incomingByID: incomingByID)

        let canonicalIDs = incoming.map(\.id)
        let storedIDs = stored.map(\.id)
        let requiresSequenceRebuild = Array(canonicalIDs.prefix(storedIDs.count)) != storedIDs
        if requiresSequenceRebuild {
            try stageClassificationAuditSequenceProjection(
                .relationHistory,
                canonicalCount: incoming.count,
                storedCount: stored.count,
                in: database
            )
        }
        let sql = """
        INSERT INTO classification_relation_history(
            history_id, history_sequence, kind, chain_id, item_id,
            origin_source_kind, origin_source_session_id, origin_source_draft_id,
            origin_source_draft_version, origin_source_evidence_id, origin_source_from_chain_id,
            origin_source_reason, origin_decision_id,
            created_at, created_revision,
            removed_source_kind, removed_source_session_id, removed_source_draft_id,
            removed_source_draft_version, removed_source_evidence_id, removed_source_from_chain_id,
            removed_source_reason, removed_decision_id,
            removed_at, removed_revision
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        for (sequence, entry) in incoming.enumerated() where storedByID[entry.id] == nil {
            try run(sql, on: database) { statement in
                bind(entry.id, to: 1, in: statement)
                bind(sequence, to: 2, in: statement)
                bind(entry.kind.rawValue, to: 3, in: statement)
                bind(entry.chainID.rawValue, to: 4, in: statement)
                bind(entry.itemID, to: 5, in: statement)
                _ = bindClassificationSource(entry.originSource, startingAt: 6, in: statement)
                bind(entry.originDecisionID?.uuidString, to: 13, in: statement)
                bindClassificationChangeDate(entry.createdAt, to: 14, in: statement)
                try bind(entry.createdRevision, to: 15, in: statement)
                _ = bindClassificationSource(entry.removedBySource, startingAt: 16, in: statement)
                bind(entry.removedByDecisionID?.uuidString, to: 23, in: statement)
                bindClassificationChangeDate(entry.removedAt, to: 24, in: statement)
                try bind(entry.removedRevision, to: 25, in: statement)
            }
        }
        if requiresSequenceRebuild {
            try restoreClassificationAuditSequenceProjection(
                .relationHistory,
                canonicalIDs: canonicalIDs,
                storedIDs: Set(storedByID.keys),
                in: database
            )
        }
    }

    func validateClassificationRelationHistory(
        _ history: [ClassificationRelationHistoryEntry],
        in classifications: TaskClassificationState
    ) throws {
        guard Set(history.map(\.id)).count == history.count else {
            throw SQLiteRepositoryError.invalidStoredValue("duplicate classification relation history identity")
        }
        for entry in history {
            guard entry.createdAt <= entry.removedAt,
                  entry.createdRevision < entry.removedRevision,
                  entry.removedRevision <= classifications.revision
            else {
                throw SQLiteRepositoryError.invalidStoredValue("invalid classification relation history interval")
            }
            try validateClassificationRelationHistoryItem(entry, in: classifications)
        }
    }

    func validateClassificationRelationHistoryItem(
        _ entry: ClassificationRelationHistoryEntry,
        in classifications: TaskClassificationState
    ) throws {
        guard let rawID = UUID(uuidString: entry.itemID) else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "classification relation history references an invalid item identity"
            )
        }
        let itemExists = switch entry.kind {
        case .category:
            classifications.categories[TaskCategoryID(rawID)] != nil
        case .label:
            classifications.labels[TaskLabelID(rawID)] != nil
        }
        guard itemExists else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "classification relation history references a missing \(entry.kind.rawValue)"
            )
        }
    }

    func validateStoredClassificationRelationHistory(
        _ stored: [ClassificationRelationHistoryEntry],
        incomingByID: [UUID: ClassificationRelationHistoryEntry]
    ) throws {
        guard incomingByID.count >= stored.count else {
            throw SQLiteRepositoryError.invalidStoredValue("classification relation history cannot be removed")
        }
        for storedEntry in stored {
            guard let incomingEntry = incomingByID[storedEntry.id] else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "classification relation history cannot be removed: \(storedEntry.id.uuidString)"
                )
            }
            guard incomingEntry == storedEntry else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "classification relation history is immutable: \(storedEntry.id.uuidString)"
                )
            }
        }
    }

    func insertClassificationMerges(
        _ classifications: TaskClassificationState,
        into database: Database?
    ) throws {
        let stored = try loadClassificationMerges(from: database)
        guard stored.categories.allSatisfy({ classifications.categoryMerges[$0.key] == $0.value }),
              stored.labels.allSatisfy({ classifications.labelMerges[$0.key] == $0.value })
        else {
            throw SQLiteRepositoryError.invalidStoredValue("classification merge facts are immutable")
        }
        let allMergeIDs = classifications.categoryMerges.values.map(\.id)
            + classifications.labelMerges.values.map(\.id)
        guard Set(allMergeIDs).count == allMergeIDs.count else {
            throw SQLiteRepositoryError.invalidStoredValue("duplicate classification merge identity")
        }

        let sql = """
        INSERT INTO classification_merges(
            kind, source_id, merge_id, target_id, merged_at, revision, change_record_id
        )
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """
        for (sourceID, merge) in classifications.categoryMerges.sorted(by: {
            $0.key.description < $1.key.description
        }) where stored.categories[sourceID] == nil {
            try run(sql, on: database) { statement in
                bind(ClassificationItemKind.category.rawValue, to: 1, in: statement)
                bind(sourceID.rawValue, to: 2, in: statement)
                bind(merge.id, to: 3, in: statement)
                bind(merge.targetID.rawValue, to: 4, in: statement)
                bindClassificationChangeDate(merge.mergedAt, to: 5, in: statement)
                try bind(merge.revision, to: 6, in: statement)
                bind(merge.changeRecordID, to: 7, in: statement)
            }
        }
        for (sourceID, merge) in classifications.labelMerges.sorted(by: {
            $0.key.description < $1.key.description
        }) where stored.labels[sourceID] == nil {
            try run(sql, on: database) { statement in
                bind(ClassificationItemKind.label.rawValue, to: 1, in: statement)
                bind(sourceID.rawValue, to: 2, in: statement)
                bind(merge.id, to: 3, in: statement)
                bind(merge.targetID.rawValue, to: 4, in: statement)
                bindClassificationChangeDate(merge.mergedAt, to: 5, in: statement)
                try bind(merge.revision, to: 6, in: statement)
                bind(merge.changeRecordID, to: 7, in: statement)
            }
        }
    }

    func insertClassificationDeletionTombstonesAndPurgeCatalog(
        _ classifications: TaskClassificationState,
        into database: Database?
    ) throws {
        let stored = try loadClassificationDeletionTombstones(from: database)
        guard stored.categories.allSatisfy({ classifications.categoryDeletionTombstones[$0.key] == $0.value }),
              stored.labels.allSatisfy({ classifications.labelDeletionTombstones[$0.key] == $0.value })
        else {
            throw SQLiteRepositoryError.invalidStoredValue("classification deletion tombstones are immutable")
        }
        let allTombstoneIDs = classifications.categoryDeletionTombstones.values.map(\.id)
            + classifications.labelDeletionTombstones.values.map(\.id)
        guard Set(allTombstoneIDs).count == allTombstoneIDs.count else {
            throw SQLiteRepositoryError.invalidStoredValue("duplicate classification deletion tombstone identity")
        }
        for (id, tombstone) in classifications.categoryDeletionTombstones {
            guard tombstone.itemID == id, classifications.categories[id] == nil else {
                throw SQLiteRepositoryError.invalidStoredValue("deleted task category identity is live or mismatched")
            }
        }
        for (id, tombstone) in classifications.labelDeletionTombstones {
            guard tombstone.itemID == id, classifications.labels[id] == nil else {
                throw SQLiteRepositoryError.invalidStoredValue("deleted task label identity is live or mismatched")
            }
        }

        let insertSQL = """
        INSERT INTO classification_deletion_tombstones(
            kind, item_id, tombstone_id, deleted_at, revision, change_record_id
        )
        VALUES (?, ?, ?, ?, ?, ?)
        """
        for (id, tombstone) in classifications.categoryDeletionTombstones.sorted(by: {
            $0.key.description < $1.key.description
        }) where stored.categories[id] == nil {
            try run(insertSQL, on: database) { statement in
                bind(ClassificationItemKind.category.rawValue, to: 1, in: statement)
                bind(id.rawValue, to: 2, in: statement)
                bind(tombstone.id, to: 3, in: statement)
                bindClassificationChangeDate(tombstone.deletedAt, to: 4, in: statement)
                try bind(tombstone.revision, to: 5, in: statement)
                bind(tombstone.changeRecordID, to: 6, in: statement)
            }
        }
        for (id, tombstone) in classifications.labelDeletionTombstones.sorted(by: {
            $0.key.description < $1.key.description
        }) where stored.labels[id] == nil {
            try run(insertSQL, on: database) { statement in
                bind(ClassificationItemKind.label.rawValue, to: 1, in: statement)
                bind(id.rawValue, to: 2, in: statement)
                bind(tombstone.id, to: 3, in: statement)
                bindClassificationChangeDate(tombstone.deletedAt, to: 4, in: statement)
                try bind(tombstone.revision, to: 5, in: statement)
                bind(tombstone.changeRecordID, to: 6, in: statement)
            }
        }

        let deleteNameExactTimesSQL = """
        DELETE FROM classification_name_version_exact_times WHERE kind = ? AND item_id = ?
        """
        let deleteNamesSQL = "DELETE FROM classification_name_versions WHERE kind = ? AND item_id = ?"
        let deleteItemExactTimeSQL = "DELETE FROM classification_item_exact_times WHERE kind = ? AND item_id = ?"
        let deleteMetadataSQL = "DELETE FROM classification_item_metadata WHERE kind = ? AND item_id = ?"
        let deleteCategorySQL = "DELETE FROM task_categories WHERE id = ?"
        let deleteLabelSQL = "DELETE FROM task_labels WHERE id = ?"
        for id in classifications.categoryDeletionTombstones.keys.sorted(by: {
            $0.description < $1.description
        }) {
            try run(deleteNameExactTimesSQL, on: database) { statement in
                bind(ClassificationItemKind.category.rawValue, to: 1, in: statement)
                bind(id.rawValue, to: 2, in: statement)
            }
            try run(deleteNamesSQL, on: database) { statement in
                bind(ClassificationItemKind.category.rawValue, to: 1, in: statement)
                bind(id.rawValue, to: 2, in: statement)
            }
            try run(deleteItemExactTimeSQL, on: database) { statement in
                bind(ClassificationItemKind.category.rawValue, to: 1, in: statement)
                bind(id.rawValue, to: 2, in: statement)
            }
            try run(deleteMetadataSQL, on: database) { statement in
                bind(ClassificationItemKind.category.rawValue, to: 1, in: statement)
                bind(id.rawValue, to: 2, in: statement)
            }
            try run(deleteCategorySQL, on: database) { statement in
                bind(id.rawValue, to: 1, in: statement)
            }
        }
        for id in classifications.labelDeletionTombstones.keys.sorted(by: {
            $0.description < $1.description
        }) {
            try run(deleteNameExactTimesSQL, on: database) { statement in
                bind(ClassificationItemKind.label.rawValue, to: 1, in: statement)
                bind(id.rawValue, to: 2, in: statement)
            }
            try run(deleteNamesSQL, on: database) { statement in
                bind(ClassificationItemKind.label.rawValue, to: 1, in: statement)
                bind(id.rawValue, to: 2, in: statement)
            }
            try run(deleteItemExactTimeSQL, on: database) { statement in
                bind(ClassificationItemKind.label.rawValue, to: 1, in: statement)
                bind(id.rawValue, to: 2, in: statement)
            }
            try run(deleteMetadataSQL, on: database) { statement in
                bind(ClassificationItemKind.label.rawValue, to: 1, in: statement)
                bind(id.rawValue, to: 2, in: statement)
            }
            try run(deleteLabelSQL, on: database) { statement in
                bind(id.rawValue, to: 1, in: statement)
            }
        }
    }

    func insertClassificationSnapshotEvents(
        _ classifications: TaskClassificationState,
        into database: Database?
    ) throws {
        let storedEvents = try loadPersistedTraceClassificationEvents(from: database)
        let storedEventsByID = Dictionary(
            uniqueKeysWithValues: storedEvents.values.flatMap { events in
                events.map { ($0.snapshot.id, $0) }
            }
        )
        let headerSQL = """
        INSERT INTO trace_classification_snapshot_events(
            event_id, trace_id, event_sequence, status, captured_at, revision
        )
        VALUES (?, ?, ?, ?, ?, ?)
        """
        let categorySQL = """
        INSERT INTO trace_classification_event_categories(
            event_id, category_id, name, color_hex, presentation_approval
        )
        VALUES (?, ?, ?, ?, ?)
        """
        let labelSQL = """
        INSERT INTO trace_classification_event_labels(event_id, label_id, name, color_hex)
        VALUES (?, ?, ?, ?)
        """
        let finalizationSQL = """
        INSERT INTO trace_classification_snapshot_event_finalizations(
            event_id, category_count, label_count
        )
        VALUES (?, ?, ?)
        """

        for (traceID, events) in classifications.snapshotEventsByTraceID.sorted(by: {
            $0.key.description < $1.key.description
        }) {
            for (sequence, snapshot) in events.enumerated() {
                guard snapshot.traceID == traceID else {
                    throw SQLiteRepositoryError.invalidStoredValue(
                        "trace classification event belongs to a different trace"
                    )
                }
                if let stored = storedEventsByID[snapshot.id] {
                    guard stored.sequence == sequence,
                          classificationSnapshotsAreEqual(stored.snapshot, snapshot)
                    else {
                        throw SQLiteRepositoryError.invalidStoredValue(
                            "trace classification event is immutable: \(snapshot.id.uuidString)"
                        )
                    }
                    continue
                }

                try run(headerSQL, on: database) { statement in
                    bind(snapshot.id, to: 1, in: statement)
                    bind(snapshot.traceID.rawValue, to: 2, in: statement)
                    bind(sequence, to: 3, in: statement)
                    bind(snapshot.status.rawValue, to: 4, in: statement)
                    bindClassificationChangeDate(snapshot.capturedAt, to: 5, in: statement)
                    try bind(snapshot.revision, to: 6, in: statement)
                }
                if let category = snapshot.category {
                    try run(categorySQL, on: database) { statement in
                        bind(snapshot.id, to: 1, in: statement)
                        bind(category.id.rawValue, to: 2, in: statement)
                        bind(category.name, to: 3, in: statement)
                        bind(category.colorHex, to: 4, in: statement)
                        bind(category.presentationApproval.rawValue, to: 5, in: statement)
                    }
                }
                for label in snapshot.labels.sorted(by: { $0.id.description < $1.id.description }) {
                    try run(labelSQL, on: database) { statement in
                        bind(snapshot.id, to: 1, in: statement)
                        bind(label.id.rawValue, to: 2, in: statement)
                        bind(label.name, to: 3, in: statement)
                        bind(label.colorHex, to: 4, in: statement)
                    }
                }
                try run(finalizationSQL, on: database) { statement in
                    bind(snapshot.id, to: 1, in: statement)
                    bind(snapshot.category == nil ? 0 : 1, to: 2, in: statement)
                    bind(snapshot.labels.count, to: 3, in: statement)
                }
            }
        }
    }

    func upsertClassificationRevision(_ revision: UInt64, into database: Database?) throws {
        let hasStoredRevision = try classificationRevisionIsStored(in: database)
        let storedRevision = try loadClassificationRevision(from: database)
        guard hasStoredRevision == false || revision >= storedRevision else {
            throw SQLiteRepositoryError.invalidStoredValue("classification revision cannot move backwards")
        }
        guard hasStoredRevision == false || revision != storedRevision else { return }
        let sql = """
        INSERT INTO classification_state(id, revision)
        VALUES (1, ?)
        ON CONFLICT(id) DO UPDATE SET revision = excluded.revision
        """
        try run(sql, on: database) { statement in
            try bind(revision, to: 1, in: statement)
        }
    }

    func insertClassificationChangeRecords(
        _ classifications: TaskClassificationState,
        into database: Database?
    ) throws {
        let incomingRecords = classifications.changeRecords
        guard Set(incomingRecords.map(\.id)).count == incomingRecords.count,
              Set(incomingRecords.map(\.planID)).count == incomingRecords.count,
              Set(incomingRecords.map(\.interactionID)).count == incomingRecords.count
        else {
            throw SQLiteRepositoryError.invalidStoredValue("duplicate classification change record identity")
        }

        let storedRecords = try loadClassificationChangeRecords(from: database)
        let incomingByID = Dictionary(uniqueKeysWithValues: incomingRecords.map { ($0.id, $0) })
        let storedByID = Dictionary(uniqueKeysWithValues: storedRecords.map { ($0.id, $0) })
        guard incomingRecords.count >= storedRecords.count else {
            throw SQLiteRepositoryError.invalidStoredValue("classification change records cannot be removed")
        }
        for storedRecord in storedRecords {
            guard let incomingRecord = incomingByID[storedRecord.id] else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "classification change record cannot be removed: \(storedRecord.id.uuidString)"
                )
            }
            guard classificationChangeRecordFactsAreEqual(incomingRecord, storedRecord) else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "classification change record is immutable: \(storedRecord.id.uuidString)"
                )
            }
        }

        let canonicalIDs = incomingRecords.map(\.id)
        let storedIDs = storedRecords.map(\.id)
        let requiresSequenceRebuild = Array(canonicalIDs.prefix(storedIDs.count)) != storedIDs
        if requiresSequenceRebuild {
            try stageClassificationAuditSequenceProjection(
                .changeRecord,
                canonicalCount: incomingRecords.count,
                storedCount: storedRecords.count,
                in: database
            )
        }
        let recordSQL = """
        INSERT INTO classification_change_records(
            record_id, record_sequence, plan_id, interaction_id, source_kind,
            source_session_id, source_draft_id, source_draft_version, source_evidence_id,
            source_from_chain_id, source_reason,
            decision_id, committed_at, revision
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        for (sequence, record) in incomingRecords.enumerated() where storedByID[record.id] == nil {
            let planDigest = record.planDigest
            let integrityDigest = record.integrityDigest
            guard isValidClassificationPlanDigest(planDigest),
                  isValidClassificationPlanDigest(integrityDigest)
            else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "new classification change record requires valid plan and integrity digests"
                )
            }
            let source = classificationSourceStorage(record.source)
            try run(recordSQL, on: database) { statement in
                bind(record.id, to: 1, in: statement)
                bind(sequence, to: 2, in: statement)
                bind(record.planID, to: 3, in: statement)
                bind(record.interactionID, to: 4, in: statement)
                bind(source.kind, to: 5, in: statement)
                bind(source.sessionID?.uuidString, to: 6, in: statement)
                bind(source.draftID?.uuidString, to: 7, in: statement)
                bind(source.draftVersion, to: 8, in: statement)
                bind(source.evidenceID?.uuidString, to: 9, in: statement)
                bind(source.fromChainID?.rawValue.uuidString, to: 10, in: statement)
                bind(source.reason, to: 11, in: statement)
                bind(record.decisionID?.uuidString, to: 12, in: statement)
                bindClassificationChangeDate(record.committedAt, to: 13, in: statement)
                try bind(record.revision, to: 14, in: statement)
            }
            try insertClassificationChanges(record, into: database)
            try insertClassificationChangeRecordNotices(record, into: database)
            try run(
                """
                INSERT INTO classification_change_record_plan_digests(record_id, digest)
                VALUES (?, ?)
                """,
                on: database
            ) { statement in
                bind(record.id, to: 1, in: statement)
                bind(planDigest, to: 2, in: statement)
            }
            try run(
                """
                INSERT INTO classification_change_record_integrity_digests(record_id, digest)
                VALUES (?, ?)
                """,
                on: database
            ) { statement in
                bind(record.id, to: 1, in: statement)
                bind(integrityDigest, to: 2, in: statement)
            }
            try run(
                """
                INSERT INTO classification_change_record_finalizations(
                    record_id, change_count, notice_count
                )
                VALUES (?, ?, ?)
                """,
                on: database
            ) { statement in
                bind(record.id, to: 1, in: statement)
                bind(record.changes.count, to: 2, in: statement)
                bind(record.notices.count, to: 3, in: statement)
            }
        }
        if requiresSequenceRebuild {
            try restoreClassificationAuditSequenceProjection(
                .changeRecord,
                canonicalIDs: canonicalIDs,
                storedIDs: Set(storedByID.keys),
                in: database
            )
        }
    }

    func insertClassificationChangeRecordNotices(
        _ record: ClassificationChangeRecord,
        into database: Database?
    ) throws {
        let sql = """
        INSERT INTO classification_change_record_notice_records(
            record_id, position, kind, duplicate_name, item_kind,
            input_name, current_name, matched_historical_alias
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """
        for (position, notice) in record.notices.enumerated() {
            let stored = classificationNoticeStorage(notice)
            try run(sql, on: database) { statement in
                bind(record.id, to: 1, in: statement)
                bind(position, to: 2, in: statement)
                bind(stored.kind, to: 3, in: statement)
                bind(stored.duplicateName, to: 4, in: statement)
                bind(stored.itemKind, to: 5, in: statement)
                bind(stored.inputName, to: 6, in: statement)
                bind(stored.currentName, to: 7, in: statement)
                bind(stored.matchedHistoricalAlias, to: 8, in: statement)
            }
        }
    }

    func insertClassificationChanges(
        _ record: ClassificationChangeRecord,
        into database: Database?
    ) throws {
        let changeSQL = """
        INSERT INTO classification_change_record_changes(
            record_id, position, kind, chain_id, item_kind, item_id,
            before_name, after_name, name, before_lifecycle, after_lifecycle,
            before_approval, after_approval
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        for (position, change) in record.changes.enumerated() {
            switch change {
            case let .create(kind, itemID, name, colorHex):
                try insertClassificationManagementChange(
                    SQLiteClassificationManagementChangeRow(
                        recordID: record.id,
                        position: position,
                        kind: "create",
                        itemKind: kind,
                        itemID: itemID,
                        name: name,
                        colorHex: colorHex
                    ),
                    into: database
                )
            case let .merge(
                kind,
                sourceID,
                sourceName,
                targetID,
                targetName,
                sourceLifecycle,
                impact
            ):
                try insertClassificationManagementChange(
                    SQLiteClassificationManagementChangeRow(
                        recordID: record.id,
                        position: position,
                        kind: "merge",
                        itemKind: kind,
                        itemID: sourceID,
                        name: sourceName,
                        targetID: targetID,
                        targetName: targetName,
                        sourceLifecycle: sourceLifecycle,
                        migratedRelationCount: impact.migratedRelationCount,
                        deduplicatedRelationCount: impact.deduplicatedRelationCount
                    ),
                    into: database
                )
                try insertClassificationMergeImpact(
                    impact,
                    recordID: record.id,
                    changePosition: position,
                    into: database
                )
            case let .hardDelete(kind, itemID, name, lifecycle, references):
                try insertClassificationManagementChange(
                    SQLiteClassificationManagementChangeRow(
                        recordID: record.id,
                        position: position,
                        kind: "hardDelete",
                        itemKind: kind,
                        itemID: itemID,
                        name: name,
                        lifecycle: lifecycle,
                        currentRelationCount: references.currentRelationCount,
                        relationHistoryCount: references.relationHistoryCount,
                        historicalEventCount: references.historicalEventCount,
                        mergeSourceCount: references.mergeSourceCount,
                        mergeTargetCount: references.mergeTargetCount
                    ),
                    into: database
                )
            case let .setCurrent(chainID, before, after):
                try run(changeSQL, on: database) { statement in
                    bind(record.id, to: 1, in: statement)
                    bind(position, to: 2, in: statement)
                    bind("setCurrent", to: 3, in: statement)
                    bind(chainID.rawValue.uuidString, to: 4, in: statement)
                    for index in 5 ... 13 {
                        bind(nil as String?, to: Int32(index), in: statement)
                    }
                }
                try insertClassificationSelection(
                    before,
                    side: .before,
                    recordID: record.id,
                    changePosition: position,
                    into: database
                )
                try insertClassificationSelection(
                    after,
                    side: .after,
                    recordID: record.id,
                    changePosition: position,
                    into: database
                )
            case let .rename(kind, itemID, beforeName, afterName):
                try run(changeSQL, on: database) { statement in
                    bind(record.id, to: 1, in: statement)
                    bind(position, to: 2, in: statement)
                    bind("rename", to: 3, in: statement)
                    bind(nil as String?, to: 4, in: statement)
                    bind(kind.rawValue, to: 5, in: statement)
                    bind(itemID, to: 6, in: statement)
                    bind(beforeName, to: 7, in: statement)
                    bind(afterName, to: 8, in: statement)
                    bind(nil as String?, to: 9, in: statement)
                    bind(nil as String?, to: 10, in: statement)
                    bind(nil as String?, to: 11, in: statement)
                    bind(nil as String?, to: 12, in: statement)
                    bind(nil as String?, to: 13, in: statement)
                }
            case let .lifecycle(kind, itemID, name, before, after):
                try run(changeSQL, on: database) { statement in
                    bind(record.id, to: 1, in: statement)
                    bind(position, to: 2, in: statement)
                    bind("lifecycle", to: 3, in: statement)
                    bind(nil as String?, to: 4, in: statement)
                    bind(kind.rawValue, to: 5, in: statement)
                    bind(itemID, to: 6, in: statement)
                    bind(nil as String?, to: 7, in: statement)
                    bind(nil as String?, to: 8, in: statement)
                    bind(name, to: 9, in: statement)
                    bind(before.rawValue, to: 10, in: statement)
                    bind(after.rawValue, to: 11, in: statement)
                    bind(nil as String?, to: 12, in: statement)
                    bind(nil as String?, to: 13, in: statement)
                }
            case let .categoryPresentationApproval(itemID, name, before, after):
                try run(changeSQL, on: database) { statement in
                    bind(record.id, to: 1, in: statement)
                    bind(position, to: 2, in: statement)
                    bind("categoryPresentationApproval", to: 3, in: statement)
                    bind(nil as String?, to: 4, in: statement)
                    bind(ClassificationItemKind.category.rawValue, to: 5, in: statement)
                    bind(itemID, to: 6, in: statement)
                    bind(nil as String?, to: 7, in: statement)
                    bind(nil as String?, to: 8, in: statement)
                    bind(name, to: 9, in: statement)
                    bind(nil as String?, to: 10, in: statement)
                    bind(nil as String?, to: 11, in: statement)
                    bind(before.rawValue, to: 12, in: statement)
                    bind(after.rawValue, to: 13, in: statement)
                }
            }
        }
    }

    func insertClassificationManagementChange(
        _ change: SQLiteClassificationManagementChangeRow,
        into database: Database?
    ) throws {
        guard UUID(uuidString: change.itemID) != nil,
              change.targetID.map({ UUID(uuidString: $0) != nil }) ?? true
        else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid classification management item ID")
        }
        let sql = """
        INSERT INTO classification_management_changes(
            record_id, position, kind, item_kind, item_id, name, color_hex,
            target_id, target_name, source_lifecycle, lifecycle,
            migrated_relation_count, deduplicated_relation_count,
            current_relation_count, relation_history_count, historical_event_count,
            merge_source_count, merge_target_count
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        try run(sql, on: database) { statement in
            bind(change.recordID, to: 1, in: statement)
            bind(change.position, to: 2, in: statement)
            bind(change.kind, to: 3, in: statement)
            bind(change.itemKind.rawValue, to: 4, in: statement)
            bind(change.itemID, to: 5, in: statement)
            bind(change.name, to: 6, in: statement)
            bind(change.colorHex, to: 7, in: statement)
            bind(change.targetID, to: 8, in: statement)
            bind(change.targetName, to: 9, in: statement)
            bind(change.sourceLifecycle?.rawValue, to: 10, in: statement)
            bind(change.lifecycle?.rawValue, to: 11, in: statement)
            bind(change.migratedRelationCount, to: 12, in: statement)
            bind(change.deduplicatedRelationCount, to: 13, in: statement)
            bind(change.currentRelationCount, to: 14, in: statement)
            bind(change.relationHistoryCount, to: 15, in: statement)
            bind(change.historicalEventCount, to: 16, in: statement)
            bind(change.mergeSourceCount, to: 17, in: statement)
            bind(change.mergeTargetCount, to: 18, in: statement)
        }
    }

    func insertClassificationMergeImpact(
        _ impact: ClassificationMergeImpact,
        recordID: UUID,
        changePosition: Int,
        into database: Database?
    ) throws {
        let chainSQL = """
        INSERT INTO classification_merge_impact_chain_ids(
            record_id, change_position, item_position, chain_id
        )
        VALUES (?, ?, ?, ?)
        """
        for (position, chainID) in impact.currentChainIDs.enumerated() {
            try run(chainSQL, on: database) { statement in
                bind(recordID, to: 1, in: statement)
                bind(changePosition, to: 2, in: statement)
                bind(position, to: 3, in: statement)
                bind(chainID.rawValue, to: 4, in: statement)
            }
        }

        let traceSQL = """
        INSERT INTO classification_merge_impact_trace_ids(
            record_id, change_position, item_position, trace_id
        )
        VALUES (?, ?, ?, ?)
        """
        for (position, traceID) in impact.historicalTraceIDs.enumerated() {
            try run(traceSQL, on: database) { statement in
                bind(recordID, to: 1, in: statement)
                bind(changePosition, to: 2, in: statement)
                bind(position, to: 3, in: statement)
                bind(traceID.rawValue, to: 4, in: statement)
            }
        }

        let eventSQL = """
        INSERT INTO classification_merge_impact_event_ids(
            record_id, change_position, item_position, event_id
        )
        VALUES (?, ?, ?, ?)
        """
        for (position, eventID) in impact.historicalEventIDs.enumerated() {
            try run(eventSQL, on: database) { statement in
                bind(recordID, to: 1, in: statement)
                bind(changePosition, to: 2, in: statement)
                bind(position, to: 3, in: statement)
                bind(eventID, to: 4, in: statement)
            }
        }
    }

    func insertClassificationSelection(
        _ preview: ClassificationSelectionPreview,
        side: SQLiteClassificationSelectionSide,
        recordID: UUID,
        changePosition: Int,
        into database: Database?
    ) throws {
        guard preview.category?.kind != .label,
              preview.labels.allSatisfy({ $0.kind == .label })
        else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid classification selection item kind")
        }
        var items: [ClassificationPlanItem] = []
        if let category = preview.category {
            items.append(category)
        }
        items.append(contentsOf: preview.labels)

        let sql = """
        INSERT INTO classification_change_selection_items(
            record_id, change_position, selection_side, item_position,
            item_id, item_kind, name, color_hex, resolution
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        for (position, item) in items.enumerated() {
            try run(sql, on: database) { statement in
                bind(recordID, to: 1, in: statement)
                bind(changePosition, to: 2, in: statement)
                bind(side.rawValue, to: 3, in: statement)
                bind(position, to: 4, in: statement)
                bind(item.id, to: 5, in: statement)
                bind(item.kind.rawValue, to: 6, in: statement)
                bind(item.name, to: 7, in: statement)
                bind(item.colorHex, to: 8, in: statement)
                bind(item.resolution.rawValue, to: 9, in: statement)
            }
        }
    }

    func classificationSourceStorage(_ source: ClassificationSource) -> SQLiteClassificationSourceRecord {
        switch source {
        case .userDirect:
            SQLiteClassificationSourceRecord(
                kind: "userDirect",
                sessionID: nil,
                draftID: nil,
                draftVersion: nil,
                evidenceID: nil,
                fromChainID: nil,
                reason: nil
            )
        case let .zhulongSuggestion(sessionID, draftID, draftVersion, evidenceID):
            SQLiteClassificationSourceRecord(
                kind: "zhulongSuggestion",
                sessionID: sessionID,
                draftID: draftID,
                draftVersion: draftVersion,
                evidenceID: evidenceID,
                fromChainID: nil,
                reason: nil
            )
        case let .inherited(fromChainID):
            SQLiteClassificationSourceRecord(
                kind: "inherited",
                sessionID: nil,
                draftID: nil,
                draftVersion: nil,
                evidenceID: nil,
                fromChainID: fromChainID,
                reason: nil
            )
        case let .deterministicDomainAction(reason):
            SQLiteClassificationSourceRecord(
                kind: "deterministicDomainAction",
                sessionID: nil,
                draftID: nil,
                draftVersion: nil,
                evidenceID: nil,
                fromChainID: nil,
                reason: reason
            )
        case let .automaticAI(jobID, generation):
            SQLiteClassificationSourceRecord(
                kind: "automaticAI",
                sessionID: jobID,
                draftID: nil,
                draftVersion: generation,
                evidenceID: nil,
                fromChainID: nil,
                reason: nil
            )
        }
    }

    @discardableResult
    func bindClassificationSource(
        _ source: ClassificationSource,
        startingAt index: Int32,
        in statement: Statement?
    ) -> Int32 {
        let stored = classificationSourceStorage(source)
        bind(stored.kind, to: index, in: statement)
        bind(stored.sessionID?.uuidString, to: index + 1, in: statement)
        bind(stored.draftID?.uuidString, to: index + 2, in: statement)
        bind(stored.draftVersion, to: index + 3, in: statement)
        bind(stored.evidenceID?.uuidString, to: index + 4, in: statement)
        bind(stored.fromChainID?.rawValue.uuidString, to: index + 5, in: statement)
        bind(stored.reason, to: index + 6, in: statement)
        return index + 7
    }

    func insertClassificationReceipts(
        _ classifications: TaskClassificationState,
        into database: Database?
    ) throws {
        let storedReceipts = try loadClassificationReceipts(from: database)
        let changeRecordsByID = Dictionary(
            uniqueKeysWithValues: classifications.changeRecords.map { ($0.id, $0) }
        )
        let commitSQL = """
        INSERT INTO classification_commits(interaction_id, plan_id, revision)
        VALUES (?, ?, ?)
        """
        let noticeSQL = """
        INSERT INTO classification_commit_notice_records(
            interaction_id, position, kind, duplicate_name, item_kind,
            input_name, current_name, matched_historical_alias
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """
        let metadataSQL = """
        INSERT INTO classification_commit_receipt_metadata(
            interaction_id, change_record_id, decision_id
        )
        VALUES (?, ?, ?)
        """
        let digestSQL = """
        INSERT INTO classification_commit_receipt_integrity_digests(interaction_id, digest)
        VALUES (?, ?)
        """
        let finalizationSQL = """
        INSERT INTO classification_commit_finalizations(interaction_id, notice_count)
        VALUES (?, ?)
        """

        for (interactionID, receipt) in classifications.committedReceiptsByInteractionID.sorted(by: {
            $0.key.uuidString < $1.key.uuidString
        }) {
            guard let referencedRecord = changeRecordsByID[receipt.changeRecordID],
                  referencedRecord.planID == receipt.planID,
                  referencedRecord.interactionID == interactionID,
                  referencedRecord.revision == receipt.revision,
                  referencedRecord.decisionID == receipt.decisionID,
                  receipt.changeRecordIntegrityDigest == referencedRecord.integrityDigest
            else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "classification receipt does not match its change record"
                )
            }
            let integrityDigest = referencedRecord.integrityDigest
            if let stored = storedReceipts[interactionID] {
                guard stored == receipt else {
                    throw SQLiteRepositoryError.invalidStoredValue(
                        "classification receipt is immutable: \(interactionID.uuidString)"
                    )
                }
                continue
            }

            try run(commitSQL, on: database) { statement in
                bind(interactionID, to: 1, in: statement)
                bind(receipt.planID, to: 2, in: statement)
                try bind(receipt.revision, to: 3, in: statement)
            }
            for (position, notice) in receipt.notices.enumerated() {
                let storedNotice = classificationNoticeStorage(notice)
                try run(noticeSQL, on: database) { statement in
                    bind(interactionID, to: 1, in: statement)
                    bind(position, to: 2, in: statement)
                    bind(storedNotice.kind, to: 3, in: statement)
                    bind(storedNotice.duplicateName, to: 4, in: statement)
                    bind(storedNotice.itemKind, to: 5, in: statement)
                    bind(storedNotice.inputName, to: 6, in: statement)
                    bind(storedNotice.currentName, to: 7, in: statement)
                    bind(storedNotice.matchedHistoricalAlias, to: 8, in: statement)
                }
            }
            try run(metadataSQL, on: database) { statement in
                bind(interactionID, to: 1, in: statement)
                bind(receipt.changeRecordID, to: 2, in: statement)
                bind(receipt.decisionID?.uuidString, to: 3, in: statement)
            }
            try run(digestSQL, on: database) { statement in
                bind(interactionID, to: 1, in: statement)
                bind(integrityDigest, to: 2, in: statement)
            }
            try run(finalizationSQL, on: database) { statement in
                bind(interactionID, to: 1, in: statement)
                bind(receipt.notices.count, to: 2, in: statement)
            }
        }
    }

    func classificationNoticeStorage(_ notice: ClassificationNotice) -> SQLiteClassificationNoticeRecord {
        switch notice {
        case let .duplicateLabelCollapsed(name):
            return SQLiteClassificationNoticeRecord(
                kind: "duplicateLabelCollapsed",
                duplicateName: name,
                itemKind: nil,
                inputName: nil,
                currentName: nil,
                matchedHistoricalAlias: nil
            )
        case let .existingItemReused(kind, inputName, currentName, matchedHistoricalAlias):
            return SQLiteClassificationNoticeRecord(
                kind: "existingItemReused",
                duplicateName: nil,
                itemKind: kind.rawValue,
                inputName: inputName,
                currentName: currentName,
                matchedHistoricalAlias: matchedHistoricalAlias ? 1 : 0
            )
        }
    }

    func upsert(_ preferences: AppPreferences, into database: Database?) throws {
        let sql = """
        INSERT INTO app_preferences(
            id, theme, language,
            theme_language_updated_at, theme_language_updated_at_bits,
            theme_language_writer_id
        )
        VALUES (1, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            theme = excluded.theme,
            language = excluded.language,
            theme_language_updated_at = excluded.theme_language_updated_at,
            theme_language_updated_at_bits =
                excluded.theme_language_updated_at_bits,
            theme_language_writer_id =
                excluded.theme_language_writer_id
        """
        try run(sql, on: database) { statement in
            bind(preferences.theme.rawValue, to: 1, in: statement)
            bind(preferences.language.rawValue, to: 2, in: statement)
            bind(
                preferences.themeLanguageUpdatedAt,
                to: 3,
                in: statement
            )
            try bindExactDate(
                preferences.themeLanguageUpdatedAt,
                to: 4,
                in: statement
            )
            bind(
                preferences.themeLanguageWriterID,
                to: 5,
                in: statement
            )
        }
        try upsertPreferenceSetting(key: "app.data_mode", value: preferences.dataMode.rawValue, into: database)
        try upsertPreferenceSetting(
            key: "app.backup.frequency",
            value: preferences.backupPolicy.frequency.rawValue,
            into: database
        )
        try upsertPreferenceSetting(
            key: "app.backup.destination",
            value: preferences.backupPolicy.destination.rawValue,
            into: database
        )
        try upsertPreferenceSetting(
            key: "app.local_first_sync.enabled",
            value: preferences.localFirstSyncPolicy.enabled ? "true" : "false",
            into: database
        )
        try upsertPreferenceSetting(
            key: "app.local_first_sync.endpoint",
            value: preferences.localFirstSyncPolicy.endpoint.rawValue,
            into: database
        )
        try upsertPreferenceSetting(
            key: "app.local_first_sync.mode",
            value: preferences.localFirstSyncPolicy.mode.rawValue,
            into: database
        )
        try upsertPreferenceSetting(
            key: "app.local_first_sync.interval_seconds",
            value: "\(preferences.localFirstSyncPolicy.intervalSeconds)",
            into: database
        )
        try upsertPreferenceSetting(
            key: "app.local_first_sync.generate_conflict_copy",
            value: preferences.localFirstSyncPolicy.generateConflictCopy ? "true" : "false",
            into: database
        )
        try upsertPreferenceSetting(
            key: "app.local_first_sync.retention_days",
            value: "\(preferences.localFirstSyncPolicy.snapshotRetention.indexRetentionDays)",
            into: database
        )
        try upsertPreferenceSetting(
            key: "app.local_first_sync.retention_daily",
            value: "\(preferences.localFirstSyncPolicy.snapshotRetention.retentionIndexesDaily)",
            into: database
        )
        try upsertPreferenceSetting(
            key: "app.settings_poem.enabled",
            value: preferences.settingsPoemDisplayPolicy.enabled ? "true" : "false",
            into: database
        )
        try upsertPreferenceSetting(
            key: "app.settings_poem.text",
            value: preferences.settingsPoemDisplayPolicy.text,
            into: database
        )
    }

    func upsertPreferenceSetting(key: String, value: String, into database: Database?) throws {
        let sql = """
        INSERT INTO sync_settings(key, value, updated_at)
        VALUES (?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET
            value = excluded.value,
            updated_at = excluded.updated_at
        """
        try run(sql, on: database) { statement in
            bind(key, to: 1, in: statement)
            bind(value, to: 2, in: statement)
            bind(Date(timeIntervalSince1970: 0), to: 3, in: statement)
        }
    }

    func appendJournalEntries(_ entries: [SyncJournalEntry], into database: Database?) throws {
        for entry in entries {
            try SQLiteJournalCAS.insertOrValidateExact(entry, into: database)
        }
    }
}

private extension SQLiteEngineRepository {
    func loadDays(from database: Database?) throws -> [Day] {
        try query(
            """
            SELECT
                id, date, locked_at, locked_at_bits,
                review_summary, review_unfinished_reason, review_tomorrow_note,
                created_at, created_at_bits, updated_at, updated_at_bits
            FROM days
            ORDER BY date
            """,
            on: database
        ) { statement in
            var day = Day(
                id: DayID(try uuid(statement, 0)),
                date: LocalDate(try string(statement, 1)),
                now: try validatedExactDate(
                    statement,
                    textIndex: 7,
                    bitsIndex: 8
                )
            )
            day.lockedAt = try optionalExactDate(
                statement,
                textIndex: 2,
                bitsIndex: 3
            )
            day.reviewSummary = optionalString(statement, 4)
            day.reviewUnfinishedReason = optionalString(statement, 5)
            day.reviewTomorrowNote = optionalString(statement, 6)
            day.updatedAt = try validatedExactDate(
                statement,
                textIndex: 9,
                bitsIndex: 10
            )
            return day
        }
    }

    func loadTaskCycleSeries(
        from database: Database?
    ) throws -> [TaskCycleSeries] {
        try query(
            """
            SELECT
                id, title, description_text, start_date, end_date, schedule,
                end_condition_json, plan_revisions_json,
                planned_subtasks_json, category_id, label_ids_json,
                classification_revisions_json, cancellation_facts_json,
                created_at, created_at_bits, updated_at, updated_at_bits
            FROM task_cycle_series
            ORDER BY created_at, id
            """,
            on: database
        ) { statement in
            let schedule = try taskCycleSchedule(
                from: string(statement, 5)
            )
            return TaskCycleSeries(
                id: TaskCycleSeriesID(try uuid(statement, 0)),
                title: try string(statement, 1),
                descriptionText: optionalString(statement, 2),
                plannedSubtasks: try taskCyclePlannedSubtasks(
                    from: string(statement, 8)
                ),
                categoryID: try optionalUUID(statement, 9).map {
                    TaskCategoryID($0)
                },
                labelIDs: try taskCycleLabelIDs(
                    from: string(statement, 10)
                ),
                startDate: LocalDate(try string(statement, 3)),
                endDate: LocalDate(try string(statement, 4)),
                schedule: schedule,
                endCondition: try taskCycleEndCondition(
                    from: string(statement, 6)
                ),
                planRevisions: try taskCyclePlanRevisions(
                    from: string(statement, 7)
                ),
                classificationRevisions:
                try taskCycleClassificationRevisions(
                    from: string(statement, 11)
                ),
                cancellationFacts: try taskCycleCancellationFacts(
                    from: string(statement, 12)
                ),
                createdAt: try validatedExactDate(
                    statement,
                    textIndex: 13,
                    bitsIndex: 14
                ),
                updatedAt: try validatedExactDate(
                    statement,
                    textIndex: 15,
                    bitsIndex: 16
                )
            )
        }
    }

    func loadChains(from database: Database?) throws -> [TaskChain] {
        try query(
            """
            SELECT
                c.id, c.state, c.cycle_membership_json, c.note_entries_json,
                c.created_at, c.created_at_bits,
                c.updated_at, c.updated_at_bits
            FROM task_chains c
            ORDER BY c.created_at, c.id
            """,
            on: database
        ) { statement in
            guard let state = TaskChainState(rawValue: try string(statement, 1)) else {
                throw SQLiteRepositoryError.invalidStoredValue("invalid task chain state")
            }
            var chain = TaskChain(
                id: TaskChainID(try uuid(statement, 0)),
                state: state,
                cycleMembership: try taskCycleMembership(
                    from: optionalString(statement, 2)
                ),
                noteEntries: try noteEntries(from: string(statement, 3)),
                now: try validatedExactDate(
                    statement,
                    textIndex: 4,
                    bitsIndex: 5
                )
            )
            chain.updatedAt = try validatedExactDate(
                statement,
                textIndex: 6,
                bitsIndex: 7
            )
            return chain
        }
    }

    func loadDefinitions(from database: Database?) throws -> [TaskDefinition] {
        try query(
            """
            SELECT
                id, chain_id, sequence, title, description_text, planned_subtasks_json,
                created_at, created_at_bits,
                content_updated_at, content_updated_at_bits,
                superseded_at, superseded_at_bits, superseded_by_definition_id
            FROM task_definitions
            ORDER BY chain_id, sequence
            """,
            on: database
        ) { statement in
            var definition = TaskDefinition(
                id: TaskDefinitionID(try uuid(statement, 0)),
                chainID: TaskChainID(try uuid(statement, 1)),
                sequence: int(statement, 2),
                title: try string(statement, 3),
                descriptionText: optionalString(statement, 4),
                plannedSubtasks: try plannedSubtasks(from: optionalString(statement, 5)),
                now: try validatedExactDate(
                    statement,
                    textIndex: 6,
                    bitsIndex: 7
                ),
                contentUpdatedAt: try validatedExactDate(
                    statement,
                    textIndex: 8,
                    bitsIndex: 9
                )
            )
            definition.supersededAt = try optionalExactDate(
                statement,
                textIndex: 10,
                bitsIndex: 11
            )
            if let uuid = try optionalUUID(statement, 12) {
                definition.supersededByDefinitionID = TaskDefinitionID(uuid)
            }
            return definition
        }
    }

    func loadTraces(from database: Database?) throws -> [DayTrace] {
        try query(
            """
            SELECT id, chain_id, definition_id, date, status, priority, pin_order, continuation_seq, description_text, note_entries_json,
                   manual_progress_percent, carried_from_trace_id, changed_to_trace_id,
                   created_at, created_at_bits, content_updated_at, content_updated_at_bits,
                   completed_at, completed_at_bits, settled_at, settled_at_bits,
                   draft_cancellation_id, draft_cancelled_on
            FROM day_traces
            ORDER BY date, continuation_seq, priority, created_at
            """,
            on: database
        ) { statement in
            guard let status = TraceStatus(rawValue: try string(statement, 4)) else {
                throw SQLiteRepositoryError.invalidStoredValue("invalid trace status")
            }
            var trace = DayTrace(
                id: DayTraceID(try uuid(statement, 0)),
                chainID: TaskChainID(try uuid(statement, 1)),
                definitionID: TaskDefinitionID(try uuid(statement, 2)),
                date: LocalDate(try string(statement, 3)),
                status: status,
                priority: int(statement, 5),
                pinOrder: optionalInt(statement, 6),
                continuationSeq: int(statement, 7),
                descriptionText: optionalString(statement, 8),
                noteEntries: try noteEntries(from: string(statement, 9)),
                manualProgressPercent: optionalInt(statement, 10),
                carriedFromTraceID: try optionalUUID(statement, 11).map(DayTraceID.init),
                now: try validatedExactDate(
                    statement,
                    textIndex: 13,
                    bitsIndex: 14
                ),
                contentUpdatedAt: try validatedExactDate(
                    statement,
                    textIndex: 15,
                    bitsIndex: 16
                )
            )
            trace.changedToTraceID = try optionalUUID(statement, 12).map(DayTraceID.init)
            trace.completedAt = try optionalExactDate(
                statement,
                textIndex: 17,
                bitsIndex: 18
            )
            trace.settledAt = try optionalExactDate(
                statement,
                textIndex: 19,
                bitsIndex: 20
            )
            trace.draftCancellationID = try optionalUUID(statement, 21)
            trace.draftCancelledOn = optionalString(statement, 22)
                .map(LocalDate.init)
            return trace
        }
    }

    func loadSubtasks(from database: Database?) throws -> [Subtask] {
        try query(
            """
            SELECT id, lineage_id, trace_id, title, status, difficulty, position,
                   carried_from_subtask_id,
                   created_at, created_at_bits,
                   updated_at, updated_at_bits,
                   completed_at, completed_at_bits,
                   settled_at, settled_at_bits,
                   draft_cancellation_id
            FROM subtasks
            ORDER BY trace_id, position
            """,
            on: database
        ) { statement in
            guard let status = SubtaskStatus(rawValue: try string(statement, 4)) else {
                throw SQLiteRepositoryError.invalidStoredValue("invalid subtask status")
            }
            guard let difficulty = SubtaskDifficulty(rawValue: int(statement, 5)) else {
                throw SQLiteRepositoryError.invalidStoredValue("invalid subtask difficulty")
            }
            var subtask = Subtask(
                id: SubtaskID(try uuid(statement, 0)),
                lineageID: SubtaskLineageID(try uuid(statement, 1)),
                traceID: DayTraceID(try uuid(statement, 2)),
                title: try string(statement, 3),
                status: status,
                difficulty: difficulty,
                position: int(statement, 6),
                carriedFromSubtaskID: try optionalUUID(statement, 7).map(SubtaskID.init),
                now: try validatedExactDate(
                    statement,
                    textIndex: 8,
                    bitsIndex: 9
                )
            )
            subtask.updatedAt = try validatedExactDate(
                statement,
                textIndex: 10,
                bitsIndex: 11
            )
            subtask.completedAt = try optionalExactDate(
                statement,
                textIndex: 12,
                bitsIndex: 13
            )
            subtask.settledAt = try optionalExactDate(
                statement,
                textIndex: 14,
                bitsIndex: 15
            )
            subtask.draftCancellationID = try optionalUUID(statement, 16)
            return subtask
        }
    }

    func loadTaskClassifications(from database: Database?) throws -> TaskClassificationState {
        let metadata = try loadClassificationItemMetadata(from: database)
        let nameVersions = try loadClassificationNameVersionRows(from: database)
        let exactItemTimes = try loadClassificationItemExactTimes(from: database)
        let categories = try loadTaskCategories(
            metadata: metadata,
            nameVersions: nameVersions,
            exactItemTimes: exactItemTimes,
            from: database
        )
        let labels = try loadTaskLabels(
            metadata: metadata,
            nameVersions: nameVersions,
            exactItemTimes: exactItemTimes,
            from: database
        )
        let liveItemKeys = Set(categories.keys.map {
            SQLiteClassificationItemKey(kind: .category, itemID: $0.rawValue)
        }).union(labels.keys.map {
            SQLiteClassificationItemKey(kind: .label, itemID: $0.rawValue)
        })
        guard Set(metadata.keys) == liveItemKeys,
              Set(nameVersions.keys) == liveItemKeys,
              Set(exactItemTimes.keys) == liveItemKeys
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "classification catalog, metadata, and name versions are not one-to-one"
            )
        }
        let revision = try loadClassificationRevision(from: database)
        let snapshotEventsByTraceID = try loadTraceClassificationSnapshotEvents(from: database)
        let changeRecords = try loadClassificationChangeRecords(from: database)
        let merges = try loadClassificationMerges(from: database)
        let tombstones = try loadClassificationDeletionTombstones(from: database)
        let state = TaskClassificationState(
            revision: revision,
            categories: categories,
            labels: labels,
            currentByChainID: try loadCurrentTaskClassifications(
                categories: categories,
                labels: labels,
                revision: revision,
                from: database
            ),
            relationHistory: try loadClassificationRelationHistory(from: database),
            categoryMerges: merges.categories,
            labelMerges: merges.labels,
            categoryDeletionTombstones: tombstones.categories,
            labelDeletionTombstones: tombstones.labels,
            snapshotsByTraceID: snapshotEventsByTraceID.compactMapValues(\.last),
            snapshotEventsByTraceID: snapshotEventsByTraceID,
            committedReceiptsByInteractionID: try loadClassificationReceipts(
                changeRecords: changeRecords,
                from: database
            ),
            changeRecords: changeRecords
        )
        try validateClassificationStateIntegrity(state)
        return state
    }

    func loadClassificationItemMetadata(
        from database: Database?
    ) throws -> [SQLiteClassificationItemKey: SQLiteClassificationItemMetadata] {
        let rows = try query(
            """
            SELECT kind, item_id, canonical_key, canonical_key_version, lifecycle
            FROM classification_item_metadata
            ORDER BY kind, item_id
            """,
            on: database
        ) { statement in
            guard let kind = SQLiteClassificationKind(rawValue: try string(statement, 0)) else {
                throw SQLiteRepositoryError.invalidStoredValue("invalid classification item kind")
            }
            guard let lifecycle = ClassificationLifecycle(rawValue: try string(statement, 4)) else {
                throw SQLiteRepositoryError.invalidStoredValue("invalid classification lifecycle")
            }
            return (
                SQLiteClassificationItemKey(kind: kind, itemID: try uuid(statement, 1)),
                SQLiteClassificationItemMetadata(
                    canonicalKey: try string(statement, 2),
                    canonicalKeyVersion: try string(statement, 3),
                    lifecycle: lifecycle
                )
            )
        }
        return Dictionary(uniqueKeysWithValues: rows)
    }

    func loadClassificationNameVersionRows(
        from database: Database?
    ) throws -> [SQLiteClassificationItemKey: [SQLiteClassificationNameVersion]] {
        let exactTimes = try loadClassificationNameVersionExactTimes(from: database)
        var consumedExactTimeIDs: Set<UUID> = []
        let rows = try query(
            """
            SELECT
                version_id, kind, item_id, version_sequence, name,
                canonical_key, canonical_key_version, valid_from, valid_until
            FROM classification_name_versions
            ORDER BY kind, item_id, version_sequence
            """,
            on: database
        ) { statement in
            guard let kind = SQLiteClassificationKind(rawValue: try string(statement, 1)) else {
                throw SQLiteRepositoryError.invalidStoredValue("invalid classification name version kind")
            }
            let versionID = try uuid(statement, 0)
            let item = SQLiteClassificationItemKey(kind: kind, itemID: try uuid(statement, 2))
            guard let exactTime = exactTimes[versionID], exactTime.item == item else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "classification name version exact time is missing or mismatched"
                )
            }
            consumedExactTimeIDs.insert(versionID)
            return SQLiteClassificationNameVersion(
                item: item,
                sequence: int(statement, 3),
                version: ClassificationNameVersion(
                    id: versionID,
                    name: try string(statement, 4),
                    canonicalKey: try string(statement, 5),
                    canonicalKeyVersion: try string(statement, 6),
                    validFrom: exactTime.validFrom,
                    validUntil: exactTime.validUntil
                )
            )
        }

        var rowsByItem: [SQLiteClassificationItemKey: [SQLiteClassificationNameVersion]] = [:]
        for row in rows {
            let expectedSequence = rowsByItem[row.item]?.count ?? 0
            guard row.sequence == expectedSequence else {
                throw SQLiteRepositoryError.invalidStoredValue("invalid classification name version sequence")
            }
            rowsByItem[row.item, default: []].append(row)
        }
        guard consumedExactTimeIDs == Set(exactTimes.keys) else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "classification name version exact time has no name version"
            )
        }
        return rowsByItem
    }

    func loadClassificationItemExactTimes(
        from database: Database?
    ) throws -> [SQLiteClassificationItemKey: SQLiteClassificationItemExactTime] {
        let rows = try query(
            """
            SELECT kind, item_id, created_at, updated_at
            FROM classification_item_exact_times
            ORDER BY kind, item_id
            """,
            on: database
        ) { statement in
            guard let kind = SQLiteClassificationKind(rawValue: try string(statement, 0)) else {
                throw SQLiteRepositoryError.invalidStoredValue("invalid classification exact time item kind")
            }
            let createdAt = try classificationChangeDate(statement, 2)
            let updatedAt = try classificationChangeDate(statement, 3)
            guard createdAt <= updatedAt else {
                throw SQLiteRepositoryError.invalidStoredValue("invalid classification item exact time interval")
            }
            return (
                SQLiteClassificationItemKey(kind: kind, itemID: try uuid(statement, 1)),
                SQLiteClassificationItemExactTime(createdAt: createdAt, updatedAt: updatedAt)
            )
        }
        return Dictionary(uniqueKeysWithValues: rows)
    }

    func loadClassificationNameVersionExactTimes(
        from database: Database?
    ) throws -> [UUID: SQLiteClassificationNameVersionExactTime] {
        let rows = try query(
            """
            SELECT version_id, kind, item_id, valid_from, valid_until
            FROM classification_name_version_exact_times
            ORDER BY version_id
            """,
            on: database
        ) { statement in
            guard let kind = SQLiteClassificationKind(rawValue: try string(statement, 1)) else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "invalid classification name exact time item kind"
                )
            }
            let validFrom = try classificationChangeDate(statement, 3)
            let validUntil: Date? = if sqlite3_column_type(statement, 4) == SQLITE_NULL {
                nil
            } else {
                try classificationChangeDate(statement, 4)
            }
            guard validUntil.map({ $0 >= validFrom }) ?? true else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "invalid classification name exact time interval"
                )
            }
            return (
                try uuid(statement, 0),
                SQLiteClassificationNameVersionExactTime(
                    item: SQLiteClassificationItemKey(kind: kind, itemID: try uuid(statement, 2)),
                    validFrom: validFrom,
                    validUntil: validUntil
                )
            )
        }
        return Dictionary(uniqueKeysWithValues: rows)
    }

    func loadTaskCategories(
        metadata: [SQLiteClassificationItemKey: SQLiteClassificationItemMetadata],
        nameVersions: [SQLiteClassificationItemKey: [SQLiteClassificationNameVersion]],
        exactItemTimes: [SQLiteClassificationItemKey: SQLiteClassificationItemExactTime],
        from database: Database?
    ) throws -> [TaskCategoryID: TaskCategory] {
        let categories = try query(
            """
            SELECT id, name, color_hex, presentation_approval, created_at, updated_at
            FROM task_categories
            ORDER BY id
            """,
            on: database
        ) { statement in
            let id = TaskCategoryID(try uuid(statement, 0))
            let item = SQLiteClassificationItemKey(kind: .category, itemID: id.rawValue)
            let name = try string(statement, 1)
            guard let exactTime = exactItemTimes[item] else {
                throw SQLiteRepositoryError.invalidStoredValue("task category exact time is missing")
            }
            guard let itemMetadata = metadata[item],
                  let itemNameVersions = nameVersions[item]
            else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "task category metadata or name versions are missing"
                )
            }
            let createdAt = exactTime.createdAt
            var category = TaskCategory(
                id: id,
                name: name,
                colorHex: try string(statement, 2),
                presentationApproval: try categoryPresentationApproval(statement, 3),
                now: createdAt
            )
            category.canonicalKey = itemMetadata.canonicalKey
            category.canonicalKeyVersion = itemMetadata.canonicalKeyVersion
            category.lifecycle = itemMetadata.lifecycle
            category.nameVersions = itemNameVersions.map(\.version)
            category.updatedAt = exactTime.updatedAt
            return category
        }
        return Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
    }

    func loadTaskLabels(
        metadata: [SQLiteClassificationItemKey: SQLiteClassificationItemMetadata],
        nameVersions: [SQLiteClassificationItemKey: [SQLiteClassificationNameVersion]],
        exactItemTimes: [SQLiteClassificationItemKey: SQLiteClassificationItemExactTime],
        from database: Database?
    ) throws -> [TaskLabelID: TaskLabel] {
        let labels = try query(
            """
            SELECT id, name, color_hex, created_at, updated_at
            FROM task_labels
            ORDER BY id
            """,
            on: database
        ) { statement in
            let id = TaskLabelID(try uuid(statement, 0))
            let item = SQLiteClassificationItemKey(kind: .label, itemID: id.rawValue)
            let name = try string(statement, 1)
            guard let exactTime = exactItemTimes[item] else {
                throw SQLiteRepositoryError.invalidStoredValue("task label exact time is missing")
            }
            guard let itemMetadata = metadata[item],
                  let itemNameVersions = nameVersions[item]
            else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "task label metadata or name versions are missing"
                )
            }
            let createdAt = exactTime.createdAt
            var label = TaskLabel(
                id: id,
                name: name,
                colorHex: try string(statement, 2),
                now: createdAt
            )
            label.canonicalKey = itemMetadata.canonicalKey
            label.canonicalKeyVersion = itemMetadata.canonicalKeyVersion
            label.lifecycle = itemMetadata.lifecycle
            label.nameVersions = itemNameVersions.map(\.version)
            label.updatedAt = exactTime.updatedAt
            return label
        }
        return Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0) })
    }

    func loadCurrentTaskClassifications(
        categories: [TaskCategoryID: TaskCategory],
        labels: [TaskLabelID: TaskLabel],
        revision: UInt64,
        from database: Database?
    ) throws -> [TaskChainID: CurrentTaskClassification] {
        let facts = try loadCurrentClassificationRelationFacts(from: database)
        let categoryRows = try query(
            """
            SELECT chain_id, category_id
            FROM task_chain_categories
            ORDER BY chain_id
            """,
            on: database
        ) { statement in
            (TaskChainID(try uuid(statement, 0)), TaskCategoryID(try uuid(statement, 1)))
        }
        let labelRows = try query(
            """
            SELECT chain_id, label_id
            FROM task_chain_label_relations
            ORDER BY chain_id, label_id
            """,
            on: database
        ) { statement in
            (TaskChainID(try uuid(statement, 0)), TaskLabelID(try uuid(statement, 1)))
        }

        let chainStateRows = try query(
            """
            SELECT chain_id
            FROM classification_current_chain_states
            ORDER BY chain_id
            """,
            on: database
        ) { statement in
            TaskChainID(try uuid(statement, 0))
        }
        let chainStateIDs = Set(chainStateRows)

        var categoryRelationsByChainID: [TaskChainID: TaskCategoryRelation] = [:]
        var consumedFactKeys: Set<SQLiteClassificationRelationKey> = []
        for (chainID, categoryID) in categoryRows {
            guard let category = categories[categoryID], category.lifecycle != .merged else {
                throw SQLiteRepositoryError.invalidStoredValue("task classification references a missing category")
            }
            let key = SQLiteClassificationRelationKey(
                kind: .category,
                chainID: chainID,
                itemID: categoryID.description
            )
            guard let fact = facts[key], fact.revision <= revision else {
                throw SQLiteRepositoryError.invalidStoredValue("task category relation provenance is missing or invalid")
            }
            consumedFactKeys.insert(key)
            categoryRelationsByChainID[chainID] = TaskCategoryRelation(
                categoryID: categoryID,
                source: fact.source,
                decisionID: fact.decisionID,
                createdAt: fact.createdAt,
                updatedAt: fact.updatedAt,
                revision: fact.revision
            )
        }
        var labelRelationsByChainID: [TaskChainID: [TaskLabelRelation]] = [:]
        for (chainID, labelID) in labelRows {
            guard let label = labels[labelID], label.lifecycle != .merged else {
                throw SQLiteRepositoryError.invalidStoredValue("task classification references a missing label")
            }
            let key = SQLiteClassificationRelationKey(
                kind: .label,
                chainID: chainID,
                itemID: labelID.description
            )
            guard let fact = facts[key], fact.revision <= revision else {
                throw SQLiteRepositoryError.invalidStoredValue("task label relation provenance is missing or invalid")
            }
            consumedFactKeys.insert(key)
            labelRelationsByChainID[chainID, default: []].append(
                TaskLabelRelation(
                    labelID: labelID,
                    source: fact.source,
                    decisionID: fact.decisionID,
                    createdAt: fact.createdAt,
                    updatedAt: fact.updatedAt,
                    revision: fact.revision
                )
            )
        }
        guard consumedFactKeys == Set(facts.keys) else {
            throw SQLiteRepositoryError.invalidStoredValue("classification relation provenance has no live relation")
        }
        let relationChainIDs = Set(categoryRelationsByChainID.keys).union(labelRelationsByChainID.keys)
        guard relationChainIDs.isSubset(of: chainStateIDs) else {
            throw SQLiteRepositoryError.invalidStoredValue("classification relation has no current chain state")
        }
        return Dictionary(
            uniqueKeysWithValues: chainStateIDs.map { chainID in
                return (
                    chainID,
                    CurrentTaskClassification(
                        category: categoryRelationsByChainID[chainID],
                        labels: labelRelationsByChainID[chainID] ?? []
                    )
                )
            }
        )
    }

    func loadCurrentClassificationRelationFacts(
        from database: Database?
    ) throws -> [SQLiteClassificationRelationKey: SQLiteClassificationRelationFact] {
        let rows = try query(
            """
            SELECT
                kind, chain_id, item_id,
                source_kind, source_session_id, source_draft_id, source_draft_version,
                source_evidence_id, source_from_chain_id, source_reason,
                decision_id, created_at, updated_at, revision
            FROM classification_current_relation_facts
            ORDER BY kind, chain_id, item_id
            """,
            on: database
        ) { statement in
            guard let kind = ClassificationItemKind(rawValue: try string(statement, 0)) else {
                throw SQLiteRepositoryError.invalidStoredValue("invalid current classification relation kind")
            }
            let key = SQLiteClassificationRelationKey(
                kind: kind,
                chainID: TaskChainID(try uuid(statement, 1)),
                itemID: try string(statement, 2)
            )
            let createdAt = try classificationChangeDate(statement, 11)
            let updatedAt = try classificationChangeDate(statement, 12)
            guard createdAt <= updatedAt else {
                throw SQLiteRepositoryError.invalidStoredValue("invalid current classification relation interval")
            }
            return (
                key,
                SQLiteClassificationRelationFact(
                    key: key,
                    source: try classificationSource(from: statement, startingAt: 3),
                    decisionID: try optionalUUID(statement, 10),
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    revision: try uint64(statement, 13)
                )
            )
        }
        return Dictionary(uniqueKeysWithValues: rows)
    }

    func loadClassificationRelationHistory(
        from database: Database?
    ) throws -> [ClassificationRelationHistoryEntry] {
        let rows = try query(
            """
            SELECT
                history_sequence, history_id, kind, chain_id, item_id,
                origin_source_kind, origin_source_session_id, origin_source_draft_id,
                origin_source_draft_version, origin_source_evidence_id, origin_source_from_chain_id,
                origin_source_reason, origin_decision_id,
                created_at, created_revision,
                removed_source_kind, removed_source_session_id, removed_source_draft_id,
                removed_source_draft_version, removed_source_evidence_id, removed_source_from_chain_id,
                removed_source_reason, removed_decision_id,
                removed_at, removed_revision
            FROM classification_relation_history
            ORDER BY history_sequence
            """,
            on: database
        ) { statement in
            guard let kind = ClassificationItemKind(rawValue: try string(statement, 2)) else {
                throw SQLiteRepositoryError.invalidStoredValue("invalid classification relation history kind")
            }
            return (
                int(statement, 0),
                ClassificationRelationHistoryEntry(
                    id: try uuid(statement, 1),
                    kind: kind,
                    chainID: TaskChainID(try uuid(statement, 3)),
                    itemID: try string(statement, 4),
                    originSource: try classificationSource(from: statement, startingAt: 5),
                    originDecisionID: try optionalUUID(statement, 12),
                    createdAt: try classificationChangeDate(statement, 13),
                    createdRevision: try uint64(statement, 14),
                    removedBySource: try classificationSource(from: statement, startingAt: 15),
                    removedByDecisionID: try optionalUUID(statement, 22),
                    removedAt: try classificationChangeDate(statement, 23),
                    removedRevision: try uint64(statement, 24)
                )
            )
        }
        guard rows.map(\.0) == Array(0 ..< rows.count) else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid classification relation history sequence")
        }
        return rows.map(\.1)
    }

    func loadClassificationMerges(
        from database: Database?
    ) throws -> (
        categories: [TaskCategoryID: TaskCategoryMerge],
        labels: [TaskLabelID: TaskLabelMerge]
    ) {
        let rows = try query(
            """
            SELECT kind, source_id, merge_id, target_id, merged_at, revision, change_record_id
            FROM classification_merges
            ORDER BY kind, source_id
            """,
            on: database
        ) { statement in
            guard let kind = ClassificationItemKind(rawValue: try string(statement, 0)) else {
                throw SQLiteRepositoryError.invalidStoredValue("invalid classification merge kind")
            }
            return (
                kind,
                try uuid(statement, 1),
                try uuid(statement, 2),
                try uuid(statement, 3),
                try classificationChangeDate(statement, 4),
                try uint64(statement, 5),
                try uuid(statement, 6)
            )
        }
        var categories: [TaskCategoryID: TaskCategoryMerge] = [:]
        var labels: [TaskLabelID: TaskLabelMerge] = [:]
        for (kind, sourceID, mergeID, targetID, mergedAt, revision, changeRecordID) in rows {
            guard sourceID != targetID else {
                throw SQLiteRepositoryError.invalidStoredValue("classification identity was merged into itself")
            }
            switch kind {
            case .category:
                let source = TaskCategoryID(sourceID)
                guard categories[source] == nil else {
                    throw SQLiteRepositoryError.invalidStoredValue("duplicate task category merge source")
                }
                categories[source] = TaskCategoryMerge(
                    id: mergeID,
                    sourceID: source,
                    targetID: TaskCategoryID(targetID),
                    mergedAt: mergedAt,
                    revision: revision,
                    changeRecordID: changeRecordID
                )
            case .label:
                let source = TaskLabelID(sourceID)
                guard labels[source] == nil else {
                    throw SQLiteRepositoryError.invalidStoredValue("duplicate task label merge source")
                }
                labels[source] = TaskLabelMerge(
                    id: mergeID,
                    sourceID: source,
                    targetID: TaskLabelID(targetID),
                    mergedAt: mergedAt,
                    revision: revision,
                    changeRecordID: changeRecordID
                )
            }
        }
        return (categories, labels)
    }

    func loadClassificationDeletionTombstones(
        from database: Database?
    ) throws -> (
        categories: [TaskCategoryID: TaskCategoryDeletionTombstone],
        labels: [TaskLabelID: TaskLabelDeletionTombstone]
    ) {
        let rows = try query(
            """
            SELECT kind, item_id, tombstone_id, deleted_at, revision, change_record_id
            FROM classification_deletion_tombstones
            ORDER BY kind, item_id
            """,
            on: database
        ) { statement in
            guard let kind = ClassificationItemKind(rawValue: try string(statement, 0)) else {
                throw SQLiteRepositoryError.invalidStoredValue("invalid classification tombstone kind")
            }
            return (
                kind,
                try uuid(statement, 1),
                try uuid(statement, 2),
                try classificationChangeDate(statement, 3),
                try uint64(statement, 4),
                try uuid(statement, 5)
            )
        }
        var categories: [TaskCategoryID: TaskCategoryDeletionTombstone] = [:]
        var labels: [TaskLabelID: TaskLabelDeletionTombstone] = [:]
        for (kind, itemID, tombstoneID, deletedAt, revision, changeRecordID) in rows {
            switch kind {
            case .category:
                let id = TaskCategoryID(itemID)
                guard categories[id] == nil else {
                    throw SQLiteRepositoryError.invalidStoredValue("duplicate task category deletion tombstone")
                }
                categories[id] = TaskCategoryDeletionTombstone(
                    id: tombstoneID,
                    itemID: id,
                    deletedAt: deletedAt,
                    revision: revision,
                    changeRecordID: changeRecordID
                )
            case .label:
                let id = TaskLabelID(itemID)
                guard labels[id] == nil else {
                    throw SQLiteRepositoryError.invalidStoredValue("duplicate task label deletion tombstone")
                }
                labels[id] = TaskLabelDeletionTombstone(
                    id: tombstoneID,
                    itemID: id,
                    deletedAt: deletedAt,
                    revision: revision,
                    changeRecordID: changeRecordID
                )
            }
        }
        return (categories, labels)
    }

    func loadTraceClassificationSnapshotEvents(
        from database: Database?
    ) throws -> [DayTraceID: [TraceClassificationSnapshot]] {
        try loadPersistedTraceClassificationEvents(from: database)
            .mapValues { $0.map(\.snapshot) }
    }

    func loadPersistedTraceClassificationEvents(
        from database: Database?
    ) throws -> [DayTraceID: [SQLiteTraceClassificationEvent]] {
        let finalizationRows = try query(
            """
            SELECT event_id, category_count, label_count
            FROM trace_classification_snapshot_event_finalizations
            ORDER BY event_id
            """,
            on: database
        ) { statement in
            (try uuid(statement, 0), (int(statement, 1), int(statement, 2)))
        }
        let finalizationsByEventID = Dictionary(uniqueKeysWithValues: finalizationRows)
        let categoryRows = try query(
            """
            SELECT event_id, category_id, name, color_hex, presentation_approval
            FROM trace_classification_event_categories
            ORDER BY event_id
            """,
            on: database
        ) { statement in
            (
                try uuid(statement, 0),
                HistoricalCategoryValue(
                    id: TaskCategoryID(try uuid(statement, 1)),
                    name: try string(statement, 2),
                    colorHex: try string(statement, 3),
                    presentationApproval: try categoryPresentationApproval(statement, 4)
                )
            )
        }
        let categoriesByEventID = Dictionary(uniqueKeysWithValues: categoryRows)

        let labelRows = try query(
            """
            SELECT event_id, label_id, name, color_hex
            FROM trace_classification_event_labels
            ORDER BY event_id, label_id
            """,
            on: database
        ) { statement in
            (
                try uuid(statement, 0),
                HistoricalLabelValue(
                    id: TaskLabelID(try uuid(statement, 1)),
                    name: try string(statement, 2),
                    colorHex: try string(statement, 3)
                )
            )
        }
        let labelsByEventID = Dictionary(grouping: labelRows, by: \.0).mapValues { rows in
            rows.map(\.1).sorted(by: classificationLabelOrder)
        }

        let rows = try query(
            """
            SELECT event_id, trace_id, event_sequence, status, captured_at, revision
            FROM trace_classification_snapshot_events
            ORDER BY trace_id, event_sequence
            """,
            on: database
        ) { statement in
            let eventID = try uuid(statement, 0)
            guard let status = TraceStatus(rawValue: try string(statement, 3)) else {
                throw SQLiteRepositoryError.invalidStoredValue("invalid trace classification event status")
            }
            return SQLiteTraceClassificationEvent(
                sequence: int(statement, 2),
                snapshot: TraceClassificationSnapshot(
                    id: eventID,
                    traceID: DayTraceID(try uuid(statement, 1)),
                    status: status,
                    category: categoriesByEventID[eventID],
                    labels: labelsByEventID[eventID] ?? [],
                    capturedAt: try classificationChangeDate(statement, 4),
                    revision: try uint64(statement, 5)
                )
            )
        }

        var eventsByTraceID: [DayTraceID: [SQLiteTraceClassificationEvent]] = [:]
        var consumedFinalizationIDs: Set<UUID> = []
        for row in rows {
            let traceID = row.snapshot.traceID
            let expectedSequence = eventsByTraceID[traceID]?.count ?? 0
            guard row.sequence == expectedSequence,
                  finalizationsByEventID[row.snapshot.id]?.0 == (row.snapshot.category == nil ? 0 : 1),
                  finalizationsByEventID[row.snapshot.id]?.1 == row.snapshot.labels.count
            else {
                throw SQLiteRepositoryError.invalidStoredValue("invalid trace classification event sequence")
            }
            consumedFinalizationIDs.insert(row.snapshot.id)
            eventsByTraceID[traceID, default: []].append(row)
        }
        guard consumedFinalizationIDs == Set(finalizationsByEventID.keys) else {
            throw SQLiteRepositoryError.invalidStoredValue("trace classification event finalization is inconsistent")
        }
        return eventsByTraceID
    }

    func loadClassificationRevision(from database: Database?) throws -> UInt64 {
        let revisions = try query(
            "SELECT revision FROM classification_state WHERE id = 1",
            on: database
        ) { statement in
            try uint64(statement, 0)
        }
        return revisions.first ?? 0
    }

    func loadClassificationChangeRecords(
        from database: Database?
    ) throws -> [ClassificationChangeRecord] {
        var context = try loadClassificationChangeContext(from: database)
        let recordRows = context.recordRows
        let records = try recordRows.map { row in
            try classificationChangeRecord(from: row, context: &context)
        }
        try validateConsumedClassificationChangeChildren(context)
        return records
    }

    func loadClassificationChangeContext(
        from database: Database?
    ) throws -> SQLiteClassificationChangeLoadContext {
        let selectionRowsByKey = try loadClassificationSelectionRows(from: database)
        let changeRowsByRecordID = try loadClassificationChangeRows(from: database)
        let managementRowsByRecordID = try loadClassificationManagementChangeRows(from: database)
        let noticesByRecordID = try loadClassificationChangeRecordNotices(from: database)
        let impactChainIDs = try loadClassificationMergeImpactIDs(
            table: "classification_merge_impact_chain_ids",
            idColumn: "chain_id",
            from: database
        )
        let impactTraceIDs = try loadClassificationMergeImpactIDs(
            table: "classification_merge_impact_trace_ids",
            idColumn: "trace_id",
            from: database
        )
        let impactEventIDs = try loadClassificationMergeImpactIDs(
            table: "classification_merge_impact_event_ids",
            idColumn: "event_id",
            from: database
        )
        let finalizationsByRecordID = try loadClassificationFinalizations(from: database)
        let planDigestsByRecordID = try loadClassificationDigests(
            from: "classification_change_record_plan_digests",
            database: database
        )
        let integrityDigestsByRecordID = try loadClassificationDigests(
            from: "classification_change_record_integrity_digests",
            database: database
        )
        let recordRows = try loadClassificationChangeRecordRows(from: database)

        guard recordRows.map(\.sequence) == Array(0 ..< recordRows.count) else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid classification change record sequence")
        }
        let recordIDs = Set(recordRows.map(\.id))
        guard Set(changeRowsByRecordID.keys).isSubset(of: recordIDs),
              Set(managementRowsByRecordID.keys).isSubset(of: recordIDs),
              Set(noticesByRecordID.keys).isSubset(of: recordIDs),
              Set(finalizationsByRecordID.keys) == recordIDs,
              Set(planDigestsByRecordID.keys) == recordIDs,
              Set(integrityDigestsByRecordID.keys) == recordIDs
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "classification change record children or finalization are inconsistent"
            )
        }
        return SQLiteClassificationChangeLoadContext(
            recordRows: recordRows,
            selectionRowsByKey: selectionRowsByKey,
            changeRowsByRecordID: changeRowsByRecordID,
            managementRowsByRecordID: managementRowsByRecordID,
            noticesByRecordID: noticesByRecordID,
            impactChainIDs: impactChainIDs,
            impactTraceIDs: impactTraceIDs,
            impactEventIDs: impactEventIDs,
            finalizationsByRecordID: finalizationsByRecordID,
            planDigestsByRecordID: planDigestsByRecordID,
            integrityDigestsByRecordID: integrityDigestsByRecordID
        )
    }

    func loadClassificationChangeRecordNotices(
        from database: Database?
    ) throws -> [UUID: [ClassificationNotice]] {
        let rows = try query(
            """
            SELECT
                record_id, position, kind, duplicate_name, item_kind,
                input_name, current_name, matched_historical_alias
            FROM classification_change_record_notice_records
            ORDER BY record_id, position
            """,
            on: database
        ) { statement in
            (try uuid(statement, 0), int(statement, 1), try classificationNotice(statement))
        }
        var noticesByRecordID: [UUID: [ClassificationNotice]] = [:]
        for (recordID, position, notice) in rows {
            guard position == (noticesByRecordID[recordID]?.count ?? 0) else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "invalid classification change record notice position"
                )
            }
            noticesByRecordID[recordID, default: []].append(notice)
        }
        return noticesByRecordID
    }

    func loadClassificationFinalizations(
        from database: Database?
    ) throws -> [UUID: SQLiteClassificationRecordFinalization] {
        let rows = try query(
            """
            SELECT record_id, change_count, notice_count
            FROM classification_change_record_finalizations
            ORDER BY record_id
            """,
            on: database
        ) { statement in
            (
                try uuid(statement, 0),
                SQLiteClassificationRecordFinalization(
                    changeCount: int(statement, 1),
                    noticeCount: int(statement, 2)
                )
            )
        }
        return Dictionary(uniqueKeysWithValues: rows)
    }

    func loadClassificationDigests(
        from table: String,
        database: Database?
    ) throws -> [UUID: String] {
        let rows = try query(
            """
            SELECT record_id, digest
            FROM \(table)
            ORDER BY record_id
            """,
            on: database
        ) { statement in
            let digest = try string(statement, 1)
            guard isValidClassificationPlanDigest(digest) else {
                throw SQLiteRepositoryError.invalidStoredValue("invalid classification digest")
            }
            return (try uuid(statement, 0), digest)
        }
        return Dictionary(uniqueKeysWithValues: rows)
    }

    func classificationChangeRecord(
        from row: SQLiteClassificationChangeRecordRow,
        context: inout SQLiteClassificationChangeLoadContext
    ) throws -> ClassificationChangeRecord {
        let storedChanges = context.changeRowsByRecordID[row.id] ?? []
        let managementChanges = context.managementRowsByRecordID[row.id] ?? []
        let storedByPosition = Dictionary(uniqueKeysWithValues: storedChanges.map { ($0.position, $0) })
        let managementByPosition = Dictionary(
            uniqueKeysWithValues: managementChanges.map { ($0.position, $0) }
        )
        let positions = Set(storedByPosition.keys).union(managementByPosition.keys).sorted()
        guard Set(storedByPosition.keys).isDisjoint(with: managementByPosition.keys),
              positions == Array(0 ..< positions.count)
        else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid classification change position")
        }
        var changes: [ClassificationPlanChange] = []
        for position in positions {
            if let storedChange = storedByPosition[position] {
                changes.append(
                    try classificationPlanChange(
                        from: storedChange,
                        selectionRowsByKey: context.selectionRowsByKey,
                        consumedSelectionKeys: &context.consumedSelectionKeys
                    )
                )
            } else if let managementChange = managementByPosition[position] {
                changes.append(
                    try classificationManagementPlanChange(
                        from: managementChange,
                        impactChainIDs: context.impactChainIDs,
                        impactTraceIDs: context.impactTraceIDs,
                        impactEventIDs: context.impactEventIDs,
                        consumedImpactKeys: &context.consumedImpactKeys
                    )
                )
            }
        }
        let notices = context.noticesByRecordID[row.id] ?? []
        guard let finalization = context.finalizationsByRecordID[row.id],
              finalization.changeCount == changes.count,
              finalization.noticeCount == notices.count,
              let planDigest = context.planDigestsByRecordID[row.id],
              let integrityDigest = context.integrityDigestsByRecordID[row.id]
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "classification change record finalized child count does not match"
            )
        }
        return ClassificationChangeRecord(
            id: row.id,
            planID: row.planID,
            interactionID: row.interactionID,
            source: row.source,
            decisionID: row.decisionID,
            changes: changes,
            notices: notices,
            committedAt: row.committedAt,
            revision: row.revision,
            planDigest: planDigest,
            integrityDigest: integrityDigest
        )
    }

    func validateConsumedClassificationChangeChildren(
        _ context: SQLiteClassificationChangeLoadContext
    ) throws {
        guard Set(context.selectionRowsByKey.keys).isSubset(of: context.consumedSelectionKeys) else {
            throw SQLiteRepositoryError.invalidStoredValue("classification selection belongs to a non-selection change")
        }
        let allImpactKeys = Set(context.impactChainIDs.keys)
            .union(context.impactTraceIDs.keys)
            .union(context.impactEventIDs.keys)
        guard allImpactKeys.isSubset(of: context.consumedImpactKeys) else {
            throw SQLiteRepositoryError.invalidStoredValue("classification merge impact belongs to a non-merge change")
        }
    }

    func loadClassificationMergeImpactIDs(
        table: String,
        idColumn: String,
        from database: Database?
    ) throws -> [SQLiteClassificationChangeKey: [UUID]] {
        let rows = try query(
            """
            SELECT record_id, change_position, item_position, \(idColumn)
            FROM \(table)
            ORDER BY record_id, change_position, item_position
            """,
            on: database
        ) { statement in
            (
                SQLiteClassificationChangeKey(
                    recordID: try uuid(statement, 0),
                    position: int(statement, 1)
                ),
                int(statement, 2),
                try uuid(statement, 3)
            )
        }
        var values: [SQLiteClassificationChangeKey: [UUID]] = [:]
        for (key, position, id) in rows {
            let expectedPosition = values[key]?.count ?? 0
            guard position == expectedPosition else {
                throw SQLiteRepositoryError.invalidStoredValue("invalid classification merge impact position")
            }
            values[key, default: []].append(id)
        }
        return values
    }

    func loadClassificationManagementChangeRows(
        from database: Database?
    ) throws -> [UUID: [SQLiteClassificationManagementChangeRow]] {
        let rows = try query(
            """
            SELECT
                record_id, position, kind, item_kind, item_id, name, color_hex,
                target_id, target_name, source_lifecycle, lifecycle,
                migrated_relation_count, deduplicated_relation_count,
                current_relation_count, relation_history_count, historical_event_count,
                merge_source_count, merge_target_count
            FROM classification_management_changes
            ORDER BY record_id, position
            """,
            on: database
        ) { statement in
            guard let itemKind = ClassificationItemKind(rawValue: try string(statement, 3)) else {
                throw SQLiteRepositoryError.invalidStoredValue("invalid classification management item kind")
            }
            return SQLiteClassificationManagementChangeRow(
                recordID: try uuid(statement, 0),
                position: int(statement, 1),
                kind: try string(statement, 2),
                itemKind: itemKind,
                itemID: try string(statement, 4),
                name: try string(statement, 5),
                colorHex: optionalString(statement, 6),
                targetID: optionalString(statement, 7),
                targetName: optionalString(statement, 8),
                sourceLifecycle: try optionalClassificationLifecycle(optionalString(statement, 9)),
                lifecycle: try optionalClassificationLifecycle(optionalString(statement, 10)),
                migratedRelationCount: optionalInt(statement, 11),
                deduplicatedRelationCount: optionalInt(statement, 12),
                currentRelationCount: optionalInt(statement, 13),
                relationHistoryCount: optionalInt(statement, 14),
                historicalEventCount: optionalInt(statement, 15),
                mergeSourceCount: optionalInt(statement, 16),
                mergeTargetCount: optionalInt(statement, 17)
            )
        }
        return Dictionary(grouping: rows, by: \.recordID)
    }

    func classificationManagementPlanChange(
        from stored: SQLiteClassificationManagementChangeRow,
        impactChainIDs: [SQLiteClassificationChangeKey: [UUID]],
        impactTraceIDs: [SQLiteClassificationChangeKey: [UUID]],
        impactEventIDs: [SQLiteClassificationChangeKey: [UUID]],
        consumedImpactKeys: inout Set<SQLiteClassificationChangeKey>
    ) throws -> ClassificationPlanChange {
        guard UUID(uuidString: stored.itemID) != nil else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid classification management item ID")
        }
        let key = SQLiteClassificationChangeKey(recordID: stored.recordID, position: stored.position)
        switch stored.kind {
        case "create":
            guard let colorHex = stored.colorHex,
                  stored.targetID == nil,
                  stored.targetName == nil,
                  stored.sourceLifecycle == nil,
                  stored.lifecycle == nil,
                  stored.migratedRelationCount == nil,
                  stored.deduplicatedRelationCount == nil,
                  stored.currentRelationCount == nil,
                  stored.relationHistoryCount == nil,
                  stored.historicalEventCount == nil,
                  stored.mergeSourceCount == nil,
                  stored.mergeTargetCount == nil,
                  impactChainIDs[key] == nil,
                  impactTraceIDs[key] == nil,
                  impactEventIDs[key] == nil
            else {
                throw SQLiteRepositoryError.invalidStoredValue("invalid create classification change")
            }
            return .create(
                kind: stored.itemKind,
                itemID: stored.itemID,
                name: stored.name,
                colorHex: colorHex
            )
        case "merge":
            guard stored.colorHex == nil,
                  let targetID = stored.targetID,
                  UUID(uuidString: targetID) != nil,
                  let targetName = stored.targetName,
                  let sourceLifecycle = stored.sourceLifecycle,
                  stored.lifecycle == nil,
                  let migratedRelationCount = stored.migratedRelationCount,
                  let deduplicatedRelationCount = stored.deduplicatedRelationCount,
                  stored.currentRelationCount == nil,
                  stored.relationHistoryCount == nil,
                  stored.historicalEventCount == nil,
                  stored.mergeSourceCount == nil,
                  stored.mergeTargetCount == nil
            else {
                throw SQLiteRepositoryError.invalidStoredValue("invalid merge classification change")
            }
            consumedImpactKeys.insert(key)
            return .merge(
                kind: stored.itemKind,
                sourceID: stored.itemID,
                sourceName: stored.name,
                targetID: targetID,
                targetName: targetName,
                sourceLifecycle: sourceLifecycle,
                impact: ClassificationMergeImpact(
                    currentChainIDs: (impactChainIDs[key] ?? []).map(TaskChainID.init),
                    historicalTraceIDs: (impactTraceIDs[key] ?? []).map(DayTraceID.init),
                    historicalEventIDs: impactEventIDs[key] ?? [],
                    migratedRelationCount: migratedRelationCount,
                    deduplicatedRelationCount: deduplicatedRelationCount
                )
            )
        case "hardDelete":
            guard stored.colorHex == nil,
                  stored.targetID == nil,
                  stored.targetName == nil,
                  stored.sourceLifecycle == nil,
                  let lifecycle = stored.lifecycle,
                  stored.migratedRelationCount == nil,
                  stored.deduplicatedRelationCount == nil,
                  let currentRelationCount = stored.currentRelationCount,
                  let relationHistoryCount = stored.relationHistoryCount,
                  let historicalEventCount = stored.historicalEventCount,
                  let mergeSourceCount = stored.mergeSourceCount,
                  let mergeTargetCount = stored.mergeTargetCount,
                  impactChainIDs[key] == nil,
                  impactTraceIDs[key] == nil,
                  impactEventIDs[key] == nil
            else {
                throw SQLiteRepositoryError.invalidStoredValue("invalid hard-delete classification change")
            }
            return .hardDelete(
                kind: stored.itemKind,
                itemID: stored.itemID,
                name: stored.name,
                lifecycle: lifecycle,
                verifiedReferences: ClassificationReferenceSummary(
                    currentRelationCount: currentRelationCount,
                    relationHistoryCount: relationHistoryCount,
                    historicalEventCount: historicalEventCount,
                    mergeSourceCount: mergeSourceCount,
                    mergeTargetCount: mergeTargetCount
                )
            )
        default:
            throw SQLiteRepositoryError.invalidStoredValue("invalid classification management change kind")
        }
    }

    func loadClassificationSelectionRows(
        from database: Database?
    ) throws -> [SQLiteClassificationSelectionKey: [SQLiteClassificationSelectionItemRow]] {
        let rows = try query(
            """
            SELECT
                record_id, change_position, selection_side, item_position,
                item_id, item_kind, name, color_hex, resolution
            FROM classification_change_selection_items
            ORDER BY record_id, change_position, selection_side, item_position
            """,
            on: database
        ) { statement in
            guard let side = SQLiteClassificationSelectionSide(rawValue: try string(statement, 2)),
                  let kind = ClassificationItemKind(rawValue: try string(statement, 5)),
                  let resolution = ClassificationPlanItemResolution(rawValue: try string(statement, 8))
            else {
                throw SQLiteRepositoryError.invalidStoredValue("invalid classification selection item")
            }
            let itemID = optionalString(statement, 4)
            guard resolution == .new || itemID != nil,
                  itemID.map({ UUID(uuidString: $0) != nil }) ?? true
            else {
                throw SQLiteRepositoryError.invalidStoredValue("invalid classification selection resolution")
            }
            let key = SQLiteClassificationSelectionKey(
                recordID: try uuid(statement, 0),
                changePosition: int(statement, 1),
                side: side
            )
            let row = SQLiteClassificationSelectionItemRow(
                position: int(statement, 3),
                item: ClassificationPlanItem(
                    id: itemID,
                    kind: kind,
                    name: try string(statement, 6),
                    colorHex: try string(statement, 7),
                    resolution: resolution
                )
            )
            return (key, row)
        }
        var rowsByKey: [
            SQLiteClassificationSelectionKey: [SQLiteClassificationSelectionItemRow]
        ] = [:]
        for (key, row) in rows {
            rowsByKey[key, default: []].append(row)
        }
        return rowsByKey
    }

    func loadClassificationChangeRows(
        from database: Database?
    ) throws -> [UUID: [SQLiteClassificationChangeRow]] {
        let rows = try query(
            """
            SELECT
                record_id, position, kind, chain_id, item_kind, item_id,
                before_name, after_name, name, before_lifecycle, after_lifecycle,
                before_approval, after_approval
            FROM classification_change_record_changes
            ORDER BY record_id, position
            """,
            on: database
        ) { statement in
            return SQLiteClassificationChangeRow(
                recordID: try uuid(statement, 0),
                position: int(statement, 1),
                kind: try string(statement, 2),
                chainID: try optionalUUID(statement, 3).map(TaskChainID.init),
                itemKind: try optionalClassificationItemKind(optionalString(statement, 4)),
                itemID: optionalString(statement, 5),
                beforeName: optionalString(statement, 6),
                afterName: optionalString(statement, 7),
                name: optionalString(statement, 8),
                beforeLifecycle: try optionalClassificationLifecycle(optionalString(statement, 9)),
                afterLifecycle: try optionalClassificationLifecycle(optionalString(statement, 10)),
                beforeApproval: try optionalCategoryPresentationApproval(optionalString(statement, 11)),
                afterApproval: try optionalCategoryPresentationApproval(optionalString(statement, 12))
            )
        }
        var rowsByRecordID: [UUID: [SQLiteClassificationChangeRow]] = [:]
        for row in rows {
            rowsByRecordID[row.recordID, default: []].append(row)
        }
        return rowsByRecordID
    }

    func loadClassificationChangeRecordRows(
        from database: Database?
    ) throws -> [SQLiteClassificationChangeRecordRow] {
        try query(
            """
            SELECT
                record_sequence, record_id, plan_id, interaction_id, source_kind,
                source_session_id, source_draft_id, source_draft_version, source_evidence_id,
                source_from_chain_id, source_reason,
                decision_id, committed_at, revision
            FROM classification_change_records
            ORDER BY record_sequence
            """,
            on: database
        ) { statement in
            let source = try classificationSource(
                SQLiteClassificationSourceRecord(
                    kind: try string(statement, 4),
                    sessionID: try optionalUUID(statement, 5),
                    draftID: try optionalUUID(statement, 6),
                    draftVersion: try strictOptionalInt(statement, 7),
                    evidenceID: try optionalUUID(statement, 8),
                    fromChainID: try optionalUUID(statement, 9).map(TaskChainID.init),
                    reason: optionalString(statement, 10)
                )
            )
            return SQLiteClassificationChangeRecordRow(
                sequence: int(statement, 0),
                id: try uuid(statement, 1),
                planID: try uuid(statement, 2),
                interactionID: try uuid(statement, 3),
                source: source,
                decisionID: try optionalUUID(statement, 11),
                committedAt: try classificationChangeDate(statement, 12),
                revision: try uint64(statement, 13)
            )
        }
    }

    func optionalClassificationItemKind(_ rawValue: String?) throws -> ClassificationItemKind? {
        guard let rawValue else { return nil }
        guard let value = ClassificationItemKind(rawValue: rawValue) else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid classification change item kind")
        }
        return value
    }

    func optionalClassificationLifecycle(_ rawValue: String?) throws -> ClassificationLifecycle? {
        guard let rawValue else { return nil }
        guard let value = ClassificationLifecycle(rawValue: rawValue) else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid classification change lifecycle")
        }
        return value
    }

    func categoryPresentationApproval(
        _ statement: OpaquePointer?,
        _ index: Int32
    ) throws -> CategoryPresentationApproval {
        let rawValue = try string(statement, index)
        guard let value = CategoryPresentationApproval(rawValue: rawValue) else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "invalid category presentation approval"
            )
        }
        return value
    }

    func optionalCategoryPresentationApproval(
        _ rawValue: String?
    ) throws -> CategoryPresentationApproval? {
        guard let rawValue else { return nil }
        guard let value = CategoryPresentationApproval(rawValue: rawValue) else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "invalid category presentation approval"
            )
        }
        return value
    }

    func classificationPlanChange(
        from stored: SQLiteClassificationChangeRow,
        selectionRowsByKey: [SQLiteClassificationSelectionKey: [SQLiteClassificationSelectionItemRow]],
        consumedSelectionKeys: inout Set<SQLiteClassificationSelectionKey>
    ) throws -> ClassificationPlanChange {
        let beforeKey = SQLiteClassificationSelectionKey(
            recordID: stored.recordID,
            changePosition: stored.position,
            side: .before
        )
        let afterKey = SQLiteClassificationSelectionKey(
            recordID: stored.recordID,
            changePosition: stored.position,
            side: .after
        )
        switch stored.kind {
        case "setCurrent":
            consumedSelectionKeys.insert(beforeKey)
            consumedSelectionKeys.insert(afterKey)
            return try setCurrentClassificationPlanChange(
                from: stored,
                beforeKey: beforeKey,
                afterKey: afterKey,
                selectionRowsByKey: selectionRowsByKey
            )
        case "rename":
            return try renameClassificationPlanChange(
                from: stored,
                beforeKey: beforeKey,
                afterKey: afterKey,
                selectionRowsByKey: selectionRowsByKey
            )
        case "lifecycle":
            return try lifecycleClassificationPlanChange(
                from: stored,
                beforeKey: beforeKey,
                afterKey: afterKey,
                selectionRowsByKey: selectionRowsByKey
            )
        case "categoryPresentationApproval":
            return try categoryPresentationApprovalPlanChange(
                from: stored,
                beforeKey: beforeKey,
                afterKey: afterKey,
                selectionRowsByKey: selectionRowsByKey
            )
        default:
            throw SQLiteRepositoryError.invalidStoredValue("invalid classification change kind")
        }
    }

    func setCurrentClassificationPlanChange(
        from stored: SQLiteClassificationChangeRow,
        beforeKey: SQLiteClassificationSelectionKey,
        afterKey: SQLiteClassificationSelectionKey,
        selectionRowsByKey: [SQLiteClassificationSelectionKey: [SQLiteClassificationSelectionItemRow]]
    ) throws -> ClassificationPlanChange {
        guard let chainID = stored.chainID,
              stored.itemKind == nil,
              stored.itemID == nil,
              stored.beforeName == nil,
              stored.afterName == nil,
              stored.name == nil,
              stored.beforeLifecycle == nil,
              stored.afterLifecycle == nil,
              stored.beforeApproval == nil,
              stored.afterApproval == nil
        else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid set-current classification change")
        }
        return try .setCurrent(
            chainID: chainID,
            before: classificationSelectionPreview(for: beforeKey, rowsByKey: selectionRowsByKey),
            after: classificationSelectionPreview(for: afterKey, rowsByKey: selectionRowsByKey)
        )
    }

    func renameClassificationPlanChange(
        from stored: SQLiteClassificationChangeRow,
        beforeKey: SQLiteClassificationSelectionKey,
        afterKey: SQLiteClassificationSelectionKey,
        selectionRowsByKey: [SQLiteClassificationSelectionKey: [SQLiteClassificationSelectionItemRow]]
    ) throws -> ClassificationPlanChange {
        guard stored.chainID == nil,
              let itemKind = stored.itemKind,
              let itemID = stored.itemID,
              let beforeName = stored.beforeName,
              let afterName = stored.afterName,
              stored.name == nil,
              stored.beforeLifecycle == nil,
              stored.afterLifecycle == nil,
              stored.beforeApproval == nil,
              stored.afterApproval == nil,
              selectionRowsByKey[beforeKey] == nil,
              selectionRowsByKey[afterKey] == nil
        else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid rename classification change")
        }
        return .rename(
            kind: itemKind,
            itemID: itemID,
            beforeName: beforeName,
            afterName: afterName
        )
    }

    func lifecycleClassificationPlanChange(
        from stored: SQLiteClassificationChangeRow,
        beforeKey: SQLiteClassificationSelectionKey,
        afterKey: SQLiteClassificationSelectionKey,
        selectionRowsByKey: [SQLiteClassificationSelectionKey: [SQLiteClassificationSelectionItemRow]]
    ) throws -> ClassificationPlanChange {
        guard stored.chainID == nil,
              let itemKind = stored.itemKind,
              let itemID = stored.itemID,
              stored.beforeName == nil,
              stored.afterName == nil,
              let name = stored.name,
              let before = stored.beforeLifecycle,
              let after = stored.afterLifecycle,
              stored.beforeApproval == nil,
              stored.afterApproval == nil,
              selectionRowsByKey[beforeKey] == nil,
              selectionRowsByKey[afterKey] == nil
        else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid lifecycle classification change")
        }
        return .lifecycle(
            kind: itemKind,
            itemID: itemID,
            name: name,
            before: before,
            after: after
        )
    }

    func categoryPresentationApprovalPlanChange(
        from stored: SQLiteClassificationChangeRow,
        beforeKey: SQLiteClassificationSelectionKey,
        afterKey: SQLiteClassificationSelectionKey,
        selectionRowsByKey: [SQLiteClassificationSelectionKey: [SQLiteClassificationSelectionItemRow]]
    ) throws -> ClassificationPlanChange {
        guard stored.chainID == nil,
              stored.itemKind == .category,
              let itemID = stored.itemID,
              stored.beforeName == nil,
              stored.afterName == nil,
              let name = stored.name,
              stored.beforeLifecycle == nil,
              stored.afterLifecycle == nil,
              let before = stored.beforeApproval,
              let after = stored.afterApproval,
              selectionRowsByKey[beforeKey] == nil,
              selectionRowsByKey[afterKey] == nil
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "invalid category presentation approval change"
            )
        }
        return .categoryPresentationApproval(
            itemID: itemID,
            name: name,
            before: before,
            after: after
        )
    }

    func classificationSelectionPreview(
        for key: SQLiteClassificationSelectionKey,
        rowsByKey: [SQLiteClassificationSelectionKey: [SQLiteClassificationSelectionItemRow]]
    ) throws -> ClassificationSelectionPreview {
        let rows = rowsByKey[key] ?? []
        guard rows.map(\.position) == Array(0 ..< rows.count) else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid classification selection item position")
        }
        var category: ClassificationPlanItem?
        var labels: [ClassificationPlanItem] = []
        for row in rows {
            switch row.item.kind {
            case .category:
                guard row.position == 0, category == nil else {
                    throw SQLiteRepositoryError.invalidStoredValue("invalid classification selection category")
                }
                category = row.item
            case .label:
                labels.append(row.item)
            }
        }
        return ClassificationSelectionPreview(category: category, labels: labels)
    }

    func classificationSource(
        _ stored: SQLiteClassificationSourceRecord
    ) throws -> ClassificationSource {
        switch stored.kind {
        case "userDirect":
            return try userDirectClassificationSource(stored)
        case "zhulongSuggestion":
            return try zhulongClassificationSource(stored)
        case "inherited":
            return try inheritedClassificationSource(stored)
        case "deterministicDomainAction":
            return try deterministicClassificationSource(stored)
        case "automaticAI":
            return try automaticAIClassificationSource(stored)
        default:
            throw SQLiteRepositoryError.invalidStoredValue("invalid classification source kind")
        }
    }

    func classificationSource(
        from statement: Statement?,
        startingAt index: Int32
    ) throws -> ClassificationSource {
        try classificationSource(
            SQLiteClassificationSourceRecord(
                kind: try string(statement, index),
                sessionID: try optionalUUID(statement, index + 1),
                draftID: try optionalUUID(statement, index + 2),
                draftVersion: try strictOptionalInt(statement, index + 3),
                evidenceID: try optionalUUID(statement, index + 4),
                fromChainID: try optionalUUID(statement, index + 5).map(TaskChainID.init),
                reason: optionalString(statement, index + 6)
            )
        )
    }

    func userDirectClassificationSource(
        _ stored: SQLiteClassificationSourceRecord
    ) throws -> ClassificationSource {
        guard stored.sessionID == nil, stored.draftID == nil, stored.draftVersion == nil,
              stored.evidenceID == nil, stored.fromChainID == nil, stored.reason == nil
        else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid user-direct classification source")
        }
        return .userDirect
    }

    func zhulongClassificationSource(
        _ stored: SQLiteClassificationSourceRecord
    ) throws -> ClassificationSource {
        guard let sessionID = stored.sessionID,
              let draftID = stored.draftID,
              let draftVersion = stored.draftVersion,
              let evidenceID = stored.evidenceID,
              stored.fromChainID == nil, stored.reason == nil
        else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid Zhulong classification source")
        }
        return .zhulongSuggestion(
            sessionID: sessionID,
            draftID: draftID,
            draftVersion: draftVersion,
            evidenceID: evidenceID
        )
    }

    func inheritedClassificationSource(
        _ stored: SQLiteClassificationSourceRecord
    ) throws -> ClassificationSource {
        guard stored.sessionID == nil, stored.draftID == nil, stored.draftVersion == nil,
              stored.evidenceID == nil, let fromChainID = stored.fromChainID,
              stored.reason == nil
        else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid inherited classification source")
        }
        return .inherited(fromChainID: fromChainID)
    }

    func deterministicClassificationSource(
        _ stored: SQLiteClassificationSourceRecord
    ) throws -> ClassificationSource {
        guard stored.sessionID == nil, stored.draftID == nil, stored.draftVersion == nil,
              stored.evidenceID == nil, stored.fromChainID == nil, let reason = stored.reason
        else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid deterministic classification source")
        }
        return .deterministicDomainAction(reason: reason)
    }

    func automaticAIClassificationSource(
        _ stored: SQLiteClassificationSourceRecord
    ) throws -> ClassificationSource {
        guard let jobID = stored.sessionID,
              stored.draftID == nil,
              let generation = stored.draftVersion,
              generation > 0,
              stored.evidenceID == nil,
              stored.fromChainID == nil,
              stored.reason == nil
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "invalid automatic-AI classification source"
            )
        }
        return .automaticAI(jobID: jobID, generation: generation)
    }

    func loadClassificationReceipts(
        changeRecords knownChangeRecords: [ClassificationChangeRecord]? = nil,
        from database: Database?
    ) throws -> [UUID: ClassificationReceipt] {
        let noticeRows = try query(
            """
            SELECT
                interaction_id, position, kind, duplicate_name, item_kind,
                input_name, current_name, matched_historical_alias
            FROM classification_commit_notice_records
            ORDER BY interaction_id, position
            """,
            on: database
        ) { statement in
            (try uuid(statement, 0), int(statement, 1), try classificationNotice(statement))
        }
        var indexedNotices: [UUID: [Int: ClassificationNotice]] = [:]
        for (interactionID, position, notice) in noticeRows {
            guard indexedNotices[interactionID]?[position] == nil else {
                throw SQLiteRepositoryError.invalidStoredValue("duplicate classification notice position")
            }
            indexedNotices[interactionID, default: [:]][position] = notice
        }
        var noticesByInteractionID: [UUID: [ClassificationNotice]] = [:]
        for (interactionID, noticesByPosition) in indexedNotices {
            let positions = noticesByPosition.keys.sorted()
            guard positions == Array(0 ..< positions.count) else {
                throw SQLiteRepositoryError.invalidStoredValue("invalid classification notice position")
            }
            noticesByInteractionID[interactionID] = positions.compactMap { noticesByPosition[$0] }
        }

        let metadataRows = try query(
            """
            SELECT interaction_id, change_record_id, decision_id
            FROM classification_commit_receipt_metadata
            ORDER BY interaction_id
            """,
            on: database
        ) { statement in
            (
                try uuid(statement, 0),
                try uuid(statement, 1),
                try optionalUUID(statement, 2)
            )
        }
        let digestRows = try query(
            """
            SELECT interaction_id, digest
            FROM classification_commit_receipt_integrity_digests
            ORDER BY interaction_id
            """,
            on: database
        ) { statement in
            let digest = try string(statement, 1)
            guard isValidClassificationPlanDigest(digest) else {
                throw SQLiteRepositoryError.invalidStoredValue("invalid classification receipt digest")
            }
            return (try uuid(statement, 0), digest)
        }
        let digestsByInteractionID = Dictionary(uniqueKeysWithValues: digestRows)
        let metadataByInteractionID: [UUID: SQLiteClassificationReceiptMetadata] = Dictionary(
            uniqueKeysWithValues: try metadataRows.map { interactionID, changeRecordID, decisionID in
                guard let digest = digestsByInteractionID[interactionID] else {
                    throw SQLiteRepositoryError.invalidStoredValue(
                        "classification receipt integrity digest is missing"
                    )
                }
                return (
                    interactionID,
                    SQLiteClassificationReceiptMetadata(
                        changeRecordID: changeRecordID,
                        decisionID: decisionID,
                        integrityDigest: digest
                    )
                )
            }
        )
        let finalizationRows = try query(
            """
            SELECT interaction_id, notice_count
            FROM classification_commit_finalizations
            ORDER BY interaction_id
            """,
            on: database
        ) { statement in
            (try uuid(statement, 0), int(statement, 1))
        }
        let finalizedNoticeCounts = Dictionary(uniqueKeysWithValues: finalizationRows)
        let changeRecords = try knownChangeRecords ?? loadClassificationChangeRecords(from: database)
        let changeRecordsByID = Dictionary(uniqueKeysWithValues: changeRecords.map { ($0.id, $0) })

        let receipts: [(UUID, ClassificationReceipt)] = try query(
            """
            SELECT interaction_id, plan_id, revision
            FROM classification_commits
            ORDER BY interaction_id
            """,
            on: database
        ) { statement in
            let interactionID = try uuid(statement, 0)
            let planID = try uuid(statement, 1)
            let revision = try uint64(statement, 2)
            let row = SQLiteClassificationReceiptRow(
                interactionID: interactionID,
                planID: planID,
                revision: revision,
                notices: noticesByInteractionID[interactionID] ?? []
            )
            return (
                interactionID,
                try classificationReceipt(
                    row: row,
                    metadata: metadataByInteractionID[interactionID],
                    changeRecordsByID: changeRecordsByID
                )
            )
        }
        let receiptInteractionIDs = Set(receipts.map(\.0))
        guard Set(metadataByInteractionID.keys) == receiptInteractionIDs,
              Set(digestsByInteractionID.keys) == receiptInteractionIDs,
              Set(finalizedNoticeCounts.keys) == receiptInteractionIDs,
              Set(indexedNotices.keys).isSubset(of: receiptInteractionIDs),
              receipts.allSatisfy({ interactionID, receipt in
                  finalizedNoticeCounts[interactionID] == receipt.notices.count
              })
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "classification receipt facts or finalization are inconsistent"
            )
        }
        return Dictionary(uniqueKeysWithValues: receipts)
    }

    func classificationNotice(_ statement: Statement?) throws -> ClassificationNotice {
        switch try string(statement, 2) {
        case "duplicateLabelCollapsed":
            guard let name = optionalString(statement, 3) else {
                throw SQLiteRepositoryError.invalidStoredValue("missing duplicate classification notice name")
            }
            return .duplicateLabelCollapsed(name: name)
        case "existingItemReused":
            guard let rawItemKind = optionalString(statement, 4),
                  let itemKind = ClassificationItemKind(rawValue: rawItemKind),
                  let inputName = optionalString(statement, 5),
                  let currentName = optionalString(statement, 6),
                  let matchedHistoricalAlias = optionalInt(statement, 7),
                  matchedHistoricalAlias == 0 || matchedHistoricalAlias == 1
            else {
                throw SQLiteRepositoryError.invalidStoredValue("invalid reused classification notice")
            }
            return .existingItemReused(
                kind: itemKind,
                inputName: inputName,
                currentName: currentName,
                matchedHistoricalAlias: matchedHistoricalAlias == 1
            )
        default:
            throw SQLiteRepositoryError.invalidStoredValue("invalid classification notice kind")
        }
    }

    func classificationReceipt(
        row: SQLiteClassificationReceiptRow,
        metadata: SQLiteClassificationReceiptMetadata?,
        changeRecordsByID: [UUID: ClassificationChangeRecord]
    ) throws -> ClassificationReceipt {
        guard let metadata else {
            throw SQLiteRepositoryError.invalidStoredValue("classification receipt metadata is missing")
        }
        guard let record = changeRecordsByID[metadata.changeRecordID],
              record.planID == row.planID,
              record.interactionID == row.interactionID,
              record.revision == row.revision,
              record.decisionID == metadata.decisionID,
              record.integrityDigest == metadata.integrityDigest
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "classification receipt does not match its change record"
            )
        }
        return ClassificationReceipt(
            planID: row.planID,
            revision: row.revision,
            notices: row.notices,
            changeRecordID: metadata.changeRecordID,
            decisionID: metadata.decisionID,
            changeRecordIntegrityDigest: metadata.integrityDigest
        )
    }

    func classificationSnapshotsAreEqual(
        _ lhs: TraceClassificationSnapshot,
        _ rhs: TraceClassificationSnapshot
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.traceID == rhs.traceID
            && lhs.status == rhs.status
            && lhs.category == rhs.category
            && lhs.capturedAt == rhs.capturedAt
            && lhs.revision == rhs.revision
            && lhs.labels.sorted(by: classificationLabelIdentityOrder)
                == rhs.labels.sorted(by: classificationLabelIdentityOrder)
    }

    func classificationChangeRecordFactsAreEqual(
        _ lhs: ClassificationChangeRecord,
        _ rhs: ClassificationChangeRecord
    ) -> Bool {
        lhs == rhs
    }

    func isValidClassificationPlanDigest(_ digest: String) -> Bool {
        digest.utf8.count == 64 && digest.utf8.allSatisfy {
            (48 ... 57).contains($0) || (97 ... 102).contains($0)
        }
    }

    func classificationNameVersionFactsAreEqual(
        _ lhs: ClassificationNameVersion,
        _ rhs: ClassificationNameVersion
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.canonicalKey == rhs.canonicalKey
            && lhs.canonicalKeyVersion == rhs.canonicalKeyVersion
            && lhs.validFrom == rhs.validFrom
    }

    func classificationLabelOrder(_ lhs: HistoricalLabelValue, _ rhs: HistoricalLabelValue) -> Bool {
        let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        return classificationLabelIdentityOrder(lhs, rhs)
    }

    func classificationLabelIdentityOrder(_ lhs: HistoricalLabelValue, _ rhs: HistoricalLabelValue) -> Bool {
        lhs.id.description < rhs.id.description
    }

    func loadPreferences(from database: Database?) throws -> AppPreferences {
        let rows = try query(
            """
            SELECT
                theme, language,
                theme_language_updated_at, theme_language_updated_at_bits,
                theme_language_writer_id
            FROM app_preferences
            WHERE id = 1
            """,
            on: database
        ) { statement in
            (
                try string(statement, 0),
                try string(statement, 1),
                try validatedExactDate(
                    statement,
                    textIndex: 2,
                    bitsIndex: 3
                ),
                try string(statement, 4)
            )
        }
        guard let row = rows.first else {
            return AppPreferences()
        }
        guard let theme = AppTheme(rawValue: row.0), let language = AppLanguage(rawValue: row.1) else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid app preferences")
        }
        return AppPreferences(
            theme: theme,
            language: language,
            themeLanguageUpdatedAt: row.2,
            themeLanguageWriterID: row.3,
            dataMode: try loadDataMode(from: database),
            backupPolicy: try loadBackupPolicy(from: database),
            localFirstSyncPolicy: try loadLocalFirstSyncPolicy(from: database),
            settingsPoemDisplayPolicy: try loadSettingsPoemDisplayPolicy(from: database)
        )
    }

    func loadDataMode(from database: Database?) throws -> AppDataMode {
        let rawValue = try settingValue(key: "app.data_mode", from: database)
        guard let rawValue else {
            return .localFirst
        }
        guard let dataMode = AppDataMode(rawValue: rawValue) else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid app data mode")
        }
        return dataMode
    }

    func loadBackupPolicy(from database: Database?) throws -> ScheduledBackupPolicy {
        let rawFrequency = try settingValue(key: "app.backup.frequency", from: database)
        let rawDestination = try settingValue(key: "app.backup.destination", from: database)
        let frequency: ScheduledBackupFrequency
        if let rawFrequency {
            guard let decoded = ScheduledBackupFrequency(rawValue: rawFrequency) else {
                throw SQLiteRepositoryError.invalidStoredValue("invalid scheduled backup frequency")
            }
            frequency = decoded
        } else {
            frequency = .off
        }

        let destination: BackupDestinationKind
        if let rawDestination {
            guard let decoded = BackupDestinationKind(rawValue: rawDestination) else {
                throw SQLiteRepositoryError.invalidStoredValue("invalid backup destination")
            }
            destination = decoded
        } else {
            destination = .iCloudDrive
        }

        return ScheduledBackupPolicy(frequency: frequency, destination: destination)
    }

    func loadLocalFirstSyncPolicy(from database: Database?) throws -> LocalFirstCloudSyncPolicy {
        let rawEndpoint = try settingValue(key: "app.local_first_sync.endpoint", from: database)
        let endpoint: CloudSyncEndpointKind
        if let rawEndpoint {
            guard let decoded = CloudSyncEndpointKind(rawValue: rawEndpoint) else {
                throw SQLiteRepositoryError.invalidStoredValue("invalid local-first sync endpoint")
            }
            endpoint = decoded
        } else {
            endpoint = .iCloud
        }

        let rawMode = try settingValue(key: "app.local_first_sync.mode", from: database)
        let mode: CloudSyncMode
        if let rawMode {
            guard let decoded = CloudSyncMode(rawValue: rawMode) else {
                throw SQLiteRepositoryError.invalidStoredValue("invalid local-first sync mode")
            }
            mode = decoded
        } else {
            mode = .manual
        }

        return LocalFirstCloudSyncPolicy(
            enabled: try loadBoolSetting(key: "app.local_first_sync.enabled", defaultValue: false, from: database),
            endpoint: endpoint,
            mode: mode,
            intervalSeconds: try loadIntSetting(key: "app.local_first_sync.interval_seconds", defaultValue: 300, from: database),
            generateConflictCopy: try loadBoolSetting(
                key: "app.local_first_sync.generate_conflict_copy",
                defaultValue: true,
                from: database
            ),
            snapshotRetention: SyncSnapshotRetentionPolicy(
                indexRetentionDays: try loadIntSetting(key: "app.local_first_sync.retention_days", defaultValue: 180, from: database),
                retentionIndexesDaily: try loadIntSetting(key: "app.local_first_sync.retention_daily", defaultValue: 2, from: database)
            )
        )
    }

    func loadSettingsPoemDisplayPolicy(from database: Database?) throws -> SettingsPoemDisplayPolicy {
        SettingsPoemDisplayPolicy(
            enabled: try loadBoolSetting(key: "app.settings_poem.enabled", defaultValue: true, from: database),
            text: try settingValue(key: "app.settings_poem.text", from: database) ?? SettingsPoemDisplayPolicy.defaultText
        )
    }

    func loadBoolSetting(key: String, defaultValue: Bool, from database: Database?) throws -> Bool {
        guard let rawValue = try settingValue(key: key, from: database) else {
            return defaultValue
        }
        switch rawValue {
        case "true":
            return true
        case "false":
            return false
        default:
            throw SQLiteRepositoryError.invalidStoredValue("invalid boolean setting \(key)")
        }
    }

    func loadIntSetting(key: String, defaultValue: Int, from database: Database?) throws -> Int {
        guard let rawValue = try settingValue(key: key, from: database) else {
            return defaultValue
        }
        guard let value = Int(rawValue) else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid integer setting \(key)")
        }
        return value
    }

    func settingValue(key: String, from database: Database?) throws -> String? {
        let rows = try query(
            "SELECT value FROM sync_settings WHERE key = ?",
            on: database,
            bind: { statement in
                bind(key, to: 1, in: statement)
            },
            row: { statement in
            optionalString(statement, 0)
            }
        )
        return rows.first ?? nil
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
