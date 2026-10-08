import Foundation

// Data behind the map's extra layers: traffic on the lines, whole paths
// through our servers, and the map as it was at a past moment.

/// Bytes per second from running counters (VPN peers, the Mac's
/// connections), fed one reading at a time.
public struct RateMeter: Sendable {
    public struct Rate: Equatable, Sendable {
        /// Received and sent by the side that owns the counter.
        public var rx: Double
        public var tx: Double
        public var total: Double { rx + tx }

        public init(rx: Double, tx: Double) { self.rx = rx; self.tx = tx }

        public static func + (a: Rate, b: Rate) -> Rate { Rate(rx: a.rx + b.rx, tx: a.tx + b.tx) }
    }

    private struct Reading: Sendable {
        var counter: ByteCounter
        var time: Date
    }

    private var last: [String: Reading] = [:]
    public private(set) var rates: [String: Rate] = [:]

    public init() {}

    /// The same reading twice (no new snapshot yet) changes nothing; a
    /// counter that went down (restart, new connection) gives no rate until
    /// the next reading.
    public mutating func add(_ key: String, _ counter: ByteCounter, at time: Date) {
        if let p = last[key] {
            let dt = time.timeIntervalSince(p.time)
            guard dt > 0 else { return }
            if counter.rx >= p.counter.rx, counter.tx >= p.counter.tx {
                rates[key] = Rate(rx: Double(counter.rx - p.counter.rx) / dt,
                                  tx: Double(counter.tx - p.counter.tx) / dt)
            } else {
                rates[key] = nil
            }
        }
        last[key] = Reading(counter: counter, time: time)
    }

    /// Drops counters no longer reported, so they do not grow forever.
    public mutating func keep(_ keys: Set<String>) {
        last = last.filter { keys.contains($0.key) }
        rates = rates.filter { keys.contains($0.key) }
    }

    public func rate(_ key: String) -> Rate? { rates[key] }

    /// Sum over the keys that have a rate; nil when none has.
    public func sum(_ keys: [String]) -> Rate? {
        let found = keys.compactMap { rates[$0] }
        return found.isEmpty ? nil : found.reduce(Rate(rx: 0, tx: 0), +)
    }

    /// Key of a VPN peer's counter on a server.
    public static func peerKey(server: String, publicKey: String) -> String { "peer|" + server + "|" + publicKey }

    /// Keys of a Mac link's connections ("1.2.3.4|gost|tcp 10.0.0.2.5000").
    public static func connectionKeys(_ l: MacLink) -> [String: ByteCounter] {
        var out: [String: ByteCounter] = [:]
        for (conn, c) in l.counters { out["mac|" + l.remoteIP + "|" + l.process + "|" + conn] = c }
        return out
    }

    /// Feeds every VPN peer of every server, at its snapshot's time, and
    /// returns the keys fed.
    @discardableResult
    public mutating func add(_ statuses: [ServerStatus]) -> Set<String> {
        var keys = Set<String>()
        for s in statuses {
            guard let snap = s.snapshot else { continue }
            for vpn in snap.vpn ?? [] {
                for p in vpn.peers ?? [] {
                    let k = Self.peerKey(server: s.server.id, publicKey: p.publicKey)
                    add(k, ByteCounter(rx: p.rxBytes, tx: p.txBytes), at: snap.time)
                    keys.insert(k)
                }
            }
        }
        return keys
    }
}

/// A path traffic takes through our servers: from this Mac (its first node
/// is then the Mac's pin id) or from the first server of a cascade.
public struct NetworkChain: Equatable, Identifiable, Sendable {
    public var nodes: [String]
    /// Every hop has live traffic now.
    public var active: Bool
    public var id: String { nodes.joined(separator: ">") }

    public init(nodes: [String], active: Bool) { self.nodes = nodes; self.active = active }

    /// The hop `from` -> `to` is part of this path.
    public func contains(from: String, to: String) -> Bool {
        zip(nodes, nodes.dropFirst()).contains { $0 == from && $1 == to }
    }

    public var hops: [(from: String, to: String)] { zip(nodes, nodes.dropFirst()).map { ($0, $1) } }
}

