import Foundation

// Mirrors of the agent's JSON (agent/internal/collect). Decode with
// `AgentJSON.decoder`, which maps snake_case keys and the agent's
// nanosecond RFC 3339 timestamps.

public struct Snapshot: Codable, Equatable, Sendable {
    public var time: Date
    public var hostname: String
    public var uptimeSeconds: Double
    public var bootTime: Date
    public var cpu: CPU
    public var memory: Memory
    public var load: Load
    public var disks: [Disk]?
    public var network: Network
    public var containers: [Container]?
    public var processes: [Process]?
    public var vpn: [VPN]?
    public var services: [Service]?
    /// PostgreSQL and MySQL containers: connections and database sizes.
    public var databases: [Database]?
    public var checks: [Check]?
    /// Outgoing connections to public addresses (agent 0.4+), for VPN cascades.
    public var links: [Link]?
    /// Client traffic the server passes on through NAT, by real destination.
    public var forwards: [Link]?
    /// Connections coming in from public addresses, by source; `ports` are local.
    public var inbound: [Link]?
    public var errors: [String]?
    /// How often the agent samples right now; nil from older agents.
    public var intervalS: Int?
    /// Host care (agent 0.6+), refreshed every 5 minutes.
    public var system: System?
    public var ssh: SSHLog?
    public var backups: [Backup]?

    /// The OS and pending Ubuntu updates, as update-notifier last counted them.
    public struct System: Codable, Equatable, Sendable {
        public var os: String?
        public var updatesPending: Int
        public var securityUpdates: Int
        public var rebootRequired: Bool
        public var rebootPackages: [String]?
        /// Nil when update-notifier never counted: the numbers are then unknown.
        public var updatesCheckedAt: Date?
    }

    /// What sshd logged over the last day.
    public struct SSHLog: Codable, Equatable, Sendable {
        /// Unknown users and wrong passwords; keys a client merely offers do not count.
        public var failedDay: Int
        public var sources: [Source]?
        /// Latest successful logins, newest first.
        public var logins: [Login]?
        public var source: String?

        public struct Source: Codable, Equatable, Sendable {
            public var ip: String
            public var count: Int
        }

        public struct Login: Codable, Equatable, Sendable {
            public var time: Date
            public var user: String
            public var ip: String
            public var method: String
        }
    }

    /// Dumps of one database container made by the app, and its nightly job.
    public struct Backup: Codable, Equatable, Sendable {
        public var container: String
        /// Nil while there is a nightly job but no dump yet.
        public var newest: Date?
        public var newestBytes: Int64
        public var count: Int
        public var totalBytes: Int64
        public var nightly: Bool?
    }

    public struct CPU: Codable, Equatable, Sendable {
        public var cores: Int
        public var usagePercent: Double
        public var iowaitPercent: Double
        public var stealPercent: Double
    }

    public struct Memory: Codable, Equatable, Sendable {
        public var totalBytes: UInt64
        public var availableBytes: UInt64
        public var usedPercent: Double
        public var swapTotalBytes: UInt64
        public var swapFreeBytes: UInt64
    }

    public struct Load: Codable, Equatable, Sendable {
        public var one: Double
        public var five: Double
        public var fifteen: Double
    }

    public struct Disk: Codable, Equatable, Sendable {
        public var mount: String
        public var device: String
        public var fstype: String
        public var totalBytes: UInt64
        public var freeBytes: UInt64
        public var usedPercent: Double
    }

    public struct Network: Codable, Equatable, Sendable {
        public var rxBytes: UInt64
        public var txBytes: UInt64
        public var rxBytesPerSec: Double
        public var txBytesPerSec: Double
    }

