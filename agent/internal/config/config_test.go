package config

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestSaveLoadRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	tok, err := NewToken()
	if err != nil {
		t.Fatal(err)
	}
	c := Default(filepath.Dir(path))
	c.Token = tok
	c.Interval = Duration{30 * time.Second}
	if err := Save(path, c); err != nil {
		t.Fatal(err)
	}
	if fi, _ := os.Stat(path); fi.Mode().Perm() != 0o600 {
		t.Errorf("config mode = %v, want 0600", fi.Mode().Perm())
	}
	got, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if got != c {
		t.Errorf("round trip mismatch:\n got %+v\nwant %+v", got, c)
	}
}

func TestLoadFillsDefaults(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	os.WriteFile(path, []byte(`{"token":"0123456789abcdef0123456789abcdef"}`), 0o600)
	c, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if c.Listen != ":9443" || c.Interval.Duration != time.Minute || c.BufferSize != 1440 {
		t.Errorf("defaults not applied: %+v", c)
	}
}

func TestValidateRejectsShortToken(t *testing.T) {
	c := Default("/tmp")
	c.Token = "short"
	if c.Validate() == nil {
		t.Error("short token accepted")
	}
}
