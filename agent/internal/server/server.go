// Package server exposes the agent's read-only HTTPS API.
package server

import (
	"crypto/subtle"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/Janderov/monitoring/agent/internal/buffer"
)

// maxHistory caps one /v1/history response; the Mac pages with ?since=.
const maxHistory = 500

type Server struct {
	token   []byte
	ring    *buffer.Ring
	version string
	started time.Time
}

func New(token string, ring *buffer.Ring, version string) *Server {
	return &Server{token: []byte(token), ring: ring, version: version, started: time.Now()}
}

// Handler returns the API routes, all behind token authentication.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/health", s.health)
	mux.HandleFunc("GET /v1/snapshot", s.snapshot)
	mux.HandleFunc("GET /v1/history", s.history)
	return s.auth(mux)
}

func (s *Server) auth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		if !ok || subtle.ConstantTimeCompare([]byte(got), s.token) != 1 {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) health(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"status":         "ok",
		"version":        s.version,
		"agent_uptime_s": int64(time.Since(s.started).Seconds()),
		"time":           time.Now().UTC(),
	})
}

func (s *Server) snapshot(w http.ResponseWriter, _ *http.Request) {
	snap, ok := s.ring.Latest()
	if !ok {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "no samples yet"})
		return
	}
	writeJSON(w, http.StatusOK, snap)
}

// history returns snapshots newer than ?since= (unix seconds), oldest first.
// "more" tells the client to request again from the last returned time.
func (s *Server) history(w http.ResponseWriter, r *http.Request) {
	var since time.Time
	if v := r.URL.Query().Get("since"); v != "" {
		sec, err := strconv.ParseInt(v, 10, 64)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "since must be unix seconds"})
			return
		}
		since = time.Unix(sec, 0)
	}
	items := s.ring.Since(since, maxHistory+1)
	more := len(items) > maxHistory
	if more {
		items = items[:maxHistory]
	}
	writeJSON(w, http.StatusOK, map[string]any{"snapshots": items, "more": more})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
