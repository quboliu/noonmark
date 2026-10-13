package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"reflect"
	"strconv"
	"time"

	"github.com/quboliu/noonmark/services/noonmark/internal/core"
)

func rows(ctx context.Context, tx *sql.Tx, q string, dataset string, scan func(*sql.Rows) error) error {
	r, err := tx.QueryContext(ctx, q, dataset)
	if err != nil {
		return storageError(err)
	}
	defer r.Close()
	for r.Next() {
		if err = scan(r); err != nil {
			return storageError(err)
		}
	}
	return storageError(r.Err())
}

func (s *Store) read(ctx context.Context, tx *sql.Tx) (core.Snapshot, error) {
	out := core.Snapshot{SchemaVersion: 1, Chains: []core.Chain{}, Definitions: []core.Definition{}, Traces: []core.Trace{}, Subtasks: []core.Subtask{}, Days: []core.Day{}, Ideas: []core.Idea{}}
	var seq int64
	if err := tx.QueryRowContext(ctx, "SELECT instance_id,instance_epoch,dataset_id,owner_id,timezone,sequence,frontier_bits FROM instance_state WHERE id=1").Scan(&out.InstanceID, &out.InstanceEpoch, &out.DatasetID, &out.OwnerID, &out.Timezone, &seq, &out.FrontierBits); err != nil {
		return out, storageError(err)
	}
	out.Sequence = strconv.FormatInt(seq, 10)
	location, err := time.LoadLocation(out.Timezone)
	if err != nil {
		return out, core.Fail("INVALID_TIMEZONE")
	}
	out.Today = s.now().In(location).Format("2006-01-02")
	if err = rows(ctx, tx, "SELECT id,definition_id,state,location,revision,created_at,updated_at,mutation_bits FROM chains WHERE dataset_id=?", out.DatasetID, func(r *sql.Rows) error {
		var v core.Chain
		err := r.Scan(&v.ID, &v.DefinitionID, &v.State, &v.Location, &v.Revision, &v.CreatedAt, &v.UpdatedAt, &v.MutationBits)
		out.Chains = append(out.Chains, v)
		return err
	}); err != nil {
		return out, err
	}
	if err = rows(ctx, tx, "SELECT id,chain_id,version,title,description,planned_subtasks,created_at,updated_at,mutation_bits FROM definitions WHERE dataset_id=?", out.DatasetID, func(r *sql.Rows) error {
		var v core.Definition
		var planned string
		err := r.Scan(&v.ID, &v.ChainID, &v.Version, &v.Title, &v.Description, &planned, &v.CreatedAt, &v.UpdatedAt, &v.MutationBits)
		if err != nil {
			return err
		}
		if err = json.Unmarshal([]byte(planned), &v.PlannedSubtasks); err != nil {
			return core.Fail("INVARIANT_VIOLATION")
		}
		out.Definitions = append(out.Definitions, v)
		return nil
	}); err != nil {
		return out, err
	}
	if err = rows(ctx, tx, "SELECT id,chain_id,definition_id,date,status,priority,continuation_seq,description,COALESCE(carried_from_trace_id,''),progress_floor,manual_progress,completed_at,settled_at,created_at,updated_at,mutation_bits FROM traces WHERE dataset_id=?", out.DatasetID, func(r *sql.Rows) error {
		var v core.Trace
		err := r.Scan(&v.ID, &v.ChainID, &v.DefinitionID, &v.Date, &v.Status, &v.Priority, &v.ContinuationSeq, &v.Description, &v.CarriedFromTraceID, &v.ProgressFloor, &v.ManualProgress, &v.CompletedAt, &v.SettledAt, &v.CreatedAt, &v.UpdatedAt, &v.MutationBits)
		out.Traces = append(out.Traces, v)
		return err
	}); err != nil {
		return out, err
	}
	if err = rows(ctx, tx, "SELECT id,trace_id,lineage_id,COALESCE(carried_from_subtask_id,''),title,difficulty,status,position,completed_at,settled_at,created_at,updated_at,mutation_bits FROM subtasks WHERE dataset_id=?", out.DatasetID, func(r *sql.Rows) error {
		var v core.Subtask
		err := r.Scan(&v.ID, &v.TraceID, &v.LineageID, &v.CarriedFromSubtaskID, &v.Title, &v.Difficulty, &v.Status, &v.Position, &v.CompletedAt, &v.SettledAt, &v.CreatedAt, &v.UpdatedAt, &v.MutationBits)
		out.Subtasks = append(out.Subtasks, v)
		return err
	}); err != nil {
		return out, err
	}
	if err = rows(ctx, tx, "SELECT date,revision,locked_at,summary,unfinished_reason,tomorrow_note,created_at,updated_at,mutation_bits FROM days WHERE dataset_id=?", out.DatasetID, func(r *sql.Rows) error {
		var v core.Day
		err := r.Scan(&v.Date, &v.Revision, &v.LockedAt, &v.Summary, &v.UnfinishedReason, &v.TomorrowNote, &v.CreatedAt, &v.UpdatedAt, &v.MutationBits)
		out.Days = append(out.Days, v)
		return err
	}); err != nil {
		return out, err
	}
	if err = rows(ctx, tx, "SELECT id,revision,body,pinned_at,deleted_at,created_at,updated_at,mutation_bits FROM ideas WHERE dataset_id=?", out.DatasetID, func(r *sql.Rows) error {
		var v core.Idea
		err := r.Scan(&v.ID, &v.Revision, &v.Body, &v.PinnedAt, &v.DeletedAt, &v.CreatedAt, &v.UpdatedAt, &v.MutationBits)
		out.Ideas = append(out.Ideas, v)
		return err
	}); err != nil {
		return out, err
	}
	return out, core.Validate(out)
}
func nullable(s string) any {
	if s == "" {
		return nil
	}
	return s
}
func indexed[T any](vs []T, id func(T) string) map[string]T {
	out := make(map[string]T, len(vs))
	for _, v := range vs {
		out[id(v)] = v
	}
	return out
}
func changed[T any](prior map[string]T, id string, v T) bool {
	old, ok := prior[id]
	return !ok || !reflect.DeepEqual(old, v)
}

