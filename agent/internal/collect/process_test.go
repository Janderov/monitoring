package collect

import (
	"fmt"
	"os"
	"testing"
)

func statLine(pid int, comm string, utime, stime, start, rss uint64) string {
	// Fields 3..24 after "(comm)"; only utime(14), stime(15), starttime(22), rss(24) matter.
	return fmt.Sprintf("%d (%s) S 1 1 1 0 -1 4194560 100 0 0 0 %d %d 0 0 20 0 1 0 %d 1000000 %d 18446744073709551615\n",
		pid, comm, utime, stime, start, rss)
}

func TestParseProcStatOddNames(t *testing.T) {
	name, ticks, start, rss, ok := parseProcStat(statLine(7, "my (weird) proc", 30, 12, 555, 42))
	if !ok || name != "my (weird) proc" || ticks != 42 || start != 555 || rss != 42 {
		t.Errorf("got %q %d %d %d %v", name, ticks, start, rss, ok)
	}
	if _, _, _, _, ok := parseProcStat("garbage"); ok {
		t.Error("garbage parsed")
	}
}

func TestReadProcessesCPUAndPIDReuse(t *testing.T) {
	dir := t.TempDir()
	page := uint64(os.Getpagesize())
	writeProc(t, dir, map[string]string{
		"10/stat": statLine(10, "postgres", 100, 0, 1000, 1000),
		"20/stat": statLine(20, "nginx", 50, 0, 2000, 10),
		"30/stat": statLine(30, "reused", 900, 0, 3000, 10),
	})
	_, prev, err := readProcesses(dir, nil, 0, 10)
	if err != nil {
		t.Fatal(err)
	}

	// 60s later: postgres used 30s of CPU (3000 ticks) = 50%; nginx 0.6s = 1%;
	// pid 30 was reused by a new process, so no rate.
	writeProc(t, dir, map[string]string{
		"10/stat": statLine(10, "postgres", 2100, 1000, 1000, 1000),
		"20/stat": statLine(20, "nginx", 110, 0, 2000, 10),
		"30/stat": statLine(30, "newproc", 5, 0, 9999, 10),
	})
	ps, _, err := readProcesses(dir, prev, 60, 10)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]Process{}
	for _, p := range ps {
		got[p.Name] = p
	}
	if got["postgres"].CPUPercent != 50 || got["postgres"].RSSBytes != 1000*page {
		t.Errorf("postgres = %+v", got["postgres"])
	}
	if got["nginx"].CPUPercent != 1 {
		t.Errorf("nginx = %+v", got["nginx"])
	}
	if got["newproc"].CPUPercent != 0 {
		t.Errorf("reused pid got a rate: %+v", got["newproc"])
	}
	if ps[0].Name != "postgres" {
		t.Errorf("not sorted by CPU: %+v", ps)
	}
}

func TestTopNUnionOfCPUAndMemory(t *testing.T) {
	all := []Process{
		{PID: 1, CPUPercent: 90, RSSBytes: 1},
		{PID: 2, CPUPercent: 1, RSSBytes: 900},
		{PID: 3, CPUPercent: 5, RSSBytes: 5},
	}
	got := topN(all, 1)
	if len(got) != 2 || got[0].PID != 1 || got[1].PID != 2 {
		t.Errorf("topN = %+v, want pids 1 (cpu) and 2 (mem)", got)
	}
}
