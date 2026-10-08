package collect

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestParseUpdates(t *testing.T) {
	cases := []struct {
		text              string
		pending, security int
	}{
		{"\n14 updates can be applied immediately.\n5 of these updates are standard security updates.\nTo see these additional updates run: apt list --upgradable\n", 14, 5},
		{"1 update can be applied immediately.\n1 of these updates is a standard security update.\n", 1, 1},
		{"0 updates can be applied immediately.\n", 0, 0},
		{"Expanded Security Maintenance for Applications is not enabled.\n\n3 updates can be applied immediately.\n", 3, 0},
	}
	for _, c := range cases {
		p, s := parseUpdates(c.text)
		if p != c.pending || s != c.security {
			t.Errorf("%q: got %d/%d, want %d/%d", c.text, p, s, c.pending, c.security)
		}
	}
}

func TestReadSystem(t *testing.T) {
	root := t.TempDir()
	write := func(p, s string) {
		full := filepath.Join(root, p)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(s), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("etc/os-release", "NAME=\"Ubuntu\"\nPRETTY_NAME=\"Ubuntu 24.04.1 LTS\"\n")
	write("var/lib/update-notifier/updates-available", "7 updates can be applied immediately.\n2 of these updates are standard security updates.\n")
	write("run/reboot-required", "*** System restart required ***\n")
	write("run/reboot-required.pkgs", "linux-image-6.8.0-45-generic\nlinux-base\nlinux-base\n")
	s := ReadSystem(root)
	if s.OS != "Ubuntu 24.04.1 LTS" || s.UpdatesPending != 7 || s.SecurityUpdates != 2 || !s.RebootRequired {
		t.Fatalf("got %+v", s)
	}
	if len(s.RebootPackages) != 2 || s.UpdatesCheckedAt == nil {
		t.Fatalf("packages %v, checked %v", s.RebootPackages, s.UpdatesCheckedAt)
	}
	if e := ReadSystem(t.TempDir()); e.RebootRequired || e.UpdatesCheckedAt != nil {
		t.Fatalf("empty root: %+v", e)
	}
}

func TestParseSSH(t *testing.T) {
	now := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	log := strings.Join([]string{
		"2026-10-08T09:12:01.123456+00:00 nl sshd[1]: Invalid user admin from 198.51.100.7 port 51234",
		"2026-10-08T09:12:03.000000+00:00 nl sshd[1]: Failed password for invalid user admin from 198.51.100.7 port 51234 ssh2",
		"2026-10-08T09:13:00.000000+00:00 nl sshd[2]: Failed password for root from 203.0.113.9 port 4000 ssh2",
		"2026-10-08T09:14:00.000000+00:00 nl sshd[3]: Accepted publickey for root from 192.0.2.10 port 5000 ssh2: ED25519 SHA256:x",
		"2026-10-08T10:14:00.000000+00:00 nl sshd[4]: Accepted publickey for root from 192.0.2.11 port 5001 ssh2: ED25519 SHA256:y",
		"2026-10-06T09:00:00.000000+00:00 nl sshd[5]: Invalid user old from 198.51.100.99 port 1",
		"2026-10-08T09:15:00.000000+00:00 nl CRON[6]: pam_unix(cron:session): session opened",
		"Oct  8 11:00:00 nl sshd[7]: Invalid user test from 198.51.100.7 port 2",
	}, "\n")
	l := ParseSSH(strings.NewReader(log), now)
	if l.Failed24h != 3 {
		t.Fatalf("failed = %d, want 3", l.Failed24h)
	}
	if len(l.Sources) != 2 || l.Sources[0].IP != "198.51.100.7" || l.Sources[0].Count != 2 {
		t.Fatalf("sources %+v", l.Sources)
	}
	if len(l.Logins) != 2 || l.Logins[0].IP != "192.0.2.11" || l.Logins[0].Method != "publickey" {
		t.Fatalf("logins %+v", l.Logins)
	}
}

func TestLogTimeYearRollover(t *testing.T) {
	now := time.Date(2027, 1, 1, 0, 30, 0, 0, time.UTC)
	got, ok := logTime("Dec 31 23:59:00 host sshd[1]: x", now)
	if !ok || got.Year() != 2026 {
		t.Fatalf("got %v %v", got, ok)
	}
}

func TestReadBackups(t *testing.T) {
	dir, cron := t.TempDir(), t.TempDir()
	for _, n := range []string{"db-1-20261007-031700.sql.gz", "db-1-20261008-031700.sql.gz", "db-1-20261008-040000.sql.gz.part", "notes.txt", "mysql-20261001-010101.sql"} {
		if err := os.WriteFile(filepath.Join(dir, n), []byte("dump"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	old := time.Date(2026, 10, 7, 3, 17, 0, 0, time.UTC)
	os.Chtimes(filepath.Join(dir, "db-1-20261007-031700.sql.gz"), old, old)
	os.WriteFile(filepath.Join(cron, "monitor-backup-db-1"), []byte("x"), 0o644)
	os.WriteFile(filepath.Join(cron, "monitor-backup-pg2"), []byte("x"), 0o644)
	b := ReadBackups(dir, cron)
	if len(b) != 3 {
		t.Fatalf("got %+v", b)
	}
	if b[0].Container != "db-1" || b[0].Count != 2 || b[0].TotalBytes != 8 || !b[0].Nightly || b[0].Newest.Equal(old) {
		t.Fatalf("db-1: %+v", b[0])
	}
	if b[1].Container != "mysql" || b[1].Nightly {
		t.Fatalf("mysql: %+v", b[1])
	}
	if b[2].Container != "pg2" || b[2].Count != 0 || !b[2].Nightly {
		t.Fatalf("pg2: %+v", b[2])
	}
	if ReadBackups(filepath.Join(dir, "missing"), cron) != nil {
		t.Fatal("missing dir should give nil")
	}
}
