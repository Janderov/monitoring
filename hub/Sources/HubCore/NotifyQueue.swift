import Foundation
import Logging
import MonitorCore
import PostgresNIO

/// What a row of ntf.delivery carries for Telegram (payload jsonb).
struct DeliveryPayload: Codable, Equatable {
    var message: TelegramMessage
    /// Send as a reply to the first message about the incident («решено»).
    var reply: Bool?
    /// Edit the first message about the incident instead of sending.
    var edit: Bool?
    /// A new alert: may join others of this client into one list.
    var bundle: String?
    var incident: NotifyIncident?

    var json: String { String(decoding: (try? JSONEncoder().encode(self)) ?? Data("{}".utf8), as: UTF8.self) }
}

/// Turns alert events into rows of ntf.delivery, in the same transaction as
/// the incident (PostgresPollStore.addEvent), so nothing is lost or sent twice
/// across restarts. The rules themselves are MonitorCore's `Notify`.
public enum NotifyQueue {
    /// New alerts wait this long, so the ones of one round leave as one list.
    public static let bundleWait: TimeInterval = 15
    static let massKey = "notify.mass_outage"

    static func id(_ u: UUID?) -> String? { u?.uuidString.lowercased() }

    // MARK: Loading

    static func incident(_ conn: PostgresConnection, _ id: UUID, logger: Logger) async throws -> (NotifyIncident, reminders: Int)? {
        let rows = try await conn.query("""
            SELECT i.id, i.object_type, i.object_id, i.object_name, i.key, i.severity::int4, i.message,
                   i.started_at, i.ended_at, i.reminders, c.id, c.name
            FROM ops.incident i
            LEFT JOIN LATERAL (
              SELECT c.id, c.name FROM inv.client_asset ca JOIN inv.client c ON c.id = ca.client_id
              WHERE ca.asset_id = i.object_id AND ca.until IS NULL
              ORDER BY c.is_internal, c.name LIMIT 1) c ON true
            WHERE i.id = \(id)
            """, logger: logger)
        for try await (iid, type, oid, name, key, sev, msg, start, end, rem, cid, cname) in rows.decode(
            (UUID, String, UUID?, String, String, Int32, String, Date, Date?, Int32, UUID?, String?).self) {
            return (NotifyIncident(id: self.id(iid)!, objectType: type, objectID: self.id(oid), objectName: name,
                                   clientID: self.id(cid), clientName: cname, key: key,
                                   severity: sev >= 2 ? .critical : .warning, message: msg,
                                   startedAt: start, endedAt: end), Int(rem))
        }
        return nil
    }

    /// Accounts with alerts_receive on the object, with their Telegram chat,
    /// settings and mutes.
    static func recipients(_ conn: PostgresConnection, type: String, object: UUID?, logger: Logger) async throws -> [NotifyRecipient] {
        var out: [NotifyRecipient] = []
        let rows = try await conn.query("""
            SELECT a.id, a.display_name, a.kind = 'owner',
                   CASE WHEN coalesce('telegram' = ANY (p.channels), true) THEN tl.chat_id END,
                   coalesce(p.min_severity, 1)::int4,
                   coalesce(p.timezone, (SELECT value #>> '{}' FROM acc.preference
                                         WHERE account_id = a.id AND key = 'timezone'), 'Europe/Moscow'),
                   (extract(hour FROM p.quiet_from) * 60 + extract(minute FROM p.quiet_from))::int4,
                   (extract(hour FROM p.quiet_to) * 60 + extract(minute FROM p.quiet_to))::int4,
                   coalesce(p.quiet_days, '{1,2,3,4,5,6,7}')::int4[],
                   coalesce(p.critical_in_quiet, true),
                   coalesce(p.digest_enabled, true),
                   coalesce(extract(hour FROM p.digest_time) * 60 + extract(minute FROM p.digest_time), 540)::int4
            FROM acc.account a
            LEFT JOIN ntf.telegram_link tl ON tl.account_id = a.id AND tl.unlinked_at IS NULL AND NOT tl.blocked_bot
            LEFT JOIN ntf.prefs p ON p.account_id = a.id
            WHERE a.status = 'active' AND acc.permission_mode(a.id, 'alerts_receive', \(type), \(object)) = 'allow'
            ORDER BY a.kind DESC, a.display_name
            """, logger: logger)
        for try await (aid, name, owner, chat, minSev, tz, qf, qt, days, crit, digest, digestAt) in rows.decode(
            (UUID, String, Bool, Int64?, Int32, String, Int32?, Int32?, [Int32], Bool, Bool, Int32).self) {
            let prefs = NotifyPrefs(minSeverity: minSev >= 2 ? .critical : .warning,
                                    timeZone: TimeZone(identifier: tz) ?? NotifyPrefs.defaults.timeZone,
                                    quietFrom: qf.map(Int.init), quietTo: qt.map(Int.init),
                                    quietDays: Set(days.map(Int.init)), criticalInQuiet: crit,
                                    digestEnabled: digest, digestTime: Int(digestAt))
            out.append(NotifyRecipient(accountID: id(aid)!, name: name, chatID: chat, prefs: prefs, isOwner: owner))
        }
        guard !out.isEmpty else { return [] }
        let ids = out.compactMap { UUID(uuidString: $0.accountID) }
        var mutes: [String: [NotifyMute]] = [:]
        for try await (aid, scope, sid, until) in try await conn.query("""
            SELECT account_id, scope_type, scope_id, until FROM ntf.mute
            WHERE account_id = ANY (\(ids)) AND (until IS NULL OR until > now())
            """, logger: logger).decode((UUID, String, UUID, Date?).self) {
            guard let s = NotifyMute.Scope(rawValue: scope) else { continue }
            mutes[id(aid)!, default: []].append(NotifyMute(scope: s, scopeID: id(sid)!, until: until))
        }
        for i in out.indices { out[i].mutes = mutes[out[i].accountID] ?? [] }
        return out
    }

