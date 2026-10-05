package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/Janderov/monitoring/agent/internal/buffer"
	"github.com/Janderov/monitoring/agent/internal/collect"
)

const token = "0123456789abcdef0123456789abcdef"

func do(t *testing.T, h http.Handler, path, auth string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, path, nil)
	if auth != "" {
		req.Header.Set("Authorization", auth)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func TestAuthRequired(t *testing.T) {
	h := New(token, buffer.New(5), "test").Handler()
	for _, auth := range []string{"", "Bearer wrong", "Basic " + token, token, "Bearer " + token + "x"} {
		if rec := do(t, h, "/v1/health", auth); rec.Code != http.StatusUnauthorized {
			t.Errorf("auth %q: status %d, want 401", auth, rec.Code)
		}
	}
	// Unknown paths must not leak that they don't exist before auth.
	if rec := do(t, h, "/nope", ""); rec.Code != http.StatusUnauthorized {
		t.Errorf("unauthenticated unknown path: %d, want 401", rec.Code)
	}
	if rec := do(t, h, "/v1/health", "Bearer "+token); rec.Code != http.StatusOK {
		t.Errorf("valid token: status %d, want 200", rec.Code)
	}
}

func TestSnapshotAndHistory(t *testing.T) {
	ring := buffer.New(1000)
	h := New(token, ring, "test").Handler()
	auth := "Bearer " + token

	if rec := do(t, h, "/v1/snapshot", auth); rec.Code != http.StatusServiceUnavailable {
		t.Errorf("snapshot before first sample: %d, want 503", rec.Code)
	}

	base := time.Unix(1_700_000_000, 0)
	for i := 0; i < maxHistory+10; i++ {
		ring.Add(collect.Snapshot{Time: base.Add(time.Duration(i) * time.Minute), Hostname: "srv"})
	}

	rec := do(t, h, "/v1/snapshot", auth)
	var snap collect.Snapshot
	if err := json.Unmarshal(rec.Body.Bytes(), &snap); err != nil || snap.Hostname != "srv" {
		t.Fatalf("snapshot: %d %s", rec.Code, rec.Body)
	}

	var page struct {
		Snapshots []collect.Snapshot `json:"snapshots"`
		More      bool               `json:"more"`
	}
	rec = do(t, h, "/v1/history", auth)
	if err := json.Unmarshal(rec.Body.Bytes(), &page); err != nil {
		t.Fatal(err)
	}
	if len(page.Snapshots) != maxHistory || !page.More {
		t.Errorf("first page: %d items, more=%v", len(page.Snapshots), page.More)
	}

	last := page.Snapshots[len(page.Snapshots)-1].Time.Unix()
	rec = do(t, h, "/v1/history?since="+itoa(last), auth)
	page.Snapshots, page.More = nil, false
	if err := json.Unmarshal(rec.Body.Bytes(), &page); err != nil {
		t.Fatal(err)
	}
	if len(page.Snapshots) != 10 || page.More {
		t.Errorf("second page: %d items, more=%v, want 10 and false", len(page.Snapshots), page.More)
	}

	if rec := do(t, h, "/v1/history?since=yesterday", auth); rec.Code != http.StatusBadRequest {
		t.Errorf("bad since: %d, want 400", rec.Code)
	}
}

func itoa(v int64) string { b, _ := json.Marshal(v); return string(b) }
