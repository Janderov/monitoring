// Package probe checks local services and remote targets (sites, neighbour
// servers) from this agent.
package probe

import (
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/Janderov/monitoring/agent/internal/collect"
)

// ServiceSpec describes a local daemon to watch. It is stored in the config.
type ServiceSpec struct {
	Name      string   `json:"name"`
	Kind      string   `json:"kind"`
	Processes []string `json:"processes"`
	Port      int      `json:"port,omitempty"`
}

// Known services the agent looks for when none are configured.
var Known = []ServiceSpec{
	{Name: "PostgreSQL", Kind: "postgresql", Processes: []string{"postgres"}, Port: 5432},
	{Name: "MySQL", Kind: "mysql", Processes: []string{"mysqld", "mariadbd"}, Port: 3306},
}

// Detect returns the known services that are present on this host right now
// (process running or port open). Used once at install time.
func Detect(procRoot string) []ServiceSpec {
	running := processNames(procRoot)
	var out []ServiceSpec
	for _, s := range Known {
		if anyRunning(running, s.Processes) || portOpen(s.Port, time.Second) {
			out = append(out, s)
		}
	}
	return out
}

// Services checks each configured service.
func Services(procRoot string, specs []ServiceSpec) []collect.Service {
	if len(specs) == 0 {
		return nil
	}
	running := processNames(procRoot)
	out := make([]collect.Service, 0, len(specs))
	for _, s := range specs {
		r := collect.Service{Name: s.Name, Kind: s.Kind, Port: s.Port}
		r.ProcessRunning = anyRunning(running, s.Processes)
		if s.Port > 0 {
			start := time.Now()
			conn, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(s.Port)), 2*time.Second)
			if err != nil {
				r.Error = err.Error()
			} else {
				r.PortOpen = true
				r.LatencyMs = ms(time.Since(start))
				conn.Close()
			}
		}
		out = append(out, r)
	}
	return out
}

// processNames returns the comm of every process. Processes in Docker
// containers share the host PID namespace view, so they are included.
func processNames(procRoot string) map[string]bool {
	names := map[string]bool{}
	entries, err := os.ReadDir(procRoot)
	if err != nil {
		return names
	}
	for _, e := range entries {
		if _, err := strconv.Atoi(e.Name()); err != nil {
			continue
		}
		b, err := os.ReadFile(filepath.Join(procRoot, e.Name(), "comm"))
		if err == nil {
			names[strings.TrimSpace(string(b))] = true
		}
	}
	return names
}

func anyRunning(running map[string]bool, procs []string) bool {
	for _, p := range procs {
		if running[p] {
			return true
		}
	}
	return false
}

func portOpen(port int, timeout time.Duration) bool {
	if port <= 0 {
		return false
	}
	conn, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), timeout)
	if err != nil {
		return false
	}
	conn.Close()
	return true
}

func ms(d time.Duration) float64 { return float64(d.Microseconds()) / 1000 }