    static func acks(_ conn: PostgresConnection, _ incident: UUID, logger: Logger) async throws -> [NotifyAck] {
        var out: [NotifyAck] = []
        for try await (aid, name, at) in try await conn.query("""
            SELECT k.account_id, a.display_name, k.acked_at FROM ops.incident_ack k
            JOIN acc.account a ON a.id = k.account_id WHERE k.incident_id = \(incident) ORDER BY k.acked_at
            """, logger: logger).decode((UUID, String, Date).self) {
            out.append(NotifyAck(accountID: id(aid)!, name: name, at: at))
        }
        return out
    }

    /// Accounts already told about the incident (or about to be).
    static func told(_ conn: PostgresConnection, _ incident: UUID, logger: Logger) async throws -> Set<String> {
        var out = Set<String>()
        for try await aid in try await conn.query("""
            SELECT DISTINCT account_id FROM ntf.delivery
            WHERE incident_id = \(incident) AND channel = 'telegram' AND status IN ('queued','sent') AND account_id IS NOT NULL
            """, logger: logger).decode(UUID.self) {
            out.insert(id(aid)!)
        }
        return out
    }

    // MARK: Writing

    static func insert(_ conn: PostgresConnection, _ p: Notify.Planned, incident: UUID?, payload: DeliveryPayload,
                       now: Date, wait: TimeInterval = 0, logger: Logger) async throws {
        let status = p.decision == .holdForMorning ? "dropped_quiet" : "queued"
        let next = now.addingTimeInterval(wait)
        try await conn.query("""
            INSERT INTO ntf.delivery (kind, account_id, channel, target, incident_id, dedup_key, payload, status, next_attempt_at)
            VALUES (\(p.kind.rawValue), \(UUID(uuidString: p.accountID)), 'telegram', \(String(p.chatID)), \(incident),
                    \(p.dedupKey), \(payload.json)::jsonb, \(status), \(next))
            ON CONFLICT (dedup_key) DO NOTHING
            """, logger: logger)
    }

    /// Called for every fired / reminder / resolved event with its incident.
    public static func enqueue(_ conn: PostgresConnection, kind: AlertEvent.Kind, incidentID: UUID, now: Date,
                               logger: Logger) async throws {
        guard kind != .info, let (incident, reminders) = try await self.incident(conn, incidentID, logger: logger) else { return }
        var recipients = try await self.recipients(conn, type: incident.objectType, object: UUID(uuidString: incident.objectID ?? ""),
                                                   logger: logger)
        guard !recipients.isEmpty else { return }
        let acks = try await self.acks(conn, incidentID, logger: logger)

        if incident.key == "down" && incident.objectType == "server" {
            if try await massOutage(conn, recipients: recipients, now: now, logger: logger) { return }
        }

        switch kind {
        case .fired:
            for p in Notify.plan(.fired, incident, recipients: recipients, acks: acks, now: now) {
                try await insert(conn, p, incident: incidentID,
                                 payload: DeliveryPayload(message: p.message, bundle: incident.clientID ?? incident.objectID,
                                                          incident: incident),
                                 now: now, wait: bundleWait, logger: logger)
            }
        case .reminder:
            for p in Notify.plan(.reminder, incident, recipients: recipients, acks: acks, reminder: reminders - 1, now: now) {
                try await insert(conn, p, incident: incidentID, payload: DeliveryPayload(message: p.message), now: now, logger: logger)
            }
        case .resolved:
            // Only those who heard about it hear that it is over.
            let told = try await self.told(conn, incidentID, logger: logger)
            recipients = recipients.filter { told.contains($0.accountID) }
            for p in Notify.plan(.resolved, incident, recipients: recipients, acks: acks, now: now) {
                try await insert(conn, p, incident: incidentID, payload: DeliveryPayload(message: p.message, reply: true),
                                 now: now, logger: logger)
                var edit = p
                edit.dedupKey = "closed:\(incident.id):\(p.accountID)"
                edit.decision = .send
                try await insert(conn, edit, incident: incidentID,
                                 payload: DeliveryPayload(message: TelegramText.closed(incident), edit: true), now: now, logger: logger)
            }
        case .info:
            break
        }
    }

