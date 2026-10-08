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
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/Janderov/monitoring/agent/internal/buffer"
	"github.com/Janderov/monitoring/agent/internal/collect"
	"github.com/Janderov/monitoring/agent/internal/config"
	"github.com/Janderov/monitoring/agent/internal/docker"
	"github.com/Janderov/monitoring/agent/internal/flows"
	"github.com/Janderov/monitoring/agent/internal/links"
	"github.com/Janderov/monitoring/agent/internal/pace"
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
	case "flows":
		err = cmdFlows(os.Args[2:])
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
	fmt.Fprintln(os.Stderr, "usage: monitor-agent init|run|flows|fingerprint|version [-config path]")
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

	// The Mac can change the interval at run time; see /v1/settings.
	pc, err := pace.Open(filepath.Join(c.StateDir, "pace.json"), c.Interval.Duration)
	if err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	s := &sampler{
		version:    version,
		col:        collect.New(c.ProcRoot, listerOrNil(dk)),
		docker:     dk,
		procRoot:   c.ProcRoot,
		services:   services,
		checks:     checks,
		pace:       pc,
		listenPort: listenPort(c.Listen),
		flowsFile:  flows.DefaultPath,
		// The helper writes every 30 s; a few missed rounds mean it is gone.
		flowsMaxAge: 3 * time.Minute,
	}
	// History stays one sample per minute however fast the agent samples,
	// so buffer_size still means 24 h and the Mac's database does not grow.
	ring := buffer.NewEvery(c.BufferSize, time.Minute)
	go sampleLoop(ctx, s, ring)

	srv := &http.Server{
		Addr:              c.Listen,
		Handler:           server.New(c.Token, ring, checks, pc, version).Handler(),
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

	log.Printf("monitor-agent %s listening on %s, sampling every %s", version, c.Listen, pc.Get())
	if err := srv.ListenAndServeTLS("", ""); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

// cmdFlows is the root helper: every 30 s it reads the conntrack tables of the
// host and of each container namespace and writes a summary for the agent.
// Its systemd unit gives it no network access.
func cmdFlows(args []string) error {
	fs := flag.NewFlagSet("flows", flag.ExitOnError)
	path := fs.String("config", config.DefaultPath, "config file path")
	out := fs.String("out", flows.DefaultPath, "summary file")
	every := fs.Duration("every", 30*time.Second, "interval")
	once := fs.Bool("once", false, "write one summary and exit")
	fs.Parse(args)

	c, err := config.Load(*path)
	if err != nil {
		return err
	}
	var dk *docker.Client
	if c.DockerSocket != "" {
		if _, err := os.Stat(c.DockerSocket); err == nil {
			dk = docker.New(c.DockerSocket)
		}
	}
	ignore := map[int]bool{listenPort(c.Listen): true, 22: true}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	for {
		sum := flows.Collect(flowSources(c.ProcRoot, dk), ignore, time.Now())
		if err := flows.Write(*out, sum); err != nil {
			return err
		}
		if *once {
			return nil
		}
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(*every):
		}
	}
}

