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

	var lister collect.ContainerLister
	if c.DockerSocket != "" {
		if _, err := os.Stat(c.DockerSocket); err == nil {
			lister = docker.New(c.DockerSocket)
		} else {
			log.Printf("docker socket %s not found, container monitoring off", c.DockerSocket)
		}
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	ring := buffer.New(c.BufferSize)
	col := collect.New(c.ProcRoot, lister)
	go sampleLoop(ctx, col, ring, c.Interval.Duration)

	srv := &http.Server{
		Addr:              c.Listen,
		Handler:           server.New(c.Token, ring, version).Handler(),
		TLSConfig:         &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12},
		ReadHeaderTimeout: 10 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       2 * time.Minute,
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

// sampleLoop takes one snapshot immediately, then one per interval.
func sampleLoop(ctx context.Context, col *collect.Collector, ring *buffer.Ring, every time.Duration) {
	// The first CPU and network rates need a previous sample; take a short
	// warm-up sample so the first stored snapshot already has real rates.
	col.Sample(time.Now())
	select {
	case <-ctx.Done():
		return
	case <-time.After(time.Second):
	}

	t := time.NewTicker(every)
	defer t.Stop()
	for {
		snap := col.Sample(time.Now())
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
