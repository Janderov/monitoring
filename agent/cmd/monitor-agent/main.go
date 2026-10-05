// Command monitor-agent collects host metrics and serves them over HTTPS to
// the monitoring app on the Mac.
//
//	monitor-agent init [-config path] [-token T] [-host IP]...  create config and certificate
//	monitor-agent run  [-config path]                            start the agent
//	monitor-agent fingerprint [-config path]                     print the certificate fingerprint
//	monitor-agent version
package main

import (
	"context"
	"crypto/tls"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/Janderov/monitoring/agent/internal/buffer"
	"github.com/Janderov/monitoring/agent/internal/collect"
	"github.com/Janderov/monitoring/agent/internal/config"
	"github.com/Janderov/monitoring/agent/internal/docker"
	"github.com/Janderov/monitoring/agent/internal/probe"
	"github.com/Janderov/monitoring/agent/internal/server"
	"github.com/Janderov/monitoring/agent/internal/tlsutil"
)

// version is set at build time with -ldflags "-X main.version=...".
var version = "dev"

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	var err error
	switch os.Args[1] {
	case "init":
		err = cmdInit(os.Args[2:])
	case "run":
		err = cmdRun(os.Args[2:])
	case "fingerprint":
		err = cmdFingerprint(os.Args[2:])
	case "version":
		fmt.Println(version)
	default:
		usage()
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "monitor-agent:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: monitor-agent init|run|fingerprint|version [-config path]")
	os.Exit(2)
}

type hostList []string

func (h *hostList) String() string     { return strings.Join(*h, ",") }
func (h *hostList) Set(v string) error { *h = append(*h, v); return nil }

func cmdInit(args []string) error {
	fs := flag.NewFlagSet("init", flag.ExitOnError)
	path := fs.String("config", config.DefaultPath, "config file path")
	token := fs.String("token", "", "token issued by the Mac app (generated if empty)")
	tokenFile := fs.String("token-file", "", "read the token from this file instead of -token")
	listen := fs.String("listen", ":9443", "HTTPS listen address")
	force := fs.Bool("force", false, "overwrite an existing config and certificate")
	var hosts hostList
	fs.Var(&hosts, "host", "IP or DNS name to put in the certificate (repeatable)")
	fs.Parse(args)

	if _, err := os.Stat(*path); err == nil && !*force {
		return fmt.Errorf("%s already exists (use -force to replace it)", *path)
	}
	dir := filepath.Dir(*path)
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return err
	}

	c := config.Default(dir)
	c.Listen = *listen
	c.Token = *token
	if *tokenFile != "" {
		b, err := os.ReadFile(*tokenFile)
		if err != nil {
			return err
		}
		c.Token = strings.TrimSpace(string(b))
		*token = c.Token // issued by the caller, so don't echo it back
	}
	if c.Token == "" {
		t, err := config.NewToken()
		if err != nil {
			return err
		}
		c.Token = t
	}
	if err := c.Validate(); err != nil {
		return err
	}

	// Remember the databases present now, so one that goes down later is
	// reported as down instead of silently disappearing.
	if found := probe.Detect(c.ProcRoot); len(found) > 0 {
		c.Services = found
	}

	hostname, _ := os.Hostname()
	if err := tlsutil.Generate(c.CertFile, c.KeyFile, hostname, hosts); err != nil {
		return fmt.Errorf("generate certificate: %w", err)
	}
	if err := config.Save(*path, c); err != nil {
		return err
	}
	fp, err := tlsutil.Fingerprint(c.CertFile)
	if err != nil {
		return err
	}
	fmt.Printf("config:      %s\nlisten:      %s\nfingerprint: %s\n", *path, c.Listen, fp)
	for _, svc := range c.Services {
		fmt.Printf("service:     %s (port %d)\n", svc.Name, svc.Port)
	}
	if *token == "" {
		fmt.Printf("token:       %s\n", c.Token)
	}
	return nil
}

func cmdFingerprint(args []string) error {
	fs := flag.NewFlagSet("fingerprint", flag.ExitOnError)
	path := fs.String("config", config.DefaultPath, "config file path")
	fs.Parse(args)
	c, err := config.Load(*path)
	if err != nil {
		return err
	}
	fp, err := tlsutil.Fingerprint(c.CertFile)
	if err != nil {
		return err
	}
	fmt.Println(fp)
	return nil
}

