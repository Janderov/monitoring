package collect

import (
	"path/filepath"
	"testing"
	"time"
)

type fakeLister []Container

func (f fakeLister) List() ([]Container, error) {
	out := make([]Container, len(f))
	copy(out, f)
	return out, nil
}

func TestContainerUsageCgroupV2(t *testing.T) {
	proc := fakeProc(t, "cpu 100 0 100 800 0 0 0 0 0 0", 1000, 2000)
	cg := t.TempDir()
	scope := filepath.Join("system.slice", "docker-aaaabbbbccccdddd.scope")
	write := func(usec string) {
		writeProc(t, cg, map[string]string{
			filepath.Join(scope, "cpu.stat"):       "usage_usec " + usec + "\nuser_usec 1\n",
			filepath.Join(scope, "memory.current"): "300000000\n",
			filepath.Join(scope, "memory.stat"):    "anon 1\ninactive_file 100000000\n",
			filepath.Join(scope, "memory.max"):     "max\n",
		})
	}
	write("1000000")
	c := New(proc, fakeLister{
		{ID: "aaaabbbbcccc", FullID: "aaaabbbbccccdddd", Name: "web", State: "running"},
		{ID: "eeee", FullID: "eeee", Name: "old", State: "exited"},
	})
	c.CgroupRoot = cg

	t0 := time.Unix(1700000000, 0)
	s := c.Sample(t0)
	web := s.Containers[0]
	if web.MemBytes == nil || *web.MemBytes != 200000000 {
		t.Fatalf("mem = %v, want 200000000 (current minus inactive_file)", web.MemBytes)
	}
	if web.CPUPercent != nil {
		t.Fatalf("first sample has CPU %v, want none", *web.CPUPercent)
	}
	if web.MemLimitBytes != nil {
		t.Fatalf("limit %v, want none for \"max\"", *web.MemLimitBytes)
	}
	if s.Containers[1].MemBytes != nil {
		t.Fatal("stopped container got usage")
	}

	// 30 s of CPU over 60 s is half a core.
	write("31000000")
	s = c.Sample(t0.Add(time.Minute))
	if p := s.Containers[0].CPUPercent; p == nil || *p != 50 {
		t.Fatalf("cpu = %v, want 50", p)
	}
}

func TestContainerUsageCgroupV1(t *testing.T) {
	proc := fakeProc(t, "cpu 100 0 100 800 0 0 0 0 0 0", 1000, 2000)
	cg := t.TempDir()
	writeProc(t, cg, map[string]string{
		"cpuacct/docker/abc/cpuacct.usage":        "5000000000\n",
		"memory/docker/abc/memory.usage_in_bytes": "1000\n",
		"memory/docker/abc/memory.stat":           "total_inactive_file 400\n",
		"memory/docker/abc/memory.limit_in_bytes": "2048\n",
	})
	c := New(proc, fakeLister{{ID: "abc", FullID: "abc", State: "running"}})
	c.CgroupRoot = cg
	ct := c.Sample(time.Now()).Containers[0]
	if ct.MemBytes == nil || *ct.MemBytes != 600 || ct.MemLimitBytes == nil || *ct.MemLimitBytes != 2048 {
		t.Fatalf("got mem %v limit %v", ct.MemBytes, ct.MemLimitBytes)
	}
}
