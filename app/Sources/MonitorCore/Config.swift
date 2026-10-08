import Foundation

/// A server the Mac polls, as listed in `servers.json` in the data folder.
/// The token is kept in Keychain and left out of the file (see
/// `ConfigRepository`); a token still written in the file is accepted.
public struct ServerConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var host: String
    public var port: Int
    public var token: String
    /// SHA-256 of the agent certificate, as `monitor-agent fingerprint` prints it.
    public var fingerprint: String
    /// Free-form grouping for the dashboard, e.g. country or hosting.
    public var group: String?
    public var tags: [String]?
    /// Optional per-server overrides of the default alert thresholds.
    public var thresholds: Thresholds?
    /// How the Mac logs in over SSH (agent install, VPN keys), as entered in
    /// the add-server form; nil means `ssh root@host` with ~/.ssh/config.
    public var ssh: SSHTarget?
    /// What the server costs, entered by hand.
    public var cost: ServerCost?

    public init(id: String, name: String, host: String, port: Int = 9443, token: String,
                fingerprint: String, group: String? = nil, tags: [String]? = nil,
                thresholds: Thresholds? = nil, ssh: SSHTarget? = nil, cost: ServerCost? = nil) {
        self.id = id; self.name = name; self.host = host; self.port = port
        self.token = token; self.fingerprint = fingerprint
        self.group = group; self.tags = tags; self.thresholds = thresholds; self.ssh = ssh
        self.cost = cost
    }

    /// Where to SSH for this server.
    /// Id of the TCP check other agents run against this server.
    public var peerCheckID: String { ServerConfig.peerCheckPrefix + id }
    public static let peerCheckPrefix = "peer-"

    public var sshTarget: SSHTarget { ssh ?? SSHTarget(host: host, user: "root") }

    public var baseURL: URL { URL(string: "https://\(host):\(port)")! }

    enum CodingKeys: String, CodingKey {
        case id, name, host, port, token, fingerprint, group, tags, thresholds, ssh, cost
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 9443
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
        fingerprint = try c.decode(String.self, forKey: .fingerprint)
        group = try c.decodeIfPresent(String.self, forKey: .group)
        tags = try c.decodeIfPresent([String].self, forKey: .tags)
        thresholds = try c.decodeIfPresent(Thresholds.self, forKey: .thresholds)
        ssh = try c.decodeIfPresent(SSHTarget.self, forKey: .ssh)
        cost = try c.decodeIfPresent(ServerCost.self, forKey: .cost)
    }

    /// An empty token is omitted, which is how the file stores servers whose
    /// token is in Keychain.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        if !token.isEmpty { try c.encode(token, forKey: .token) }
        try c.encode(fingerprint, forKey: .fingerprint)
        try c.encodeIfPresent(group, forKey: .group)
        try c.encodeIfPresent(tags, forKey: .tags)
        try c.encodeIfPresent(thresholds, forKey: .thresholds)
        try c.encodeIfPresent(ssh, forKey: .ssh)
        try c.encodeIfPresent(cost, forKey: .cost)
    }
}

/// A server's price per month and the day of the month it is paid.
public struct ServerCost: Codable, Equatable, Sendable {
    public var monthly: Double
    /// "₽", "€", "$".
    public var currency: String
    /// 1...31; nil when the payment day is not tracked.
    public var payDay: Int?

    public init(monthly: Double, currency: String, payDay: Int? = nil) {
        self.monthly = monthly; self.currency = currency; self.payDay = payDay
    }

    /// The next payment on or after the start of today; the day is clamped to
    /// short months (31 -> 30 or 28).
    public func nextPayment(after now: Date, calendar: Calendar = .current) -> Date? {
        guard let day = payDay, (1...31).contains(day) else { return nil }
        let today = calendar.startOfDay(for: now)
        for offset in 0...1 {
            guard let month = calendar.date(byAdding: .month, value: offset, to: today),
                  let range = calendar.range(of: .day, in: .month, for: month) else { continue }
            var parts = calendar.dateComponents([.year, .month], from: month)
            parts.day = min(day, range.count)
            if let d = calendar.date(from: parts), d >= today { return d }
        }
        return nil
    }
}

/// Fingerprints are compared as 32 raw bytes, so case and separators don't matter.
public enum Fingerprint {
    public static func bytes(_ s: String) -> [UInt8]? {
        let hex = s.filter(\.isHexDigit)
        guard hex.count == 64 else { return nil }
        var out: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }

