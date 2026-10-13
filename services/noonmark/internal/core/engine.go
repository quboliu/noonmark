package core

import (
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

type engine struct {
	s           Snapshot
	chains      map[string]*Chain
	definitions map[string]*Definition
	traces      map[string]*Trace
	subtasks    map[string]*Subtask
	days        map[string]*Day
	ideas       map[string]*Idea
	stamp       Stamp
	id          func() string
}

func load(s Snapshot, now time.Time, id func() string) (*engine, error) {
	bits, err := NextMutation(now, s.FrontierBits)
	if err != nil {
		return nil, err
	}
	instant, err := MutationTime(bits)
	if err != nil {
		return nil, err
	}
	e := &engine{s: s, chains: map[string]*Chain{}, definitions: map[string]*Definition{}, traces: map[string]*Trace{}, subtasks: map[string]*Subtask{}, days: map[string]*Day{}, ideas: map[string]*Idea{}, id: id, stamp: Stamp{CreatedAt: instant.Format(MutationTimeLayout), UpdatedAt: instant.Format(MutationTimeLayout), MutationBits: bits}}
	for _, v := range s.Chains {
		v := v
		e.chains[v.ID] = &v
	}
	for _, v := range s.Definitions {
		v := v
		e.definitions[v.ID] = &v
	}
	for _, v := range s.Traces {
		v := v
		e.traces[v.ID] = &v
	}
	for _, v := range s.Subtasks {
		v := v
		e.subtasks[v.ID] = &v
	}
	for _, v := range s.Days {
		v := v
		e.days[v.Date] = &v
	}
	for _, v := range s.Ideas {
		v := v
		e.ideas[v.ID] = &v
	}
	return e, nil
}
func (e *engine) touch(s *Stamp) {
	s.UpdatedAt = e.stamp.UpdatedAt
	s.MutationBits = e.stamp.MutationBits
}
func bump(revision string) string {
	n, _ := strconv.ParseUint(revision, 10, 64)
	return strconv.FormatUint(n+1, 10)
}
func (e *engine) touchChain(c *Chain) { c.Revision = bump(c.Revision); e.touch(&c.Stamp) }
func (e *engine) day(date string) *Day {
	if d := e.days[date]; d != nil {
		return d
	}
	d := &Day{Date: date, Revision: "0", Stamp: e.stamp}
	e.days[date] = d
	return d
}
func (e *engine) touchDay(d *Day) { d.Revision = bump(d.Revision); e.touch(&d.Stamp) }
func (e *engine) unlocked(t *Trace) error {
	if t.Date < e.s.Today || e.day(t.Date).LockedAt != "" {
		return Fail("DAY_LOCKED")
	}
	return nil
}
func (e *engine) pending(t *Trace) error {
	if err := e.unlocked(t); err != nil {
		return err
	}
	if t.Status != "pending" || e.chains[t.ChainID].State != "active" {
		return Fail("INVALID_TRANSITION")
	}
	return nil
}
func (e *engine) latest(chain string) *Trace {
	var latest *Trace
	for _, t := range e.traces {
		if t.ChainID != chain || t.Status == "cancelledDraft" {
			continue
		}
		if latest == nil || t.Date > latest.Date || (t.Date == latest.Date && t.Priority > latest.Priority) {
			latest = t
		}
	}
	return latest
}
func (e *engine) active(chain string) *Trace {
	for _, t := range e.traces {
		if t.ChainID == chain && t.Status == "pending" {
			return t
		}
	}
	return nil
}
func (e *engine) newTrace(c *Chain, date string) *Trace {
	p := 1
	for _, t := range e.traces {
		if t.Date == date && t.Priority >= p {
			p = t.Priority + 1
		}
	}
	d := e.definitions[c.DefinitionID]
	t := &Trace{ID: e.id(), ChainID: c.ID, DefinitionID: c.DefinitionID, Date: date, Status: "pending", Priority: p, Description: d.Description, Stamp: e.stamp}
	e.traces[t.ID] = t
	e.day(date)
	c.Location = "trace"
	return t
}
func checkRevision(got, want string) error {
	if got != want {
		return Fail("VERSION_CONFLICT")
	}
	return nil
}
func textOK(s string, max int, empty bool) bool {
	return utf8.ValidString(s) && len(s) <= max && (empty || strings.TrimSpace(s) != "") && !strings.ContainsRune(s, 0)
}
func difficulty(s string) bool { return s == "simple" || s == "medium" || s == "hard" }
func weight(s string) int {
	switch s {
	case "hard":
		return 3
	case "medium":
		return 2
	default:
		return 1
	}
}

// Apply 只计算候选事实；持久层须在同一事务写入结果与 receipt。
func Apply(s Snapshot, c Command, now time.Time, id func() string) (Snapshot, string, error) {
	e, err := load(s, now, id)
	if err != nil {
		return s, "", err
	}
	entity, err := e.apply(c)
	if err != nil {
		return s, "", err
	}
	result := e.snapshot()
	result.FrontierBits = e.stamp.MutationBits
	if err = Validate(result); err != nil {
		return s, "", err
	}
	return result, entity, nil
}
func (e *engine) apply(cmd Command) (string, error) {
	p := cmd.Payload
	for _, s := range []string{p.Title, p.Description, p.Body, p.Summary, p.UnfinishedReason, p.TomorrowNote} {
		if !textOK(s, 65536, true) {
			return "", Fail("INVALID_INPUT")
		}
	}
	if strings.HasSuffix(cmd.Type, "Idea") {
		return e.ideaCommand(cmd)
	}
	if cmd.Type == "UpdateReview" {
		if !ValidDate(p.Date) || p.Date > e.s.Today {
			return "", Fail("INVALID_DATE")
		}
		d := e.day(p.Date)
		if err := checkRevision(cmd.ExpectedRevision, d.Revision); err != nil {
			return "", err
		}
		d.Summary = p.Summary
		d.UnfinishedReason = p.UnfinishedReason
		d.TomorrowNote = p.TomorrowNote
		e.touchDay(d)
		return d.Date, nil
	}
	if cmd.Type == "CreateTask" {
		if err := checkRevision(cmd.ExpectedRevision, "0"); err != nil {
			return "", err
		}
		if !textOK(p.Title, 2000, false) {
			return "", Fail("INVALID_INPUT")
		}
		if p.Date != "" && (!ValidDate(p.Date) || p.Date < e.s.Today) {
			return "", Fail("INVALID_DATE")
		}
		c := &Chain{ID: e.id(), DefinitionID: e.id(), State: "active", Location: "pool", Revision: "1", Stamp: e.stamp}
		d := &Definition{ID: c.DefinitionID, ChainID: c.ID, Version: 1, Title: strings.TrimSpace(p.Title), Description: p.Description, PlannedSubtasks: []PlannedSubtask{}, Stamp: e.stamp}
		e.chains[c.ID] = c
		e.definitions[d.ID] = d
		if p.Date != "" {
			e.newTrace(c, p.Date)
		}
		return c.ID, nil
	}
	var c *Chain
	var t *Trace
	var sub *Subtask
	if p.SubtaskID != "" {
		sub = e.subtasks[p.SubtaskID]
		if sub == nil {
			return "", Fail("NOT_FOUND")
		}
		t = e.traces[sub.TraceID]
	} else if p.TraceID != "" {
		t = e.traces[p.TraceID]
		if t == nil {
			return "", Fail("NOT_FOUND")
		}
	}
	if t != nil {
		c = e.chains[t.ChainID]
	} else {
		c = e.chains[p.ChainID]
	}
	if c == nil {
		return "", Fail("NOT_FOUND")
	}
	if err := checkRevision(cmd.ExpectedRevision, c.Revision); err != nil {
		return "", err
	}
	if c.State != "active" && cmd.Type != "ReactivateChain" {
		return "", Fail("CHAIN_ABANDONED")
	}
	if cmd.Type == "EditTask" {
		if !textOK(p.Title, 2000, true) {
			return "", Fail("INVALID_INPUT")
		}
		if c.Location != "pool" && c.Location != "trace" {
			return "", Fail("INVALID_TRANSITION")
		}
		a := e.active(c.ID)
		if a != nil {
			if err := e.pending(a); err != nil {
				return "", err
			}
		}
		d := e.definitions[c.DefinitionID]
		historical := false
		for _, trace := range e.traces {
			if trace.DefinitionID == d.ID && trace.Status != "pending" && trace.Status != "cancelledDraft" {
				historical = true
			}
		}
		if historical {
			nd := *d
			nd.ID = e.id()
			nd.Version++
			nd.Stamp = e.stamp
			d = &nd
			e.definitions[d.ID] = d
			c.DefinitionID = d.ID
			if a != nil {
				a.DefinitionID = d.ID
			}
		}
		d.Title = strings.TrimSpace(p.Title)
		d.Description = p.Description
		e.touch(&d.Stamp)
		if a != nil {
			a.Description = p.Description
			e.touch(&a.Stamp)
		}
		e.touchChain(c)
		return c.ID, nil
	}
	if cmd.Type == "ScheduleTask" {
		if c.Location != "pool" || e.active(c.ID) != nil {
			return "", Fail("INVALID_TRANSITION")
		}
		if !ValidDate(p.Date) || p.Date < e.s.Today {
			return "", Fail("INVALID_DATE")
		}
		t = e.newTrace(c, p.Date)
		for _, planned := range e.definitions[c.DefinitionID].PlannedSubtasks {
			s := &Subtask{ID: e.id(), TraceID: t.ID, LineageID: planned.LineageID, Title: planned.Title, Difficulty: planned.Difficulty, Position: planned.Position, Status: "pending", Stamp: e.stamp}
			e.subtasks[s.ID] = s
		}
		e.touchChain(c)
		return t.ID, nil
	}
	if t == nil {
		return "", Fail("INVALID_INPUT")
	}
	switch cmd.Type {
	case "CompleteTrace", "UndoCompleteTrace":
		if err := e.unlocked(t); err != nil {
			return "", err
		}
		if t.Date != e.s.Today {
			return "", Fail("FUTURE_DAY")
		}
		if cmd.Type == "CompleteTrace" {
			if t.Status != "pending" {
				return "", Fail("INVALID_TRANSITION")
			}
			for _, s := range e.subtasks {
				if s.TraceID == t.ID && (s.Status == "pending" || s.Status == "unfinished" || s.Status == "deferred") {
					return "", Fail("OPEN_SUBTASKS")
				}
			}
			t.Status = "completed"
			t.CompletedAt = e.stamp.UpdatedAt
			c.Location = "completed"
		} else {
			if t.Status != "completed" {
				return "", Fail("INVALID_TRANSITION")
			}
			t.Status = "pending"
			t.CompletedAt = ""
			c.Location = "trace"
		}
	case "DeferTrace", "ContinueTrace":
		if !ValidDate(p.Date) || p.Date < e.s.Today || p.Date <= t.Date {
			return "", Fail("INVALID_DATE")
		}
		if e.latest(c.ID) != t {
			return "", Fail("INVALID_TRANSITION")
		}
		if cmd.Type == "DeferTrace" {
			if err := e.pending(t); err != nil {
				return "", err
			}
			if t.Date != e.s.Today {
				return "", Fail("INVALID_TRANSITION")
			}
		} else {
			if t.Status != "unfinished" || t.Date >= e.s.Today || e.active(c.ID) != nil || c.Location != "followup" {
				return "", Fail("INVALID_TRANSITION")
			}
		}
		progress := e.progress(t)
		next := e.newTrace(c, p.Date)
		next.Description = t.Description
		next.CarriedFromTraceID = t.ID
		next.ProgressFloor = progress
		next.ManualProgress = progress
		next.ContinuationSeq = t.ContinuationSeq
		if cmd.Type == "ContinueTrace" {
			next.ContinuationSeq++
		} else {
			t.Status = "deferred"
			t.SettledAt = e.stamp.UpdatedAt
			e.touch(&t.Stamp)
		}
		oldSubs := e.orderedSubtasks(t.ID)
		position := 0
		for _, s := range oldSubs {
			if s.Status != "pending" && s.Status != "unfinished" {
				continue
			}
			n := *s
			position++
			n.Position = position
			n.ID = e.id()
			n.TraceID = next.ID
			n.Status = "pending"
			n.CarriedFromSubtaskID = s.ID
			n.Stamp = e.stamp
			n.CompletedAt = ""
			n.SettledAt = ""
			e.subtasks[n.ID] = &n
			if cmd.Type == "DeferTrace" {
				s.Status = "deferred"
				s.SettledAt = e.stamp.UpdatedAt
				e.touch(&s.Stamp)
			}
		}
		e.touchChain(c)
		return next.ID, nil
	case "RescheduleTrace":
		if err := e.pending(t); err != nil {
			return "", err
		}
		if t.Date <= e.s.Today || !ValidDate(p.Date) || p.Date <= e.s.Today {
			return "", Fail("INVALID_DATE")
		}
		t.Date = p.Date
		t.Priority = 1
		for _, other := range e.traces {
			if other.ID != t.ID && other.Date == p.Date && other.Priority >= t.Priority {
				t.Priority = other.Priority + 1
			}
		}
		e.day(p.Date)
	case "ReturnToPool":
		if err := e.pending(t); err != nil {
			return "", err
		}
		d := *e.definitions[c.DefinitionID]
		d.ID = e.id()
		d.Version++
		d.Description = t.Description
		d.Stamp = e.stamp
		d.PlannedSubtasks = []PlannedSubtask{}
		for _, s := range e.orderedSubtasks(t.ID) {
			if s.Status == "pending" || s.Status == "unfinished" {
				d.PlannedSubtasks = append(d.PlannedSubtasks, PlannedSubtask{ID: e.id(), LineageID: s.LineageID, Title: s.Title, Difficulty: s.Difficulty, Position: len(d.PlannedSubtasks) + 1})
			}
		}
		e.definitions[d.ID] = &d
		c.DefinitionID = d.ID
		c.Location = "pool"
		t.Status = "returnedToPool"
		if t.Date > e.s.Today {
			t.Status = "cancelledDraft"
		}
		t.SettledAt = e.stamp.UpdatedAt
	case "AbandonChain":
		if a := e.active(c.ID); a != nil {
			t = a
		}
		if t.Status != "pending" && t.Status != "unfinished" {
			return "", Fail("INVALID_TRANSITION")
		}
		if t.Status == "unfinished" && e.latest(c.ID) != t {
			return "", Fail("INVALID_TRANSITION")
		}
		t.Status = "abandoned"
		t.SettledAt = e.stamp.UpdatedAt
		c.State = "abandoned"
		c.Location = "abandoned"
	case "ReactivateChain":
		if c.State != "abandoned" || t.Status != "abandoned" || e.active(c.ID) != nil {
			return "", Fail("INVALID_TRANSITION")
		}
		c.State = "active"
		if t.Date < e.s.Today || e.day(t.Date).LockedAt != "" {
			t.Status = "unfinished"
			c.Location = "followup"
		} else {
			t.Status = "pending"
			t.SettledAt = ""
			c.Location = "trace"
		}
	case "AddSubtask":
		if err := e.pending(t); err != nil {
			return "", err
		}
		if !textOK(p.Title, 2000, false) || !difficulty(p.Difficulty) {
			return "", Fail("INVALID_INPUT")
		}
		s := &Subtask{ID: e.id(), TraceID: t.ID, LineageID: e.id(), Title: strings.TrimSpace(p.Title), Difficulty: p.Difficulty, Position: len(e.orderedSubtasks(t.ID)) + 1, Status: "pending", Stamp: e.stamp}
		e.subtasks[s.ID] = s
		e.touchChain(c)
		return s.ID, nil
	case "CompleteSubtask", "UndoCompleteSubtask", "AbandonSubtask", "DeleteSubtask", "EditSubtask":
		if err := e.pending(t); err != nil {
			return "", err
		}
		if sub == nil || sub.Status == "cancelledDraft" {
			return "", Fail("NOT_FOUND")
		}
		if cmd.Type == "CompleteSubtask" || cmd.Type == "UndoCompleteSubtask" || cmd.Type == "AbandonSubtask" {
			if t.Date != e.s.Today {
				return "", Fail("FUTURE_DAY")
			}
		}
		switch cmd.Type {
		case "CompleteSubtask":
			if sub.Status != "pending" {
				return "", Fail("INVALID_TRANSITION")
			}
			sub.Status = "completed"
			sub.CompletedAt = e.stamp.UpdatedAt
		case "UndoCompleteSubtask":
			if sub.Status != "completed" {
				return "", Fail("INVALID_TRANSITION")
			}
			sub.Status = "pending"
			sub.CompletedAt = ""
		case "AbandonSubtask":
			if sub.Status != "pending" {
				return "", Fail("INVALID_TRANSITION")
			}
			sub.Status = "abandoned"
			sub.SettledAt = e.stamp.UpdatedAt
		case "DeleteSubtask":
			sub.Status = "cancelledDraft"
			sub.CompletedAt = ""
			sub.SettledAt = e.stamp.UpdatedAt
		case "EditSubtask":
			if !textOK(p.Title, 2000, false) || !difficulty(p.Difficulty) {
				return "", Fail("INVALID_INPUT")
			}
			sub.Title = strings.TrimSpace(p.Title)
			sub.Difficulty = p.Difficulty
		}
		e.touch(&sub.Stamp)
		e.touchChain(c)
		return sub.ID, nil
	case "UpdateProgress":
		if err := e.pending(t); err != nil {
			return "", err
		}
		if t.Date != e.s.Today {
			return "", Fail("FUTURE_DAY")
		}
		for _, s := range e.subtasks {
			if e.traces[s.TraceID].ChainID == c.ID && s.Status != "cancelledDraft" {
				return "", Fail("WEIGHTED_PROGRESS")
			}
		}
		if p.Progress < 0 || p.Progress > 100 {
			return "", Fail("INVALID_INPUT")
		}
		t.ManualProgress = max(p.Progress, t.ProgressFloor)
	default:
		return "", Fail("COMMAND_UNSUPPORTED")
	}
	e.touch(&t.Stamp)
	e.touchChain(c)
	return t.ID, nil
}
func (e *engine) ideaCommand(c Command) (string, error) {
	p := c.Payload
	if c.Type == "CreateIdea" {
		if err := checkRevision(c.ExpectedRevision, "0"); err != nil {
			return "", err
		}
		if !textOK(p.Body, 65536, false) {
			return "", Fail("INVALID_INPUT")
		}
		v := &Idea{ID: e.id(), Revision: "1", Body: strings.TrimSpace(p.Body), Stamp: e.stamp}
		e.ideas[v.ID] = v
		return v.ID, nil
	}
	v := e.ideas[p.IdeaID]
	if v == nil || v.DeletedAt != "" {
		return "", Fail("NOT_FOUND")
	}
	if err := checkRevision(c.ExpectedRevision, v.Revision); err != nil {
		return "", err
	}
	switch c.Type {
	case "EditIdea":
		if !textOK(p.Body, 65536, false) {
			return "", Fail("INVALID_INPUT")
		}
		v.Body = strings.TrimSpace(p.Body)
	case "DeleteIdea":
		v.Body = ""
		v.PinnedAt = ""
		v.DeletedAt = e.stamp.UpdatedAt
	case "PinIdea":
		v.PinnedAt = e.stamp.UpdatedAt
	case "UnpinIdea":
		v.PinnedAt = ""
	default:
		return "", Fail("COMMAND_UNSUPPORTED")
	}
	v.Revision = bump(v.Revision)
	e.touch(&v.Stamp)
	return v.ID, nil
}
func (e *engine) orderedSubtasks(trace string) []*Subtask {
	var out []*Subtask
	for _, s := range e.subtasks {
		if s.TraceID == trace {
			out = append(out, s)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Position != out[j].Position {
			return out[i].Position < out[j].Position
		}
		return out[i].ID < out[j].ID
	})
	return out
}
func (e *engine) rawProgress(t *Trace) int {
	if t.Status == "completed" {
		return 100
	}
	weights := map[string]int{}
	done := map[string]bool{}
	for _, sub := range e.subtasks {
		st := e.traces[sub.TraceID]
		if st.ChainID != t.ChainID || st.Date > t.Date || st.Status == "cancelledDraft" || sub.Status == "cancelledDraft" {
			continue
		}
		weights[sub.LineageID] = max(weights[sub.LineageID], weight(sub.Difficulty))
		if sub.Status == "completed" {
			done[sub.LineageID] = true
		}
	}
	total, completed := 0, 0
	for id, w := range weights {
		total += w
		if done[id] {
			completed += w
		}
	}
	if total == 0 {
		return t.ManualProgress
	}
	return int(float64(completed)*100/float64(total) + 0.5)
}
func (e *engine) progress(t *Trace) int {
	floor := t.ProgressFloor
	for _, prior := range e.traces {
		if prior.ChainID == t.ChainID && prior.Status != "cancelledDraft" && (prior.Date < t.Date || (prior.Date == t.Date && prior.ContinuationSeq < t.ContinuationSeq)) {
			floor = max(floor, e.rawProgress(prior))
		}
	}
	return max(e.rawProgress(t), floor)
}
func (e *engine) snapshot() Snapshot {
	s := e.s
	s.Chains = []Chain{}
	s.Definitions = []Definition{}
	s.Traces = []Trace{}
	s.Subtasks = []Subtask{}
	s.Days = []Day{}
	s.Ideas = []Idea{}
	for _, v := range e.chains {
		s.Chains = append(s.Chains, *v)
	}
	for _, v := range e.definitions {
		s.Definitions = append(s.Definitions, *v)
	}
	for _, v := range e.traces {
		v.Progress = e.progress(v)
		s.Traces = append(s.Traces, *v)
	}
	for _, v := range e.subtasks {
		s.Subtasks = append(s.Subtasks, *v)
	}
	for _, v := range e.days {
		s.Days = append(s.Days, *v)
	}
	for _, v := range e.ideas {
		s.Ideas = append(s.Ideas, *v)
	}
	sort.Slice(s.Chains, func(i, j int) bool { return s.Chains[i].ID < s.Chains[j].ID })
	sort.Slice(s.Definitions, func(i, j int) bool { return s.Definitions[i].ID < s.Definitions[j].ID })
	sort.Slice(s.Traces, func(i, j int) bool {
		if s.Traces[i].Date != s.Traces[j].Date {
			return s.Traces[i].Date < s.Traces[j].Date
		}
		if s.Traces[i].Priority != s.Traces[j].Priority {
			return s.Traces[i].Priority < s.Traces[j].Priority
		}
		return s.Traces[i].ID < s.Traces[j].ID
	})
	sort.Slice(s.Subtasks, func(i, j int) bool {
		if s.Subtasks[i].Position != s.Subtasks[j].Position {
			return s.Subtasks[i].Position < s.Subtasks[j].Position
		}
		return s.Subtasks[i].ID < s.Subtasks[j].ID
	})
	sort.Slice(s.Days, func(i, j int) bool { return s.Days[i].Date < s.Days[j].Date })
	sort.Slice(s.Ideas, func(i, j int) bool {
		if s.Ideas[i].CreatedAt != s.Ideas[j].CreatedAt {
			return s.Ideas[i].CreatedAt > s.Ideas[j].CreatedAt
		}
		return s.Ideas[i].ID < s.Ideas[j].ID
	})
	return s
}

// Settle 在读取与提交前补结算；历史 review 仍可独立补写。
func Settle(s Snapshot, now time.Time, id func() string) (Snapshot, bool, error) {
	e, err := load(s, now, id)
	if err != nil {
		return s, false, err
	}
	changed := false
	for _, d := range e.days {
		if d.Date >= s.Today || d.LockedAt != "" {
			continue
		}
		changed = true
		for _, t := range e.traces {
			if t.Date != d.Date || t.Status != "pending" {
				continue
			}
			t.Status = "unfinished"
			t.SettledAt = e.stamp.UpdatedAt
			e.touch(&t.Stamp)
			c := e.chains[t.ChainID]
			c.Location = "followup"
			e.touchChain(c)
			for _, sub := range e.subtasks {
				if sub.TraceID == t.ID && sub.Status == "pending" {
					sub.Status = "unfinished"
					sub.SettledAt = e.stamp.UpdatedAt
					e.touch(&sub.Stamp)
				}
			}
		}
		d.LockedAt = e.stamp.UpdatedAt
		e.touchDay(d)
	}
	out := e.snapshot()
	if changed {
		out.FrontierBits = e.stamp.MutationBits
	}
	return out, changed, Validate(out)
}

func Project(s Snapshot) Snapshot {
	e, err := load(s, time.Unix(978307200, 0), func() string { return "" })
	if err != nil {
		return s
	}
	return e.snapshot()
}
