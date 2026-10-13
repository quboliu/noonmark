package store

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/quboliu/noonmark/services/noonmark/internal/core"
)

type DemoReport struct {
	Status        string                    `json:"status"`
	Profile       string                    `json:"profile"`
	StartDate     string                    `json:"start_date"`
	EndDate       string                    `json:"end_date"`
	Days          int                       `json:"days"`
	Sequence      string                    `json:"sequence"`
	CommandCounts map[string]int            `json:"command_counts"`
	QuarterCounts map[string]map[string]int `json:"quarter_counts"`
	Facts         map[string]int            `json:"facts"`
	Reopened      bool                      `json:"reopened"`
}

var demoCommands = []string{"CreateTask", "EditTask", "ScheduleTask", "CompleteTrace", "UndoCompleteTrace", "DeferTrace", "ContinueTrace", "ReturnToPool", "RescheduleTrace", "AbandonChain", "ReactivateChain", "AddSubtask", "EditSubtask", "CompleteSubtask", "UndoCompleteSubtask", "AbandonSubtask", "DeleteSubtask", "UpdateProgress", "CreateIdea", "EditIdea", "DeleteIdea", "PinIdea", "UnpinIdea", "UpdateReview"}

// CreateDemo 只用于独占的外置 demo run；Store 在注入历史时钟期间不向调用者暴露。
func CreateDemo(ctx context.Context, dataDir, timezone, password string) (DemoReport, error) {
	return createDemo(ctx, dataDir, timezone, password, time.Now)
}

// createDemo 的可控时钟仅供确定性测试；公开入口始终传入真实墙钟。
func createDemo(ctx context.Context, dataDir, timezone, password string, now func() time.Time) (DemoReport, error) {
	var report DemoReport
	if err := validateDemoRoot(dataDir); err != nil {
		return report, err
	}
	if err := ValidatePassword(password); err != nil {
		return report, err
	}
	anchor := now()
	location, err := time.LoadLocation(timezone)
	if err != nil {
		return report, core.Fail("INVALID_TIMEZONE")
	}
	local := anchor.In(location)
	start := time.Date(local.Year(), local.Month(), local.Day(), 12, 0, 0, 0, location).AddDate(0, 0, -364)
	s, err := initAt(ctx, dataDir, timezone, start.Add(-time.Second))
	if err != nil {
		return report, err
	}
	defer s.Close()
	s.now = now
	if err = s.InitializeOwner(ctx, password); err != nil {
		return report, err
	}
	if err = s.InitializeKey(); err != nil {
		return report, err
	}
	report, err = s.replayDemo(ctx, anchor)
	if err != nil {
		return report, err
	}
	if err = s.Close(); err != nil {
		return report, err
	}
	return readBackDemo(ctx, dataDir, report, now)
}

func readBackDemo(ctx context.Context, dataDir string, report DemoReport, now func() time.Time) (DemoReport, error) {
	reopened, err := openAt(ctx, dataDir, now)
	if err != nil {
		return report, err
	}
	defer reopened.Close()
	if err = reopened.ValidateKey(); err != nil {
		return report, err
	}
	if !reopened.OwnerInitialized(ctx) {
		return report, core.Fail("OWNER_REQUIRED")
	}
	v, err := reopened.Snapshot(ctx)
	if err != nil {
		return report, err
	}
	if v.Today != report.EndDate {
		return report, core.Fail("DEMO_DAY_CHANGED")
	}
	if err = validateDemoReport(v, &report); err != nil {
		return report, err
	}
	if err = reopened.verifyDemoCommitCounts(ctx, report); err != nil {
		return report, err
	}
	report.Status = "ready"
	report.Reopened = true
	return report, nil
}

