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
	Container string `json:"container"`
	Protocol  string `json:"protocol"`
	Running   bool   `json:"running"`
	// ClientsKnown is false for protocols whose clients the agent cannot
	// read yet (xray, openvpn, socks5proxy); their counts are then zero.
	ClientsKnown  bool      `json:"clients_known"`
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
	// Endpoint is where the peer was last seen (ip:port). For a client that
	// is its address; for an upstream server (a cascade) it is that server.
	Endpoint string `json:"endpoint,omitempty"`
	// AllowedIPs containing 0.0.0.0/0 means traffic leaves through this peer,
	// i.e. the peer is the next hop of a cascade rather than a client.
	AllowedIPs string `json:"allowed_ips,omitempty"`
}

// Link is outgoing traffic from this server to one public address: the host
// or a container connecting out, e.g. an entry VPN server relaying to an exit.
type Link struct {
	RemoteIP    string   `json:"remote_ip"`
	Ports       []int    `json:"ports"`
	Protos      []string `json:"protos"`
	Connections int      `json:"connections"`
	// Via names where the connections come from: "host" or container names.
	Via []string `json:"via"`
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
	// Auth: the probe logged in with credentials from the Mac app.
	Auth bool `json:"auth,omitempty"`
}

// Database is one PostgreSQL or MySQL container: client connections and the
// size of each database. Read once a minute at most.
type Database struct {
	Container      string   `json:"container"`
	Engine         string   `json:"engine"` // "postgresql" or "mysql"
	Connections    int      `json:"connections"`
	MaxConnections int      `json:"max_connections,omitempty"`
	Databases      []DBSize `json:"databases,omitempty"`
	Error          string   `json:"error,omitempty"`
}

type DBSize struct {
	Name      string `json:"name"`
	SizeBytes int64  `json:"size_bytes"`
}
