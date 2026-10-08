import Foundation

// Tools behind the map's "Разбор" mode and the panel next to it: what breaks
// if a server goes away, checks from Russian cities, where packets are lost,
// the disk forecast and what expires soon.

/// What stops working if one server goes away. Nothing is switched off: the
/// map only shows the consequences.
public struct WhatIfImpact: Equatable, Sendable {
    /// Paths that go through the server.
    public var brokenChains: [NetworkChain]
    /// VPN keys whose traffic goes through the server: its own clients and
    /// the clients of servers whose cascade leads through it.
    public var clientsLost: Int
    public var clientsLostOnline: Int
    public var clientsTotal: Int
    /// Sites running on the server.
    public var sites: [String]
    /// Sites the server checks: they lose one country of checks.
    public var checks: [String]
    /// Every broken path has another one from the same start that avoids the
    /// server; nil when no path is broken.
    public var hasBackup: Bool?
}

public enum WhatIf {
    /// - Parameters:
    ///   - clients: every VPN key with the server it connects to.
    ///   - siteHosts: site id -> the server it runs on.
    ///   - siteChecks: site id -> servers that check it.
    public static func impact(off: String, chains: [NetworkChain],
                              clients: [(serverID: String, active: Bool)],
                              siteHosts: [String: String], siteChecks: [String: [String]]) -> WhatIfImpact {
        let broken = chains.filter { $0.nodes.contains(off) }
        // A cascade's clients enter at its first server.
        var through: Set<String> = [off]
        for c in broken { if let first = c.nodes.first { through.insert(first) } }
        let lost = clients.filter { through.contains($0.serverID) }

        var backup: Bool?
        if !broken.isEmpty {
            backup = broken.allSatisfy { c in
                chains.contains { o in o.nodes.first == c.nodes.first && o.nodes.count > 1 && !o.nodes.contains(off) }
            }
        }
        return WhatIfImpact(brokenChains: broken,
                            clientsLost: lost.count, clientsLostOnline: lost.filter(\.active).count,
                            clientsTotal: clients.count,
                            sites: siteHosts.filter { $0.value == off }.map(\.key).sorted(),
                            checks: siteChecks.filter { $0.value.contains(off) }.map(\.key).sorted(),
                            hasBackup: backup)
    }
}

/// check-host.net: TCP checks of an address from its probes in many cities.
/// https://check-host.net/about/api
public enum CheckHost {
    public struct Node: Equatable, Sendable {
        /// "ru1.node.check-host.net".
        public var id: String
        public var country: String
        public var city: String
    }

    public enum Result: Equatable, Sendable {
        case ok(ms: Double)
        case failed(String)
        case pending
    }

    public static let base = "https://check-host.net"

    /// Probes in one country from `/nodes/hosts`, sorted by city.
    public static func nodes(_ data: Data, country: String = "ru") -> [Node] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nodes = obj["nodes"] as? [String: Any] else { return [] }
        var out: [Node] = []
        for (id, v) in nodes {
            guard let info = v as? [String: Any], let loc = info["location"] as? [Any], loc.count >= 3,
                  let code = loc[0] as? String, code.lowercased() == country.lowercased() else { continue }
            out.append(Node(id: id, country: code.uppercased(), city: (loc[2] as? String) ?? id))
        }
        return out.sorted { ($0.city, $0.id) < ($1.city, $1.id) }
    }

    /// The id of a started check (`/check-tcp`).
    public static func requestID(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["request_id"] as? String
    }

    /// `/check-result/<id>` of a TCP check: per probe a list with one
    /// `{"time": seconds}` or `{"error": "..."}`, or null while it runs.
    public static func results(_ data: Data) -> [String: Result] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [String: Result] = [:]
        for (node, v) in obj {
            out[node] = result(v)
        }
        return out
    }

    private static func result(_ v: Any) -> Result {
        var item: Any = v
        // Unwrap [ {...} ] and [[ {...} ]].
        while let list = item as? [Any] {
            guard let first = list.first else { return .pending }
            item = first
        }
        guard let d = item as? [String: Any] else { return .pending }
        if let t = (d["time"] as? NSNumber)?.doubleValue { return .ok(ms: t * 1000) }
        if let e = d["error"] as? String { return .failed(e) }
        return .pending
    }

    /// "Connection timed out" -> a short Russian word for the panel.
    public static func describe(_ error: String) -> String {
        let e = error.lowercased()
        if e.contains("timed out") || e.contains("timeout") { return "не отвечает" }
        if e.contains("refused") { return "порт закрыт" }
        if e.contains("unreachable") { return "нет маршрута" }
        if e.contains("reset") { return "соединение сброшено" }
        return error
    }
}

