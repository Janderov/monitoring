package docker

import (
	"errors"
	"net"
	"net/http"
	"path/filepath"
	"testing"
	"time"
)

func TestListOverUnixSocket(t *testing.T) {
	sock := filepath.Join(t.TempDir(), "docker.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Skip("unix sockets unavailable:", err)
	}
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/containers/json" || r.URL.Query().Get("all") != "1" {
			http.NotFound(w, r)
			return
		}
		w.Write([]byte(`[{"Id":"0123456789abcdef0123","Names":["/amnezia-awg"],"Image":"amnezia-awg","State":"running","Status":"Up 3 days"}]`))
	})}
	go srv.Serve(ln)
	defer srv.Close()

	got, err := New(sock).List()
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].Name != "amnezia-awg" || got[0].ID != "0123456789ab" || got[0].State != "running" {
		t.Errorf("containers = %+v", got)
	}
}

func TestHealth(t *testing.T) {
	for status, want := range map[string]string{
		"Up 2 weeks (healthy)":            "healthy",
		"Up 1 minute (unhealthy)":         "unhealthy",
		"Up 5 seconds (health: starting)": "starting",
		"Up 5 days":                       "",
		"Exited (1) 3 hours ago":          "",
	} {
		if got := health(status); got != want {
			t.Errorf("health(%q) = %q, want %q", status, got, want)
		}
	}
}

// A hung Docker costs one budget per sample, not 5 s for every call.
func TestRoundBudget(t *testing.T) {
	sock := filepath.Join(t.TempDir(), "docker.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Skip("unix sockets unavailable:", err)
	}
	release := make(chan struct{})
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-release:
		case <-r.Context().Done():
		}
	})}
	go srv.Serve(ln)
	defer srv.Close()
	defer close(release)

	c := New(sock)
	c.StartRound(200 * time.Millisecond)
	start := time.Now()
	if _, err := c.List(); !errors.Is(err, ErrBudget) {
		t.Fatalf("first call: err = %v, want ErrBudget", err)
	}
	if _, err := c.Pid("x"); !errors.Is(err, ErrBudget) {
		t.Fatalf("second call: err = %v, want ErrBudget", err)
	}
	if d := time.Since(start); d > 2*time.Second {
		t.Errorf("took %s, want about the budget", d)
	}
}
