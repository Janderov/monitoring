// Package config loads and saves the agent configuration file.
package config

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/Janderov/monitoring/agent/internal/probe"
)

// DefaultPath is where the installer puts the configuration.
const DefaultPath = "/etc/monitor-agent/config.json"

// Config is the on-disk agent configuration.
type Config struct {
	// Listen is the HTTPS listen address, e.g. ":9443".
	Listen string `json:"listen"`
	// Token is the shared secret the Mac app sends as a Bearer token.
	Token string `json:"token"`
	// CertFile and KeyFile hold the self-signed TLS certificate.
	CertFile string `json:"cert_file"`
	KeyFile  string `json:"key_file"`
	// Interval between samples, as a Go duration string ("60s").
	Interval Duration `json:"interval"`
	// BufferSize is how many samples are kept in memory (1440 = 24h at 1/min).
	BufferSize int `json:"buffer_size"`
	// ProcRoot lets tests point the collector at a fake /proc.
	ProcRoot string `json:"proc_root"`
	// DockerSocket is the Docker Engine API socket; empty disables Docker.
	DockerSocket string `json:"docker_socket"`
	// StateDir holds data the agent writes, such as the check list from the Mac.
	StateDir string `json:"state_dir"`
	// Services are local daemons to watch. Absent (null) means detect the
	// known ones (PostgreSQL, MySQL) when the agent starts; [] means none.
	Services []probe.ServiceSpec `json:"services"`
}

// Duration wraps time.Duration so it reads and writes as "60s" in JSON.
type Duration struct{ time.Duration }

func (d Duration) MarshalJSON() ([]byte, error) { return json.Marshal(d.String()) }

func (d *Duration) UnmarshalJSON(b []byte) error {
	var s string
	if err := json.Unmarshal(b, &s); err != nil {
		return err
	}
	v, err := time.ParseDuration(s)
	if err != nil {
		return err
	}
	d.Duration = v
	return nil
}

// Default returns a configuration with all defaults filled in, rooted at dir.
func Default(dir string) Config {
	return Config{
		Listen:       ":9443",
		CertFile:     filepath.Join(dir, "cert.pem"),
		KeyFile:      filepath.Join(dir, "key.pem"),
		Interval:     Duration{time.Minute},
		BufferSize:   1440,
		ProcRoot:     "/proc",
		DockerSocket: "/var/run/docker.sock",
		StateDir:     "/var/lib/monitor-agent",
	}
}

// Load reads and validates the configuration at path.
func Load(path string) (Config, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return Config{}, err
	}
	c := Default(filepath.Dir(path))
	if err := json.Unmarshal(b, &c); err != nil {
		return Config{}, fmt.Errorf("parse %s: %w", path, err)
	}
	return c, c.Validate()
}

// Save writes the configuration readable only by its owner.
func Save(path string, c Config) error {
	b, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(b, '\n'), 0o600)
}

// Validate checks the fields the agent cannot run without.
func (c Config) Validate() error {
	switch {
	case len(c.Token) < 32:
		return errors.New("token must be at least 32 characters")
	case c.Listen == "":
		return errors.New("listen address is empty")
	case c.Interval.Duration < time.Second:
		return errors.New("interval must be at least 1s")
	case c.BufferSize < 1:
		return errors.New("buffer_size must be positive")
	}
	return nil
}

// NewToken returns a random 256-bit token as hex.
func NewToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}