func validateDemoRoot(dataDir string) error {
	bad := func() error { return core.Fail("DEMO_PROFILE_REQUIRED") }
	if os.Getenv("NOONMARK_PROFILE") != "demo" {
		return bad()
	}
	work, err := safeRoot(os.Getenv("NOONMARK_WORK_ROOT"))
	if err != nil {
		return bad()
	}
	run, err := safeRoot(os.Getenv("NOONMARK_RUN_ROOT"))
	if err != nil {
		return bad()
	}
	id := os.Getenv("NOONMARK_RUN_ID")
	if !core.ValidID(id) || run != filepath.Join(work, "runs", "demo", id) {
		return bad()
	}
	absolute, err := filepath.Abs(dataDir)
	if err != nil || absolute != filepath.Join(run, "databases", "instance") {
		return bad()
	}
	parent, err := safeRoot(filepath.Dir(absolute))
	if err != nil || parent != filepath.Join(run, "databases") {
		return bad()
	}
	path := filepath.Join(run, "ownership.json")
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() > 8192 {
		return bad()
	}
	f, err := os.Open(path)
	if err != nil {
		return bad()
	}
	defer f.Close()
	var manifest struct {
		Profile    string `json:"profile"`
		RunID      string `json:"run_id"`
		OwnerUID   int    `json:"owner_uid"`
		SourceHash string `json:"source_hash"`
	}
	if err = json.NewDecoder(io.LimitReader(f, 8193)).Decode(&manifest); err != nil {
		return bad()
	}
	if manifest.Profile != "demo" || manifest.RunID != id || manifest.OwnerUID != os.Geteuid() || manifest.SourceHash == "" || manifest.SourceHash != os.Getenv("NOONMARK_SOURCE_HASH") {
		return bad()
	}
	return nil
}

type demoRunner struct {
	s      *Store
	ctx    context.Context
	report *DemoReport
	index  int
	cursor *time.Time
	err    error
}