    public static func matches(_ expected: String, sha256 digest: [UInt8]) -> Bool {
        guard let want = bytes(expected), want.count == digest.count else { return false }
        // Constant-time compare; the value is not secret, but it costs nothing.
        return zip(want, digest).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// A site checked from the agents (several countries) plus domain expiry from
/// the Mac.
public struct SiteConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var url: String
    public var group: String?
    public var tags: [String]?
    /// Server ids to check from; all servers when nil.
    public var from: [String]?
    public var thresholds: Thresholds?
    /// Login for a site behind a password, so agents check past the login
    /// prompt. The password is kept in Keychain, never in the file.
    public var authUser: String?
    public var authPassword: String? = nil
    /// The password is sealed by the admin key and the app is locked: agents
    /// keep the login they have until it is unlocked (see Poller).
    public var authLocked = false

    enum CodingKeys: String, CodingKey {
        case id, name, url, group, tags, from, thresholds, authUser
    }

    public init(id: String, name: String, url: String, group: String? = nil, tags: [String]? = nil,
                from: [String]? = nil, thresholds: Thresholds? = nil,
                authUser: String? = nil, authPassword: String? = nil) {
        self.id = id; self.name = name; self.url = url; self.group = group; self.tags = tags
        self.from = from; self.thresholds = thresholds
        self.authUser = authUser; self.authPassword = authPassword
    }

    /// What the agents log in with; nil when the site has no login set.
    public var basicAuth: CheckTarget.BasicAuth? {
        guard let user = authUser, !user.isEmpty, let password = authPassword, !password.isEmpty else { return nil }
        return CheckTarget.BasicAuth(user: user, password: password)
    }

    /// Id of the agent check target for this site. The prefix marks targets
    /// the app manages, so server rules leave them to the site rules.
    public var checkID: String { SiteConfig.checkPrefix + id }
    public static let checkPrefix = "site-"

    public var host: String? { URL(string: url)?.host?.lowercased() }

    public func checked(from server: ServerConfig) -> Bool { from?.contains(server.id) ?? true }
}

public struct ServersFile: Codable, Sendable {
    public var servers: [ServerConfig]
    public var sites: [SiteConfig]?

    public init(servers: [ServerConfig], sites: [SiteConfig]? = nil) {
        self.servers = servers; self.sites = sites
    }

    public static func load(from url: URL) throws -> ServersFile {
        let file = try decode(Data(contentsOf: url))
        try file.validate()
        return file
    }

    /// Keys are snake_case like the agent's, e.g. "thresholds": {"disk_percent": 80}.
    public static func decode(_ data: Data) throws -> ServersFile {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(ServersFile.self, from: data)
    }

    /// For monitoring: an entry that cannot be read is left out with the
    /// reason, and the others are read. Only a file that is not JSON at all
    /// stops everything.
    public static func decodeSkipping(_ data: Data) throws -> (file: ServersFile, problems: [String]) {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        let raw = try d.decode(Lossy.self, from: data)
        var problems: [String] = []
        var servers: [ServerConfig] = []
        for (i, e) in raw.servers.enumerated() {
            if let s = e.value { servers.append(s) } else { problems.append("сервер №\(i + 1): \(e.error ?? "")") }
        }
        var sites: [SiteConfig] = []
        for (i, e) in (raw.sites ?? []).enumerated() {
            if let s = e.value { sites.append(s) } else { problems.append("сайт №\(i + 1): \(e.error ?? "")") }
        }
        // Validation (`usable`) comes after the tokens are filled in from
        // the secret store: the file itself has none.
        return (ServersFile(servers: servers, sites: raw.sites == nil ? nil : sites), problems)
    }

    /// The servers and sites that pass `validate`, and why the others do not.
    public func usable() -> (ServersFile, [String]) {
        var problems: [String] = []
        var kept: [ServerConfig] = []
        for s in servers {
            do {
                guard !kept.contains(where: { $0.id == s.id }) else { throw ConfigError("id сервера \"\(s.id)\" повторяется") }
                try ServersFile(servers: [s]).validate()
                kept.append(s)
            } catch {
                problems.append(String(describing: error))
            }
        }
        var keptSites: [SiteConfig] = []
        for site in sites ?? [] {
            do {
                guard !keptSites.contains(where: { $0.id == site.id }) else { throw ConfigError("id сайта \"\(site.id)\" повторяется") }
                try ServersFile(servers: kept, sites: [site]).validate()
                keptSites.append(site)
            } catch {
                problems.append(String(describing: error))
            }
        }
        return (ServersFile(servers: kept, sites: sites == nil ? nil : keptSites), problems)
    }

