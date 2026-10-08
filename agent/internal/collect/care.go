package collect

import (
	"bufio"
	"bytes"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Slow-changing host care: pending Ubuntu updates, SSH login attempts and
// database backups. The sampler refreshes these every few minutes, not every
// sample.

// System is the OS and its pending updates, as Ubuntu's update-notifier
// last counted them.
type System struct {
	OS              string   `json:"os,omitempty"`
	UpdatesPending  int      `json:"updates_pending"`
	SecurityUpdates int      `json:"security_updates"`
	RebootRequired  bool     `json:"reboot_required"`
	RebootPackages  []string `json:"reboot_packages,omitempty"`
	// UpdatesCheckedAt is when update-notifier wrote its count; nil when it
	// never did (the counts are then unknown, not zero).
	UpdatesCheckedAt *time.Time `json:"updates_checked_at,omitempty"`
}

// ReadSystem reads /etc/os-release, update-notifier's count and the reboot
// flag under root ("/" on a real host).
func ReadSystem(root string) System {
	var s System
	if b, err := os.ReadFile(filepath.Join(root, "etc/os-release")); err == nil {
		s.OS = osName(string(b))
	}
	p := filepath.Join(root, "var/lib/update-notifier/updates-available")
	if b, err := os.ReadFile(p); err == nil {
		s.UpdatesPending, s.SecurityUpdates = parseUpdates(string(b))
		if st, err := os.Stat(p); err == nil {
			t := st.ModTime().UTC()
			s.UpdatesCheckedAt = &t
		}
	}
	run := filepath.Join(root, "run")
	if _, err := os.Stat(filepath.Join(run, "reboot-required")); err == nil {
		s.RebootRequired = true
		if b, err := os.ReadFile(filepath.Join(run, "reboot-required.pkgs")); err == nil {
			seen := map[string]bool{}
			for _, l := range strings.Fields(string(b)) {
				if !seen[l] {
					seen[l] = true
					s.RebootPackages = append(s.RebootPackages, l)
				}
			}
		}
	}
	return s
}

func osName(release string) string {
	for _, l := range strings.Split(release, "\n") {
		if v, ok := strings.CutPrefix(l, "PRETTY_NAME="); ok {
			return strings.Trim(v, `"'`)
		}
	}
	return ""
}

var (
	reUpdates  = regexp.MustCompile(`(\d+) (?:updates?|packages?) can be (?:applied|updated|installed)`)
	reSecurity = regexp.MustCompile(`(\d+) (?:of these )?(?:updates?|packages?) (?:are|is) (?:a )?(?:standard )?security update`)
)

// parseUpdates reads update-notifier's text, e.g. "14 updates can be applied
// immediately.\n5 of these updates are standard security updates."
func parseUpdates(text string) (pending, security int) {
	if m := reUpdates.FindStringSubmatch(text); m != nil {
		pending, _ = strconv.Atoi(m[1])
	}
	if m := reSecurity.FindStringSubmatch(text); m != nil {
		security, _ = strconv.Atoi(m[1])
	}
	return pending, security
}

// SSHLog is what sshd logged over the last day.
type SSHLog struct {
	// Failed24h counts login attempts that failed: unknown users and wrong
	// passwords. Public keys a client merely offers do not count.
	Failed24h int         `json:"failed_24h"`
	Sources   []SSHSource `json:"sources,omitempty"`
	// Logins are the latest successful logins, newest first.
	Logins []SSHLogin `json:"logins,omitempty"`
	// Source names where the lines came from, e.g. "/var/log/auth.log".
	Source string `json:"source,omitempty"`
}

type SSHSource struct {
	IP    string `json:"ip"`
	Count int    `json:"count"`
}

type SSHLogin struct {
	Time   time.Time `json:"time"`
	User   string    `json:"user"`
	IP     string    `json:"ip"`
	Method string    `json:"method"`
}

var (
	reInvalid  = regexp.MustCompile(`Invalid user (\S*) from (\S+)`)
	reFailed   = regexp.MustCompile(`Failed password for (\S+) from (\S+)`)
	reAccepted = regexp.MustCompile(`Accepted (\S+) for (\S+) from (\S+)`)
)

// maxSources and maxLogins keep the snapshot small.
const (
	maxSources = 30
	maxLogins  = 5
)

// ParseSSH reads auth.log lines (RFC 3339 or classic syslog stamps) and
// keeps what happened in the day before now.
func ParseSSH(r io.Reader, now time.Time) SSHLog {
	var out SSHLog
	bySource := map[string]int{}
	from := now.Add(-24 * time.Hour)
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	for sc.Scan() {
		line := sc.Text()
		if !strings.Contains(line, "sshd") {
			continue
		}
		t, ok := logTime(line, now)
		if !ok || t.Before(from) || t.After(now.Add(time.Hour)) {
			continue
		}
		if m := reInvalid.FindStringSubmatch(line); m != nil {
			out.Failed24h++
			bySource[m[2]]++
		} else if m := reFailed.FindStringSubmatch(line); m != nil && m[1] != "invalid" {
			// "Failed password for invalid user x" follows an "Invalid user"
			// line that was already counted.
			out.Failed24h++
			bySource[m[2]]++
		} else if m := reAccepted.FindStringSubmatch(line); m != nil {
			out.Logins = append(out.Logins, SSHLogin{Time: t.UTC(), User: m[2], IP: m[3], Method: m[1]})
		}
	}
	for ip, n := range bySource {
		out.Sources = append(out.Sources, SSHSource{IP: ip, Count: n})
	}
	sort.Slice(out.Sources, func(i, j int) bool {
		if out.Sources[i].Count != out.Sources[j].Count {
			return out.Sources[i].Count > out.Sources[j].Count
		}
		return out.Sources[i].IP < out.Sources[j].IP
	})
	if len(out.Sources) > maxSources {
		out.Sources = out.Sources[:maxSources]
	}
	sort.SliceStable(out.Logins, func(i, j int) bool { return out.Logins[i].Time.After(out.Logins[j].Time) })
	if len(out.Logins) > maxLogins {
		out.Logins = out.Logins[:maxLogins]
	}
	return out
}

// logTime reads "2026-10-08T09:12:01.123456+00:00 host ..." or
// "Oct  8 09:12:01 host ..." (no year: the latest such date not after now).
func logTime(line string, now time.Time) (time.Time, bool) {
	if sp := strings.IndexByte(line, ' '); sp > 0 {
		if t, err := time.Parse(time.RFC3339Nano, line[:sp]); err == nil {
			return t, true
		}
	}
	if len(line) < 15 {
		return time.Time{}, false
	}
	t, err := time.ParseInLocation("Jan _2 15:04:05", line[:15], now.Location())
	if err != nil {
		return time.Time{}, false
	}
	t = t.AddDate(now.Year(), 0, 0)
	if t.After(now.Add(24 * time.Hour)) {
		t = t.AddDate(-1, 0, 0)
	}
	return t, true
}

// ReadSSH reads the last few megabytes of the first auth log that exists.
func ReadSSH(paths []string, now time.Time) (SSHLog, error) {
	var lastErr error
	for _, p := range paths {
		b, err := tail(p, 8<<20)
		if err != nil {
			lastErr = err
			continue
		}
		l := ParseSSH(bytes.NewReader(b), now)
		l.Source = p
		return l, nil
	}
	return SSHLog{}, lastErr
}

func tail(path string, max int64) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if st.Size() > max {
		if _, err := f.Seek(st.Size()-max, io.SeekStart); err != nil {
			return nil, err
		}
	}
	return io.ReadAll(f)
}

