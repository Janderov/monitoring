package docker

import (
	"net"
	"net/http"
	"path/filepath"
	"testing"
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
