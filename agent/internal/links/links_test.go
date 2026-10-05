package links

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// hexAddr encodes an IPv4 address the way /proc/net/tcp prints it.
func hexAddr(ip string, port int) string {
	b := net.ParseIP(ip).To4()
	return fmt.Sprintf("%02X%02X%02X%02X:%04X", b[3], b[2], b[1], b[0], port)
}

func line(i int, local string, lport int, remote string, rport int, state string) string {
	return fmt.Sprintf("%4d: %s %s %s 00000000:00000000 00:00000000 00000000 0 0 1 1 0\n",
		i, hexAddr(local, lport), hexAddr(remote, rport), state)
}

const header = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"

func writeNet(t *testing.T, dir, name, body string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, name), []byte(header+body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestCollect(t *testing.T) {
	root := t.TempDir()
	host := filepath.Join(root, "net")
	writeNet(t, host, "tcp",
		line(0, "0.0.0.0", 443, "0.0.0.0", 0, "0A")+ // nginx listening
			line(1, "203.0.113.10", 443, "8.8.8.8", 51234, "01")+ // a visitor: incoming, skipped
			line(2, "203.0.113.10", 51000, "192.0.2.130", 443, "01")+ // relay to the exit server
			line(3, "203.0.113.10", 51001, "192.0.2.130", 443, "01")+
			line(4, "10.0.0.2", 40000, "10.0.0.5", 5432, "01")+ // private: skipped
			line(5, "203.0.113.10", 40001, "198.51.100.7", 9443, "01")) // agent probe: ignored
	writeNet(t, host, "udp", line(0, "203.0.113.10", 40002, "192.0.2.130", 51820, "01"))

	// A bridge-network container relaying out, plus a socket also seen on the host.
	ctr := filepath.Join(root, "1234", "net")
	writeNet(t, ctr, "tcp",
		line(0, "172.17.0.2", 38000, "198.51.100.20", 8443, "01")+
			line(1, "203.0.113.10", 51000, "192.0.2.130", 443, "01"))

	got := Collect([]Source{{"host", host}, {"amnezia-xray", ctr}}, map[int]bool{9443: true})
	if len(got) != 2 {
		t.Fatalf("got %d links: %+v", len(got), got)
	}
	exit := got[0]
	if exit.RemoteIP != "192.0.2.130" || exit.Connections != 3 ||
		!reflect.DeepEqual(exit.Ports, []int{443, 51820}) || !reflect.DeepEqual(exit.Protos, []string{"tcp", "udp"}) ||
		!reflect.DeepEqual(exit.Via, []string{"host"}) {
		t.Errorf("exit link: %+v", exit)
	}
	if got[1].RemoteIP != "198.51.100.20" || !reflect.DeepEqual(got[1].Via, []string{"amnezia-xray"}) {
		t.Errorf("container link: %+v", got[1])
	}
}

func TestParseAddrIPv6(t *testing.T) {
	// ::ffff:1.2.3.4 port 443 as the kernel prints it.
	ip, port, ok := parseAddr("0000000000000000FFFF000004030201:01BB")
	if !ok || port != 443 || ip.String() != "1.2.3.4" {
		t.Errorf("got %v %d %v", ip, port, ok)
	}
}
