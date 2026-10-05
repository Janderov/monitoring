package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Janderov/monitoring/agent/internal/buffer"
	"github.com/Janderov/monitoring/agent/internal/collect"
	"github.com/Janderov/monitoring/agent/internal/probe"
)

func store(t *testing.T) *probe.Store {
	t.Helper()
	s, err := probe.OpenStore(filepath.Join(t.TempDir(), "checks.json"))
	if err != nil {
		t.Fatal(err)
	}
	return s
}

const token = "0123456789abcdef0123456789abcdef"

func do(t *testing.T, h http.Handler, path, auth string) *httptest.ResponseRecorder {
	return doMethod(t, h, http.MethodGet, path, auth, "")
}

func doMethod(t *testing.T, h http.Handler, method, path, auth, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if auth != "" {
		req.Header.Set("Authorization", auth)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func TestAuthRequired(t *testing.T) {
	h := New(token, buffer.New(5), store(t), "test").Handler()
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
	h := New(token, ring, store(t), "test").Handler()
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

func TestChecksEndpoints(t *testing.T) {
	h := New(token, buffer.New(5), store(t), "test").Handler()
	auth := "Bearer " + token

	if rec := doMethod(t, h, http.MethodPut, "/v1/checks", "", `{"targets":[]}`); rec.Code != http.StatusUnauthorized {
		t.Errorf("PUT without token: %d, want 401", rec.Code)
	}
	good := `{"targets":[{"id":"site","kind":"http","url":"https://example.com"},{"id":"nl","kind":"tcp","host":"203.0.113.7","port":22}]}`
	if rec := doMethod(t, h, http.MethodPut, "/v1/checks", auth, good); rec.Code != http.StatusOK {
		t.Fatalf("PUT good: %d %s", rec.Code, rec.Body)
	}
	for name, body := range map[string]string{
		"bad kind":      `{"targets":[{"id":"x","kind":"icmp","host":"a"}]}`,
		"bad url":       `{"targets":[{"id":"x","kind":"http","url":"ftp://a"}]}`,
		"duplicate id":  `{"targets":[{"id":"x","kind":"tcp","host":"a","port":1},{"id":"x","kind":"tcp","host":"b","port":1}]}`,
		"unknown field": `{"targets":[],"extra":1}`,
		"not json":      `nope`,
	} {
		if rec := doMethod(t, h, http.MethodPut, "/v1/checks", auth, body); rec.Code != http.StatusBadRequest {
			t.Errorf("%s: %d, want 400", name, rec.Code)
		}
	}
	var got struct{ Targets []probe.Target }
	json.Unmarshal(do(t, h, "/v1/checks", auth).Body.Bytes(), &got)
	if len(got.Targets) != 2 || got.Targets[1].Port != 22 {
		t.Errorf("GET after bad PUTs = %+v, want the 2 good targets", got.Targets)
	}

	// Site credentials go in, the password never comes back.
	withAuth := `{"targets":[{"id":"site","kind":"http","url":"https://example.com","basic_auth":{"user":"u","password":"s3cret"}}]}`
	rec := doMethod(t, h, http.MethodPut, "/v1/checks", auth, withAuth)
	if rec.Code != http.StatusOK || strings.Contains(rec.Body.String(), "s3cret") {
		t.Fatalf("PUT with auth: %d %s", rec.Code, rec.Body)
	}
	body := do(t, h, "/v1/checks", auth).Body.String()
	if strings.Contains(body, "s3cret") || !strings.Contains(body, `"user":"u"`) {
		t.Errorf("GET leaks or loses credentials: %s", body)
	}
	if rec := doMethod(t, h, http.MethodPut, "/v1/checks", auth,
		`{"targets":[{"id":"n","kind":"tcp","host":"a","port":1,"basic_auth":{"user":"u"}}]}`); rec.Code != http.StatusBadRequest {
		t.Errorf("basic_auth on tcp: %d, want 400", rec.Code)
	}
}