    // MARK: Mass outage

    /// More than half the servers down at once: one message instead of one per
    /// server. When it clears, the servers that are still down are reported
    /// one by one. Returns true while the outage lasts (skip this event).
    static func massOutage(_ conn: PostgresConnection, recipients: [NotifyRecipient], now: Date, logger: Logger) async throws -> Bool {
        let total = Int(try await conn.scalar("""
            SELECT count(*) FROM inv.server WHERE archived_at IS NULL AND NOT paused
            """, as: Int64.self, logger: logger) ?? 0)
        let down = Int(try await conn.scalar("""
            SELECT count(*) FROM ops.incident WHERE object_type = 'server' AND key = 'down' AND ended_at IS NULL
            """, as: Int64.self, logger: logger) ?? 0)
        let was = try await conn.scalar("SELECT value::text FROM sys.kv WHERE key = \(massKey)", as: String.self, logger: logger) != nil
        let now_ = Notify.massOutage(down: down, total: total)
        if now_ && !was {
            try await conn.query("""
                INSERT INTO sys.kv (key, value) VALUES (\(massKey), \("{\"since\":\(Int(now.timeIntervalSince1970))}")::jsonb)
                ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now()
                """, logger: logger)
            let m = TelegramText.massOutage(down: down, total: total)
            for r in recipients {
                guard let chat = r.chatID else { continue }
                let p = Notify.Planned(accountID: r.accountID, chatID: chat, kind: .service, incidentIDs: [],
                                       dedupKey: "mass:\(Int(now.timeIntervalSince1970)):\(r.accountID)", decision: .send, message: m)
                try await insert(conn, p, incident: nil, payload: DeliveryPayload(message: m), now: now, logger: logger)
            }
        } else if !now_ && was {
            try await conn.query("DELETE FROM sys.kv WHERE key = \(massKey)", logger: logger)
            let m = TelegramText.massOutageOver(total: total)
            for r in recipients {
                guard let chat = r.chatID else { continue }
                let p = Notify.Planned(accountID: r.accountID, chatID: chat, kind: .service, incidentIDs: [],
                                       dedupKey: "mass-over:\(Int(now.timeIntervalSince1970)):\(r.accountID)", decision: .send, message: m)
                try await insert(conn, p, incident: nil, payload: DeliveryPayload(message: m), now: now, logger: logger)
            }
            // Servers that stay down are real problems: report them now.
            var left: [UUID] = []
            for try await i in try await conn.query("""
                SELECT i.id FROM ops.incident i WHERE i.object_type = 'server' AND i.key = 'down' AND i.ended_at IS NULL
                  AND NOT EXISTS (SELECT 1 FROM ntf.delivery d WHERE d.incident_id = i.id)
                """, logger: logger).decode(UUID.self) { left.append(i) }
            for i in left { try await enqueue(conn, kind: .fired, incidentID: i, now: now, logger: logger) }
        }
        return now_
    }

    // MARK: Jobs (once a minute)