    public struct Container: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var image: String
        public var state: String
        public var status: String
        public var health: String?
        /// Usage of a running container (agents since container usage):
        /// CPU in percent of one core, memory without page cache.
        public var cpuPercent: Double?
        public var memBytes: UInt64?
        public var memLimitBytes: UInt64?
    }

    public struct Process: Codable, Equatable, Sendable {
        public var pid: Int
        public var name: String
        public var cpuPercent: Double
        public var rssBytes: UInt64
    }

    public struct VPN: Codable, Equatable, Sendable {
        public var container: String
        public var `protocol`: String
        public var running: Bool
        public var clientsKnown: Bool?
        public var clients: Int
        public var activeClients: Int
        public var rxBytes: UInt64
        public var txBytes: UInt64
        public var peers: [Peer]?
        public var error: String?

        public struct Peer: Codable, Equatable, Sendable {
            public var name: String?
            public var publicKey: String
            public var latestHandshake: Date?
            public var active: Bool
            public var rxBytes: UInt64
            public var txBytes: UInt64
            /// Where the peer was last seen, "ip:port".
            public var endpoint: String?
            /// "0.0.0.0/0" here means traffic leaves through this peer.
            public var allowedIps: String?
        }
    }

    public struct Database: Codable, Equatable, Sendable {
        public var container: String
        /// "postgresql" or "mysql".
        public var engine: String
        public var connections: Int
        public var maxConnections: Int?
        public var databases: [Size]?
        public var error: String?

        public struct Size: Codable, Equatable, Sendable {
            public var name: String
            public var sizeBytes: Int64
        }

        public var totalBytes: Int64 { (databases ?? []).reduce(0) { $0 + $1.sizeBytes } }
    }

    public struct Link: Codable, Equatable, Sendable {
        public var remoteIp: String
        public var ports: [Int]
        public var protos: [String]
        public var connections: Int
        /// "host" or the names of the containers making the connections.
        public var via: [String]
    }

    public struct Service: Codable, Equatable, Sendable {
        public var name: String
        public var kind: String
        public var processRunning: Bool
        public var port: Int?
        public var portOpen: Bool
        public var latencyMs: Double?
        public var error: String?
    }

    public struct Check: Codable, Equatable, Sendable {
        public var id: String
        public var kind: String
        public var target: String
        public var ok: Bool
        public var statusCode: Int?
        public var latencyMs: Double
        public var tlsExpiry: Date?
        public var error: String?
        /// The agent logged in with the site's credentials: a 401/403 is then a real failure.
        public var auth: Bool? = nil

        /// HTTP answers that mean the site is up but asks for a login.
        public static let authStatuses: Set<Int> = [401, 403]
    }

    /// Highest used percentage over all disks, 0 when none are reported.
    public var maxDiskPercent: Double { disks?.map(\.usedPercent).max() ?? 0 }

    /// Connected clients over all VPN containers whose clients are known.
    public var vpnActiveClients: Int { vpn?.reduce(0) { $0 + $1.activeClients } ?? 0 }
}

/// One page of `/v1/history`.
public struct HistoryPage: Codable, Sendable {
    public var snapshots: [Snapshot]?
    public var more: Bool
}

public enum AgentJSON {
    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = parseRFC3339(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad date \(s)")
            }
            return date
        }
        return d
    }

    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(formatRFC3339(date))
        }
        return e
    }

    /// Parses RFC 3339 with any number of fractional digits (Go emits up to 9,
    /// which ISO8601DateFormatter rejects).
    public static func parseRFC3339(_ s: String) -> Date? {
        var base = s
        var fraction = 0.0
        if let dot = s.firstIndex(of: ".") {
            var end = s.index(after: dot)
            while end < s.endIndex, s[end].isNumber { end = s.index(after: end) }
            fraction = Double("0" + s[dot..<end]) ?? 0
            base = String(s[..<dot]) + String(s[end...])
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard let d = f.date(from: base) else { return nil }
        return d.addingTimeInterval(fraction)
    }

    public static func formatRFC3339(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}

extension Snapshot.Check {
    /// Older agents count 401/403 as a failure; a site behind a password is up,
    /// unless the agent logged in with the site's credentials and was refused.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(String.self, forKey: .kind)
        target = try c.decode(String.self, forKey: .target)
        ok = try c.decode(Bool.self, forKey: .ok)
        statusCode = try c.decodeIfPresent(Int.self, forKey: .statusCode)
        latencyMs = try c.decode(Double.self, forKey: .latencyMs)
        tlsExpiry = try c.decodeIfPresent(Date.self, forKey: .tlsExpiry)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        auth = try c.decodeIfPresent(Bool.self, forKey: .auth)
        if !ok, auth != true, let code = statusCode, Self.authStatuses.contains(code) {
            ok = true
            error = nil
        }
    }
}
