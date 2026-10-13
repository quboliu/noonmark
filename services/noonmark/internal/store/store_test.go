package store

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/quboliu/noonmark/services/noonmark/internal/core"
)

func testStore(t *testing.T) (*Store, *time.Time) {
	t.Helper()
	now := time.Date(2026, 10, 12, 8, 0, 0, 0, time.UTC)
	s, err := initAt(context.Background(), filepath.Join(t.TempDir(), "instance"), "Asia/Singapore", now.Add(-time.Second))
	if err != nil {
		t.Fatal(err)
	}
	s.now = func() time.Time { return now }
	t.Cleanup(func() { s.Close() })
	return s, &now
}
func snap(t *testing.T, s *Store) core.Snapshot {
	t.Helper()
	v, err := s.Snapshot(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	return v
}
func command(v core.Snapshot, kind string, p core.Payload) core.Command {
	revision := "0"
	chain := p.ChainID
	if p.SubtaskID != "" {
		for _, sub := range v.Subtasks {
			if sub.ID == p.SubtaskID {
				p.TraceID = sub.TraceID
			}
		}
	}
	if p.TraceID != "" {
		for _, tr := range v.Traces {
			if tr.ID == p.TraceID {
				chain = tr.ChainID
			}
		}
	}
	for _, c := range v.Chains {
		if c.ID == chain {
			revision = c.Revision
		}
	}
	for _, i := range v.Ideas {
		if i.ID == p.IdeaID {
			revision = i.Revision
		}
	}
	if kind == "UpdateReview" {
		for _, d := range v.Days {
			if d.Date == p.Date {
				revision = d.Revision
			}
		}
	}
	return core.Command{InstanceID: v.InstanceID, InstanceEpoch: v.InstanceEpoch, DatasetID: v.DatasetID, CommandID: uuid(), SchemaVersion: 1, Type: kind, ExpectedRevision: revision, Payload: p}
}
func run(t *testing.T, s *Store, kind string, p core.Payload) core.Receipt {
	t.Helper()
	r, err := s.Execute(context.Background(), command(snap(t, s), kind, p))
	if err != nil {
		t.Fatalf("%s: %v", kind, err)
	}
	return r
}
func code(t *testing.T, err error, want string) {
	t.Helper()
	if core.ErrorCode(err) != want {
		t.Fatalf("got %v, want %s", err, want)
	}
}

func TestIdempotencyConcurrencyAndRestart(t *testing.T) {
	s, now := testStore(t)
	v := snap(t, s)
	c := command(v, "CreateTask", core.Payload{Title: "并发捕获", Date: v.Today})
	const n = 16
	receipts := make(chan core.Receipt, n)
	errs := make(chan error, n)
	var wg sync.WaitGroup
	for range n {
		wg.Add(1)
		go func() { defer wg.Done(); r, err := s.Execute(context.Background(), c); receipts <- r; errs <- err }()
	}
	wg.Wait()
	close(receipts)
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	var entity string
	for r := range receipts {
		if entity != "" && entity != r.EntityID {
			t.Fatal("duplicate command created different identities")
		}
		entity = r.EntityID
	}
	v = snap(t, s)
	if len(v.Chains) != 1 || len(v.Traces) != 1 || v.Sequence != "1" {
		t.Fatalf("wrong counts/sequence: %d %d %s", len(v.Chains), len(v.Traces), v.Sequence)
	}
	c.Payload.Title = "不同意图"
	_, err := s.Execute(context.Background(), c)
	code(t, err, "IDEMPOTENCY_MISMATCH")
	c.Payload.Title = "并发捕获"
	path := s.root
	if err = s.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := Open(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	reopened.now = func() time.Time { return *now }
	r, err := reopened.Execute(context.Background(), c)
	if err != nil || r.EntityID != entity {
		t.Fatalf("restart receipt lost: %v", err)
	}
}

func TestOptimisticConcurrencyAndTransactionRollback(t *testing.T) {
	s, _ := testStore(t)
	r := run(t, s, "CreateTask", core.Payload{Title: "原始"})
	v := snap(t, s)
	a := command(v, "EditTask", core.Payload{ChainID: r.EntityID, Title: "先提交"})
	b := command(v, "EditTask", core.Payload{ChainID: r.EntityID, Title: "迟到"})
	if _, err := s.Execute(context.Background(), a); err != nil {
		t.Fatal(err)
	}
	_, err := s.Execute(context.Background(), b)
	code(t, err, "VERSION_CONFLICT")
	v = snap(t, s)
	if _, err = s.db.Exec(`CREATE TRIGGER fault_before_receipt BEFORE INSERT ON command_receipts BEGIN SELECT RAISE(ABORT,'test failure'); END`); err != nil {
		t.Fatal(err)
	}
	_, err = s.Execute(context.Background(), command(v, "CreateIdea", core.Payload{Body: "不会半提交"}))
	if err == nil {
		t.Fatal("injected transaction failure accepted")
	}
	after := snap(t, s)
	if after.Sequence != v.Sequence || len(after.Ideas) != 0 || after.FrontierBits != v.FrontierBits {
		t.Fatal("failed transaction published facts or frontier")
	}
	if _, err = s.db.Exec("DROP TRIGGER fault_before_receipt"); err != nil {
		t.Fatal(err)
	}
	if err = s.Doctor(context.Background()); err != nil {
		t.Fatal(err)
	}
}

func TestDaySettlementContinuationAndImmutableHistory(t *testing.T) {
	s, now := testStore(t)
	v := snap(t, s)
	r := run(t, s, "CreateTask", core.Payload{Title: "连续任务", Date: v.Today})
	v = snap(t, s)
	source := v.Traces[0]
	run(t, s, "AddSubtask", core.Payload{TraceID: source.ID, Title: "第一步", Difficulty: "simple"})
	run(t, s, "AddSubtask", core.Payload{TraceID: source.ID, Title: "第二步", Difficulty: "hard"})
	v = snap(t, s)
	run(t, s, "CompleteSubtask", core.Payload{SubtaskID: v.Subtasks[0].ID})
	v = snap(t, s)
	_, err := s.Execute(context.Background(), command(v, "CompleteTrace", core.Payload{TraceID: source.ID}))
	code(t, err, "OPEN_SUBTASKS")
	*now = now.Add(24 * time.Hour)
	v = snap(t, s)
	if v.Traces[0].Status != "unfinished" || v.Days[0].LockedAt == "" || v.Chains[0].Location != "followup" {
		t.Fatal("day did not settle")
	}
	historyDefinition := v.Traces[0].DefinitionID
	next := run(t, s, "ContinueTrace", core.Payload{TraceID: source.ID, Date: v.Today})
	v = snap(t, s)
	if len(v.Subtasks) != 3 || len(v.Traces) != 2 {
		t.Fatal("continuation copied completed subtask or lost history")
	}
	var target core.Trace
	for _, tr := range v.Traces {
		if tr.ID == next.EntityID {
			target = tr
		}
	}
	if target.ContinuationSeq != 1 || target.Progress < 25 || target.CarriedFromTraceID != source.ID {
		t.Fatal("continuation lost frontier/progress")
	}
	run(t, s, "EditTask", core.Payload{ChainID: r.EntityID, Title: "今天修改", Description: "新说明"})
	v = snap(t, s)
	if v.Traces[0].DefinitionID != historyDefinition || len(v.Definitions) != 2 {
		t.Fatal("historical definition overwritten")
	}
	for _, sub := range v.Subtasks {
		if sub.TraceID == target.ID {
			run(t, s, "CompleteSubtask", core.Payload{SubtaskID: sub.ID})
		}
	}
	run(t, s, "CompleteTrace", core.Payload{TraceID: target.ID})
	*now = now.Add(24 * time.Hour)
	v = snap(t, s)
	_, err = s.Execute(context.Background(), command(v, "UndoCompleteTrace", core.Payload{TraceID: target.ID}))
	code(t, err, "DAY_LOCKED")
	if _, err = s.db.Exec("UPDATE traces SET description='forbidden' WHERE id=?", source.ID); err == nil {
		t.Fatal("SQL bypass rewrote locked history")
	}
	if _, err = s.db.Exec("UPDATE definitions SET title='forbidden' WHERE id=?", historyDefinition); err == nil {
		t.Fatal("SQL bypass rewrote historical definition")
	}
	run(t, s, "UpdateReview", core.Payload{Date: source.Date, Summary: "历史复盘可补写"})
	if err = s.Doctor(context.Background()); err != nil {
		t.Fatal(err)
	}
}

func TestDeferralReturnPoolAndReactivation(t *testing.T) {
	s, now := testStore(t)
	v := snap(t, s)
	r := run(t, s, "CreateTask", core.Payload{Title: "安排", Date: v.Today})
	v = snap(t, s)
	source := v.Traces[0]
	run(t, s, "AddSubtask", core.Payload{TraceID: source.ID, Title: "保留轨迹线", Difficulty: "medium"})
	targetDate := now.Add(24 * time.Hour).In(time.FixedZone("SGT", 8*3600)).Format("2006-01-02")
	target := run(t, s, "DeferTrace", core.Payload{TraceID: source.ID, Date: targetDate})
	v = snap(t, s)
	if v.Traces[0].Status != "deferred" || v.Traces[1].ContinuationSeq != 0 {
		t.Fatal("deferral was incorrectly counted as continuation")
	}
	run(t, s, "ReturnToPool", core.Payload{TraceID: target.EntityID})
	v = snap(t, s)
	if v.Chains[0].Location != "pool" || v.Traces[1].Status != "cancelledDraft" {
		t.Fatal("future return did not preserve hidden cancellation")
	}
	again := run(t, s, "ScheduleTask", core.Payload{ChainID: r.EntityID, Date: targetDate})
	run(t, s, "AbandonChain", core.Payload{TraceID: again.EntityID})
	run(t, s, "ReactivateChain", core.Payload{TraceID: again.EntityID})
	v = snap(t, s)
	if v.Chains[0].Location != "trace" {
		t.Fatal("reactivation lost current location")
	}
	var pending []core.Subtask
	for _, sub := range v.Subtasks {
		if sub.TraceID == again.EntityID {
			pending = append(pending, sub)
		}
	}
	if len(pending) != 1 || pending[0].LineageID != v.Subtasks[0].LineageID {
		t.Fatal("pool round trip lost planned lineage")
	}
}

func TestIdeaTombstoneAndExactClockRollback(t *testing.T) {
	s, now := testStore(t)
	r := run(t, s, "CreateIdea", core.Payload{Body: "  飞光记录  "})
	run(t, s, "PinIdea", core.Payload{IdeaID: r.EntityID})
	v := snap(t, s)
	oldBits, _ := strconv.ParseUint(v.FrontierBits, 10, 64)
	*now = now.Add(-time.Hour)
	run(t, s, "EditIdea", core.Payload{IdeaID: r.EntityID, Body: "修改"})
	v = snap(t, s)
	bits, _ := strconv.ParseUint(v.FrontierBits, 10, 64)
	if bits <= oldBits {
		t.Fatal("clock rollback reversed exact frontier")
	}
	run(t, s, "DeleteIdea", core.Payload{IdeaID: r.EntityID})
	v = snap(t, s)
	if len(v.Ideas) != 1 || v.Ideas[0].Body != "" || v.Ideas[0].PinnedAt != "" || v.Ideas[0].DeletedAt == "" {
		t.Fatal("delete lost tombstone or exposed body")
	}
	_, err := s.Execute(context.Background(), command(v, "EditIdea", core.Payload{IdeaID: r.EntityID, Body: "复活"}))
	code(t, err, "NOT_FOUND")
	if _, err = s.db.Exec("UPDATE ideas SET body='resurrected',deleted_at='' WHERE id=?", r.EntityID); err == nil {
		t.Fatal("tombstone bypass")
	}
}

func TestInstanceIdentitySchemaAndStorageGuards(t *testing.T) {
	s, _ := testStore(t)
	v := snap(t, s)
	c := command(v, "CreateIdea", core.Payload{Body: "身份"})
	c.InstanceEpoch = uuid()
	_, err := s.Execute(context.Background(), c)
	code(t, err, "INSTANCE_CHANGED")
	c.InstanceEpoch = v.InstanceEpoch
	c.DatasetID = uuid()
	_, err = s.Execute(context.Background(), c)
	code(t, err, "DATASET_INACTIVE")
	if _, err = Init(context.Background(), s.root, "UTC"); err == nil {
		t.Fatal("reinitialized existing root")
	}
	path := s.root
	if _, err = s.db.Exec("PRAGMA user_version=99"); err != nil {
		t.Fatal(err)
	}
	s.Close()
	_, err = Open(context.Background(), path)
	code(t, err, "SCHEMA_UNSUPPORTED")
	link := filepath.Join(t.TempDir(), "link")
	if err = os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	_, err = Open(context.Background(), link)
	code(t, err, "INVALID_DATA_DIRECTORY")
}

func TestExclusiveInitOfMountedEmptyDirectory(t *testing.T) {
	dir := t.TempDir()
	if err := os.Chmod(dir, 0700); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	results := make(chan *Store, 2)
	for range 2 {
		wg.Add(1)
		go func() { defer wg.Done(); s, _ := Init(context.Background(), dir, "UTC"); results <- s }()
	}
	wg.Wait()
	close(results)
	success := 0
	for s := range results {
		if s != nil {
			success++
			s.Close()
		}
	}
	if success != 1 {
		t.Fatalf("concurrent init successes: %d", success)
	}
}

func TestProcessLockHelper(t *testing.T) {
	if os.Getenv("NOONMARK_LOCK_HELPER") != "1" {
		return
	}
	s, err := Open(context.Background(), os.Getenv("NOONMARK_LOCK_TEST_ROOT"))
	if os.Getenv("NOONMARK_EXPECT_LOCKED") == "1" {
		if core.ErrorCode(err) != "INSTANCE_LOCKED" {
			os.Exit(2)
		}
	} else {
		if err != nil {
			os.Exit(3)
		}
		s.Close()
	}
	os.Exit(0)
}
func TestCrossProcessWriterLock(t *testing.T) {
	s, _ := testStore(t)
	probe := func(locked bool) {
		t.Helper()
		cmd := exec.Command(os.Args[0], "-test.run=^TestProcessLockHelper$")
		want := "0"
		if locked {
			want = "1"
		}
		cmd.Env = append(os.Environ(), "NOONMARK_LOCK_HELPER=1", "NOONMARK_LOCK_TEST_ROOT="+s.root, "NOONMARK_EXPECT_LOCKED="+want)
		if output, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("process lock probe: %v (%s)", err, strings.TrimSpace(string(output)))
		}
	}
	probe(true)
	s.Close()
	probe(false)
}

func TestCrashRecoveryHelper(t *testing.T) {
	if os.Getenv("NOONMARK_CRASH_HELPER") != "1" {
		return
	}
	s, err := Init(context.Background(), os.Getenv("NOONMARK_CRASH_TEST_ROOT"), "UTC")
	if err != nil {
		os.Exit(2)
	}
	v, err := s.Snapshot(context.Background())
	if err != nil {
		os.Exit(3)
	}
	if _, err = s.Execute(context.Background(), command(v, "CreateIdea", core.Payload{Body: "已确认的合成记录"})); err != nil {
		os.Exit(4)
	}
	fmt.Println("committed")
	for {
		time.Sleep(time.Hour)
	}
}

func TestCommittedWALSurvivesProcessKill(t *testing.T) {
	root := filepath.Join(t.TempDir(), "instance")
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestCrashRecoveryHelper$")
	cmd.Env = append(os.Environ(), "NOONMARK_CRASH_HELPER=1", "NOONMARK_CRASH_TEST_ROOT="+root)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err = cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if cmd.ProcessState == nil {
			_ = cmd.Process.Kill()
			_ = cmd.Wait()
		}
	})
	scanner := bufio.NewScanner(stdout)
	if !scanner.Scan() || scanner.Text() != "committed" {
		t.Fatal("child failed to commit before kill")
	}
	wal, err := os.Stat(filepath.Join(root, "state.sqlite-wal"))
	if err != nil || wal.Size() == 0 {
		t.Fatal("no committed WAL to recover")
	}
	if err = cmd.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	_ = cmd.Wait()
	s, err := Open(context.Background(), root)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	v := snap(t, s)
	if len(v.Ideas) != 1 || v.Sequence != "1" {
		t.Fatal("acknowledged mutation lost after SIGKILL")
	}
	var receipts, batches int
	if err = s.db.QueryRow("SELECT COUNT(*) FROM command_receipts").Scan(&receipts); err != nil {
		t.Fatal(err)
	}
	if err = s.db.QueryRow("SELECT COUNT(*) FROM change_batches").Scan(&batches); err != nil {
		t.Fatal(err)
	}
	if receipts != 1 || batches != 1 {
		t.Fatal("facts and commit evidence diverged after SIGKILL")
	}
}

