// Package flows reads the kernel's connection tracking table (nf_conntrack) to
// find what the socket list cannot show: client traffic the server passes on
// through NAT (a VPN server masquerading its clients, a port forward to another
// server) and connections coming in from public addresses, UDP included.
//
// The table is readable only by root, so a small root helper ("monitor-agent
// flows", its own systemd unit without network access) writes the summary to
// a file and the unprivileged agent picks it up.
package flows

import (
	"bufio"
	"encoding/hex"
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/Janderov/monitoring/agent/internal/collect"
	"github.com/Janderov/monitoring/agent/internal/links"
)

// DefaultPath is where the helper writes and the agent reads the summary.
const DefaultPath = "/run/monitor-agent-flows/flows.json"

// maxEntries caps each list; VPN clients browsing produce many destinations,
// only the busiest are worth sending.
const maxEntries = 64

// Flow is one tracked connection: the original direction and the reply.
type Flow struct {
	Proto              string
	OrigSrc, OrigDst   net.IP
	OrigDport          int
	ReplySrc, ReplyDst net.IP
	ReplySport         int
	Unreplied          bool
	// Live: an established TCP connection, or a UDP flow seen both ways.
	Live bool
}

// Parse reads /proc/net/nf_conntrack lines such as
//
//	ipv4 2 tcp 6 431999 ESTABLISHED src=10.8.1.2 dst=1.1.1.1 sport=5 dport=443 src=1.1.1.1 dst=203.0.113.10 sport=443 dport=5 [ASSURED] mark=0 use=1
//
// Only TCP and UDP are kept.
func Parse(r io.Reader) []Flow {
	var out []Flow
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) < 4 || (f[2] != "tcp" && f[2] != "udp") {
			continue
		}
		fl := Flow{Proto: f[2]}
		// Closed TCP connections linger in the table (TIME_WAIT); one-off
		// checks between servers must not look like traffic being relayed.
		if f[2] == "tcp" {
			fl.Live = len(f) > 5 && f[5] == "ESTABLISHED"
		}
		var src, dst []net.IP
		var sport, dport []int
		for _, tok := range f[4:] {
			if tok == "[UNREPLIED]" {
				fl.Unreplied = true
				continue
			}
			if tok == "[ASSURED]" && f[2] == "udp" {
				fl.Live = true
				continue
			}
			k, v, ok := strings.Cut(tok, "=")
			if !ok {
				continue
			}
			switch k {
			case "src":
				src = append(src, parseIP(v))
			case "dst":
				dst = append(dst, parseIP(v))
			case "sport":
				n, _ := strconv.Atoi(v)
				sport = append(sport, n)
			case "dport":
				n, _ := strconv.Atoi(v)
				dport = append(dport, n)
			}
		}
		if len(src) < 2 || len(dst) < 2 || len(sport) < 2 || len(dport) < 2 || src[0] == nil || dst[0] == nil ||
			src[1] == nil || dst[1] == nil {
			continue
		}
		fl.OrigSrc, fl.OrigDst, fl.OrigDport = src[0], dst[0], dport[0]
		fl.ReplySrc, fl.ReplyDst, fl.ReplySport = src[1], dst[1], sport[1]
		out = append(out, fl)
	}
	return out
}

func parseIP(s string) net.IP {
	ip := net.ParseIP(s)
	if v4 := ip.To4(); v4 != nil {
		return v4
	}
	return ip
}

// Source is one network namespace: its conntrack table and local addresses.
type Source struct {
	Label  string // "host" or the container name
	NetDir string // /proc/net or /proc/<pid>/net
}

// Summary is what the helper writes and the agent sends on.
type Summary struct {
	Time     time.Time      `json:"time"`
	Forwards []collect.Link `json:"forwards"`
	Inbound  []collect.Link `json:"inbound"`
}

