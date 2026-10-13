package core

import (
	"encoding/json"
	"errors"
	"math"
	"strconv"
	"time"
)

type Error struct {
	Code string `json:"code"`
}

func (e *Error) Error() string { return e.Code }
func Fail(code string) error   { return &Error{Code: code} }
func ErrorCode(err error) string {
	var e *Error
	if errors.As(err, &e) {
		return e.Code
	}
	return "INTERNAL"
}

type Command struct {
	InstanceID       string  `json:"instance_id"`
	InstanceEpoch    string  `json:"instance_epoch"`
	DatasetID        string  `json:"dataset_id"`
	CommandID        string  `json:"command_id"`
	SchemaVersion    int     `json:"schema_version"`
	Type             string  `json:"type"`
	ExpectedRevision string  `json:"expected_revision"`
	Payload          Payload `json:"payload"`
}
type Payload struct {
	ChainID          string `json:"chain_id,omitempty"`
	TraceID          string `json:"trace_id,omitempty"`
	SubtaskID        string `json:"subtask_id,omitempty"`
	IdeaID           string `json:"idea_id,omitempty"`
	Title            string `json:"title,omitempty"`
	Description      string `json:"description,omitempty"`
	Date             string `json:"date,omitempty"`
	Body             string `json:"body,omitempty"`
	Difficulty       string `json:"difficulty,omitempty"`
	Progress         int    `json:"progress,omitempty"`
	Summary          string `json:"summary,omitempty"`
	UnfinishedReason string `json:"unfinished_reason,omitempty"`
	TomorrowNote     string `json:"tomorrow_note,omitempty"`
}
type Receipt struct {
	CommandID    string `json:"command_id"`
	Status       string `json:"status"`
	Sequence     string `json:"sequence"`
	EntityID     string `json:"entity_id"`
	MutationBits string `json:"mutation_bits"`
}
type Snapshot struct {
	SchemaVersion int          `json:"schema_version"`
	InstanceID    string       `json:"instance_id"`
	InstanceEpoch string       `json:"instance_epoch"`
	DatasetID     string       `json:"dataset_id"`
	OwnerID       string       `json:"owner_id"`
	Sequence      string       `json:"sequence"`
	FrontierBits  string       `json:"frontier_bits"`
	Today         string       `json:"today"`
	Timezone      string       `json:"timezone"`
	Chains        []Chain      `json:"chains"`
	Definitions   []Definition `json:"definitions"`
	Traces        []Trace      `json:"traces"`
	Subtasks      []Subtask    `json:"subtasks"`
	Days          []Day        `json:"days"`
	Ideas         []Idea       `json:"ideas"`
}
type Stamp struct {
	CreatedAt    string `json:"created_at"`
	UpdatedAt    string `json:"updated_at"`
	MutationBits string `json:"mutation_bits"`
}
type Chain struct {
	ID           string `json:"id"`
	DefinitionID string `json:"definition_id"`
	State        string `json:"state"`
	Location     string `json:"location"`
	Revision     string `json:"revision"`
	Stamp
}
type Definition struct {
	ID              string           `json:"id"`
	ChainID         string           `json:"chain_id"`
	Version         int              `json:"version"`
	Title           string           `json:"title"`
	Description     string           `json:"description"`
	PlannedSubtasks []PlannedSubtask `json:"planned_subtasks"`
	Stamp
}
type PlannedSubtask struct {
	ID         string `json:"id"`
	LineageID  string `json:"lineage_id"`
	Title      string `json:"title"`
	Difficulty string `json:"difficulty"`
	Position   int    `json:"position"`
}
type Trace struct {
	ID                 string `json:"id"`
	ChainID            string `json:"chain_id"`
	DefinitionID       string `json:"definition_id"`
	Date               string `json:"date"`
	Status             string `json:"status"`
	Priority           int    `json:"priority"`
	ContinuationSeq    int    `json:"continuation_seq"`
	Description        string `json:"description"`
	CarriedFromTraceID string `json:"carried_from_trace_id,omitempty"`
	ProgressFloor      int    `json:"progress_floor"`
	ManualProgress     int    `json:"manual_progress"`
	Progress           int    `json:"progress"`
	CompletedAt        string `json:"completed_at,omitempty"`
	SettledAt          string `json:"settled_at,omitempty"`
	Stamp
}
type Subtask struct {
	ID                   string `json:"id"`
	TraceID              string `json:"trace_id"`
	LineageID            string `json:"lineage_id"`
	CarriedFromSubtaskID string `json:"carried_from_subtask_id,omitempty"`
	Title                string `json:"title"`
	Difficulty           string `json:"difficulty"`
	Status               string `json:"status"`
	Position             int    `json:"position"`
	CompletedAt          string `json:"completed_at,omitempty"`
	SettledAt            string `json:"settled_at,omitempty"`
	Stamp
}
type Day struct {
	Date             string `json:"date"`
	Revision         string `json:"revision"`
	LockedAt         string `json:"locked_at,omitempty"`
	Summary          string `json:"summary"`
	UnfinishedReason string `json:"unfinished_reason"`
	TomorrowNote     string `json:"tomorrow_note"`
	Stamp
}
type Idea struct {
	ID        string `json:"id"`
	Revision  string `json:"revision"`
	Body      string `json:"body"`
	PinnedAt  string `json:"pinned_at,omitempty"`
	DeletedAt string `json:"deleted_at,omitempty"`
	Stamp
}

