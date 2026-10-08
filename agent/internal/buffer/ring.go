// Package buffer keeps the most recent snapshots so the Mac app can catch up
// on history it missed while asleep.
package buffer

import (
	"bufio"
	"encoding/json"
	"os"
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

	// History on disk, one JSON line per stored snapshot, so a restart of
	// the agent while the Mac sleeps keeps the day it has not fetched yet.
	path  string
	file  *os.File
	lines int
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
	if r.store(s) {
		r.save(s)
	}
}

// store puts s in the history unless the previous one is too recent.
func (r *Ring) store(s collect.Snapshot) bool {
	if r.step > 0 && (r.full || r.next > 0) {
		// Some slack so a minute of 15 s samples still yields one per minute.
		last := r.items[(r.next-1+len(r.items))%len(r.items)]
		if s.Time.Sub(last.Time) < r.step-r.step/30 {
			return false
		}
	}
	r.items[r.next] = s
	r.next = (r.next + 1) % len(r.items)
	if r.next == 0 {
		r.full = true
	}
	return true
}

// Persist reads back the history saved at path (dropping what is older than
// maxAge or from the future), then appends every stored snapshot to it. The
// file is rewritten from memory once it holds twice the capacity. Latest
// stays empty until the first new sample: a snapshot from before the
// restart is history, not the current state.
func (r *Ring) Persist(path string, now time.Time, maxAge time.Duration) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.path = path
	if f, err := os.Open(path); err == nil {
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 64*1024), 16<<20)
		for sc.Scan() {
			var s collect.Snapshot
			// A line cut short by a crash is skipped.
			if json.Unmarshal(sc.Bytes(), &s) != nil || now.Sub(s.Time) > maxAge || s.Time.After(now.Add(time.Minute)) {
				continue
			}
			r.store(s)
		}
		f.Close()
	} else if !os.IsNotExist(err) {
		return err
	}
	return r.rewrite()
}

func (r *Ring) save(s collect.Snapshot) {
	if r.file == nil {
		return
	}
	b, err := json.Marshal(s)
	if err == nil {
		_, err = r.file.Write(append(b, '\n'))
	}
	r.lines++
	if err != nil || r.lines >= 2*len(r.items) {
		// A failed write leaves a broken line; rewriting drops it.
		r.rewrite()
	}
}

// rewrite replaces the file with the history in memory, atomically.
func (r *Ring) rewrite() error {
	if r.file != nil {
		r.file.Close()
		r.file = nil
	}
	tmp := r.path + ".tmp"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	w := bufio.NewWriter(f)
	enc := json.NewEncoder(w)
	r.lines = 0
	for _, s := range r.sinceLocked(time.Time{}, 0) {
		if err := enc.Encode(s); err != nil {
			f.Close()
			return err
		}
		r.lines++
	}
	if err := w.Flush(); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp, r.path); err != nil {
		return err
	}
	r.file, err = os.OpenFile(r.path, os.O_APPEND|os.O_WRONLY, 0o600)
	return err
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
	return r.sinceLocked(t, limit)
}

func (r *Ring) sinceLocked(t time.Time, limit int) []collect.Snapshot {
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
