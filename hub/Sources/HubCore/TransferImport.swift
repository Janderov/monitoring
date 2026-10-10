import Foundation
import Logging
import MonitorCore
import PostgresNIO

/// Moves the Mac's monitoring onto the hub from the file the app already
/// makes in Settings → «Перенос» (servers, sites, their secrets and the
/// SQLite history, encrypted with a password). Running it again updates the
/// servers and sites and adds only what is missing: safe to repeat.
///
/// Clients come from the file's clients.json (see ClientImport); files made
/// before clients existed put everything under «Своё».
///
/// SSH passwords in the file are NOT imported: root access stays on the Mac.
public enum TransferImport {
    public struct Report: Sendable, CustomStringConvertible {
        public var servers = 0
        public var sites = 0
        public var rows: [String: Int] = [:]
        public var skipped: [String] = []

        public var description: String {
            var lines = ["серверов: \(servers)", "сайтов: \(sites)"]
            for (t, n) in rows.sorted(by: { $0.key < $1.key }) { lines.append("\(t): \(n)") }
            for s in skipped { lines.append("пропущено: \(s)") }
            return lines.joined(separator: "\n")
        }
    }

    public static func run(_ db: Database, box: SecretBox, file: Data, password: String, source: String,
                           now: Date = Date()) async throws -> Report {
        let (contents, database) = try Transfer.open(file, password: password)
        let (servers, problems) = try ServersFile.decodeSkipping(contents.servers)
        var report = Report()
        report.skipped = problems

        try await Partitions.ensure(db, now: now, back: 731 * 86_400)
        let internalID = try await internalClient(db)
        // Files from before clients existed have no book: everything is «Своё».
        var book: ClientBook?
        if let data = contents.clients {
            do { book = try ClientsRepository.decode(data) } catch {
                report.skipped.append("клиенты: файл клиентов не читается, всё отнесено к «Своё»")
            }
        }
        let client: UUID? = book == nil ? internalID : nil

        // Servers: old text id → uuid, kept in sys.legacy_id.
        var serverIDs: [String: UUID] = [:]
        for s in servers.servers {
            guard let token = contents.secrets[SecretKey.agentToken(s.id)], !token.isEmpty else {
                report.skipped.append("сервер «\(s.name)»: в файле нет токена агента")
                continue
            }
            guard let fp = Fingerprint.bytes(s.fingerprint) else {
                report.skipped.append("сервер «\(s.name)»: неверный отпечаток сертификата")
                continue
            }
            serverIDs[s.id] = try await upsertServer(db, box: box, s, token: token, fingerprint: fp, client: client)
            report.servers += 1
        }
        let probes = try await Inventory.probes(db, hubName: "Хаб")

        var siteIDs: [String: UUID] = [:]
        for site in servers.sites ?? [] {
            let password = contents.secrets[SecretKey.siteAuth(site.id)]
            let id = try await upsertSite(db, box: box, site, password: password, client: client)
            siteIDs[site.id] = id
            try await db.query("DELETE FROM inv.site_probe WHERE site_id = \(id)")
            for legacy in site.from ?? [] {
                guard let sid = serverIDs[legacy], let probe = probes.agents[sid] else { continue }
                try await db.query("INSERT INTO inv.site_probe (site_id, probe_id) VALUES (\(id), \(probe)) ON CONFLICT DO NOTHING")
            }
            report.sites += 1
        }

        // History, from a temporary copy of the Mac's database.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hub-import-\(UUID().uuidString).sqlite")
        try database.write(to: tmp, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let sqlite = try Store(path: tmp.path)
        try await importHistory(db, from: sqlite, servers: serverIDs, sites: siteIDs, probes: probes,
                                source: source, now: now, report: &report)
        if let book {
            let ids = try await ClientImport.clients(db, book, internalID: internalID)
            try await ClientImport.assets(db, book, clients: ids, internalID: internalID, servers: serverIDs,
                                          sites: siteIDs, now: now, report: &report)
        }
        return report
    }

    static func internalClient(_ db: Database) async throws -> UUID {
        if let id = try await db.scalar("SELECT id FROM inv.client WHERE is_internal", as: UUID.self) { return id }
        return try await db.scalar("""
            INSERT INTO inv.client (name, is_internal) VALUES ('Своё', true)
            ON CONFLICT (name) DO UPDATE SET is_internal = true RETURNING id
            """, as: UUID.self)!
    }

    static func legacy(_ db: Database, _ kind: String, _ id: String) async throws -> UUID? {
        try await db.scalar("SELECT id FROM sys.legacy_id WHERE kind = \(kind) AND legacy_id = \(id)", as: UUID.self)
    }

    static func snakeJSON<T: Encodable>(_ value: T?) throws -> String {
        guard let value else { return "{}" }
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return String(decoding: try e.encode(value), as: UTF8.self)
    }

    static func sshTarget(_ t: SSHTarget?) -> String? {
        guard let t else { return nil }
        var s = t.user.map { "\($0)@" } ?? ""
        s += t.host
        if let p = t.port { s += ":\(p)" }
        return s
    }

    static func currency(_ symbol: String) -> String? {
        switch symbol {
        case "₽", "RUB": return "RUB"
        case "€", "EUR": return "EUR"
        case "$", "USD": return "USD"
        default: return symbol.count == 3 ? symbol.uppercased() : nil
        }
    }

    static func upsertServer(_ db: Database, box: SecretBox, _ s: ServerConfig, token: String, fingerprint: [UInt8],
                             client: UUID?) async throws -> UUID {
        let tags = ([s.group].compactMap { $0 } + (s.tags ?? [])).filter { !$0.isEmpty }
        let th = try snakeJSON(s.thresholds)
        let ssh = sshTarget(s.ssh)
        let cost = s.cost.map { Double($0.monthly) }
        let cur = s.cost.flatMap { currency($0.currency) }
        let payDay = s.cost?.payDay.map(Int64.init)
        if let id = try await legacy(db, "server", s.id),
           let secretID = try await db.scalar("SELECT agent_token_id FROM inv.server WHERE id = \(id)", as: UUID.self) {
            let sealed = try box.seal(token, id: secretID, kind: "agent_token")
            try await db.transaction { conn in
                try await conn.query("""
                    UPDATE sys.secret SET ciphertext = \(ByteBuffer(bytes: sealed.ciphertext)), nonce = \(ByteBuffer(bytes: sealed.nonce)),
                      key_version = \(SecretBox.keyVersion), rotated_at = now() WHERE id = \(secretID)
                    """, logger: db.logger)
                try await conn.query("""
                    UPDATE inv.server SET name = \(s.name), host = \(s.host), agent_port = \(s.port),
                      agent_fingerprint = \(ByteBuffer(bytes: fingerprint)), thresholds = \(th)::jsonb, tags = \(tags),
                      ssh_target = \(ssh), monthly_cost = \(cost), currency = \(cur), pay_day = \(payDay),
                      archived_at = NULL
                    WHERE id = \(id)
                    """, logger: db.logger)
            }
            return id
        }
        let id = UUID(), secretID = UUID()
        let sealed = try box.seal(token, id: secretID, kind: "agent_token")
        try await db.transaction { conn in
            try await conn.query("""
                INSERT INTO sys.secret (id, kind, ciphertext, nonce, key_version, label)
                VALUES (\(secretID), 'agent_token', \(ByteBuffer(bytes: sealed.ciphertext)), \(ByteBuffer(bytes: sealed.nonce)), \(SecretBox.keyVersion),
                        \("токен агента \(s.name)"))
                """, logger: db.logger)
            try await conn.query("""
                INSERT INTO inv.server (id, name, host, agent_port, agent_fingerprint, agent_token_id, ssh_target,
                                        thresholds, tags, monthly_cost, currency, pay_day)
                VALUES (\(id), \(s.name), \(s.host), \(s.port), \(ByteBuffer(bytes: fingerprint)), \(secretID), \(ssh), \(th)::jsonb,
                        \(tags), \(cost), \(cur), \(payDay))
                """, logger: db.logger)
            try await conn.query("INSERT INTO sys.legacy_id (kind, legacy_id, id) VALUES ('server', \(s.id), \(id))",
                                 logger: db.logger)
            if let client {
                try await conn.query("""
                    INSERT INTO inv.client_asset (client_id, asset_type, asset_id) VALUES (\(client), 'server', \(id))
                    ON CONFLICT DO NOTHING
                    """, logger: db.logger)
            }
        }
        return id
    }

    static func upsertSite(_ db: Database, box: SecretBox, _ site: SiteConfig, password: String?,
                           client: UUID?) async throws -> UUID {
        let tags = ([site.group].compactMap { $0 } + (site.tags ?? [])).filter { !$0.isEmpty }
        let th = try snakeJSON(site.thresholds)
        let existing = try await legacy(db, "site", site.id)
        let id = existing ?? UUID()
        let oldSecret = existing == nil ? nil
            : try await db.scalar("SELECT auth_password_id FROM inv.site WHERE id = \(id)", as: UUID?.self) ?? nil
        var secretID: UUID? = oldSecret
        try await db.transaction { conn in
            if let password, !password.isEmpty {
                let sid = oldSecret ?? UUID()
                let sealed = try box.seal(password, id: sid, kind: "site_password")
                try await conn.query("""
                    INSERT INTO sys.secret (id, kind, ciphertext, nonce, key_version, label)
                    VALUES (\(sid), 'site_password', \(ByteBuffer(bytes: sealed.ciphertext)), \(ByteBuffer(bytes: sealed.nonce)), \(SecretBox.keyVersion),
                            \("пароль сайта \(site.name)"))
                    ON CONFLICT (id) DO UPDATE SET ciphertext = EXCLUDED.ciphertext, nonce = EXCLUDED.nonce,
                      key_version = EXCLUDED.key_version, rotated_at = now()
                    """, logger: db.logger)
                secretID = sid
            }
            if existing != nil {
                try await conn.query("""
                    UPDATE inv.site SET name = \(site.name), url = \(site.url), thresholds = \(th)::jsonb, tags = \(tags),
                      auth_user = \(site.authUser), auth_password_id = \(secretID), archived_at = NULL
                    WHERE id = \(id)
                    """, logger: db.logger)
            } else {
                try await conn.query("""
                    INSERT INTO inv.site (id, name, url, thresholds, tags, auth_user, auth_password_id)
                    VALUES (\(id), \(site.name), \(site.url), \(th)::jsonb, \(tags), \(site.authUser), \(secretID))
                    """, logger: db.logger)
                try await conn.query("INSERT INTO sys.legacy_id (kind, legacy_id, id) VALUES ('site', \(site.id), \(id))",
                                     logger: db.logger)
                if let client {
                    try await conn.query("""
                        INSERT INTO inv.client_asset (client_id, asset_type, asset_id) VALUES (\(client), 'site', \(id))
                        ON CONFLICT DO NOTHING
                        """, logger: db.logger)
                }
            }
        }
        return id
    }

    // MARK: history

    static func batch(_ db: Database, source: String, table: String,
                      _ body: () async throws -> Int) async throws -> Int {
        let id = try await db.scalar(
            "INSERT INTO sys.import_batch (source, source_table) VALUES (\(source), \(table)) RETURNING id", as: UUID.self)!
        do {
            let n = try await body()
            try await db.query("UPDATE sys.import_batch SET finished_at = now(), rows = \(Int64(n)), status = 'done' WHERE id = \(id)")
            return n
        } catch {
            _ = try? await db.query("UPDATE sys.import_batch SET finished_at = now(), status = 'failed', error = \(String(describing: error)) WHERE id = \(id)")
            throw error
        }
    }

    static func alreadyDone(_ db: Database, source: String, table: String) async throws -> Bool {
        try await db.scalar("""
            SELECT count(*) FROM sys.import_batch WHERE source = \(source) AND source_table = \(table) AND status = 'done'
            """, as: Int64.self) ?? 0 > 0
    }

    static func importHistory(_ db: Database, from sqlite: Store, servers: [String: UUID], sites: [String: UUID],
                              probes: (hub: UUID, agents: [UUID: UUID]), source: String, now: Date,
                              report: inout Report) async throws {
        let day: TimeInterval = 86_400
        let rawFrom = Partitions.start(of: now.addingTimeInterval(-30 * day), step: .day)
        let yearFrom = Partitions.start(of: now.addingTimeInterval(-365 * day), step: .month)

        report.rows["samples"] = try await batch(db, source: source, table: "samples") {
            var n = 0
            for (legacy, id) in servers {
                let rows = try await sqlite.samples(legacy, from: rawFrom, to: now)
                for chunk in stride(from: 0, to: rows.count, by: 5000).map({ Array(rows[$0..<min($0 + 5000, rows.count)]) }) {
                    try await db.query("""
                        INSERT INTO mon.server_sample (server_id, ts, cpu, mem, disk_max, load1, rx_bps, tx_bps, vpn_clients)
                        SELECT \(id), * FROM unnest(\(chunk.map(\.time))::timestamptz[], \(chunk.map(\.cpu))::float8[],
                          \(chunk.map(\.mem))::float8[], \(chunk.map(\.disk))::float8[], \(chunk.map(\.load1))::float8[],
                          \(chunk.map(\.rx))::float8[], \(chunk.map(\.tx))::float8[], \(chunk.map { Int64($0.vpnClients) })::int8[])
                        ON CONFLICT DO NOTHING
                        """)
                    n += chunk.count
                }
            }
            return n
        }

        report.rows["hourly"] = try await batch(db, source: source, table: "hourly") {
            var n = 0
            for (legacy, id) in servers {
                let rows = try await sqlite.hourly(legacy, from: yearFrom, to: now)
                for chunk in stride(from: 0, to: rows.count, by: 5000).map({ Array(rows[$0..<min($0 + 5000, rows.count)]) }) {
                    try await db.query("""
                        INSERT INTO mon.server_hourly (server_id, hour, cpu_avg, cpu_max, mem_avg, mem_max, disk_max,
                                                       rx_avg, tx_avg, vpn_max, samples, polls_ok, polls_total)
                        SELECT \(id), * FROM unnest(\(chunk.map(\.hour))::timestamptz[], \(chunk.map(\.cpuAvg))::float8[],
                          \(chunk.map(\.cpuMax))::float8[], \(chunk.map(\.memAvg))::float8[], \(chunk.map(\.memMax))::float8[],
                          \(chunk.map(\.diskMax))::float8[], \(chunk.map(\.rxAvg))::float8[], \(chunk.map(\.txAvg))::float8[],
                          \(chunk.map { Int64($0.vpnMax) })::int8[], \(chunk.map { Int64($0.samples) })::int8[],
                          \(chunk.map { Int64($0.pollsOK) })::int8[], \(chunk.map { Int64($0.pollsTotal) })::int8[])
                        ON CONFLICT DO NOTHING
                        """)
                    n += chunk.count
                }
            }
            return n
        }

        report.rows["site_checks"] = try await batch(db, source: source, table: "site_samples") {
            var n = 0
            for (legacy, id) in sites {
                let rows = try await sqlite.siteSamples(legacy, from: rawFrom, to: now)
                    .compactMap { r -> (Store.SiteSample, UUID)? in
                        guard let sid = servers[r.serverID], let probe = probes.agents[sid] else { return nil }
                        return (r, probe)
                    }
                for chunk in stride(from: 0, to: rows.count, by: 5000).map({ Array(rows[$0..<min($0 + 5000, rows.count)]) }) {
                    try await db.query("""
                        INSERT INTO mon.site_check (site_id, probe_id, ts, ok, status, latency_ms, error)
                        SELECT \(id), p, t, o, CASE WHEN hs THEN st END, l, CASE WHEN he THEN e END
                        FROM unnest(\(chunk.map(\.1))::uuid[], \(chunk.map(\.0.time))::timestamptz[], \(chunk.map(\.0.ok))::bool[],
                          \(chunk.map { Int64($0.0.statusCode ?? 0) })::int8[], \(chunk.map { $0.0.statusCode != nil })::bool[],
                          \(chunk.map(\.0.latencyMs))::float8[], \(chunk.map { $0.0.error ?? "" })::text[],
                          \(chunk.map { $0.0.error != nil })::bool[]) AS x(p, t, o, st, hs, l, e, he)
                        ON CONFLICT DO NOTHING
                        """)
                    n += chunk.count
                }
            }
            return n
        }

        report.rows["links"] = try await batch(db, source: source, table: "link_samples") {
            var n = 0
            let linkFrom = Partitions.start(of: now.addingTimeInterval(-3 * day), step: .day)
            for (legacy, id) in servers {
                let rows = try await sqlite.linkSamples(legacy, from: linkFrom, to: now)
                    .compactMap { r -> (Store.LinkSample, UUID)? in servers[r.peerID].map { (r, $0) } }
                    .filter { $0.0.time >= linkFrom }
                guard !rows.isEmpty else { continue }
                try await db.query("""
                    INSERT INTO mon.link_sample (server_id, peer_id, ts, ok, latency_ms)
                    SELECT \(id), p, t, o, CASE WHEN o THEN l END
                    FROM unnest(\(rows.map(\.1))::uuid[], \(rows.map(\.0.time))::timestamptz[], \(rows.map(\.0.ok))::bool[],
                      \(rows.map { $0.0.latencyMs ?? 0 })::float8[]) AS x(p, t, o, l)
                    ON CONFLICT DO NOTHING
                    """)
                n += rows.count
            }
            return n
        }

        // Journal and audit have no natural key: imported once per Mac.
        if try await !alreadyDone(db, source: source, table: "events") {
            report.rows["events"] = try await batch(db, source: source, table: "events") {
                let evFrom = now.addingTimeInterval(-730 * day)
                var n = 0
                for e in try await sqlite.events(limit: 1_000_000, serverID: nil) where e.time >= evFrom {
                    let objectID: String
                    if e.serverID.hasPrefix("site:") {
                        objectID = sites[String(e.serverID.dropFirst(5))].map { "site:" + $0.uuidString } ?? "hub"
                    } else {
                        objectID = servers[e.serverID]?.uuidString ?? "hub"
                    }
                    let (type, id) = PostgresPollStore.object(objectID.lowercased())
                    try await db.query("""
                        INSERT INTO ops.event (ts, object_type, object_id, kind, key, severity, message)
                        VALUES (\(e.time), \(type), \(id), \(e.kind.rawValue), \(e.key), \(Int64(e.severity.rawValue)), \(e.message))
                        """)
                    n += 1
                }
                return n
            }
        }
        if try await !alreadyDone(db, source: source, table: "actions") {
            report.rows["audit"] = try await batch(db, source: source, table: "actions") {
                var n = 0
                for a in try await sqlite.actions(limit: 1_000_000, objectID: nil) where a.time >= now.addingTimeInterval(-730 * day) {
                    let type: String
                    var oid: UUID?
                    switch a.object.type {
                    case .server: type = "server"; oid = servers[a.object.id]
                    case .site: type = "site"; oid = sites[a.object.id]
                    case .vpnKey: type = "vpn_key"
                    case .app: type = "app"
                    }
                    let detail = try snakeJSON(["text": a.detail, "mac_object_id": a.object.id, "mac_actor_id": a.actor.id])
                    try await db.query("""
                        INSERT INTO ops.audit_log (ts, actor_kind, actor_name, action, object_type, object_id, object_name,
                                                   detail, result, error)
                        VALUES (\(a.time), 'owner', \(a.actor.name), \(a.action.rawValue), \(type), \(oid), \(a.object.name),
                                \(detail)::jsonb, \(a.result.rawValue), \(a.error))
                        """)
                    n += 1
                }
                return n
            }
        }

        report.rows["vpn_traffic"] = try await batch(db, source: source, table: "vpn_traffic") {
            var n = 0
            let localDay = DateFormatter()
            localDay.calendar = Calendar(identifier: .gregorian)
            localDay.timeZone = .current
            localDay.dateFormat = "yyyy-MM-dd"
            for (legacy, id) in servers {
                for key in try await sqlite.vpnTraffic(legacy, from: yearFrom, to: now).keys {
                    guard let vk = try await db.scalar("""
                        INSERT INTO inv.vpn_key (server_id, container, public_key, name)
                        VALUES (\(id), '', \(key), \(String(key.prefix(8))))
                        ON CONFLICT (server_id, public_key) DO UPDATE SET server_id = EXCLUDED.server_id
                        RETURNING id
                        """, as: UUID.self) else { continue }
                    for (day, usage) in try await sqlite.vpnDaily(legacy, publicKey: key, from: yearFrom, to: now) {
                        try await db.query("""
                            INSERT INTO mon.vpn_traffic_daily (vpn_key_id, day, rx, tx)
                            VALUES (\(vk), \(localDay.string(from: day))::date, \(Int64(clamping: usage.rx)), \(Int64(clamping: usage.tx)))
                            ON CONFLICT DO NOTHING
                            """)
                        n += 1
                    }
                }
            }
            return n
        }

        report.rows["domains"] = try await batch(db, source: source, table: "domains") {
            var n = 0
            for (name, e) in try await sqlite.domains() {
                try await db.query("""
                    INSERT INTO inv.domain (name, expires_at, checked_at, error) VALUES (\(name), \(e.expiry), \(e.checkedAt), \(e.error))
                    ON CONFLICT (name) DO NOTHING
                    """)
                n += 1
            }
            return n
        }
    }
}