func (r *demoRunner) snapshot() core.Snapshot {
	if r.err != nil {
		return core.Snapshot{}
	}
	v, err := r.s.Snapshot(r.ctx)
	r.err = err
	return v
}
func (r *demoRunner) send(kind string, p core.Payload) core.Receipt {
	v := r.snapshot()
	if r.err != nil {
		return core.Receipt{}
	}
	revision := "0"
	chain := p.ChainID
	trace := p.TraceID
	for _, sub := range v.Subtasks {
		if sub.ID == p.SubtaskID {
			trace = sub.TraceID
		}
	}
	for _, tr := range v.Traces {
		if tr.ID == trace {
			chain = tr.ChainID
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
	cmd := core.Command{InstanceID: v.InstanceID, InstanceEpoch: v.InstanceEpoch, DatasetID: v.DatasetID, CommandID: uuid(), SchemaVersion: 1, Type: kind, ExpectedRevision: revision, Payload: p}
	receipt, err := r.s.Execute(r.ctx, cmd)
	if err != nil {
		r.err = fmt.Errorf("demo %s: %w", kind, err)
		return core.Receipt{}
	}
	r.report.CommandCounts[kind]++
	quarter := fmt.Sprintf("Q%d", min(r.index/92+1, 4))
	r.report.QuarterCounts[quarter][kind]++
	if r.index < 364 {
		*r.cursor = r.cursor.Add(time.Second)
	}
	return receipt
}
func (r *demoRunner) task(title, date string) (string, string) {
	created := r.send("CreateTask", core.Payload{Title: title, Description: "年度演示的合成任务，可直接继续体验。", Date: date})
	if date == "" {
		return created.EntityID, ""
	}
	v := r.snapshot()
	for _, tr := range v.Traces {
		if tr.ChainID == created.EntityID && tr.Status == "pending" {
			return created.EntityID, tr.ID
		}
	}
	if r.err == nil {
		r.err = core.Fail("DEMO_TRACE_MISSING")
	}
	return "", ""
}

// replayDemo 使用真实 Execute 边界重放一年；调用者必须尚未发布此 Store。
func (s *Store) replayDemo(ctx context.Context, anchor time.Time) (DemoReport, error) {
	report := DemoReport{Profile: "demo", Days: 365, CommandCounts: map[string]int{}, QuarterCounts: map[string]map[string]int{}, Facts: map[string]int{}}
	for i := 1; i <= 4; i++ {
		report.QuarterCounts[fmt.Sprintf("Q%d", i)] = map[string]int{}
	}
	v, err := s.Snapshot(ctx)
	if err != nil {
		return report, err
	}
	if v.Sequence != "0" || len(v.Chains)+len(v.Ideas)+len(v.Days)+len(v.Traces)+len(v.Subtasks)+len(v.Definitions) != 0 {
		return report, core.Fail("DEMO_REQUIRES_EMPTY_INSTANCE")
	}
	location, err := time.LoadLocation(v.Timezone)
	if err != nil {
		return report, err
	}
	end := anchor.In(location)
	end = time.Date(end.Year(), end.Month(), end.Day(), 12, 0, 0, 0, location)
	start := end.AddDate(0, 0, -364)
	report.StartDate = start.Format("2006-01-02")
	report.EndDate = end.Format("2006-01-02")
	originalNow := s.now
	cursor := start
	s.now = func() time.Time { return cursor }
	defer func() { s.now = originalNow }()
	r := &demoRunner{s: s, ctx: ctx, report: &report, cursor: &cursor}
	var continueTomorrow, deferTomorrow string
	for day := 0; day < 365; day++ {
		if err = ctx.Err(); err != nil {
			return report, err
		}
		r.index = day
		cursor = start.AddDate(0, 0, day)
		if day == 364 {
			cursor = anchor.In(location)
		}
		date := cursor.Format("2006-01-02")
		if continueTomorrow != "" {
			next := r.send("ContinueTrace", core.Payload{TraceID: continueTomorrow, Date: date})
			r.send("CompleteTrace", core.Payload{TraceID: next.EntityID})
			continueTomorrow = ""
		}
		if deferTomorrow != "" {
			r.send("CompleteTrace", core.Payload{TraceID: deferTomorrow})
			deferTomorrow = ""
		}
		chain, trace := r.task("整理每日工作记录 · "+date, date)
		r.send("EditTask", core.Payload{ChainID: chain, Title: "整理并核对每日工作记录 · " + date, Description: "整理进展、待跟进事项和下一次行动；保留每日真实结果。"})
		r.send("CompleteTrace", core.Payload{TraceID: trace})
		r.send("UpdateReview", core.Payload{Date: date, Summary: "完成今天的整理，确认下一次可执行行动。", UnfinishedReason: "外部反馈仍在等待，未完成记录继续保留。", TomorrowNote: "先处理关键事项，再集中处理零散沟通。"})
		if day%30 == 15 {
			r.send("UndoCompleteTrace", core.Payload{TraceID: trace})
			r.send("CompleteTrace", core.Payload{TraceID: trace})
			pool, _ := r.task("整理资料并调整安排 · "+date, "")
			planned := r.send("ScheduleTask", core.Payload{ChainID: pool, Date: date})
			r.send("ReturnToPool", core.Payload{TraceID: planned.EntityID})
			planned = r.send("ScheduleTask", core.Payload{ChainID: pool, Date: cursor.AddDate(0, 0, 1).Format("2006-01-02")})
			r.send("RescheduleTrace", core.Payload{TraceID: planned.EntityID, Date: cursor.AddDate(0, 0, 2).Format("2006-01-02")})
			r.send("ReturnToPool", core.Payload{TraceID: planned.EntityID})
			planned = r.send("ScheduleTask", core.Payload{ChainID: pool, Date: date})
			r.send("CompleteTrace", core.Payload{TraceID: planned.EntityID})
			_, parent := r.task("逐项核对交接清单 · "+date, date)
			a := r.send("AddSubtask", core.Payload{TraceID: parent, Title: "整理入口", Difficulty: "simple"})
			b := r.send("AddSubtask", core.Payload{TraceID: parent, Title: "核对暂不需要的方案", Difficulty: "hard"})
			r.send("EditSubtask", core.Payload{SubtaskID: a.EntityID, Title: "整理并核对入口", Difficulty: "medium"})
			r.send("CompleteSubtask", core.Payload{SubtaskID: a.EntityID})
			r.send("UndoCompleteSubtask", core.Payload{SubtaskID: a.EntityID})
			r.send("CompleteSubtask", core.Payload{SubtaskID: a.EntityID})
			r.send("AbandonSubtask", core.Payload{SubtaskID: b.EntityID})
			removed := r.send("AddSubtask", core.Payload{TraceID: parent, Title: "重复输入的草稿项", Difficulty: "simple"})
			r.send("DeleteSubtask", core.Payload{SubtaskID: removed.EntityID})
			r.send("CompleteTrace", core.Payload{TraceID: parent})
			_, deferred := r.task("等待确认后完成简报 · "+date, date)
			r.send("UpdateProgress", core.Payload{TraceID: deferred, Progress: 40})
			next := r.send("DeferTrace", core.Payload{TraceID: deferred, Date: cursor.AddDate(0, 0, 1).Format("2006-01-02")})
			deferTomorrow = next.EntityID
			_, continueTomorrow = r.task("第二天延续访谈整理 · "+date, date)
			_, abandoned := r.task("重新启用暂缓的资料核对 · "+date, date)
			r.send("AbandonChain", core.Payload{TraceID: abandoned})
			r.send("ReactivateChain", core.Payload{TraceID: abandoned})
			r.send("CompleteTrace", core.Payload{TraceID: abandoned})
			_, abandoned = r.task("保留已经放弃的旧实验 · "+date, date)
			r.send("AbandonChain", core.Payload{TraceID: abandoned})
			r.task("任务池里的后续想法 · "+date, "")
			idea := r.send("CreateIdea", core.Payload{Body: "记录一次工作中的发现 · " + date + "\n先把观察留下，再决定是否形成任务。"})
			r.send("EditIdea", core.Payload{IdeaID: idea.EntityID, Body: "记录一次工作中的发现 · " + date + "\n补充：把下一步缩小，先验证最关键的假设。"})
			r.send("PinIdea", core.Payload{IdeaID: idea.EntityID})
			r.send("UnpinIdea", core.Payload{IdeaID: idea.EntityID})
			if day >= 270 {
				r.send("PinIdea", core.Payload{IdeaID: idea.EntityID})
			}
			deleted := r.send("CreateIdea", core.Payload{Body: "确认后删除的临时记录"})
			r.send("DeleteIdea", core.Payload{IdeaID: deleted.EntityID})
		}
		if day == 363 {
			r.task("等待下一次延续的访谈笔记", date)
			r.task("尚未完成的接口清单", date)
		}
		if r.err != nil {
			return report, r.err
		}
	}
	// 当前日保留足够长的真实列表，供滚动、输入、焦点及悬浮入口验收。
	for i := 0; i < 60; i++ {
		title := []string{"整理访谈摘要", "核对任务边界", "补充使用说明", "确认下一次行动", "检查页面交互", "回看本周记录"}[i%6]
		_, trace := r.task(fmt.Sprintf("%s（%02d）", title, i+1), report.EndDate)
		if i < 4 {
			r.send("AddSubtask", core.Payload{TraceID: trace, Title: "确认关键步骤", Difficulty: "medium"})
			r.send("AddSubtask", core.Payload{TraceID: trace, Title: "补充验证记录", Difficulty: "simple"})
		}
	}
	for i := 1; i <= 8; i++ {
		r.task(fmt.Sprintf("未来计划：第 %d 次阶段整理", i), end.AddDate(0, 0, i).Format("2006-01-02"))
	}
	if r.err != nil {
		return report, r.err
	}
	v = r.snapshot()
	if r.err != nil {
		return report, r.err
	}
	if err = validateDemoReport(v, &report); err != nil {
		return report, err
	}
	if err = s.Doctor(ctx); err != nil {
		return report, err
	}
	if err = s.verifyDemoCommitCounts(ctx, report); err != nil {
		return report, err
	}
	return report, nil
}

func (s *Store) verifyDemoCommitCounts(ctx context.Context, report DemoReport) error {
	rows, err := s.db.QueryContext(ctx, "SELECT kind,COUNT(*) FROM change_batches WHERE kind!='day_settlement' GROUP BY kind")
	if err != nil {
		return storageError(err)
	}
	counts := map[string]int{}
	total := 0
	for rows.Next() {
		var kind string
		var count int
		if err = rows.Scan(&kind, &count); err != nil {
			rows.Close()
			return storageError(err)
		}
		counts[kind] = count
		total += count
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return storageError(err)
	}
	if len(counts) != len(report.CommandCounts) {
		return core.Fail("DEMO_RECEIPT_MISMATCH")
	}
	for kind, count := range counts {
		if report.CommandCounts[kind] != count {
			return core.Fail("DEMO_RECEIPT_MISMATCH")
		}
	}
	var receipts int
	if err = s.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM command_receipts").Scan(&receipts); err != nil {
		return storageError(err)
	}
	if receipts != total {
		return core.Fail("DEMO_RECEIPT_MISMATCH")
	}
	return nil
}

func validateDemoReport(v core.Snapshot, report *DemoReport) error {
	bad := func() error { return core.Fail("DEMO_COVERAGE_FAILED") }
	location, err := time.LoadLocation(v.Timezone)
	if err != nil {
		return bad()
	}
	creationDays := map[string]bool{}
	for _, chain := range v.Chains {
		instant, err := time.Parse(time.RFC3339Nano, chain.CreatedAt)
		if err != nil {
			return bad()
		}
		date := instant.In(location).Format("2006-01-02")
		if date < report.StartDate || date > report.EndDate {
			return bad()
		}
		creationDays[date] = true
	}
	if len(creationDays) != 365 {
		return bad()
	}
	for _, quarter := range report.QuarterCounts {
		for _, name := range demoCommands {
			if quarter[name] < 3 {
				return bad()
			}
		}
	}
	reviews, locked, todayPending, pool, completed, unfinished, abandoned, pinned, deleted := 0, 0, 0, 0, 0, 0, 0, 0, 0
	for _, d := range v.Days {
		if d.Date >= report.StartDate && d.Date <= report.EndDate {
			if d.Summary != "" {
				reviews++
			}
			if d.LockedAt != "" {
				locked++
			}
		}
	}
	for _, c := range v.Chains {
		if c.Location == "pool" {
			pool++
		}
	}
	for _, tr := range v.Traces {
		if tr.Status == "pending" && tr.Date == report.EndDate {
			todayPending++
		}
		switch tr.Status {
		case "completed":
			completed++
		case "unfinished":
			unfinished++
		case "abandoned":
			abandoned++
		}
	}
	for _, i := range v.Ideas {
		if i.PinnedAt != "" {
			pinned++
		}
		if i.DeletedAt != "" {
			deleted++
		}
	}
	if reviews != 365 || locked != 364 || todayPending < 60 || pool < 12 || completed < 365 || unfinished < 12 || abandoned < 12 || pinned < 3 || deleted < 12 {
		return bad()
	}
	report.Sequence = v.Sequence
	report.Facts = map[string]int{"creation_days": len(creationDays), "chains": len(v.Chains), "definitions": len(v.Definitions), "traces": len(v.Traces), "subtasks": len(v.Subtasks), "ideas": len(v.Ideas), "reviews": reviews, "locked_days": locked, "today_pending": todayPending, "pool": pool, "completed": completed, "unfinished": unfinished, "abandoned": abandoned, "pinned_ideas": pinned, "idea_tombstones": deleted}
	return nil
}
