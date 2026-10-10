import Foundation
import Logging
import MonitorCore
import PostgresNIO
import XCTest
@testable import HubCore

/// Runs against a real PostgreSQL when HUB_TEST_PG=1 (PGHOST, PGPORT,
/// PGUSER, PGDATABASE, HUB_MIGRATIONS as for the hub). The database is wiped.
/// With HUB_TEST_AGENT=host:port, HUB_TEST_AGENT_TOKEN and
/// HUB_TEST_AGENT_FP it also polls a real agent.
final class PostgresTests: XCTestCase {
    var env: [String: String] { ProcessInfo.processInfo.environment }

    func snapshotJSON(time: Date, cpu: Double, rx: Int, siteID: String, peerID: String) -> String {
        """
        {
          "time": "\(AgentJSON.formatRFC3339(time))", "hostname": "wise", "uptime_seconds": 86400.5,
          "boot_time": "2026-10-04T07:58:28Z",
          "cpu": {"cores": 2, "usage_percent": \(cpu), "iowait_percent": 0.1, "steal_percent": 0},
          "memory": {"total_bytes": 2048000000, "available_bytes": 1024000000, "used_percent": 30,
                     "swap_total_bytes": 1000, "swap_free_bytes": 250},
          "load": {"one": 0.1, "five": 0.2, "fifteen": 0.3},
          "disks": [{"mount": "/", "device": "/dev/vda1", "fstype": "ext4",
                     "total_bytes": 20000000000, "free_bytes": 10000000000, "used_percent": 50}],
          "network": {"rx_bytes": 1000, "tx_bytes": 2000, "rx_bytes_per_sec": 10.5, "tx_bytes_per_sec": 20.5},
          "containers": [{"id": "abc", "name": "amnezia-awg2", "image": "amnezia-awg2", "state": "running",
                          "status": "Up", "cpu_percent": 1.5, "mem_bytes": 1000000}],
          "vpn": [{"container": "amnezia-awg2", "protocol": "awg", "running": true, "clients_known": true,
                   "clients": 24, "active_clients": 3, "rx_bytes": 5, "tx_bytes": 6,
                   "peers": [{"name": "phone", "public_key": "k=", "latest_handshake": "2026-10-05T07:57:00Z",
                              "active": true, "rx_bytes": \(rx), "tx_bytes": 2}]}],
          "checks": [
            {"id": "site-\(siteID)", "kind": "http", "target": "https://example.org", "ok": true,
             "status_code": 200, "latency_ms": 120},
            {"id": "peer-\(peerID)", "kind": "tcp", "target": "203.0.113.10:9443", "ok": false,
             "latency_ms": 0, "error": "timeout"}]
        }
        """
    }

    func snapshot(_ time: Date, cpu: Double = 12.5, rx: Int = 100, site: String = "shop", peer: String = "nl") -> Snapshot {
        try! AgentJSON.decoder.decode(Snapshot.self, from: Data(snapshotJSON(time: time, cpu: cpu, rx: rx,
                                                                                siteID: site, peerID: peer).utf8))
    }

    func testEverythingOnARealDatabase() async throws {
        guard env["HUB_TEST_PG"] == "1" else { throw XCTSkip("HUB_TEST_PG=1 not set") }
        do { try await everything() } catch { XCTFail(HubError.describe(error)) }
    }

