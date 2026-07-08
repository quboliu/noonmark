import Foundation
import SQLite3
import SuntraceCore
import SuntraceSync

public final class SQLiteEngineRepository {
    private let databaseURL: URL

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    public func save(_ engine: SuntraceEngine) throws {
        try save(engine.snapshot())
    }

    public func save(_ snapshot: SuntraceSnapshot) throws {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        try execute("BEGIN IMMEDIATE TRANSACTION", on: database)
        do {
            try upsert(snapshot.preferences, into: database)
            try upsert(snapshot.days, into: database)
            try upsert(snapshot.chains, into: database)
            try upsert(snapshot.definitions, into: database)
            try upsert(snapshot.traces, into: database)
            try upsert(snapshot.subtasks, into: database)
            try execute("COMMIT", on: database)
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    public func save(
        _ snapshot: SuntraceSnapshot,
        recordingChangesFor deviceID: SyncDeviceID,
        changedAt: Date = Date()
    ) throws {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        let oldSnapshot = try loadSnapshot(from: database)
        let journalEntries = SyncSnapshotDiffer().journalEntries(
            from: oldSnapshot,
            to: snapshot,
            changedAt: changedAt,
            deviceID: deviceID
        )

        try execute("BEGIN IMMEDIATE TRANSACTION", on: database)
        do {
            try upsert(snapshot.preferences, into: database)
            try upsert(snapshot.days, into: database)
            try upsert(snapshot.chains, into: database)
            try upsert(snapshot.definitions, into: database)
            try upsert(snapshot.traces, into: database)
            try upsert(snapshot.subtasks, into: database)
            try appendJournalEntries(journalEntries, into: database)
            try execute("COMMIT", on: database)
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    public func load() throws -> SuntraceEngine {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try applySchema(on: database)
        return try SuntraceEngine(snapshot: loadSnapshot(from: database))
    }
}

public enum SQLiteRepositoryError: Error, Equatable {
    case openFailed(String)
    case prepareFailed(String)
    case executeFailed(String)
    case stepFailed(String)
    case invalidStoredValue(String)
}

extension SQLiteRepositoryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
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
        }
    }
}

private extension SQLiteEngineRepository {
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

    func plannedSubtasksJSON(_ plannedSubtasks: [PlannedSubtask]) throws -> String? {
        guard plannedSubtasks.isEmpty == false else { return nil }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(plannedSubtasks)
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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([PlannedSubtask].self, from: data)
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
        if try columnExists("planned_subtasks_json", in: "task_definitions", database: database) == false {
            try execute("ALTER TABLE task_definitions ADD COLUMN planned_subtasks_json TEXT", on: database)
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

        return try readRows(from: statement, database: database, row: row)
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
        return try readRows(from: statement, database: database, row: row)
    }

    func readRows<T>(
        from statement: Statement?,
        database: Database?,
        row: (Statement?) throws -> T
    ) throws -> [T] {
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
        sqlite3_bind_int(statement, index, Int32(value))
    }

    func bind(_ value: LocalDate, to index: Int32, in statement: Statement?) {
        bind(value.description, to: index, in: statement)
    }

    func bind(_ value: Date?, to index: Int32, in statement: Statement?) {
        bind(value.map(Self.string(from:)), to: index, in: statement)
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
        Int(sqlite3_column_int(statement, index))
    }

    func optionalInt(_ statement: Statement?, _ index: Int32) -> Int? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : int(statement, index)
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

    func lastError(_ database: Database?) -> String {
        database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite error"
    }

    func columnExists(_ columnName: String, in tableName: String, database: Database?) throws -> Bool {
        try query("PRAGMA table_info(\(tableName))", on: database) { statement in
            try string(statement, 1)
        }
        .contains(columnName)
    }
}

private extension SQLiteEngineRepository {
    func loadSnapshot(from database: Database?) throws -> SuntraceSnapshot {
        var preferences = try loadPreferences(from: database)
        var chains = try loadChains(from: database)
        try migrateLegacyTaskClassifications(from: database, preferences: &preferences, chains: &chains)
        return SuntraceSnapshot(
            days: try loadDays(from: database),
            chains: chains,
            definitions: try loadDefinitions(from: database),
            traces: try loadTraces(from: database),
            subtasks: try loadSubtasks(from: database),
            preferences: preferences
        )
    }

