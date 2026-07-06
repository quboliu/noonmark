import Foundation
import SuntraceCore

public enum SQLiteSchema {
    public static let version = 3

    public static let statements: [String] = [
        """
        PRAGMA foreign_keys = ON
        """,
        """
        CREATE TABLE IF NOT EXISTS days (
            id TEXT NOT NULL,
            date TEXT PRIMARY KEY NOT NULL,
            locked_at TEXT,
            review_summary TEXT,
            review_unfinished_reason TEXT,
            review_tomorrow_note TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS task_chains (
            id TEXT PRIMARY KEY NOT NULL,
            state TEXT NOT NULL CHECK (state IN ('active', 'abandoned')),
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS task_definitions (
            id TEXT PRIMARY KEY NOT NULL,
            chain_id TEXT NOT NULL REFERENCES task_chains(id),
            sequence INTEGER NOT NULL,
            title TEXT NOT NULL CHECK (length(trim(title)) > 0),
            description_text TEXT,
            note TEXT,
            created_at TEXT NOT NULL,
            superseded_at TEXT,
            superseded_by_definition_id TEXT REFERENCES task_definitions(id),
            UNIQUE (chain_id, sequence)
        )
        """,
        """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_one_current_definition_per_chain
        ON task_definitions(chain_id)
        WHERE superseded_at IS NULL
        """,
        """
        CREATE TABLE IF NOT EXISTS day_traces (
            id TEXT PRIMARY KEY NOT NULL,
            chain_id TEXT NOT NULL REFERENCES task_chains(id),
            definition_id TEXT NOT NULL REFERENCES task_definitions(id),
            date TEXT NOT NULL,
            status TEXT NOT NULL CHECK (
                status IN (
                    'pending',
                    'completed',
                    'unfinished',
                    'continued',
                    'changed',
                    'returnedToPool',
                    'abandoned'
                )
            ),
            priority INTEGER NOT NULL,
            continuation_seq INTEGER NOT NULL DEFAULT 0,
            description_text TEXT,
            note TEXT,
            manual_progress_percent INTEGER CHECK (
                manual_progress_percent IS NULL
                OR (manual_progress_percent >= 0 AND manual_progress_percent <= 100)
            ),
            continued_from_trace_id TEXT REFERENCES day_traces(id),
            changed_to_trace_id TEXT REFERENCES day_traces(id),
            created_at TEXT NOT NULL,
            completed_at TEXT,
            settled_at TEXT
        )
        """,
        """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_one_active_trace_per_chain
        ON day_traces(chain_id)
        WHERE status = 'pending'
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_day_traces_date_priority
        ON day_traces(date, priority)
        """,
        """
        CREATE TABLE IF NOT EXISTS subtasks (
            id TEXT PRIMARY KEY NOT NULL,
            lineage_id TEXT NOT NULL,
            trace_id TEXT NOT NULL REFERENCES day_traces(id),
            title TEXT NOT NULL CHECK (length(trim(title)) > 0),
            status TEXT NOT NULL CHECK (
                status IN (
                    'pending',
                    'completed',
                    'unfinished',
                    'continued',
                    'abandoned'
                )
            ),
            difficulty INTEGER NOT NULL DEFAULT 1 CHECK (difficulty IN (1, 2, 3)),
            position INTEGER NOT NULL,
            continued_from_subtask_id TEXT REFERENCES subtasks(id),
            created_at TEXT NOT NULL,
            completed_at TEXT,
            settled_at TEXT
        )
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_subtasks_trace_position
        ON subtasks(trace_id, position)
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_subtasks_lineage
        ON subtasks(lineage_id)
        """,
        """
        CREATE TABLE IF NOT EXISTS sync_settings (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT,
            updated_at TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS app_preferences (
            id INTEGER PRIMARY KEY NOT NULL CHECK (id = 1),
            theme TEXT NOT NULL CHECK (theme IN ('coolGray', 'warmPaper')),
            language TEXT NOT NULL CHECK (language IN ('chinese', 'english')),
            updated_at TEXT NOT NULL
        )
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_day_trace_delete
        BEFORE DELETE ON day_traces
        BEGIN
            SELECT RAISE(ABORT, 'day traces are immutable and cannot be deleted');
        END
        """,
        """
        CREATE VIEW IF NOT EXISTS task_pool_view AS
        SELECT
            c.id AS chain_id,
            d.id AS definition_id,
            d.title,
            d.description_text,
            d.note,
            c.created_at,
            c.updated_at
        FROM task_chains c
        JOIN task_definitions d ON d.chain_id = c.id AND d.superseded_at IS NULL
        WHERE c.state = 'active'
          AND NOT EXISTS (
              SELECT 1 FROM day_traces t
              WHERE t.chain_id = c.id AND t.status != 'returnedToPool'
          )
        """,
        """
        CREATE VIEW IF NOT EXISTS future_plan_view AS
        SELECT
            t.*,
            d.title,
            d.description_text AS definition_description_text,
            d.note AS definition_note
        FROM day_traces t
        JOIN task_definitions d ON d.id = t.definition_id
        WHERE t.status = 'pending'
        """,
        """
        CREATE VIEW IF NOT EXISTS unfinished_detail_view AS
        SELECT
            t.*,
            d.title,
            d.description_text AS definition_description_text,
            d.note AS definition_note
        FROM day_traces t
        JOIN task_definitions d ON d.id = t.definition_id
        WHERE t.status IN ('unfinished', 'continued')
        """,
        """
        CREATE VIEW IF NOT EXISTS unfinished_pool_view AS
        SELECT
            c.id AS chain_id,
            d.id AS definition_id,
            d.title,
            d.description_text,
            d.note,
            COUNT(u.id) AS unfinished_count,
            MAX(u.date) AS latest_unfinished_date,
            MAX(u.continuation_seq) AS max_continuation_seq,
            active.id AS active_trace_id,
            active.date AS active_trace_date
        FROM task_chains c
        JOIN task_definitions d ON d.chain_id = c.id AND d.superseded_at IS NULL
        JOIN day_traces u ON u.chain_id = c.id AND u.status IN ('unfinished', 'continued')
        LEFT JOIN day_traces active ON active.chain_id = c.id AND active.status = 'pending'
        WHERE c.state = 'active'
          AND NOT EXISTS (
              SELECT 1 FROM day_traces done
              WHERE done.chain_id = c.id AND done.status = 'completed'
          )
        GROUP BY c.id, d.id, d.title, d.description_text, d.note, active.id, active.date
        """,
        """
        CREATE VIEW IF NOT EXISTS completed_pool_view AS
        SELECT
            t.*,
            d.title,
            d.description_text AS definition_description_text,
            d.note AS definition_note,
            first_trace.date AS trajectory_start_date,
            t.date AS trajectory_completed_date
        FROM day_traces t
        JOIN task_definitions d ON d.id = t.definition_id
        JOIN day_traces first_trace ON first_trace.id = (
            SELECT first.id
            FROM day_traces first
            WHERE first.chain_id = t.chain_id
            ORDER BY first.date, first.continuation_seq, first.priority, first.created_at
            LIMIT 1
        )
        WHERE t.status = 'completed'
        """,
        """
        CREATE VIEW IF NOT EXISTS completed_trajectory_detail_view AS
        SELECT
            done.id AS completed_trace_id,
            history.id AS trace_id,
            history.chain_id,
            history.definition_id,
            history.date,
            history.status,
            history.priority,
            history.continuation_seq,
            history.continued_from_trace_id,
            history.changed_to_trace_id,
            history.created_at,
            history.completed_at,
            history.settled_at
        FROM day_traces done
        JOIN day_traces history ON history.chain_id = done.chain_id
        WHERE done.status = 'completed'
        """,
        """
        CREATE VIEW IF NOT EXISTS completed_subtask_trajectory_detail_view AS
        SELECT
            done.id AS completed_trace_id,
            s.id AS subtask_id,
            s.lineage_id,
            s.trace_id,
            t.date,
            s.title,
            s.status,
            s.difficulty,
            s.position,
            s.continued_from_subtask_id,
            s.created_at,
            s.completed_at,
            s.settled_at
        FROM day_traces done
        JOIN day_traces t ON t.chain_id = done.chain_id
        JOIN subtasks s ON s.trace_id = t.id
        WHERE done.status = 'completed'
        """,
        """
        CREATE VIEW IF NOT EXISTS completed_subtask_record_view AS
        SELECT
            t.date,
            s.id AS subtask_id,
            s.lineage_id,
            s.trace_id,
            s.title,
            s.status,
            s.difficulty,
            s.position,
            s.continued_from_subtask_id,
            s.created_at,
            s.completed_at,
            s.settled_at,
            t.id AS parent_trace_id,
            t.chain_id AS parent_chain_id,
            d.id AS parent_definition_id,
            d.title AS parent_title
        FROM subtasks s
        JOIN day_traces t ON t.id = s.trace_id
        JOIN task_definitions d ON d.id = t.definition_id
        WHERE s.status = 'completed'
        """,
        """
        CREATE VIEW IF NOT EXISTS sync_endpoint_options_view AS
        SELECT
            'customEndpoint' AS kind,
            '自定义同步端点' AS title,
            '连接自有服务端' AS description,
            'planned' AS availability
        UNION ALL
        SELECT
            'iCloud' AS kind,
            'iCloud 云同步' AS title,
            '原生云同步' AS description,
            'planned' AS availability
        """,
        """
        CREATE VIEW IF NOT EXISTS day_todo_view AS
        SELECT
            t.*,
            d.title,
            d.description_text AS definition_description_text,
            d.note AS definition_note
        FROM day_traces t
        JOIN task_definitions d ON d.id = t.definition_id
        """
    ]
}
