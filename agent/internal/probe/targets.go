package probe

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"sync"
	"time"

	"github.com/Janderov/monitoring/agent/internal/collect"
)

const (
	defaultTimeout = 10 * time.Second
	maxTargets     = 100
	// maxConcurrent bounds parallel probes so a long list cannot spike load.
	maxConcurrent = 8
)

// Target is a site or server this agent should probe. The Mac app sets the
// list through PUT /v1/checks.
type Target struct {
	ID   string `json:"id"`
	Kind string `json:"kind"` // "http" or "tcp"
	// URL for "http" targets.
	URL string `json:"url,omitempty"`
	// Host and Port for "tcp" targets (e.g. a neighbour server's SSH or agent port).
	Host string `json:"host,omitempty"`
	Port int    `json:"port,omitempty"`
	// TimeoutSeconds defaults to 10.
	TimeoutSeconds int `json:"timeout_seconds,omitempty"`
}

func (t Target) validate() error {
	if t.ID == "" {
		return errors.New("target id is empty")
	}
	switch t.Kind {
	case "http":
		u, err := url.Parse(t.URL)
		if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
			return fmt.Errorf("target %s: url must be http(s)://host/...", t.ID)
		}
	case "tcp":
		if t.Host == "" || t.Port < 1 || t.Port > 65535 {
			return fmt.Errorf("target %s: host and port 1-65535 required", t.ID)
		}
	default:
		return fmt.Errorf("target %s: kind must be http or tcp", t.ID)
	}
	if t.TimeoutSeconds < 0 || t.TimeoutSeconds > 30 {
		return fmt.Errorf("target %s: timeout_seconds must be 0-30", t.ID)
	}
	return nil
}

func (t Target) timeout() time.Duration {
	if t.TimeoutSeconds > 0 {
		return time.Duration(t.TimeoutSeconds) * time.Second
	}
	return defaultTimeout
}

// Validate checks a full target list.
func Validate(targets []Target) error {
	if len(targets) > maxTargets {
		return fmt.Errorf("at most %d targets", maxTargets)
	}
	seen := map[string]bool{}
	for _, t := range targets {
		if err := t.validate(); err != nil {
			return err
		}
		if seen[t.ID] {
			return fmt.Errorf("duplicate target id %s", t.ID)
		}
		seen[t.ID] = true
	}
	return nil
}

// Store holds the target list and persists it to a file so it survives restarts.
type Store struct {
	path    string
	mu      sync.RWMutex
	targets []Target
}

// OpenStore loads the list from path; a missing file means an empty list.
func OpenStore(path string) (*Store, error) {
	s := &Store{path: path}
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(b, &s.targets); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	return s, Validate(s.targets)
}

func (s *Store) Get() []Target {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return append([]Target(nil), s.targets...)
}

// Set validates, saves and replaces the list.
func (s *Store) Set(targets []Target) error {
	if err := Validate(targets); err != nil {
		return err
	}
	if targets == nil {
		targets = []Target{}
	}
	b, err := json.MarshalIndent(targets, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, s.path); err != nil {
		return err
	}
	s.mu.Lock()
	s.targets = targets
	s.mu.Unlock()
	return nil
}

// Run probes all targets in parallel and returns results in input order.
func Run(ctx context.Context, targets []Target) []collect.Check {
	out := make([]collect.Check, len(targets))
	sem := make(chan struct{}, maxConcurrent)
	var wg sync.WaitGroup
	for i, t := range targets {
		wg.Add(1)
		go func() {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			out[i] = probe(ctx, t)
		}()
	}
	wg.Wait()
	return out
}

func probe(ctx context.Context, t Target) collect.Check {
	ctx, cancel := context.WithTimeout(ctx, t.timeout())
	defer cancel()
	if t.Kind == "tcp" {
		return probeTCP(ctx, t)
	}
	return probeHTTP(ctx, t)
}

func probeTCP(ctx context.Context, t Target) collect.Check {
	addr := net.JoinHostPort(t.Host, strconv.Itoa(t.Port))
	c := collect.Check{ID: t.ID, Kind: t.Kind, Target: addr}
	start := time.Now()
	var d net.Dialer
	conn, err := d.DialContext(ctx, "tcp", addr)
	c.LatencyMs = ms(time.Since(start))
	if err != nil {
		c.Error = err.Error()
		return c
	}
	conn.Close()
	c.OK = true
	return c
}

// httpClient does not reuse connections, so each probe measures a fresh
// DNS + TCP + TLS handshake as a real visitor would see it.
var httpClient = &http.Client{
	Transport: &http.Transport{
		DisableKeepAlives: true,
		Proxy:             nil,
		TLSClientConfig:   &tls.Config{MinVersion: tls.VersionTLS12},
	},
	CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if len(via) >= 5 {
			return errors.New("too many redirects")
		}
		return nil
	},
}

func probeHTTP(ctx context.Context, t Target) collect.Check {
	c := collect.Check{ID: t.ID, Kind: t.Kind, Target: t.URL}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, t.URL, nil)
	if err != nil {
		c.Error = err.Error()
		return c
	}
	req.Header.Set("User-Agent", "monitor-agent")
	start := time.Now()
	resp, err := httpClient.Do(req)
	c.LatencyMs = ms(time.Since(start))
	if err != nil {
		c.Error = err.Error()
		return c
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<20))

	c.StatusCode = resp.StatusCode
	c.OK = resp.StatusCode < 400
	if resp.TLS != nil && len(resp.TLS.PeerCertificates) > 0 {
		exp := resp.TLS.PeerCertificates[0].NotAfter.UTC()
		c.TLSExpiry = &exp
	}
	if !c.OK {
		c.Error = resp.Status
	}
	return c
}