func TestOwnerTimezoneControlsMidnightAcrossDST(t *testing.T) {
	s, err := Init(context.Background(), filepath.Join(t.TempDir(), "instance"), "America/New_York")
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	now := time.Date(2026, 11, 1, 3, 59, 0, 0, time.UTC)
	s.now = func() time.Time { return now }
	v := snap(t, s)
	if v.Today != "2026-10-31" {
		t.Fatal("server UTC leaked into owner day")
	}
	run(t, s, "CreateTask", core.Payload{Title: "跨日合成记录", Date: v.Today})
	now = now.Add(2 * time.Minute)
	v = snap(t, s)
	if v.Today != "2026-11-01" || v.Traces[0].Status != "unfinished" {
		t.Fatal("owner midnight did not settle")
	}
	seq := v.Sequence
	now = time.Date(2026, 11, 1, 6, 30, 0, 0, time.UTC)
	v = snap(t, s)
	if v.Today != "2026-11-01" || v.Sequence != seq {
		t.Fatal("DST rollback repeated settlement")
	}
}

func TestIncompleteRestoreCannotOpen(t *testing.T) {
	s, _ := testStore(t)
	root := s.root
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, ".restore-pending"), []byte("pending"), 0600); err != nil {
		t.Fatal(err)
	}
	_, err := Open(context.Background(), root)
	code(t, err, "RESTORE_INCOMPLETE")
}

