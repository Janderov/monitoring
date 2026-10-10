import Foundation
import Logging
import MonitorCore
import PostgresNIO

/// MonitorCore's `TelegramStore` on PostgreSQL. Rights are checked here with
/// acc.permission_mode: alerts_receive to see a problem, alerts_ack to take it.
public actor PostgresTelegramStore: TelegramStore {
    let db: Database
    var logger: Logger { db.logger }
    static let offsetKey = "telegram.offset"
    /// The bot's username, for the cabinet's t.me link.
    public static let usernameKey = "telegram.bot"

    public init(db: Database) { self.db = db }

    func uuid(_ s: String) -> UUID? { UUID(uuidString: s) }
    static func id(_ u: UUID) -> String { u.uuidString.lowercased() }

    // MARK: Linking

    /// A new code for «Подключить Telegram» (the cabinet shows the link as a QR).
    /// Earlier unused codes of the account stop working.
    public static func newCode(_ db: Database, account: UUID, now: Date = Date()) async throws -> String {
        let code = LinkCode.generate()
        try await db.transaction { conn in
            try await conn.query("UPDATE ntf.link_code SET used_at = \(now) WHERE account_id = \(account) AND used_at IS NULL",
                                 logger: db.logger)
            try await conn.query("""
                INSERT INTO ntf.link_code (code_hash, account_id, created_at, expires_at)
                VALUES (\(ByteBuffer(bytes: Array(LinkCode.hash(code)))), \(account), \(now), \(now.addingTimeInterval(LinkCode.lifetime)))
                """, logger: db.logger)
        }
        return code
    }

    public func redeem(codeHash: Data, chatID: Int64, username: String?, now: Date) async throws
        -> (name: String, clients: [String], prefs: NotifyPrefs)? {
        let account: UUID? = try await db.transaction { conn in
            guard let a = try await conn.scalar("""
                UPDATE ntf.link_code c SET used_at = \(now)
                FROM acc.account a
                WHERE c.code_hash = \(ByteBuffer(bytes: Array(codeHash))) AND c.used_at IS NULL AND c.expires_at > \(now)
                  AND a.id = c.account_id AND a.status = 'active'
                RETURNING c.account_id
                """, as: UUID.self, logger: logger) else { return nil }
            // One chat per person and one person per chat.
            try await conn.query("""
                UPDATE ntf.telegram_link SET unlinked_at = \(now)
                WHERE unlinked_at IS NULL AND (account_id = \(a) OR chat_id = \(chatID))
                """, logger: logger)
            try await conn.query("""
                INSERT INTO ntf.telegram_link (account_id, chat_id, tg_username, linked_at)
                VALUES (\(a), \(chatID), \(username), \(now))
                """, logger: logger)
            return a
        }
        guard let account, let acc = try await self.account(chatID: chatID) else { return nil }
        return (acc.name, try await clientNames(account), acc.prefs)
    }

    func clientNames(_ account: UUID) async throws -> [String] {
        var out: [String] = []
        for try await n in try await db.query("""
            SELECT DISTINCT c.name FROM inv.client c
            JOIN inv.client_asset ca ON ca.client_id = c.id AND ca.until IS NULL
            WHERE acc.permission_mode(\(account), 'alerts_receive', ca.asset_type, ca.asset_id) = 'allow'
            ORDER BY c.name
            """).decode(String.self) { out.append(n) }
        return out
    }

    public func account(chatID: Int64) async throws -> (accountID: String, name: String, prefs: NotifyPrefs)? {
        let rows = try await db.query("""
            SELECT a.id, a.display_name, coalesce(p.min_severity, 1)::int4,
                   coalesce(p.timezone, (SELECT value #>> '{}' FROM acc.preference
                                         WHERE account_id = a.id AND key = 'timezone'), 'Europe/Moscow'),
                   (extract(hour FROM p.quiet_from) * 60 + extract(minute FROM p.quiet_from))::int4,
                   (extract(hour FROM p.quiet_to) * 60 + extract(minute FROM p.quiet_to))::int4,
                   coalesce(p.critical_in_quiet, true), coalesce(p.digest_enabled, true),
                   coalesce(extract(hour FROM p.digest_time) * 60 + extract(minute FROM p.digest_time), 540)::int4
            FROM ntf.telegram_link tl JOIN acc.account a ON a.id = tl.account_id
            LEFT JOIN ntf.prefs p ON p.account_id = a.id
            WHERE tl.chat_id = \(chatID) AND tl.unlinked_at IS NULL AND a.status = 'active'
              AND (a.access_expires_at IS NULL OR a.access_expires_at > now())
            """)
        for try await (aid, name, sev, tz, qf, qt, crit, digest, at) in rows.decode(
            (UUID, String, Int32, String, Int32?, Int32?, Bool, Bool, Int32).self) {
            return (Self.id(aid), name, NotifyPrefs(minSeverity: sev >= 2 ? .critical : .warning,
                                                   timeZone: TimeZone(identifier: tz) ?? NotifyPrefs.defaults.timeZone,
                                                   quietFrom: qf.map(Int.init), quietTo: qt.map(Int.init),
                                                   criticalInQuiet: crit, digestEnabled: digest, digestTime: Int(at)))
        }
        return nil
    }

    public func unlink(chatID: Int64, now: Date) async throws {
        try await db.query("UPDATE ntf.telegram_link SET unlinked_at = \(now) WHERE chat_id = \(chatID) AND unlinked_at IS NULL")
    }

    public func markBlocked(chatID: Int64) async throws {
        try await db.query("UPDATE ntf.telegram_link SET blocked_bot = true WHERE chat_id = \(chatID) AND unlinked_at IS NULL")
    }

    // MARK: Problems

    public func ack(incidentID: String, accountID: String, now: Date) async throws
        -> (incident: NotifyIncident, ack: NotifyAck, sent: [TelegramSent])? {
        guard let iid = uuid(incidentID), let aid = uuid(accountID) else { return nil }
        return try await db.transaction { conn in
            guard try await conn.scalar("""
                SELECT acc.permission_mode(\(aid), 'alerts_ack', i.object_type, i.object_id) = 'allow'
                FROM ops.incident i WHERE i.id = \(iid)
                """, as: Bool.self, logger: logger) == true else { return nil }
            try await conn.query("""
                INSERT INTO ops.incident_ack (incident_id, account_id, acked_at, via) VALUES (\(iid), \(aid), \(now), 'telegram')
                ON CONFLICT DO NOTHING
                """, logger: logger)
            guard let (incident, _) = try await NotifyQueue.incident(conn, iid, logger: logger),
                  let first = try await NotifyQueue.acks(conn, iid, logger: logger).first else { return nil }
            // Every first message about it, except lists of several problems.
            var sent: [TelegramSent] = []
            for try await (target, ext, acc) in try await conn.query("""
                SELECT d.target, d.external_id, d.account_id FROM ntf.delivery d
                WHERE d.incident_id = \(iid) AND d.kind IN ('fired','escalation') AND d.status = 'sent'
                  AND d.external_id IS NOT NULL AND d.channel = 'telegram'
                  AND NOT EXISTS (SELECT 1 FROM ntf.delivery o WHERE o.target = d.target AND o.external_id = d.external_id
                                  AND o.incident_id IS DISTINCT FROM d.incident_id)
                """, logger: logger).decode((String, String, UUID?).self) {
                if let chat = Int64(target), let m = Int64(ext) {
                    sent.append(TelegramSent(chatID: chat, messageID: m, accountID: acc.map(Self.id) ?? ""))
                }
            }
            return (incident, first, sent)
        }
    }

    public func openIncidents(scope: String, accountID: String) async throws -> [String] {
        guard let sid = uuid(scope), let aid = uuid(accountID) else { return [] }
        var out: [String] = []
        for try await i in try await db.query("""
            SELECT i.id FROM ops.incident i
            WHERE i.ended_at IS NULL
              AND (i.object_id = \(sid) OR EXISTS (SELECT 1 FROM inv.client_asset ca
                   WHERE ca.client_id = \(sid) AND ca.asset_id = i.object_id AND ca.until IS NULL))
              AND acc.permission_mode(\(aid), 'alerts_ack', i.object_type, i.object_id) = 'allow'
            ORDER BY i.started_at
            """).decode(UUID.self) { out.append(Self.id(i)) }
        return out
    }

    public func mute(accountID: String, scope: NotifyMute.Scope, scopeID: String, until: Date?) async throws {
        guard let aid = uuid(accountID), let sid = uuid(scopeID) else { return }
        try await db.query("""
            INSERT INTO ntf.mute (account_id, scope_type, scope_id, until) VALUES (\(aid), \(scope.rawValue), \(sid), \(until))
            """)
    }

    public func muteAll(accountID: String, until: Date) async throws {
        guard let aid = uuid(accountID) else { return }
        try await db.query("""
            INSERT INTO ntf.mute (account_id, scope_type, scope_id, until)
            SELECT DISTINCT \(aid), 'client', ca.client_id, \(until) FROM inv.client_asset ca
            WHERE ca.until IS NULL AND acc.permission_mode(\(aid), 'alerts_receive', ca.asset_type, ca.asset_id) = 'allow'
            """)
    }

    public func details(incidentID: String, accountID: String) async throws -> TelegramMessage? {
        guard let iid = uuid(incidentID), let aid = uuid(accountID) else { return nil }
        for try await (name, json) in try await db.query("""
            SELECT s.name, l.snapshot::text FROM ops.incident i
            JOIN inv.server s ON s.id = i.object_id AND i.object_type = 'server'
            JOIN mon.latest_snapshot l ON l.server_id = s.id
            WHERE i.id = \(iid) AND acc.permission_mode(\(aid), 'alerts_receive', 'server', s.id) = 'allow'
            """).decode((String, String).self) {
            guard let snap = try? AgentJSON.decoder.decode(Snapshot.self, from: Data(json.utf8)) else { return nil }
            let tz = try await account(accountID: aid)
            return TelegramText.details(name, snap, tz: tz)
        }
        return nil
    }

    func account(accountID: UUID) async throws -> TimeZone {
        let tz = try await db.scalar("""
            SELECT coalesce((SELECT timezone FROM ntf.prefs WHERE account_id = \(accountID)),
                            (SELECT value #>> '{}' FROM acc.preference WHERE account_id = \(accountID) AND key = 'timezone'),
                            'Europe/Moscow')
            """, as: String.self)
        return tz.flatMap(TimeZone.init(identifier:)) ?? NotifyPrefs.defaults.timeZone
    }

    public func status(accountID: String) async throws -> [TelegramText.ClientState] {
        guard let aid = uuid(accountID) else { return [] }
        var out: [TelegramText.ClientState] = []
        for try await (name, servers, sites, warn, crit) in try await db.query("""
            WITH mine AS (
              SELECT ca.client_id, ca.asset_type, ca.asset_id FROM inv.client_asset ca
              WHERE ca.until IS NULL AND ca.asset_type IN ('server','site')
                AND acc.permission_mode(\(aid), 'alerts_receive', ca.asset_type, ca.asset_id) = 'allow')
            SELECT c.name,
                   count(DISTINCT m.asset_id) FILTER (WHERE m.asset_type = 'server')::int4,
                   count(DISTINCT m.asset_id) FILTER (WHERE m.asset_type = 'site')::int4,
                   count(DISTINCT i.id) FILTER (WHERE i.severity = 1)::int4,
                   count(DISTINCT i.id) FILTER (WHERE i.severity = 2)::int4
            FROM mine m JOIN inv.client c ON c.id = m.client_id
            LEFT JOIN ops.incident i ON i.object_id = m.asset_id AND i.ended_at IS NULL
            GROUP BY c.name, c.is_internal ORDER BY c.is_internal DESC, c.name
            """).decode((String, Int32, Int32, Int32, Int32).self) {
            out.append(.init(name: name, servers: Int(servers), sites: Int(sites), warnings: Int(warn), criticals: Int(crit)))
        }
        return out
    }

    public func problems(accountID: String) async throws -> [NotifyIncident] {
        guard let aid = uuid(accountID) else { return [] }
        var ids: [UUID] = []
        for try await i in try await db.query("""
            SELECT i.id FROM ops.incident i
            WHERE i.ended_at IS NULL AND acc.permission_mode(\(aid), 'alerts_receive', i.object_type, i.object_id) = 'allow'
            ORDER BY i.severity DESC, i.started_at LIMIT 30
            """).decode(UUID.self) { ids.append(i) }
        return try await db.transaction { conn in
            var out: [NotifyIncident] = []
            for i in ids { if let (inc, _) = try await NotifyQueue.incident(conn, i, logger: logger) { out.append(inc) } }
            return out
        }
    }

    // MARK: Outbox

    public func due(now: Date, limit: Int) async throws -> [TelegramOutgoing] {
        var out: [TelegramOutgoing] = []
        var nothingToEdit: [UUID] = []
        for try await (did, target, payload, attempts, first, shared) in try await db.query("""
            SELECT d.id, d.target, d.payload::text, d.attempts::int4, o.external_id, coalesce(o.shared, false)
            FROM ntf.delivery d
            LEFT JOIN LATERAL (
              SELECT f.external_id, EXISTS (SELECT 1 FROM ntf.delivery x WHERE x.target = f.target
                                            AND x.external_id = f.external_id AND x.incident_id IS DISTINCT FROM f.incident_id) AS shared
              FROM ntf.delivery f
              WHERE d.incident_id IS NOT NULL AND f.incident_id = d.incident_id AND f.account_id = d.account_id
                AND f.kind IN ('fired','escalation') AND f.status = 'sent' AND f.external_id IS NOT NULL
              ORDER BY f.sent_at LIMIT 1) o ON true
            WHERE d.channel = 'telegram' AND d.status = 'queued' AND coalesce(d.next_attempt_at, d.queued_at) <= \(now)
            ORDER BY d.queued_at LIMIT \(Int32(limit))
            """).decode((UUID, String, String, Int32, String?, Bool).self) {
            guard let chat = Int64(target), let p = try? JSONDecoder().decode(DeliveryPayload.self, from: Data(payload.utf8)) else {
                try await failed(deliveryID: Self.id(did), error: "непонятная запись очереди", retryAt: nil)
                continue
            }
            let original = first.flatMap(Int64.init)
            if p.edit == true {
                // A list of several problems is not rewritten for one of them.
                guard let original, !shared else { nothingToEdit.append(did); continue }
                out.append(TelegramOutgoing(deliveryID: Self.id(did), chatID: chat, message: p.message, edit: original,
                                            attempts: Int(attempts)))
            } else {
                out.append(TelegramOutgoing(deliveryID: Self.id(did), chatID: chat, message: p.message,
                                            replyTo: p.reply == true ? original : nil, attempts: Int(attempts),
                                            bundle: p.bundle, incident: p.incident))
            }
        }
        for d in nothingToEdit { try await sent(deliveryID: Self.id(d), messageID: nil, now: now) }
        return out
    }

    public func sent(deliveryID: String, messageID: Int64?, now: Date) async throws {
        guard let did = uuid(deliveryID) else { return }
        try await db.query("""
            UPDATE ntf.delivery SET status = 'sent', sent_at = \(now), external_id = \(messageID.map(String.init)),
                   attempts = attempts + 1, error = NULL
            WHERE id = \(did)
            """)
    }

    public func failed(deliveryID: String, error: String, retryAt: Date?) async throws {
        guard let did = uuid(deliveryID) else { return }
        try await db.query("""
            UPDATE ntf.delivery SET status = \(retryAt == nil ? "failed" : "queued"), next_attempt_at = \(retryAt),
                   attempts = attempts + 1, error = \(error)
            WHERE id = \(did)
            """)
    }

    public func offset() async throws -> Int64? {
        try await db.scalar("SELECT (value #>> '{}')::int8 FROM sys.kv WHERE key = \(Self.offsetKey)", as: Int64.self)
    }

    public func setOffset(_ id: Int64) async throws {
        try await db.query("""
            INSERT INTO sys.kv (key, value) VALUES (\(Self.offsetKey), to_jsonb(\(id)::int8))
            ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now()
            """)
    }

    public func setUsername(_ name: String) async throws {
        try await db.query("""
            INSERT INTO sys.kv (key, value) VALUES (\(Self.usernameKey), to_jsonb(\(name)::text))
            ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now()
            """)
    }
}