func (s *Store) persist(ctx context.Context, tx *sql.Tx, before, after core.Snapshot) error {
	ds := after.DatasetID
	exec := func(q string, args ...any) error { _, err := tx.ExecContext(ctx, q, args...); return storageError(err) }
	days := indexed(before.Days, func(v core.Day) string { return v.Date })
	chains := indexed(before.Chains, func(v core.Chain) string { return v.ID })
	defs := indexed(before.Definitions, func(v core.Definition) string { return v.ID })
	traces := indexed(before.Traces, func(v core.Trace) string { return v.ID })
	subs := indexed(before.Subtasks, func(v core.Subtask) string { return v.ID })
	ideas := indexed(before.Ideas, func(v core.Idea) string { return v.ID })
	// 新 Day 先插入，既有 Day 的锁定在 trace/subtask 完成结算后写入。
	for _, d := range after.Days {
		if _, ok := days[d.Date]; !ok {
			if err := exec("INSERT INTO days VALUES(?,?,?,?,?,?,?,?,?,?)", ds, d.Date, d.Revision, "", d.Summary, d.UnfinishedReason, d.TomorrowNote, d.CreatedAt, d.UpdatedAt, d.MutationBits); err != nil {
				return err
			}
		}
	}
	for _, d := range after.Definitions {
		if !changed(defs, d.ID, d) {
			continue
		}
		planned, err := json.Marshal(d.PlannedSubtasks)
		if err != nil {
			return core.Fail("INVALID_INPUT")
		}
		if err = exec(`INSERT INTO definitions VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(dataset_id,id) DO UPDATE SET title=excluded.title,description=excluded.description,planned_subtasks=excluded.planned_subtasks,updated_at=excluded.updated_at,mutation_bits=excluded.mutation_bits`, ds, d.ID, d.ChainID, d.Version, d.Title, d.Description, string(planned), d.CreatedAt, d.UpdatedAt, d.MutationBits); err != nil {
			return err
		}
	}
	for _, c := range after.Chains {
		if !changed(chains, c.ID, c) {
			continue
		}
		if err := exec(`INSERT INTO chains VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(dataset_id,id) DO UPDATE SET definition_id=excluded.definition_id,state=excluded.state,location=excluded.location,revision=excluded.revision,updated_at=excluded.updated_at,mutation_bits=excluded.mutation_bits`, ds, c.ID, c.DefinitionID, c.State, c.Location, c.Revision, c.CreatedAt, c.UpdatedAt, c.MutationBits); err != nil {
			return err
		}
	}
	// 先终结已有 pending 轨迹，再插入其继任者，满足唯一活跃轨迹约束。
	writeTrace := func(t core.Trace) error {
		return exec(`INSERT INTO traces VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(dataset_id,id) DO UPDATE SET definition_id=excluded.definition_id,date=excluded.date,status=excluded.status,priority=excluded.priority,description=excluded.description,progress_floor=excluded.progress_floor,manual_progress=excluded.manual_progress,completed_at=excluded.completed_at,settled_at=excluded.settled_at,updated_at=excluded.updated_at,mutation_bits=excluded.mutation_bits`, ds, t.ID, t.ChainID, t.DefinitionID, t.Date, t.Status, t.Priority, t.ContinuationSeq, t.Description, nullable(t.CarriedFromTraceID), t.ProgressFloor, t.ManualProgress, t.CompletedAt, t.SettledAt, t.CreatedAt, t.UpdatedAt, t.MutationBits)
	}
	for _, t := range after.Traces {
		old, exists := traces[t.ID]
		if !exists {
			continue
		}
		old.Progress = 0
		t.Progress = 0
		if !reflect.DeepEqual(old, t) {
			if err := writeTrace(t); err != nil {
				return err
			}
		}
	}
	for _, t := range after.Traces {
		if _, exists := traces[t.ID]; !exists {
			if err := writeTrace(t); err != nil {
				return err
			}
		}
	}
	for _, sub := range after.Subtasks {
		if !changed(subs, sub.ID, sub) {
			continue
		}
		if err := exec(`INSERT INTO subtasks VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(dataset_id,id) DO UPDATE SET title=excluded.title,difficulty=excluded.difficulty,status=excluded.status,completed_at=excluded.completed_at,settled_at=excluded.settled_at,updated_at=excluded.updated_at,mutation_bits=excluded.mutation_bits`, ds, sub.ID, sub.TraceID, sub.LineageID, nullable(sub.CarriedFromSubtaskID), sub.Title, sub.Difficulty, sub.Status, sub.Position, sub.CompletedAt, sub.SettledAt, sub.CreatedAt, sub.UpdatedAt, sub.MutationBits); err != nil {
			return err
		}
	}
	for _, d := range after.Days {
		if !changed(days, d.Date, d) {
			continue
		}
		if err := exec(`UPDATE days SET revision=?,locked_at=?,summary=?,unfinished_reason=?,tomorrow_note=?,updated_at=?,mutation_bits=? WHERE dataset_id=? AND date=?`, d.Revision, d.LockedAt, d.Summary, d.UnfinishedReason, d.TomorrowNote, d.UpdatedAt, d.MutationBits, ds, d.Date); err != nil {
			return err
		}
	}
	for _, v := range after.Ideas {
		if !changed(ideas, v.ID, v) {
			continue
		}
		if err := exec(`INSERT INTO ideas VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(dataset_id,id) DO UPDATE SET revision=excluded.revision,body=excluded.body,pinned_at=excluded.pinned_at,deleted_at=excluded.deleted_at,updated_at=excluded.updated_at,mutation_bits=excluded.mutation_bits`, ds, v.ID, v.Revision, v.Body, v.PinnedAt, v.DeletedAt, v.CreatedAt, v.UpdatedAt, v.MutationBits); err != nil {
			return err
		}
	}
	return nil
}
