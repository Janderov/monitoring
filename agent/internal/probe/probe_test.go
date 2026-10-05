package probe

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"
)

func fakeProcWith(t *testing.T, comms ...string) string {
	t.Helper()
	dir := t.TempDir()
	for i, c := range comms {
		p := filepath.Join(dir, strconv.Itoa(100+i))
		os.MkdirAll(p, 0o755)
		os.WriteFile(filepath.Join(p, "comm"), []byte(c+"\n"), 0o644)
	}
	return dir
}

func TestServices(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	open := ln.Addr().(*net.TCPAddr).Port

	proc := fakeProcWith(t, "postgres", "sshd")
	got := Services(proc, []ServiceSpec{
		{Name: "PostgreSQL", Kind: "postgresql", Processes: []string{"postgres"}, Port: open},
		{Name: "MySQL", Kind: "mysql", Processes: []string{"mysqld", "mariadbd"}, Port: 1}, // nothing listens on 1
	})
	if !got[0].ProcessRunning || !got[0].PortOpen || got[0].Error != "" {
		t.Errorf("postgres = %+v", got[0])
	}
	if got[1].ProcessRunning || got[1].PortOpen || got[1].Error == "" {
		t.Errorf("mysql = %+v", got[1])
	}
}

func TestDetectByProcess(t *testing.T) {
	got := Detect(fakeProcWith(t, "mariadbd"))
	var mysql *ServiceSpec
	for i := range got {
		if got[i].Kind == "mysql" {
			mysql = &got[i]
		}
	}
	if mysql == nil {
		t.Fatalf("Detect = %+v, want mysql via mariadbd", got)
	}
	// Nothing listens on 3306 here, like a database in Docker without a
	// published port: watch the process only, or it would look down.
	if portOpen(3306, time.Second) {
		t.Skip("something listens on 3306 on this machine")
	}
	if mysql.Port != 0 {
		t.Errorf("port = %d, want 0 (not reachable at detection)", mysql.Port)
	}
	if r := Services(fakeProcWith(t, "mariadbd"), []ServiceSpec{*mysql}); !r[0].ProcessRunning || r[0].Error != "" {
		t.Errorf("service = %+v, want running with no error", r[0])
	}
}

func TestRunHTTPAndTCP(t *testing.T) {
	ok := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer ok.Close()
	bad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
	}))
	defer bad.Close()
	auth := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer auth.Close()
	// The test server's certificate is self-signed; trust it for this test.
	tr := httpClient.Transport.(*http.Transport)
	tr.TLSClientConfig.RootCAs = ok.Client().Transport.(*http.Transport).TLSClientConfig.RootCAs
	defer func() { tr.TLSClientConfig.RootCAs = nil }()

	host, port, _ := net.SplitHostPort(ok.Listener.Addr().String())
	p, _ := strconv.Atoi(port)
	res := Run(context.Background(), []Target{
		{ID: "ok", Kind: "http", URL: ok.URL},
		{ID: "bad", Kind: "http", URL: bad.URL},
		{ID: "tcp-up", Kind: "tcp", Host: host, Port: p},
		{ID: "tcp-down", Kind: "tcp", Host: "127.0.0.1", Port: 1, TimeoutSeconds: 1},
		{ID: "auth", Kind: "http", URL: auth.URL},
	})
	if r := res[0]; !r.OK || r.StatusCode != 200 || r.TLSExpiry == nil || r.TLSExpiry.Before(time.Now()) {
		t.Errorf("ok = %+v", r)
	}
	if r := res[1]; r.OK || r.StatusCode != 502 || r.Error == "" {
		t.Errorf("bad = %+v", r)
	}
	if !res[2].OK {
		t.Errorf("tcp-up = %+v", res[2])
	}
	if res[3].OK || res[3].Error == "" {
		t.Errorf("tcp-down = %+v", res[3])
	}
	if r := res[4]; !r.OK || r.StatusCode != 401 || r.Error != "" {
		t.Errorf("auth = %+v", r)
	}
}

func TestStorePersists(t *testing.T) {
	path := filepath.Join(t.TempDir(), "checks.json")
	s, err := OpenStore(path)
	if err != nil || len(s.Get()) != 0 {
		t.Fatalf("new store: %v %v", s, err)
	}
	if err := s.Set([]Target{{ID: "a", Kind: "tcp", Host: "h", Port: 22}}); err != nil {
		t.Fatal(err)
	}
	if err := s.Set([]Target{{ID: "b", Kind: "tcp", Host: "h"}}); err == nil {
		t.Error("invalid list accepted")
	}
	s2, err := OpenStore(path)
	if err != nil || len(s2.Get()) != 1 || s2.Get()[0].ID != "a" {
		t.Errorf("reopened = %+v %v", s2.Get(), err)
	}
	if fi, _ := os.Stat(path); fi.Mode().Perm() != 0o600 {
		t.Errorf("mode = %v", fi.Mode().Perm())
	}
}
