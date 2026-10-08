import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Overall state of one server for the menu bar and dashboard.
public struct ServerStatus: Equatable, Identifiable, Sendable {
    public enum Level: Int, Comparable, Sendable {
        case unknown = 0, ok, warning, critical
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    public var id: String { server.id }
    public var server: ServerConfig
    public var snapshot: Snapshot?
    /// Last successful poll.
    public var lastSeen: Date?
    /// Error of the last poll, nil when it succeeded.
    public var error: String?
    public var alerts: [ActiveAlert]

    public var level: Level {
        if let worst = alerts.map(\.severity).max() { return worst == .critical ? .critical : .warning }
        if lastSeen == nil { return .unknown }
        return .ok
    }
}

/// Whether the Mac itself manages to poll. While it does not, the screens
/// must not present the last known state as current.
public struct PollerHealth: Equatable, Sendable {
    /// The last full round that reached the agents and saved its data.
    public var lastGoodRound: Date?
    /// No agent answered: the Mac has no network (or has just woken up).
    public var macOffline = false
    /// The database could not be written in the last round.
    public var storeError: String?

    public init(lastGoodRound: Date? = nil, macOffline: Bool = false, storeError: String? = nil) {
        self.lastGoodRound = lastGoodRound; self.macOffline = macOffline; self.storeError = storeError
    }

