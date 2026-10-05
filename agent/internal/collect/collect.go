// Package collect reads host metrics from /proc and the filesystem.
package collect

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Snapshot is one sample of host state. Rates are computed against the
// previous sample, so the first snapshot after start has zero rates.
type Snapshot struct {
	Time          time.Time   `json:"time"`
	Hostname      string      `json:"hostname"`
	UptimeSeconds float64     `json:"uptime_seconds"`
	BootTime      time.Time   `json:"boot_time"`
	CPU           CPU         `json:"cpu"`
	Memory        Memory      `json:"memory"`
	Load          Load        `json:"load"`
	Disks         []Disk      `json:"disks"`
	Network       Network     `json:"network"`
	Containers    []Container `json:"containers,omitempty"`
	Processes     []Process   `json:"processes,omitempty"`
	VPN           []VPN       `json:"vpn,omitempty"`
	Services      []Service   `json:"services,omitempty"`
	Checks        []Check     `json:"checks,omitempty"`
	Errors        []string    `json:"errors,omitempty"`
}

type CPU struct {
	Cores        int     `json:"cores"`
	UsagePercent float64 `json:"usage_percent"`
	IOWait       float64 `json:"iowait_percent"`
	Steal        float64 `json:"steal_percent"`
}

type Memory struct {
	TotalBytes     uint64  `json:"total_bytes"`
	AvailableBytes uint64  `json:"available_bytes"`
	UsedPercent    float64 `json:"used_percent"`
	SwapTotalBytes uint64  `json:"swap_total_bytes"`
	SwapFreeBytes  uint64  `json:"swap_free_bytes"`
}

type Load struct {
	One     float64 `json:"one"`
	Five    float64 `json:"five"`
	Fifteen float64 `json:"fifteen"`
}

type Disk struct {
	Mount       string  `json:"mount"`
	Device      string  `json:"device"`
	FSType      string  `json:"fstype"`
	TotalBytes  uint64  `json:"total_bytes"`
	FreeBytes   uint64  `json:"free_bytes"`
	UsedPercent float64 `json:"used_percent"`
}

type Network struct {
	RxBytes       uint64  `json:"rx_bytes"`
	TxBytes       uint64  `json:"tx_bytes"`
	RxBytesPerSec float64 `json:"rx_bytes_per_sec"`
	TxBytesPerSec float64 `json:"tx_bytes_per_sec"`
	Interfaces    []Iface `json:"interfaces"`
}

type Iface struct {
	Name    string `json:"name"`
	RxBytes uint64 `json:"rx_bytes"`
	TxBytes uint64 `json:"tx_bytes"`
}

// Container is the subset of Docker state the Mac app needs.
type Container struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Image  string `json:"image"`
	State  string `json:"state"`
	Status string `json:"status"`
	// Health is the Docker healthcheck result: "healthy", "unhealthy",
	// "starting", or empty when the container has no healthcheck.
	Health string `json:"health,omitempty"`
}

// ContainerLister is implemented by the docker package; nil disables it.
type ContainerLister interface {
	List() ([]Container, error)
}

// Collector keeps the previous counters so it can report rates.
type Collector struct {
	procRoot string
	docker   ContainerLister

	mu        sync.Mutex
	prevCPU   cpuTimes
	prevNet   Network
	prevTime  time.Time
	prevProcs map[int]procTicks
}

func New(procRoot string, docker ContainerLister) *Collector {
	return &Collector{procRoot: procRoot, docker: docker}
}

// Sample takes one snapshot. Individual probe failures are recorded in
// Snapshot.Errors instead of failing the whole sample.
func (c *Collector) Sample(now time.Time) Snapshot {
	c.mu.Lock()
	defer c.mu.Unlock()

	s := Snapshot{Time: now.UTC()}
	fail := func(what string, err error) { s.Errors = append(s.Errors, what+": "+err.Error()) }

	if h, err := os.Hostname(); err == nil {
		s.Hostname = h
	}
	if up, err := readUptime(c.path("uptime")); err != nil {
		fail("uptime", err)
	} else {
		s.UptimeSeconds = up
	}

	stat, err := readStat(c.path("stat"))
	if err != nil {
		fail("cpu", err)
	} else {
		s.BootTime = stat.boot
		s.CPU = cpuUsage(c.prevCPU, stat.total, stat.cores)
		c.prevCPU = stat.total
	}

	if m, err := readMeminfo(c.path("meminfo")); err != nil {
		fail("memory", err)
	} else {
		s.Memory = m
	}
	if l, err := readLoadavg(c.path("loadavg")); err != nil {
		fail("load", err)
	} else {
		s.Load = l
	}
	if d, err := readDisks(c.path("mounts")); err != nil {
		fail("disks", err)
	} else {
		s.Disks = d
	}

	if n, err := readNetDev(c.path("net/dev")); err != nil {
		fail("network", err)
	} else {
		if !c.prevTime.IsZero() {
			dt := now.Sub(c.prevTime).Seconds()
			n.RxBytesPerSec = rate(c.prevNet.RxBytes, n.RxBytes, dt)
			n.TxBytesPerSec = rate(c.prevNet.TxBytes, n.TxBytes, dt)
		}
		s.Network = n
		c.prevNet = n
	}
	if ps, cur, err := readProcesses(c.procRoot, c.prevProcs, now.Sub(c.prevTime).Seconds(), topProcesses); err != nil {
		fail("processes", err)
	} else {
		if !c.prevTime.IsZero() {
			s.Processes = ps
		}
		c.prevProcs = cur
	}
	c.prevTime = now

	if c.docker != nil {
		if cs, err := c.docker.List(); err != nil {
			fail("docker", err)
		} else {
			s.Containers = cs
		}
	}
	return s
}