// Classify sorts flows of one namespace into forwards and inbound connections.
// local holds the namespace's own addresses; ignore drops ports that are not
// traffic (the agents' own port, SSH).
func Classify(label string, flows []Flow, local map[string]bool, ignore map[int]bool, fwd, in agg) {
	for _, f := range flows {
		if !f.Live {
			continue
		}
		natted := !f.OrigSrc.Equal(f.ReplyDst) || !f.OrigDst.Equal(f.ReplySrc)
		// Passed on: the address that really answers, after any port forward.
		if natted && !f.Unreplied && links.IsPublic(f.ReplySrc) && !local[f.ReplySrc.String()] {
			if !ignore[f.ReplySport] {
				fwd.add(f.ReplySrc.String(), f.ReplySport, f.Proto, "nat:"+label)
			}
			continue
		}
		// Coming in, also to ports published by containers (DNAT to a private address).
		if local[f.OrigDst.String()] && !local[f.OrigSrc.String()] && links.IsPublic(f.OrigSrc) &&
			!ignore[f.OrigDport] {
			in.add(f.OrigSrc.String(), f.OrigDport, f.Proto, label)
		}
	}
}

type agg map[string]*collect.Link

func (a agg) add(ip string, port int, proto, via string) {
	l := a[ip]
	if l == nil {
		l = &collect.Link{RemoteIP: ip}
		a[ip] = l
	}
	l.Connections++
	l.Ports = addInt(l.Ports, port)
	l.Protos = addStr(l.Protos, proto)
	l.Via = addStr(l.Via, via)
}

func (a agg) list() []collect.Link {
	out := make([]collect.Link, 0, len(a))
	for _, l := range a {
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
	if len(out) > maxEntries {
		out = out[:maxEntries]
	}
	return out
}

// Collect reads every namespace and summarises it.
func Collect(sources []Source, ignore map[int]bool, now time.Time) Summary {
	fwd, in := agg{}, agg{}
	for _, src := range sources {
		f, err := os.Open(filepath.Join(src.NetDir, "nf_conntrack"))
		if err != nil {
			continue
		}
		flows := Parse(f)
		f.Close()
		Classify(src.Label, flows, LocalAddrs(src.NetDir), ignore, fwd, in)
	}
	return Summary{Time: now.UTC(), Forwards: fwd.list(), Inbound: in.list()}
}

// LocalAddrs lists a namespace's own addresses from fib_trie (IPv4, "/32 host
// LOCAL" entries) and if_inet6 (IPv6).
func LocalAddrs(netDir string) map[string]bool {
	out := map[string]bool{}
	if f, err := os.Open(filepath.Join(netDir, "fib_trie")); err == nil {
		parseFibTrie(f, out)
		f.Close()
	}
	if f, err := os.Open(filepath.Join(netDir, "if_inet6")); err == nil {
		parseIfInet6(f, out)
		f.Close()
	}
	return out
}

func parseFibTrie(r io.Reader, out map[string]bool) {
	sc := bufio.NewScanner(r)
	var last string
	for sc.Scan() {
		t := strings.TrimSpace(sc.Text())
		if ip, ok := strings.CutPrefix(t, "|-- "); ok {
			last = ip
			continue
		}
		if strings.HasPrefix(t, "/32 host LOCAL") && last != "" {
			out[last] = true
		}
	}
}

func parseIfInet6(r io.Reader, out map[string]bool) {
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) == 0 || len(f[0]) != 32 {
			continue
		}
		b, err := hex.DecodeString(f[0])
		if err != nil {
			continue
		}
		out[net.IP(b).String()] = true
	}
}

// Write saves the summary atomically, readable by the agent's group.
func Write(path string, s Summary) error {
	b, err := json.Marshal(s)
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o640); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// Read returns the helper's summary when it is fresh; nil otherwise (helper
// not installed, stopped, or no conntrack on this kernel).
func Read(path string, now time.Time, maxAge time.Duration) *Summary {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var s Summary
	if json.Unmarshal(b, &s) != nil || now.Sub(s.Time) > maxAge {
		return nil
	}
	return &s
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
