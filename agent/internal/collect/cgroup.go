package collect

import (
	"bufio"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// containerUsage fills CPU and memory of running containers from their
// cgroups. Reading files is far cheaper than the Docker stats API, which
// needs a second per container. elapsed is the time since the last sample.
func (c *Collector) containerUsage(cs []Container, elapsed time.Duration, havePrev bool) {
	if c.CgroupRoot == "" {
		return
	}
	cur := make(map[string]time.Duration, len(cs))
	for i := range cs {
		ct := &cs[i]
		if ct.State != "running" || ct.FullID == "" {
			continue
		}
		u, ok := readCgroup(c.CgroupRoot, ct.FullID)
		if !ok {
			continue
		}
		if u.memSet {
			mem := u.mem
			ct.MemBytes = &mem
		}
		if u.limit > 0 {
			limit := u.limit
			ct.MemLimitBytes = &limit
		}
		if !u.cpuSet {
			continue
		}
		cur[ct.FullID] = u.cpu
		if prev, ok := c.prevCtr[ct.FullID]; ok && havePrev && elapsed > 0 && u.cpu >= prev {
			pct := round2(100 * float64(u.cpu-prev) / float64(elapsed))
			ct.CPUPercent = &pct
		}
	}
	c.prevCtr = cur
}

type cgroupUsage struct {
	cpu        time.Duration
	cpuSet     bool
	mem, limit uint64
	memSet     bool
}

// readCgroup looks in the places Docker puts a container's cgroup: cgroup v2
// with the systemd driver (Ubuntu 22.04 and later) or cgroupfs, then v1.
func readCgroup(root, id string) (cgroupUsage, bool) {
	for _, dir := range []string{
		filepath.Join(root, "system.slice", "docker-"+id+".scope"),
		filepath.Join(root, "docker", id),
	} {
		if u, ok := readCgroupV2(dir); ok {
			return u, true
		}
	}
	for _, rel := range []string{filepath.Join("system.slice", "docker-"+id+".scope"), filepath.Join("docker", id)} {
		if u, ok := readCgroupV1(root, rel); ok {
			return u, true
		}
	}
	return cgroupUsage{}, false
}

func readCgroupV2(dir string) (cgroupUsage, bool) {
	var u cgroupUsage
	if st, err := readKV(filepath.Join(dir, "cpu.stat")); err == nil {
		if v, ok := st["usage_usec"]; ok {
			u.cpu, u.cpuSet = time.Duration(v)*time.Microsecond, true
		}
	}
	if cur, err := readUint(filepath.Join(dir, "memory.current")); err == nil {
		st, _ := readKV(filepath.Join(dir, "memory.stat"))
		u.mem, u.memSet = cur-min(st["inactive_file"], cur), true
	}
	if limit, err := readUint(filepath.Join(dir, "memory.max")); err == nil { // "max" fails to parse: no limit
		u.limit = limit
	}
	return u, u.cpuSet || u.memSet
}

func readCgroupV1(root, rel string) (cgroupUsage, bool) {
	var u cgroupUsage
	if ns, err := readUint(filepath.Join(root, "cpuacct", rel, "cpuacct.usage")); err == nil {
		u.cpu, u.cpuSet = time.Duration(ns), true
	}
	mdir := filepath.Join(root, "memory", rel)
	if cur, err := readUint(filepath.Join(mdir, "memory.usage_in_bytes")); err == nil {
		st, _ := readKV(filepath.Join(mdir, "memory.stat"))
		u.mem, u.memSet = cur-min(st["total_inactive_file"], cur), true
	}
	// v1 reports "no limit" as a huge number near the top of int64.
	if limit, err := readUint(filepath.Join(mdir, "memory.limit_in_bytes")); err == nil && limit < 1<<60 {
		u.limit = limit
	}
	return u, u.cpuSet || u.memSet
}

func readUint(path string) (uint64, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}
	return strconv.ParseUint(strings.TrimSpace(string(b)), 10, 64)
}

// readKV parses "name value" lines such as cpu.stat and memory.stat.
func readKV(path string) (map[string]uint64, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	out := map[string]uint64{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		k, v, ok := strings.Cut(sc.Text(), " ")
		if !ok {
			continue
		}
		if n, err := strconv.ParseUint(strings.TrimSpace(v), 10, 64); err == nil {
			out[k] = n
		}
	}
	return out, sc.Err()
}
