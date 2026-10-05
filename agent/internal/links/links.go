// Package links finds the server's outgoing connections to public addresses,
// read from /proc/<pid>/net/{tcp,udp}[6] of the host and of each container's
// network namespace. The Mac app matches the remote addresses against its
// other servers to draw VPN cascades (entry -> exit) on the map. Connections
// to this server's own listening ports (clients coming in) are left out.
package links

import (
	"bufio"
	"encoding/hex"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/Janderov/monitoring/agent/internal/collect"
)

// Source is one network namespace: the host or a container.
type Source struct {
	Label  string // "host" or the container name
	NetDir string // e.g. /proc/net or /proc/1234/net
}

// maxLinks caps the list; a cascade is a handful of remotes, not thousands.
const maxLinks = 64

type socket struct {
	proto      string
	local      net.IP
	localPort  int
	remote     net.IP
	remotePort int
	state      string
}

// Collect returns outgoing connections grouped by remote address, busiest first.
// ignorePorts drops remote ports that are not traffic, such as agent probes.
func Collect(sources []Source, ignorePorts map[int]bool) []collect.Link {
	agg := map[string]*collect.Link{}
	seen := map[string]bool{}
	for _, src := range sources {
		var socks []socket
		for _, f := range []struct{ name, proto string }{
			{"tcp", "tcp"}, {"tcp6", "tcp"}, {"udp", "udp"}, {"udp6", "udp"},
		} {
			s, err := readFile(filepath.Join(src.NetDir, f.name), f.proto)
			if err == nil {
				socks = append(socks, s...)
			}
		}
		listening := map[string]bool{}
		for _, s := range socks {
			if isListening(s) {
				listening[fmt.Sprintf("%s/%d", s.proto, s.localPort)] = true
			}
		}
		for _, s := range socks {
			if !isConnected(s) || listening[fmt.Sprintf("%s/%d", s.proto, s.localPort)] {
				continue
			}
			if !IsPublic(s.remote) || ignorePorts[s.remotePort] {
				continue
			}
			// Host-network containers share the host's sockets; count each once.
			id := fmt.Sprintf("%s %s:%d %s:%d", s.proto, s.local, s.localPort, s.remote, s.remotePort)
			if seen[id] {
				continue
			}
			seen[id] = true
			ip := s.remote.String()
			l := agg[ip]
			if l == nil {
				l = &collect.Link{RemoteIP: ip}
				agg[ip] = l
			}
			l.Connections++
			l.Ports = addInt(l.Ports, s.remotePort)
			l.Protos = addStr(l.Protos, s.proto)
			l.Via = addStr(l.Via, src.Label)
		}
	}
	out := make([]collect.Link, 0, len(agg))
	for _, l := range agg {
		sort.Ints(l.Ports)
		sort.Strings(l.Protos)
		sort.Strings(l.Via)
		out = append(out, *l)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Connections != out[j].Connections {
			return out[i].Connections > out[j].Connections
		}
		return out[i].RemoteIP < out[j].RemoteIP
	})
	if len(out) > maxLinks {
		out = out[:maxLinks]
	}
	return out
}

// TCP states from include/net/tcp_states.h; UDP uses 01 for a connected socket
// and 07 (close) for an unconnected one.
const (
	stateEstablished = "01"
	stateListen      = "0A"
	stateClose       = "07"
)

func isListening(s socket) bool {
	if s.proto == "tcp" {
		return s.state == stateListen
	}
	return s.state == stateClose && s.remote.IsUnspecified()
}

func isConnected(s socket) bool { return s.state == stateEstablished && !s.remote.IsUnspecified() }

// IsPublic reports whether ip is a routable internet address.
func IsPublic(ip net.IP) bool {
	if ip == nil || ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsUnspecified() ||
		ip.IsMulticast() {
		return false
	}
	// Carrier-grade NAT, 100.64.0.0/10.
	if v4 := ip.To4(); v4 != nil && v4[0] == 100 && v4[1]&0xC0 == 64 {
		return false
	}
	return true
}

func readFile(path, proto string) ([]socket, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return parse(bufio.NewScanner(f), proto), nil
}

func parse(sc *bufio.Scanner, proto string) []socket {
	var out []socket
	first := true
	for sc.Scan() {
		if first { // header
			first = false
			continue
		}
		f := strings.Fields(sc.Text())
		if len(f) < 4 {
			continue
		}
		lip, lport, ok1 := parseAddr(f[1])
		rip, rport, ok2 := parseAddr(f[2])
		if !ok1 || !ok2 {
			continue
		}
		out = append(out, socket{proto: proto, local: lip, localPort: lport, remote: rip, remotePort: rport,
			state: strings.ToUpper(f[3])})
	}
	return out
}

// parseAddr decodes "0100007F:AB27" (IPv4) or a 32-hex-digit IPv6 address.
// The kernel prints each 32-bit word in host byte order (little endian).
func parseAddr(s string) (net.IP, int, bool) {
	host, port, ok := strings.Cut(s, ":")
	if !ok {
		return nil, 0, false
	}
	p, err := strconv.ParseUint(port, 16, 16)
	if err != nil {
		return nil, 0, false
	}
	b, err := hex.DecodeString(host)
	if err != nil || (len(b) != 4 && len(b) != 16) {
		return nil, 0, false
	}
	ip := make(net.IP, len(b))
	for w := 0; w < len(b); w += 4 {
		ip[w], ip[w+1], ip[w+2], ip[w+3] = b[w+3], b[w+2], b[w+1], b[w]
	}
	if v4 := ip.To4(); v4 != nil {
		ip = v4
	}
	return ip, int(p), true
}

func addInt(xs []int, x int) []int {
	for _, v := range xs {
		if v == x {
			return xs
		}
	}
	return append(xs, x)
}

func addStr(xs []string, x string) []string {
	for _, v := range xs {
		if v == x {
			return xs
		}
	}
	return append(xs, x)
}
