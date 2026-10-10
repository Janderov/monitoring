import Foundation
import Logging
import MonitorCore
import PostgresNIO

/// The poller's storage on PostgreSQL: the same calls the Mac's SQLite
/// `Store` answers, written into the tables of db/migrations. Ids are the
/// uuids of inv.server and inv.site as text, the way the poller passes them.
public actor PostgresPollStore: PollStore {
    let db: Database
    var logger: Logger { db.logger }
    /// The hub's own check point (who made a poll) and each agent's.
    var hubProbe: UUID?
    var agentProbes: [UUID: UUID] = [:]
    /// Poll id (the Mac's old id, or the uuid as text) → uuid; see Inventory.
    var serverIDs: [String: UUID] = [:]
    var siteIDs: [String: UUID] = [:]
    private var prunedAt: Date?

    public static let pruneEvery: TimeInterval = 3600

    public init(db: Database) { self.db = db }

    public func setProbes(hub: UUID, agents: [UUID: UUID]) {
        hubProbe = hub
        agentProbes = agents
    }

    public func setIDs(servers: [String: UUID], sites: [String: UUID]) {
        serverIDs = servers
        siteIDs = sites
    }

    struct BadID: Error, CustomStringConvertible {
        var id: String
        var description: String { "не uuid: \(id)" }
    }

    func uuid(_ s: String) throws -> UUID {
        guard let u = serverIDs[s] ?? UUID(uuidString: s) else { throw BadID(id: s) }
        return u
    }
    func siteUUID(_ s: String) -> UUID? { siteIDs[s] ?? UUID(uuidString: s) }
    func serverUUID(_ s: String) -> UUID? { serverIDs[s] ?? UUID(uuidString: s) }

    // MARK: samples

    public func addSamples(_ serverID: String, _ snaps: [Snapshot]) async throws {
        guard !snaps.isEmpty else { return }
        let id = try uuid(serverID)
        let ts = snaps.map(\.time)
        let cpu = snaps.map(\.cpu.usagePercent), iowait = snaps.map(\.cpu.iowaitPercent)
        let steal = snaps.map(\.cpu.stealPercent), mem = snaps.map(\.memory.usedPercent)
        let swap = snaps.map { s -> Double in
            s.memory.swapTotalBytes == 0 ? 0
                : 100 * Double(s.memory.swapTotalBytes - min(s.memory.swapFreeBytes, s.memory.swapTotalBytes))
                    / Double(s.memory.swapTotalBytes)
        }
        let disk = snaps.map(\.maxDiskPercent), load = snaps.map(\.load.one)
        let rx = snaps.map(\.network.rxBytesPerSec), tx = snaps.map(\.network.txBytesPerSec)
        let vpn = snaps.map { Int64($0.vpnActiveClients) }
        try await db.transaction { conn in
            try await conn.query("""
                INSERT INTO mon.server_sample
                  (server_id, ts, cpu, iowait, steal, mem, swap, disk_max, load1, rx_bps, tx_bps, vpn_clients)
                SELECT \(id), * FROM unnest(\(ts)::timestamptz[], \(cpu)::float8[], \(iowait)::float8[],
                  \(steal)::float8[], \(mem)::float8[], \(swap)::float8[], \(disk)::float8[], \(load)::float8[],
                  \(rx)::float8[], \(tx)::float8[], \(vpn)::int8[])
                ON CONFLICT (server_id, ts) DO UPDATE SET cpu = EXCLUDED.cpu, iowait = EXCLUDED.iowait,
                  steal = EXCLUDED.steal, mem = EXCLUDED.mem, swap = EXCLUDED.swap, disk_max = EXCLUDED.disk_max,
                  load1 = EXCLUDED.load1, rx_bps = EXCLUDED.rx_bps, tx_bps = EXCLUDED.tx_bps,
                  vpn_clients = EXCLUDED.vpn_clients
                """, logger: logger)
            try await addDetails(id, snaps, conn: conn)
        }
    }

    /// Per-disk (every 5 minutes, for the "disk fills up in N days"
    /// forecast) and per-container rows (every sample) from the same snapshots.
    func addDetails(_ id: UUID, _ snaps: [Snapshot], conn: PostgresConnection) async throws {
        var dTs: [Date] = [], dMount: [String] = [], dUsed: [Int64] = [], dTotal: [Int64] = []
        var cTs: [Date] = [], cName: [String] = [], cCPU: [Double] = [], cMem: [Int64] = [], cRun: [Bool] = []
        var cHasCPU: [Bool] = [], cHasMem: [Bool] = []
        for s in snaps {
            if Int(s.time.timeIntervalSince1970) / 60 % 5 == 0 {
                for d in s.disks ?? [] {
                    dTs.append(s.time); dMount.append(d.mount)
                    dUsed.append(Int64(clamping: d.totalBytes - min(d.freeBytes, d.totalBytes)))
                    dTotal.append(Int64(clamping: d.totalBytes))
                }
            }
            for c in s.containers ?? [] {
                cTs.append(s.time); cName.append(c.name)
                cCPU.append(c.cpuPercent ?? 0); cHasCPU.append(c.cpuPercent != nil)
                cMem.append(Int64(clamping: c.memBytes ?? 0)); cHasMem.append(c.memBytes != nil)
                cRun.append(c.state == "running")
            }
        }
        if !dTs.isEmpty {
            try await conn.query("""
                INSERT INTO mon.disk_sample (server_id, mount, ts, used_bytes, total_bytes)
                SELECT \(id), m, t, u, tot FROM unnest(\(dMount)::text[], \(dTs)::timestamptz[], \(dUsed)::int8[],
                  \(dTotal)::int8[]) AS x(m, t, u, tot)
                ON CONFLICT (server_id, mount, ts) DO UPDATE SET used_bytes = EXCLUDED.used_bytes,
                  total_bytes = EXCLUDED.total_bytes
                """, logger: logger)
        }
        if !cTs.isEmpty {
            try await conn.query("""
                INSERT INTO mon.container_sample (server_id, container, ts, cpu, mem_bytes, running)
                SELECT \(id), n, t, CASE WHEN hc THEN c END, CASE WHEN hm THEN m END, r
                FROM unnest(\(cName)::text[], \(cTs)::timestamptz[], \(cCPU)::float8[], \(cHasCPU)::bool[],
                  \(cMem)::int8[], \(cHasMem)::bool[], \(cRun)::bool[]) AS x(n, t, c, hc, m, hm, r)
                ON CONFLICT (server_id, container, ts) DO UPDATE SET cpu = EXCLUDED.cpu,
                  mem_bytes = EXCLUDED.mem_bytes, running = EXCLUDED.running
                """, logger: logger)
        }
    }

    public func addSiteSamples(serverID: String, _ snaps: [Snapshot]) async throws {
        guard let probe = agentProbes[try uuid(serverID)] else { return }
        var site: [UUID] = [], ts: [Date] = [], ok: [Bool] = [], status: [Int64] = [], hasStatus: [Bool] = []
        var latency: [Double] = [], error: [String] = [], hasError: [Bool] = []
        for s in snaps {
            for c in s.checks ?? [] where c.id.hasPrefix(SiteConfig.checkPrefix) {
                guard let id = siteUUID(String(c.id.dropFirst(SiteConfig.checkPrefix.count))) else { continue }
                site.append(id); ts.append(s.time); ok.append(c.ok)
                status.append(Int64(c.statusCode ?? 0)); hasStatus.append(c.statusCode != nil)
                latency.append(c.latencyMs)
                error.append(c.error ?? ""); hasError.append(c.error != nil)
            }
        }
        guard !site.isEmpty else { return }
        try await db.query("""
            INSERT INTO mon.site_check (site_id, probe_id, ts, ok, status, latency_ms, error)
            SELECT s, \(probe), t, o, CASE WHEN hs THEN st END, l, CASE WHEN he THEN e END
            FROM unnest(\(site)::uuid[], \(ts)::timestamptz[], \(ok)::bool[], \(status)::int8[], \(hasStatus)::bool[],
              \(latency)::float8[], \(error)::text[], \(hasError)::bool[]) AS x(s, t, o, st, hs, l, e, he)
            ON CONFLICT (site_id, probe_id, ts) DO UPDATE SET ok = EXCLUDED.ok, status = EXCLUDED.status,
              latency_ms = EXCLUDED.latency_ms, error = EXCLUDED.error
            """)
    }

    public func addLinkSamples(serverID: String, _ snaps: [Snapshot]) async throws {
        let id = try uuid(serverID)
        var peer: [UUID] = [], ts: [Date] = [], ok: [Bool] = [], latency: [Double] = []
        for s in snaps {
            for c in s.checks ?? [] where c.id.hasPrefix(ServerConfig.peerCheckPrefix) {
                guard let p = serverUUID(String(c.id.dropFirst(ServerConfig.peerCheckPrefix.count))) else { continue }
                peer.append(p); ts.append(s.time); ok.append(c.ok); latency.append(c.latencyMs)
            }
        }
        guard !peer.isEmpty else { return }
        try await db.query("""
            INSERT INTO mon.link_sample (server_id, peer_id, ts, ok, latency_ms)
            SELECT \(id), p, t, o, CASE WHEN o THEN l END
            FROM unnest(\(peer)::uuid[], \(ts)::timestamptz[], \(ok)::bool[], \(latency)::float8[]) AS x(p, t, o, l)
            ON CONFLICT (server_id, peer_id, ts) DO UPDATE SET ok = EXCLUDED.ok, latency_ms = EXCLUDED.latency_ms
            """)
    }

    /// Same counting as the Mac: the growth of each client's counter since
    /// the last snapshot goes to its local day; a smaller counter means the
    /// VPN restarted and the whole value is new; a client seen for the first
    /// time only sets the starting point. Each client gets an inv.vpn_key row.
    public func addVPNTraffic(_ serverID: String, _ snap: Snapshot, calendar: Calendar) async throws {
        let id = try uuid(serverID)
        let peers = (snap.vpn ?? []).flatMap { v in (v.peers ?? []).map { (v, $0) } }
        guard !peers.isEmpty else { return }
        let c = calendar.dateComponents([.year, .month, .day], from: snap.time)
        let day = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        try await db.transaction { conn in
            for (vpn, p) in peers {
                let name = p.name?.isEmpty == false ? p.name! : String(p.publicKey.prefix(8))
                guard let key = try await conn.scalar("""
                    INSERT INTO inv.vpn_key (server_id, container, protocol, public_key, name)
                    VALUES (\(id), \(vpn.container), \(vpn.protocol), \(p.publicKey), \(name))
                    ON CONFLICT (server_id, public_key) DO UPDATE SET container = EXCLUDED.container,
                      protocol = EXCLUDED.protocol,
                      name = CASE WHEN \(p.name ?? "") <> '' THEN EXCLUDED.name ELSE inv.vpn_key.name END
                    RETURNING id
                    """, as: UUID.self, logger: logger) else { continue }
                let rx = Int64(clamping: p.rxBytes), tx = Int64(clamping: p.txBytes)
                let prev = try await conn.query("SELECT rx, tx FROM mon.vpn_counter WHERE vpn_key_id = \(key)",
                                                logger: logger).decode((Int64, Int64).self)
                var before: (Int64, Int64)?
                for try await row in prev { before = row }
                if let (prx, ptx) = before {
                    let drx = rx >= prx ? rx - prx : rx, dtx = tx >= ptx ? tx - ptx : tx
                    if drx > 0 || dtx > 0 {
                        try await conn.query("""
                            INSERT INTO mon.vpn_traffic_daily (vpn_key_id, day, rx, tx) VALUES (\(key), \(day)::date, \(drx), \(dtx))
                            ON CONFLICT (vpn_key_id, day) DO UPDATE SET
                              rx = mon.vpn_traffic_daily.rx + EXCLUDED.rx, tx = mon.vpn_traffic_daily.tx + EXCLUDED.tx
                            """, logger: logger)
                    }
                }
                try await conn.query("""
                    INSERT INTO mon.vpn_counter (vpn_key_id, rx, tx, seen_at, last_handshake_at)
                    VALUES (\(key), \(rx), \(tx), \(snap.time), \(p.latestHandshake))
                    ON CONFLICT (vpn_key_id) DO UPDATE SET rx = EXCLUDED.rx, tx = EXCLUDED.tx,
                      seen_at = EXCLUDED.seen_at, last_handshake_at = EXCLUDED.last_handshake_at
                    """, logger: logger)
            }
        }
    }

    public func addPoll(_ serverID: String, at time: Date, ok: Bool, error: String?) async throws {
        guard let probe = hubProbe else { return }
        try await db.query("""
            INSERT INTO mon.poll (server_id, probe_id, ts, ok, error) VALUES (\(try uuid(serverID)), \(probe), \(time), \(ok), \(error))
            ON CONFLICT (server_id, probe_id, ts) DO UPDATE SET ok = EXCLUDED.ok, error = EXCLUDED.error
            """)
    }

    // MARK: events and problems

    /// What an alert id names: a server (uuid), a site ("site:<uuid>"), or
    /// the hub itself (anything else, like the summary after a pause).
    static func object(_ alertID: String, servers: [String: UUID] = [:], sites: [String: UUID] = [:]) -> (type: String, id: UUID?) {
        if alertID.hasPrefix("site:") {
            let s = String(alertID.dropFirst(5))
            if let u = sites[s] ?? UUID(uuidString: s) { return ("site", u) }
        }
        if let u = servers[alertID] ?? UUID(uuidString: alertID) { return ("server", u) }
        return ("hub", nil)
    }

    /// The journal line, and for alerts the problem it belongs to: "fired"
    /// opens an ops.incident, "reminder" counts on it, "resolved" closes it.
    /// One transaction, so the journal and the problems never disagree.
    public func addEvent(_ e: AlertEvent, actor: String) async throws {
        let (type, id) = Self.object(e.serverID, servers: serverIDs, sites: siteIDs)
        let kind = String(e.key.split(separator: ":").first ?? Substring(e.key))
        let severity = Int64(e.severity.rawValue)
        try await db.transaction { conn in
            var incident: UUID?
            switch e.kind {
            case .fired:
                incident = try await conn.scalar("""
                    INSERT INTO ops.incident (object_type, object_id, object_name, key, kind, severity, message,
                                              started_at, last_notified_at)
                    VALUES (\(type), \(id), \(e.serverName), \(e.key), \(kind), \(max(1, min(2, severity))),
                            \(e.message), \(e.time), \(e.time))
                    ON CONFLICT (object_type, object_id, key) WHERE ended_at IS NULL
                      DO UPDATE SET severity = EXCLUDED.severity, message = EXCLUDED.message
                    RETURNING id
                    """, as: UUID.self, logger: logger)
            case .reminder:
                incident = try await conn.scalar("""
                    UPDATE ops.incident SET reminders = reminders + 1, last_notified_at = \(e.time)
                    WHERE object_type = \(type) AND object_id IS NOT DISTINCT FROM \(id) AND key = \(e.key)
                      AND ended_at IS NULL
                    RETURNING id
                    """, as: UUID.self, logger: logger)
            case .resolved:
                incident = try await conn.scalar("""
                    UPDATE ops.incident SET ended_at = greatest(started_at, \(e.time))
                    WHERE object_type = \(type) AND object_id IS NOT DISTINCT FROM \(id) AND key = \(e.key)
                      AND ended_at IS NULL
                    RETURNING id
                    """, as: UUID.self, logger: logger)
            case .info:
                break
            }
            try await conn.query("""
                INSERT INTO ops.event (ts, object_type, object_id, kind, key, severity, message, incident_id, actor_id)
                VALUES (\(e.time), \(type), \(id), \(e.kind.rawValue), \(e.key), \(severity), \(e.message), \(incident),
                        \(UUID(uuidString: actor)))
                """, logger: logger)
            // Telegram messages for it, in the same transaction. A mistake
            // there must not lose the journal line or the incident.
            if let incident {
                try await conn.query("SAVEPOINT notify", logger: logger)
                do {
                    try await NotifyQueue.enqueue(conn, kind: e.kind, incidentID: incident, now: e.time, logger: logger)
                    try await conn.query("RELEASE SAVEPOINT notify", logger: logger)
                } catch {
                    logger.error("telegram queue: \(HubError.describe(error))")
                    try await conn.query("ROLLBACK TO SAVEPOINT notify", logger: logger)
                }
            }
        }
    }

    public func eventCount(_ serverID: String, key: String, since: Date) async throws -> Int {
        let (type, id) = Self.object(serverID, servers: serverIDs, sites: siteIDs)
        return Int(try await db.scalar("""
            SELECT count(*) FROM ops.event
            WHERE object_type = \(type) AND object_id IS NOT DISTINCT FROM \(id) AND key = \(key) AND ts >= \(since)
            """, as: Int64.self) ?? 0)
    }

    // MARK: latest snapshot

    public func setLatest(_ serverID: String, _ snap: Snapshot) async throws {
        let json = String(decoding: try AgentJSON.encoder.encode(snap), as: UTF8.self)
        try await db.query("""
            INSERT INTO mon.latest_snapshot (server_id, ts, snapshot) VALUES (\(try uuid(serverID)), \(snap.time), \(json)::jsonb)
            ON CONFLICT (server_id) DO UPDATE SET ts = EXCLUDED.ts, snapshot = EXCLUDED.snapshot
            """)
        if let v = snap.agentVersion {
            try await db.query("UPDATE inv.server SET agent_version = \(v) WHERE id = \(try uuid(serverID)) AND agent_version IS DISTINCT FROM \(v)")
        }
    }

    public func latest(_ serverID: String) async throws -> Snapshot? {
        guard let json = try await db.scalar(
            "SELECT snapshot::text FROM mon.latest_snapshot WHERE server_id = \(try uuid(serverID))", as: String.self)
        else { return nil }
        return try? AgentJSON.decoder.decode(Snapshot.self, from: Data(json.utf8))
    }

    public func lastSampleTime(_ serverID: String) async throws -> Date? {
        try await db.scalar("SELECT max(ts) FROM mon.server_sample WHERE server_id = \(try uuid(serverID))",
                            as: Date?.self) ?? nil
    }

    // MARK: summaries and cleanup

    /// Recomputes every hour touched since `since` (running it again is
    /// harmless), then once an hour makes the partitions ahead and drops the
    /// expired ones.
    public func rollup(since: Date, now: Date) async throws {
        let from = Date(timeIntervalSince1970: (since.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
        let probe = hubProbe
        try await db.transaction { conn in
            try await conn.query("""
                INSERT INTO mon.server_hourly (server_id, hour, cpu_avg, cpu_max, mem_avg, mem_max, disk_max,
                  load1_avg, rx_avg, tx_avg, vpn_max, samples, polls_ok, polls_total)
                SELECT h.server_id, h.hour, s.cpu_avg, s.cpu_max, s.mem_avg, s.mem_max, s.disk_max, s.load1_avg,
                       s.rx_avg, s.tx_avg, s.vpn_max, coalesce(s.n, 0), coalesce(p.ok, 0), coalesce(p.total, 0)
                FROM (SELECT server_id, date_trunc('hour', ts) AS hour FROM mon.server_sample WHERE ts >= \(from)
                      UNION SELECT server_id, date_trunc('hour', ts) FROM mon.poll
                            WHERE ts >= \(from) AND probe_id IS NOT DISTINCT FROM \(probe)) h
                LEFT JOIN (SELECT server_id, date_trunc('hour', ts) AS hour, avg(cpu) cpu_avg, max(cpu) cpu_max,
                                  avg(mem) mem_avg, max(mem) mem_max, max(disk_max) disk_max, avg(load1) load1_avg,
                                  avg(rx_bps) rx_avg, avg(tx_bps) tx_avg, max(vpn_clients) vpn_max, count(*) n
                           FROM mon.server_sample WHERE ts >= \(from) GROUP BY 1, 2) s
                  ON s.server_id = h.server_id AND s.hour = h.hour
                LEFT JOIN (SELECT server_id, date_trunc('hour', ts) AS hour, count(*) FILTER (WHERE ok) ok, count(*) total
                           FROM mon.poll WHERE ts >= \(from) AND probe_id IS NOT DISTINCT FROM \(probe) GROUP BY 1, 2) p
                  ON p.server_id = h.server_id AND p.hour = h.hour
                ON CONFLICT (server_id, hour) DO UPDATE SET cpu_avg = EXCLUDED.cpu_avg, cpu_max = EXCLUDED.cpu_max,
                  mem_avg = EXCLUDED.mem_avg, mem_max = EXCLUDED.mem_max, disk_max = EXCLUDED.disk_max,
                  load1_avg = EXCLUDED.load1_avg, rx_avg = EXCLUDED.rx_avg, tx_avg = EXCLUDED.tx_avg,
                  vpn_max = EXCLUDED.vpn_max, samples = EXCLUDED.samples, polls_ok = EXCLUDED.polls_ok,
                  polls_total = EXCLUDED.polls_total
                """, logger: logger)
            try await conn.query("""
                INSERT INTO mon.link_hourly (server_id, peer_id, hour, ok, total, latency_ms)
                SELECT server_id, peer_id, date_trunc('hour', ts), count(*) FILTER (WHERE ok), count(*), avg(latency_ms)
                FROM mon.link_sample WHERE ts >= \(from) GROUP BY 1, 2, 3
                ON CONFLICT (server_id, peer_id, hour) DO UPDATE SET ok = EXCLUDED.ok, total = EXCLUDED.total,
                  latency_ms = EXCLUDED.latency_ms
                """, logger: logger)
            try await conn.query("""
                INSERT INTO mon.site_hourly (site_id, probe_id, hour, ok, total, latency_avg, latency_p95)
                SELECT site_id, probe_id, date_trunc('hour', ts), count(*) FILTER (WHERE ok), count(*),
                       avg(latency_ms), percentile_cont(0.95) WITHIN GROUP (ORDER BY latency_ms)
                FROM mon.site_check WHERE ts >= \(from) GROUP BY 1, 2, 3
                ON CONFLICT (site_id, probe_id, hour) DO UPDATE SET ok = EXCLUDED.ok, total = EXCLUDED.total,
                  latency_avg = EXCLUDED.latency_avg, latency_p95 = EXCLUDED.latency_p95
                """, logger: logger)
            try await conn.query("""
                INSERT INTO mon.container_hourly (server_id, container, hour, cpu_avg, cpu_max, mem_avg, mem_max,
                                                  running_minutes)
                SELECT server_id, container, date_trunc('hour', ts), avg(cpu), max(cpu), avg(mem_bytes)::bigint,
                       max(mem_bytes), count(*) FILTER (WHERE running)
                FROM mon.container_sample WHERE ts >= \(from) GROUP BY 1, 2, 3
                ON CONFLICT (server_id, container, hour) DO UPDATE SET cpu_avg = EXCLUDED.cpu_avg,
                  cpu_max = EXCLUDED.cpu_max, mem_avg = EXCLUDED.mem_avg, mem_max = EXCLUDED.mem_max,
                  running_minutes = EXCLUDED.running_minutes
                """, logger: logger)
        }
        if let prunedAt, now.timeIntervalSince(prunedAt) < Self.pruneEvery, now >= prunedAt { return }
        let changed = try await Partitions.ensure(db, now: now)
        if !changed.isEmpty { logger.info("partitions: \(changed.joined(separator: ", "))") }
        // Tables without partitions are trimmed by age (db-schema.md).
        try await db.query("DELETE FROM sys.job_run WHERE started_at < \(now.addingTimeInterval(-7 * 86_400))")
        try await db.query("DELETE FROM ntf.delivery WHERE queued_at < \(now.addingTimeInterval(-365 * 86_400))")
        prunedAt = now
    }

    // MARK: domains and small state

    public func setDomain(_ domain: String, _ e: DomainExpiry.Entry) async throws {
        try await db.query("""
            INSERT INTO inv.domain (name, expires_at, checked_at, error) VALUES (\(domain), \(e.expiry), \(e.checkedAt), \(e.error))
            ON CONFLICT (name) DO UPDATE SET expires_at = EXCLUDED.expires_at, checked_at = EXCLUDED.checked_at,
              error = EXCLUDED.error
            """)
    }

    public func domains() async throws -> [String: DomainExpiry.Entry] {
        var out: [String: DomainExpiry.Entry] = [:]
        let rows = try await db.query("SELECT name::text, expires_at, checked_at, error FROM inv.domain WHERE checked_at IS NOT NULL")
        for try await (name, expiry, checked, error) in rows.decode((String, Date?, Date, String?).self) {
            out[name] = DomainExpiry.Entry(expiry: expiry, error: error, checkedAt: checked)
        }
        return out
    }

    public func setValue(_ value: String?, for key: String) async throws {
        if let value {
            try await db.query("""
                INSERT INTO sys.kv (key, value, updated_at) VALUES (\(key), to_jsonb(\(value)::text), now())
                ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now()
                """)
        } else {
            try await db.query("DELETE FROM sys.kv WHERE key = \(key)")
        }
    }

    public func value(_ key: String) async throws -> String? {
        try await db.scalar("SELECT value #>> '{}' FROM sys.kv WHERE key = \(key)", as: String?.self) ?? nil
    }
}
