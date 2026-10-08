import Foundation

/// Alert thresholds. Every field is optional so a server can override just
/// one of them in servers.json; `resolved` fills in the defaults.
public struct Thresholds: Codable, Equatable, Sendable {
    public var diskPercent: Double?
    public var cpuPercent: Double?
    /// CPU must stay above `cpuPercent` for this many minutes (polls).
    public var cpuMinutes: Int?
    public var memoryPercent: Double?
    /// Warn when a TLS certificate expires within this many days.
    public var tlsDays: Int?
    /// Warn when a domain registration expires within this many days.
    public var domainDays: Int?

    public init(diskPercent: Double? = nil, cpuPercent: Double? = nil, cpuMinutes: Int? = nil,
                memoryPercent: Double? = nil, tlsDays: Int? = nil, domainDays: Int? = nil) {
        self.diskPercent = diskPercent; self.cpuPercent = cpuPercent; self.cpuMinutes = cpuMinutes
        self.memoryPercent = memoryPercent; self.tlsDays = tlsDays; self.domainDays = domainDays
    }

    public static let defaults = Thresholds(diskPercent: 90, cpuPercent: 90, cpuMinutes: 5,
                                            memoryPercent: 90, tlsDays: 14, domainDays: 14)

    /// `self` with missing fields taken from `defaults`.
    public var resolved: Thresholds {
        let d = Thresholds.defaults
        return Thresholds(diskPercent: diskPercent ?? d.diskPercent, cpuPercent: cpuPercent ?? d.cpuPercent,
                          cpuMinutes: cpuMinutes ?? d.cpuMinutes, memoryPercent: memoryPercent ?? d.memoryPercent,
                          tlsDays: tlsDays ?? d.tlsDays, domainDays: domainDays ?? d.domainDays)
    }
}

public enum Severity: Int, Codable, Comparable, Sendable {
    case warning = 1
    case critical = 2

    public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

    public var label: String { self == .critical ? "критично" : "предупреждение" }
}

/// One problem seen in a single poll, e.g. "disk is 93% full".
public struct Condition: Codable, Equatable, Sendable {
    /// Stable identity across polls, e.g. "disk" or "svc:nginx".
    public var key: String
    public var severity: Severity
    public var message: String
    /// Consecutive bad polls before notifying.
    public var after: Int

    public init(key: String, severity: Severity, message: String, after: Int = 2) {
        self.key = key; self.severity = severity; self.message = message; self.after = after
    }

    /// How often a lasting problem is repeated. An outage is worth a sound
    /// every half hour; a full disk or a certificate running out is not,
    /// once a day is enough (the morning summary lists them too).
    public var remindEvery: TimeInterval { severity == .critical ? 30 * 60 : 24 * 3600 }
}

/// What a poll of one server produced.
public enum PollOutcome: Sendable {
    case snapshot(Snapshot)
    case failure(String)
}

public enum Rules {
    /// Server unreachable: 3 failed polls in a row before notifying.
    public static let downAfter = 3
    /// The agent answers but its newest sample has not changed for this long:
    /// its sampling hangs (Docker, a slow disk).
    public static let staleAfter: TimeInterval = 3 * 60

    /// `frozenSince`: when the Mac first got the same sample again.
    public static func stale(frozenSince: Date?, now: Date) -> Condition? {
        guard let since = frozenSince, now.timeIntervalSince(since) >= staleAfter else { return nil }
        let minutes = Int(now.timeIntervalSince(since) / 60)
        return Condition(key: "stale", severity: .warning,
                         message: "данные агента не обновляются \(minutes) мин: замеры на сервере зависли")
    }
    /// A disk, CPU or memory alert clears only this many points below its
    /// threshold, so a value hovering at the limit does not ring every minute.
    public static let hysteresis: Double = 5

    /// `active`: keys of the alerts already raised for this server.
    public static func conditions(_ outcome: PollOutcome, thresholds: Thresholds?, active: Set<String> = [],
                                  now: Date) -> [Condition] {
        switch outcome {
        case .failure(let err):
            return [Condition(key: "down", severity: .critical, message: "агент не отвечает: \(err)", after: downAfter)]
        case .snapshot(let s):
            return conditions(s, thresholds: (thresholds ?? Thresholds()).resolved, active: active, now: now)
        }
    }

