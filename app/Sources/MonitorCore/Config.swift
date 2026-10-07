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

    public init(id: String, name: String, host: String, port: Int = 9443, token: String,
                fingerprint: String, group: String? = nil, tags: [String]? = nil,
                thresholds: Thresholds? = nil, ssh: SSHTarget? = nil) {
        self.id = id; self.name = name; self.host = host; self.port = port
        self.token = token; self.fingerprint = fingerprint
        self.group = group; self.tags = tags; self.thresholds = thresholds; self.ssh = ssh
    }

    /// Where to SSH for this server.
    /// Id of the TCP check other agents run against this server.
    public var peerCheckID: String { ServerConfig.peerCheckPrefix + id }
    public static let peerCheckPrefix = "peer-"

    public var sshTarget: SSHTarget { ssh ?? SSHTarget(host: host, user: "root") }

    public var baseURL: URL { URL(string: "https://\(host):\(port)")! }

    enum CodingKeys: String, CodingKey {
        case id, name, host, port, token, fingerprint, group, tags, thresholds, ssh
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