// Backup is the dumps of one database container the app made over SSH
// ("<container>-<UTC stamp>.sql.gz" in the backup folder).
type Backup struct {
	Container  string    `json:"container"`
	Newest     time.Time `json:"newest"`
	NewestSize int64     `json:"newest_bytes"`
	Count      int       `json:"count"`
	TotalBytes int64     `json:"total_bytes"`
	// Nightly: a cron job made by the app runs the dump every night.
	Nightly bool `json:"nightly,omitempty"`
}

// BackupDir is where the app's backup script writes dumps.
const BackupDir = "/var/backups/monitor"

// ReadBackups lists dumps per container in dir; cronDir marks the ones with
// a nightly job ("monitor-backup-<container>").
func ReadBackups(dir, cronDir string) []Backup {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	by := map[string]*Backup{}
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || strings.HasSuffix(name, ".part") {
			continue
		}
		ctr, ok := dumpContainer(name)
		if !ok {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		b := by[ctr]
		if b == nil {
			b = &Backup{Container: ctr}
			by[ctr] = b
		}
		b.Count++
		b.TotalBytes += info.Size()
		if info.ModTime().After(b.Newest) {
			b.Newest, b.NewestSize = info.ModTime().UTC(), info.Size()
		}
	}
	if crons, err := os.ReadDir(cronDir); err == nil {
		for _, c := range crons {
			if ctr, ok := strings.CutPrefix(c.Name(), "monitor-backup-"); ok {
				if by[ctr] == nil {
					by[ctr] = &Backup{Container: ctr}
				}
				by[ctr].Nightly = true
			}
		}
	}
	out := make([]Backup, 0, len(by))
	for _, b := range by {
		out = append(out, *b)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Container < out[j].Container })
	return out
}

// reDump matches "db-1-20261008-031700.sql.gz" (and .sql, .dump).
var reDump = regexp.MustCompile(`^(.+)-(\d{8}-\d{6})\.(sql\.gz|sql|dump)$`)

func dumpContainer(name string) (string, bool) {
	m := reDump.FindStringSubmatch(name)
	if m == nil {
		return "", false
	}
	return m[1], true
}
