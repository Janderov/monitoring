import Foundation

/// A server the Mac polls. Until the "Add server" screen exists these live in
/// `servers.json` in the data folder.
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

    public init(id: String, name: String, host: String, port: Int = 9443, token: String,
                fingerprint: String, group: String? = nil, tags: [String]? = nil,
                thresholds: Thresholds? = nil) {
        self.id = id; self.name = name; self.host = host; self.port = port
        self.token = token; self.fingerprint = fingerprint
        self.group = group; self.tags = tags; self.thresholds = thresholds
    }

    public var baseURL: URL { URL(string: "https://\(host):\(port)")! }
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

public struct ServersFile: Codable, Sendable {
    public var servers: [ServerConfig]

    public init(servers: [ServerConfig]) { self.servers = servers }

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
            guard s.token.count >= 32 else { throw ConfigError("сервер \(s.id): токен слишком короткий") }
            guard Fingerprint.bytes(s.fingerprint) != nil else {
                throw ConfigError("сервер \(s.id): отпечаток должен состоять из 64 шестнадцатеричных символов "
                                  + "(двоеточия можно оставить), сейчас их \(s.fingerprint.filter(\.isHexDigit).count)")
            }
            guard (1...65535).contains(s.port), !s.host.isEmpty else {
                throw ConfigError("сервер \(s.id): неверный адрес или порт")
            }
        }
    }

    /// Written on first launch so there is something to edit.
    public static let example = """
    {
      "servers": [
        {
          "id": "nl-1",
          "name": "Нидерланды VPN",
          "host": "203.0.113.10",
          "port": 9443,
          "token": "PASTE-TOKEN-FROM-remote-install.sh",
          "fingerprint": "PASTE-FINGERPRINT-FROM-remote-install.sh",
          "group": "Нидерланды",
          "tags": ["vpn", "прод"]
        }
      ]
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
