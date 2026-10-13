package core

import (
	"encoding/hex"
	"math"
	"strconv"
	"strings"
	"time"
)

func ValidID(s string) bool {
	if len(s) != 36 || s[8] != '-' || s[13] != '-' || s[18] != '-' || s[23] != '-' {
		return false
	}
	_, err := hex.DecodeString(strings.ReplaceAll(s, "-", ""))
	return err == nil && s == strings.ToLower(s)
}
func validRevision(s string, zero bool) bool {
	n, err := strconv.ParseUint(s, 10, 63)
	return err == nil && strconv.FormatUint(n, 10) == s && (zero || n > 0)
}
func validBits(s string) (float64, bool) {
	n, err := strconv.ParseUint(s, 10, 64)
	f := math.Float64frombits(n)
	return f, err == nil && strconv.FormatUint(n, 10) == s && !math.IsNaN(f) && !math.IsInf(f, 0)
}
func oneOf(s string, values ...string) bool {
	for _, v := range values {
		if s == v {
			return true
		}
	}
	return false
}

// Validate 对账完整领域引用与当前唯一位置；不对丢失引用猜测修复。
func Validate(s Snapshot) error {
	bad := func() error { return Fail("INVARIANT_VIOLATION") }
	if s.SchemaVersion != 1 || !ValidID(s.InstanceID) || !ValidID(s.InstanceEpoch) || !ValidID(s.DatasetID) || !ValidID(s.OwnerID) || !ValidDate(s.Today) || !validRevision(s.Sequence, true) {
		return bad()
	}
	if _, err := time.LoadLocation(s.Timezone); err != nil {
		return bad()
	}
	frontier, ok := validBits(s.FrontierBits)
	if !ok {
		return bad()
	}
	if _, err := MutationTime(s.FrontierBits); err != nil {
		return bad()
	}
	stampOK := func(st Stamp) bool {
		bits, ok := validBits(st.MutationBits)
		if !ok || bits > frontier {
			return false
		}
		created, a := time.Parse(time.RFC3339Nano, st.CreatedAt)
		updated, b := time.Parse(time.RFC3339Nano, st.UpdatedAt)
		projected, err := MutationTime(st.MutationBits)
		return a == nil && b == nil && err == nil && !created.After(updated) && updated.Equal(projected) && st.CreatedAt == created.UTC().Format(MutationTimeLayout) && st.UpdatedAt == projected.Format(MutationTimeLayout)
	}
	chains := map[string]Chain{}
	defs := map[string]Definition{}
	traces := map[string]Trace{}
	days := map[string]Day{}
	subs := map[string]Subtask{}
	active := map[string]int{}
	completed := map[string]int{}
	ideas := map[string]bool{}
	for _, d := range s.Days {
		if !ValidDate(d.Date) || !validRevision(d.Revision, true) || !stampOK(d.Stamp) {
			return bad()
		}
		if _, ok := days[d.Date]; ok {
			return bad()
		}
		if d.LockedAt != "" {
			if _, err := time.Parse(time.RFC3339Nano, d.LockedAt); err != nil {
				return bad()
			}
		}
		days[d.Date] = d
	}
	for _, c := range s.Chains {
		if !ValidID(c.ID) || !validRevision(c.Revision, false) || !oneOf(c.State, "active", "abandoned") || !oneOf(c.Location, "pool", "trace", "followup", "completed", "abandoned") || !stampOK(c.Stamp) {
			return bad()
		}
		if _, ok := chains[c.ID]; ok {
			return bad()
		}
		chains[c.ID] = c
	}
	versions := map[string]bool{}
	for _, d := range s.Definitions {
		c, ok := chains[d.ChainID]
		if !ok || !ValidID(d.ID) || d.Version < 1 || !textOK(d.Title, 2000, true) || !textOK(d.Description, 65536, true) || !stampOK(d.Stamp) {
			return bad()
		}
		_ = c
		if _, ok := defs[d.ID]; ok {
			return bad()
		}
		key := d.ChainID + ":" + strconv.Itoa(d.Version)
		if versions[key] {
			return bad()
		}
		versions[key] = true
		for _, p := range d.PlannedSubtasks {
			if !ValidID(p.ID) || !ValidID(p.LineageID) || !textOK(p.Title, 2000, false) || !difficulty(p.Difficulty) || p.Position < 1 {
				return bad()
			}
		}
		defs[d.ID] = d
	}
	for _, c := range chains {
		d, ok := defs[c.DefinitionID]
		if !ok || d.ChainID != c.ID {
			return bad()
		}
	}
	for _, t := range s.Traces {
		c, exists := chains[t.ChainID]
		d, ok := defs[t.DefinitionID]
		day, hasDay := days[t.Date]
		if !exists || !ok || !hasDay || d.ChainID != c.ID || !ValidID(t.ID) || !stampOK(t.Stamp) || t.Priority < 1 || t.ContinuationSeq < 0 || t.ProgressFloor < 0 || t.ProgressFloor > 100 || t.ManualProgress < 0 || t.ManualProgress > 100 || !oneOf(t.Status, "pending", "completed", "unfinished", "deferred", "returnedToPool", "cancelledDraft", "abandoned") {
			return bad()
		}
		if _, ok := traces[t.ID]; ok {
			return bad()
		}
		if t.Status == "pending" {
			active[c.ID]++
			if day.LockedAt != "" {
				return bad()
			}
		}
		if t.Status == "completed" {
			completed[c.ID]++
			if t.CompletedAt == "" {
				return bad()
			}
		}
		traces[t.ID] = t
	}
	carried := map[string]bool{}
	for _, t := range traces {
		if t.CarriedFromTraceID != "" {
			source, ok := traces[t.CarriedFromTraceID]
			if !ok || source.ChainID != t.ChainID || source.Date >= t.Date || !oneOf(source.Status, "deferred", "unfinished", "abandoned") {
				return bad()
			}
			if carried[source.ID] {
				return bad()
			}
			carried[source.ID] = true
		}
	}
	for _, c := range chains {
		if active[c.ID] > 1 || completed[c.ID] > 1 {
			return bad()
		}
		switch c.Location {
		case "trace":
			if active[c.ID] != 1 || c.State != "active" {
				return bad()
			}
		case "completed":
			if completed[c.ID] != 1 || active[c.ID] != 0 || c.State != "active" {
				return bad()
			}
		case "abandoned":
			if c.State != "abandoned" || active[c.ID] != 0 {
				return bad()
			}
		default:
			if active[c.ID] != 0 || c.State != "active" {
				return bad()
			}
		}
	}
	for _, sub := range s.Subtasks {
		if _, ok := traces[sub.TraceID]; !ok {
			return bad()
		}
		if !ValidID(sub.ID) || !ValidID(sub.LineageID) || !textOK(sub.Title, 2000, false) || !difficulty(sub.Difficulty) || sub.Position < 1 || !oneOf(sub.Status, "pending", "completed", "unfinished", "deferred", "abandoned", "cancelledDraft") || !stampOK(sub.Stamp) {
			return bad()
		}
		if _, ok := subs[sub.ID]; ok {
			return bad()
		}
		subs[sub.ID] = sub
	}
	for _, sub := range subs {
		if sub.CarriedFromSubtaskID != "" {
			source, ok := subs[sub.CarriedFromSubtaskID]
			if !ok || source.LineageID != sub.LineageID || traces[source.TraceID].ChainID != traces[sub.TraceID].ChainID || traces[source.TraceID].Date >= traces[sub.TraceID].Date {
				return bad()
			}
		}
	}
	for _, v := range s.Ideas {
		if !ValidID(v.ID) || ideas[v.ID] || !validRevision(v.Revision, false) || !stampOK(v.Stamp) {
			return bad()
		}
		if v.DeletedAt != "" {
			if v.Body != "" || v.PinnedAt != "" {
				return bad()
			}
		} else if !textOK(v.Body, 65536, false) {
			return bad()
		}
		ideas[v.ID] = true
	}
	return nil
}
