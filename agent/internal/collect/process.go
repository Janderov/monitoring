package collect

import (
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

const (
	topProcesses = 10
	// clockTicks is USER_HZ, 100 on every mainstream Linux build (x86, arm64).
	clockTicks = 100
)

type procTicks struct {
	ticks uint64
	start uint64 // process start time, to detect PID reuse
}

// readProcesses scans /proc/[pid]/stat and returns the union of the top n
// processes by CPU and by memory, sorted by CPU. prev holds the previous
// scan's counters; the returned map is the current scan for the next call.
func readProcesses(procRoot string, prev map[int]procTicks, seconds float64, n int) ([]Process, map[int]procTicks, error) {
	entries, err := os.ReadDir(procRoot)
	if err != nil {
		return nil, nil, err
	}
	pageSize := uint64(os.Getpagesize())
	cur := make(map[int]procTicks, len(entries))
	var all []Process
	for _, e := range entries {
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		b, err := os.ReadFile(filepath.Join(procRoot, e.Name(), "stat"))
		if err != nil {
			continue // process exited between ReadDir and ReadFile
		}
		name, ticks, start, rssPages, ok := parseProcStat(string(b))
		if !ok {
			continue
		}
		cur[pid] = procTicks{ticks: ticks, start: start}
		p := Process{PID: pid, Name: name, RSSBytes: rssPages * pageSize}
		if old, seen := prev[pid]; seen && old.start == start && ticks >= old.ticks && seconds > 0 {
			p.CPUPercent = round2(100 * float64(ticks-old.ticks) / clockTicks / seconds)
		}
		all = append(all, p)
	}
	return topN(all, n), cur, nil
}

// parseProcStat extracts comm, utime+stime, starttime and rss from a
// /proc/[pid]/stat line. comm may contain spaces and parentheses, so the
// fixed fields are counted from the last ')'.
func parseProcStat(line string) (name string, ticks, start, rss uint64, ok bool) {
	open, end := strings.IndexByte(line, '('), strings.LastIndexByte(line, ')')
	if open < 0 || end < open {
		return "", 0, 0, 0, false
	}
	name = line[open+1 : end]
	f := strings.Fields(line[end+1:])
	// f[0] is field 3 (state); utime=14, stime=15, starttime=22, rss=24.
	if len(f) < 22 {
		return "", 0, 0, 0, false
	}
	var v [4]uint64
	for i, idx := range []int{11, 12, 19, 21} {
		x, err := strconv.ParseUint(f[idx], 10, 64)
		if err != nil {
			return "", 0, 0, 0, false
		}
		v[i] = x
	}
	return name, v[0] + v[1], v[2], v[3], true
}

func topN(all []Process, n int) []Process {
	pick := map[int]bool{}
	sort.Slice(all, func(i, j int) bool { return all[i].RSSBytes > all[j].RSSBytes })
	for i := 0; i < n && i < len(all); i++ {
		pick[all[i].PID] = true
	}
	sort.SliceStable(all, func(i, j int) bool { return all[i].CPUPercent > all[j].CPUPercent })
	for i := 0; i < n && i < len(all); i++ {
		pick[all[i].PID] = true
	}
	out := make([]Process, 0, len(pick))
	for _, p := range all {
		if pick[p.PID] {
			out = append(out, p)
		}
	}
	return out
}
