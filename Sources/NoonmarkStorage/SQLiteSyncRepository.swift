import Foundation
import NoonmarkCore
import NoonmarkSync
import SQLite3

public struct SyncPendingDownloadRecord: Equatable, Sendable {
    public let record: SyncRecord
    public let generationID: UUID
    public let dependencies: [ClassificationCommitDependency]
    public let firstSeenAt: Date
    public let lastAttemptedAt: Date
    public let attemptCount: Int

    public init(
        record: SyncRecord,
        generationID: UUID,
        dependencies: [ClassificationCommitDependency],
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
    let snapshot: NoonmarkSnapshot
    let conflicts: [SyncConflict]
    let waiting: [SyncWaitingRecord]
    let terminal: [SyncPendingDownloadRecord]
    let auditEntries: [SyncAuditLogEntry]
    let metadata: SyncMetadataEntry
    let attemptedAt: Date
}

public final class SQLiteSyncRepository {
    private let databaseURL: URL

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
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
                deviceID: SyncDeviceID(try string(statement, 0)),
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
            SyncMetadataEntry(key: try string(statement, 0), value: data(statement, 1), updatedAt: try date(statement, 2))
        }.first
    }

    public func appendJournalEntry(_ entry: SyncJournalEntry) throws {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        try execute("BEGIN IMMEDIATE TRANSACTION", on: database)
        do {
            try SQLiteJournalCAS.insertOrValidateExact(entry, into: database)
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
        let sql = """
        SELECT id, entity_type, entity_id, operation, changed_at, changed_at_bits,
            device_id, sync_state, retry_count, last_error, record_payload
        FROM change_journal
        WHERE (? IS NULL OR sync_state = ?)
        ORDER BY changed_at,
            CASE entity_type
                WHEN 'taskChain' THEN 0
                WHEN 'taskDefinition' THEN 1
                WHEN 'day' THEN 2
                WHEN 'classificationCommit' THEN 3
                WHEN 'dayTrace' THEN 4
                WHEN 'traceClassificationEvent' THEN 5
                WHEN 'subtask' THEN 6
                WHEN 'appPreferences' THEN 7
                ELSE 8
            END,
            entity_id,
            id
        LIMIT ?
        """
        return try query(sql, on: database) { statement in
            bind(state?.rawValue, to: 1, in: statement)
            bind(state?.rawValue, to: 2, in: statement)
            bind(limit ?? Int(Int32.max), to: 3, in: statement)
        } row: { statement in
            try journalEntry(from: statement)
        }
    }

    public func markJournalEntriesUploaded(_ ids: [UUID]) throws {
        try updateJournalEntries(ids) { database, id in
            try run(
                "UPDATE change_journal SET sync_state = 'uploaded', last_error = NULL WHERE id = ?",
                on: database
            ) { statement in
                bind(id, to: 1, in: statement)
            }
        }
    }

    public func markJournalEntryFailed(_ id: UUID, error: String) throws {
        try updateJournalEntries([id]) { database, id in
            try run(
                """
                UPDATE change_journal
                SET sync_state = 'failed',
                    retry_count = retry_count + 1,
                    last_error = ?
                WHERE id = ?
                """,
                on: database
            ) { statement in
                bind(error, to: 1, in: statement)
                bind(id, to: 2, in: statement)
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

    public func reconcilePendingDownloads(
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
        try execute("BEGIN IMMEDIATE TRANSACTION", on: database)
        do {
            try reconcilePendingDownloads(
                waiting: waiting,
                terminal: terminal,
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
        let preparedConflicts: [(conflict: SyncConflict, remotePayload: Data)] = try commit.conflicts.map {
            ($0, try validatedConflictRemotePayload($0))
        }

        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        try execute("BEGIN IMMEDIATE TRANSACTION", on: database)
        do {
            try engineRepository.persistValidatedSnapshot(commit.snapshot, into: database)
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
                attemptedAt: commit.attemptedAt,
                into: database
            )
            for entry in commit.auditEntries {
                try appendAuditLog(entry, into: database)
            }
            try saveMetadata(commit.metadata, into: database)
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
            SELECT id, direction, entity_type, entity_id, action, created_at, message
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
}

private extension SQLiteSyncRepository {
    typealias Database = OpaquePointer
    typealias Statement = OpaquePointer

    struct PendingDependencyRow {
        let recordID: SyncRecordID
        let dependency: ClassificationCommitDependency
    }

    static func makeDateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    static func string(from date: Date) -> String {
        makeDateFormatter().string(from: date)
    }

    static func date(from string: String) -> Date? {
        makeDateFormatter().date(from: string)
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
        return database
    }

    func applySchema(on database: Database?) throws {
        try SQLiteSchema.installOrValidate(on: database)
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
                "only current classification commits can wait for download dependencies"
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
        attemptedAt: Date,
        into database: Database?
    ) throws {
        let storedByID = Dictionary(
            uniqueKeysWithValues: try pendingDownloads(from: database).map {
                ($0.record.id, $0)
            }
        )
        for pending in waiting {
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
              recordsMatchExactly(stored.remoteRecord, conflict.remoteRecord)
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
            ON CONFLICT(entity_type, entity_id) DO NOTHING
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
        guard storedConflictIDs == [rejection.conflict.id] else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "terminal immutable record identity collided with different evidence"
            )
        }
    }

    func appendAuditLog(_ entry: SyncAuditLogEntry, into database: Database?) throws {
        try run(
            """
            INSERT INTO sync_audit_log(
                id, direction, entity_type, entity_id, action, created_at, message
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            on: database
        ) { statement in
            bind(entry.id, to: 1, in: statement)
            bind(entry.direction.rawValue, to: 2, in: statement)
            bind(entry.entityType.rawValue, to: 3, in: statement)
            bind(entry.entityID, to: 4, in: statement)
            bind(entry.action, to: 5, in: statement)
            bind(entry.createdAt, to: 6, in: statement)
            bind(entry.message, to: 7, in: statement)
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
                modified_by_device_id, payload, first_seen_at_bits,
                last_attempted_at_bits, attempt_count
            FROM sync_pending_download_records
            ORDER BY record_id
            """,
            on: database
        ) { statement in
            let recordID = try syncRecordID(statement, 0)
            let generationID = try uuid(statement, 1)
            guard let entityType = SyncEntityType(rawValue: try string(statement, 2)),
                  entityType.requiresImmutableRecordPayload
            else {
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
                payload: data(statement, 7)
            )
            guard waitingRecordIsCurrent(record) else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "pending download payload is not a current immutable classification record"
                )
            }
            let firstSeenAt = try exactDate(statement, 8)
            let lastAttemptedAt = try exactDate(statement, 9)
            let attemptCount = try int(statement, 10)
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
            guard stored.record == waiting.record else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "pending download record identity collision: \(waiting.record.id.rawValue)"
                )
            }
            guard attemptedAt >= stored.lastAttemptedAt else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "pending download attempt time moved backwards"
                )
            }
            try run(
                """
                UPDATE sync_pending_download_records
                SET last_attempted_at_bits = ?, attempt_count = attempt_count + 1
                WHERE record_id = ?
                """,
                on: database
            ) { statement in
                bindExactDate(attemptedAt, to: 1, in: statement)
                bind(waiting.record.id.rawValue, to: 2, in: statement)
            }
        } else {
            try run(
                """
                INSERT INTO sync_pending_download_records(
                    record_id, generation_id, entity_type, entity_id, operation, modified_at_bits,
                    modified_by_device_id, payload, first_seen_at_bits,
                    last_attempted_at_bits, attempt_count
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
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
                bindExactDate(attemptedAt, to: 9, in: statement)
                bindExactDate(attemptedAt, to: 10, in: statement)
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
        let dependency: ClassificationCommitDependency
        switch kind {
        case "taskChain":
            dependency = .taskChain(TaskChainID(try pendingDependencyUUID(rawID, kind: kind)))
        case "dayTrace":
            dependency = .dayTrace(DayTraceID(try pendingDependencyUUID(rawID, kind: kind)))
        case "category":
            dependency = .category(TaskCategoryID(try pendingDependencyUUID(rawID, kind: kind)))
        case "label":
            dependency = .label(TaskLabelID(try pendingDependencyUUID(rawID, kind: kind)))
        case "classificationEvent":
            dependency = .classificationEvent(try pendingDependencyUUID(rawID, kind: kind))
        case "classificationCommit":
            dependency = .classificationCommit(try pendingDependencyUUID(rawID, kind: kind))
        case "classificationRevision":
            guard let revision = UInt64(rawID), revision.description == rawID else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "invalid pending classification revision dependency"
                )
            }
            dependency = .classificationRevision(revision)
        default:
            throw SQLiteRepositoryError.invalidStoredValue(
                "invalid pending download dependency kind"
            )
        }
        return PendingDependencyRow(recordID: recordID, dependency: dependency)
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
        _ dependency: ClassificationCommitDependency
    ) -> (kind: String, id: String) {
        switch dependency {
        case let .taskChain(id):
            ("taskChain", id.description)
        case let .dayTrace(id):
            ("dayTrace", id.description)
        case let .category(id):
            ("category", id.description)
        case let .label(id):
            ("label", id.description)
        case let .classificationEvent(id):
            ("classificationEvent", id.uuidString)
        case let .classificationCommit(id):
            ("classificationCommit", id.uuidString)
        case let .classificationRevision(revision):
            ("classificationRevision", revision.description)
        }
    }

    func dependencySort(
        _ lhs: ClassificationCommitDependency,
        _ rhs: ClassificationCommitDependency
    ) -> Bool {
        let lhsFact = dependencyFact(lhs)
        let rhsFact = dependencyFact(rhs)
        return (lhsFact.kind, lhsFact.id) < (rhsFact.kind, rhsFact.id)
    }

    func waitingRecordIsCurrent(_ waiting: SyncWaitingRecord) -> Bool {
        waitingRecordIsCurrent(waiting.record)
    }

    func waitingRecordIsCurrent(_ record: SyncRecord) -> Bool {
        guard record.entityType.requiresImmutableRecordPayload,
              record.operation == .upsert,
              record.payload.isEmpty == false
        else { return false }
        guard let payload = try? SyncRecordMapper().payload(from: record) else {
            return false
        }
        switch payload {
        case .classificationCommit, .traceClassificationEvent:
            return true
        case .day, .taskChain, .taskDefinition, .dayTrace, .subtask, .appPreferences:
            return false
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
            && recordsMatchExactly(stored.record, observed.record)
            && stored.dependencies == observed.dependencies
            && exactDateBits(stored.firstSeenAt) == exactDateBits(observed.firstSeenAt)
            && exactDateBits(stored.lastAttemptedAt) == exactDateBits(observed.lastAttemptedAt)
            && stored.attemptCount == observed.attemptCount
    }

    func recordsMatchExactly(_ lhs: SyncRecord, _ rhs: SyncRecord) -> Bool {
        lhs.id == rhs.id
            && lhs.entityType == rhs.entityType
            && lhs.entityID == rhs.entityID
            && lhs.operation == rhs.operation
            && exactDateBits(lhs.modifiedAt) == exactDateBits(rhs.modifiedAt)
            && lhs.modifiedByDeviceID == rhs.modifiedByDeviceID
            && lhs.payload == rhs.payload
    }

    func dateIsFinite(_ value: Date) -> Bool {
        value.timeIntervalSinceReferenceDate.isFinite
    }

    func exactDateBits(_ value: Date) -> UInt64 {
        value.timeIntervalSinceReferenceDate.bitPattern
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
            throw SQLiteRepositoryError.stepFailed(lastError(database))
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
                throw SQLiteRepositoryError.stepFailed(lastError(database))
            }
            rows.append(try row(statement))
        }
    }

    func updateJournalEntries(_ ids: [UUID], update: (Database?, UUID) throws -> Void) throws {
        guard ids.isEmpty == false else { return }
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
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
        guard entityType.requiresImmutableRecordPayload == (recordPayload != nil) else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "immutable sync journal payload invariant is invalid"
            )
        }
        return SyncJournalEntry(
            id: try uuid(statement, 0),
            entityType: entityType,
            entityID: try string(statement, 2),
            operation: operation,
            changedAt: changedAt,
            deviceID: SyncDeviceID(try string(statement, 6)),
            state: state,
            retryCount: try int(statement, 8),
            lastError: try optionalString(statement, 9),
            recordPayload: recordPayload
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

    func conflict(from statement: Statement?) throws -> SyncConflict {
        guard let type = SyncConflictType(rawValue: try string(statement, 1)) else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid sync conflict type")
        }
        guard let entityType = SyncEntityType(rawValue: try string(statement, 2)) else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid sync conflict entity type")
        }
        let entityID = try string(statement, 3)
        let remoteRecordID = SyncRecordID(try string(statement, 5))
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
            localRecordID: try optionalString(statement, 4).map(SyncRecordID.init),
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
            action: try string(statement, 4),
            createdAt: try date(statement, 5),
            message: try optionalString(statement, 6)
        )
    }

    func lastError(_ database: Database?) -> String {
        database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite error"
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
