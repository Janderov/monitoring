package collect

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

// cpuTimes are the aggregate jiffy counters from the "cpu" line of /proc/stat.
type cpuTimes struct {
	user, nice, system, idle, iowait, irq, softirq, steal uint64
}

func (t cpuTimes) total() uint64 {
	return t.user + t.nice + t.system + t.idle + t.iowait + t.irq + t.softirq + t.steal
}

type statInfo struct {
	total cpuTimes
	cores int
	boot  time.Time
}

func readStat(path string) (statInfo, error) {
	f, err := os.Open(path)
	if err != nil {
		return statInfo{}, err
	}
	defer f.Close()

	var s statInfo
	found := false
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) == 0 {
			continue
		}
		switch {
		case fields[0] == "cpu":
			if len(fields) < 9 {
				return statInfo{}, fmt.Errorf("short cpu line in %s", path)
			}
			var v [8]uint64
			for i := range v {
				if v[i], err = strconv.ParseUint(fields[i+1], 10, 64); err != nil {
					return statInfo{}, err
				}
			}
			s.total = cpuTimes{v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7]}
			found = true
		case strings.HasPrefix(fields[0], "cpu"):
			s.cores++
		case fields[0] == "btime" && len(fields) > 1:
			if sec, err := strconv.ParseInt(fields[1], 10, 64); err == nil {
				s.boot = time.Unix(sec, 0).UTC()
			}
		}
	}
	if err := sc.Err(); err != nil {
		return statInfo{}, err
	}
	if !found {
		return statInfo{}, fmt.Errorf("no cpu line in %s", path)
	}
	return s, nil
}

// cpuUsage computes percentages between two samples. With no previous sample
// (or after a counter reset) it returns zero usage.
func cpuUsage(prev, cur cpuTimes, cores int) CPU {
	out := CPU{Cores: cores}
	if prev.total() == 0 || cur.total() <= prev.total() {
		return out
	}
	dt := float64(cur.total() - prev.total())
	idle := float64((cur.idle + cur.iowait) - (prev.idle + prev.iowait))
	out.UsagePercent = round2(100 * (dt - idle) / dt)
	out.IOWait = round2(100 * float64(cur.iowait-prev.iowait) / dt)
	out.Steal = round2(100 * float64(cur.steal-prev.steal) / dt)
	return out
}
