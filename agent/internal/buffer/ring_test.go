package buffer

import (
	"testing"
	"time"

	"github.com/Janderov/monitoring/agent/internal/collect"
)

func at(sec int) collect.Snapshot { return collect.Snapshot{Time: time.Unix(int64(sec), 0)} }

func secs(s []collect.Snapshot) []int64 {
	out := make([]int64, len(s))
	for i, v := range s {
		out[i] = v.Time.Unix()
	}
	return out
}

func equal(a, b []int64) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestEmpty(t *testing.T) {
	r := New(3)
	if _, ok := r.Latest(); ok {
		t.Error("Latest on empty ring returned ok")
	}
	if got := r.Since(time.Time{}, 0); len(got) != 0 {
		t.Errorf("Since on empty ring = %v", got)
	}
}

func TestWrapKeepsNewestInOrder(t *testing.T) {
	r := New(3)
	for i := 1; i <= 5; i++ {
		r.Add(at(i))
	}
	if got := secs(r.Since(time.Time{}, 0)); !equal(got, []int64{3, 4, 5}) {
		t.Errorf("Since(all) = %v, want [3 4 5]", got)
	}
	if l, _ := r.Latest(); l.Time.Unix() != 5 {
		t.Errorf("Latest = %v, want 5", l.Time.Unix())
	}
}

func TestSinceIsExclusiveAndLimited(t *testing.T) {
	r := New(10)
	for i := 1; i <= 6; i++ {
		r.Add(at(i))
	}
	if got := secs(r.Since(time.Unix(3, 0), 0)); !equal(got, []int64{4, 5, 6}) {
		t.Errorf("Since(3) = %v, want [4 5 6]", got)
	}
	if got := secs(r.Since(time.Unix(1, 0), 2)); !equal(got, []int64{2, 3}) {
		t.Errorf("Since(1, limit 2) = %v, want [2 3]", got)
	}
}

func TestExactlyFull(t *testing.T) {
	r := New(3)
	for i := 1; i <= 3; i++ {
		r.Add(at(i))
	}
	if got := secs(r.Since(time.Time{}, 0)); !equal(got, []int64{1, 2, 3}) {
		t.Errorf("Since(all) = %v, want [1 2 3]", got)
	}
	if l, _ := r.Latest(); l.Time.Unix() != 3 {
		t.Errorf("Latest = %v, want 3", l.Time.Unix())
	}
}

func TestEveryKeepsOnePerStep(t *testing.T) {
	r := NewEvery(10, time.Minute)
	for sec := 0; sec <= 150; sec += 15 {
		r.Add(at(sec))
	}
	if got, want := secs(r.Since(time.Time{}, 0)), []int64{0, 60, 120}; !equal(got, want) {
		t.Errorf("history = %v, want %v", got, want)
	}
	if l, ok := r.Latest(); !ok || l.Time.Unix() != 150 {
		t.Errorf("Latest = %v, %v; want 150", l.Time.Unix(), ok)
	}
	// Slightly early ticks still count as the next minute.
	r = NewEvery(10, time.Minute)
	r.Add(at(0))
	r.Add(at(59))
	if got := secs(r.Since(time.Time{}, 0)); !equal(got, []int64{0, 59}) {
		t.Errorf("history = %v, want [0 59]", got)
	}
}