    private struct Lossy: Decodable {
        var servers: [Entry<ServerConfig>]
        var sites: [Entry<SiteConfig>]?
    }

    private struct Entry<T: Decodable>: Decodable {
        var value: T?
        var error: String?
        init(from decoder: Decoder) throws {
            do { value = try T(from: decoder) } catch { self.error = ServersFile.describe(error) }
        }
    }

    static func describe(_ error: Error) -> String {
        switch error as? DecodingError {
        case .keyNotFound(let key, _): return "нет поля «\(key.stringValue)»"
        case .typeMismatch(_, let c), .valueNotFound(_, let c): return "неверное значение поля «\(c.codingPath.last?.stringValue ?? "")»"
        case .dataCorrupted(let c): return c.debugDescription
        default: return String(describing: error)
        }
    }

    public func validate() throws {
        var ids = Set<String>()
        for s in servers {
            guard !s.id.isEmpty, ids.insert(s.id).inserted else {
                throw ConfigError("id сервера \"\(s.id)\" пустой или повторяется")
            }
            if s.token.hasPrefix("PASTE") || s.fingerprint.hasPrefix("PASTE") {
                throw ConfigError("сервер \(s.id): это пример из файла, впишите свой IP, токен и отпечаток")
            }
            if s.token.isEmpty {
                throw ConfigError("сервер \(s.id): токена нет ни в файле, ни в Связке ключей, "
                                  + "переустановите агента из приложения")
            }
            guard s.token.count >= 32 else { throw ConfigError("сервер \(s.id): токен слишком короткий") }
            guard Fingerprint.bytes(s.fingerprint) != nil else {
                throw ConfigError("сервер \(s.id): отпечаток должен состоять из 64 шестнадцатеричных символов "
                                  + "(двоеточия можно оставить), сейчас их \(s.fingerprint.filter(\.isHexDigit).count)")
            }
            guard (1...65535).contains(s.port), !s.host.isEmpty else {
                throw ConfigError("сервер \(s.id): неверный адрес или порт")
            }
        }
        var siteIDs = Set<String>()
        for site in sites ?? [] {
            guard !site.id.isEmpty, siteIDs.insert(site.id).inserted else {
                throw ConfigError("id сайта \"\(site.id)\" пустой или повторяется")
            }
            guard let u = URL(string: site.url), u.scheme == "https" || u.scheme == "http", u.host != nil else {
                throw ConfigError("сайт \(site.id): адрес должен начинаться с https:// или http://")
            }
            for sid in site.from ?? [] where !ids.contains(sid) {
                throw ConfigError("сайт \(site.id): в from указан неизвестный сервер \(sid)")
            }
        }
    }

    /// Same key style as `decode`; servers whose token is empty (kept in
    /// Keychain) are written without one.
    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try e.encode(self)
    }

    /// Written on first launch: servers and sites are added from the app.
    public static let example = """
    {
      "servers": [],
      "sites": []
    }

    """
}

public struct ConfigError: Error, CustomStringConvertible, Sendable {
    public var description: String
    public init(_ d: String) { description = d }
}

/// Where the app keeps its files. Moving to the Mac mini = copying this folder.
public enum DataFolder {
    public static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Monitor", isDirectory: true)
    }
    public static var serversFile: URL { url.appendingPathComponent("servers.json") }
    public static var database: URL { url.appendingPathComponent("monitor.sqlite") }
    /// The build replaced by the last update and the database as it was then.
    public static var previousApp: URL { url.appendingPathComponent("Previous/Monitor.app", isDirectory: true) }
    public static var previousDatabase: URL { url.appendingPathComponent("Previous/monitor.sqlite") }
    /// A database brought by an import, put in place on the next start, and
    /// the one it replaced.
    public static var pendingImport: URL { url.appendingPathComponent("import.sqlite") }
    public static var beforeImport: URL { url.appendingPathComponent("Previous/monitor-before-import.sqlite") }
    /// Daily copies of the database, one per even and odd day.
    public static func dailyCopy(_ date: Date, calendar: Calendar = .current) -> URL {
        let day = calendar.ordinality(of: .day, in: .era, for: date) ?? 0
        return url.appendingPathComponent("Backups/monitor-\(day % 2 == 0 ? "even" : "odd").sqlite")
    }

    /// Creates the folder (owner-only) and an example servers.json if missing.
    public static func prepare() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: serversFile.path) {
            _ = fm.createFile(atPath: serversFile.path, contents: Data(ServersFile.example.utf8),
                          attributes: [.posixPermissions: 0o600])
        }
    }
}