func TestRevokedSessionCannotReadReceipt(t *testing.T) {
	s, _ := testStore(t)
	if err := s.InitializeOwner(context.Background(), "synthetic-owner-password"); err != nil {
		t.Fatal(err)
	}
	session, err := s.Login(context.Background(), "synthetic-owner-password")
	if err != nil {
		t.Fatal(err)
	}
	r := run(t, s, "CreateIdea", core.Payload{Body: "收据权限合成记录"})
	ctx := WithSession(context.Background(), session.Token)
	if _, err = s.Receipt(ctx, r.CommandID); err != nil {
		t.Fatal(err)
	}
	if err = s.Logout(context.Background(), session.Token); err != nil {
		t.Fatal(err)
	}
	if _, err = s.Receipt(ctx, r.CommandID); !errors.Is(err, ErrCredentials) {
		t.Fatalf("revoked session receipt access: %v", err)
	}
}

func TestCarryoverReindexesRemainingSubtasksBeforeNewOnes(t *testing.T) {
	s, now := testStore(t)
	v := snap(t, s)
	run(t, s, "CreateTask", core.Payload{Title: "子任务顺序合成记录", Date: v.Today})
	v = snap(t, s)
	trace := v.Traces[0].ID
	first := run(t, s, "AddSubtask", core.Payload{TraceID: trace, Title: "第一步", Difficulty: "simple"})
	second := run(t, s, "AddSubtask", core.Payload{TraceID: trace, Title: "第二步", Difficulty: "simple"})
	run(t, s, "AddSubtask", core.Payload{TraceID: trace, Title: "第三步", Difficulty: "hard"})
	run(t, s, "CompleteSubtask", core.Payload{SubtaskID: first.EntityID})
	run(t, s, "CompleteSubtask", core.Payload{SubtaskID: second.EntityID})
	next := run(t, s, "DeferTrace", core.Payload{TraceID: trace, Date: now.Add(24 * time.Hour).Format("2006-01-02")})
	added := run(t, s, "AddSubtask", core.Payload{TraceID: next.EntityID, Title: "后来新增", Difficulty: "simple"})
	v = snap(t, s)
	for _, sub := range v.Subtasks {
		if sub.TraceID != next.EntityID {
			continue
		}
		want := 1
		if sub.ID == added.EntityID {
			want = 2
		}
		if sub.Position != want {
			t.Fatalf("carryover subtask position=%d want=%d", sub.Position, want)
		}
	}
}

