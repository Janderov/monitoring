import Foundation
import Logging
import MonitorCore
import PostgresNIO

/// The servers and sites the hub watches, read from inv.* with their
/// secrets opened. Replaces servers.json + Keychain of the Mac app.
public struct Inventory: Equatable, Sendable {
    public var servers: [ServerConfig]
    public var sites: [SiteConfig]
    /// Why some rows were left out (a secret that does not open, …).
    public var problems: [String]
    /// The id the poller knows each server and site by → its uuid. Objects
    /// brought from the Mac keep the Mac's id here, so while both run the
    /// agents get the same check list (site-<id>, peer-<id>) from each.
    public var serverIDs: [String: UUID] = [:]
    public var siteIDs: [String: UUID] = [:]

    public init(servers: [ServerConfig] = [], sites: [SiteConfig] = [], problems: [String] = []) {
        self.servers = servers; self.sites = sites; self.problems = problems
    }

    static let snakeDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    static func thresholds(_ json: String?) -> Thresholds? {
        guard let json, json != "{}", let t = try? snakeDecoder.decode(Thresholds.self, from: Data(json.utf8)) else { return nil }
        return t
    }

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    public static func load(_ db: Database, box: SecretBox?) async throws -> Inventory {
        var inv = Inventory()
        func open(_ id: UUID, _ kind: String, _ c: ByteBuffer, _ n: ByteBuffer) throws -> String {
            guard let box else { throw HubConfig.Error("нет ключа шифрования (\(HubConfig.credentialNames.key))") }
            return try box.open(.init(ciphertext: Array(buffer: c), nonce: Array(buffer: n)), id: id, kind: kind)
        }

        // Every server's poll id, archived ones too: their old checks and
        // links still name them.
        for try await (id, legacy) in try await db.query("""
            SELECT s.id, l.legacy_id FROM inv.server s
            LEFT JOIN sys.legacy_id l ON l.kind = 'server' AND l.id = s.id
            """).decode((UUID, String?).self) {
            inv.serverIDs[legacy ?? id.uuidString.lowercased()] = id
        }
        let pollID = Dictionary(inv.serverIDs.map { ($1, $0) }, uniquingKeysWith: { a, _ in a })

        let servers = try await db.query("""
            SELECT s.id, s.name, s.host, s.agent_port, s.agent_fingerprint, s.thresholds::text, s.tags,
                   sec.id, sec.kind, sec.ciphertext, sec.nonce
            FROM inv.server s JOIN sys.secret sec ON sec.id = s.agent_token_id
            WHERE s.archived_at IS NULL AND NOT s.paused
            ORDER BY s.position, s.name
            """)
        for try await (id, name, host, port, fp, th, tags, sid, kind, c, n) in servers.decode(
            (UUID, String, String, Int32, ByteBuffer, String, [String], UUID, String, ByteBuffer, ByteBuffer).self) {
            do {
                let token = try open(sid, kind, c, n)
                inv.servers.append(ServerConfig(
                    id: pollID[id] ?? id.uuidString.lowercased(), name: name, host: host, port: Int(port), token: token,
                    fingerprint: hex(Array(buffer: fp)), tags: tags.isEmpty ? nil : tags, thresholds: thresholds(th)))
            } catch {
                inv.problems.append("сервер «\(name)»: \(error)")
            }
        }

        // Which agents check each site: inv.site_probe rows of kind 'agent';
        // none means all of them, as `from: nil` on the Mac.
        var from: [UUID: [String]] = [:]
        let probes = try await db.query("""
            SELECT sp.site_id, p.server_id FROM inv.site_probe sp JOIN inv.probe p ON p.id = sp.probe_id
            WHERE p.kind = 'agent'
            """)
        for try await (site, server) in probes.decode((UUID, UUID).self) {
            from[site, default: []].append(pollID[server] ?? server.uuidString.lowercased())
        }

        let sites = try await db.query("""
            SELECT s.id, l.legacy_id, s.name, s.url, s.thresholds::text, s.tags, s.auth_user,
                   sec.id, sec.kind, sec.ciphertext, sec.nonce
            FROM inv.site s LEFT JOIN sys.secret sec ON sec.id = s.auth_password_id
            LEFT JOIN sys.legacy_id l ON l.kind = 'site' AND l.id = s.id
            WHERE s.archived_at IS NULL AND NOT s.paused
            ORDER BY s.position, s.name
            """)
        for try await (id, legacy, name, url, th, tags, user, sid, kind, c, n) in sites.decode(
            (UUID, String?, String, String, String, [String], String?, UUID?, String?, ByteBuffer?, ByteBuffer?).self) {
            let siteID = legacy ?? id.uuidString.lowercased()
            inv.siteIDs[siteID] = id
            var site = SiteConfig(id: siteID, name: name, url: url,
                                  tags: tags.isEmpty ? nil : tags, from: from[id], thresholds: thresholds(th),
                                  authUser: user)
            if let sid, let kind, let c, let n {
                do { site.authPassword = try open(sid, kind, c, n) } catch {
                    // Checked without the login rather than not at all;
                    // agents keep the list they have meanwhile.
                    site.authLocked = true
                    inv.problems.append("сайт «\(name)»: \(error)")
                }
            }
            inv.sites.append(site)
        }
        return inv
    }

    /// Makes sure the hub and every server have a check point (inv.probe)
    /// and returns their ids: the hub's, and each server's agent's.
    public static func probes(_ db: Database, hubName: String) async throws -> (hub: UUID, agents: [UUID: UUID]) {
        try await db.query("""
            INSERT INTO inv.probe (kind, server_id, name, country)
            SELECT 'agent', s.id, s.name, s.country FROM inv.server s
            ON CONFLICT (server_id) DO UPDATE SET name = EXCLUDED.name, country = EXCLUDED.country
            """)
        var hub = try await db.scalar("SELECT id FROM inv.probe WHERE kind = 'hub' ORDER BY name LIMIT 1", as: UUID.self)
        if hub == nil {
            hub = try await db.scalar("INSERT INTO inv.probe (kind, name) VALUES ('hub', \(hubName)) RETURNING id", as: UUID.self)
        }
        var agents: [UUID: UUID] = [:]
        for try await (server, probe) in try await db.query(
            "SELECT server_id, id FROM inv.probe WHERE kind = 'agent'").decode((UUID, UUID).self) {
            agents[server] = probe
        }
        return (hub!, agents)
    }
}