func cmdRun(args []string) error {
	fs := flag.NewFlagSet("run", flag.ExitOnError)
	path := fs.String("config", config.DefaultPath, "config file path")
	fs.Parse(args)

	c, err := config.Load(*path)
	if err != nil {
		return err
	}
	cert, err := tls.LoadX509KeyPair(c.CertFile, c.KeyFile)
	if err != nil {
		return fmt.Errorf("load certificate: %w", err)
	}

	var dk *docker.Client
	if c.DockerSocket != "" {
		if _, err := os.Stat(c.DockerSocket); err == nil {
			dk = docker.New(c.DockerSocket)
		} else {
			log.Printf("docker socket %s not found, container monitoring off", c.DockerSocket)
		}
	}

	services := c.Services
	if services == nil {
		services = probe.Detect(c.ProcRoot)
		log.Printf("services not configured, detected %d", len(services))
	}

	if err := os.MkdirAll(c.StateDir, 0o700); err != nil {
		return fmt.Errorf("state dir: %w", err)
	}
	checks, err := probe.OpenStore(filepath.Join(c.StateDir, "checks.json"))
	if err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	s := &sampler{
		col:      collect.New(c.ProcRoot, listerOrNil(dk)),
		docker:   dk,
		procRoot: c.ProcRoot,
		services: services,
		checks:   checks,
		budget:   c.Interval.Duration * 3 / 4,
	}
	ring := buffer.New(c.BufferSize)
	go sampleLoop(ctx, s, ring, c.Interval.Duration)

	srv := &http.Server{
		Addr:              c.Listen,
		Handler:           server.New(c.Token, ring, checks, version).Handler(),
		TLSConfig:         &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12},
		ReadHeaderTimeout: 10 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       2 * time.Minute,
		ErrorLog:          log.New(handshakeFilter{}, "", log.LstdFlags),
	}
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		srv.Shutdown(shutdownCtx)
	}()

	log.Printf("monitor-agent %s listening on %s, sampling every %s", version, c.Listen, c.Interval.Duration)
	if err := srv.ListenAndServeTLS("", ""); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

// handshakeFilter drops "TLS handshake error" lines: neighbour agents probe
// this port with a bare TCP connect every minute, which would flood the log.
type handshakeFilter struct{}

func (handshakeFilter) Write(p []byte) (int, error) {
	if strings.Contains(string(p), "TLS handshake error") {
		return len(p), nil
	}
	return os.Stderr.Write(p)
}

// listerOrNil avoids handing collect a non-nil interface holding a nil pointer.
func listerOrNil(dk *docker.Client) collect.ContainerLister {
	if dk == nil {
		return nil
	}
	return dk
}

// sampler builds one full snapshot: host metrics, then VPN, local services
// and remote checks.
type sampler struct {
	col      *collect.Collector
	docker   *docker.Client
	procRoot string
	services []probe.ServiceSpec
	checks   *probe.Store
	budget   time.Duration // remote checks must finish within this
}

func (s *sampler) sample(ctx context.Context) collect.Snapshot {
	now := time.Now()
	snap := s.col.Sample(now)
	if s.docker != nil && snap.Containers != nil {
		snap.VPN = s.docker.VPN(snap.Containers, now)
	}
	snap.Services = probe.Services(s.procRoot, s.services)
	if targets := s.checks.Get(); len(targets) > 0 {
		ctx, cancel := context.WithTimeout(ctx, s.budget)
		snap.Checks = probe.Run(ctx, targets)
		cancel()
	}
	return snap
}

// sampleLoop takes one snapshot immediately, then one per interval.
func sampleLoop(ctx context.Context, s *sampler, ring *buffer.Ring, every time.Duration) {
	// The first CPU, network and process rates need a previous sample; take a
	// short warm-up sample so the first stored snapshot already has real rates.
	s.col.Sample(time.Now())
	select {
	case <-ctx.Done():
		return
	case <-time.After(time.Second):
	}

	t := time.NewTicker(every)
	defer t.Stop()
	for {
		snap := s.sample(ctx)
		for _, e := range snap.Errors {
			log.Printf("sample: %s", e)
		}
		ring.Add(snap)
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}