    func upsert(_ days: [Day], into database: Database?) throws {
        let sql = """
        INSERT INTO days(id, date, locked_at, review_summary, review_unfinished_reason, review_tomorrow_note, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(date) DO UPDATE SET
            id = excluded.id,
            locked_at = excluded.locked_at,
            review_summary = excluded.review_summary,
            review_unfinished_reason = excluded.review_unfinished_reason,
            review_tomorrow_note = excluded.review_tomorrow_note,
            created_at = excluded.created_at,
            updated_at = excluded.updated_at
        """
        for day in days {
            try run(sql, on: database) { statement in
                bind(day.id.rawValue, to: 1, in: statement)
                bind(day.date, to: 2, in: statement)
                bind(day.lockedAt, to: 3, in: statement)
                bind(day.reviewSummary, to: 4, in: statement)
                bind(day.reviewUnfinishedReason, to: 5, in: statement)
                bind(day.reviewTomorrowNote, to: 6, in: statement)
                bind(day.createdAt, to: 7, in: statement)
                bind(day.updatedAt, to: 8, in: statement)
            }
        }
    }

    func upsert(_ chains: [TaskChain], into database: Database?) throws {
        let chainSQL = """
        INSERT INTO task_chains(id, state, created_at, updated_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            state = excluded.state,
            created_at = excluded.created_at,
            updated_at = excluded.updated_at
        """
        let deleteAssignmentsSQL = """
        DELETE FROM task_tag_assignments WHERE chain_id = ?
        """
        let assignmentSQL = """
        INSERT INTO task_tag_assignments(chain_id, tag_id, slot, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?)
        """
        for chain in chains {
            try run(chainSQL, on: database) { statement in
                bind(chain.id.rawValue, to: 1, in: statement)
                bind(chain.state.rawValue, to: 2, in: statement)
                bind(chain.createdAt, to: 3, in: statement)
                bind(chain.updatedAt, to: 4, in: statement)
            }
            try run(deleteAssignmentsSQL, on: database) { statement in
                bind(chain.id.rawValue, to: 1, in: statement)
            }
            for assignment in chain.tagAssignments {
                try run(assignmentSQL, on: database) { statement in
                    bind(chain.id.rawValue, to: 1, in: statement)
                    bind(assignment.tagID.rawValue, to: 2, in: statement)
                    bind(assignment.slot.rawValue, to: 3, in: statement)
                    bind(assignment.createdAt, to: 4, in: statement)
                    bind(assignment.updatedAt, to: 5, in: statement)
                }
            }
        }
    }