func (c *Collector) path(name string) string { return filepath.Join(c.procRoot, name) }

// rate returns bytes/sec, treating a counter reset (reboot, iface reset) as zero.
func rate(prev, cur uint64, seconds float64) float64 {
	if cur < prev || seconds <= 0 {
		return 0
	}
	return round2(float64(cur-prev) / seconds)
}

func readUptime(path string) (float64, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}
	f := strings.Fields(string(b))
	if len(f) == 0 {
		return 0, fmt.Errorf("empty %s", path)
	}
	return strconv.ParseFloat(f[0], 64)
}

func readLoadavg(path string) (Load, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return Load{}, err
	}
	f := strings.Fields(string(b))
	if len(f) < 3 {
		return Load{}, fmt.Errorf("malformed %s", path)
	}
	var l Load
	var vals [3]float64
	for i := range vals {
		if vals[i], err = strconv.ParseFloat(f[i], 64); err != nil {
			return Load{}, err
		}
	}
	l.One, l.Five, l.Fifteen = vals[0], vals[1], vals[2]
	return l, nil
}

func readMeminfo(path string) (Memory, error) {
	f, err := os.Open(path)
	if err != nil {
		return Memory{}, err
	}
	defer f.Close()

	kv := map[string]uint64{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		name, rest, ok := strings.Cut(sc.Text(), ":")
		if !ok {
			continue
		}
		fields := strings.Fields(rest)
		if len(fields) == 0 {
			continue
		}
		v, err := strconv.ParseUint(fields[0], 10, 64)
		if err != nil {
			continue
		}
		kv[name] = v * 1024 // values are in kB
	}
	if err := sc.Err(); err != nil {
		return Memory{}, err
	}
	total, ok := kv["MemTotal"]
	if !ok || total == 0 {
		return Memory{}, fmt.Errorf("MemTotal missing in %s", path)
	}
	avail, ok := kv["MemAvailable"]
	if !ok { // kernels before 3.14
		avail = kv["MemFree"] + kv["Buffers"] + kv["Cached"]
	}
	return Memory{
		TotalBytes:     total,
		AvailableBytes: avail,
		UsedPercent:    round2(100 * float64(total-min(avail, total)) / float64(total)),
		SwapTotalBytes: kv["SwapTotal"],
		SwapFreeBytes:  kv["SwapFree"],
	}, nil
}

func readNetDev(path string) (Network, error) {
	f, err := os.Open(path)
	if err != nil {
		return Network{}, err
	}
	defer f.Close()

	var n Network
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		name, rest, ok := strings.Cut(sc.Text(), ":")
		if !ok {
			continue // header lines
		}
		name = strings.TrimSpace(name)
		fields := strings.Fields(rest)
		if len(fields) < 9 {
			continue
		}
		rx, err1 := strconv.ParseUint(fields[0], 10, 64)
		tx, err2 := strconv.ParseUint(fields[8], 10, 64)
		if err1 != nil || err2 != nil {
			continue
		}
		n.Interfaces = append(n.Interfaces, Iface{Name: name, RxBytes: rx, TxBytes: tx})
		if skipIface(name) {
			continue
		}
		n.RxBytes += rx
		n.TxBytes += tx
	}
	return n, sc.Err()
}

// skipIface excludes loopback and virtual interfaces from the host total so
// container and VPN traffic is not counted twice. Per-interface counters are
// still reported.
func skipIface(name string) bool {
	if name == "lo" {
		return true
	}
	// amn* is AmneziaWG's host-side interface when the container runs with
	// host networking (seen on a real server as amn0).
	for _, p := range []string{"docker", "br-", "veth", "virbr", "tun", "wg", "awg", "amn"} {
		if strings.HasPrefix(name, p) {
			return true
		}
	}
	return false
}

func round2(v float64) float64 { return float64(int64(v*100+0.5)) / 100 }
