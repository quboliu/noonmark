package store

const schemaVersion = 1

const schemaSQL = `
CREATE TABLE instance_state (
 id INTEGER PRIMARY KEY CHECK(id=1),
 instance_id TEXT NOT NULL UNIQUE, instance_epoch TEXT NOT NULL,
 dataset_id TEXT NOT NULL UNIQUE, owner_id TEXT NOT NULL,
 timezone TEXT NOT NULL, sequence INTEGER NOT NULL CHECK(sequence>=0), frontier_bits TEXT NOT NULL
);
CREATE TABLE owners(id TEXT PRIMARY KEY, password_hash TEXT NOT NULL);
CREATE TABLE sessions(token_hash TEXT PRIMARY KEY, owner_id TEXT NOT NULL REFERENCES owners(id), expires_at INTEGER NOT NULL, created_at INTEGER NOT NULL);
CREATE INDEX sessions_expiry ON sessions(expires_at);
CREATE TABLE days(
 dataset_id TEXT NOT NULL REFERENCES instance_state(dataset_id), date TEXT NOT NULL,
 revision TEXT NOT NULL, locked_at TEXT NOT NULL, summary TEXT NOT NULL, unfinished_reason TEXT NOT NULL, tomorrow_note TEXT NOT NULL,
 created_at TEXT NOT NULL, updated_at TEXT NOT NULL, mutation_bits TEXT NOT NULL,
 PRIMARY KEY(dataset_id,date)
);
CREATE TABLE chains(
 dataset_id TEXT NOT NULL REFERENCES instance_state(dataset_id), id TEXT NOT NULL, definition_id TEXT NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('active','abandoned')), location TEXT NOT NULL CHECK(location IN ('pool','trace','followup','completed','abandoned')),
 revision TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, mutation_bits TEXT NOT NULL,
 PRIMARY KEY(dataset_id,id), FOREIGN KEY(dataset_id,definition_id) REFERENCES definitions(dataset_id,id) DEFERRABLE INITIALLY DEFERRED
);
CREATE TABLE definitions(
 dataset_id TEXT NOT NULL, id TEXT NOT NULL, chain_id TEXT NOT NULL, version INTEGER NOT NULL CHECK(version>0),
 title TEXT NOT NULL, description TEXT NOT NULL, planned_subtasks TEXT NOT NULL CHECK(json_valid(planned_subtasks)),
 created_at TEXT NOT NULL, updated_at TEXT NOT NULL, mutation_bits TEXT NOT NULL,
 PRIMARY KEY(dataset_id,id), UNIQUE(dataset_id,chain_id,version),
 FOREIGN KEY(dataset_id,chain_id) REFERENCES chains(dataset_id,id) DEFERRABLE INITIALLY DEFERRED
);
CREATE TABLE traces(
 dataset_id TEXT NOT NULL, id TEXT NOT NULL, chain_id TEXT NOT NULL, definition_id TEXT NOT NULL, date TEXT NOT NULL,
 status TEXT NOT NULL CHECK(status IN ('pending','completed','unfinished','deferred','returnedToPool','cancelledDraft','abandoned')),
 priority INTEGER NOT NULL CHECK(priority>0), continuation_seq INTEGER NOT NULL CHECK(continuation_seq>=0),
 description TEXT NOT NULL, carried_from_trace_id TEXT, progress_floor INTEGER NOT NULL CHECK(progress_floor BETWEEN 0 AND 100), manual_progress INTEGER NOT NULL CHECK(manual_progress BETWEEN 0 AND 100),
 completed_at TEXT NOT NULL, settled_at TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, mutation_bits TEXT NOT NULL,
 PRIMARY KEY(dataset_id,id),
 FOREIGN KEY(dataset_id,chain_id) REFERENCES chains(dataset_id,id),
 FOREIGN KEY(dataset_id,definition_id) REFERENCES definitions(dataset_id,id),
 FOREIGN KEY(dataset_id,date) REFERENCES days(dataset_id,date),
 FOREIGN KEY(dataset_id,carried_from_trace_id) REFERENCES traces(dataset_id,id) DEFERRABLE INITIALLY DEFERRED,
 UNIQUE(dataset_id,carried_from_trace_id)
);
CREATE UNIQUE INDEX one_active_trace ON traces(dataset_id,chain_id) WHERE status='pending';
CREATE INDEX traces_by_date ON traces(dataset_id,date,priority);
CREATE TABLE subtasks(
 dataset_id TEXT NOT NULL, id TEXT NOT NULL, trace_id TEXT NOT NULL, lineage_id TEXT NOT NULL, carried_from_subtask_id TEXT,
 title TEXT NOT NULL, difficulty TEXT NOT NULL CHECK(difficulty IN ('simple','medium','hard')),
 status TEXT NOT NULL CHECK(status IN ('pending','completed','unfinished','deferred','abandoned','cancelledDraft')),
 position INTEGER NOT NULL CHECK(position>0), completed_at TEXT NOT NULL, settled_at TEXT NOT NULL,
 created_at TEXT NOT NULL, updated_at TEXT NOT NULL, mutation_bits TEXT NOT NULL,
 PRIMARY KEY(dataset_id,id), FOREIGN KEY(dataset_id,trace_id) REFERENCES traces(dataset_id,id),
 FOREIGN KEY(dataset_id,carried_from_subtask_id) REFERENCES subtasks(dataset_id,id) DEFERRABLE INITIALLY DEFERRED,
 UNIQUE(dataset_id,trace_id,lineage_id)
);
CREATE TABLE ideas(
 dataset_id TEXT NOT NULL REFERENCES instance_state(dataset_id), id TEXT NOT NULL, revision TEXT NOT NULL, body TEXT NOT NULL,
 pinned_at TEXT NOT NULL, deleted_at TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, mutation_bits TEXT NOT NULL,
 PRIMARY KEY(dataset_id,id), CHECK(deleted_at='' OR (body='' AND pinned_at=''))
);
CREATE TABLE command_receipts(
 dataset_id TEXT NOT NULL REFERENCES instance_state(dataset_id), command_id TEXT NOT NULL, request_hash TEXT NOT NULL,
 sequence INTEGER NOT NULL, entity_id TEXT NOT NULL, mutation_bits TEXT NOT NULL,
 PRIMARY KEY(dataset_id,command_id)
);
CREATE TABLE change_batches(
 dataset_id TEXT NOT NULL REFERENCES instance_state(dataset_id), sequence INTEGER NOT NULL, command_id TEXT NOT NULL, kind TEXT NOT NULL,
 mutation_bits TEXT NOT NULL, PRIMARY KEY(dataset_id,sequence)
);
CREATE TRIGGER receipts_no_update BEFORE UPDATE ON command_receipts BEGIN SELECT RAISE(ABORT,'immutable_receipt'); END;
CREATE TRIGGER receipts_no_delete BEFORE DELETE ON command_receipts BEGIN SELECT RAISE(ABORT,'immutable_receipt'); END;
CREATE TRIGGER changes_no_update BEFORE UPDATE ON change_batches BEGIN SELECT RAISE(ABORT,'immutable_batch'); END;
CREATE TRIGGER changes_no_delete BEFORE DELETE ON change_batches BEGIN SELECT RAISE(ABORT,'immutable_batch'); END;
CREATE TRIGGER historical_definition BEFORE UPDATE ON definitions
 WHEN EXISTS(SELECT 1 FROM traces WHERE dataset_id=OLD.dataset_id AND definition_id=OLD.id AND status NOT IN ('pending','cancelledDraft'))
 BEGIN SELECT RAISE(ABORT,'immutable_definition'); END;
CREATE TRIGGER historical_trace BEFORE UPDATE ON traces
 WHEN EXISTS(SELECT 1 FROM days WHERE dataset_id=OLD.dataset_id AND date=OLD.date AND locked_at!='')
 AND NOT (
  OLD.status IN ('unfinished','abandoned') AND NEW.status IN ('unfinished','abandoned')
  AND NEW.id=OLD.id AND NEW.dataset_id=OLD.dataset_id AND NEW.chain_id=OLD.chain_id AND NEW.definition_id=OLD.definition_id
  AND NEW.date=OLD.date AND NEW.priority=OLD.priority AND NEW.continuation_seq=OLD.continuation_seq
  AND NEW.description=OLD.description AND NEW.carried_from_trace_id IS OLD.carried_from_trace_id
  AND NEW.progress_floor=OLD.progress_floor AND NEW.manual_progress=OLD.manual_progress AND NEW.completed_at=OLD.completed_at AND NEW.created_at=OLD.created_at
 ) BEGIN SELECT RAISE(ABORT,'immutable_trace'); END;
CREATE TRIGGER historical_subtask BEFORE UPDATE ON subtasks
 WHEN EXISTS(SELECT 1 FROM traces t JOIN days d ON d.dataset_id=t.dataset_id AND d.date=t.date WHERE t.dataset_id=OLD.dataset_id AND t.id=OLD.trace_id AND d.locked_at!='')
 BEGIN SELECT RAISE(ABORT,'immutable_subtask'); END;
CREATE TRIGGER day_cannot_unlock BEFORE UPDATE ON days WHEN OLD.locked_at!='' AND NEW.locked_at!=OLD.locked_at BEGIN SELECT RAISE(ABORT,'immutable_day_lock'); END;
CREATE TRIGGER idea_cannot_resurrect BEFORE UPDATE ON ideas WHEN OLD.deleted_at!='' BEGIN SELECT RAISE(ABORT,'immutable_tombstone'); END;
CREATE TRIGGER chains_no_delete BEFORE DELETE ON chains BEGIN SELECT RAISE(ABORT,'append_only'); END;
CREATE TRIGGER definitions_no_delete BEFORE DELETE ON definitions BEGIN SELECT RAISE(ABORT,'append_only'); END;
CREATE TRIGGER traces_no_delete BEFORE DELETE ON traces BEGIN SELECT RAISE(ABORT,'append_only'); END;
CREATE TRIGGER subtasks_no_delete BEFORE DELETE ON subtasks BEGIN SELECT RAISE(ABORT,'append_only'); END;
CREATE TRIGGER ideas_no_delete BEFORE DELETE ON ideas BEGIN SELECT RAISE(ABORT,'append_only'); END;
CREATE TRIGGER days_no_delete BEFORE DELETE ON days BEGIN SELECT RAISE(ABORT,'append_only'); END;
PRAGMA user_version=1;
`
