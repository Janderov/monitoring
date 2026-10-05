package flows

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// NL at 203.0.113.10; VPN client 10.8.1.2; US exit 198.51.100.7.
const table = `ipv4     2 udp      17 170 src=10.8.1.2 dst=142.250.1.1 sport=5000 dport=443 src=142.250.1.1 dst=203.0.113.10 sport=443 dport=5000 [ASSURED] mark=0 zone=0 use=2
ipv4     2 tcp      6 431999 ESTABLISHED src=10.8.1.2 dst=142.250.1.1 sport=5001 dport=443 src=142.250.1.1 dst=203.0.113.10 sport=443 dport=5001 [ASSURED] mark=0 zone=0 use=2
ipv4     2 tcp      6 431999 ESTABLISHED src=192.0.2.50 dst=203.0.113.10 sport=6000 dport=8443 src=198.51.100.7 dst=203.0.113.10 sport=443 dport=6000 [ASSURED] mark=0 zone=0 use=2
ipv4     2 udp      17 175 src=192.0.2.50 dst=203.0.113.10 sport=7000 dport=51820 src=203.0.113.10 dst=192.0.2.50 sport=51820 dport=7000 [ASSURED] mark=0 zone=0 use=2
ipv4     2 tcp      6 431999 ESTABLISHED src=198.51.100.7 dst=203.0.113.10 sport=6001 dport=443 src=172.17.0.2 dst=198.51.100.7 sport=443 dport=6001 [ASSURED] mark=0 zone=0 use=2
ipv4     2 tcp      6 299 ESTABLISHED src=198.51.100.7 dst=203.0.113.10 sport=6002 dport=9443 src=203.0.113.10 dst=198.51.100.7 sport=9443 dport=6002 [ASSURED] mark=0 zone=0 use=2
ipv4     2 tcp      6 431999 ESTABLISHED src=203.0.113.10 dst=93.184.216.34 sport=40000 dport=443 src=93.184.216.34 dst=203.0.113.10 sport=443 dport=40000 [ASSURED] mark=0 zone=0 use=2
ipv4     2 udp      17 25 src=10.8.1.3 dst=8.8.8.8 sport=5353 dport=53 [UNREPLIED] src=8.8.8.8 dst=203.0.113.10 sport=53 dport=5353 mark=0 zone=0 use=2
ipv4     2 tcp      6 100 TIME_WAIT src=198.51.100.7 dst=203.0.113.10 sport=6003 dport=443 src=203.0.113.10 dst=198.51.100.7 sport=443 dport=6003 [ASSURED] mark=0 zone=0 use=2
ipv4     2 icmp     1 29 src=10.8.1.2 dst=1.1.1.1 type=8 code=0 id=1 src=1.1.1.1 dst=203.0.113.10 type=0 code=0 id=1 mark=0 zone=0 use=2
`

func TestClassify(t *testing.T) {
	flows := Parse(strings.NewReader(table))
	if len(flows) != 9 {
		t.Fatalf("parsed %d flows, want 9 (icmp skipped)", len(flows))
	}
	fwd, in := agg{}, agg{}
	local := map[string]bool{"203.0.113.10": true}
	Classify("host", flows, local, map[int]bool{9443: true, 22: true}, fwd, in)

	f := fwd.list()
	if len(f) != 2 || f[0].RemoteIP != "142.250.1.1" || f[0].Connections != 2 ||
		strings.Join(f[0].Protos, ",") != "tcp,udp" || f[0].Via[0] != "nat:host" {
		t.Fatalf("forwards = %+v", f)
	}
	// The port forward NL:8443 -> US:443 shows the real destination.
	if f[1].RemoteIP != "198.51.100.7" || f[1].Ports[0] != 443 {
		t.Fatalf("port forward = %+v", f[1])
	}

	i := in.list()
	// Client over UDP, and US reaching a container port; the agent probe and a
	// closed one-off connection are ignored.
	if len(i) != 2 {
		t.Fatalf("inbound = %+v", i)
	}
	got := map[string]int{}
	for _, l := range i {
		got[l.RemoteIP] = l.Ports[0]
	}
	if got["192.0.2.50"] != 51820 || got["198.51.100.7"] != 443 {
		t.Fatalf("inbound = %+v", i)
	}
}

func TestLocalAddrs(t *testing.T) {
	dir := t.TempDir()
	trie := `Main:
  +-- 0.0.0.0/0 3 0 5
     |-- 0.0.0.0
        /0 universe UNICAST
     +-- 203.0.113.0/24 2 0 2
        |-- 203.0.113.0
           /24 link UNICAST
        |-- 203.0.113.10
           /32 host LOCAL
`
	os.WriteFile(filepath.Join(dir, "fib_trie"), []byte(trie), 0o644)
	os.WriteFile(filepath.Join(dir, "if_inet6"),
		[]byte("20010db8000000000000000000000001 02 40 00 80 eth0\n"), 0o644)
	got := LocalAddrs(dir)
	if !got["203.0.113.10"] || got["203.0.113.0"] || !got["2001:db8::1"] {
		t.Fatalf("local = %v", got)
	}
}

func TestWriteRead(t *testing.T) {
	path := filepath.Join(t.TempDir(), "flows.json")
	now := time.Now()
	if err := Write(path, Summary{Time: now, Inbound: nil}); err != nil {
		t.Fatal(err)
	}
	if Read(path, now.Add(time.Minute), 2*time.Minute) == nil {
		t.Fatal("fresh summary not read")
	}
	if Read(path, now.Add(5*time.Minute), 2*time.Minute) != nil {
		t.Fatal("stale summary read")
	}
}