// flowSources lists the host and each container with its own network
// namespace; host-network containers share the host's table.
func flowSources(procRoot string, dk *docker.Client) []flows.Source {
	src := []flows.Source{{Label: "host", NetDir: filepath.Join(procRoot, "net")}}
	if dk == nil {
		return src
	}
	seen := map[string]bool{}
	if ns, err := os.Readlink(filepath.Join(procRoot, "1", "ns", "net")); err == nil {
		seen[ns] = true
	}
	cts, err := dk.List()
	if err != nil {
		return src
	}
	for _, ct := range cts {
		if ct.State != "running" {
			continue
		}
		pid, err := dk.Pid(ct.ID)
		if err != nil || pid <= 0 {
			continue
		}
		ns, err := os.Readlink(filepath.Join(procRoot, strconv.Itoa(pid), "ns", "net"))
		if err != nil || seen[ns] {
			continue
		}
		seen[ns] = true
		src = append(src, flows.Source{Label: ct.Name, NetDir: filepath.Join(procRoot, strconv.Itoa(pid), "net")})
	}
	return src
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

// listenPort extracts the port from a listen address such as ":9443".
func listenPort(addr string) int {
	_, p, err := net.SplitHostPort(addr)
	if err != nil {
		return 0
	}
	n, _ := strconv.Atoi(p)
	return n
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
	version  string
	col      *collect.Collector
	docker   *docker.Client
	procRoot string
	services []probe.ServiceSpec
	checks   *probe.Store
	pace     *pace.Pace
	// listenPort is the agents' own port: neighbour probes to it are not traffic.
	listenPort int
	// flowsFile is written by the root helper (monitor-agent flows).
	flowsFile   string
	flowsMaxAge time.Duration
	// Database statistics run a query in each DB container, so they are
	// refreshed at most once a minute even when sampling is faster.
	dbAt    time.Time
	dbCache []collect.Database
	// Updates and SSH logins change slowly and read log files: every 5
	// minutes. Backups are one directory listing, read every sample, so a
	// dump made from the Mac shows at once.
	careAt    time.Time
	careCache care
}

type care struct {
	system collect.System
	ssh    *collect.SSHLog
	sshErr string
}

// authLogs: Ubuntu's rsyslog file, or the RHEL name. The agent reads it
// through the adm group (install.sh adds it).
var authLogs = []string{"/var/log/auth.log", "/var/log/secure"}

func (s *sampler) care(now time.Time) care {
	if now.Sub(s.careAt) < 5*time.Minute {
		return s.careCache
	}
	c := care{system: collect.ReadSystem("/")}
	if l, err := collect.ReadSSH(authLogs, now); err != nil {
		c.sshErr = "ssh log: " + err.Error()
	} else {
		c.ssh = &l
	}
	s.careCache, s.careAt = c, now
	return c
}

func (s *sampler) databases(containers []collect.Container, now time.Time) []collect.Database {
	if s.docker == nil || containers == nil {
		return nil
	}
	if now.Sub(s.dbAt) >= time.Minute-2*time.Second {
		s.dbCache, s.dbAt = s.docker.Databases(containers), now
	}
	return s.dbCache
}

// linkSources lists the host and every running container's network namespace.
func (s *sampler) linkSources(containers []collect.Container) []links.Source {
	src := []links.Source{{Label: "host", NetDir: filepath.Join(s.procRoot, "net")}}
	if s.docker == nil {
		return src
	}
	for _, ct := range containers {
		if ct.State != "running" {
			continue
		}
		if pid, err := s.docker.Pid(ct.ID); err == nil && pid > 0 {
			src = append(src, links.Source{Label: ct.Name, NetDir: filepath.Join(s.procRoot, strconv.Itoa(pid), "net")})
		}
	}
	return src
}

func (s *sampler) sample(ctx context.Context) collect.Snapshot {
	now := time.Now()
	every := s.pace.Get()
	if s.docker != nil {
		s.docker.StartRound(dockerBudget(every))
	}
	snap := s.col.Sample(now)
	snap.AgentVersion = s.version
	snap.IntervalSeconds = int(every / time.Second)
	if s.docker != nil && snap.Containers != nil {
		snap.VPN = s.docker.VPN(snap.Containers, now)
	}
	snap.Databases = s.databases(snap.Containers, now)
	c := s.care(now)
	sys := c.system
	snap.System, snap.SSH = &sys, c.ssh
	snap.Backups = collect.ReadBackups(collect.BackupDir, "/etc/cron.d")
	if c.sshErr != "" {
		snap.Errors = append(snap.Errors, c.sshErr)
	}
	snap.Services = probe.Services(s.procRoot, s.services)
	snap.Links = links.Collect(s.linkSources(snap.Containers), map[int]bool{s.listenPort: true})
	if f := flows.Read(s.flowsFile, now, s.flowsMaxAge); f != nil {
		snap.Forwards, snap.Inbound = f.Forwards, f.Inbound
	}
	if targets := s.checks.Get(); len(targets) > 0 {
		// Remote checks must finish before the next sample is due.
		ctx, cancel := context.WithTimeout(ctx, every*3/4)
		snap.Checks = probe.Run(ctx, targets)
		cancel()
	}
	return snap
}

// dockerBudget is how long all Docker calls of one sample may take together:
// half the interval, between 5 and 20 s.
func dockerBudget(every time.Duration) time.Duration {
	return min(max(every/2, 5*time.Second), 20*time.Second)
}

// sampleLoop takes one snapshot immediately, then one per interval, counted
// start to start. A new interval from the Mac applies to the current wait.
func sampleLoop(ctx context.Context, s *sampler, ring *buffer.Ring) {
	// The first CPU, network and process rates need a previous sample; take a
	// short warm-up sample so the first stored snapshot already has real rates.
	s.col.Sample(time.Now())
	select {
	case <-ctx.Done():
		return
	case <-time.After(time.Second):
	}

	for {
		start := time.Now()
		snap := s.sample(ctx)
		for _, e := range snap.Errors {
			log.Printf("sample: %s", e)
		}
		ring.Add(snap)
	wait:
		for {
			t := time.NewTimer(time.Until(start.Add(s.pace.Get())))
			select {
			case <-ctx.Done():
				t.Stop()
				return
			case <-s.pace.Changed():
				t.Stop()
			case <-t.C:
				break wait
			}
		}
	}
}
