package pace

import (
	"path/filepath"
	"testing"
	"time"
)

func TestSetPersistsAndResets(t *testing.T) {
	path := filepath.Join(t.TempDir(), "pace.json")
	p, err := Open(path, time.Minute)
	if err != nil || p.Get() != time.Minute {
		t.Fatalf("Open = %v, %v", p.Get(), err)
	}
	if err := p.Set(15 * time.Second); err != nil {
		t.Fatal(err)
	}
	select {
	case <-p.Changed():
	default:
		t.Error("Set did not signal Changed")
	}
	again, err := Open(path, time.Minute)
	if err != nil || again.Get() != 15*time.Second {
		t.Errorf("reopened = %v, %v; want 15s", again.Get(), err)
	}
	if err := again.Set(0); err != nil || again.Get() != time.Minute {
		t.Errorf("reset = %v, %v; want 1m", again.Get(), err)
	}
	if third, _ := Open(path, time.Minute); third.Get() != time.Minute {
		t.Errorf("after reset reopened = %v, want 1m", third.Get())
	}
}

func TestSetRejectsOutOfRange(t *testing.T) {
	p, _ := Open(filepath.Join(t.TempDir(), "pace.json"), time.Minute)
	for _, d := range []time.Duration{time.Second, 9 * time.Second, time.Hour} {
		if err := p.Set(d); err == nil {
			t.Errorf("Set(%s) accepted", d)
		}
	}
	if p.Get() != time.Minute {
		t.Errorf("interval changed to %s", p.Get())
	}
}
