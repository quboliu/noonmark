import Foundation
import NoonmarkCore
import SQLite3

private let sqliteInvariantWhitespaceCharacters =
    "char(9,10,11,12,13,32,133,160,5760," +
    "8192,8193,8194,8195,8196,8197,8198,8199,8200,8201,8202," +
    "8232,8233,8239,8287,12288,65279)"

private func sqliteNonemptyInvariant(_ column: String) -> String {
    "length(trim(\(column), \(sqliteInvariantWhitespaceCharacters))) > 0"
}

public enum SQLiteSchema {
    public static let version = 13

    public static let statements: [String] = [
        """
        PRAGMA foreign_keys = ON
        """,
        """
        CREATE TABLE IF NOT EXISTS days (
            id TEXT NOT NULL UNIQUE,
            date TEXT PRIMARY KEY NOT NULL,
            locked_at TEXT,
            locked_at_bits INTEGER CHECK (
                locked_at_bits IS NULL OR typeof(locked_at_bits) = 'integer'
            ),
            review_summary TEXT,
            review_unfinished_reason TEXT,
            review_tomorrow_note TEXT,
            created_at TEXT NOT NULL,
            created_at_bits INTEGER NOT NULL CHECK (typeof(created_at_bits) = 'integer'),
            updated_at TEXT NOT NULL,
            updated_at_bits INTEGER NOT NULL CHECK (typeof(updated_at_bits) = 'integer'),
            CHECK ((locked_at IS NULL) = (locked_at_bits IS NULL))
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS task_cycle_series (
            id TEXT PRIMARY KEY NOT NULL,
            title TEXT NOT NULL CHECK (
                \(sqliteNonemptyInvariant("title"))
            ),
            description_text TEXT,
            start_date TEXT NOT NULL,
            end_date TEXT NOT NULL CHECK (end_date >= start_date),
            schedule TEXT NOT NULL CHECK (schedule IN ('daily', 'weekdays')),
            cancellation_facts_json TEXT NOT NULL CHECK (
                json_valid(cancellation_facts_json)
                AND json_type(cancellation_facts_json) = 'array'
            ),
            created_at TEXT NOT NULL,
            created_at_bits INTEGER NOT NULL CHECK (typeof(created_at_bits) = 'integer'),
            updated_at TEXT NOT NULL,
            updated_at_bits INTEGER NOT NULL CHECK (typeof(updated_at_bits) = 'integer')
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS task_chains (
            id TEXT PRIMARY KEY NOT NULL,
            state TEXT NOT NULL CHECK (state IN ('active', 'abandoned')),
            cycle_membership_json TEXT CHECK (
                cycle_membership_json IS NULL
                OR (
                    json_valid(cycle_membership_json)
                    AND json_type(cycle_membership_json) = 'object'
                )
            ),
            note_entries_json TEXT NOT NULL CHECK (
                json_valid(note_entries_json)
                AND json_type(note_entries_json) = 'array'
            ),
            created_at TEXT NOT NULL,
            created_at_bits INTEGER NOT NULL CHECK (typeof(created_at_bits) = 'integer'),
            updated_at TEXT NOT NULL,
            updated_at_bits INTEGER NOT NULL CHECK (typeof(updated_at_bits) = 'integer')
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS automatic_classification_jobs (
            id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
            chain_id TEXT NOT NULL REFERENCES task_chains(id),
            content_digest TEXT NOT NULL CHECK (
                length(content_digest) = 64
                AND content_digest NOT GLOB '*[^0-9a-f]*'
            ),
            classification_fingerprint TEXT NOT NULL CHECK (
                length(classification_fingerprint) = 64
                AND classification_fingerprint NOT GLOB '*[^0-9a-f]*'
            ),
            authority_payload BLOB NOT NULL CHECK (
                length(authority_payload) BETWEEN 1 AND 65536
            ),
            catalog_digest TEXT NOT NULL CHECK (
                length(catalog_digest) = 64
                AND catalog_digest NOT GLOB '*[^0-9a-f]*'
            ),
            generation INTEGER NOT NULL CHECK (
                typeof(generation) = 'integer' AND generation > 0
            ),
            state TEXT NOT NULL CHECK (
                state IN (
                    'waitingForConfiguration', 'ready', 'running',
                    'proposalReady', 'completed', 'superseded',
                    'cancelled', 'failed'
                )
            ),
            dispatch_authorization TEXT NOT NULL CHECK (
                dispatch_authorization IN (
                    'automatic', 'pendingUserDecision', 'explicit'
                )
            ),
            authorization_id TEXT CHECK (
                authorization_id IS NULL OR length(authorization_id) = 36
            ),
            authorized_at REAL,
            attempt INTEGER NOT NULL CHECK (
                typeof(attempt) = 'integer' AND attempt >= 0
            ),
            claim_id TEXT CHECK (claim_id IS NULL OR length(claim_id) = 36),
            proposal_checkpoint BLOB CHECK (
                proposal_checkpoint IS NULL
                OR length(proposal_checkpoint) BETWEEN 1 AND 262144
            ),
            error_code TEXT CHECK (
                error_code IS NULL OR error_code IN (
                    'configurationUnavailable', 'providerUnavailable',
                    'providerRateLimited', 'providerRejected',
                    'invalidProviderResponse', 'invalidProposal',
                    'retryLimitReached', 'transientStorageFailure',
                    'cancelledByUndo', 'backlogSkippedByUser',
                    'manualClassificationWon',
                    'contentOrCatalogChanged', 'taskBecameIneligible',
                    'internalFailure'
                )
            ),
            available_at REAL NOT NULL,
            claimed_at REAL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            terminal_at REAL,
            cancelled_by_undo INTEGER NOT NULL DEFAULT 0 CHECK (
                cancelled_by_undo IN (0, 1)
            ),
            UNIQUE(chain_id, generation),
            CHECK ((claim_id IS NULL) = (claimed_at IS NULL)),
            CHECK (
                (dispatch_authorization = 'explicit')
                = (authorization_id IS NOT NULL AND authorized_at IS NOT NULL)
            ),
            CHECK (
                dispatch_authorization != 'pendingUserDecision'
                OR state IN (
                    'waitingForConfiguration', 'superseded', 'cancelled', 'failed'
                )
            ),
            CHECK (updated_at >= created_at),
            CHECK (claimed_at IS NULL OR claimed_at >= created_at),
            CHECK (terminal_at IS NULL OR terminal_at >= created_at),
            CHECK (
                (state IN ('completed', 'superseded', 'cancelled', 'failed'))
                = (terminal_at IS NOT NULL)
            ),
            CHECK (
                (state = 'proposalReady') = (proposal_checkpoint IS NOT NULL)
            ),
            CHECK (
                state NOT IN ('waitingForConfiguration', 'ready')
                OR (claim_id IS NULL AND proposal_checkpoint IS NULL)
            ),
            CHECK (cancelled_by_undo = 0 OR state = 'cancelled')
        )
        """,
        """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_automatic_classification_job_claim
        ON automatic_classification_jobs(claim_id)
        WHERE claim_id IS NOT NULL
        """,
        """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_one_live_automatic_classification_job_per_chain
        ON automatic_classification_jobs(chain_id)
        WHERE state IN (
            'waitingForConfiguration', 'ready', 'running', 'proposalReady'
        )
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_automatic_classification_job_claimable
        ON automatic_classification_jobs(state, available_at, claimed_at, created_at, id)
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_automatic_classification_job_backlog
        ON automatic_classification_jobs(
            dispatch_authorization, state, created_at, id
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS automatic_classification_provider_circuit (
            singleton_id INTEGER PRIMARY KEY NOT NULL CHECK (singleton_id = 1),
            provider_execution_revision TEXT CHECK (
                provider_execution_revision IS NULL OR (
                    length(provider_execution_revision) = 36
                    AND substr(provider_execution_revision, 9, 1) = '-'
                    AND substr(provider_execution_revision, 14, 1) = '-'
                    AND substr(provider_execution_revision, 19, 1) = '-'
                    AND substr(provider_execution_revision, 24, 1) = '-'
                )
            ),
            state TEXT NOT NULL CHECK (
                state IN ('unconfigured', 'closed', 'open', 'halfOpen', 'blocked')
            ),
            failure_code TEXT CHECK (
                failure_code IS NULL OR failure_code IN (
                    'providerUnavailable', 'providerRateLimited', 'providerRejected'
                )
            ),
            consecutive_failures INTEGER NOT NULL CHECK (
                typeof(consecutive_failures) = 'integer'
                AND consecutive_failures >= 0
            ),
            retry_at REAL,
            probe_job_id TEXT CHECK (
                probe_job_id IS NULL OR length(probe_job_id) = 36
            ),
            probe_generation INTEGER CHECK (
                probe_generation IS NULL OR (
                    typeof(probe_generation) = 'integer' AND probe_generation > 0
                )
            ),
            probe_attempt INTEGER CHECK (
                probe_attempt IS NULL OR (
                    typeof(probe_attempt) = 'integer' AND probe_attempt > 0
                )
            ),
            probe_claim_id TEXT CHECK (
                probe_claim_id IS NULL OR length(probe_claim_id) = 36
            ),
            opened_at REAL,
            updated_at REAL NOT NULL,
            transition_version INTEGER NOT NULL CHECK (
                typeof(transition_version) = 'integer'
                AND transition_version >= 0
            ),
            CHECK (
                (
                    state = 'unconfigured'
                    AND provider_execution_revision IS NULL
                    AND failure_code IS NULL
                    AND consecutive_failures = 0
                    AND retry_at IS NULL
                    AND probe_job_id IS NULL
                    AND probe_generation IS NULL
                    AND probe_attempt IS NULL
                    AND probe_claim_id IS NULL
                    AND opened_at IS NULL
                )
                OR (
                    state = 'closed'
                    AND provider_execution_revision IS NOT NULL
                    AND failure_code IS NULL
                    AND consecutive_failures = 0
                    AND retry_at IS NULL
                    AND probe_job_id IS NULL
                    AND probe_generation IS NULL
                    AND probe_attempt IS NULL
                    AND probe_claim_id IS NULL
                    AND opened_at IS NULL
                )
                OR (
                    state = 'open'
                    AND provider_execution_revision IS NOT NULL
                    AND failure_code IN ('providerUnavailable', 'providerRateLimited')
                    AND consecutive_failures BETWEEN 1 AND 2
                    AND retry_at IS NOT NULL
                    AND probe_job_id IS NULL
                    AND probe_generation IS NULL
                    AND probe_attempt IS NULL
                    AND probe_claim_id IS NULL
                    AND opened_at IS NOT NULL
                )
                OR (
                    state = 'halfOpen'
                    AND provider_execution_revision IS NOT NULL
                    AND failure_code IN ('providerUnavailable', 'providerRateLimited')
                    AND consecutive_failures BETWEEN 1 AND 2
                    AND retry_at IS NULL
                    AND probe_job_id IS NOT NULL
                    AND probe_generation IS NOT NULL
                    AND probe_attempt IS NOT NULL
                    AND probe_claim_id IS NOT NULL
                    AND opened_at IS NOT NULL
                )
                OR (
                    state = 'blocked'
                    AND provider_execution_revision IS NOT NULL
                    AND failure_code IN (
                        'providerUnavailable', 'providerRateLimited', 'providerRejected'
                    )
                    AND consecutive_failures > 0
                    AND retry_at IS NULL
                    AND probe_job_id IS NULL
                    AND probe_generation IS NULL
                    AND probe_attempt IS NULL
                    AND probe_claim_id IS NULL
                    AND opened_at IS NOT NULL
                )
            )
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS task_categories (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL CHECK (length(trim(name)) > 0),
            color_hex TEXT NOT NULL,
            presentation_approval TEXT NOT NULL CHECK (
                presentation_approval IN ('userApproved', 'pendingAIReview')
            ),
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS task_labels (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL CHECK (length(trim(name)) > 0),
            color_hex TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS classification_item_metadata (
            kind TEXT NOT NULL CHECK (kind IN ('category', 'label')),
            item_id TEXT NOT NULL,
            canonical_key TEXT NOT NULL CHECK (length(canonical_key) > 0),
            canonical_key_version TEXT NOT NULL CHECK (length(canonical_key_version) > 0),
            lifecycle TEXT NOT NULL CHECK (lifecycle IN ('active', 'archived', 'merged')),
            PRIMARY KEY(kind, item_id)
        )
        """,
        """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_classification_item_metadata_key
        ON classification_item_metadata(kind, canonical_key_version, canonical_key)
        """,
        """
        CREATE TABLE IF NOT EXISTS classification_canonical_name_ownership (
            kind TEXT NOT NULL CHECK (kind IN ('category', 'label')),
            canonical_key_version TEXT NOT NULL CHECK (length(canonical_key_version) > 0),
            canonical_key TEXT NOT NULL CHECK (length(canonical_key) > 0),
            item_id TEXT NOT NULL,
            PRIMARY KEY(kind, canonical_key_version, canonical_key),
            FOREIGN KEY(kind, item_id)
                REFERENCES classification_item_metadata(kind, item_id)
                ON DELETE CASCADE
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS classification_name_versions (
            version_id TEXT PRIMARY KEY NOT NULL,
            kind TEXT NOT NULL,
            item_id TEXT NOT NULL,
            version_sequence INTEGER NOT NULL CHECK (version_sequence >= 0),
            name TEXT NOT NULL CHECK (length(trim(name)) > 0),
            canonical_key TEXT NOT NULL CHECK (length(canonical_key) > 0),
            canonical_key_version TEXT NOT NULL CHECK (length(canonical_key_version) > 0),
            valid_from TEXT NOT NULL,
            valid_until TEXT,
            FOREIGN KEY(kind, item_id)
                REFERENCES classification_item_metadata(kind, item_id),
            UNIQUE(kind, item_id, version_sequence)
        )
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_classification_name_versions_alias
        ON classification_name_versions(kind, canonical_key_version, canonical_key, item_id)
        """,
        """
        CREATE TRIGGER IF NOT EXISTS claim_classification_canonical_name_owner
        BEFORE INSERT ON classification_name_versions
        BEGIN
            SELECT CASE WHEN EXISTS (
                SELECT 1
                FROM classification_canonical_name_ownership owner
                WHERE owner.kind = NEW.kind
                  AND owner.canonical_key_version = NEW.canonical_key_version
                  AND owner.canonical_key = NEW.canonical_key
                  AND owner.item_id <> NEW.item_id
            ) THEN RAISE(ABORT, 'classification canonical name belongs to another identity') END;
            INSERT OR IGNORE INTO classification_canonical_name_ownership(
                kind, canonical_key_version, canonical_key, item_id
            )
            VALUES (
                NEW.kind, NEW.canonical_key_version, NEW.canonical_key, NEW.item_id
            );
        END
        """,
        """
        CREATE TABLE IF NOT EXISTS classification_item_exact_times (
            kind TEXT NOT NULL CHECK (kind IN ('category', 'label')),
            item_id TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            PRIMARY KEY(kind, item_id),
            CHECK (updated_at >= created_at)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS classification_name_version_exact_times (
            version_id TEXT PRIMARY KEY NOT NULL,
            kind TEXT NOT NULL CHECK (kind IN ('category', 'label')),
            item_id TEXT NOT NULL,
            valid_from REAL NOT NULL,
            valid_until REAL,
            CHECK (valid_until IS NULL OR valid_until >= valid_from)
        )
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_classification_name_version_exact_times_item
        ON classification_name_version_exact_times(kind, item_id, valid_from)
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_item_exact_time_rewrite
        BEFORE UPDATE ON classification_item_exact_times
        WHEN NEW.kind IS NOT OLD.kind
          OR NEW.item_id IS NOT OLD.item_id
          OR NEW.created_at IS NOT OLD.created_at
          OR NEW.updated_at < OLD.updated_at
        BEGIN
            SELECT RAISE(ABORT, 'classification item exact time facts cannot move backwards');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_name_version_exact_time_rewrite
        BEFORE UPDATE ON classification_name_version_exact_times
        WHEN NEW.version_id IS NOT OLD.version_id
          OR NEW.kind IS NOT OLD.kind
          OR NEW.item_id IS NOT OLD.item_id
          OR NEW.valid_from IS NOT OLD.valid_from
          OR OLD.valid_until IS NOT NULL
          OR NEW.valid_until IS NULL
        BEGIN
            SELECT RAISE(ABORT, 'classification name version exact time facts are immutable');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_name_version_rewrite
        BEFORE UPDATE ON classification_name_versions
        WHEN NEW.version_id IS NOT OLD.version_id
          OR NEW.kind IS NOT OLD.kind
          OR NEW.item_id IS NOT OLD.item_id
          OR NEW.version_sequence IS NOT OLD.version_sequence
          OR NEW.name IS NOT OLD.name
          OR NEW.canonical_key IS NOT OLD.canonical_key
          OR NEW.canonical_key_version IS NOT OLD.canonical_key_version
          OR NEW.valid_from IS NOT OLD.valid_from
          OR OLD.valid_until IS NOT NULL
          OR NEW.valid_until IS NULL
        BEGIN
            SELECT RAISE(ABORT, 'classification name version facts are immutable');
        END
        """,
        """
        CREATE TABLE IF NOT EXISTS task_chain_categories (
            chain_id TEXT PRIMARY KEY NOT NULL REFERENCES task_chains(id) ON DELETE CASCADE,
            category_id TEXT NOT NULL REFERENCES task_categories(id)
        )
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_task_chain_categories_category
        ON task_chain_categories(category_id, chain_id)
        """,
        """
        CREATE TABLE IF NOT EXISTS task_chain_label_relations (
            chain_id TEXT NOT NULL REFERENCES task_chains(id) ON DELETE CASCADE,
            label_id TEXT NOT NULL REFERENCES task_labels(id),
            PRIMARY KEY(chain_id, label_id)
        )
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_task_chain_label_relations_label
        ON task_chain_label_relations(label_id, chain_id)
        """,
        """
        CREATE TABLE IF NOT EXISTS classification_current_chain_states (
            chain_id TEXT PRIMARY KEY NOT NULL REFERENCES task_chains(id) ON DELETE CASCADE
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS classification_current_relation_facts (
            kind TEXT NOT NULL CHECK (kind IN ('category', 'label')),
            chain_id TEXT NOT NULL REFERENCES task_chains(id) ON DELETE CASCADE,
            item_id TEXT NOT NULL,
            source_kind TEXT NOT NULL CHECK (
                source_kind IN (
                    'userDirect',
                    'zhulongSuggestion',
                    'inherited',
                    'deterministicDomainAction',
                    'automaticAI'
                )
            ),
            source_session_id TEXT,
            source_draft_id TEXT,
            source_draft_version INTEGER,
            source_evidence_id TEXT,
            source_from_chain_id TEXT,
            source_reason TEXT,
            decision_id TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            revision INTEGER NOT NULL CHECK (revision >= 0),
            FOREIGN KEY(kind, item_id)
                REFERENCES classification_item_metadata(kind, item_id),
            PRIMARY KEY(kind, chain_id, item_id),
            CHECK (updated_at >= created_at),
            CHECK (
                (
                    source_kind = 'userDirect'
                    AND source_session_id IS NULL
                    AND source_draft_id IS NULL
                    AND source_draft_version IS NULL
                    AND source_evidence_id IS NULL
                    AND source_from_chain_id IS NULL
                    AND source_reason IS NULL
                )
                OR (
                    source_kind = 'zhulongSuggestion'
                    AND source_session_id IS NOT NULL
                    AND source_draft_id IS NOT NULL
                    AND source_draft_version IS NOT NULL
                    AND typeof(source_draft_version) = 'integer'
                    AND source_evidence_id IS NOT NULL
                    AND source_from_chain_id IS NULL
                    AND source_reason IS NULL
                )
                OR (
                    source_kind = 'inherited'
                    AND source_session_id IS NULL
                    AND source_draft_id IS NULL
                    AND source_draft_version IS NULL
                    AND source_evidence_id IS NULL
                    AND source_from_chain_id IS NOT NULL
                    AND source_reason IS NULL
                )
                OR (
                    source_kind = 'deterministicDomainAction'
                    AND source_session_id IS NULL
                    AND source_draft_id IS NULL
                    AND source_draft_version IS NULL
                    AND source_evidence_id IS NULL
                    AND source_from_chain_id IS NULL
                    AND source_reason IS NOT NULL
                )
                OR (
                    source_kind = 'automaticAI'
                    AND source_session_id IS NOT NULL
                    AND source_draft_id IS NULL
                    AND source_draft_version IS NOT NULL
                    AND typeof(source_draft_version) = 'integer'
                    AND source_draft_version > 0
                    AND source_evidence_id IS NULL
                    AND source_from_chain_id IS NULL
                    AND source_reason IS NULL
                )
            )
        )
        """,
        """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_one_current_category_fact_per_chain
        ON classification_current_relation_facts(chain_id)
        WHERE kind = 'category'
        """,
        """
        CREATE TABLE IF NOT EXISTS classification_relation_history (
            history_id TEXT PRIMARY KEY NOT NULL,
            history_sequence INTEGER NOT NULL UNIQUE CHECK (history_sequence >= 0),
            kind TEXT NOT NULL CHECK (kind IN ('category', 'label')),
            chain_id TEXT NOT NULL REFERENCES task_chains(id),
            item_id TEXT NOT NULL,
            origin_source_kind TEXT NOT NULL CHECK (
                origin_source_kind IN (
                    'userDirect',
                    'zhulongSuggestion',
                    'inherited',
                    'deterministicDomainAction',
                    'automaticAI'
                )
            ),
            origin_source_session_id TEXT,
            origin_source_draft_id TEXT,
            origin_source_draft_version INTEGER,
            origin_source_evidence_id TEXT,
            origin_source_from_chain_id TEXT,
            origin_source_reason TEXT,
            origin_decision_id TEXT,
            created_at REAL NOT NULL,
            created_revision INTEGER NOT NULL CHECK (created_revision >= 0),
            removed_source_kind TEXT NOT NULL CHECK (
                removed_source_kind IN (
                    'userDirect',
                    'zhulongSuggestion',
                    'inherited',
                    'deterministicDomainAction',
                    'automaticAI'
                )
            ),
            removed_source_session_id TEXT,
            removed_source_draft_id TEXT,
            removed_source_draft_version INTEGER,
            removed_source_evidence_id TEXT,
            removed_source_from_chain_id TEXT,
            removed_source_reason TEXT,
            removed_decision_id TEXT,
            removed_at REAL NOT NULL,
            removed_revision INTEGER NOT NULL CHECK (removed_revision >= 0),
            FOREIGN KEY(kind, item_id)
                REFERENCES classification_item_metadata(kind, item_id),
            CHECK (removed_at >= created_at),
            CHECK (removed_revision > created_revision),
            CHECK (
                (
                    origin_source_kind = 'userDirect'
                    AND origin_source_session_id IS NULL
                    AND origin_source_draft_id IS NULL
                    AND origin_source_draft_version IS NULL
                    AND origin_source_evidence_id IS NULL
                    AND origin_source_from_chain_id IS NULL
                    AND origin_source_reason IS NULL
                )
                OR (
                    origin_source_kind = 'zhulongSuggestion'
                    AND origin_source_session_id IS NOT NULL
                    AND origin_source_draft_id IS NOT NULL
                    AND origin_source_draft_version IS NOT NULL
                    AND typeof(origin_source_draft_version) = 'integer'
                    AND origin_source_evidence_id IS NOT NULL
                    AND origin_source_from_chain_id IS NULL
                    AND origin_source_reason IS NULL
                )
                OR (
                    origin_source_kind = 'inherited'
                    AND origin_source_session_id IS NULL
                    AND origin_source_draft_id IS NULL
                    AND origin_source_draft_version IS NULL
                    AND origin_source_evidence_id IS NULL
                    AND origin_source_from_chain_id IS NOT NULL
                    AND origin_source_reason IS NULL
                )
                OR (
                    origin_source_kind = 'deterministicDomainAction'
                    AND origin_source_session_id IS NULL
                    AND origin_source_draft_id IS NULL
                    AND origin_source_draft_version IS NULL
                    AND origin_source_evidence_id IS NULL
                    AND origin_source_from_chain_id IS NULL
                    AND origin_source_reason IS NOT NULL
                )
                OR (
                    origin_source_kind = 'automaticAI'
                    AND origin_source_session_id IS NOT NULL
                    AND origin_source_draft_id IS NULL
                    AND origin_source_draft_version IS NOT NULL
                    AND typeof(origin_source_draft_version) = 'integer'
                    AND origin_source_draft_version > 0
                    AND origin_source_evidence_id IS NULL
                    AND origin_source_from_chain_id IS NULL
                    AND origin_source_reason IS NULL
                )
            ),
            CHECK (
                (
                    removed_source_kind = 'userDirect'
                    AND removed_source_session_id IS NULL
                    AND removed_source_draft_id IS NULL
                    AND removed_source_draft_version IS NULL
                    AND removed_source_evidence_id IS NULL
                    AND removed_source_from_chain_id IS NULL
                    AND removed_source_reason IS NULL
                )
                OR (
                    removed_source_kind = 'zhulongSuggestion'
                    AND removed_source_session_id IS NOT NULL
                    AND removed_source_draft_id IS NOT NULL
                    AND removed_source_draft_version IS NOT NULL
                    AND typeof(removed_source_draft_version) = 'integer'
                    AND removed_source_evidence_id IS NOT NULL
                    AND removed_source_from_chain_id IS NULL
                    AND removed_source_reason IS NULL
                )
                OR (
                    removed_source_kind = 'inherited'
                    AND removed_source_session_id IS NULL
                    AND removed_source_draft_id IS NULL
                    AND removed_source_draft_version IS NULL
                    AND removed_source_evidence_id IS NULL
                    AND removed_source_from_chain_id IS NOT NULL
                    AND removed_source_reason IS NULL
                )
                OR (
                    removed_source_kind = 'deterministicDomainAction'
                    AND removed_source_session_id IS NULL
                    AND removed_source_draft_id IS NULL
                    AND removed_source_draft_version IS NULL
                    AND removed_source_evidence_id IS NULL
                    AND removed_source_from_chain_id IS NULL
                    AND removed_source_reason IS NOT NULL
                )
                OR (
                    removed_source_kind = 'automaticAI'
                    AND removed_source_session_id IS NOT NULL
                    AND removed_source_draft_id IS NULL
                    AND removed_source_draft_version IS NOT NULL
                    AND typeof(removed_source_draft_version) = 'integer'
                    AND removed_source_draft_version > 0
                    AND removed_source_evidence_id IS NULL
                    AND removed_source_from_chain_id IS NULL
                    AND removed_source_reason IS NULL
                )
            )
        )
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_classification_relation_history_item
        ON classification_relation_history(kind, item_id, history_sequence)
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_relation_history_update
        BEFORE UPDATE OF
            history_id, kind, chain_id, item_id,
            origin_source_kind, origin_source_session_id, origin_source_draft_id,
            origin_source_draft_version, origin_source_evidence_id, origin_source_from_chain_id,
            origin_source_reason, origin_decision_id,
            created_at, created_revision,
            removed_source_kind, removed_source_session_id, removed_source_draft_id,
            removed_source_draft_version, removed_source_evidence_id, removed_source_from_chain_id,
            removed_source_reason, removed_decision_id,
            removed_at, removed_revision
        ON classification_relation_history
        BEGIN
            SELECT RAISE(ABORT, 'classification relation history facts are immutable');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_relation_history_delete
        BEFORE DELETE ON classification_relation_history
        BEGIN
            SELECT RAISE(ABORT, 'classification relation history is append-only');
        END
        """,
        """
        CREATE TABLE IF NOT EXISTS classification_merges (
            kind TEXT NOT NULL CHECK (kind IN ('category', 'label')),
            source_id TEXT NOT NULL,
            merge_id TEXT NOT NULL UNIQUE,
            target_id TEXT NOT NULL,
            merged_at REAL NOT NULL,
            revision INTEGER NOT NULL CHECK (revision >= 0),
            change_record_id TEXT NOT NULL REFERENCES classification_change_records(record_id),
            FOREIGN KEY(kind, source_id)
                REFERENCES classification_item_metadata(kind, item_id),
            FOREIGN KEY(kind, target_id)
                REFERENCES classification_item_metadata(kind, item_id),
            PRIMARY KEY(kind, source_id),
            CHECK (source_id != target_id)
        )
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_classification_merges_target
        ON classification_merges(kind, target_id)
        """,
        """
        CREATE TRIGGER IF NOT EXISTS validate_classification_merge_insert
        BEFORE INSERT ON classification_merges
        WHEN NOT EXISTS (
            SELECT 1 FROM classification_item_metadata source
            WHERE source.kind = NEW.kind AND source.item_id = NEW.source_id
        )
        OR NOT EXISTS (
            SELECT 1 FROM classification_item_metadata target
            WHERE target.kind = NEW.kind AND target.item_id = NEW.target_id
        )
        BEGIN
            SELECT RAISE(ABORT, 'classification merge identity is missing or has the wrong kind');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_merge_update
        BEFORE UPDATE ON classification_merges
        BEGIN
            SELECT RAISE(ABORT, 'classification merges are append-only');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_merge_delete
        BEFORE DELETE ON classification_merges
        BEGIN
            SELECT RAISE(ABORT, 'classification merges are append-only');
        END
        """,
        """
        CREATE TABLE IF NOT EXISTS classification_state (
            id INTEGER PRIMARY KEY NOT NULL CHECK (id = 1),
            revision INTEGER NOT NULL CHECK (revision >= 0)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS classification_commits (
            interaction_id TEXT PRIMARY KEY NOT NULL,
            plan_id TEXT NOT NULL UNIQUE,
            revision INTEGER NOT NULL CHECK (revision >= 0)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS classification_commit_notice_records (
            interaction_id TEXT NOT NULL
                REFERENCES classification_commits(interaction_id) ON DELETE CASCADE,
            position INTEGER NOT NULL CHECK (position >= 0),
            kind TEXT NOT NULL CHECK (kind IN ('duplicateLabelCollapsed', 'existingItemReused')),
            duplicate_name TEXT,
            item_kind TEXT CHECK (item_kind IS NULL OR item_kind IN ('category', 'label')),
            input_name TEXT,
            current_name TEXT,
            matched_historical_alias INTEGER CHECK (
                matched_historical_alias IS NULL OR matched_historical_alias IN (0, 1)
            ),
            PRIMARY KEY(interaction_id, position),
            CHECK (
                (
                    kind = 'duplicateLabelCollapsed'
                    AND duplicate_name IS NOT NULL
                    AND length(trim(duplicate_name)) > 0
                    AND item_kind IS NULL
                    AND input_name IS NULL
                    AND current_name IS NULL
                    AND matched_historical_alias IS NULL
                )
                OR (
                    kind = 'existingItemReused'
                    AND duplicate_name IS NULL
                    AND item_kind IS NOT NULL
                    AND input_name IS NOT NULL
                    AND length(trim(input_name)) > 0
                    AND current_name IS NOT NULL
                    AND length(trim(current_name)) > 0
                    AND matched_historical_alias IS NOT NULL
                )
            )
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS classification_change_records (
            record_id TEXT PRIMARY KEY NOT NULL CHECK (length(record_id) > 0),
            record_sequence INTEGER NOT NULL UNIQUE CHECK (record_sequence >= 0),
            plan_id TEXT NOT NULL UNIQUE,
            interaction_id TEXT NOT NULL UNIQUE,
            source_kind TEXT NOT NULL CHECK (
                source_kind IN (
                    'userDirect',
                    'zhulongSuggestion',
                    'inherited',
                    'deterministicDomainAction',
                    'automaticAI'
                )
            ),
            source_session_id TEXT,
            source_draft_id TEXT,
            source_draft_version INTEGER,
            source_evidence_id TEXT,
            source_from_chain_id TEXT,
            source_reason TEXT,
            decision_id TEXT,
            committed_at REAL NOT NULL,
            revision INTEGER NOT NULL CHECK (revision >= 0),
            CHECK (
                (
                    source_kind = 'userDirect'
                    AND source_session_id IS NULL
                    AND source_draft_id IS NULL
                    AND source_draft_version IS NULL
                    AND source_evidence_id IS NULL
                    AND source_from_chain_id IS NULL
                    AND source_reason IS NULL
                )
                OR (
                    source_kind = 'zhulongSuggestion'
                    AND source_session_id IS NOT NULL
                    AND source_draft_id IS NOT NULL
                    AND source_draft_version IS NOT NULL
                    AND typeof(source_draft_version) = 'integer'
                    AND source_evidence_id IS NOT NULL
                    AND source_from_chain_id IS NULL
                    AND source_reason IS NULL
                )
                OR (
                    source_kind = 'inherited'
                    AND source_session_id IS NULL
                    AND source_draft_id IS NULL
                    AND source_draft_version IS NULL
                    AND source_evidence_id IS NULL
                    AND source_from_chain_id IS NOT NULL
                    AND source_reason IS NULL
                )
                OR (
                    source_kind = 'deterministicDomainAction'
                    AND source_session_id IS NULL
                    AND source_draft_id IS NULL
                    AND source_draft_version IS NULL
                    AND source_evidence_id IS NULL
                    AND source_from_chain_id IS NULL
                    AND source_reason IS NOT NULL
                )
                OR (
                    source_kind = 'automaticAI'
                    AND source_session_id IS NOT NULL
                    AND source_draft_id IS NULL
                    AND source_draft_version IS NOT NULL
                    AND typeof(source_draft_version) = 'integer'
                    AND source_draft_version > 0
                    AND source_evidence_id IS NULL
                    AND source_from_chain_id IS NULL
                    AND source_reason IS NULL
                )
            )
        )
        """,
        """
        CREATE TRIGGER IF NOT EXISTS validate_classification_change_record_source_insert
        BEFORE INSERT ON classification_change_records
        WHEN NOT (
            (
                NEW.source_kind = 'userDirect'
                AND NEW.source_session_id IS NULL
                AND NEW.source_draft_id IS NULL
                AND NEW.source_draft_version IS NULL
                AND NEW.source_evidence_id IS NULL
                AND NEW.source_from_chain_id IS NULL
                AND NEW.source_reason IS NULL
            )
            OR (
                NEW.source_kind = 'zhulongSuggestion'
                AND NEW.source_session_id IS NOT NULL
                AND NEW.source_draft_id IS NOT NULL
                AND NEW.source_draft_version IS NOT NULL
                AND typeof(NEW.source_draft_version) = 'integer'
                AND NEW.source_evidence_id IS NOT NULL
                AND NEW.source_from_chain_id IS NULL
                AND NEW.source_reason IS NULL
            )
            OR (
                NEW.source_kind = 'inherited'
                AND NEW.source_session_id IS NULL
                AND NEW.source_draft_id IS NULL
                AND NEW.source_draft_version IS NULL
                AND NEW.source_evidence_id IS NULL
                AND NEW.source_from_chain_id IS NOT NULL
                AND NEW.source_reason IS NULL
            )
            OR (
                NEW.source_kind = 'deterministicDomainAction'
                AND NEW.source_session_id IS NULL
                AND NEW.source_draft_id IS NULL
                AND NEW.source_draft_version IS NULL
                AND NEW.source_evidence_id IS NULL
                AND NEW.source_from_chain_id IS NULL
                AND NEW.source_reason IS NOT NULL
            )
            OR (
                NEW.source_kind = 'automaticAI'
                AND NEW.source_session_id IS NOT NULL
                AND NEW.source_draft_id IS NULL
                AND NEW.source_draft_version IS NOT NULL
                AND typeof(NEW.source_draft_version) = 'integer'
                AND NEW.source_draft_version > 0
                AND NEW.source_evidence_id IS NULL
                AND NEW.source_from_chain_id IS NULL
                AND NEW.source_reason IS NULL
            )
        )
        BEGIN
            SELECT RAISE(ABORT, 'classification change record source payload is invalid');
        END
        """,
        """
        CREATE TABLE IF NOT EXISTS classification_change_record_notice_records (
            record_id TEXT NOT NULL REFERENCES classification_change_records(record_id),
            position INTEGER NOT NULL CHECK (position >= 0),
            kind TEXT NOT NULL CHECK (kind IN ('duplicateLabelCollapsed', 'existingItemReused')),
            duplicate_name TEXT,
            item_kind TEXT CHECK (item_kind IS NULL OR item_kind IN ('category', 'label')),
            input_name TEXT,
            current_name TEXT,
            matched_historical_alias INTEGER CHECK (
                matched_historical_alias IS NULL OR matched_historical_alias IN (0, 1)
            ),
            PRIMARY KEY(record_id, position),
            CHECK (
                (
                    kind = 'duplicateLabelCollapsed'
                    AND duplicate_name IS NOT NULL
                    AND length(trim(duplicate_name)) > 0
                    AND item_kind IS NULL
                    AND input_name IS NULL
                    AND current_name IS NULL
                    AND matched_historical_alias IS NULL
                )
                OR (
                    kind = 'existingItemReused'
                    AND duplicate_name IS NULL
                    AND item_kind IS NOT NULL
                    AND input_name IS NOT NULL
                    AND length(trim(input_name)) > 0
                    AND current_name IS NOT NULL
                    AND length(trim(current_name)) > 0
                    AND matched_historical_alias IS NOT NULL
                )
            )
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS classification_change_record_changes (
            record_id TEXT NOT NULL
                REFERENCES classification_change_records(record_id),
            position INTEGER NOT NULL CHECK (position >= 0),
            kind TEXT NOT NULL CHECK (
                kind IN ('setCurrent', 'rename', 'lifecycle', 'categoryPresentationApproval')
            ),
            chain_id TEXT,
            item_kind TEXT CHECK (item_kind IS NULL OR item_kind IN ('category', 'label')),
            item_id TEXT,
            before_name TEXT,
            after_name TEXT,
            name TEXT,
            before_lifecycle TEXT CHECK (
                before_lifecycle IS NULL OR before_lifecycle IN ('active', 'archived', 'merged')
            ),
            after_lifecycle TEXT CHECK (
                after_lifecycle IS NULL OR after_lifecycle IN ('active', 'archived', 'merged')
            ),
            before_approval TEXT CHECK (
                before_approval IS NULL OR before_approval IN ('userApproved', 'pendingAIReview')
            ),
            after_approval TEXT CHECK (
                after_approval IS NULL OR after_approval IN ('userApproved', 'pendingAIReview')
            ),
            PRIMARY KEY(record_id, position),
            CHECK (
                (
                    kind = 'setCurrent'
                    AND chain_id IS NOT NULL
                    AND item_kind IS NULL
                    AND item_id IS NULL
                    AND before_name IS NULL
                    AND after_name IS NULL
                    AND name IS NULL
                    AND before_lifecycle IS NULL
                    AND after_lifecycle IS NULL
                    AND before_approval IS NULL
                    AND after_approval IS NULL
                )
                OR (
                    kind = 'rename'
                    AND chain_id IS NULL
                    AND item_kind IS NOT NULL
                    AND item_id IS NOT NULL
                    AND length(trim(item_id)) > 0
                    AND before_name IS NOT NULL
                    AND length(trim(before_name)) > 0
                    AND after_name IS NOT NULL
                    AND length(trim(after_name)) > 0
                    AND name IS NULL
                    AND before_lifecycle IS NULL
                    AND after_lifecycle IS NULL
                    AND before_approval IS NULL
                    AND after_approval IS NULL
                )
                OR (
                    kind = 'lifecycle'
                    AND chain_id IS NULL
                    AND item_kind IS NOT NULL
                    AND item_id IS NOT NULL
                    AND length(trim(item_id)) > 0
                    AND before_name IS NULL
                    AND after_name IS NULL
                    AND name IS NOT NULL
                    AND length(trim(name)) > 0
                    AND before_lifecycle IS NOT NULL
                    AND after_lifecycle IS NOT NULL
                    AND before_approval IS NULL
                    AND after_approval IS NULL
                )
                OR (
                    kind = 'categoryPresentationApproval'
                    AND chain_id IS NULL
                    AND item_kind = 'category'
                    AND item_id IS NOT NULL
                    AND length(trim(item_id)) > 0
                    AND before_name IS NULL
                    AND after_name IS NULL
                    AND name IS NOT NULL
                    AND length(trim(name)) > 0
                    AND before_lifecycle IS NULL
                    AND after_lifecycle IS NULL
                    AND before_approval = 'pendingAIReview'
                    AND after_approval = 'userApproved'
                )
            )
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS classification_change_selection_items (
            record_id TEXT NOT NULL,
            change_position INTEGER NOT NULL CHECK (change_position >= 0),
            selection_side TEXT NOT NULL CHECK (selection_side IN ('before', 'after')),
            item_position INTEGER NOT NULL CHECK (item_position >= 0),
            item_id TEXT,
            item_kind TEXT NOT NULL CHECK (item_kind IN ('category', 'label')),
            name TEXT NOT NULL CHECK (length(trim(name)) > 0),
            color_hex TEXT NOT NULL CHECK (length(trim(color_hex)) > 0),
            resolution TEXT NOT NULL CHECK (resolution IN ('existing', 'historicalAlias', 'new')),
            PRIMARY KEY(record_id, change_position, selection_side, item_position),
            FOREIGN KEY(record_id, change_position)
                REFERENCES classification_change_record_changes(record_id, position),
            CHECK (
                (
                    resolution = 'new'
                    AND (item_id IS NULL OR length(trim(item_id)) > 0)
                )
                OR (
                    resolution != 'new'
                    AND item_id IS NOT NULL
                    AND length(trim(item_id)) > 0
                )
            )
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS classification_management_changes (
            record_id TEXT NOT NULL REFERENCES classification_change_records(record_id),
            position INTEGER NOT NULL CHECK (position >= 0),
            kind TEXT NOT NULL CHECK (kind IN ('create', 'merge', 'hardDelete')),
            item_kind TEXT NOT NULL CHECK (item_kind IN ('category', 'label')),
            item_id TEXT NOT NULL CHECK (length(trim(item_id)) > 0),
            name TEXT NOT NULL CHECK (length(trim(name)) > 0),
            color_hex TEXT,
            target_id TEXT,
            target_name TEXT,
            source_lifecycle TEXT CHECK (
                source_lifecycle IS NULL OR source_lifecycle IN ('active', 'archived', 'merged')
            ),
            lifecycle TEXT CHECK (
                lifecycle IS NULL OR lifecycle IN ('active', 'archived', 'merged')
            ),
            migrated_relation_count INTEGER CHECK (migrated_relation_count >= 0),
            deduplicated_relation_count INTEGER CHECK (deduplicated_relation_count >= 0),
            current_relation_count INTEGER CHECK (current_relation_count >= 0),
            relation_history_count INTEGER CHECK (relation_history_count >= 0),
            historical_event_count INTEGER CHECK (historical_event_count >= 0),
            merge_source_count INTEGER CHECK (merge_source_count >= 0),
            merge_target_count INTEGER CHECK (merge_target_count >= 0),
            PRIMARY KEY(record_id, position),
            CHECK (
                (
                    kind = 'create'
                    AND color_hex IS NOT NULL
                    AND length(trim(color_hex)) > 0
                    AND target_id IS NULL
                    AND target_name IS NULL
                    AND source_lifecycle IS NULL
                    AND lifecycle IS NULL
                    AND migrated_relation_count IS NULL
                    AND deduplicated_relation_count IS NULL
                    AND current_relation_count IS NULL
                    AND relation_history_count IS NULL
                    AND historical_event_count IS NULL
                    AND merge_source_count IS NULL
                    AND merge_target_count IS NULL
                )
                OR (
                    kind = 'merge'
                    AND color_hex IS NULL
                    AND target_id IS NOT NULL
                    AND length(trim(target_id)) > 0
                    AND target_name IS NOT NULL
                    AND length(trim(target_name)) > 0
                    AND source_lifecycle IS NOT NULL
                    AND lifecycle IS NULL
                    AND migrated_relation_count IS NOT NULL
                    AND deduplicated_relation_count IS NOT NULL
                    AND current_relation_count IS NULL
                    AND relation_history_count IS NULL
                    AND historical_event_count IS NULL
                    AND merge_source_count IS NULL
                    AND merge_target_count IS NULL
                )
                OR (
                    kind = 'hardDelete'
                    AND color_hex IS NULL
                    AND target_id IS NULL
                    AND target_name IS NULL
                    AND source_lifecycle IS NULL
                    AND lifecycle IS NOT NULL
                    AND migrated_relation_count IS NULL
                    AND deduplicated_relation_count IS NULL
                    AND current_relation_count IS NOT NULL
                    AND relation_history_count IS NOT NULL
                    AND historical_event_count IS NOT NULL
                    AND merge_source_count IS NOT NULL
                    AND merge_target_count IS NOT NULL
                )
            )
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS classification_merge_impact_chain_ids (
            record_id TEXT NOT NULL,
            change_position INTEGER NOT NULL CHECK (change_position >= 0),
            item_position INTEGER NOT NULL CHECK (item_position >= 0),
            chain_id TEXT NOT NULL,
            PRIMARY KEY(record_id, change_position, item_position),
            FOREIGN KEY(record_id, change_position)
                REFERENCES classification_management_changes(record_id, position)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS classification_merge_impact_trace_ids (
            record_id TEXT NOT NULL,
            change_position INTEGER NOT NULL CHECK (change_position >= 0),
            item_position INTEGER NOT NULL CHECK (item_position >= 0),
            trace_id TEXT NOT NULL,
            PRIMARY KEY(record_id, change_position, item_position),
            FOREIGN KEY(record_id, change_position)
                REFERENCES classification_management_changes(record_id, position)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS classification_merge_impact_event_ids (
            record_id TEXT NOT NULL,
            change_position INTEGER NOT NULL CHECK (change_position >= 0),
            item_position INTEGER NOT NULL CHECK (item_position >= 0),
            event_id TEXT NOT NULL,
            PRIMARY KEY(record_id, change_position, item_position),
            FOREIGN KEY(record_id, change_position)
                REFERENCES classification_management_changes(record_id, position)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS classification_change_record_plan_digests (
            record_id TEXT PRIMARY KEY NOT NULL REFERENCES classification_change_records(record_id),
            digest TEXT NOT NULL CHECK (
                length(digest) = 64
                AND digest NOT GLOB '*[^0-9a-f]*'
            )
        )
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_plan_digest_update
        BEFORE UPDATE ON classification_change_record_plan_digests
        BEGIN
            SELECT RAISE(ABORT, 'classification plan digest is immutable');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_plan_digest_delete
        BEFORE DELETE ON classification_change_record_plan_digests
        BEGIN
            SELECT RAISE(ABORT, 'classification plan digest is immutable');
        END
        """,
        """
        CREATE TABLE IF NOT EXISTS classification_change_record_integrity_digests (
            record_id TEXT PRIMARY KEY NOT NULL REFERENCES classification_change_records(record_id),
            digest TEXT NOT NULL CHECK (
                length(digest) = 64
                AND digest NOT GLOB '*[^0-9a-f]*'
            )
        )
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_integrity_digest_update
        BEFORE UPDATE ON classification_change_record_integrity_digests
        BEGIN
            SELECT RAISE(ABORT, 'classification integrity digest is immutable');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_integrity_digest_delete
        BEFORE DELETE ON classification_change_record_integrity_digests
        BEGIN
            SELECT RAISE(ABORT, 'classification integrity digest is immutable');
        END
        """,
        """
        CREATE TABLE IF NOT EXISTS classification_change_record_finalizations (
            record_id TEXT PRIMARY KEY NOT NULL REFERENCES classification_change_records(record_id),
            change_count INTEGER NOT NULL CHECK (change_count >= 0),
            notice_count INTEGER NOT NULL CHECK (notice_count >= 0)
        )
        """,
        """
        CREATE TRIGGER IF NOT EXISTS validate_classification_change_record_finalization_insert
        BEFORE INSERT ON classification_change_record_finalizations
        WHEN NEW.change_count != (
            SELECT COUNT(*) FROM classification_change_record_changes change
            WHERE change.record_id = NEW.record_id
        ) + (
            SELECT COUNT(*) FROM classification_management_changes management
            WHERE management.record_id = NEW.record_id
        )
        OR NEW.notice_count != (
            SELECT COUNT(*) FROM classification_change_record_notice_records notice
            WHERE notice.record_id = NEW.record_id
        )
        OR NOT EXISTS (
            SELECT 1 FROM classification_change_record_plan_digests digest
            WHERE digest.record_id = NEW.record_id
        )
        OR NOT EXISTS (
            SELECT 1 FROM classification_change_record_integrity_digests digest
            WHERE digest.record_id = NEW.record_id
        )
        BEGIN
            SELECT RAISE(ABORT, 'classification change record finalization does not match its facts');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_change_record_notice_update
        BEFORE UPDATE ON classification_change_record_notice_records
        BEGIN
            SELECT RAISE(ABORT, 'classification change record notices are append-only');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_change_record_notice_delete
        BEFORE DELETE ON classification_change_record_notice_records
        BEGIN
            SELECT RAISE(ABORT, 'classification change record notices are append-only');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_change_record_finalization_update
        BEFORE UPDATE ON classification_change_record_finalizations
        BEGIN
            SELECT RAISE(ABORT, 'classification change record finalization is immutable');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_change_record_finalization_delete
        BEFORE DELETE ON classification_change_record_finalizations
        BEGIN
            SELECT RAISE(ABORT, 'classification change record finalization is immutable');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_late_classification_change_insert
        BEFORE INSERT ON classification_change_record_changes
        WHEN EXISTS (
            SELECT 1 FROM classification_change_record_finalizations finalization
            WHERE finalization.record_id = NEW.record_id
        )
        BEGIN
            SELECT RAISE(ABORT, 'classification change record is finalized');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_late_classification_change_record_notice_insert
        BEFORE INSERT ON classification_change_record_notice_records
        WHEN EXISTS (
            SELECT 1 FROM classification_change_record_finalizations finalization
            WHERE finalization.record_id = NEW.record_id
        )
        BEGIN
            SELECT RAISE(ABORT, 'classification change record is finalized');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_late_classification_plan_digest_insert
        BEFORE INSERT ON classification_change_record_plan_digests
        WHEN EXISTS (
            SELECT 1 FROM classification_change_record_finalizations finalization
            WHERE finalization.record_id = NEW.record_id
        )
        BEGIN
            SELECT RAISE(ABORT, 'classification change record is finalized');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_late_classification_integrity_digest_insert
        BEFORE INSERT ON classification_change_record_integrity_digests
        WHEN EXISTS (
            SELECT 1 FROM classification_change_record_finalizations finalization
            WHERE finalization.record_id = NEW.record_id
        )
        BEGIN
            SELECT RAISE(ABORT, 'classification change record is finalized');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_late_classification_selection_insert
        BEFORE INSERT ON classification_change_selection_items
        WHEN EXISTS (
            SELECT 1 FROM classification_change_record_finalizations finalization
            WHERE finalization.record_id = NEW.record_id
        )
        BEGIN
            SELECT RAISE(ABORT, 'classification change record is finalized');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_late_classification_management_change_insert
        BEFORE INSERT ON classification_management_changes
        WHEN EXISTS (
            SELECT 1 FROM classification_change_record_finalizations finalization
            WHERE finalization.record_id = NEW.record_id
        )
        BEGIN
            SELECT RAISE(ABORT, 'classification change record is finalized');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_late_classification_merge_impact_chain_insert
        BEFORE INSERT ON classification_merge_impact_chain_ids
        WHEN EXISTS (
            SELECT 1 FROM classification_change_record_finalizations finalization
            WHERE finalization.record_id = NEW.record_id
        )
        BEGIN
            SELECT RAISE(ABORT, 'classification change record is finalized');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_late_classification_merge_impact_trace_insert
        BEFORE INSERT ON classification_merge_impact_trace_ids
        WHEN EXISTS (
            SELECT 1 FROM classification_change_record_finalizations finalization
            WHERE finalization.record_id = NEW.record_id
        )
        BEGIN
            SELECT RAISE(ABORT, 'classification change record is finalized');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_late_classification_merge_impact_event_insert
        BEFORE INSERT ON classification_merge_impact_event_ids
        WHEN EXISTS (
            SELECT 1 FROM classification_change_record_finalizations finalization
            WHERE finalization.record_id = NEW.record_id
        )
        BEGIN
            SELECT RAISE(ABORT, 'classification change record is finalized');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_management_change_update
        BEFORE UPDATE ON classification_management_changes
        BEGIN
            SELECT RAISE(ABORT, 'classification management changes are append-only');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_management_change_delete
        BEFORE DELETE ON classification_management_changes
        BEGIN
            SELECT RAISE(ABORT, 'classification management changes are append-only');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_merge_impact_chain_update
        BEFORE UPDATE ON classification_merge_impact_chain_ids
        BEGIN
            SELECT RAISE(ABORT, 'classification merge impact is append-only');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_merge_impact_chain_delete
        BEFORE DELETE ON classification_merge_impact_chain_ids
        BEGIN
            SELECT RAISE(ABORT, 'classification merge impact is append-only');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_merge_impact_trace_update
        BEFORE UPDATE ON classification_merge_impact_trace_ids
        BEGIN
            SELECT RAISE(ABORT, 'classification merge impact is append-only');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_merge_impact_trace_delete
        BEFORE DELETE ON classification_merge_impact_trace_ids
        BEGIN
            SELECT RAISE(ABORT, 'classification merge impact is append-only');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_merge_impact_event_update
        BEFORE UPDATE ON classification_merge_impact_event_ids
        BEGIN
            SELECT RAISE(ABORT, 'classification merge impact is append-only');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_merge_impact_event_delete
        BEFORE DELETE ON classification_merge_impact_event_ids
        BEGIN
            SELECT RAISE(ABORT, 'classification merge impact is append-only');
        END
        """,
        """
        CREATE TABLE IF NOT EXISTS classification_commit_receipt_metadata (
            interaction_id TEXT PRIMARY KEY NOT NULL
                REFERENCES classification_commits(interaction_id),
            change_record_id TEXT NOT NULL UNIQUE
                REFERENCES classification_change_records(record_id),
            decision_id TEXT
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS classification_commit_receipt_integrity_digests (
            interaction_id TEXT PRIMARY KEY NOT NULL
                REFERENCES classification_commit_receipt_metadata(interaction_id),
            digest TEXT NOT NULL CHECK (
                length(digest) = 64
                AND digest NOT GLOB '*[^0-9a-f]*'
            )
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS classification_commit_finalizations (
            interaction_id TEXT PRIMARY KEY NOT NULL
                REFERENCES classification_commits(interaction_id),
            notice_count INTEGER NOT NULL CHECK (notice_count >= 0)
        )
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_commit_update
        BEFORE UPDATE ON classification_commits
        BEGIN
            SELECT RAISE(ABORT, 'classification commits are append-only');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_commit_delete
        BEFORE DELETE ON classification_commits
        BEGIN
            SELECT RAISE(ABORT, 'classification commits are append-only');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_notice_record_update
        BEFORE UPDATE ON classification_commit_notice_records
        BEGIN
            SELECT RAISE(ABORT, 'classification commit notices are append-only');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_notice_record_delete
        BEFORE DELETE ON classification_commit_notice_records
        BEGIN
            SELECT RAISE(ABORT, 'classification commit notices are append-only');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_receipt_metadata_update
        BEFORE UPDATE ON classification_commit_receipt_metadata
        BEGIN
            SELECT RAISE(ABORT, 'classification receipt metadata is immutable');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_receipt_metadata_delete
        BEFORE DELETE ON classification_commit_receipt_metadata
        BEGIN
            SELECT RAISE(ABORT, 'classification receipt metadata is immutable');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_receipt_digest_update
        BEFORE UPDATE ON classification_commit_receipt_integrity_digests
        BEGIN
            SELECT RAISE(ABORT, 'classification receipt integrity digest is immutable');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_receipt_digest_delete
        BEFORE DELETE ON classification_commit_receipt_integrity_digests
        BEGIN
            SELECT RAISE(ABORT, 'classification receipt integrity digest is immutable');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS validate_classification_commit_finalization_insert
        BEFORE INSERT ON classification_commit_finalizations
        WHEN NEW.notice_count != (
            SELECT COUNT(*) FROM classification_commit_notice_records notice
            WHERE notice.interaction_id = NEW.interaction_id
        )
        OR NOT EXISTS (
            SELECT 1 FROM classification_commit_receipt_metadata metadata
            WHERE metadata.interaction_id = NEW.interaction_id
        )
        OR NOT EXISTS (
            SELECT 1 FROM classification_commit_receipt_integrity_digests digest
            WHERE digest.interaction_id = NEW.interaction_id
        )
        BEGIN
            SELECT RAISE(ABORT, 'classification commit finalization does not match its facts');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_commit_finalization_update
        BEFORE UPDATE ON classification_commit_finalizations
        BEGIN
            SELECT RAISE(ABORT, 'classification commit finalization is immutable');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_commit_finalization_delete
        BEFORE DELETE ON classification_commit_finalizations
        BEGIN
            SELECT RAISE(ABORT, 'classification commit finalization is immutable');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_late_classification_notice_record_insert
        BEFORE INSERT ON classification_commit_notice_records
        WHEN EXISTS (
            SELECT 1 FROM classification_commit_finalizations finalization
            WHERE finalization.interaction_id = NEW.interaction_id
        )
        BEGIN
            SELECT RAISE(ABORT, 'classification commit is finalized');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_late_classification_receipt_metadata_insert
        BEFORE INSERT ON classification_commit_receipt_metadata
        WHEN EXISTS (
            SELECT 1 FROM classification_commit_finalizations finalization
            WHERE finalization.interaction_id = NEW.interaction_id
        )
        BEGIN
            SELECT RAISE(ABORT, 'classification commit is finalized');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_late_classification_receipt_digest_insert
        BEFORE INSERT ON classification_commit_receipt_integrity_digests
        WHEN EXISTS (
            SELECT 1 FROM classification_commit_finalizations finalization
            WHERE finalization.interaction_id = NEW.interaction_id
        )
        BEGIN
            SELECT RAISE(ABORT, 'classification commit is finalized');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_change_record_update
        BEFORE UPDATE OF
            record_id, plan_id, interaction_id, source_kind,
            source_session_id, source_draft_id, source_draft_version, source_evidence_id,
            source_from_chain_id, source_reason,
            decision_id, committed_at, revision
        ON classification_change_records
        BEGIN
            SELECT RAISE(ABORT, 'classification change record facts are immutable');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_change_record_delete
        BEFORE DELETE ON classification_change_records
        BEGIN
            SELECT RAISE(ABORT, 'classification change records are append-only');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_change_update
        BEFORE UPDATE ON classification_change_record_changes
        BEGIN
            SELECT RAISE(ABORT, 'classification changes are append-only');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_change_delete
        BEFORE DELETE ON classification_change_record_changes
        BEGIN
            SELECT RAISE(ABORT, 'classification changes are append-only');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_change_selection_update
        BEFORE UPDATE ON classification_change_selection_items
        BEGIN
            SELECT RAISE(ABORT, 'classification change selections are append-only');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_change_selection_delete
        BEFORE DELETE ON classification_change_selection_items
        BEGIN
            SELECT RAISE(ABORT, 'classification change selections are append-only');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_receipt_metadata_update
        BEFORE UPDATE ON classification_commit_receipt_metadata
        BEGIN
            SELECT RAISE(ABORT, 'classification receipt metadata is immutable');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_receipt_metadata_delete
        BEFORE DELETE ON classification_commit_receipt_metadata
        BEGIN
            SELECT RAISE(ABORT, 'classification receipt metadata is immutable');
        END
        """,
        """
        CREATE TABLE IF NOT EXISTS task_definitions (
            id TEXT PRIMARY KEY NOT NULL,
            chain_id TEXT NOT NULL REFERENCES task_chains(id),
            sequence INTEGER NOT NULL,
            title TEXT NOT NULL,
            description_text TEXT,
            planned_subtasks_json TEXT,
            created_at TEXT NOT NULL,
            created_at_bits INTEGER NOT NULL CHECK (typeof(created_at_bits) = 'integer'),
            content_updated_at TEXT NOT NULL,
            content_updated_at_bits INTEGER NOT NULL CHECK (
                typeof(content_updated_at_bits) = 'integer'
            ),
            superseded_at TEXT,
            superseded_at_bits INTEGER CHECK (
                superseded_at_bits IS NULL OR typeof(superseded_at_bits) = 'integer'
            ),
            superseded_by_definition_id TEXT REFERENCES task_definitions(id),
            CHECK ((superseded_at IS NULL) = (superseded_at_bits IS NULL)),
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
                    'deferred',
                    'changed',
                    'returnedToPool',
                    'cancelledDraft',
                    'abandoned'
                )
            ),
            priority INTEGER NOT NULL,
            pin_order INTEGER CHECK (
                pin_order IS NULL
                OR (
                    typeof(pin_order) = 'integer'
                    AND pin_order > 0
                    AND status = 'pending'
                )
            ),
            continuation_seq INTEGER NOT NULL DEFAULT 0,
            description_text TEXT,
            note_entries_json TEXT NOT NULL CHECK (
                json_valid(note_entries_json)
                AND json_type(note_entries_json) = 'array'
            ),
            manual_progress_percent INTEGER CHECK (
                manual_progress_percent IS NULL
                OR (manual_progress_percent >= 0 AND manual_progress_percent <= 100)
            ),
            carried_from_trace_id TEXT REFERENCES day_traces(id),
            changed_to_trace_id TEXT REFERENCES day_traces(id),
            created_at TEXT NOT NULL,
            created_at_bits INTEGER NOT NULL CHECK (typeof(created_at_bits) = 'integer'),
            content_updated_at TEXT NOT NULL,
            content_updated_at_bits INTEGER NOT NULL CHECK (typeof(content_updated_at_bits) = 'integer'),
            completed_at TEXT,
            completed_at_bits INTEGER CHECK (
                completed_at_bits IS NULL OR typeof(completed_at_bits) = 'integer'
            ),
            settled_at TEXT,
            settled_at_bits INTEGER CHECK (
                settled_at_bits IS NULL OR typeof(settled_at_bits) = 'integer'
            ),
            draft_cancellation_id TEXT CHECK (
                draft_cancellation_id IS NULL OR length(draft_cancellation_id) = 36
            ),
            draft_cancelled_on TEXT,
            CHECK ((completed_at IS NULL) = (completed_at_bits IS NULL)),
            CHECK ((settled_at IS NULL) = (settled_at_bits IS NULL)),
            CHECK (
                (
                    status = 'cancelledDraft'
                    AND draft_cancellation_id IS NOT NULL
                    AND draft_cancelled_on IS NOT NULL
                    AND date >= draft_cancelled_on
                    AND completed_at IS NULL
                    AND settled_at IS NOT NULL
                    AND changed_to_trace_id IS NULL
                )
                OR (
                    status <> 'cancelledDraft'
                    AND draft_cancelled_on IS NULL
                )
            )
        )
        """,
        """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_unique_draft_cancellation_id
        ON day_traces(draft_cancellation_id)
        WHERE draft_cancellation_id IS NOT NULL
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
        CREATE TABLE IF NOT EXISTS trace_classification_snapshot_events (
            event_id TEXT PRIMARY KEY NOT NULL,
            trace_id TEXT NOT NULL REFERENCES day_traces(id),
            event_sequence INTEGER NOT NULL CHECK (event_sequence >= 0),
            status TEXT NOT NULL CHECK (
                status IN (
                    'pending',
                    'completed',
                    'unfinished',
                    'deferred',
                    'changed',
                    'returnedToPool',
                    'abandoned'
                )
            ),
            captured_at REAL NOT NULL,
            revision INTEGER NOT NULL CHECK (revision > 0),
            UNIQUE(trace_id, event_sequence)
        )
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_trace_classification_snapshot_events_trace
        ON trace_classification_snapshot_events(trace_id, event_sequence)
        """,
        """
        CREATE TABLE IF NOT EXISTS trace_classification_event_categories (
            event_id TEXT PRIMARY KEY NOT NULL
                REFERENCES trace_classification_snapshot_events(event_id) ON DELETE CASCADE,
            category_id TEXT NOT NULL,
            name TEXT NOT NULL CHECK (length(trim(name)) > 0),
            color_hex TEXT NOT NULL,
            presentation_approval TEXT NOT NULL CHECK (
                presentation_approval IN ('userApproved', 'pendingAIReview')
            )
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS trace_classification_event_labels (
            event_id TEXT NOT NULL
                REFERENCES trace_classification_snapshot_events(event_id) ON DELETE CASCADE,
            label_id TEXT NOT NULL,
            name TEXT NOT NULL CHECK (length(trim(name)) > 0),
            color_hex TEXT NOT NULL,
            PRIMARY KEY(event_id, label_id)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS trace_classification_snapshot_event_finalizations (
            event_id TEXT PRIMARY KEY NOT NULL
                REFERENCES trace_classification_snapshot_events(event_id),
            category_count INTEGER NOT NULL CHECK (category_count IN (0, 1)),
            label_count INTEGER NOT NULL CHECK (label_count >= 0)
        )
        """,
        """
        CREATE TRIGGER IF NOT EXISTS validate_trace_classification_event_finalization_insert
        BEFORE INSERT ON trace_classification_snapshot_event_finalizations
        WHEN NEW.category_count != (
            SELECT COUNT(*) FROM trace_classification_event_categories category
            WHERE category.event_id = NEW.event_id
        )
        OR NEW.label_count != (
            SELECT COUNT(*) FROM trace_classification_event_labels label
            WHERE label.event_id = NEW.event_id
        )
        BEGIN
            SELECT RAISE(ABORT, 'trace classification event finalization does not match its values');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_trace_classification_event_finalization_update
        BEFORE UPDATE ON trace_classification_snapshot_event_finalizations
        BEGIN
            SELECT RAISE(ABORT, 'trace classification event finalization is immutable');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_trace_classification_event_finalization_delete
        BEFORE DELETE ON trace_classification_snapshot_event_finalizations
        BEGIN
            SELECT RAISE(ABORT, 'trace classification event finalization is immutable');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_late_trace_classification_event_category_insert
        BEFORE INSERT ON trace_classification_event_categories
        WHEN EXISTS (
            SELECT 1 FROM trace_classification_snapshot_event_finalizations finalization
            WHERE finalization.event_id = NEW.event_id
        )
        BEGIN
            SELECT RAISE(ABORT, 'trace classification event is finalized');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_late_trace_classification_event_label_insert
        BEFORE INSERT ON trace_classification_event_labels
        WHEN EXISTS (
            SELECT 1 FROM trace_classification_snapshot_event_finalizations finalization
            WHERE finalization.event_id = NEW.event_id
        )
        BEGIN
            SELECT RAISE(ABORT, 'trace classification event is finalized');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_trace_classification_snapshot_event_update
        BEFORE UPDATE ON trace_classification_snapshot_events
        BEGIN
            SELECT RAISE(ABORT, 'trace classification snapshot events are immutable');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_trace_classification_snapshot_event_delete
        BEFORE DELETE ON trace_classification_snapshot_events
        BEGIN
            SELECT RAISE(ABORT, 'trace classification snapshot events are immutable');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_trace_classification_event_category_update
        BEFORE UPDATE ON trace_classification_event_categories
        BEGIN
            SELECT RAISE(ABORT, 'trace classification event categories are immutable');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_trace_classification_event_category_delete
        BEFORE DELETE ON trace_classification_event_categories
        BEGIN
            SELECT RAISE(ABORT, 'trace classification event categories are immutable');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_trace_classification_event_label_update
        BEFORE UPDATE ON trace_classification_event_labels
        BEGIN
            SELECT RAISE(ABORT, 'trace classification event labels are immutable');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_trace_classification_event_label_delete
        BEFORE DELETE ON trace_classification_event_labels
        BEGIN
            SELECT RAISE(ABORT, 'trace classification event labels are immutable');
        END
        """,
        """
        CREATE TABLE IF NOT EXISTS classification_deletion_tombstones (
            kind TEXT NOT NULL CHECK (kind IN ('category', 'label')),
            item_id TEXT NOT NULL,
            tombstone_id TEXT NOT NULL UNIQUE,
            deleted_at REAL NOT NULL,
            revision INTEGER NOT NULL CHECK (revision >= 0),
            change_record_id TEXT NOT NULL REFERENCES classification_change_records(record_id),
            PRIMARY KEY(kind, item_id)
        )
        """,
        """
        CREATE TRIGGER IF NOT EXISTS validate_classification_deletion_tombstone_insert
        BEFORE INSERT ON classification_deletion_tombstones
        WHEN EXISTS (
                SELECT 1 FROM classification_current_relation_facts relation
                WHERE relation.kind = NEW.kind AND relation.item_id = NEW.item_id
            )
            OR (
                NEW.kind = 'category'
                AND EXISTS (
                    SELECT 1 FROM task_chain_categories relation
                    WHERE relation.category_id = NEW.item_id
                )
            )
            OR (
                NEW.kind = 'label'
                AND EXISTS (
                    SELECT 1 FROM task_chain_label_relations relation
                    WHERE relation.label_id = NEW.item_id
                )
            )
            OR EXISTS (
                SELECT 1 FROM classification_relation_history history
                WHERE history.kind = NEW.kind AND history.item_id = NEW.item_id
            )
            OR EXISTS (
                SELECT 1 FROM classification_merges merge_fact
                WHERE merge_fact.kind = NEW.kind
                  AND (merge_fact.source_id = NEW.item_id OR merge_fact.target_id = NEW.item_id)
            )
            OR (
                NEW.kind = 'category'
                AND EXISTS (
                    SELECT 1 FROM trace_classification_event_categories event_value
                    WHERE event_value.category_id = NEW.item_id
                )
            )
            OR (
                NEW.kind = 'label'
                AND EXISTS (
                    SELECT 1 FROM trace_classification_event_labels event_value
                    WHERE event_value.label_id = NEW.item_id
                )
            )
        BEGIN
            SELECT RAISE(ABORT, 'classification identity still has references');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_deletion_tombstone_update
        BEFORE UPDATE ON classification_deletion_tombstones
        BEGIN
            SELECT RAISE(ABORT, 'classification deletion tombstones are append-only');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_deletion_tombstone_delete
        BEFORE DELETE ON classification_deletion_tombstones
        BEGIN
            SELECT RAISE(ABORT, 'classification deletion tombstones are append-only');
        END
        """,
        """
        DROP TRIGGER IF EXISTS prevent_classification_name_version_delete
        """,
        """
        CREATE TRIGGER prevent_classification_name_version_delete
        BEFORE DELETE ON classification_name_versions
        WHEN NOT EXISTS (
            SELECT 1
            FROM classification_deletion_tombstones tombstone
            WHERE tombstone.kind = OLD.kind AND tombstone.item_id = OLD.item_id
        )
        BEGIN
            SELECT RAISE(ABORT, 'classification name versions are append-only');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_deleted_task_category_recreation
        BEFORE INSERT ON task_categories
        WHEN EXISTS (
            SELECT 1 FROM classification_deletion_tombstones tombstone
            WHERE tombstone.kind = 'category' AND tombstone.item_id = NEW.id
        )
        BEGIN
            SELECT RAISE(ABORT, 'deleted task category identity cannot be recreated');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_deleted_task_label_recreation
        BEFORE INSERT ON task_labels
        WHEN EXISTS (
            SELECT 1 FROM classification_deletion_tombstones tombstone
            WHERE tombstone.kind = 'label' AND tombstone.item_id = NEW.id
        )
        BEGIN
            SELECT RAISE(ABORT, 'deleted task label identity cannot be recreated');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_deleted_classification_metadata_recreation
        BEFORE INSERT ON classification_item_metadata
        WHEN EXISTS (
            SELECT 1 FROM classification_deletion_tombstones tombstone
            WHERE tombstone.kind = NEW.kind AND tombstone.item_id = NEW.item_id
        )
        BEGIN
            SELECT RAISE(ABORT, 'deleted classification metadata cannot be recreated');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_deleted_classification_name_version_recreation
        BEFORE INSERT ON classification_name_versions
        WHEN EXISTS (
            SELECT 1 FROM classification_deletion_tombstones tombstone
            WHERE tombstone.kind = NEW.kind AND tombstone.item_id = NEW.item_id
        )
        BEGIN
            SELECT RAISE(ABORT, 'deleted classification name version cannot be recreated');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_item_exact_time_delete
        BEFORE DELETE ON classification_item_exact_times
        WHEN NOT EXISTS (
            SELECT 1 FROM classification_deletion_tombstones tombstone
            WHERE tombstone.kind = OLD.kind AND tombstone.item_id = OLD.item_id
        )
        BEGIN
            SELECT RAISE(ABORT, 'classification item exact time facts are immutable');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_classification_name_version_exact_time_delete
        BEFORE DELETE ON classification_name_version_exact_times
        WHEN NOT EXISTS (
            SELECT 1 FROM classification_deletion_tombstones tombstone
            WHERE tombstone.kind = OLD.kind AND tombstone.item_id = OLD.item_id
        )
        BEGIN
            SELECT RAISE(ABORT, 'classification name version exact time facts are immutable');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_deleted_classification_item_exact_time_recreation
        BEFORE INSERT ON classification_item_exact_times
        WHEN EXISTS (
            SELECT 1 FROM classification_deletion_tombstones tombstone
            WHERE tombstone.kind = NEW.kind AND tombstone.item_id = NEW.item_id
        )
        BEGIN
            SELECT RAISE(ABORT, 'deleted classification item exact time cannot be recreated');
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS prevent_deleted_classification_name_exact_time_recreation
        BEFORE INSERT ON classification_name_version_exact_times
        WHEN EXISTS (
            SELECT 1 FROM classification_deletion_tombstones tombstone
            WHERE tombstone.kind = NEW.kind AND tombstone.item_id = NEW.item_id
        )
        BEGIN
            SELECT RAISE(ABORT, 'deleted classification name exact time cannot be recreated');
        END
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
                    'deferred',
                    'abandoned',
                    'cancelledDraft'
                )
            ),
            difficulty INTEGER NOT NULL DEFAULT 1 CHECK (difficulty IN (1, 2, 3)),
            position INTEGER NOT NULL,
            carried_from_subtask_id TEXT REFERENCES subtasks(id),
            created_at TEXT NOT NULL,
            created_at_bits INTEGER NOT NULL CHECK (typeof(created_at_bits) = 'integer'),
            updated_at TEXT NOT NULL,
            updated_at_bits INTEGER NOT NULL CHECK (typeof(updated_at_bits) = 'integer'),
            completed_at TEXT,
            completed_at_bits INTEGER CHECK (
                completed_at_bits IS NULL OR typeof(completed_at_bits) = 'integer'
            ),
            settled_at TEXT,
            settled_at_bits INTEGER CHECK (
                settled_at_bits IS NULL OR typeof(settled_at_bits) = 'integer'
            ),
            draft_cancellation_id TEXT,
            CHECK ((completed_at IS NULL) = (completed_at_bits IS NULL)),
            CHECK ((settled_at IS NULL) = (settled_at_bits IS NULL)),
            CHECK (
                (
                    status = 'pending'
                    AND completed_at IS NULL
                    AND settled_at IS NULL
                )
                OR (
                    status = 'completed'
                    AND completed_at IS NOT NULL
                    AND settled_at IS NULL
                )
                OR (
                    status IN ('unfinished', 'deferred', 'abandoned')
                    AND completed_at IS NULL
                    AND settled_at IS NOT NULL
                )
                OR (
                    status = 'cancelledDraft'
                    AND completed_at IS NULL
                    AND settled_at IS NOT NULL
                    AND draft_cancellation_id IS NOT NULL
                )
            )
        )
        """,
        """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_unique_subtask_draft_cancellation_id
        ON subtasks(draft_cancellation_id)
        WHERE draft_cancellation_id IS NOT NULL
        """,
        """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_subtasks_trace_position
        ON subtasks(trace_id, position)
        """,
        """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_subtasks_trace_lineage
        ON subtasks(trace_id, lineage_id)
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
        CREATE TABLE IF NOT EXISTS sync_device_identity (
            id INTEGER PRIMARY KEY NOT NULL CHECK (id = 1),
            device_id TEXT NOT NULL CHECK (
                \(sqliteNonemptyInvariant("device_id"))
            ),
            display_name TEXT,
            created_at TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS sync_metadata (
            key TEXT PRIMARY KEY NOT NULL CHECK (
                \(sqliteNonemptyInvariant("key"))
            ),
            value BLOB,
            updated_at TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS change_journal (
            id TEXT PRIMARY KEY NOT NULL,
            entity_type TEXT NOT NULL CHECK (
                entity_type IN (
                    'day', 'taskCycleSeries', 'taskChain', 'taskDefinition',
                    'dayTrace', 'subtask', 'appPreferences',
                    'classificationCommit', 'traceClassificationEvent'
                )
            ),
            entity_id TEXT NOT NULL,
            operation TEXT NOT NULL CHECK (operation IN ('upsert', 'delete')),
            changed_at TEXT NOT NULL,
            changed_at_bits INTEGER NOT NULL CHECK (typeof(changed_at_bits) = 'integer'),
            device_id TEXT NOT NULL CHECK (
                \(sqliteNonemptyInvariant("device_id"))
            ),
            sync_state TEXT NOT NULL CHECK (sync_state IN ('pendingUpload', 'uploaded', 'failed')),
            retry_count INTEGER NOT NULL DEFAULT 0,
            last_error TEXT,
            record_payload BLOB,
            CHECK (
                (
                    entity_type IN (
                        'appPreferences',
                        'classificationCommit',
                        'traceClassificationEvent'
                    )
                    AND record_payload IS NOT NULL
                    AND length(record_payload) > 0
                )
                OR (
                    entity_type = 'taskChain'
                    AND (record_payload IS NULL OR length(record_payload) > 0)
                )
                OR (
                    entity_type NOT IN (
                        'appPreferences',
                        'classificationCommit',
                        'traceClassificationEvent',
                        'taskChain'
                    )
                    AND record_payload IS NULL
                )
            )
        )
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_change_journal_state_changed_at
        ON change_journal(sync_state, changed_at)
        """,
        """
        CREATE TABLE IF NOT EXISTS sync_pending_download_records (
            record_id TEXT PRIMARY KEY NOT NULL CHECK (length(record_id) > 0),
            generation_id TEXT NOT NULL UNIQUE CHECK (length(generation_id) = 36),
            entity_type TEXT NOT NULL CHECK (
                entity_type IN (
                    'day', 'taskCycleSeries', 'taskChain', 'taskDefinition',
                    'dayTrace', 'subtask', 'appPreferences',
                    'classificationCommit', 'traceClassificationEvent'
                )
            ),
            entity_id TEXT NOT NULL CHECK (length(entity_id) > 0),
            operation TEXT NOT NULL CHECK (operation = 'upsert'),
            modified_at_bits INTEGER NOT NULL CHECK (typeof(modified_at_bits) = 'integer'),
            modified_by_device_id TEXT NOT NULL CHECK (
                length(CAST(modified_by_device_id AS BLOB)) > 0
            ),
            payload BLOB NOT NULL CHECK (length(payload) > 0),
            reactivation_witnesses BLOB NOT NULL CHECK (
                length(reactivation_witnesses) > 0
            ),
            first_seen_at_bits INTEGER NOT NULL CHECK (typeof(first_seen_at_bits) = 'integer'),
            last_attempted_at_bits INTEGER NOT NULL CHECK (typeof(last_attempted_at_bits) = 'integer'),
            attempt_count INTEGER NOT NULL CHECK (
                typeof(attempt_count) = 'integer'
                AND attempt_count BETWEEN 1 AND 2147483647
            )
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS sync_pending_download_dependencies (
            record_id TEXT NOT NULL
                REFERENCES sync_pending_download_records(record_id)
                ON DELETE CASCADE,
            dependency_kind TEXT NOT NULL CHECK (
                dependency_kind IN (
                    'day', 'taskChain', 'dayTrace', 'taskDefinition', 'subtask',
                    'category', 'label',
                    'classificationEvent', 'classificationCommit',
                    'classificationRevision', 'currentSnapshotIntegrity'
                )
            ),
            dependency_id TEXT NOT NULL CHECK (length(dependency_id) > 0),
            PRIMARY KEY(record_id, dependency_kind, dependency_id)
        )
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_sync_pending_download_dependency
        ON sync_pending_download_dependencies(dependency_kind, dependency_id)
        """,
        """
        CREATE TABLE IF NOT EXISTS sync_conflicts (
            id TEXT PRIMARY KEY NOT NULL,
            conflict_type TEXT NOT NULL,
            entity_type TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            local_record_id TEXT CHECK (
                local_record_id IS NULL OR
                \(sqliteNonemptyInvariant("local_record_id"))
            ),
            remote_record_id TEXT NOT NULL CHECK (
                \(sqliteNonemptyInvariant("remote_record_id"))
            ),
            local_payload BLOB,
            remote_payload BLOB NOT NULL CHECK (length(remote_payload) > 0),
            detected_at TEXT NOT NULL,
            resolved_at TEXT,
            resolution TEXT NOT NULL DEFAULT 'unresolved',
            message TEXT
        )
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_sync_conflicts_unresolved
        ON sync_conflicts(resolution, detected_at)
        """,
        """
        CREATE TABLE IF NOT EXISTS sync_terminal_rejections (
            entity_type TEXT NOT NULL CHECK (
                entity_type IN ('classificationCommit', 'traceClassificationEvent')
            ),
            entity_id TEXT NOT NULL CHECK (length(entity_id) = 36),
            conflict_id TEXT NOT NULL UNIQUE
                REFERENCES sync_conflicts(id),
            PRIMARY KEY(entity_type, entity_id)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS sync_audit_log (
            id TEXT PRIMARY KEY NOT NULL,
            direction TEXT NOT NULL CHECK (direction IN ('upload', 'download', 'merge')),
            entity_type TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            source_evidence_id TEXT CHECK (
                source_evidence_id IS NULL OR (
                    length(source_evidence_id) = 64
                    AND source_evidence_id NOT GLOB '*[^0-9a-f]*'
                )
            ),
            canonical_evidence_id TEXT CHECK (
                canonical_evidence_id IS NULL OR (
                    length(canonical_evidence_id) = 64
                    AND canonical_evidence_id NOT GLOB '*[^0-9a-f]*'
                )
            ),
            action TEXT NOT NULL CHECK (
                \(sqliteNonemptyInvariant("action"))
            ),
            created_at TEXT NOT NULL,
            message TEXT
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS engine_snapshot_generation (
            id INTEGER PRIMARY KEY NOT NULL CHECK (id = 1),
            epoch TEXT NOT NULL CHECK (length(epoch) = 36),
            revision INTEGER NOT NULL CHECK (revision >= 0)
        )
        """,
        """
        INSERT OR IGNORE INTO engine_snapshot_generation(id, epoch, revision)
        VALUES (
            1,
            lower(
                hex(randomblob(4)) || '-' ||
                hex(randomblob(2)) || '-' ||
                hex(randomblob(2)) || '-' ||
                hex(randomblob(2)) || '-' ||
                hex(randomblob(6))
            ),
            0
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS app_preferences (
            id INTEGER PRIMARY KEY NOT NULL CHECK (id = 1),
            theme TEXT NOT NULL CHECK (theme IN ('coolGray', 'warmPaper')),
            language TEXT NOT NULL CHECK (language IN ('chinese', 'english')),
            theme_language_updated_at TEXT NOT NULL,
            theme_language_updated_at_bits INTEGER NOT NULL CHECK (
                typeof(theme_language_updated_at_bits) = 'integer'
            ),
            theme_language_writer_id TEXT NOT NULL CHECK (
                length(trim(theme_language_writer_id)) > 0
            )
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
            c.note_entries_json,
            c.created_at,
            c.updated_at
        FROM task_chains c
        JOIN task_definitions d ON d.chain_id = c.id AND d.superseded_at IS NULL
        WHERE c.state = 'active'
          AND NOT EXISTS (
              SELECT 1 FROM day_traces t
              WHERE t.chain_id = c.id
                AND t.status = 'pending'
          )
          AND (
              NOT EXISTS (
                  SELECT 1 FROM day_traces t
                  WHERE t.chain_id = c.id
              )
              OR EXISTS (
                  SELECT 1 FROM day_traces latest
                  WHERE latest.chain_id = c.id
                    AND latest.status IN ('returnedToPool', 'cancelledDraft')
                    AND NOT EXISTS (
                        SELECT 1 FROM day_traces newer
                        WHERE newer.chain_id = c.id
                          AND (
                              newer.content_updated_at > latest.content_updated_at
                              OR (
                                  newer.content_updated_at = latest.content_updated_at
                                  AND newer.created_at > latest.created_at
                              )
                              OR (
                                  newer.content_updated_at = latest.content_updated_at
                                  AND newer.created_at = latest.created_at
                                  AND newer.id > latest.id
                              )
                          )
                    )
              )
          )
        """,
        """
        CREATE VIEW IF NOT EXISTS future_plan_view AS
        SELECT
            t.*,
            d.title,
            d.description_text AS definition_description_text,
            c.note_entries_json AS chain_note_entries_json
        FROM day_traces t
        JOIN task_definitions d ON d.id = t.definition_id
        JOIN task_chains c ON c.id = t.chain_id
        WHERE t.status = 'pending'
        """,
        """
        CREATE VIEW IF NOT EXISTS unfinished_detail_view AS
        SELECT
            t.*,
            d.title,
            d.description_text AS definition_description_text,
            c.note_entries_json AS chain_note_entries_json
        FROM day_traces t
        JOIN task_definitions d ON d.id = t.definition_id
        JOIN task_chains c ON c.id = t.chain_id
        WHERE t.status IN ('unfinished', 'deferred', 'abandoned')
        """,
        """
        CREATE VIEW IF NOT EXISTS unfinished_pool_view AS
        SELECT
            c.id AS chain_id,
            d.id AS definition_id,
            d.title,
            d.description_text,
            c.note_entries_json,
            COUNT(u.id) AS unfinished_count,
            MAX(u.date) AS latest_unfinished_date,
            MAX(u.continuation_seq) AS max_continuation_seq,
            active.id AS active_trace_id,
            active.date AS active_trace_date
        FROM task_chains c
        JOIN task_definitions d ON d.chain_id = c.id AND d.superseded_at IS NULL
        JOIN day_traces u ON u.chain_id = c.id AND u.status IN ('unfinished', 'deferred', 'abandoned')
        LEFT JOIN day_traces active ON active.chain_id = c.id AND active.status = 'pending'
        WHERE c.state IN ('active', 'abandoned')
          AND NOT EXISTS (
              SELECT 1 FROM day_traces done
              WHERE done.chain_id = c.id AND done.status = 'completed'
          )
        GROUP BY c.id, d.id, d.title, d.description_text, c.note_entries_json, active.id, active.date
        """,
        """
        CREATE VIEW IF NOT EXISTS completed_pool_view AS
        SELECT
            t.*,
            d.title,
            d.description_text AS definition_description_text,
            c.note_entries_json AS chain_note_entries_json,
            first_trace.date AS trajectory_start_date,
            t.date AS trajectory_completed_date
        FROM day_traces t
        JOIN task_definitions d ON d.id = t.definition_id
        JOIN task_chains c ON c.id = t.chain_id
        JOIN day_traces first_trace ON first_trace.id = (
            SELECT first.id
            FROM day_traces first
            WHERE first.chain_id = t.chain_id
              AND first.status != 'cancelledDraft'
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
            history.carried_from_trace_id,
            history.changed_to_trace_id,
            history.created_at,
            history.completed_at,
            history.settled_at
        FROM day_traces done
        JOIN day_traces history
          ON history.chain_id = done.chain_id
         AND history.status != 'cancelledDraft'
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
            s.carried_from_subtask_id,
            s.created_at,
            s.completed_at,
            s.settled_at
        FROM day_traces done
        JOIN day_traces t
          ON t.chain_id = done.chain_id
         AND t.status != 'cancelledDraft'
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
            s.carried_from_subtask_id,
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
          AND t.status != 'cancelledDraft'
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
            '写入当前 Apple Account 的 iCloud Drive 同步仓库' AS description,
            'available' AS availability
        UNION ALL
        SELECT
            'localFolder' AS kind,
            '本地同步文件夹' AS title,
            '自管目录或局域网共享端点' AS description,
            'available' AS availability
        """,
        """
        CREATE VIEW IF NOT EXISTS day_todo_view AS
        SELECT
            t.*,
            d.title,
            d.description_text AS definition_description_text,
            c.note_entries_json AS chain_note_entries_json
        FROM day_traces t
        JOIN task_definitions d ON d.id = t.definition_id
        JOIN task_chains c ON c.id = t.chain_id
        WHERE t.status IN ('pending', 'completed', 'unfinished', 'deferred', 'abandoned')
        """
    ]
}

