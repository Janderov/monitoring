// Package buffer keeps the most recent snapshots so the Mac app can catch up
// on history it missed while asleep.
package buffer

import (
	"sync"
	"time"

	"github.com/Janderov/monitoring/agent/internal/collect"
)

// Ring is a fixed-size, concurrency-safe ring of snapshots in time order.
type Ring struct {
	mu     sync.RWMutex
	items  []collect.Snapshot
	next   int
	full   bool
	step   time.Duration
	latest *collect.Snapshot
}

func New(capacity int) *Ring {
	return &Ring{items: make([]collect.Snapshot, capacity)}
}

// NewEvery keeps at most about one snapshot per step in the history, however
// often Add is called, so a faster sampling rate neither shortens the
// history nor grows the Mac's database. Latest still returns the newest one.
func NewEvery(capacity int, step time.Duration) *Ring {
	r := New(capacity)
	r.step = step
	return r
}

func (r *Ring) Add(s collect.Snapshot) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.latest = &s
	if r.step > 0 && (r.full || r.next > 0) {
		// Some slack so a minute of 15 s samples still yields one per minute.
		last := r.items[(r.next-1+len(r.items))%len(r.items)]
		if s.Time.Sub(last.Time) < r.step-r.step/30 {
			return
		}
	}
	r.items[r.next] = s
	r.next = (r.next + 1) % len(r.items)
	if r.next == 0 {
		r.full = true
	}
}

// Latest returns the newest snapshot, if any.
func (r *Ring) Latest() (collect.Snapshot, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if r.latest == nil {
		return collect.Snapshot{}, false
	}
	return *r.latest, true
}

// Since returns snapshots strictly newer than t, oldest first, at most limit
// of them (limit <= 0 means no limit).
func (r *Ring) Since(t time.Time, limit int) []collect.Snapshot {
	r.mu.RLock()
	defer r.mu.RUnlock()

	n, start := r.next, 0
	if r.full {
		n, start = len(r.items), r.next
	}
	var out []collect.Snapshot
	for i := 0; i < n; i++ {
		s := r.items[(start+i)%len(r.items)]
		if !s.Time.After(t) {
			continue
		}
		out = append(out, s)
		if limit > 0 && len(out) == limit {
			break
		}
	}
	return out
}
