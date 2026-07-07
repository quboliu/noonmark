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
            try upsert(snapshot.days, into: database)
            try upsert(snapshot.chains, into: database)
            try upsert(snapshot.definitions, into: database)
            try upsert(snapshot.traces, into: database)
            try upsert(snapshot.subtasks, into: database)
            try upsert(snapshot.preferences, into: database)
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
            try upsert(snapshot.days, into: database)
            try upsert(snapshot.chains, into: database)
            try upsert(snapshot.definitions, into: database)
            try upsert(snapshot.traces, into: database)
            try upsert(snapshot.subtasks, into: database)
            try upsert(snapshot.preferences, into: database)
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
}

private extension SQLiteEngineRepository {
    func loadSnapshot(from database: Database?) throws -> SuntraceSnapshot {
        try SuntraceSnapshot(
            days: loadDays(from: database),
            chains: loadChains(from: database),
            definitions: loadDefinitions(from: database),
            traces: loadTraces(from: database),
            subtasks: loadSubtasks(from: database),
            preferences: loadPreferences(from: database)
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
        let sql = """
        INSERT INTO task_chains(id, state, created_at, updated_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            state = excluded.state,
            created_at = excluded.created_at,
            updated_at = excluded.updated_at
        """
        for chain in chains {
            try run(sql, on: database) { statement in
                bind(chain.id.rawValue, to: 1, in: statement)
                bind(chain.state.rawValue, to: 2, in: statement)
                bind(chain.createdAt, to: 3, in: statement)
                bind(chain.updatedAt, to: 4, in: statement)
            }
        }
    }

    func upsert(_ definitions: [TaskDefinition], into database: Database?) throws {
        let sql = """
        INSERT INTO task_definitions(id, chain_id, sequence, title, description_text, note, created_at, superseded_at, superseded_by_definition_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            chain_id = excluded.chain_id,
            sequence = excluded.sequence,
            title = excluded.title,
            description_text = excluded.description_text,
            note = excluded.note,
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
                bind(definition.createdAt, to: 7, in: statement)
                bind(definition.supersededAt, to: 8, in: statement)
                bind(nil as String?, to: 9, in: statement)
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
        try query(
            "SELECT id, state, created_at, updated_at FROM task_chains ORDER BY created_at, id",
            on: database
        ) { statement in
            guard let state = TaskChainState(rawValue: try string(statement, 1)) else {
                throw SQLiteRepositoryError.invalidStoredValue("invalid task chain state")
            }
            var chain = TaskChain(id: TaskChainID(try uuid(statement, 0)), state: state, now: try date(statement, 2))
            chain.updatedAt = try date(statement, 3)
            return chain
        }
    }

    func loadDefinitions(from database: Database?) throws -> [TaskDefinition] {
        try query(
            """
            SELECT id, chain_id, sequence, title, description_text, note, created_at, superseded_at, superseded_by_definition_id
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
                now: try date(statement, 6)
            )
            definition.supersededAt = try optionalDate(statement, 7)
            if let uuid = try optionalUUID(statement, 8) {
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
            return AppPreferences()
        }
        guard let theme = AppTheme(rawValue: row.0), let language = AppLanguage(rawValue: row.1) else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid app preferences")
        }
        return AppPreferences(
            theme: theme,
            language: language,
            dataMode: try loadDataMode(from: database),
            backupPolicy: try loadBackupPolicy(from: database)
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