/// One step of a `traceroute -n` run.
public struct TraceHop: Equatable, Sendable {
    public var number: Int
    /// Nil when no probe came back.
    public var ip: String?
    /// Round trip of each probe that came back, ms.
    public var rtts: [Double]
    public var sent: Int

    public var lost: Int { sent - rtts.count }
    /// Lost share, 0...1.
    public var loss: Double { sent == 0 ? 0 : Double(lost) / Double(sent) }
    public var averageMs: Double? { rtts.isEmpty ? nil : rtts.reduce(0, +) / Double(rtts.count) }
}

public enum Traceroute {
    /// Parses macOS/Linux `traceroute -n` output:
    /// ` 3  192.0.2.1  9.123 ms  9.001 ms *`, ` 7  * * *`.
    public static func parse(_ text: String) -> [TraceHop] {
        var hops: [TraceHop] = []
        for line in text.split(separator: "\n") {
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let first = tokens.first, let n = Int(first) else { continue }
            var hop = TraceHop(number: n, ip: nil, rtts: [], sent: 0)
            var i = 1
            while i < tokens.count {
                let t = tokens[i]
                if t == "*" {
                    hop.sent += 1
                } else if let v = Double(t), i + 1 < tokens.count, tokens[i + 1] == "ms" {
                    hop.rtts.append(v)
                    hop.sent += 1
                    i += 1
                } else if t.hasPrefix("!") || t == "ms" {
                    // "!H", "!N": unreachable marks next to a time.
                } else if hop.ip == nil, t.contains(".") || t.contains(":") {
                    hop.ip = t.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                }
                i += 1
            }
            if hop.sent > 0 { hops.append(hop) }
        }
        return hops
    }

    /// The step where packets start to go missing for good: loss there and on
    /// every step after it. Loss at one middle step only is the router
    /// skipping replies, not lost traffic. Nil when the last step is fine.
    public static func culprit(_ hops: [TraceHop], threshold: Double = 0.1) -> TraceHop? {
        guard let last = hops.last, last.loss >= threshold else { return nil }
        var start = hops.count - 1
        while start > 0, hops[start - 1].loss >= threshold { start -= 1 }
        return hops[start]
    }
}

/// When a disk fills up at the pace of the last two weeks.
public enum DiskForecast {
    /// - Parameters:
    ///   - points: time and disk use in percent.
    ///   - full: the percent counted as full.
    /// - Returns: days left; nil when the disk does not grow, or there is not
    ///   enough history, or it is more than a year away.
    public static func daysUntilFull(_ points: [(time: Date, percent: Double)], now: Date,
                                     full: Double = 95, window: TimeInterval = 14 * 86400) -> Double? {
        let recent = points.filter { now.timeIntervalSince($0.time) <= window && $0.time <= now }
        guard recent.count >= 10, let first = recent.map(\.time).min(), let last = recent.max(by: { $0.time < $1.time }),
              last.time.timeIntervalSince(first) >= 2 * 86400 else { return nil }
        if last.percent >= full { return 0 }
        // Least squares: percent per day.
        let xs = recent.map { $0.time.timeIntervalSince(first) / 86400 }
        let ys = recent.map(\.percent)
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0
        for (x, y) in zip(xs, ys) { sxy += (x - mx) * (y - my); sxx += (x - mx) * (x - mx) }
        guard sxx > 0 else { return nil }
        let slope = sxy / sxx
        guard slope > 0.05 else { return nil }
        let days = (full - last.percent) / slope
        return days <= 365 ? days : nil
    }
}

