package docker

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"net"
	"net/http"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Janderov/monitoring/agent/internal/collect"
)

var now = time.Unix(1_700_000_600, 0)

const wgDump = "wg0\tPRIVKEY\tSERVERPUB\t51820\toff\n" +
	"wg0\tPUB_A\t(none)\t198.51.100.1:5000\t10.8.1.2/32\t1700000500\t1000\t5000\toff\n" + // 100s ago: active
	"wg0\tPUB_B\t(none)\t(none)\t10.8.1.3/32\t1699990000\t200\t300\toff\n" + // hours ago
	"wg0\tPUB_C\t(none)\t(none)\t10.8.1.4/32\t0\t0\t0\toff\n" // never connected

func TestParseWGDump(t *testing.T) {
	peers := parseWGDump(wgDump, now)
	if len(peers) != 3 {
		t.Fatalf("peers = %d, want 3", len(peers))
	}
	if !peers[0].Active || peers[0].RxBytes != 1000 || peers[0].TxBytes != 5000 {
		t.Errorf("peer A = %+v", peers[0])
	}
	if peers[1].Active || peers[1].LatestHandshake == nil {
		t.Errorf("peer B = %+v", peers[1])
	}
	if peers[2].Active || peers[2].LatestHandshake != nil {
		t.Errorf("peer C = %+v", peers[2])
	}
}

func TestParseClientsTableConcatenated(t *testing.T) {
	in := `[{"clientId":"PUB_A","userData":{"clientName":"iPhone Mihail"}}]` + "\n" +
		`[{"clientId":"PUB_B","userData":{"clientName":"Laptop"}},{"clientId":"PUB_X","userData":{}}]`
	got := parseClientsTable([]byte(in))
	if got["PUB_A"] != "iPhone Mihail" || got["PUB_B"] != "Laptop" || len(got) != 2 {
		t.Errorf("names = %v", got)
	}
	if len(parseClientsTable([]byte("not json"))) != 0 {
		t.Error("garbage produced names")
	}
}

func TestVPNProtocol(t *testing.T) {
	for name, want := range map[string]string{
		"amnezia-awg": "awg", "amnezia-awg2": "awg2", "amnezia-xray": "xray", "amnezia-dns": "", "nginx": "",
	} {
		got, ok := vpnProtocol(name)
		if got != want || ok != (want != "") {
			t.Errorf("vpnProtocol(%q) = %q,%v", name, got, ok)
		}
	}
}

func frame(stream byte, payload string) []byte {
	h := make([]byte, 8)
	h[0] = stream
	binary.BigEndian.PutUint32(h[4:], uint32(len(payload)))
	return append(h, payload...)
}

func TestDemux(t *testing.T) {
	var b bytes.Buffer
	b.Write(frame(1, "hello "))
	b.Write(frame(2, "oops"))
	b.Write(frame(1, "world"))
	out, errb, err := demux(&b)
	if err != nil || string(out) != "hello world" || string(errb) != "oops" {
		t.Errorf("demux = %q %q %v", out, errb, err)
	}
}

// fakeDocker answers the exec API: each command's stdout is looked up by a
// substring of the command line.
func fakeDocker(t *testing.T, outputs map[string]string) string {
	t.Helper()
	sock := filepath.Join(t.TempDir(), "d.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Skip("unix sockets unavailable:", err)
	}
	var mu sync.Mutex
	cmds := map[string]string{}
	n := 0
	mux := http.NewServeMux()
	mux.HandleFunc("POST /containers/{name}/exec", func(w http.ResponseWriter, r *http.Request) {
		var body struct{ Cmd []string }
		json.NewDecoder(r.Body).Decode(&body)
		mu.Lock()
		n++
		id := string(rune('a' + n))
		cmds[id] = strings.Join(body.Cmd, " ")
		mu.Unlock()
		json.NewEncoder(w).Encode(map[string]string{"Id": id})
	})
	mux.HandleFunc("POST /exec/{id}/start", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		cmd := cmds[r.PathValue("id")]
		mu.Unlock()
		for k, v := range outputs {
			if strings.Contains(cmd, k) {
				w.Write(frame(1, v))
			}
		}
	})
	mux.HandleFunc("GET /exec/{id}/json", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"ExitCode":0}`))
	})
	srv := &http.Server{Handler: mux}
	go srv.Serve(ln)
	t.Cleanup(func() { srv.Close() })
	return sock
}

func TestVPNEndToEnd(t *testing.T) {
	sock := fakeDocker(t, map[string]string{
		"wg show":      wgDump,
		"clientsTable": `[{"clientId":"PUB_A","userData":{"clientName":"iPhone"}}]`,
	})
	got := New(sock).VPN([]collect.Container{
		{Name: "amnezia-awg", State: "running"},
		{Name: "amnezia-xray", State: "exited"},
		{Name: "nginx", State: "running"},
	}, now)
	if len(got) != 2 {
		t.Fatalf("vpn = %+v, want awg and xray", got)
	}
	awg := got[0]
	if awg.Error != "" || awg.Clients != 3 || awg.ActiveClients != 1 || awg.RxBytes != 1200 || awg.TxBytes != 5300 {
		t.Errorf("awg = %+v", awg)
	}
	if awg.Peers[0].Name != "iPhone" {
		t.Errorf("peer name = %q", awg.Peers[0].Name)
	}
	if got[1].Running || got[1].Protocol != "xray" {
		t.Errorf("xray = %+v", got[1])
	}
}
