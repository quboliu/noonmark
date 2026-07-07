import Foundation
import SQLite3
import SuntraceSync

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
                displayName: optionalString(statement, 1),
                createdAt: try date(statement, 2)
            )
        }.first
    }

    public func saveMetadata(_ entry: SyncMetadataEntry) throws {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        let sql = """
        INSERT INTO sync_metadata(key, value, updated_at)
        VALUES (?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET
            value = excluded.value,
            updated_at = excluded.updated_at
        """
        try run(sql, on: database) { statement in
            bind(entry.key, to: 1, in: statement)
            bind(entry.value, to: 2, in: statement)
            bind(entry.updatedAt, to: 3, in: statement)
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
            SyncMetadataEntry(key: try string(statement, 0), value: data(statement, 1), updatedAt: try date(statement, 2))
        }.first
    }

    public func appendJournalEntry(_ entry: SyncJournalEntry) throws {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        let sql = """
        INSERT INTO change_journal(
            id, entity_type, entity_id, operation, changed_at, device_id, sync_state, retry_count, last_error
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            entity_type = excluded.entity_type,
            entity_id = excluded.entity_id,
            operation = excluded.operation,
            changed_at = excluded.changed_at,
            device_id = excluded.device_id,
            sync_state = excluded.sync_state,
            retry_count = excluded.retry_count,
            last_error = excluded.last_error
        """
        try run(sql, on: database) { statement in
            bind(entry.id, to: 1, in: statement)
            bind(entry.entityType.rawValue, to: 2, in: statement)
            bind(entry.entityID, to: 3, in: statement)
            bind(entry.operation.rawValue, to: 4, in: statement)
            bind(entry.changedAt, to: 5, in: statement)
            bind(entry.deviceID.rawValue, to: 6, in: statement)
            bind(entry.state.rawValue, to: 7, in: statement)
            bind(entry.retryCount, to: 8, in: statement)
            bind(entry.lastError, to: 9, in: statement)
        }
    }

    public func journalEntries(state: SyncChangeState? = nil, limit: Int? = nil) throws -> [SyncJournalEntry] {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        let sql = """
        SELECT id, entity_type, entity_id, operation, changed_at, device_id, sync_state, retry_count, last_error
        FROM change_journal
        WHERE (? IS NULL OR sync_state = ?)
        ORDER BY changed_at, id
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

    public func saveConflict(_ conflict: SyncConflict) throws {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        let sql = """
        INSERT INTO sync_conflicts(
            id, conflict_type, entity_type, entity_id, local_record_id, remote_record_id,
            local_payload, remote_payload, detected_at, resolved_at, resolution, message
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            conflict_type = excluded.conflict_type,
            entity_type = excluded.entity_type,
            entity_id = excluded.entity_id,
            local_record_id = excluded.local_record_id,
            remote_record_id = excluded.remote_record_id,
            detected_at = excluded.detected_at,
            resolution = excluded.resolution,
            message = excluded.message
        """
        try run(sql, on: database) { statement in
            bind(conflict.id, to: 1, in: statement)
            bind(conflict.type.rawValue, to: 2, in: statement)
            bind(conflict.entityType.rawValue, to: 3, in: statement)
            bind(conflict.entityID, to: 4, in: statement)
            bind(conflict.localRecordID?.rawValue, to: 5, in: statement)
            bind(conflict.remoteRecordID.rawValue, to: 6, in: statement)
            bind(nil as String?, to: 7, in: statement)
            bind(nil as String?, to: 8, in: statement)
            bind(conflict.detectedAt, to: 9, in: statement)
            bind(nil as Date?, to: 10, in: statement)
            bind(conflict.resolution.rawValue, to: 11, in: statement)
            bind(conflict.message, to: 12, in: statement)
        }
    }

    public func unresolvedConflicts() throws -> [SyncConflict] {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        return try query(
            """
            SELECT id, conflict_type, entity_type, entity_id, local_record_id, remote_record_id, detected_at, resolution, message
            FROM sync_conflicts
            WHERE resolution = 'unresolved'
            ORDER BY detected_at, id
            """,
            on: database,
            row: conflict(from:)
        )
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
        let sql = """
        INSERT INTO sync_audit_log(id, direction, entity_type, entity_id, action, created_at, message)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """
        try run(sql, on: database) { statement in
            bind(entry.id, to: 1, in: statement)
            bind(entry.direction.rawValue, to: 2, in: statement)
            bind(entry.entityType.rawValue, to: 3, in: statement)
            bind(entry.entityID, to: 4, in: statement)
            bind(entry.action, to: 5, in: statement)
            bind(entry.createdAt, to: 6, in: statement)
            bind(entry.message, to: 7, in: statement)
        }
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
        for statement in SQLiteSchema.statements {
            try execute(statement, on: database)
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
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    func bind(_ value: Int, to index: Int32, in statement: Statement?) {
        sqlite3_bind_int(statement, index, Int32(value))
    }

    func bind(_ value: UUID, to index: Int32, in statement: Statement?) {
        bind(value.uuidString, to: index, in: statement)
    }

    func bind(_ value: Date?, to index: Int32, in statement: Statement?) {
        bind(value.map(Self.string(from:)), to: index, in: statement)
    }

    func bind(_ value: Data, to index: Int32, in statement: Statement?) {
        _ = value.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(value.count), SQLITE_TRANSIENT)
        }
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
        Int(sqlite3_column_int(statement, index))
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

    func data(_ statement: Statement?, _ index: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }

    func journalEntry(from statement: Statement?) throws -> SyncJournalEntry {
        guard let entityType = SyncEntityType(rawValue: try string(statement, 1)) else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid sync entity type")
        }
        guard let operation = SyncOperation(rawValue: try string(statement, 3)) else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid sync operation")
        }
        guard let state = SyncChangeState(rawValue: try string(statement, 6)) else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid sync state")
        }
        return SyncJournalEntry(
            id: try uuid(statement, 0),
            entityType: entityType,
            entityID: try string(statement, 2),
            operation: operation,
            changedAt: try date(statement, 4),
            deviceID: SyncDeviceID(try string(statement, 5)),
            state: state,
            retryCount: int(statement, 7),
            lastError: optionalString(statement, 8)
        )
    }

    func conflict(from statement: Statement?) throws -> SyncConflict {
        guard let type = SyncConflictType(rawValue: try string(statement, 1)) else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid sync conflict type")
        }
        guard let entityType = SyncEntityType(rawValue: try string(statement, 2)) else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid sync conflict entity type")
        }
        guard let resolution = SyncConflictResolution(rawValue: try string(statement, 7)) else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid sync conflict resolution")
        }
        return SyncConflict(
            id: try uuid(statement, 0),
            type: type,
            entityType: entityType,
            entityID: try string(statement, 3),
            localRecordID: optionalString(statement, 4).map(SyncRecordID.init),
            remoteRecordID: SyncRecordID(try string(statement, 5)),
            detectedAt: try date(statement, 6),
            message: optionalString(statement, 8) ?? "Stored sync conflict",
            resolution: resolution
        )
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
            message: optionalString(statement, 6)
        )
    }

    func lastError(_ database: Database?) -> String {
        database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite error"
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
