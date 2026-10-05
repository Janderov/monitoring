import Foundation

/// A site as seen from every server that checks it, plus its domain expiry.
public struct SiteStatus: Equatable, Identifiable, Sendable {
    public struct Origin: Equatable, Sendable {
        public var serverID: String
        public var serverName: String
        /// The agent's latest result; nil while the agent is unreachable or
        /// has not run the check yet.
        public var check: Snapshot.Check?
    }

    public var id: String { site.id }
    public var site: SiteConfig
    public var origins: [Origin]
    public var domain: String?
    public var domainExpiry: Date?
    public var domainError: String?
    public var alerts: [ActiveAlert]

    /// Earliest certificate expiry any origin saw.
    public var tlsExpiry: Date? { origins.compactMap { $0.check?.tlsExpiry }.min() }

    public var level: ServerStatus.Level {
        if let worst = alerts.map(\.severity).max() { return worst == .critical ? .critical : .warning }
        return origins.contains { $0.check != nil } ? .ok : .unknown
    }

    /// Key under which the alert engine and the event log track this site.
    public static func alertID(_ siteID: String) -> String { "site:" + siteID }
}

public enum SiteRules {
    public static func conditions(_ s: SiteStatus, now: Date) -> [Condition] {
        let t = (s.site.thresholds ?? Thresholds()).resolved
        var out: [Condition] = []
        let seen = s.origins.filter { $0.check != nil }
        let failing = seen.filter { $0.check?.ok == false }

        if !seen.isEmpty, failing.count == seen.count {
            let why = failing.first?.check.map(reason) ?? ""
            out.append(Condition(key: "down", severity: .critical,
                                 message: "сайт \(s.site.name) недоступен: \(why)"))
        } else {
            // Down from some countries only: likely blocked or a routing issue.
            for o in failing {
                out.append(Condition(key: "from:\(o.serverID)", severity: .warning,
                                     message: "сайт \(s.site.name) недоступен с сервера \(o.serverName): "
                                         + (o.check.map(reason) ?? "")))
            }
        }
        if let exp = s.tlsExpiry, let days = t.tlsDays, exp.timeIntervalSince(now) < Double(days) * 86400 {
            let left = Int(exp.timeIntervalSince(now) / 86400)
            out.append(Condition(key: "tls", severity: .warning,
                                 message: left < 0 ? "SSL \(s.site.name) истёк"
                                                   : "SSL \(s.site.name) истекает через \(left) дн."))
        }
        if let exp = s.domainExpiry, let days = t.domainDays, exp.timeIntervalSince(now) < Double(days) * 86400 {
            let left = Int(exp.timeIntervalSince(now) / 86400)
            // One poll is enough: the date comes from the registry, not a flaky probe.
            out.append(Condition(key: "domain", severity: .warning,
                                 message: left < 0 ? "домен \(s.domain ?? "") истёк"
                                                   : "домен \(s.domain ?? "") истекает через \(left) дн.",
                                 after: 1))
        }
        return out
    }

    static func reason(_ c: Snapshot.Check) -> String {
        if let e = c.error, !e.isEmpty { return e }
        return c.statusCode.map { "HTTP \($0)" } ?? "нет ответа"
    }
}

// MARK: - domains

public enum DomainName {
    /// Second-level zones where names are registered one level deeper.
    static let deeperZones: Set<String> = [
        "com.ru", "net.ru", "org.ru", "pp.ru", "msk.ru", "spb.ru",
        "co.uk", "org.uk", "com.au", "net.au", "com.br", "com.tr", "com.ua",
    ]

    /// The registered domain of a host: "shop.example.com" -> "example.com".
    /// Nil for IP addresses and single-label or non-ASCII hosts.
    public static func registrable(_ host: String) -> String? {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard h.allSatisfy({ $0.isASCII }), h.contains("."),
              !h.split(separator: ".").allSatisfy({ $0.allSatisfy(\.isNumber) }), !h.contains(":")
        else { return nil }
        let labels = h.split(separator: ".").map(String.init)
        let last2 = labels.suffix(2).joined(separator: ".")
        if deeperZones.contains(last2), labels.count >= 3 { return labels.suffix(3).joined(separator: ".") }
        return last2
    }

