package store

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/quboliu/noonmark/services/noonmark/internal/core"
)

func demoTestRoot(t *testing.T) string {
	t.Helper()
	work := t.TempDir()
	if err := os.Chmod(work, 0700); err != nil {
		t.Fatal(err)
	}
	id := uuid()
	run := filepath.Join(work, "runs", "demo", id)
	if err := os.MkdirAll(filepath.Join(run, "databases"), 0700); err != nil {
		t.Fatal(err)
	}
	for key, value := range map[string]string{"NOONMARK_PROFILE": "demo", "NOONMARK_WORK_ROOT": work, "NOONMARK_RUN_ROOT": run, "NOONMARK_RUN_ID": id, "NOONMARK_SOURCE_HASH": "synthetic-demo-test-source"} {
		t.Setenv(key, value)
	}
	manifest := map[string]any{"profile": "demo", "run_id": id, "owner_uid": os.Geteuid(), "source_hash": "synthetic-demo-test-source"}
	data, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(run, "ownership.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
	return filepath.Join(run, "databases", "instance")
}

func TestDemoRequiresOwnedExplicitProfile(t *testing.T) {
	root := demoTestRoot(t)
	if err := validateDemoRoot(root); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOONMARK_PROFILE", "audit")
	_, err := CreateDemo(context.Background(), root, "UTC", "synthetic-demo-password")
	code(t, err, "DEMO_PROFILE_REQUIRED")
	if _, err = os.Stat(root); !os.IsNotExist(err) {
		t.Fatal("rejected demo touched instance root")
	}
	t.Setenv("NOONMARK_PROFILE", "demo")
	code(t, validateDemoRoot(filepath.Join(filepath.Dir(root), "other")), "DEMO_PROFILE_REQUIRED")
	t.Setenv("NOONMARK_RUN_ID", uuid())
	code(t, validateDemoRoot(root), "DEMO_PROFILE_REQUIRED")
}

func TestDemoNeverReplaysIntoExistingFacts(t *testing.T) {
	s, _ := testStore(t)
	run(t, s, "CreateTask", core.Payload{Title: "已有合成事实"})
	before := snap(t, s)
	oldNow := s.now()
	_, err := s.replayDemo(context.Background(), time.Now())
	code(t, err, "DEMO_REQUIRES_EMPTY_INSTANCE")
	after := snap(t, s)
	if after.Sequence != before.Sequence || s.now() != oldNow {
		t.Fatal("rejected replay mutated facts or clock")
	}
}

func TestDemoOneYearCommandsAndReopen(t *testing.T) {
	root := demoTestRoot(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	location, err := time.LoadLocation("America/New_York")
	if err != nil {
		t.Fatal(err)
	}
	anchor := time.Date(2026, 7, 24, 23, 59, 59, 0, location)
	now := func() time.Time { return anchor }
	report, err := createDemo(ctx, root, "America/New_York", "synthetic-demo-password", now)
	if err != nil {
		t.Fatal(err)
	}
	if report.Status != "ready" || !report.Reopened || report.Days != 365 || report.Facts["reviews"] != 365 || report.Facts["locked_days"] != 364 || report.Facts["today_pending"] != 60 {
		t.Fatalf("demo report not complete: %+v", report.Facts)
	}
	start, err := time.Parse("2006-01-02", report.StartDate)
	if err != nil {
		t.Fatal(err)
	}
	end, err := time.Parse("2006-01-02", report.EndDate)
	if err != nil || end.Sub(start) != 364*24*time.Hour {
		t.Fatal("not 365 consecutive civil days")
	}
	for quarter, counts := range report.QuarterCounts {
		for _, kind := range demoCommands {
			if counts[kind] < 3 {
				t.Fatalf("%s insufficient %s", quarter, kind)
			}
		}
	}
	s, err := openAt(ctx, root, now)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	v := snap(t, s)
	if v.Sequence != report.Sequence || len(v.Chains) != report.Facts["chains"] {
		t.Fatal("readback differs from ready report")
	}
	if err = s.verifyDemoCommitCounts(ctx, report); err != nil {
		t.Fatal(err)
	}
}

func TestDemoClockSurvivesStoreReopen(t *testing.T) {
	location, err := time.LoadLocation("America/New_York")
	if err != nil {
		t.Fatal(err)
	}
	anchor := time.Date(2026, 7, 24, 23, 59, 59, 0, location)
	root := filepath.Join(t.TempDir(), "instance")
	s, err := initAt(context.Background(), root, "America/New_York", anchor.Add(-time.Second))
	if err != nil {
		t.Fatal(err)
	}
	s.now = func() time.Time { return anchor }
	before := snap(t, s)
	if err = s.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := openAt(context.Background(), root, func() time.Time { return anchor })
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	after := snap(t, reopened)
	if before.Today != "2026-07-24" || after.Today != before.Today {
		t.Fatal("reopen lost the deterministic demo clock")
	}
}

func TestDemoReadbackRejectsMidnightRollover(t *testing.T) {
	location, err := time.LoadLocation("America/New_York")
	if err != nil {
		t.Fatal(err)
	}
	anchor := time.Date(2026, 7, 24, 23, 59, 59, 0, location)
	root := filepath.Join(t.TempDir(), "instance")
	s, err := initAt(context.Background(), root, "America/New_York", anchor.Add(-time.Second))
	if err != nil {
		t.Fatal(err)
	}
	s.now = func() time.Time { return anchor }
	if err = s.InitializeOwner(context.Background(), "synthetic-demo-password"); err != nil {
		s.Close()
		t.Fatal(err)
	}
	if err = s.InitializeKey(); err != nil {
		s.Close()
		t.Fatal(err)
	}
	run(t, s, "CreateTask", core.Payload{Title: "跨午夜的合成演示任务", Date: "2026-07-24"})
	if err = s.Close(); err != nil {
		t.Fatal(err)
	}
	report, err := readBackDemo(context.Background(), root, DemoReport{EndDate: "2026-07-24"}, func() time.Time { return anchor.Add(2 * time.Second) })
	code(t, err, "DEMO_DAY_CHANGED")
	if report.Status == "ready" || report.Reopened {
		t.Fatal("midnight rollover falsely published ready demo")
	}
}