    static func conditions(_ s: Snapshot, thresholds t: Thresholds, active: Set<String> = [],
                           now: Date) -> [Condition] {
        var out: [Condition] = []
        func pct(_ v: Double) -> String { String(format: "%.0f%%", v) }
        /// The threshold, lowered while the alert is on.
        func limit(_ value: Double, _ key: String) -> Double { active.contains(key) ? value - hysteresis : value }

        if let base = t.diskPercent {
            for d in s.disks ?? [] where d.usedPercent > limit(base, "disk:\(d.mount)") {
                out.append(Condition(key: "disk:\(d.mount)", severity: .warning,
                                     message: "диск \(d.mount) заполнен на \(pct(d.usedPercent))"))
            }
        }
        if let base = t.cpuPercent, s.cpu.usagePercent > limit(base, "cpu") {
            out.append(Condition(key: "cpu", severity: .warning,
                                 message: "CPU \(pct(s.cpu.usagePercent)) дольше \(t.cpuMinutes ?? 5) мин",
                                 after: max(t.cpuMinutes ?? 5, 1)))
        }
        if let base = t.memoryPercent, s.memory.usedPercent > limit(base, "mem") {
            out.append(Condition(key: "mem", severity: .warning,
                                 message: "память занята на \(pct(s.memory.usedPercent))"))
        }
        for v in s.vpn ?? [] where !v.running {
            out.append(Condition(key: "vpn:\(v.container)", severity: .critical,
                                 message: "VPN \(v.container) остановлен"))
        }
        for svc in s.services ?? [] {
            if !svc.processRunning {
                out.append(Condition(key: "svc:\(svc.name)", severity: .critical,
                                     message: "сервис \(svc.name) не запущен"))
            } else if let port = svc.port, !svc.portOpen {
                out.append(Condition(key: "svc:\(svc.name)", severity: .critical,
                                     message: "сервис \(svc.name) не принимает подключения на порту \(port)"))
            }
        }
        for c in s.containers ?? [] where c.health == "unhealthy" {
            out.append(Condition(key: "ctr:\(c.name)", severity: .warning,
                                 message: "контейнер \(c.name) нездоров"))
        }
        // Sites the app manages are judged across all countries by SiteRules;
        // links between our servers are shown on the map, not alerted on the source.
        for c in s.checks ?? [] where !c.id.hasPrefix(SiteConfig.checkPrefix)
            && !c.id.hasPrefix(ServerConfig.peerCheckPrefix) {
            if !c.ok {
                out.append(Condition(key: "check:\(c.id)", severity: .critical,
                                     message: "\(c.target) недоступен: \(c.error ?? "HTTP \(c.statusCode ?? 0)")"))
            }
            if let exp = c.tlsExpiry, let days = t.tlsDays,
               exp.timeIntervalSince(now) < Double(days) * 86400 {
                let left = Int(exp.timeIntervalSince(now) / 86400)
                out.append(Condition(key: "tls:\(c.id)", severity: .warning,
                                     message: left < 0 ? "SSL \(c.target) истёк"
                                                       : "SSL \(c.target) истекает через \(left) дн."))
            }
        }
        return out
    }
}

public struct AlertEvent: Equatable, Sendable {
    /// `info` is a server's history (a reboot, a container stopping), logged
    /// without a notification; the rest come from the alert rules.
    public enum Kind: String, Codable, Sendable { case fired, reminder, resolved, info }

    public var serverID: String
    public var serverName: String
    public var key: String
    public var kind: Kind
    public var severity: Severity
    public var message: String
    public var time: Date

    public init(serverID: String, serverName: String, key: String, kind: Kind, severity: Severity,
                message: String, time: Date) {
        self.serverID = serverID
        self.serverName = serverName
        self.key = key
        self.kind = kind
        self.severity = severity
        self.message = message
        self.time = time
    }

    /// Notification title, e.g. "🔴 Нидерланды VPN".
    public var title: String {
        switch kind {
        case .resolved: return "✅ \(serverName)"
        case .info: return serverName
        case .fired, .reminder: return "\(severity == .critical ? "🔴" : "🟡") \(serverName)"
        }
    }