    /// Zones without RDAP whose registry answers WHOIS instead.
    static let whoisServers: [String: String] = [
        "ru": "whois.tcinet.ru", "su": "whois.tcinet.ru", "xn--p1ai": "whois.tcinet.ru",
    ]

    public static func whoisServer(for domain: String) -> String? {
        domain.split(separator: ".").last.flatMap { whoisServers[String($0)] }
    }

    /// Expiration date from an RDAP domain response.
    public static func parseRDAP(_ data: Data) -> Date? {
        struct Response: Decodable {
            struct Event: Decodable { var eventAction: String; var eventDate: String }
            var events: [Event]?
        }
        guard let r = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        return r.events?.first { $0.eventAction == "expiration" }
            .flatMap { AgentJSON.parseRFC3339($0.eventDate) }
    }

    /// Expiration date from WHOIS text (tcinet "paid-till", gTLD-style fields).
    public static func parseWhois(_ text: String) -> Date? {
        let keys = ["paid-till:", "registry expiry date:", "registrar registration expiration date:",
                    "expiration date:", "expiry date:", "expires:"]
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            let lower = l.lowercased()
            for k in keys where lower.hasPrefix(k) {
                let value = l.dropFirst(k.count).trimmingCharacters(in: .whitespaces)
                if let d = AgentJSON.parseRFC3339(value) ?? parseDay(value) { return d }
            }
        }
        return nil
    }

    private static func parseDay(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd", "yyyy.MM.dd", "dd-MMM-yyyy"] {
            f.dateFormat = format
            if let d = f.date(from: String(s.prefix(11)).trimmingCharacters(in: .whitespaces)) { return d }
        }
        return nil
    }
}

/// Fetches registry data for domain lookups. The real one uses HTTPS (RDAP)
/// and TCP port 43 (WHOIS); tests substitute a fake.
public protocol DomainLookupTransport: Sendable {
    func rdap(_ domain: String) async throws -> Data
    func whois(server: String, query: String) async throws -> String
}

/// Domain expiry dates, looked up at most twice a day per domain.
public actor DomainExpiry {
    public static let refresh: TimeInterval = 12 * 3600
    /// After an error, try again sooner.
    public static let retry: TimeInterval = 3600

    public struct Entry: Equatable, Sendable {
        public var expiry: Date?
        public var error: String?
        public var checkedAt: Date
    }

    private let transport: DomainLookupTransport
    private var cache: [String: Entry] = [:]
    private var inFlight: Set<String> = []

    public init(transport: DomainLookupTransport, cached: [String: Entry] = [:]) {
        self.transport = transport
        self.cache = cached
    }

    public func entry(_ domain: String) -> Entry? { cache[domain] }

    /// Seeds the cache from the database after a restart.
    public func restore(_ domain: String, _ entry: Entry) {
        if cache[domain] == nil { cache[domain] = entry }
    }

    /// Domains whose entry is missing or stale.
    public func due(_ domains: Set<String>, now: Date) -> [String] {
        domains.filter { d in
            guard !inFlight.contains(d) else { return false }
            guard let e = cache[d] else { return true }
            let age = now.timeIntervalSince(e.checkedAt)
            return age >= (e.expiry == nil ? DomainExpiry.retry : DomainExpiry.refresh)
        }.sorted()
    }

    /// Looks one domain up and caches the result.
    public func lookup(_ domain: String, now: Date) async -> Entry {
        inFlight.insert(domain)
        defer { inFlight.remove(domain) }
        var entry = Entry(expiry: nil, error: nil, checkedAt: now)
        do {
            if let server = DomainName.whoisServer(for: domain) {
                entry.expiry = DomainName.parseWhois(try await transport.whois(server: server, query: domain))
            } else {
                entry.expiry = DomainName.parseRDAP(try await transport.rdap(domain))
            }
            if entry.expiry == nil { entry.error = "регистратор не сообщил срок" }
        } catch {
            entry.error = "не удалось узнать срок домена: \(error.localizedDescription)"
        }
        cache[domain] = entry
        return entry
    }
}
