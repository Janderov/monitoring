package collect

import "time"

// Process is one entry of the top-N list by CPU or memory.
type Process struct {
	PID        int     `json:"pid"`
	Name       string  `json:"name"`
	CPUPercent float64 `json:"cpu_percent"` // of one core; can exceed 100
	RSSBytes   uint64  `json:"rss_bytes"`
}

// VPN is the state of one AmneziaVPN container.
type VPN struct {
	Container     string    `json:"container"`
	Protocol      string    `json:"protocol"`
	Running       bool      `json:"running"`
	Clients       int       `json:"clients"`
	ActiveClients int       `json:"active_clients"`
	RxBytes       uint64    `json:"rx_bytes"`
	TxBytes       uint64    `json:"tx_bytes"`
	Peers         []VPNPeer `json:"peers,omitempty"`
	Error         string    `json:"error,omitempty"`
}

// VPNPeer is one configured client. Rx is what the server received from the
// client (client upload), Tx what it sent (client download).
type VPNPeer struct {
	Name            string     `json:"name,omitempty"`
	PublicKey       string     `json:"public_key"`
	LatestHandshake *time.Time `json:"latest_handshake,omitempty"`
	Active          bool       `json:"active"`
	RxBytes         uint64     `json:"rx_bytes"`
	TxBytes         uint64     `json:"tx_bytes"`
}

// Service is a local daemon check: is the process running, does the port answer.
type Service struct {
	Name           string  `json:"name"`
	Kind           string  `json:"kind"`
	ProcessRunning bool    `json:"process_running"`
	Port           int     `json:"port,omitempty"`
	PortOpen       bool    `json:"port_open"`
	LatencyMs      float64 `json:"latency_ms,omitempty"`
	Error          string  `json:"error,omitempty"`
}

// Check is the result of probing a site or a neighbour server from this agent.
type Check struct {
	ID         string     `json:"id"`
	Kind       string     `json:"kind"`
	Target     string     `json:"target"`
	OK         bool       `json:"ok"`
	StatusCode int        `json:"status_code,omitempty"`
	LatencyMs  float64    `json:"latency_ms"`
	TLSExpiry  *time.Time `json:"tls_expiry,omitempty"`
	Error      string     `json:"error,omitempty"`
}
