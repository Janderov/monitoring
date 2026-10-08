import CSQLite
import Foundation

/// SQLite history in the data folder:
///  - `samples`: one row per agent minute with the key metrics (30 days);
///  - `hourly`: hourly averages/maxima rolled up from samples (1 year);
///  - `polls`: whether each poll reached the agent, for availability (30 days);
///  - `latest`: the last full snapshot per server, for the UI after restart;
///  - `events`: the alert log (1 year).
public actor Store {
    public static let sampleRetention: TimeInterval = 30 * 86400
    public static let hourlyRetention: TimeInterval = 365 * 86400

    private let db: SQLiteDB

    public init(path: String) throws {
        db = try SQLiteDB(path: path)
        try db.exec("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;")
        try Store.migrate(db)
    }

    /// Schema changes, applied in order and recorded in `PRAGMA user_version`.
    /// Never edit a shipped entry: append a new one (users and roles, an audit
    /// log of VPN key changes and the like will arrive this way), so an
    /// existing monitor.sqlite upgrades in place.
    static let migrations: [String] = [
        """
        CREATE TABLE IF NOT EXISTS samples (
          server_id TEXT NOT NULL, ts INTEGER NOT NULL,
          cpu REAL, mem REAL, disk REAL, load1 REAL, rx REAL, tx REAL, vpn_clients INTEGER,
          PRIMARY KEY (server_id, ts)) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS hourly (
          server_id TEXT NOT NULL, hour INTEGER NOT NULL,
          cpu_avg REAL, cpu_max REAL, mem_avg REAL, mem_max REAL, disk_max REAL,
          rx_avg REAL, tx_avg REAL, vpn_max INTEGER, samples INTEGER,
          polls_ok INTEGER, polls_total INTEGER,
          PRIMARY KEY (server_id, hour)) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS polls (
          server_id TEXT NOT NULL, ts INTEGER NOT NULL, ok INTEGER NOT NULL, error TEXT,
          PRIMARY KEY (server_id, ts)) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS latest (
          server_id TEXT PRIMARY KEY, ts INTEGER NOT NULL, json TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS events (
          id INTEGER PRIMARY KEY AUTOINCREMENT, server_id TEXT NOT NULL, ts INTEGER NOT NULL,
          key TEXT NOT NULL, kind TEXT NOT NULL, severity INTEGER NOT NULL, message TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS events_ts ON events (ts);
        """,
        // Who caused an event: "system" for alerts; user ids once there are users.
        "ALTER TABLE events ADD COLUMN actor TEXT NOT NULL DEFAULT 'system';",
        // Site checks as each agent ran them, and domain expiry from the registry.
        """
        CREATE TABLE site_samples (
          site_id TEXT NOT NULL, server_id TEXT NOT NULL, ts INTEGER NOT NULL,
          ok INTEGER NOT NULL, status INTEGER, latency_ms REAL, error TEXT,
          PRIMARY KEY (site_id, server_id, ts)) WITHOUT ROWID;
        CREATE TABLE domains (
          domain TEXT PRIMARY KEY, expiry INTEGER, error TEXT, checked_at INTEGER NOT NULL);
        """,
        // Audit log: every change a person makes (add a server, create a VPN
        // key, ...), allowed or refused, with who did it.
        """
        CREATE TABLE actions (
          id TEXT PRIMARY KEY, ts INTEGER NOT NULL,
          actor_id TEXT NOT NULL, actor_name TEXT NOT NULL,
          kind TEXT NOT NULL, object_type TEXT NOT NULL, object_id TEXT NOT NULL, object_name TEXT NOT NULL,
          detail TEXT NOT NULL DEFAULT '', result TEXT NOT NULL, error TEXT);
        CREATE INDEX actions_ts ON actions (ts);
        CREATE INDEX actions_object ON actions (object_id, ts);
        """,
        // Before 401/403 counted as up, a site behind a password was logged
        // as down: fix its availability and drop those alerts from the log.
        """
        UPDATE site_samples SET ok = 1, error = NULL WHERE ok = 0 AND status IN (401, 403);
        DELETE FROM events WHERE message LIKE 'сайт % недоступен%'
          AND (message LIKE '%: 401 %' OR message LIKE '%: 403 %' OR message LIKE '%HTTP 401' OR message LIKE '%HTTP 403');
        """,
        // Traffic of each VPN client per local day (1 year), from the agents'
        // running counters; vpn_counters holds the last counter seen.
        """
        CREATE TABLE vpn_counters (
          server_id TEXT NOT NULL, public_key TEXT NOT NULL, rx INTEGER NOT NULL, tx INTEGER NOT NULL,
          PRIMARY KEY (server_id, public_key)) WITHOUT ROWID;
        CREATE TABLE vpn_traffic (
          server_id TEXT NOT NULL, public_key TEXT NOT NULL, day INTEGER NOT NULL,
          rx INTEGER NOT NULL, tx INTEGER NOT NULL,
          PRIMARY KEY (server_id, public_key, day)) WITHOUT ROWID;
        """,
        // Agent-to-agent checks (latency between servers), 30 days.
        """
        CREATE TABLE link_samples (
          server_id TEXT NOT NULL, peer_id TEXT NOT NULL, ts INTEGER NOT NULL,
          ok INTEGER NOT NULL, latency_ms REAL,
          PRIMARY KEY (server_id, peer_id, ts)) WITHOUT ROWID;
        """,
        // Small app state that must survive a restart: the alerts in progress
        // and when the Mac last polled.
        """
        CREATE TABLE kv (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
        """,
    ]

    public static var schemaVersion: Int { migrations.count }

    static func migrate(_ db: SQLiteDB) throws {
        let current = Int(try db.prepare("PRAGMA user_version").rows().first?.int(0) ?? 0)
        guard current <= migrations.count else {
            throw SQLiteError(description: "monitor.sqlite is from a newer app version (schema \(current))")
        }
        for (i, sql) in migrations.enumerated() where i >= current {
            try db.transaction {
                try db.exec(sql)
                try db.exec("PRAGMA user_version = \(i + 1)")
            }
        }
    }

    // MARK: writes

    public func addSamples(_ serverID: String, _ snaps: [Snapshot]) throws {
        guard !snaps.isEmpty else { return }
        try db.transaction {
            let st = try db.prepare("""
            INSERT OR REPLACE INTO samples (server_id, ts, cpu, mem, disk, load1, rx, tx, vpn_clients)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
            for s in snaps {
                try st.run(.text(serverID), .int(Int64(s.time.timeIntervalSince1970)),
                           .real(s.cpu.usagePercent), .real(s.memory.usedPercent), .real(s.maxDiskPercent),
                           .real(s.load.one), .real(s.network.rxBytesPerSec), .real(s.network.txBytesPerSec),
                           .int(Int64(s.vpnActiveClients)))
            }
        }
    }

    /// Stores the results of the app's site checks found in agent snapshots.
    public func addSiteSamples(serverID: String, _ snaps: [Snapshot]) throws {
        let rows = snaps.flatMap { snap in
            (snap.checks ?? []).filter { $0.id.hasPrefix(SiteConfig.checkPrefix) }.map { (snap.time, $0) }
        }
        guard !rows.isEmpty else { return }
        try db.transaction {
            let st = try db.prepare("""
            INSERT OR REPLACE INTO site_samples (site_id, server_id, ts, ok, status, latency_ms, error)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """)
            for (time, c) in rows {
                try st.run(.text(String(c.id.dropFirst(SiteConfig.checkPrefix.count))), .text(serverID),
                           .int(Int64(time.timeIntervalSince1970)), .int(c.ok ? 1 : 0),
                           c.statusCode.map { .int(Int64($0)) } ?? .null, .real(c.latencyMs),
                           c.error.map { .text($0) } ?? .null)
            }
        }
    }

    /// Adds what each VPN client transferred since the previous call to its
    /// day. Agents report counters that only grow until the VPN restarts; a
    /// smaller counter means a restart, and then the whole value is new.
    public func addVPNTraffic(_ serverID: String, _ snap: Snapshot, calendar: Calendar = .current) throws {
        let peers = (snap.vpn ?? []).flatMap { $0.peers ?? [] }
        guard !peers.isEmpty else { return }
        let day = Int64(calendar.startOfDay(for: snap.time).timeIntervalSince1970)
        try db.transaction {
            let read = try db.prepare("SELECT rx, tx FROM vpn_counters WHERE server_id = ? AND public_key = ?")
            let save = try db.prepare("INSERT OR REPLACE INTO vpn_counters (server_id, public_key, rx, tx) VALUES (?, ?, ?, ?)")
            let add = try db.prepare("""
            INSERT INTO vpn_traffic (server_id, public_key, day, rx, tx) VALUES (?1, ?2, ?3, ?4, ?5)
            ON CONFLICT (server_id, public_key, day) DO UPDATE SET rx = rx + ?4, tx = tx + ?5
            """)
            for p in peers {
                let rx = Int64(clamping: p.rxBytes), tx = Int64(clamping: p.txBytes)
                if let prev = try read.rows(.text(serverID), .text(p.publicKey)).first {
                    let prx = prev.int(0) ?? 0, ptx = prev.int(1) ?? 0
                    let drx = rx >= prx ? rx - prx : rx, dtx = tx >= ptx ? tx - ptx : tx
                    if drx > 0 || dtx > 0 {
                        try add.run(.text(serverID), .text(p.publicKey), .int(day), .int(drx), .int(dtx))
                    }
                }
                // A client seen for the first time only sets the starting point:
                // its counter holds traffic from before the app watched it.
                try save.run(.text(serverID), .text(p.publicKey), .int(rx), .int(tx))
            }
        }
    }

    /// Stores the agent-to-agent checks (`peer-<id>`) found in snapshots.
    public func addLinkSamples(serverID: String, _ snaps: [Snapshot]) throws {
        let rows = snaps.flatMap { snap in
            (snap.checks ?? []).filter { $0.id.hasPrefix(ServerConfig.peerCheckPrefix) }.map { (snap.time, $0) }
        }
        guard !rows.isEmpty else { return }
        try db.transaction {
            let st = try db.prepare("""
            INSERT OR REPLACE INTO link_samples (server_id, peer_id, ts, ok, latency_ms) VALUES (?, ?, ?, ?, ?)
            """)
            for (time, c) in rows {
                try st.run(.text(serverID), .text(String(c.id.dropFirst(ServerConfig.peerCheckPrefix.count))),
                           .int(Int64(time.timeIntervalSince1970)), .int(c.ok ? 1 : 0),
                           c.ok ? .real(c.latencyMs) : .null)
            }
        }
    }

    public func setDomain(_ domain: String, _ e: DomainExpiry.Entry) throws {
        try db.prepare("INSERT OR REPLACE INTO domains (domain, expiry, error, checked_at) VALUES (?, ?, ?, ?)")
            .run(.text(domain), e.expiry.map { .int(Int64($0.timeIntervalSince1970)) } ?? .null,
                 e.error.map { .text($0) } ?? .null, .int(Int64(e.checkedAt.timeIntervalSince1970)))
    }

    /// A consistent copy of the whole database in one file, made while the
    /// app keeps running (before an update, for "Вернуть предыдущую").
    public func copy(to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try db.prepare("VACUUM INTO ?").run(.text(url.path))
    }

    public func setValue(_ value: String?, for key: String) throws {
        if let value {
            try db.prepare("INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)").run(.text(key), .text(value))
        } else {
            try db.prepare("DELETE FROM kv WHERE key = ?").run(.text(key))
        }
    }

    public func value(_ key: String) throws -> String? {
        try db.prepare("SELECT value FROM kv WHERE key = ?").rows(.text(key)).first?.text(0)
    }

    public func domains() throws -> [String: DomainExpiry.Entry] {
        var out: [String: DomainExpiry.Entry] = [:]
        for r in try db.prepare("SELECT domain, expiry, error, checked_at FROM domains").rows() {
            out[r.text(0) ?? ""] = DomainExpiry.Entry(
                expiry: r.int(1).map { Date(timeIntervalSince1970: TimeInterval($0)) }, error: r.text(2),
                checkedAt: Date(timeIntervalSince1970: TimeInterval(r.int(3) ?? 0)))
        }
        return out
    }

    public func setLatest(_ serverID: String, _ snap: Snapshot) throws {
        let json = String(decoding: try AgentJSON.encoder.encode(snap), as: UTF8.self)
        try db.prepare("INSERT OR REPLACE INTO latest (server_id, ts, json) VALUES (?, ?, ?)")
            .run(.text(serverID), .int(Int64(snap.time.timeIntervalSince1970)), .text(json))
    }

    public func addPoll(_ serverID: String, at time: Date, ok: Bool, error: String?) throws {
        try db.prepare("INSERT OR REPLACE INTO polls (server_id, ts, ok, error) VALUES (?, ?, ?, ?)")
            .run(.text(serverID), .int(Int64(time.timeIntervalSince1970)), .int(ok ? 1 : 0),
                 error.map { .text($0) } ?? .null)
    }

    public func addEvent(_ e: AlertEvent, actor: String = "system") throws {
        try db.prepare("""
        INSERT INTO events (server_id, ts, key, kind, severity, message, actor) VALUES (?, ?, ?, ?, ?, ?, ?)
        """).run(.text(e.serverID), .int(Int64(e.time.timeIntervalSince1970)), .text(e.key),
                 .text(e.kind.rawValue), .int(Int64(e.severity.rawValue)), .text(e.message), .text(actor))
    }

    /// How many events with this key the server logged since `since`.
    public func eventCount(_ serverID: String, key: String, since: Date) throws -> Int {
        Int(try db.prepare("SELECT COUNT(*) FROM events WHERE server_id = ? AND key = ? AND ts >= ?")
            .rows(.text(serverID), .text(key), .int(Int64(since.timeIntervalSince1970))).first?.int(0) ?? 0)
    }

    /// Recomputes the hourly rows for every hour touched since `since`
    /// (re-running is harmless), then drops data past retention.
    public func rollup(since: Date, now: Date) throws {
        let from = Int64(since.timeIntervalSince1970) / 3600 * 3600
        try db.transaction {
            try db.prepare("""
            INSERT OR REPLACE INTO hourly
              (server_id, hour, cpu_avg, cpu_max, mem_avg, mem_max, disk_max, rx_avg, tx_avg, vpn_max,
               samples, polls_ok, polls_total)
            SELECT h.server_id, h.hour, s.cpu_avg, s.cpu_max, s.mem_avg, s.mem_max, s.disk_max,
                   s.rx_avg, s.tx_avg, s.vpn_max, COALESCE(s.n, 0), COALESCE(p.ok, 0), COALESCE(p.total, 0)
            FROM (SELECT server_id, ts / 3600 * 3600 AS hour FROM samples WHERE ts >= ?1
                  UNION SELECT server_id, ts / 3600 * 3600 FROM polls WHERE ts >= ?1) h
            LEFT JOIN (SELECT server_id, ts / 3600 * 3600 AS hour, AVG(cpu) cpu_avg, MAX(cpu) cpu_max,
                              AVG(mem) mem_avg, MAX(mem) mem_max, MAX(disk) disk_max,
                              AVG(rx) rx_avg, AVG(tx) tx_avg, MAX(vpn_clients) vpn_max, COUNT(*) n
                       FROM samples WHERE ts >= ?1 GROUP BY 1, 2) s
              ON s.server_id = h.server_id AND s.hour = h.hour
            LEFT JOIN (SELECT server_id, ts / 3600 * 3600 AS hour, SUM(ok) ok, COUNT(*) total
                       FROM polls WHERE ts >= ?1 GROUP BY 1, 2) p
              ON p.server_id = h.server_id AND p.hour = h.hour
            """).run(.int(from))

            let sampleCut = Int64(now.timeIntervalSince1970 - Store.sampleRetention)
            let hourlyCut = Int64(now.timeIntervalSince1970 - Store.hourlyRetention)
            try db.prepare("DELETE FROM samples WHERE ts < ?").run(.int(sampleCut))
            try db.prepare("DELETE FROM polls WHERE ts < ?").run(.int(sampleCut))
            try db.prepare("DELETE FROM site_samples WHERE ts < ?").run(.int(sampleCut))
            try db.prepare("DELETE FROM link_samples WHERE ts < ?").run(.int(sampleCut))
            try db.prepare("DELETE FROM hourly WHERE hour < ?").run(.int(hourlyCut))
            try db.prepare("DELETE FROM events WHERE ts < ?").run(.int(hourlyCut))
            try db.prepare("DELETE FROM vpn_traffic WHERE day < ?").run(.int(hourlyCut))
        }
    }

    /// Drops everything about servers no longer in the config except the
    /// event log, which stays readable.
    public func forget(serverID: String) throws {
        for table in ["samples", "hourly", "polls", "latest", "vpn_counters", "vpn_traffic", "link_samples"] {
            try db.prepare("DELETE FROM \(table) WHERE server_id = ?").run(.text(serverID))
        }
        try db.prepare("DELETE FROM link_samples WHERE peer_id = ?").run(.text(serverID))
    }

    // MARK: reads

    public func lastSampleTime(_ serverID: String) throws -> Date? {
        try db.prepare("SELECT MAX(ts) FROM samples WHERE server_id = ?")
            .rows(.text(serverID)).first?.int(0).map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    public func latest(_ serverID: String) throws -> Snapshot? {
        guard let json = try db.prepare("SELECT json FROM latest WHERE server_id = ?")
            .rows(.text(serverID)).first?.text(0) else { return nil }
        return try? AgentJSON.decoder.decode(Snapshot.self, from: Data(json.utf8))
    }

    public struct Sample: Equatable, Sendable {
        public var time: Date
        public var cpu, mem, disk, load1, rx, tx: Double
        public var vpnClients: Int
    }

    public func samples(_ serverID: String, from: Date, to: Date) throws -> [Sample] {
        try db.prepare("""
        SELECT ts, cpu, mem, disk, load1, rx, tx, vpn_clients FROM samples
        WHERE server_id = ? AND ts >= ? AND ts <= ? ORDER BY ts
        """).rows(.text(serverID), .int(Int64(from.timeIntervalSince1970)), .int(Int64(to.timeIntervalSince1970)))
            .map { r in
                Sample(time: Date(timeIntervalSince1970: TimeInterval(r.int(0) ?? 0)),
                       cpu: r.real(1) ?? 0, mem: r.real(2) ?? 0, disk: r.real(3) ?? 0, load1: r.real(4) ?? 0,
                       rx: r.real(5) ?? 0, tx: r.real(6) ?? 0, vpnClients: Int(r.int(7) ?? 0))
            }
    }

    /// One check from a server to another server's agent port; the latency
    /// is the TCP connect time, close to the round trip between them.
    public struct LinkSample: Equatable, Sendable {
        public var peerID: String
        public var time: Date
        public var ok: Bool
        public var latencyMs: Double?
    }

    /// Checks made by `serverID` to the other servers, oldest first.
    public func linkSamples(_ serverID: String, from: Date, to: Date) throws -> [LinkSample] {
        try db.prepare("""
        SELECT peer_id, ts, ok, latency_ms FROM link_samples
        WHERE server_id = ? AND ts >= ? AND ts <= ? ORDER BY ts, peer_id
        """).rows(.text(serverID), .int(Int64(from.timeIntervalSince1970)), .int(Int64(to.timeIntervalSince1970)))
            .map { r in
                LinkSample(peerID: r.text(0) ?? "", time: Date(timeIntervalSince1970: TimeInterval(r.int(1) ?? 0)),
                           ok: r.int(2) == 1, latencyMs: r.real(3))
            }
    }

    public struct SiteSample: Equatable, Sendable {
        public var serverID: String
        public var time: Date
        public var ok: Bool
        public var statusCode: Int?
        public var latencyMs: Double
        public var error: String?
    }

    /// One site's check results from every server, oldest first.
    public func siteSamples(_ siteID: String, from: Date, to: Date) throws -> [SiteSample] {
        try db.prepare("""
        SELECT server_id, ts, ok, status, latency_ms, error FROM site_samples
        WHERE site_id = ? AND ts >= ? AND ts <= ? ORDER BY ts, server_id
        """).rows(.text(siteID), .int(Int64(from.timeIntervalSince1970)), .int(Int64(to.timeIntervalSince1970)))
            .map { r in
                SiteSample(serverID: r.text(0) ?? "", time: Date(timeIntervalSince1970: TimeInterval(r.int(1) ?? 0)),
                           ok: r.int(2) == 1, statusCode: r.int(3).map { Int($0) }, latencyMs: r.real(4) ?? 0,
                           error: r.text(5))
            }
    }

    /// Bytes one VPN client transferred; rx is what the server received from
    /// the client (its uploads), tx what it sent (its downloads).
    public struct VPNUsage: Equatable, Sendable {
        public var rx: UInt64
        public var tx: UInt64
        public var total: UInt64 { rx + tx }
    }

    /// Traffic per client public key over the local days touching [from, to].
    public func vpnTraffic(_ serverID: String, from: Date, to: Date,
                           calendar: Calendar = .current) throws -> [String: VPNUsage] {
        let first = Int64(calendar.startOfDay(for: from).timeIntervalSince1970)
        var out: [String: VPNUsage] = [:]
        for r in try db.prepare("""
        SELECT public_key, SUM(rx), SUM(tx) FROM vpn_traffic
        WHERE server_id = ? AND day >= ? AND day <= ? GROUP BY public_key
        """).rows(.text(serverID), .int(first), .int(Int64(to.timeIntervalSince1970))) {
            out[r.text(0) ?? ""] = VPNUsage(rx: UInt64(max(0, r.int(1) ?? 0)), tx: UInt64(max(0, r.int(2) ?? 0)))
        }
        return out
    }

    /// Daily traffic of one client, oldest first, for a chart.
    public func vpnDaily(_ serverID: String, publicKey: String, from: Date, to: Date,
                         calendar: Calendar = .current) throws -> [(day: Date, usage: VPNUsage)] {
        let first = Int64(calendar.startOfDay(for: from).timeIntervalSince1970)
        return try db.prepare("""
        SELECT day, rx, tx FROM vpn_traffic WHERE server_id = ? AND public_key = ? AND day >= ? AND day <= ?
        ORDER BY day
        """).rows(.text(serverID), .text(publicKey), .int(first), .int(Int64(to.timeIntervalSince1970))).map { r in
            (Date(timeIntervalSince1970: TimeInterval(r.int(0) ?? 0)),
             VPNUsage(rx: UInt64(max(0, r.int(1) ?? 0)), tx: UInt64(max(0, r.int(2) ?? 0))))
        }
    }

    public struct Hourly: Equatable, Sendable {
        public var hour: Date
        public var cpuAvg, cpuMax, memAvg, memMax, diskMax, rxAvg, txAvg: Double
        public var vpnMax, samples, pollsOK, pollsTotal: Int
    }

    public func hourly(_ serverID: String, from: Date, to: Date) throws -> [Hourly] {
        try db.prepare("""
        SELECT hour, cpu_avg, cpu_max, mem_avg, mem_max, disk_max, rx_avg, tx_avg, vpn_max,
               samples, polls_ok, polls_total
        FROM hourly WHERE server_id = ? AND hour >= ? AND hour <= ? ORDER BY hour
        """).rows(.text(serverID), .int(Int64(from.timeIntervalSince1970)), .int(Int64(to.timeIntervalSince1970)))
            .map { r in
                Hourly(hour: Date(timeIntervalSince1970: TimeInterval(r.int(0) ?? 0)),
                       cpuAvg: r.real(1) ?? 0, cpuMax: r.real(2) ?? 0, memAvg: r.real(3) ?? 0,
                       memMax: r.real(4) ?? 0, diskMax: r.real(5) ?? 0, rxAvg: r.real(6) ?? 0,
                       txAvg: r.real(7) ?? 0, vpnMax: Int(r.int(8) ?? 0), samples: Int(r.int(9) ?? 0),
                       pollsOK: Int(r.int(10) ?? 0), pollsTotal: Int(r.int(11) ?? 0))
            }
    }

    public struct LoggedEvent: Equatable, Sendable {
        public var serverID: String
        public var time: Date
        public var key: String
        public var kind: AlertEvent.Kind
        public var severity: Severity
        public var message: String
        public var actor: String
    }

    public func addAction(_ a: AuditRecord) throws {
        try db.prepare("""
        INSERT OR REPLACE INTO actions
          (id, ts, actor_id, actor_name, kind, object_type, object_id, object_name, detail, result, error)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """).run(.text(a.id), .int(Int64(a.time.timeIntervalSince1970)), .text(a.actor.id), .text(a.actor.name),
                 .text(a.action.rawValue), .text(a.object.type.rawValue), .text(a.object.id), .text(a.object.name),
                 .text(a.detail), .text(a.result.rawValue), a.error.map { .text($0) } ?? .null)
    }

    /// Newest first; `objectID` narrows to one server, site or VPN key. Kept
    /// forever: it is small and is the answer to "who deleted this key".
    public func actions(limit: Int = 200, objectID: String? = nil) throws -> [AuditRecord] {
        let st = try db.prepare("""
        SELECT id, ts, actor_id, actor_name, kind, object_type, object_id, object_name, detail, result, error
        FROM actions WHERE ?1 IS NULL OR object_id = ?1 ORDER BY ts DESC, rowid DESC LIMIT ?2
        """)
        return try st.rows(objectID.map { .text($0) } ?? .null, .int(Int64(limit))).map { r in
            AuditRecord(id: r.text(0) ?? "", time: Date(timeIntervalSince1970: TimeInterval(r.int(1) ?? 0)),
                        actor: AppUser(id: r.text(2) ?? "", name: r.text(3) ?? ""),
                        action: UserAction(rawValue: r.text(4) ?? "") ?? .view,
                        object: ObjectRef(type: ObjectRef.Kind(rawValue: r.text(5) ?? "") ?? .server,
                                          id: r.text(6) ?? "", name: r.text(7) ?? ""),
                        detail: r.text(8) ?? "", result: AuditRecord.Result(rawValue: r.text(9) ?? "") ?? .failed,
                        error: r.text(10))
        }
    }

    public func events(limit: Int = 200, serverID: String? = nil) throws -> [LoggedEvent] {
        let st = try db.prepare("""
        SELECT server_id, ts, key, kind, severity, message, actor FROM events
        WHERE ?1 IS NULL OR server_id = ?1 ORDER BY ts DESC, id DESC LIMIT ?2
        """)
        return try st.rows(serverID.map { .text($0) } ?? .null, .int(Int64(limit))).map { r in
            LoggedEvent(serverID: r.text(0) ?? "", time: Date(timeIntervalSince1970: TimeInterval(r.int(1) ?? 0)),
                        key: r.text(2) ?? "", kind: AlertEvent.Kind(rawValue: r.text(3) ?? "") ?? .fired,
                        severity: Severity(rawValue: Int(r.int(4) ?? 1)) ?? .warning, message: r.text(5) ?? "",
                        actor: r.text(6) ?? "system")
        }
    }
}

// MARK: - minimal SQLite wrapper

public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public var description: String
}

final class SQLiteDB {
    private var handle: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw SQLiteError(description: "\(path): \(msg)")
        }
        sqlite3_busy_timeout(handle, 5000)
    }

    deinit { sqlite3_close(handle) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError(description: msg)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &st, nil) == SQLITE_OK, let st else {
            throw SQLiteError(description: "\(lastError): \(sql.prefix(80))")
        }
        return Statement(db: self, handle: st)
    }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    var lastError: String { String(cString: sqlite3_errmsg(handle)) }

    enum Value {
        case int(Int64), real(Double), text(String), null
    }

    struct Row {
        var values: [Value]
        func int(_ i: Int) -> Int64? { if case .int(let v) = values[i] { return v }; return nil }
        func real(_ i: Int) -> Double? {
            switch values[i] {
            case .real(let v): return v
            case .int(let v): return Double(v)
            default: return nil
            }
        }
        func text(_ i: Int) -> String? { if case .text(let v) = values[i] { return v }; return nil }
    }

    final class Statement {
        let db: SQLiteDB
        let handle: OpaquePointer

        init(db: SQLiteDB, handle: OpaquePointer) { self.db = db; self.handle = handle }
        deinit { sqlite3_finalize(handle) }

        private func bind(_ values: [Value]) throws {
            sqlite3_reset(handle)
            sqlite3_clear_bindings(handle)
            // SQLITE_TRANSIENT: sqlite copies the string before we return.
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (i, v) in values.enumerated() {
                let idx = Int32(i + 1)
                let rc: Int32
                switch v {
                case .int(let x): rc = sqlite3_bind_int64(handle, idx, x)
                case .real(let x): rc = sqlite3_bind_double(handle, idx, x)
                case .text(let x): rc = sqlite3_bind_text(handle, idx, x, -1, transient)
                case .null: rc = sqlite3_bind_null(handle, idx)
                }
                guard rc == SQLITE_OK else { throw SQLiteError(description: db.lastError) }
            }
        }

        func run(_ values: Value...) throws {
            try bind(values)
            let rc = sqlite3_step(handle)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw SQLiteError(description: db.lastError) }
        }

        func rows(_ values: Value...) throws -> [Row] {
            try bind(values)
            var out: [Row] = []
            while true {
                let rc = sqlite3_step(handle)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw SQLiteError(description: db.lastError) }
                let n = sqlite3_column_count(handle)
                out.append(Row(values: (0..<n).map { i in
                    switch sqlite3_column_type(handle, i) {
                    case SQLITE_INTEGER: return .int(sqlite3_column_int64(handle, i))
                    case SQLITE_FLOAT: return .real(sqlite3_column_double(handle, i))
                    case SQLITE_TEXT: return .text(String(cString: sqlite3_column_text(handle, i)))
                    default: return .null
                    }
                }))
            }
            return out
        }
    }
}