extension SQLiteSchema {
    static func installOrValidate(on database: OpaquePointer?) throws {
        try execute(statements[0], on: database)
        let storedVersion = try integerValue("PRAGMA user_version", on: database)
        if storedVersion == version {
            try validateCurrentSchema(on: database)
            return
        }

        let objectCount = try integerValue(
            """
            SELECT COUNT(*)
            FROM sqlite_master
            WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%'
            """,
            on: database
        )
        guard storedVersion == 0, objectCount == 0 else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "only an empty store or the current schema is supported"
            )
        }

        try execute("BEGIN IMMEDIATE TRANSACTION", on: database)
        do {
            for statement in statements.dropFirst() {
                try execute(statement, on: database)
            }
            try execute("PRAGMA user_version = \(version)", on: database)
            try execute("COMMIT", on: database)
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
        try validateCurrentSchema(on: database)
    }

    private static func validateCurrentSchema(on database: OpaquePointer?) throws {
        guard try schemaDefinitions(on: database) == expectedSchemaDefinitions() else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "current database schema fingerprint does not match"
            )
        }
        guard try stringValues("PRAGMA quick_check", on: database) == ["ok"] else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "current database failed SQLite quick_check"
            )
        }
        guard try hasRows("PRAGMA foreign_key_check", on: database) == false else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "current database has foreign key violations"
            )
        }
    }

    private static func expectedSchemaDefinitions() throws -> [String: String] {
        var database: OpaquePointer?
        guard sqlite3_open(":memory:", &database) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "unknown in-memory schema open error"
            sqlite3_close(database)
            throw SQLiteRepositoryError.openFailed(message)
        }
        defer { sqlite3_close(database) }
        for statement in statements {
            try execute(statement, on: database)
        }
        return try schemaDefinitions(on: database)
    }

    private static func schemaDefinitions(
        on database: OpaquePointer?
    ) throws -> [String: String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            """
            SELECT type, name, sql
            FROM sqlite_master
            WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%'
            ORDER BY type, name
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw SQLiteRepositoryError.prepareFailed(lastError(database))
        }
        defer { sqlite3_finalize(statement) }

        var definitions: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let type = try text(statement, column: 0)
            let name = try text(statement, column: 1)
            let sql = try text(statement, column: 2)
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
                .lowercased()
            definitions["\(type):\(name)"] = sql
        }
        guard sqlite3_errcode(database) == SQLITE_OK
            || sqlite3_errcode(database) == SQLITE_DONE
        else {
            throw SQLiteRepositoryError.stepFailed(lastError(database))
        }
        return definitions
    }

    private static func integerValue(
        _ sql: String,
        on database: OpaquePointer?
    ) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteRepositoryError.prepareFailed(lastError(database))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteRepositoryError.stepFailed(lastError(database))
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func stringValues(
        _ sql: String,
        on database: OpaquePointer?
    ) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteRepositoryError.prepareFailed(lastError(database))
        }
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            values.append(try text(statement, column: 0))
        }
        return values
    }

    private static func hasRows(
        _ sql: String,
        on database: OpaquePointer?
    ) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteRepositoryError.prepareFailed(lastError(database))
        }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else {
            throw SQLiteRepositoryError.stepFailed(lastError(database))
        }
        return result == SQLITE_ROW
    }

    private static func execute(
        _ sql: String,
        on database: OpaquePointer?
    ) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteRepositoryError.executeFailed(lastError(database))
        }
    }

    private static func text(
        _ statement: OpaquePointer?,
        column: Int32
    ) throws -> String {
        guard let value = sqlite3_column_text(statement, column) else {
            throw SQLiteRepositoryError.invalidStoredValue("SQLite text value is null")
        }
        return String(cString: value)
    }

    private static func lastError(_ database: OpaquePointer?) -> String {
        database.map { String(cString: sqlite3_errmsg($0)) }
            ?? "unknown SQLite error"
    }
}
