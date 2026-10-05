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

/// Polls every agent once a minute: pulls the history missed since the last
/// stored sample (up to the agent's 24 h buffer), stores it, evaluates alert
/// rules on the fresh snapshot and reports notifications.
public actor Poller {
    public static let interval: TimeInterval = 60
    /// How far back to backfill a server seen for the first time.
    public static let firstBackfill: TimeInterval = 24 * 3600

    private let client: AgentClient
    private let store: Store
    private var servers: [ServerConfig] = []
    private var engine = AlertEngine()
    private var statuses: [String: ServerStatus] = [:]
    private var task: Task<Void, Never>?

    private let onUpdate: @Sendable ([ServerStatus]) -> Void
    private let onEvents: @Sendable ([AlertEvent]) -> Void

    public init(client: AgentClient, store: Store,
                onUpdate: @escaping @Sendable ([ServerStatus]) -> Void,
                onEvents: @escaping @Sendable ([AlertEvent]) -> Void) {
        self.client = client
        self.store = store
        self.onUpdate = onUpdate
        self.onEvents = onEvents
    }

    /// Replaces the server list; data of removed servers is dropped.
    public func setServers(_ list: [ServerConfig]) async {
        let ids = Set(list.map(\.id))
        for old in servers where !ids.contains(old.id) {
            try? await store.forget(serverID: old.id)
            statuses[old.id] = nil
        }
        engine.retain(serverIDs: ids)
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
                await self?.pollAll(now: Date())
                try? await Task.sleep(nanoseconds: UInt64(Poller.interval * 1_000_000_000))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// One round over all servers, in parallel.
    public func pollAll(now: Date) async {
        let list = servers
        let results = await withTaskGroup(of: (ServerConfig, PollResult).self) { group in
            for s in list {
                group.addTask { [client, store] in (s, await Poller.poll(s, client: client, store: store, now: now)) }
            }
            var out: [(ServerConfig, PollResult)] = []
            for await r in group { out.append(r) }
            return out
        }

        // Every agent failing at once means the Mac itself is offline (or just
        // woke up): don't count it against the servers or raise alerts.
        let macOffline = !results.isEmpty && results.allSatisfy { $0.1.snapshot == nil }
            && (results.count >= 2 || results.allSatisfy { $0.1.offline })

        var events: [AlertEvent] = []
        for (s, r) in results {
            if !macOffline { try? await store.addPoll(s.id, at: now, ok: r.snapshot != nil, error: r.error) }
            let outcome: PollOutcome = r.snapshot.map { .snapshot($0) } ?? .failure(r.error ?? "нет ответа")
            if !macOffline {
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
            st.alerts = engine.active(s.id)
            statuses[s.id] = st
        }
        // Backfilled history can reach back hours: roll up from its oldest sample.
        let oldest = results.compactMap(\.1.oldestNew).min() ?? now
        try? await store.rollup(since: min(oldest, now.addingTimeInterval(-2 * 3600)), now: now)
        publish()
        if !events.isEmpty { onEvents(events) }
    }

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
    }

    static func poll(_ s: ServerConfig, client: AgentClient, store: Store, now: Date) async -> PollResult {
        do {
            let since = (try? await store.lastSampleTime(s.id)) ?? now.addingTimeInterval(-firstBackfill)
            let history = try await client.history(s, since: since)
            try await store.addSamples(s.id, history)
            let snap = try await client.snapshot(s)
            try await store.setLatest(s.id, snap)
            return PollResult(snapshot: snap, error: nil, oldestNew: history.first?.time)
        } catch {
            let offline = (error as? URLError)?.code == .notConnectedToInternet
            return PollResult(snapshot: nil, error: describe(error), offline: offline)
        }
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? AgentError { return e.description }
        if let e = error as? URLError {
            switch e.code {
            case .cancelled: return "сертификат агента не совпадает с сохранённым отпечатком"
            case .timedOut: return "таймаут"
            case .cannotConnectToHost: return "порт закрыт или агент не запущен"
            case .notConnectedToInternet: return "нет интернета"
            default: return e.localizedDescription
            }
        }
        return String(describing: error)
    }
}

extension ServerStatus {
    public init(server: ServerConfig, alerts: [ActiveAlert]) {
        self.init(server: server, snapshot: nil, lastSeen: nil, error: nil, alerts: alerts)
    }
}