    func upsert(_ definitions: [TaskDefinition], into database: Database?) throws {
        let sql = """
        INSERT INTO task_definitions(
            id, chain_id, sequence, title, description_text, note, planned_subtasks_json,
            created_at, superseded_at, superseded_by_definition_id
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            chain_id = excluded.chain_id,
            sequence = excluded.sequence,
            title = excluded.title,
            description_text = excluded.description_text,
            note = excluded.note,
            planned_subtasks_json = excluded.planned_subtasks_json,
            created_at = excluded.created_at,
            superseded_at = excluded.superseded_at,
            superseded_by_definition_id = excluded.superseded_by_definition_id
        """
        for definition in definitions {
            try run(sql, on: database) { statement in
                bind(definition.id.rawValue, to: 1, in: statement)
                bind(definition.chainID.rawValue, to: 2, in: statement)
                bind(definition.sequence, to: 3, in: statement)
                bind(definition.title, to: 4, in: statement)
                bind(definition.descriptionText, to: 5, in: statement)
                bind(definition.note, to: 6, in: statement)
                bind(try plannedSubtasksJSON(definition.plannedSubtasks), to: 7, in: statement)
                bind(definition.createdAt, to: 8, in: statement)
                bind(definition.supersededAt, to: 9, in: statement)
                bind(nil as String?, to: 10, in: statement)
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
        let sql = """
        INSERT INTO day_traces(
            id, chain_id, definition_id, date, status, priority, continuation_seq, description_text, note,
            manual_progress_percent, continued_from_trace_id, changed_to_trace_id, created_at, completed_at, settled_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            chain_id = excluded.chain_id,
            definition_id = excluded.definition_id,
            date = excluded.date,
            status = excluded.status,
            priority = excluded.priority,
            continuation_seq = excluded.continuation_seq,
            description_text = excluded.description_text,
            note = excluded.note,
            manual_progress_percent = excluded.manual_progress_percent,
            continued_from_trace_id = excluded.continued_from_trace_id,
            changed_to_trace_id = excluded.changed_to_trace_id,
            created_at = excluded.created_at,
            completed_at = excluded.completed_at,
            settled_at = excluded.settled_at
        """
        for trace in traces {
            try run(sql, on: database) { statement in
                bind(trace.id.rawValue, to: 1, in: statement)
                bind(trace.chainID.rawValue, to: 2, in: statement)
                bind(trace.definitionID.rawValue, to: 3, in: statement)
                bind(trace.date, to: 4, in: statement)
                bind(trace.status.rawValue, to: 5, in: statement)
                bind(trace.priority, to: 6, in: statement)
                bind(trace.continuationSeq, to: 7, in: statement)
                bind(trace.descriptionText, to: 8, in: statement)
                bind(trace.note, to: 9, in: statement)
                bind(trace.manualProgressPercent, to: 10, in: statement)
                bind(trace.continuedFromTraceID?.rawValue.uuidString, to: 11, in: statement)
                bind(nil as String?, to: 12, in: statement)
                bind(trace.createdAt, to: 13, in: statement)
                bind(trace.completedAt, to: 14, in: statement)
                bind(trace.settledAt, to: 15, in: statement)
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
            continued_from_subtask_id, created_at, completed_at, settled_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            lineage_id = excluded.lineage_id,
            trace_id = excluded.trace_id,
            title = excluded.title,
            status = excluded.status,
            difficulty = excluded.difficulty,
            position = excluded.position,
            continued_from_subtask_id = excluded.continued_from_subtask_id,
            created_at = excluded.created_at,
            completed_at = excluded.completed_at,
            settled_at = excluded.settled_at
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
                bind(subtask.completedAt, to: 10, in: statement)
                bind(subtask.settledAt, to: 11, in: statement)
            }
        }

        let relationSQL = """
        UPDATE subtasks
        SET continued_from_subtask_id = ?
        WHERE id = ?
        """
        for subtask in subtasks {
            try run(relationSQL, on: database) { statement in
                bind(subtask.continuedFromSubtaskID?.rawValue.uuidString, to: 1, in: statement)
                bind(subtask.id.rawValue, to: 2, in: statement)
            }
        }
    }

    func upsert(_ preferences: AppPreferences, into database: Database?) throws {
        let sql = """
        INSERT INTO app_preferences(id, theme, language, updated_at)
        VALUES (1, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            theme = excluded.theme,
            language = excluded.language,
            updated_at = excluded.updated_at
        """
        try run(sql, on: database) { statement in
            bind(preferences.theme.rawValue, to: 1, in: statement)
            bind(preferences.language.rawValue, to: 2, in: statement)
            bind(Date(timeIntervalSince1970: 0), to: 3, in: statement)
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
        try upsertTaskTags(preferences.taskTags, into: database)
    }

    func upsertTaskTags(_ tags: [TaskTag], into database: Database?) throws {
        try execute("DELETE FROM task_tag_assignments", on: database)
        try execute("DELETE FROM task_tags", on: database)
        let sql = """
        INSERT INTO task_tags(id, name, status, color_hex, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """
        for tag in tags {
            try run(sql, on: database) { statement in
                bind(tag.id.rawValue, to: 1, in: statement)
                bind(tag.name, to: 2, in: statement)
                bind(tag.status.rawValue, to: 3, in: statement)
                bind(tag.colorHex, to: 4, in: statement)
                bind(tag.createdAt, to: 5, in: statement)
                bind(tag.updatedAt, to: 6, in: statement)
            }
        }
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
        for entry in entries {
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
    }
}

private extension SQLiteEngineRepository {
    func loadDays(from database: Database?) throws -> [Day] {
        try query(
            """
            SELECT id, date, locked_at, review_summary, review_unfinished_reason, review_tomorrow_note, created_at, updated_at
            FROM days
            ORDER BY date
            """,
            on: database
        ) { statement in
            var day = Day(id: DayID(try uuid(statement, 0)), date: LocalDate(try string(statement, 1)), now: try date(statement, 6))
            day.lockedAt = try optionalDate(statement, 2)
            day.reviewSummary = optionalString(statement, 3)
            day.reviewUnfinishedReason = optionalString(statement, 4)
            day.reviewTomorrowNote = optionalString(statement, 5)
            day.updatedAt = try date(statement, 7)
            return day
        }
    }

    func loadChains(from database: Database?) throws -> [TaskChain] {
        let assignmentsByChainID = try loadTaskTagAssignments(from: database)
        return try query(
            """
            SELECT c.id, c.state, c.created_at, c.updated_at
            FROM task_chains c
            ORDER BY c.created_at, c.id
            """,
            on: database
        ) { statement in
            guard let state = TaskChainState(rawValue: try string(statement, 1)) else {
                throw SQLiteRepositoryError.invalidStoredValue("invalid task chain state")
            }
            let chainID = TaskChainID(try uuid(statement, 0))
            var chain = TaskChain(
                id: chainID,
                state: state,
                tagAssignments: assignmentsByChainID[chainID] ?? [],
                now: try date(statement, 2)
            )
            chain.updatedAt = try date(statement, 3)
            return chain
        }
    }

    func loadTaskTagAssignments(from database: Database?) throws -> [TaskChainID: [TaskTagAssignment]] {
        let assignments = try query(
            """
            SELECT chain_id, tag_id, slot, created_at, updated_at
            FROM task_tag_assignments
            ORDER BY chain_id, slot
            """,
            on: database
        ) { statement in
            guard let slot = TaskTagSlot(rawValue: int(statement, 2)) else {
                throw SQLiteRepositoryError.invalidStoredValue("invalid task tag slot")
            }
            var assignment = TaskTagAssignment(
                tagID: TaskTagID(try uuid(statement, 1)),
                slot: slot,
                now: try date(statement, 3)
            )
            assignment.updatedAt = try date(statement, 4)
            return (TaskChainID(try uuid(statement, 0)), assignment)
        }
        return Dictionary(grouping: assignments, by: \.0)
            .mapValues { rows in rows.map(\.1).sorted { $0.slot < $1.slot } }
    }

    func migrateLegacyTaskClassifications(
        from database: Database?,
        preferences: inout AppPreferences,
        chains: inout [TaskChain]
    ) throws {
        let legacyRows = try query(
            """
            SELECT chain_id, manual_group, manual_label, ai_group, ai_label, updated_at
            FROM task_chain_metadata
            """,
            on: database
        ) { statement in
            (
                TaskChainID(try uuid(statement, 0)),
                optionalString(statement, 1),
                optionalString(statement, 2),
                optionalString(statement, 3),
                optionalString(statement, 4),
                try date(statement, 5)
            )
        }
        guard legacyRows.isEmpty == false else { return }

        var tagsByName = Dictionary(uniqueKeysWithValues: preferences.taskTags.map { ($0.name.lowercased(), $0) })
        let chainIndexByID = Dictionary(uniqueKeysWithValues: chains.enumerated().map { ($0.element.id, $0.offset) })

        for row in legacyRows {
            guard let chainIndex = chainIndexByID[row.0],
                  chains[chainIndex].tagAssignments.isEmpty
            else { continue }
            guard let rawName = [row.1, row.2, row.3, row.4]
                .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { $0.isEmpty == false })
            else { continue }

            let key = rawName.lowercased()
            let tag: TaskTag
            if let existing = tagsByName[key] {
                tag = existing
            } else {
                tag = TaskTag(name: rawName, now: row.5)
                preferences.taskTags.append(tag)
                tagsByName[key] = tag
            }
            chains[chainIndex].tagAssignments = [TaskTagAssignment(tagID: tag.id, slot: .tagI, now: row.5)]
        }
        preferences.taskTags.sort { $0.createdAt < $1.createdAt }
    }

    func loadDefinitions(from database: Database?) throws -> [TaskDefinition] {
        try query(
            """
            SELECT
                id, chain_id, sequence, title, description_text, note, planned_subtasks_json,
                created_at, superseded_at, superseded_by_definition_id
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
                note: optionalString(statement, 5),
                plannedSubtasks: try plannedSubtasks(from: optionalString(statement, 6)),
                now: try date(statement, 7)
            )
            definition.supersededAt = try optionalDate(statement, 8)
            if let uuid = try optionalUUID(statement, 9) {
                definition.supersededByDefinitionID = TaskDefinitionID(uuid)
            }
            return definition
        }
    }

    func loadTraces(from database: Database?) throws -> [DayTrace] {
        try query(
            """
            SELECT id, chain_id, definition_id, date, status, priority, continuation_seq, description_text, note,
                   manual_progress_percent, continued_from_trace_id, changed_to_trace_id, created_at, completed_at, settled_at
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
                continuationSeq: int(statement, 6),
                descriptionText: optionalString(statement, 7),
                note: optionalString(statement, 8),
                manualProgressPercent: optionalInt(statement, 9),
                continuedFromTraceID: try optionalUUID(statement, 10).map(DayTraceID.init),
                now: try date(statement, 12)
            )
            trace.changedToTraceID = try optionalUUID(statement, 11).map(DayTraceID.init)
            trace.completedAt = try optionalDate(statement, 13)
            trace.settledAt = try optionalDate(statement, 14)
            return trace
        }
    }

    func loadSubtasks(from database: Database?) throws -> [Subtask] {
        try query(
            """
            SELECT id, lineage_id, trace_id, title, status, difficulty, position,
                   continued_from_subtask_id, created_at, completed_at, settled_at
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
                continuedFromSubtaskID: try optionalUUID(statement, 7).map(SubtaskID.init),
                now: try date(statement, 8)
            )
            subtask.completedAt = try optionalDate(statement, 9)
            subtask.settledAt = try optionalDate(statement, 10)
            return subtask
        }
    }

    func loadPreferences(from database: Database?) throws -> AppPreferences {
        let rows = try query(
            "SELECT theme, language FROM app_preferences WHERE id = 1",
            on: database
        ) { statement in
            (try string(statement, 0), try string(statement, 1))
        }
        guard let row = rows.first else {
            return AppPreferences(taskTags: try loadTaskTags(from: database))
        }
        guard let theme = AppTheme(rawValue: row.0), let language = AppLanguage(rawValue: row.1) else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid app preferences")
        }
        return AppPreferences(
            theme: theme,
            language: language,
            dataMode: try loadDataMode(from: database),
            backupPolicy: try loadBackupPolicy(from: database),
            localFirstSyncPolicy: try loadLocalFirstSyncPolicy(from: database),
            settingsPoemDisplayPolicy: try loadSettingsPoemDisplayPolicy(from: database),
            taskTags: try loadTaskTags(from: database)
        )
    }

    func loadTaskTags(from database: Database?) throws -> [TaskTag] {
        try query(
            """
            SELECT id, name, status, color_hex, created_at, updated_at
            FROM task_tags
            ORDER BY created_at, rowid
            """,
            on: database
        ) { statement in
            guard let status = TaskTagStatus(rawValue: try string(statement, 2)) else {
                throw SQLiteRepositoryError.invalidStoredValue("invalid task tag status")
            }
            var tag = TaskTag(
                id: TaskTagID(try uuid(statement, 0)),
                name: try string(statement, 1),
                status: status,
                colorHex: try string(statement, 3),
                now: try date(statement, 4)
            )
            tag.updatedAt = try date(statement, 5)
            return tag
        }
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