    /// What is wrong with the monitoring itself, nil when it works.
    public var problem: String? {
        if let storeError { return "не удаётся записать данные: \(storeError)" }
        if macOffline { return "ни один сервер не отвечает Маку, похоже, нет сети" }
        return nil
    }
}

/// Polls every agent once a minute: pulls the history missed since the last
/// stored sample (up to the agent's 24 h buffer), stores it, evaluates alert
/// rules on the fresh snapshot and reports notifications. With a shorter
/// refresh interval it also fetches just the current snapshot in between, so
/// the screens update faster while alerts and history stay per minute.
public actor Poller {
    /// The full round: history, database, alerts.
    public static let interval: TimeInterval = 60
    /// Refresh intervals offered in Settings; agents sample at the same rate.
    public static let refreshChoices: [TimeInterval] = [10, 15, 30, 60]
    /// UserDefaults key of the chosen refresh interval.
    public static let refreshDefaultsKey = "refreshInterval"
    /// How far back to backfill a server seen for the first time.
    public static let firstBackfill: TimeInterval = 24 * 3600

    private let client: AgentClient
    private let store: Store
    private var servers: [ServerConfig] = []
    private var engine = AlertEngine()
    private var statuses: [String: ServerStatus] = [:]
    private var task: Task<Void, Never>?
    private var refresh: TimeInterval = Poller.interval
    /// Servers asked to reboot from the app, with when.
    private var rebooting: [String: Date] = [:]
    /// When each unreachable server first stopped answering.
    private var failingSince: [String: Date] = [:]
    private var macOffline = false
    /// How long a reboot may take before it counts as a plain outage.
    public static let rebootGrace: TimeInterval = 10 * 60
    private var lastFullRound: Date?

    private var sites: [SiteConfig] = []
    private var siteStatuses: [String: SiteStatus] = [:]
    /// Check targets each agent last accepted, so they are pushed only on change.
    private var pushedTargets: [String: [CheckTarget]] = [:]
    private let domains: DomainExpiry
    private var domainsLoaded = false
    private var onSites: (@Sendable ([SiteStatus]) -> Void)?
    private var onHealth: (@Sendable (PollerHealth) -> Void)?
    private var health = PollerHealth()
    /// The full round in progress; another caller waits for it to finish.
    private var round: Task<Void, Never>?
    /// Alerts in progress and the last good round, read back from the database once.
    private var restored = false
    static let alertsKey = "alerts"
    static let lastRoundKey = "lastGoodRound"

    private let onUpdate: @Sendable ([ServerStatus]) -> Void
    private let onEvents: @Sendable ([AlertEvent]) -> Void

    public init(client: AgentClient, store: Store,
                domainLookup: DomainLookupTransport = NetworkDomainLookup(),
                onUpdate: @escaping @Sendable ([ServerStatus]) -> Void,
                onEvents: @escaping @Sendable ([AlertEvent]) -> Void) {
        self.client = client
        self.store = store
        self.domains = DomainExpiry(transport: domainLookup)
        self.onUpdate = onUpdate
        self.onEvents = onEvents
    }

    /// Receives every site's status after each round.
    public func setSitesHandler(_ handler: @escaping @Sendable ([SiteStatus]) -> Void) {
        onSites = handler
        handler(orderedSites())
    }

    /// Receives the state of the monitoring itself after each full round.
    public func setHealthHandler(_ handler: @escaping @Sendable (PollerHealth) -> Void) {
        onHealth = handler
        handler(health)
    }

    public func currentHealth() -> PollerHealth { health }

    /// Replaces the site list. The agents get the new check targets on the next round.
    public func setSites(_ list: [SiteConfig]) {
        let ids = Set(list.map(\.id))
        siteStatuses = siteStatuses.filter { ids.contains($0.key) }
        sites = list
        engine.retain(serverIDs: Set(servers.map(\.id)).union(list.map { SiteStatus.alertID($0.id) }))
        publishSites()
    }

    /// Convenience for servers.json: servers and sites together.
    public func setConfig(_ file: ServersFile) async {
        await setServers(file.servers)
        setSites(file.sites ?? [])
    }

    /// Replaces the server list; data of removed servers is dropped.
    public func setServers(_ list: [ServerConfig]) async {
        let ids = Set(list.map(\.id))
        for old in servers where !ids.contains(old.id) {
            try? await store.forget(serverID: old.id)
            statuses[old.id] = nil
            rebooting[old.id] = nil
            failingSince[old.id] = nil
        }
        engine.retain(serverIDs: ids.union(sites.map { SiteStatus.alertID($0.id) }))
        pushedTargets = pushedTargets.filter { ids.contains($0.key) }
        servers = list
        for s in list {
            var st: ServerStatus
            if let known = statuses[s.id] {
                st = known
            } else {
                st = ServerStatus(server: s, alerts: [])
                st.snapshot = try? await store.latest(s.id)
            }
            st.server = s
            statuses[s.id] = st
        }
        publish()
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let pause = await self?.tick(now: Date()) else { return }
                try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
            }
        }
    }

    /// How often the screens refresh (and agents sample), clamped to the
    /// offered range. A running loop restarts so the change applies at once.
    public func setRefreshInterval(_ seconds: TimeInterval) {
        let clamped = min(max(seconds, Poller.refreshChoices.min()!), Poller.interval)
        guard clamped != refresh else { return }
        refresh = clamped
        if task != nil {
            stop()
            start()
        }
    }

    /// A full round once a minute, a snapshot-only round in between; returns
    /// the pause before the next tick.
    func tick(now: Date) async -> TimeInterval {
        if let last = lastFullRound, now.timeIntervalSince(last) < Poller.interval - 1 {
            await refreshLive(now: now)
        } else {
            await pollAll(now: now)
        }
        return refresh
    }

    /// Fetches only the current snapshot of every server and redraws. Nothing
    /// is stored and no alert fires here; a server that stops answering turns
    /// orange at once and red when the full round's "down" alert fires.
    public func refreshLive(now: Date) async {
        let list = servers
        let results = await withTaskGroup(of: (String, Result<Snapshot, Error>).self) { group in
            for s in list {
                group.addTask { [client] in
                    do { return (s.id, .success(try await client.snapshot(s))) } catch { return (s.id, .failure(error)) }
                }
            }
            var out: [String: Result<Snapshot, Error>] = [:]
            for await (id, r) in group { out[id] = r }
            return out
        }
        for (id, r) in results {
            guard var st = statuses[id] else { continue }
            switch r {
            case .success(let snap):
                st.snapshot = snap
                st.lastSeen = now
                st.error = nil
            case .failure(let error):
                st.error = Poller.describe(error)
            }
            statuses[id] = st
            track(id, now: now)
        }
        let fresh = Set(statuses.filter { $0.value.error == nil && $0.value.snapshot != nil }.keys)
        _ = await evaluateSites(fresh: fresh, macOffline: false, alerts: false, now: now)
        publish()
        publishSites()
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// The server was told to reboot: show it as rebooting, not as fine or
    /// down, until it answers with a newer boot time or the grace runs out.
    public func markRebooting(_ serverID: String, now: Date = Date()) {
        rebooting[serverID] = now
        if var st = statuses[serverID] {
            st.alerts = alerts(for: st, now: now)
            statuses[serverID] = st
        }
        publish()
    }

    /// Updates the failure and reboot bookkeeping for one server after a poll
    /// and recomputes the alerts it shows.
    private func track(_ id: String, now: Date) {
        guard var st = statuses[id] else { return }
        if st.error == nil {
            failingSince[id] = nil
        } else if failingSince[id] == nil {
            failingSince[id] = now
        }
        if let since = rebooting[id] {
            let rebooted = st.error == nil && (st.snapshot?.bootTime ?? .distantPast) > since.addingTimeInterval(-60)
            if rebooted || now.timeIntervalSince(since) > Poller.rebootGrace { rebooting[id] = nil }
        }
        st.alerts = alerts(for: st, now: now)
        statuses[id] = st
    }

    /// The engine's alerts plus what the screens must show before any alert
    /// fires: a server that does not answer is never "в норме".
    private func alerts(for st: ServerStatus, now: Date) -> [ActiveAlert] {
        var list = engine.active(st.id)
        if let since = rebooting[st.id] {
            list.append(ActiveAlert(key: "rebooting", severity: .warning, message: "перезагружается", since: since))
        } else if let err = st.error, !macOffline, !list.contains(where: { $0.key == "down" }) {
            list.append(ActiveAlert(key: "noreply", severity: .warning, message: "нет ответа: \(err)",
                                    since: failingSince[st.id] ?? now))
        }
        return list
    }

    /// What one agent probes: the sites it checks, and every other server's
    /// agent port, so the map shows who reaches whom.
    static func targets(for s: ServerConfig, servers: [ServerConfig], sites: [SiteConfig]) -> [CheckTarget] {
        sites.filter { $0.checked(from: s) }.map { CheckTarget.http($0.checkID, url: $0.url, auth: $0.basicAuth) }
            + servers.filter { $0.id != s.id && $0.host != s.host }
                .map { CheckTarget.tcp($0.peerCheckID, host: $0.host, port: $0.port) }
    }

    /// One round over all servers, in parallel. Rounds never overlap: a call
    /// made while one runs (a button, a config change, waking up) waits for it
    /// and then runs its own, so it sees the latest settings.
    public func pollAll(now: Date) async {
        while let running = round { await running.value }
        let task = Task { await self.runRound(now: now) }
        round = task
        await task.value
        round = nil
    }

    /// Reads back what the previous run of the app left: alerts in progress
    /// are not announced again as new, and the pause can be summed up.
    private func restore() async {
        // The first rounds can run before the config is loaded: wait for it,
        // or the saved alerts would be dropped as belonging to no server.
        guard !restored, !servers.isEmpty || !sites.isEmpty else { return }
        restored = true
        if let saved = try? await store.value(Poller.alertsKey) { engine.restore(Data(saved.utf8)) }
        engine.retain(serverIDs: Set(servers.map(\.id)).union(sites.map { SiteStatus.alertID($0.id) }))
        if let saved = try? await store.value(Poller.lastRoundKey), let t = Double(saved) {
            health.lastGoodRound = Date(timeIntervalSince1970: t)
        }
    }

    private func runRound(now: Date) async {
        await restore()
        lastFullRound = now
        let list = servers
        let wantInterval = Int(refresh)
        let wanted = Dictionary(uniqueKeysWithValues: list.map { s in
            (s.id, Poller.targets(for: s, servers: list, sites: sites))
        })
        let results = await withTaskGroup(of: (ServerConfig, PollResult).self) { group in
            for s in list {
                // A site whose password is sealed while the app is locked
                // would reach the agent without it; keep the agent's list.
                let held = sites.contains { $0.authLocked && $0.checked(from: s) }
                let push = held || pushedTargets[s.id] == wanted[s.id] ? nil : wanted[s.id]
                group.addTask { [client, store] in
                    (s, await Poller.poll(s, client: client, store: store, push: push,
                                          interval: wantInterval, now: now))
                }
            }
            var out: [(ServerConfig, PollResult)] = []
            for await r in group { out.append(r) }
            return out
        }

        // Every agent failing at once means the Mac itself is offline (or just
        // woke up): don't count it against the servers or raise alerts.
        let macOffline = !results.isEmpty && results.allSatisfy { $0.1.snapshot == nil }
            && (results.count >= 2 || results.allSatisfy { $0.1.offline })
        self.macOffline = macOffline
        var storeError = results.compactMap(\.1.storeError).first
        func failed(_ error: Error) { if storeError == nil { storeError = Poller.describe(error) } }

        var events: [AlertEvent] = []
        for (s, r) in results {
            if let pushed = r.pushed { pushedTargets[s.id] = pushed }
            if !macOffline {
                do { try await store.addPoll(s.id, at: now, ok: r.snapshot != nil, error: r.error) } catch { failed(error) }
            }
            let outcome: PollOutcome = r.snapshot.map { .snapshot($0) } ?? .failure(r.error ?? "нет ответа")
            // A server rebooting on request is expected to be silent for a while.
            let expectedSilence = r.snapshot == nil && rebooting[s.id] != nil
            if !macOffline && !expectedSilence {
                let ev = engine.process(server: s, outcome: outcome, now: now)
                events += ev
                for e in ev { try? await store.addEvent(e) }
            }

            var st = statuses[s.id] ?? ServerStatus(server: s, alerts: [])
            if let snap = r.snapshot {
                st.snapshot = snap
                st.lastSeen = now
            }
            st.error = r.error
            statuses[s.id] = st
            track(s.id, now: now)
        }
        // Backfilled history can reach back hours: roll up from its oldest sample.
        let oldest = results.compactMap(\.1.oldestNew).min() ?? now
        try? await store.rollup(since: min(oldest, now.addingTimeInterval(-2 * 3600)), now: now)
        events += await evaluateSites(fresh: Set(results.filter { $0.1.snapshot != nil }.map(\.0.id)),
                                      macOffline: macOffline, now: now)

        if !macOffline && restored {
            if let away = await summarizePause(results, now: now) { events.append(away) }
            if let data = engine.saved() {
                do { try await store.setValue(String(decoding: data, as: UTF8.self), for: Poller.alertsKey) } catch { failed(error) }
            }
            if storeError == nil {
                health.lastGoodRound = now
                try? await store.setValue(String(now.timeIntervalSince1970), for: Poller.lastRoundKey)
            }
        }
        health.macOffline = macOffline
        health.storeError = storeError
        onHealth?(health)

        publish()
        publishSites()
        if !events.isEmpty { onEvents(events) }
        await refreshDomains(now: now)
    }

    /// After a pause of `AwaySummary.minimumGap` or more (the Mac slept, was
    /// off or offline), one journal entry about what happened meanwhile; it
    /// is returned for a notification only when something did.
    private func summarizePause(_ results: [(ServerConfig, PollResult)], now: Date) async -> AlertEvent? {
        guard let last = health.lastGoodRound, now.timeIntervalSince(last) >= AwaySummary.minimumGap else { return nil }
        let seen = results.filter { $0.1.snapshot != nil }.map {
            AwaySummary.Seen(server: $0.0, before: $0.1.before, samples: $0.1.samples)
        }
        let lines = AwaySummary.lines(from: last, seen: seen, sites: sites)
        let event = AwaySummary.event(from: last, to: now, lines: lines)
        try? await store.addEvent(event)
        return lines.isEmpty ? nil : event
    }

    /// Builds each site's status from the agents that answered this round and,
    /// when `alerts` is set, runs the site alert rules.
    private func evaluateSites(fresh: Set<String>, macOffline: Bool, alerts: Bool = true,
                               now: Date) async -> [AlertEvent] {
        var events: [AlertEvent] = []
        for site in sites {
            let origins = servers.filter { site.checked(from: $0) }.map { s in
                SiteStatus.Origin(serverID: s.id, serverName: s.name,
                                  check: fresh.contains(s.id)
                                      ? statuses[s.id]?.snapshot?.checks?.first { $0.id == site.checkID } : nil)
            }
            let domain = site.host.flatMap(DomainName.registrable)
            let entry = await domain.asyncFlatMap { await domains.entry($0) }
            var st = SiteStatus(site: site, origins: origins, domain: domain, domainExpiry: entry?.expiry,
                                domainError: entry?.error, alerts: [])
            let alertID = SiteStatus.alertID(site.id)
            if alerts && !macOffline {
                let ev = engine.process(id: alertID, name: site.name, conditions: SiteRules.conditions(st, now: now),
                                        reachable: true, now: now)
                for e in ev { try? await store.addEvent(e) }
                events += ev
            }
            st.alerts = engine.active(alertID)
            siteStatuses[site.id] = st
        }
        return events
    }

    /// Looks up stale domain expiry dates in the background.
    private func refreshDomains(now: Date) async {
        if !domainsLoaded {
            domainsLoaded = true
            for (d, e) in (try? await store.domains()) ?? [:] { await domains.restore(d, e) }
        }
        let wanted = Set(sites.compactMap { $0.host.flatMap(DomainName.registrable) })
        for d in await domains.due(wanted, now: now) {
            Task { [domains, store] in
                let entry = await domains.lookup(d, now: now)
                try? await store.setDomain(d, entry)
            }
        }
    }

    public func currentSites() -> [SiteStatus] { orderedSites() }

    private func orderedSites() -> [SiteStatus] {
        sites.map { siteStatuses[$0.id] ?? SiteStatus(site: $0, origins: [], alerts: []) }
    }

    private func publishSites() { onSites?(orderedSites()) }

    public func current() -> [ServerStatus] { ordered() }

    private func ordered() -> [ServerStatus] { servers.compactMap { statuses[$0.id] } }

    private func publish() { onUpdate(ordered()) }

    struct PollResult: Sendable {
        var snapshot: Snapshot?
        var error: String?
        /// The Mac has no network connection.
        var offline = false
        /// Oldest sample stored by this poll.
        var oldestNew: Date?
        /// Check targets the agent accepted in this poll.
        var pushed: [CheckTarget]?
        /// The agent answered, but saving its data failed.
        var storeError: String?
        /// The last snapshot stored before this poll, and the ones it brought.
        var before: Snapshot?
        var samples: [Snapshot] = []
    }

    static func poll(_ s: ServerConfig, client: AgentClient, store: Store, push: [CheckTarget]? = nil,
                     interval: Int? = nil, now: Date) async -> PollResult {
        // First everything from the agent, then the database: a database
        // that cannot be written must not make a healthy server look down.
        let history: [Snapshot]
        let snap: Snapshot
        var pushed: [CheckTarget]?
        do {
            let since = (try? await store.lastSampleTime(s.id)) ?? now.addingTimeInterval(-firstBackfill)
            history = try await client.history(s, since: since)
            // A failed push is retried next round; it must not hide the server's metrics.
            if let push {
                if (try? await client.setChecks(s, targets: push)) != nil {
                    pushed = push
                } else if push.contains(where: { $0.basicAuth != nil }) {
                    // Agents before site logins reject the whole list; check
                    // those sites without the login until the agent is updated.
                    let plain = push.map { var t = $0; t.basicAuth = nil; return t }
                    if (try? await client.setChecks(s, targets: plain)) != nil { pushed = plain }
                }
            }
            snap = try await client.snapshot(s)
        } catch {
            let offline = (error as? URLError)?.code == .notConnectedToInternet
            return PollResult(snapshot: nil, error: describe(error), offline: offline)
        }

        var storeError: String?
        do {
            try await store.addSamples(s.id, history)
            try await store.addSiteSamples(serverID: s.id, history)
            try await store.addLinkSamples(serverID: s.id, history)
        } catch {
            storeError = describe(error)
        }
        // Reboots and container changes since the last round, including
        // those inside the backfilled history.
        let previous = (try? await store.latest(s.id)) ?? nil
        for e in ServerEvents.changes(serverID: s.id, serverName: s.name, previous: previous,
                                      snapshots: history + [snap]) {
            // A container stuck restarting would flood the log: a few
            // entries an hour per container are enough to see it.
            let recent = (try? await store.eventCount(s.id, key: e.key, since: e.time.addingTimeInterval(-3600))) ?? 0
            if recent < ServerEvents.maxPerHour { try? await store.addEvent(e) }
        }
        do { try await store.setLatest(s.id, snap) } catch { storeError = storeError ?? describe(error) }
        try? await store.addVPNTraffic(s.id, snap)
        // Older agents report no interval and have no settings to change.
        if let interval, let current = snap.intervalS, current != interval {
            try? await client.setInterval(s, seconds: interval)
        }
        // The snapshot is usually the newest history sample again.
        let samples = history.last.map { $0.time >= snap.time } == true ? history : history + [snap]
        return PollResult(snapshot: snap, error: nil, oldestNew: history.first?.time, pushed: pushed,
                          storeError: storeError, before: previous, samples: samples)
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? AgentError { return e.description }
        if let e = error as? URLError {
            switch e.code {
            case .cancelled: return "сертификат агента не совпадает с сохранённым отпечатком"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
                return "не удалось установить TLS-соединение с агентом"
            case .timedOut: return "таймаут"
            case .cannotConnectToHost: return "порт закрыт или агент не запущен"
            case .notConnectedToInternet: return "нет интернета"
            default: return e.localizedDescription
            }
        }
        return String(describing: error)
    }
}

extension Optional {
    func asyncFlatMap<U>(_ f: (Wrapped) async -> U?) async -> U? {
        guard let v = self else { return nil }
        return await f(v)
    }
}

extension SiteStatus {
    public init(site: SiteConfig, origins: [Origin], alerts: [ActiveAlert]) {
        self.init(site: site, origins: origins, domain: site.host.flatMap(DomainName.registrable),
                  domainExpiry: nil, domainError: nil, alerts: alerts)
    }
}

extension ServerStatus {
    public init(server: ServerConfig, alerts: [ActiveAlert]) {
        self.init(server: server, snapshot: nil, lastSeen: nil, error: nil, alerts: alerts)
    }
}
