package docker

import (
	"encoding/json"
	"strconv"
	"strings"
	"time"

	"github.com/Janderov/monitoring/agent/internal/collect"
)

// activeWindow: WireGuard re-handshakes every 2 minutes while traffic flows,
// so a peer with a handshake in the last 3 minutes is connected.
const activeWindow = 3 * time.Minute

// vpnProtocol maps an AmneziaVPN container name to its protocol. Containers
// are created by the AmneziaVPN app as "amnezia-<protocol>".
func vpnProtocol(name string) (string, bool) {
	p, ok := strings.CutPrefix(name, "amnezia-")
	if !ok || p == "" || p == "dns" {
		return "", false
	}
	return p, true
}

// isWireGuard reports whether the protocol exposes `wg show` (AmneziaWG and
// plain WireGuard). Others (xray, openvpn, ...) only report running state.
func isWireGuard(protocol string) bool {
	return strings.HasPrefix(protocol, "awg") || protocol == "wireguard"
}

// VPN inspects every AmneziaVPN container in containers.
func (c *Client) VPN(containers []collect.Container, now time.Time) []collect.VPN {
	var out []collect.VPN
	for _, ct := range containers {
		proto, ok := vpnProtocol(ct.Name)
		if !ok {
			continue
		}
		v := collect.VPN{Container: ct.Name, Protocol: proto, Running: ct.State == "running"}
		if v.Running && isWireGuard(proto) {
			c.fillWireGuard(&v, now)
		}
		out = append(out, v)
	}
	return out
}

func (c *Client) fillWireGuard(v *collect.VPN, now time.Time) {
	// The AmneziaWG image ships `awg`; older images and plain WireGuard ship `wg`.
	dump, err := c.Exec(v.Container, "sh", "-c", "awg show all dump 2>/dev/null || wg show all dump")
	if err != nil {
		v.Error = "wg show: " + err.Error()
		return
	}
	peers := parseWGDump(string(dump), now)

	// Client names live in the AmneziaVPN app's clientsTable; missing is fine.
	if table, err := c.Exec(v.Container, "sh", "-c", "cat /opt/amnezia/*/clientsTable 2>/dev/null || true"); err == nil {
		names := parseClientsTable(table)
		for i := range peers {
			peers[i].Name = names[peers[i].PublicKey]
		}
	}

	v.Peers = peers
	v.ClientsKnown = true
	v.Clients = len(peers)
	for _, p := range peers {
		if p.Active {
			v.ActiveClients++
		}
		v.RxBytes += p.RxBytes
		v.TxBytes += p.TxBytes
	}
}

// parseWGDump parses `wg show all dump`. Interface lines have 5 fields, peer
// lines 9: iface, public-key, preshared-key, endpoint, allowed-ips,
// latest-handshake, rx, tx, keepalive.
func parseWGDump(dump string, now time.Time) []collect.VPNPeer {
	var peers []collect.VPNPeer
	for _, line := range strings.Split(dump, "\n") {
		f := strings.Split(strings.TrimSpace(line), "\t")
		if len(f) != 9 {
			continue
		}
		hs, _ := strconv.ParseInt(f[5], 10, 64)
		rx, _ := strconv.ParseUint(f[6], 10, 64)
		tx, _ := strconv.ParseUint(f[7], 10, 64)
		p := collect.VPNPeer{PublicKey: f[1], RxBytes: rx, TxBytes: tx}
		if hs > 0 {
			t := time.Unix(hs, 0).UTC()
			p.LatestHandshake = &t
			p.Active = now.Sub(t) < activeWindow
		}
		peers = append(peers, p)
	}
	return peers
}

// parseClientsTable maps public keys to client names. Several tables may be
// concatenated (one per protocol), so it decodes a stream of JSON arrays.
func parseClientsTable(b []byte) map[string]string {
	names := map[string]string{}
	dec := json.NewDecoder(strings.NewReader(string(b)))
	for {
		var table []struct {
			ClientID string `json:"clientId"`
			UserData struct {
				ClientName string `json:"clientName"`
			} `json:"userData"`
		}
		if err := dec.Decode(&table); err != nil {
			return names
		}
		for _, e := range table {
			if e.ClientID != "" && e.UserData.ClientName != "" {
				names[e.ClientID] = e.UserData.ClientName
			}
		}
	}
}
