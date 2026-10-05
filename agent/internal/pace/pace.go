// Package pace holds the sampling interval, which the Mac app can change at
// run time. A changed interval is saved so it survives a restart.
package pace

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sync"
	"time"
)

// Bounds for an interval set from the Mac.
const (
	Min = 10 * time.Second
	Max = 10 * time.Minute
)

type Pace struct {
	mu      sync.RWMutex
	path    string
	def     time.Duration
	every   time.Duration
	changed chan struct{}
}

type file struct {
	IntervalSeconds int `json:"interval_s"`
}

// Open loads the saved interval from path; without one the config's def applies.
func Open(path string, def time.Duration) (*Pace, error) {
	p := &Pace{path: path, def: def, every: def, changed: make(chan struct{}, 1)}
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return p, nil
	}
	if err != nil {
		return nil, err
	}
	var f file
	if err := json.Unmarshal(b, &f); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	if d := time.Duration(f.IntervalSeconds) * time.Second; d >= Min && d <= Max {
		p.every = d
	}
	return p, nil
}

func (p *Pace) Get() time.Duration {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return p.every
}

// Set saves and applies a new interval; 0 returns to the config's value.
func (p *Pace) Set(d time.Duration) error {
	if d != 0 && (d < Min || d > Max) {
		return fmt.Errorf("interval must be between %s and %s", Min, Max)
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if d == 0 {
		if err := os.Remove(p.path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		d = p.def
	} else {
		b, _ := json.Marshal(file{IntervalSeconds: int(d / time.Second)})
		tmp := p.path + ".tmp"
		if err := os.WriteFile(tmp, b, 0o600); err != nil {
			return err
		}
		if err := os.Rename(tmp, p.path); err != nil {
			return err
		}
	}
	p.every = d
	select {
	case p.changed <- struct{}{}:
	default:
	}
	return nil
}

// Changed fires after Set, so a waiting sampler can pick up the new interval.
func (p *Pace) Changed() <-chan struct{} { return p.changed }
