// Package docker lists containers through the Docker Engine API on a unix
// socket, using only GET requests.
package docker

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/Janderov/monitoring/agent/internal/collect"
)

type Client struct {
	http *http.Client

	mu sync.Mutex
	// deadline bounds every call of the current sample; zero means no bound.
	deadline time.Time
	// names: VPN client names per container, read every few minutes.
	names map[string]clientNames
}

// ErrBudget: an earlier call in this sample used up the time Docker gets.
var ErrBudget = errors.New("docker did not answer in time; skipped until the next sample")

// StartRound gives all Docker calls of one sample a shared time budget. Each
// call still has its own 5 s limit, but a hung Docker now costs at most
// `budget` per sample, not 5 s for every container, and the sample (CPU,
// disks) goes on without the container data.
func (c *Client) StartRound(budget time.Duration) {
	c.mu.Lock()
	c.deadline = time.Now().Add(budget)
	c.mu.Unlock()
}

// do sends one request to the Engine API within the round's budget.
func (c *Client) do(method, path string, body io.Reader) (*http.Response, error) {
	c.mu.Lock()
	dl := c.deadline
	c.mu.Unlock()
	ctx, cancel := context.Background(), context.CancelFunc(func() {})
	if !dl.IsZero() {
		if time.Until(dl) <= 0 {
			return nil, ErrBudget
		}
		ctx, cancel = context.WithDeadline(ctx, dl)
	}
	req, err := http.NewRequestWithContext(ctx, method, "http://docker"+path, body)
	if err != nil {
		cancel()
		return nil, err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.http.Do(req)
	if err != nil {
		cancel()
		if ctx.Err() != nil {
			return nil, ErrBudget
		}
		return nil, err
	}
	resp.Body = cancelOnClose{resp.Body, cancel}
	return resp, nil
}

// cancelOnClose releases the request's context once its body is read.
type cancelOnClose struct {
	io.ReadCloser
	cancel context.CancelFunc
}

func (b cancelOnClose) Close() error {
	err := b.ReadCloser.Close()
	b.cancel()
	return err
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
	resp, err := c.do(http.MethodGet, "/containers/json?all=1", nil)
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
		out = append(out, collect.Container{ID: id, FullID: r.ID, Name: name, Image: r.Image, State: r.State,
			Status: r.Status, Health: health(r.Status)})
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
