import Foundation
@testable import MonitorCore

enum Fixtures {
    /// Shaped like a real agent snapshot (nanosecond timestamps, snake_case,
    /// extra fields the app ignores such as network.interfaces).
    static func snapshotJSON(time: String = "2026-10-05T07:58:28.414284339Z", cpu: Double = 12.5,
                             disk: Double = 41.2, mem: Double = 30, vpnRunning: Bool = true) -> String {
        """
        {
          "time": "\(time)",
          "hostname": "wise",
          "uptime_seconds": 86400.5,
          "boot_time": "2026-10-04T07:58:28Z",
          "cpu": {"cores": 2, "usage_percent": \(cpu), "iowait_percent": 0.1, "steal_percent": 0},
          "memory": {"total_bytes": 2048000000, "available_bytes": 1024000000, "used_percent": \(mem),
                     "swap_total_bytes": 0, "swap_free_bytes": 0},
          "load": {"one": 0.1, "five": 0.2, "fifteen": 0.3},
          "disks": [{"mount": "/", "device": "/dev/vda1", "fstype": "ext4",
                     "total_bytes": 20000000000, "free_bytes": 10000000000, "used_percent": \(disk)}],
          "network": {"rx_bytes": 1000, "tx_bytes": 2000, "rx_bytes_per_sec": 10.5, "tx_bytes_per_sec": 20.5,
                      "interfaces": [{"name": "eth0", "rx_bytes": 1000, "tx_bytes": 2000}]},
          "containers": [{"id": "abc", "name": "amnezia-awg2", "image": "amnezia-awg2", "state": "running",
                          "status": "Up 2 days (healthy)", "health": "healthy"}],
          "vpn": [{"container": "amnezia-awg2", "protocol": "awg", "running": \(vpnRunning), "clients_known": true,
                   "clients": 24, "active_clients": 3, "rx_bytes": 5, "tx_bytes": 6,
                   "peers": [{"name": "phone", "public_key": "k=", "latest_handshake": "2026-10-05T07:57:00Z",
                              "active": true, "rx_bytes": 1, "tx_bytes": 2}]}],
          "services": [{"name": "nginx", "kind": "web", "process_running": true, "port": 443,
                        "port_open": true, "latency_ms": 0.4}],
          "checks": [{"id": "site", "kind": "http", "target": "https://example.org", "ok": true,
                      "status_code": 200, "latency_ms": 120, "tls_expiry": "2027-01-01T00:00:00Z"}]
        }
        """
    }

    static func snapshot(time: Date = Date(timeIntervalSince1970: 1_790_000_000), cpu: Double = 12.5,
                         disk: Double = 41.2, mem: Double = 30, vpnRunning: Bool = true) -> Snapshot {
        let json = snapshotJSON(time: AgentJSON.formatRFC3339(time), cpu: cpu, disk: disk, mem: mem,
                                vpnRunning: vpnRunning)
        return try! AgentJSON.decoder.decode(Snapshot.self, from: Data(json.utf8))
    }

    static let server = ServerConfig(id: "nl", name: "Нидерланды", host: "203.0.113.10",
                                     token: String(repeating: "a", count: 43),
                                     fingerprint: String(repeating: "AB:", count: 31) + "AB")
}
