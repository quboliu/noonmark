import Foundation
import SuntraceCore

public enum SQLiteSchema {
    public static let version = 1

    public static let statements: [String] = [
        """
        PRAGMA foreign_keys = ON
        """,
        """
        CREATE TABLE IF NOT EXISTS days (
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
            notes TEXT,
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
            trace_id TEXT NOT NULL REFERENCES day_traces(id),
            title TEXT NOT NULL CHECK (length(trim(title)) > 0),
            is_done INTEGER NOT NULL CHECK (is_done IN (0, 1)),
            position INTEGER NOT NULL,
            created_at TEXT NOT NULL,
            completed_at TEXT
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS sync_settings (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT,
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
            d.notes,
            c.created_at,
            c.updated_at
        FROM task_chains c
        JOIN task_definitions d ON d.chain_id = c.id AND d.superseded_at IS NULL
        WHERE c.state = 'active'
          AND NOT EXISTS (
              SELECT 1 FROM day_traces t WHERE t.chain_id = c.id
          )
        """,
        """
        CREATE VIEW IF NOT EXISTS future_plan_view AS
        SELECT
            t.*,
            d.title,
            d.notes
        FROM day_traces t
        JOIN task_definitions d ON d.id = t.definition_id
        WHERE t.status = 'pending'
        """,
        """
        CREATE VIEW IF NOT EXISTS unfinished_detail_view AS
        SELECT
            t.*,
            d.title,
            d.notes
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
            d.notes,
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
        GROUP BY c.id, d.id, d.title, d.notes, active.id, active.date
        """,
        """
        CREATE VIEW IF NOT EXISTS completed_pool_view AS
        SELECT
            t.*,
            d.title,
            d.notes
        FROM day_traces t
        JOIN task_definitions d ON d.id = t.definition_id
        WHERE t.status = 'completed'
        """,
        """
        CREATE VIEW IF NOT EXISTS day_todo_view AS
        SELECT
            t.*,
            d.title,
            d.notes
        FROM day_traces t
        JOIN task_definitions d ON d.id = t.definition_id
        """
    ]
}