    func everything() async throws {
        var logger = Logger(label: "test")
        logger.logLevel = .warning
        var config = try HubConfig.fromEnvironment(env)
        config.secretKey = Data(repeating: 9, count: 32)
        let hub = Hub(config: config, logger: logger)
        let db = Database(config, logger: logger)
        let runner = Task { await db.run() }
        defer { runner.cancel() }

        for s in ["sys", "acc", "inv", "mon", "ops", "ntf", "rep"] {
            try await db.query(PostgresQuery(unsafeSQL: "DROP SCHEMA IF EXISTS \(s) CASCADE"))
        }
        try await db.query("DROP TABLE IF EXISTS public.schema_migrations")
        try await db.query("DROP FUNCTION IF EXISTS public.uuidv7()")
        // uuidv7() is built into PostgreSQL 18; older test servers get a stand-in.
        if let version = try await db.scalar("SELECT current_setting('server_version_num')::int", as: Int32.self), version < 180000 {
            try await db.query("CREATE FUNCTION public.uuidv7() RETURNS uuid LANGUAGE sql AS 'SELECT gen_random_uuid()'")
        }

        // Migrations: applied once, then nothing to do.
        let first = try await Migrator.migrate(db, dir: config.migrationsDir)
        XCTAssertFalse(first.isEmpty)
        let again = try await Migrator.migrate(db, dir: config.migrationsDir)
        XCTAssertEqual(again, [])
        _ = try await hub.withDatabase { _ in () }

        // The Mac's transfer file: one server (the test agent when given),
        // one site behind a login, and some history.
        let now = Date()
        let agentHost = env["HUB_TEST_AGENT"]?.split(separator: ":").first.map(String.init) ?? "203.0.113.10"
        let agentPort = env["HUB_TEST_AGENT"]?.split(separator: ":").last.flatMap { Int($0) } ?? 9443
        let token = env["HUB_TEST_AGENT_TOKEN"] ?? String(repeating: "a", count: 43)
        let fp = env["HUB_TEST_AGENT_FP"] ?? String(repeating: "AB:", count: 31) + "AB"
        let servers = ServersFile(
            servers: [ServerConfig(id: "nl", name: "Нидерланды", host: agentHost, port: agentPort, token: "",
                                   fingerprint: fp, group: "VPN", thresholds: Thresholds(diskPercent: 85),
                                   ssh: SSHTarget(host: agentHost, port: 22, user: "root"),
                                   cost: ServerCost(monthly: 500, currency: "₽", payDay: 5))],
            sites: [SiteConfig(id: "shop", name: "Магазин", url: "https://example.org", from: ["nl"], authUser: "u")])
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mac-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let mac = try Store(path: tmp.path)
        let old = (1...30).map { snapshot(now.addingTimeInterval(TimeInterval(-3600 - $0 * 60)), cpu: Double($0)) }
        try await mac.addSamples("nl", old)
        try await mac.addSiteSamples(serverID: "nl", old)
        try await mac.rollup(since: now.addingTimeInterval(-7200), now: now)
        try await mac.addEvent(AlertEvent(serverID: "nl", serverName: "Нидерланды", key: "down", kind: .fired,
                                          severity: .critical, message: "не отвечает", time: now.addingTimeInterval(-5000)))
        try await mac.copy(to: tmp.appendingPathExtension("copy"))
        let database = try Data(contentsOf: tmp.appendingPathExtension("copy"))
        try? FileManager.default.removeItem(at: tmp.appendingPathExtension("copy"))
        // Clients: the site belongs to a customer, the server to nobody (= «Своё»).
        var book = ClientBook()
        book.ensureInternal(now: now)
        let shopOwner = Client(name: "ООО Ромашка", kind: .company,
                               contacts: [ClientContact(name: "Ирина", role: .owner, email: "Irina@example.com",
                                                        receivesReport: true)],
                               contracts: [ClientContract(planName: "Базовый", monthlyPrice: 3500, currency: "₽",
                                                          billingDay: 10, startedOn: now.addingTimeInterval(-40 * 86_400),
                                                          slaUptime: 99.5, reportDay: 3)],
                               createdAt: now.addingTimeInterval(-40 * 86_400))
        book.clients.append(shopOwner)
        book.assets = [ClientAsset(clientID: shopOwner.id, type: .site, assetID: "shop", since: now.addingTimeInterval(-40 * 86_400)),
                       ClientAsset(clientID: shopOwner.id, type: .vpnKey, assetID: "unknown-key", since: now)]
        let file = try Transfer.seal(
            Transfer.Contents(created: now, servers: try servers.encoded(),
                              secrets: [SecretKey.agentToken("nl"): token, SecretKey.siteAuth("shop"): "pw",
                                        SecretKey.sshPassword("nl"): "root-password"],
                              clients: try ClientsRepository.encode(book)),
            database: database, password: "password1", iterations: 1000)
        let box = try SecretBox(key: config.secretKey!)

        let report = try await TransferImport.run(db, box: box, file: file, password: "password1", source: "test-mac", now: now)
        XCTAssertEqual(report.servers, 1)
        XCTAssertEqual(report.sites, 1)
        XCTAssertEqual(report.rows["samples"], 30)
        XCTAssertEqual(report.rows["site_checks"], 30)
        XCTAssertEqual(report.rows["events"], 1)
        XCTAssertGreaterThan(report.rows["hourly"] ?? 0, 0)
        // A second import updates instead of duplicating.
        let second = try await TransferImport.run(db, box: box, file: file, password: "password1", source: "test-mac", now: now)
        XCTAssertNil(second.rows["events"])
        let count = try await db.scalar("SELECT count(*) FROM inv.server", as: Int64.self)
        XCTAssertEqual(count, 1)
        // The SSH password stays on the Mac.
        let secrets = try await db.scalar("SELECT count(*) FROM sys.secret", as: Int64.self)
        XCTAssertEqual(secrets, 2)
        // Clients from the book, owners replaced on every import, no doubles.
        XCTAssertEqual(second.rows["clients"], 2)
        XCTAssertTrue(second.skipped.contains { $0.contains("ключей VPN") })
        let clientCount = try await db.scalar("SELECT count(*) FROM inv.client", as: Int64.self)
        XCTAssertEqual(clientCount, 2)
        let siteOwner = try await db.scalar("""
            SELECT c.name FROM inv.client_asset a JOIN inv.client c ON c.id = a.client_id WHERE a.asset_type = 'site'
            """, as: String.self)
        XCTAssertEqual(siteOwner, "ООО Ромашка")
        let serverOwner = try await db.scalar("""
            SELECT c.name FROM inv.client_asset a JOIN inv.client c ON c.id = a.client_id WHERE a.asset_type = 'server'
            """, as: String.self)
        XCTAssertEqual(serverOwner, "Своё")
        let assetRows = try await db.scalar("SELECT count(*) FROM inv.client_asset", as: Int64.self)
        XCTAssertEqual(assetRows, 2)
        let contact = try await db.scalar("""
            SELECT email::text || '/' || role || '/' || receives_report FROM inv.client_contact
            """, as: String.self)
        XCTAssertEqual(contact, "Irina@example.com/owner/true")
        let contract = try await db.scalar("""
            SELECT plan_name || '/' || monthly_price || '/' || currency || '/' || billing_day || '/' || sla_uptime
            FROM inv.client_contract
            """, as: String.self)
        XCTAssertEqual(contract, "Базовый/3500.00/RUB/10/99.500")
        let reportDay = try await db.scalar("SELECT day_of_month::int8 FROM rep.client_report_settings", as: Int64.self)
        XCTAssertEqual(reportDay, 3)
        let shopClientID = try await db.scalar("SELECT id FROM inv.client WHERE NOT is_internal", as: UUID.self)
        XCTAssertEqual(shopClientID?.uuidString.lowercased(), shopOwner.id)

        let cost = try await db.scalar("SELECT currency::text FROM inv.server", as: String.self)
        XCTAssertEqual(cost, "RUB")

        let inv = try await Inventory.load(db, box: box)
        XCTAssertEqual(inv.servers.map(\.id), ["nl"])
        XCTAssertEqual(inv.servers.first?.token, token)
        XCTAssertEqual(inv.servers.first?.thresholds?.diskPercent, 85)
        XCTAssertEqual(inv.servers.first?.tags, ["VPN"])
        XCTAssertTrue(Fingerprint.matches(fp, sha256: Fingerprint.bytes(inv.servers.first!.fingerprint)!))
        XCTAssertEqual(inv.sites.first?.id, "shop")
        XCTAssertEqual(inv.sites.first?.from, ["nl"])
        XCTAssertEqual(inv.sites.first?.authPassword, "pw")
        XCTAssertEqual(inv.problems, [])
        let serverUUID = inv.serverIDs["nl"]!

        // The poller's store.
        let store = PostgresPollStore(db: db)
        let probes = try await Inventory.probes(db, hubName: "Хаб")
        await store.setProbes(hub: probes.hub, agents: probes.agents)
        await store.setIDs(servers: inv.serverIDs, sites: inv.siteIDs)
        let t0 = now.addingTimeInterval(-120)
        let snaps = [snapshot(t0, rx: 100), snapshot(t0.addingTimeInterval(60), rx: 400)]
        try await store.addSamples("nl", snaps)
        try await store.addSamples("nl", snaps) // again: no duplicate rows
        try await store.addSiteSamples(serverID: "nl", snaps)
        try await store.addLinkSamples(serverID: "nl", snaps)
        try await store.addVPNTraffic("nl", snaps[0], calendar: .current)
        try await store.addVPNTraffic("nl", snaps[1], calendar: .current)
        try await store.addPoll("nl", at: now, ok: true, error: nil)
        try await store.setLatest("nl", snaps[1])
        let latest = try await store.latest("nl")
        XCTAssertEqual(latest?.time, snaps[1].time)
        let last = try await store.lastSampleTime("nl")
        XCTAssertEqual(last.map { Int($0.timeIntervalSince1970) }, Int(snaps[1].time.timeIntervalSince1970))
        let raw = try await db.scalar("SELECT count(*) FROM mon.server_sample WHERE server_id = \(serverUUID)", as: Int64.self)
        XCTAssertEqual(raw, 32)
        let swap = try await db.scalar("SELECT swap::float8 FROM mon.server_sample WHERE ts >= \(t0.addingTimeInterval(-1)) ORDER BY ts LIMIT 1", as: Double.self)
        XCTAssertEqual(swap ?? 0, 75, accuracy: 0.01)
        let siteRows = try await db.scalar("SELECT count(*) FROM mon.site_check WHERE probe_id = \(probes.agents[serverUUID]!)", as: Int64.self)
        XCTAssertEqual(siteRows, 32)
        let links = try await db.scalar("SELECT count(*) FROM mon.link_sample WHERE NOT ok AND latency_ms IS NULL", as: Int64.self)
        XCTAssertEqual(links, 2)
        let traffic = try await db.scalar("SELECT sum(rx)::int8 FROM mon.vpn_traffic_daily", as: Int64.self)
        XCTAssertEqual(traffic, 300)
        let containers = try await db.scalar("SELECT count(*) FROM mon.container_sample", as: Int64.self)
        XCTAssertEqual(containers, 2)

        // Alerts: fired opens a problem, reminder counts, resolved closes it.
        let fired = AlertEvent(serverID: "nl", serverName: "Нидерланды", key: "disk:/", kind: .fired,
                               severity: .warning, message: "диск 91%", time: now.addingTimeInterval(-60))
        try await store.addEvent(fired, actor: "system")
        try await store.addEvent(fired, actor: "system") // a repeat does not open a second one
        var reminder = fired
        reminder.kind = .reminder
        try await store.addEvent(reminder, actor: "system")
        let open = try await db.scalar("SELECT reminders::int8 FROM ops.incident WHERE ended_at IS NULL AND key = 'disk:/'", as: Int64.self)
        XCTAssertEqual(open, 1)
        var resolved = fired
        resolved.kind = .resolved
        resolved.time = now
        try await store.addEvent(resolved, actor: "system")
        let closed = try await db.scalar("SELECT duration_s::int8 FROM ops.incident WHERE key = 'disk:/'", as: Int64.self)
        XCTAssertEqual(closed, 60)
        let linked = try await db.scalar("SELECT count(*) FROM ops.event WHERE incident_id IS NOT NULL", as: Int64.self)
        XCTAssertEqual(linked, 4)
        let n = try await store.eventCount("nl", key: "disk:/", since: now.addingTimeInterval(-3600))
        XCTAssertEqual(n, 4)
        let siteEvent = AlertEvent(serverID: "site:shop", serverName: "Магазин", key: "down", kind: .fired,
                                   severity: .critical, message: "не открывается", time: now)
        try await store.addEvent(siteEvent, actor: "system")
        let siteIncident = try await db.scalar("SELECT object_type FROM ops.incident WHERE object_id = \(inv.siteIDs["shop"]!)", as: String.self)
        XCTAssertEqual(siteIncident, "site")

        try await db.query("INSERT INTO sys.job_run (job, started_at) VALUES ('old', \(now.addingTimeInterval(-8 * 86_400)))")
        try await store.rollup(since: now.addingTimeInterval(-7200), now: now)
        let oldRuns = try await db.scalar("SELECT count(*) FROM sys.job_run WHERE job = 'old'", as: Int64.self)
        XCTAssertEqual(oldRuns, 0)
        let hourly = try await db.scalar("SELECT sum(samples)::int8 FROM mon.server_hourly WHERE hour >= \(now.addingTimeInterval(-10800))", as: Int64.self)
        XCTAssertEqual(hourly, 32)
        let siteHourly = try await db.scalar("SELECT sum(total)::int8 FROM mon.site_hourly", as: Int64.self)
        XCTAssertEqual(siteHourly, 32)

        try await store.setValue("{\"a\":1}", for: "alerts")
        let kv = try await store.value("alerts")
        XCTAssertEqual(kv, "{\"a\":1}")
        try await store.setValue(nil, for: "alerts")
        let gone = try await store.value("alerts")
        XCTAssertNil(gone)
        try await store.setDomain("example.org", DomainExpiry.Entry(expiry: now.addingTimeInterval(86_400 * 40), checkedAt: now))
        let domains = try await store.domains()
        XCTAssertNotNil(domains["example.org"]?.expiry)

        // Expired partitions go, recent ones stay.
        let oldDay = Partitions.start(of: now.addingTimeInterval(-40 * 86_400), step: .day)
        let oldName = Partitions.partitionName("mon.server_sample", start: oldDay, step: .day)
        try await db.query(PostgresQuery(unsafeSQL: """
            CREATE TABLE \(oldName) PARTITION OF mon.server_sample
            FOR VALUES FROM ('\(Partitions.iso(oldDay))') TO ('\(Partitions.iso(Partitions.next(oldDay, step: .day)))')
            """))
        let changed = try await Partitions.ensure(db, now: now)
        XCTAssertTrue(changed.contains("dropped \(oldName)"), "\(changed)")
        XCTAssertFalse(changed.contains { $0.hasPrefix("dropped") && $0.hasSuffix(Partitions.partitionName("server_sample", start: Partitions.start(of: now, step: .day), step: .day)) })
        // Yesterday exists for the agents' 24 hours of history.
        let yesterday = Partitions.partitionName("mon.server_sample", start: Partitions.start(of: now.addingTimeInterval(-86_400), step: .day), step: .day)
        let exists = try await db.scalar("SELECT to_regclass(\(yesterday)) IS NOT NULL", as: Bool.self)
        XCTAssertEqual(exists, true)

        // A real agent, over pinned TLS, and a whole poller round.
        guard env["HUB_TEST_AGENT"] != nil else { return }
        let client = AgentClient(transport: PinnedNIOTransport())
        let live = try await client.snapshot(inv.servers[0])
        XCTAssertFalse(live.hostname.isEmpty)
        var wrong = inv.servers[0]
        wrong.fingerprint = String(repeating: "00", count: 32)
        do {
            _ = try await client.snapshot(wrong)
            XCTFail("a certificate with another fingerprint must be refused")
        } catch {}

        let poller = Poller(client: client, store: store, onUpdate: { _ in }, onEvents: { _ in })
        await poller.setSetsAgentInterval(false)
        await poller.setServers(inv.servers)
        await poller.setSites(inv.sites)
        await poller.pollAll(now: Date())
        let polled = try await db.scalar("SELECT count(*) FROM mon.poll WHERE ok AND probe_id = \(probes.hub)", as: Int64.self)
        XCTAssertGreaterThanOrEqual(polled ?? 0, 2)
        let health = await poller.currentHealth()
        XCTAssertNil(health.storeError)
        XCTAssertFalse(health.macOffline)
    }
}
