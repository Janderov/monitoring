// Package docker lists containers through the Docker Engine API on a unix
// socket, using only GET requests.
package docker

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/Janderov/monitoring/agent/internal/collect"
)

type Client struct {
	http *http.Client
}

func New(socket string) *Client {
	tr := &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, "unix", socket)
		},
	}
	return &Client{http: &http.Client{Transport: tr, Timeout: 5 * time.Second}}
}

type apiContainer struct {
	ID     string   `json:"Id"`
	Names  []string `json:"Names"`
	Image  string   `json:"Image"`
	State  string   `json:"State"`
	Status string   `json:"Status"`
}

// List returns all containers, running or not.
func (c *Client) List() ([]collect.Container, error) {
	resp, err := c.http.Get("http://docker/containers/json?all=1")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("docker API: %s", resp.Status)
	}
	var raw []apiContainer
	if err := json.NewDecoder(resp.Body).Decode(&raw); err != nil {
		return nil, err
	}
	return convert(raw), nil
}

func convert(raw []apiContainer) []collect.Container {
	out := make([]collect.Container, 0, len(raw))
	for _, r := range raw {
		name := ""
		if len(r.Names) > 0 {
			name = strings.TrimPrefix(r.Names[0], "/")
		}
		id := r.ID
		if len(id) > 12 {
			id = id[:12]
		}
		out = append(out, collect.Container{ID: id, Name: name, Image: r.Image, State: r.State, Status: r.Status, Health: health(r.Status)})
	}
	return out
}

// health extracts the healthcheck state from the list API's Status text,
// e.g. "Up 2 weeks (healthy)" or "Up 5 seconds (health: starting)".
func health(status string) string {
	switch {
	case strings.HasSuffix(status, "(healthy)"):
		return "healthy"
	case strings.HasSuffix(status, "(unhealthy)"):
		return "unhealthy"
	case strings.HasSuffix(status, "(health: starting)"):
		return "starting"
	}
	return ""
}

// Pid returns the main process id of a running container (0 when stopped),
// whose /proc/<pid>/net shows the container's own network namespace.
func (c *Client) Pid(container string) (int, error) {
	var info struct {
		State struct {
			Pid int `json:"Pid"`
		} `json:"State"`
	}
	if err := c.getJSON("/containers/"+container+"/json", &info); err != nil {
		return 0, err
	}
	return info.State.Pid, nil
}
