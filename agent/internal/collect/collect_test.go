package collect

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func writeProc(t *testing.T, dir string, files map[string]string) {
	t.Helper()
	for name, body := range files {
		p := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

const netDev = `Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 5000      10    0    0    0     0          0         0     5000      10    0    0    0     0       0          0
  eth0: %d    100    0    0    0     0          0         0   %d     90    0    0    0     0       0          0
docker0: 777      1    0    0    0     0          0         0      888      1    0    0    0     0       0          0
`

func fakeProc(t *testing.T, cpu string, rx, tx int) string {
	dir := t.TempDir()
	writeProc(t, dir, map[string]string{
		"uptime":  "3600.50 7000.00\n",
		"loadavg": "0.50 0.25 0.10 1/200 12345\n",
		"stat":    cpu + "\ncpu0 1 1 1 1 1 1 1 1 0 0\ncpu1 1 1 1 1 1 1 1 1 0 0\nintr 0\nbtime 1700000000\n",
		"meminfo": "MemTotal:        2000000 kB\nMemFree:          100000 kB\nMemAvailable:     500000 kB\n" +
			"SwapTotal:       1000000 kB\nSwapFree:         900000 kB\n",
		"mounts":  "/dev/vda1 / ext4 rw 0 0\nproc /proc proc rw 0 0\ntmpfs /run tmpfs rw 0 0\n/dev/vda1 /var/lib/docker ext4 rw 0 0\n",
		"net/dev": fmt.Sprintf(netDev, rx, tx),
	})
	return dir
}

func TestSampleComputesRates(t *testing.T) {
	dir := fakeProc(t, "cpu  100 0 100 700 100 0 0 0 0 0", 1000, 2000)
	c := New(dir, nil)
	t0 := time.Unix(1_700_000_000, 0)
	first := c.Sample(t0)
	if len(first.Errors) != 0 {
		t.Fatalf("unexpected errors: %v", first.Errors)
	}
	if first.CPU.UsagePercent != 0 || first.Network.RxBytesPerSec != 0 {
		t.Fatalf("first sample should have zero rates, got %+v %+v", first.CPU, first.Network)
	}

	// +100 user, +0 system, +300 idle, +100 iowait, +0 steal => 500 jiffies,
	// busy = 500 - 400 = 100 => 20%; iowait 20%.
	writeProc(t, dir, map[string]string{
		"stat":    "cpu  200 0 100 1000 200 0 0 0 0 0\nbtime 1700000000\n",
		"net/dev": fmt.Sprintf(netDev, 7000, 2600),
	})
	s := c.Sample(t0.Add(60 * time.Second))

	if s.CPU.UsagePercent != 20 || s.CPU.IOWait != 20 {
		t.Errorf("cpu = %+v, want usage 20 iowait 20", s.CPU)
	}
	if s.Network.RxBytesPerSec != 100 || s.Network.TxBytesPerSec != 10 {
		t.Errorf("net rates = %v/%v, want 100/10", s.Network.RxBytesPerSec, s.Network.TxBytesPerSec)
	}
	if s.Network.RxBytes != 7000 {
		t.Errorf("rx total = %d, want 7000 (lo and docker0 excluded)", s.Network.RxBytes)
	}
	if len(s.Network.Interfaces) != 3 {
		t.Errorf("interfaces = %d, want 3", len(s.Network.Interfaces))
	}
}

func TestSampleStaticValues(t *testing.T) {
	dir := fakeProc(t, "cpu  1 1 1 1 1 1 1 1 0 0", 0, 0)
	s := New(dir, nil).Sample(time.Now())

	if s.UptimeSeconds != 3600.5 {
		t.Errorf("uptime = %v", s.UptimeSeconds)
	}
	if !s.BootTime.Equal(time.Unix(1700000000, 0)) {
		t.Errorf("boot = %v", s.BootTime)
	}
	if s.CPU.Cores != 2 {
		t.Errorf("cores = %d, want 2", s.CPU.Cores)
	}
	if s.Load != (Load{0.5, 0.25, 0.1}) {
		t.Errorf("load = %+v", s.Load)
	}
	m := s.Memory
	if m.TotalBytes != 2000000*1024 || m.AvailableBytes != 500000*1024 || m.UsedPercent != 75 {
		t.Errorf("memory = %+v", m)
	}
	if m.SwapFreeBytes != 900000*1024 {
		t.Errorf("swap free = %d", m.SwapFreeBytes)
	}
}

func TestCounterResetGivesZeroRate(t *testing.T) {
	if got := rate(1000, 10, 60); got != 0 {
		t.Errorf("rate after reset = %v, want 0", got)
	}
	prev := cpuTimes{user: 1000, idle: 1000}
	if got := cpuUsage(prev, cpuTimes{user: 10, idle: 10}, 1); got.UsagePercent != 0 {
		t.Errorf("cpu after reset = %v, want 0", got.UsagePercent)
	}
}

func TestReadMountsFiltersAndDedupes(t *testing.T) {
	dir := t.TempDir()
	writeProc(t, dir, map[string]string{"mounts": "/dev/vda1 / ext4 rw 0 0\n" +
		"/dev/vda1 /var/lib/docker ext4 rw 0 0\n" +
		"overlay /var/lib/docker/overlay2/x/merged overlay rw 0 0\n" +
		"/dev/vdb1 /mnt/my\\040data xfs rw 0 0\n" +
		"tmpfs /run tmpfs rw 0 0\n"})
	m, err := readMounts(filepath.Join(dir, "mounts"))
	if err != nil {
		t.Fatal(err)
	}
	if len(m) != 2 || m[0].point != "/" || m[1].point != "/mnt/my data" {
		t.Errorf("mounts = %+v", m)
	}
}

func TestMissingFilesAreReportedNotFatal(t *testing.T) {
	s := New(t.TempDir(), nil).Sample(time.Now())
	if len(s.Errors) < 5 {
		t.Errorf("expected errors for every missing file, got %v", s.Errors)
	}
}

func TestSkipIface(t *testing.T) {
	for name, want := range map[string]bool{
		"lo": true, "eth0": false, "ens3": false, "docker0": true, "br-1a2b": true,
		"veth12": true, "wg0": true, "awg0": true, "tun0": true, "local1": false,
	} {
		if got := skipIface(name); got != want {
			t.Errorf("skipIface(%q) = %v, want %v", name, got, want)
		}
	}
}

func TestUsedPercentMatchesDf(t *testing.T) {
	// 100 blocks, 10 free of which 5 are reserved for root: df shows 90/(90+5).
	if got := usedPercent(100, 10, 5); got != 94.74 {
		t.Errorf("usedPercent = %v, want 94.74", got)
	}
	if got := usedPercent(0, 0, 0); got != 0 {
		t.Errorf("usedPercent(empty) = %v", got)
	}
}