public enum NetworkChains {
    /// Whole paths: each of the Mac's routes, continued along cascades
    /// between servers, plus cascades that start on a server. A path that is
    /// only the start of a longer one is left out.
    public static func build(macID: String, macRoutes: [MacRoute], routes: [VPNRoute]) -> [NetworkChain] {
        var next: [String: [VPNRoute]] = [:]
        for r in routes { next[r.fromID, default: []].append(r) }

        var out: [NetworkChain] = []
        func extend(_ c: NetworkChain) {
            let onward = (next[c.nodes.last ?? ""] ?? []).filter { !c.nodes.contains($0.toID) }
            if onward.isEmpty { out.append(c); return }
            for r in onward { extend(NetworkChain(nodes: c.nodes + [r.toID], active: c.active && r.active)) }
        }

        for r in macRoutes {
            extend(NetworkChain(nodes: [macID] + (r.viaID.map { [$0] } ?? []) + [r.toID], active: r.active))
        }
        let targets = Set(routes.map(\.toID))
        for start in Set(routes.map(\.fromID)).subtracting(targets).sorted() {
            extend(NetworkChain(nodes: [start], active: true))
        }

        var unique: [NetworkChain] = []
        for c in out where !unique.contains(where: { $0.nodes == c.nodes }) { unique.append(c) }
        return unique.filter { c in
            !unique.contains { o in o.nodes.count > c.nodes.count && Array(o.nodes.prefix(c.nodes.count)) == c.nodes }
        }
    }
}

/// The map at a past moment, from what the database keeps for 30 days.
public enum MapMoment {
    /// Worst alert each server (or "site:<id>") had open at `time`.
    public static func alerts(_ events: [Store.LoggedEvent], at time: Date) -> [String: Severity] {
        var open: [String: Store.LoggedEvent] = [:]
        for e in events.sorted(by: { $0.time < $1.time }) where e.time <= time && e.kind != .info {
            let key = e.serverID + "|" + e.key
            if e.kind == .resolved { open[key] = nil } else { open[key] = e }
        }
        var out: [String: Severity] = [:]
        for e in open.values { out[e.serverID] = max(out[e.serverID] ?? e.severity, e.severity) }
        return out
    }

    /// The latest check to each peer at or before `time`, if not older than
    /// `window` (a server that was off has no fresh check).
    public static func links(_ samples: [Store.LinkSample], at time: Date,
                             window: TimeInterval = 900) -> [String: Store.LinkSample] {
        var out: [String: Store.LinkSample] = [:]
        for s in samples where s.time <= time && time.timeIntervalSince(s.time) <= window {
            if let cur = out[s.peerID], cur.time > s.time { continue }
            out[s.peerID] = s
        }
        return out
    }

    /// The last sample at or before `time` within `window`.
    public static func sample(_ samples: [Store.Sample], at time: Date,
                              window: TimeInterval = 900) -> Store.Sample? {
        samples.filter { $0.time <= time && time.timeIntervalSince($0.time) <= window }.max { $0.time < $1.time }
    }

    /// Each server's latest check of a site at or before `time` within `window`.
    public static func site(_ samples: [Store.SiteSample], at time: Date,
                            window: TimeInterval = 900) -> [String: Store.SiteSample] {
        var out: [String: Store.SiteSample] = [:]
        for s in samples where s.time <= time && time.timeIntervalSince(s.time) <= window {
            if let cur = out[s.serverID], cur.time > s.time { continue }
            out[s.serverID] = s
        }
        return out
    }
}

/// Which of our servers a site runs on.
public enum SiteHosting {
    /// "https://shop.example.com/path" -> "shop.example.com".
    public static func host(of url: String) -> String? {
        let text = url.contains("://") ? url : "https://" + url
        guard let h = URLComponents(string: text)?.host, !h.isEmpty else { return nil }
        return h.lowercased()
    }

    /// The first server (in the given order) whose addresses include one of
    /// the site's; nil for a site hosted elsewhere.
    public static func server(siteAddresses: [String], servers: [(id: String, addresses: [String])]) -> String? {
        let site = Set(siteAddresses)
        return servers.first { !site.isDisjoint(with: $0.addresses) }?.id
    }
}

/// How this Mac reaches an address, from `route -n get <host>` (macOS).
public enum MacRouting {
    /// "interface: en0" -> "en0".
    public static func interface(routeGet text: String) -> String? {
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("interface:") else { continue }
            let name = t.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        return nil
    }

    /// A VPN interface: then a check from this Mac is not a check from its country.
    public static func isTunnel(_ interface: String?) -> Bool {
        guard let i = interface else { return false }
        return ["utun", "ipsec", "ppp", "tun", "tap", "wg"].contains { i.hasPrefix($0) }
    }
}