    /// Critical problems nobody took for 15 minutes → the general admin.
    public static func escalate(_ db: Database, now: Date) async throws {
        try await db.transaction { conn in
            let logger = db.logger
            var open: [UUID] = []
            for try await i in try await conn.query("""
                SELECT i.id FROM ops.incident i
                WHERE i.ended_at IS NULL AND i.severity = 2 AND i.started_at <= \(now.addingTimeInterval(-Notify.escalateAfter))
                  AND NOT EXISTS (SELECT 1 FROM ops.incident_ack k WHERE k.incident_id = i.id)
                  AND NOT EXISTS (SELECT 1 FROM ntf.delivery d WHERE d.incident_id = i.id AND d.kind = 'escalation')
                  AND NOT EXISTS (SELECT 1 FROM sys.kv WHERE key = \(massKey))
                """, logger: logger).decode(UUID.self) { open.append(i) }
            for iid in open {
                guard let (incident, _) = try await self.incident(conn, iid, logger: logger) else { continue }
                var notified: [String] = []
                for try await n in try await conn.query("""
                    SELECT DISTINCT a.display_name FROM ntf.delivery d JOIN acc.account a ON a.id = d.account_id
                    WHERE d.incident_id = \(iid) AND d.status = 'sent' AND a.kind <> 'owner' ORDER BY 1
                    """, logger: logger).decode(String.self) { notified.append(n) }
                let owners = try await recipients(conn, type: incident.objectType,
                                                  object: UUID(uuidString: incident.objectID ?? ""), logger: logger).filter(\.isOwner)
                let open = Notify.OpenIncident(incident: incident, acks: [], escalated: false, notified: notified)
                guard !Notify.escalations([open], now: now).isEmpty else { continue }
                for p in Notify.plan(.escalation, incident, recipients: owners, notified: notified, now: now) {
                    try await insert(conn, p, incident: iid, payload: DeliveryPayload(message: p.message), now: now, logger: logger)
                }
            }
        }
    }

    /// The morning «Прогноз» for each person at their digest time (within three
    /// hours of it), once a day: open forecasts and what was kept from the
    /// quiet hours.
    public static func digests(_ db: Database, now: Date) async throws {
        try await db.transaction { conn in
            let logger = db.logger
            var people: [(UUID, Int64, NotifyPrefs)] = []
            for try await (aid, chat, tz, at) in try await conn.query("""
                SELECT a.id, tl.chat_id,
                       coalesce(p.timezone, (SELECT value #>> '{}' FROM acc.preference
                                             WHERE account_id = a.id AND key = 'timezone'), 'Europe/Moscow'),
                       coalesce(extract(hour FROM p.digest_time) * 60 + extract(minute FROM p.digest_time), 540)::int4
                FROM acc.account a
                JOIN ntf.telegram_link tl ON tl.account_id = a.id AND tl.unlinked_at IS NULL AND NOT tl.blocked_bot
                LEFT JOIN ntf.prefs p ON p.account_id = a.id
                WHERE a.status = 'active' AND coalesce(p.digest_enabled, true)
                  AND coalesce('telegram' = ANY (p.channels), true)
                """, logger: logger).decode((UUID, Int64, String, Int32).self) {
                people.append((aid, chat, NotifyPrefs(timeZone: TimeZone(identifier: tz) ?? NotifyPrefs.defaults.timeZone,
                                                      digestTime: Int(at))))
            }
            for (aid, chat, prefs) in people {
                guard let day = digestDay(prefs, now: now) else { continue }
                let key = "digest:\(day):\(id(aid)!)"
                if try await conn.scalar("SELECT 1::int4 FROM ntf.delivery WHERE dedup_key = \(key)", as: Int32.self,
                                         logger: logger) != nil { continue }
                let since = now.addingTimeInterval(-24 * 3600)
                var night: [NotifyIncident] = []
                var held: [UUID] = []
                for try await i in try await conn.query("""
                    SELECT DISTINCT incident_id FROM ntf.delivery
                    WHERE account_id = \(aid) AND status = 'dropped_quiet' AND incident_id IS NOT NULL AND queued_at >= \(since)
                    """, logger: logger).decode(UUID.self) { held.append(i) }
                for i in held { if let (inc, _) = try await incident(conn, i, logger: logger) { night.append(inc) } }
                var forecast: [String] = []
                for try await line in try await conn.query("""
                    SELECT f.line FROM ops.forecast f
                    WHERE f.status = 'open'
                      AND acc.permission_mode(\(aid), 'alerts_receive', f.object_type, f.object_id) = 'allow'
                    ORDER BY f.due_at NULLS LAST, f.line
                    """, logger: logger).decode(String.self) { forecast.append(line) }
                guard let m = TelegramText.digest(forecast: forecast, night: night, tz: prefs.timeZone) else { continue }
                let p = Notify.Planned(accountID: id(aid)!, chatID: chat, kind: .digest, incidentIDs: [], dedupKey: key,
                                       decision: .send, message: m)
                try await insert(conn, p, incident: nil, payload: DeliveryPayload(message: m), now: now, logger: logger)
            }
        }
    }

    /// "2026-10-11" while it is digest time in the person's zone, else nil.
    static func digestDay(_ p: NotifyPrefs, now: Date) -> String? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = p.timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        guard minute >= p.digestTime, minute < p.digestTime + 180 else { return nil }
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