/// Something that runs out soon: a certificate, a domain, the disk.
public struct SoonItem: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable { case tls, domain, disk }
    public var kind: Kind
    /// The site's name for certificates and domains.
    public var name: String
    public var date: Date
    public var id: String { kind.rawValue + "|" + name }

    public init(kind: Kind, name: String, date: Date) { self.kind = kind; self.name = name; self.date = date }
}

public enum Soon {
    /// Listed in the panel.
    public static let listWindow: TimeInterval = 30 * 86400
    /// Gets the dot on the pin.
    public static let badgeWindow: TimeInterval = 14 * 86400

    /// What a server should be watched for: its sites' certificates and
    /// domains, and its disk, soonest first.
    public static func items(sites: [(name: String, tls: Date?, domain: Date?)], diskDays: Double?,
                             now: Date) -> [SoonItem] {
        var out: [SoonItem] = []
        for s in sites {
            if let d = s.tls { out.append(SoonItem(kind: .tls, name: s.name, date: d)) }
            if let d = s.domain { out.append(SoonItem(kind: .domain, name: s.name, date: d)) }
        }
        if let days = diskDays { out.append(SoonItem(kind: .disk, name: "диск", date: now.addingTimeInterval(days * 86400))) }
        return out.filter { $0.date.timeIntervalSince(now) <= listWindow }.sorted { $0.date < $1.date }
    }

    public static func badge(_ items: [SoonItem], now: Date) -> Bool {
        items.contains { $0.date.timeIntervalSince(now) <= badgeWindow }
    }
}

/// A mark on the history slider.
public struct HistoryMark: Equatable, Sendable {
    public enum Kind: Sendable { case down, warning, reboot }
    public var time: Date
    public var kind: Kind
    public var serverID: String
    public var message: String
}

extension MapMoment {
    /// Problems that began and reboots, oldest first; reminders, recoveries
    /// and container changes are left out.
    public static func marks(_ events: [Store.LoggedEvent], from: Date, to: Date) -> [HistoryMark] {
        events.compactMap { e -> HistoryMark? in
            guard e.time >= from, e.time <= to else { return nil }
            switch e.kind {
            case .fired:
                return HistoryMark(time: e.time, kind: e.severity == .critical ? .down : .warning,
                                   serverID: e.serverID, message: e.message)
            case .info where e.key == "reboot":
                return HistoryMark(time: e.time, kind: .reboot, serverID: e.serverID, message: e.message)
            default:
                return nil
            }
        }
        .sorted { $0.time < $1.time }
    }
}

/// The city of an address, from ipwho.is (free, no key). Only VPN clients'
/// addresses are looked up, to put them on the map by city.
public struct IPCity: Equatable, Sendable {
    public var ip: String
    public var city: String
    public var country: String
    public var latitude: Double
    public var longitude: Double
}

public enum IPWho {
    public static func url(_ ip: String) -> URL? {
        URL(string: "https://ipwho.is/" + ip + "?fields=ip,success,city,country_code,latitude,longitude")
    }

    public static func parse(_ data: Data) -> IPCity? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["success"] as? Bool ?? true,
              let ip = obj["ip"] as? String,
              let city = obj["city"] as? String, !city.isEmpty,
              let lat = (obj["latitude"] as? NSNumber)?.doubleValue,
              let lon = (obj["longitude"] as? NSNumber)?.doubleValue else { return nil }
        return IPCity(ip: ip, city: city, country: (obj["country_code"] as? String ?? "").uppercased(),
                      latitude: lat, longitude: lon)
    }
}