    public var body: String {
        switch kind {
        case .fired, .info: return message
        case .reminder: return "всё ещё: \(message)"
        case .resolved: return "снова в норме: \(message)"
        }
    }
}

/// An alert that is currently notified (passed its consecutive-poll gate).
public struct ActiveAlert: Equatable, Sendable {
    public var key: String
    public var severity: Severity
    public var message: String
    public var since: Date
}

/// Turns per-poll conditions into notifications with the anti-spam rules:
/// notify only after N bad polls in a row, remind while it lasts (every half
/// hour for outages, daily for warnings), send one "back to normal" when it
/// clears for `clearAfter` polls.
public struct AlertEngine: Sendable {
    /// Good polls in a row before an active alert is resolved (avoids flapping).
    public var clearAfter = 2

    struct State: Codable, Sendable {
        var condition: Condition
        var bad = 0
        var good = 0
        var firedAt: Date?
        var lastNotified: Date?
    }

    /// serverID -> key -> state
    private var states: [String: [String: State]] = [:]

    public init() {}

    /// `extra`: conditions the poller sees across polls, such as stale data.
    public mutating func process(server: ServerConfig, outcome: PollOutcome, extra: [Condition] = [],
                                 now: Date) -> [AlertEvent] {
        let reachable: Bool
        if case .snapshot = outcome { reachable = true } else { reachable = false }
        let active = Set((states[server.id] ?? [:]).filter { $0.value.firedAt != nil }.keys)
        return process(id: server.id, name: server.name,
                       conditions: Rules.conditions(outcome, thresholds: server.thresholds, active: active, now: now)
                           + extra,
                       reachable: reachable, now: now)
    }

    /// The anti-spam state machine for any monitored object (a server, or a
    /// site as `site:<id>`). With `reachable` false only "down" may change;
    /// everything else keeps its state until the object is seen again.
    public mutating func process(id: String, name: String, conditions current: [Condition],
                                 reachable: Bool, now: Date) -> [AlertEvent] {
        var byKey = states[id] ?? [:]
        var events: [AlertEvent] = []
        func event(_ kind: AlertEvent.Kind, _ c: Condition) {
            events.append(AlertEvent(serverID: id, serverName: name, key: c.key, kind: kind,
                                     severity: c.severity, message: c.message, time: now))
        }

        for c in current {
            var st = byKey[c.key] ?? State(condition: c)
            st.condition = c
            st.bad += 1
            st.good = 0
            if st.firedAt == nil, st.bad >= c.after {
                st.firedAt = now
                st.lastNotified = now
                event(.fired, c)
            } else if st.firedAt != nil, let last = st.lastNotified,
                      now.timeIntervalSince(last) >= c.remindEvery {
                st.lastNotified = now
                event(.reminder, c)
            }
            byKey[c.key] = st
        }

        let seen = Set(current.map(\.key))
        for (key, var st) in byKey where !seen.contains(key) {
            // While the server is unreachable we know nothing about its disks
            // or services: keep their state as is.
            if !reachable && key != "down" { continue }
            st.bad = 0
            st.good += 1
            let needed = key == "down" ? 1 : clearAfter
            if st.firedAt == nil {
                byKey[key] = nil
            } else if st.good >= needed {
                event(.resolved, st.condition)
                byKey[key] = nil
            } else {
                byKey[key] = st
            }
        }
        states[id] = byKey
        return events
    }

    public func active(_ serverID: String) -> [ActiveAlert] {
        (states[serverID] ?? [:]).values.compactMap { st in
            st.firedAt.map { ActiveAlert(key: st.condition.key, severity: st.condition.severity,
                                         message: st.condition.message, since: $0) }
        }.sorted { ($0.severity, $1.since) > ($1.severity, $0.since) }
    }

    /// Forget servers that were removed from the config.
    public mutating func retain(serverIDs: Set<String>) {
        states = states.filter { serverIDs.contains($0.key) }
    }

    /// The whole state, saved after each round so a restart of the app does
    /// not announce every ongoing problem again as new.
    public func saved() -> Data? { try? JSONEncoder().encode(states) }

    public mutating func restore(_ data: Data) {
        if let s = try? JSONDecoder().decode([String: [String: State]].self, from: data) { states = s }
    }
}
