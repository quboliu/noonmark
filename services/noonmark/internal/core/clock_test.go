package core

import (
	"math"
	"strconv"
	"testing"
	"time"
)

func TestMutationClockUsesReferenceDateExactNextUp(t *testing.T) {
	reference := time.Date(2001, 1, 1, 0, 0, 1, 0, time.UTC)
	bits, err := NextMutation(reference, "")
	if err != nil {
		t.Fatal(err)
	}
	if bits != strconv.FormatUint(math.Float64bits(1), 10) {
		t.Fatal("wrong Swift reference date")
	}
	next, err := NextMutation(reference, bits)
	if err != nil {
		t.Fatal(err)
	}
	n, _ := strconv.ParseUint(next, 10, 64)
	if math.Float64frombits(n) != math.Nextafter(1, math.Inf(1)) {
		t.Fatal("frontier does not advance exactly one Double")
	}
	for _, f := range []float64{math.Inf(1), math.NaN(), math.MaxFloat64} {
		_, err = NextMutation(reference, strconv.FormatUint(math.Float64bits(f), 10))
		if err == nil {
			t.Fatal("accepted invalid or exhausted frontier")
		}
	}
}

func TestCivilDateValidation(t *testing.T) {
	for _, d := range []string{"2026-02-29", "2026-1-02", "0000-01-01", "2026-13-01"} {
		if ValidDate(d) {
			t.Fatal("invalid date accepted")
		}
	}
	for _, d := range []string{"2024-02-29", "2026-12-31"} {
		if !ValidDate(d) {
			t.Fatal("valid date rejected")
		}
	}
}

func TestMutationProjectionRoundTripsModernExactBits(t *testing.T) {
	base := time.Date(2026, 10, 12, 12, 0, 0, 123456789, time.UTC)
	bits, err := NextMutation(base, "")
	if err != nil {
		t.Fatal(err)
	}
	var previous time.Time
	for range 100 {
		instant, err := MutationTime(bits)
		if err != nil {
			t.Fatal(err)
		}
		if !previous.IsZero() && !instant.After(previous) {
			t.Fatal("modern adjacent Double timestamps lost ordering")
		}
		seconds := float64(instant.Unix()-978307200) + float64(instant.Nanosecond())/1e9
		if strconv.FormatUint(math.Float64bits(seconds), 10) != bits {
			t.Fatal("readable projection no longer describes exact bits")
		}
		previous = instant
		bits, err = NextMutation(base.Add(-time.Hour), bits)
		if err != nil {
			t.Fatal(err)
		}
	}
}

func TestMutationProjectionRejectsUnrepresentableTime(t *testing.T) {
	for _, f := range []float64{math.Inf(1), math.NaN(), math.MaxFloat64, -math.MaxFloat64, 252423993600, -63113904001} {
		if _, err := MutationTime(strconv.FormatUint(math.Float64bits(f), 10)); err == nil {
			t.Fatal("accepted unrepresentable mutation projection")
		}
	}
	for _, reference := range []time.Time{time.Date(1, 1, 1, 0, 0, 0, 0, time.UTC), time.Date(9999, 12, 31, 23, 59, 59, 0, time.UTC), time.Date(2000, 12, 31, 23, 59, 59, 250000000, time.UTC)} {
		bits, err := NextMutation(reference, "")
		if err != nil {
			t.Fatal(err)
		}
		instant, err := MutationTime(bits)
		if err != nil || !instant.Equal(reference) {
			t.Fatal("valid boundary projection failed")
		}
	}
}

func TestMutationStampUsesAllocatedInstant(t *testing.T) {
	wall := time.Date(2026, 10, 12, 8, 0, 0, 0, time.UTC)
	frontier, err := NextMutation(wall.Add(time.Hour), "")
	if err != nil {
		t.Fatal(err)
	}
	e, err := load(Snapshot{FrontierBits: frontier}, wall, func() string { return "unused" })
	if err != nil {
		t.Fatal(err)
	}
	projected, err := MutationTime(e.stamp.MutationBits)
	if err != nil {
		t.Fatal(err)
	}
	if e.stamp.CreatedAt != projected.Format(MutationTimeLayout) || e.stamp.UpdatedAt != e.stamp.CreatedAt {
		t.Fatal("mutation stamp used the raw wall clock instead of the allocated instant")
	}
}

func TestMutationStampCanonicalOrdering(t *testing.T) {
	wall := time.Date(2026, 10, 12, 8, 0, 0, 0, time.UTC)
	frontier, _ := NextMutation(wall.Add(-time.Second), "")
	first, err := load(Snapshot{FrontierBits: frontier}, wall, func() string { return "unused" })
	if err != nil {
		t.Fatal(err)
	}
	second, err := load(Snapshot{FrontierBits: first.stamp.MutationBits}, wall, func() string { return "unused" })
	if err != nil {
		t.Fatal(err)
	}
	if first.stamp.CreatedAt >= second.stamp.CreatedAt {
		t.Fatal("canonical projection does not preserve presentation sort order")
	}
}
