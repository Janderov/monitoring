import Foundation

/// Everything the hub reads at start. Ordinary settings come from the
/// environment; secrets come from files in the credentials folder (systemd
/// `LoadCredential=`, or Docker secrets under /run/secrets), never from the
/// environment or the database.
public struct HubConfig: Sendable {
    public var dbHost: String
    public var dbPort: Int
    public var dbUser: String
    public var dbName: String
    public var dbPassword: String?
    /// `disable` (same machine or a private Docker network), `require`.
    public var dbTLS: Bool
    /// Folder with the numbered *.sql migrations.
    public var migrationsDir: URL
    /// The 32-byte key that seals agent tokens and site passwords in `sys.secret`.
    public var secretKey: Data?
    /// healthchecks.io (or similar) ping address; nil = no outside pulse.
    public var heartbeatURL: URL?
    /// The hub's own name as a check point (inv.probe).
    public var probeName: String

    public static let credentialNames = (key: "secret-key", heartbeat: "heartbeat-url", dbPassword: "db-password")

    public init(dbHost: String = "127.0.0.1", dbPort: Int = 5432, dbUser: String = "monitor",
                dbName: String = "monitor", dbPassword: String? = nil, dbTLS: Bool = false,
                migrationsDir: URL, secretKey: Data? = nil, heartbeatURL: URL? = nil, probeName: String = "Хаб") {
        self.dbHost = dbHost; self.dbPort = dbPort; self.dbUser = dbUser; self.dbName = dbName
        self.dbPassword = dbPassword; self.dbTLS = dbTLS; self.migrationsDir = migrationsDir
        self.secretKey = secretKey; self.heartbeatURL = heartbeatURL; self.probeName = probeName
    }

    public struct Error: Swift.Error, CustomStringConvertible {
        public var description: String
        public init(_ d: String) { description = d }
    }

    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) throws -> HubConfig {
        let creds = credentialsFolder(env)
        func credential(_ name: String) -> String? {
            guard let folder = creds,
                  let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) else { return nil }
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        var key: Data?
        if let text = credential(credentialNames.key) {
            guard let k = Data(base64Encoded: text), k.count == 32 else {
                throw Error("ключ \(credentialNames.key) должен быть 32 байта в base64 (openssl rand -base64 32)")
            }
            key = k
        }
        var heartbeat: URL?
        if let text = credential(credentialNames.heartbeat) {
            guard let url = URL(string: text), url.scheme == "https" else {
                throw Error("адрес пульса \(credentialNames.heartbeat) должен начинаться с https://")
            }
            heartbeat = url
        }
        return HubConfig(
            dbHost: env["PGHOST"] ?? "127.0.0.1",
            dbPort: Int(env["PGPORT"] ?? "") ?? 5432,
            dbUser: env["PGUSER"] ?? "monitor",
            dbName: env["PGDATABASE"] ?? "monitor",
            dbPassword: credential(credentialNames.dbPassword) ?? env["PGPASSWORD"],
            dbTLS: (env["PGSSLMODE"] ?? "disable") == "require",
            migrationsDir: URL(fileURLWithPath: env["HUB_MIGRATIONS"] ?? "/opt/monitor-hub/migrations"),
            secretKey: key,
            heartbeatURL: heartbeat,
            probeName: env["HUB_NAME"] ?? "Хаб")
    }

    static func credentialsFolder(_ env: [String: String]) -> URL? {
        if let dir = env["CREDENTIALS_DIRECTORY"] ?? env["HUB_CREDENTIALS"] { return URL(fileURLWithPath: dir) }
        let docker = URL(fileURLWithPath: "/run/secrets")
        return FileManager.default.fileExists(atPath: docker.path) ? docker : nil
    }
}