func TestFactTimestampsFollowAllocatedClockAfterRollback(t *testing.T) {
	s, now := testStore(t)
	v := snap(t, s)
	run(t, s, "CreateTask", core.Payload{Title: "回拨时钟的合成任务", Date: v.Today})
	idea := run(t, s, "CreateIdea", core.Payload{Body: "回拨时钟的合成飞光"})
	v = snap(t, s)
	trace := v.Traces[0]
	created, _ := time.Parse(time.RFC3339Nano, trace.CreatedAt)
	*now = now.Add(-time.Hour)
	run(t, s, "CompleteTrace", core.Payload{TraceID: trace.ID})
	run(t, s, "EditIdea", core.Payload{IdeaID: idea.EntityID, Body: "回拨后修改"})
	run(t, s, "PinIdea", core.Payload{IdeaID: idea.EntityID})
	v = snap(t, s)
	completed, _ := time.Parse(time.RFC3339Nano, v.Traces[0].CompletedAt)
	if completed.Before(created) {
		t.Fatal("allocated completion timestamp precedes task creation after wall-clock rollback")
	}
	note := v.Ideas[0]
	noteCreated, _ := time.Parse(time.RFC3339Nano, note.CreatedAt)
	updated, _ := time.Parse(time.RFC3339Nano, note.UpdatedAt)
	pinned, _ := time.Parse(time.RFC3339Nano, note.PinnedAt)
	if updated.Before(noteCreated) || pinned.Before(noteCreated) {
		t.Fatal("note mutation timestamp moved behind creation")
	}
	run(t, s, "DeleteIdea", core.Payload{IdeaID: idea.EntityID})
	deleted, _ := time.Parse(time.RFC3339Nano, snap(t, s).Ideas[0].DeletedAt)
	if deleted.Before(pinned) {
		t.Fatal("tombstone timestamp moved behind pin")
	}
	before := snap(t, s)
	path := s.root
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := Open(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	reopened.now = func() time.Time { return *now }
	after := snap(t, reopened)
	if after.FrontierBits != before.FrontierBits || after.Traces[0].CompletedAt != before.Traces[0].CompletedAt || after.Ideas[0].DeletedAt != before.Ideas[0].DeletedAt {
		t.Fatal("restart changed allocated mutation timestamps")
	}
}

func TestMismatchedMutationProjectionFailsClosed(t *testing.T) {
	s, _ := testStore(t)
	idea := run(t, s, "CreateIdea", core.Payload{Body: "损坏投影合成记录"})
	if _, err := s.db.Exec("UPDATE ideas SET updated_at=? WHERE id=?", "1999-01-01T00:00:00Z", idea.EntityID); err != nil {
		t.Fatal(err)
	}
	code(t, s.Doctor(context.Background()), "INVARIANT_VIOLATION")
	path := s.root
	s.Close()
	_, err := Open(context.Background(), path)
	code(t, err, "INVARIANT_VIOLATION")
}

func TestSameWallClockIdeasSortNewestFirst(t *testing.T) {
	s, _ := testStore(t)
	first := run(t, s, "CreateIdea", core.Payload{Body: "相同时钟的第一条合成记录"})
	second := run(t, s, "CreateIdea", core.Payload{Body: "相同时钟的第二条合成记录"})
	v := snap(t, s)
	if len(v.Ideas) != 2 || v.Ideas[0].ID != second.EntityID || v.Ideas[1].ID != first.EntityID {
		t.Fatal("variable-width timestamp projection sorts older capture ahead of newer capture")
	}
	// 与 Notes.tsx 相同的 ECMAScript localeCompare，消费真实 Store 返回的时间投影。
	input, _ := json.Marshal([]string{v.Ideas[1].CreatedAt, v.Ideas[0].CreatedAt})
	compare := exec.Command("node", "-e", `const values=JSON.parse(require("fs").readFileSync(0,"utf8"));process.stdout.write(values.sort((a,b)=>b.localeCompare(a))[0]);`)
	compare.Stdin = strings.NewReader(string(input))
	result, err := compare.Output()
	if err != nil {
		t.Fatal("JavaScript projection comparison failed")
	}
	if string(result) != v.Ideas[0].CreatedAt {
		t.Fatal("browser comparator disagrees with chronological Store order")
	}
}
