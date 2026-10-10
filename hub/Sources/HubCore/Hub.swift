import Foundation
import Logging
import MonitorCore
import PostgresNIO

/// The hub's main loop: the Mac app's Poller (rounds, alert rules, site
/// checks, domain expiry, backfill from the agents' history) on PostgreSQL,
/// plus the outside pulse and a record of every round in sys.job_run, so
/// "the hub is up but polling is stuck" is visible.
public actor Hub {
    let config: HubConfig
    let logger: Logger
    let db: Database
    var poller: Poller?
    var store: PostgresPollStore?
    var inventory = Inventory()
    var statuses: [ServerStatus] = []
    var siteStatuses: [SiteStatus] = []
    var health = PollerHealth()
    let heartbeat = HeartbeatSender()
    /// How often the server and site lists are re-read from the database.
    public static let reloadEvery: TimeInterval = 60

    public init(config: HubConfig, logger: Logger) {
        self.config = config
        self.logger = logger
        self.db = Database(config, logger: logger)
    }

    /// Runs until cancelled.
    public func run() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await self.db.run() }
            group.addTask { try await self.main() }
            try await group.next()
            group.cancelAll()
        }
    }

    /// Runs `body` with the database open and migrated (the `migrate` and
    /// `import` commands, and the installer).
    public func withDatabase<T: Sendable>(_ body: @Sendable (Database) async throws -> T) async throws -> T {
        let runner = Task { await db.run() }
        defer { runner.cancel() }
        let applied = try await Migrator.migrate(db, dir: config.migrationsDir)
        if !applied.isEmpty { logger.info("migrations applied: \(applied.joined(separator: ", "))") }
        try await Partitions.ensure(db, now: Date())
        return try await body(db)
    }

    func main() async throws {
        let applied = try await Migrator.migrate(db, dir: config.migrationsDir)
        if !applied.isEmpty { logger.info("migrations applied: \(applied.joined(separator: ", "))") }
        try await Partitions.ensure(db, now: Date())
        let box = try config.secretKey.map { try SecretBox(key: $0) }
        if box == nil { logger.warning("нет ключа шифрования: серверы с токенами не будут опрашиваться") }

        let store = PostgresPollStore(db: db)
        self.store = store
        let poller = Poller(
            client: AgentClient(transport: PinnedNIOTransport()), store: store,
            onUpdate: { list in Task { await self.received(list) } },
            onEvents: { events in Task { await self.log(events) } })
        // While the Mac still polls too, it decides how often agents sample.
        await poller.setSetsAgentInterval(false)
        await poller.setHealthHandler { h in Task { await self.received(h) } }
        await poller.setSitesHandler { list in Task { await self.received(list) } }
        self.poller = poller

        try await reload(box: box)
        await poller.start()
        logger.info("hub started: \(inventory.servers.count) servers, \(inventory.sites.count) sites")

        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: UInt64(Self.reloadEvery * 1_000_000_000))
            do { try await reload(box: box) } catch { logger.error("reload failed: \(HubError.describe(error))") }
            await pulse()
        }
        await poller.stop()
    }

    /// Re-reads servers and sites; the poller gets them only when they changed.
    func reload(box: SecretBox?) async throws {
        let probes = try await Inventory.probes(db, hubName: config.probeName)
        await store?.setProbes(hub: probes.hub, agents: probes.agents)
        let fresh = try await Inventory.load(db, box: box)
        await store?.setIDs(servers: fresh.serverIDs, sites: fresh.siteIDs)
        guard fresh != inventory else { return }
        for p in fresh.problems where !inventory.problems.contains(p) { logger.warning("\(p)") }
        if fresh.servers != inventory.servers { await poller?.setServers(fresh.servers) }
        if fresh.sites != inventory.sites { await poller?.setSites(fresh.sites) }
        inventory = fresh
    }

    func received(_ list: [ServerStatus]) { statuses = list }
    func received(_ list: [SiteStatus]) { siteStatuses = list }

    func received(_ h: PollerHealth) {
        let previous = health
        health = h
        guard h.lastGoodRound != previous.lastGoodRound || h.storeError != previous.storeError
            || h.macOffline != previous.macOffline else { return }
        let ok = h.storeError == nil && !h.macOffline
        let detail = """
            {"servers_ok":\(serverCounts.ok),"servers_total":\(serverCounts.total),\
            "sites_ok":\(siteCounts.ok),"sites_total":\(siteCounts.total),"offline":\(h.macOffline)}
            """
        let error = h.storeError ?? (h.macOffline ? "хаб не достучался ни до одного агента" : nil)
        let now = Date()
        Task {
            try? await db.query("""
                INSERT INTO sys.job_run (job, started_at, finished_at, ok, detail, error)
                VALUES ('poll_round', \(now), \(now), \(ok), \(detail)::jsonb, \(error))
                """)
        }
    }

    var serverCounts: (ok: Int, total: Int) {
        (statuses.filter { $0.alerts.isEmpty && $0.snapshot != nil }.count, statuses.count)
    }
    var siteCounts: (ok: Int, total: Int) { (siteStatuses.filter(\.alerts.isEmpty).count, siteStatuses.count) }

    func log(_ events: [AlertEvent]) {
        for e in events where e.kind != .info {
            logger.notice("\(e.kind.rawValue): \(e.serverName): \(e.message)")
        }
    }

    /// One ping a minute to healthchecks.io after a round that worked; a
    /// database error or an empty list is reported as a failure. No ping
    /// while the hub cannot reach any agent: the silence raises the alarm.
    func pulse() async {
        guard let url = config.heartbeatURL else { return }
        let request = Heartbeat.request(url, health: health, servers: serverCounts, sites: siteCounts)
        let state = await heartbeat.tick(request)
        if let e = state.error { logger.warning("пульс: \(e)") }
    }
}