// 原生使用自 2001-01-01 起的 Double 秒数；JSON 使用完整 UInt64 十进制字符串。
func NextMutation(reference time.Time, frontier string) (string, error) {
	seconds := float64(reference.Unix()-978307200) + float64(reference.Nanosecond())/1e9
	if frontier != "" {
		bits, err := strconv.ParseUint(frontier, 10, 64)
		if err != nil {
			return "", Fail("INVALID_CLOCK")
		}
		prior := math.Float64frombits(bits)
		if math.IsNaN(prior) || math.IsInf(prior, 0) {
			return "", Fail("INVALID_CLOCK")
		}
		if prior >= seconds {
			seconds = math.Nextafter(prior, math.Inf(1))
		}
	}
	if math.IsNaN(seconds) || math.IsInf(seconds, 0) {
		return "", Fail("INVALID_CLOCK")
	}
	return strconv.FormatUint(math.Float64bits(seconds), 10), nil
}

// MutationTimeLayout 的固定九位小数让同一 UTC 时间投影具有稳定展示排序。
const MutationTimeLayout = "2006-01-02T15:04:05.000000000Z"

// MutationTime 只生成人类可读投影；精确因果身份始终保留在原始 bits。
func MutationTime(bits string) (time.Time, error) {
	n, err := strconv.ParseUint(bits, 10, 64)
	if err != nil {
		return time.Time{}, Fail("INVALID_CLOCK")
	}
	seconds := math.Float64frombits(n)
	// RFC 3339 只支持 0001–9999 年；先限制范围，避免浮点到整数溢出。
	if math.IsNaN(seconds) || math.IsInf(seconds, 0) || seconds < -63113904000 || seconds >= 252423993600 {
		return time.Time{}, Fail("INVALID_CLOCK")
	}
	whole, fraction := math.Modf(seconds)
	instant := time.Unix(int64(whole)+978307200, int64(math.Round(fraction*1e9))).UTC()
	if instant.Year() < 1 || instant.Year() > 9999 {
		return time.Time{}, Fail("INVALID_CLOCK")
	}
	return instant, nil
}
func ValidDate(date string) bool {
	t, err := time.Parse("2006-01-02", date)
	return err == nil && t.Format("2006-01-02") == date && date >= "0001-01-01"
}
func Clone(s Snapshot) Snapshot {
	b, _ := json.Marshal(s)
	var c Snapshot
	_ = json.Unmarshal(b, &c)
	return c
}
