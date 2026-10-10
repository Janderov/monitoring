import Foundation
import HubCore
import Logging
import PostgresNIO

/// Personal settings (theme, density, start page…) on top of the owner's
/// defaults; a default the owner locked cannot be changed by staff. Plus the
/// installation's own settings and the notification preferences.
public struct Preferences: Sendable {
    public let accounts: Accounts
    var db: Database { accounts.db }
    var audit: Audit { accounts.audit }
    var logger: Logger { db.logger }

    public init(accounts: Accounts) { self.accounts = accounts }

    /// The keys the cabinet knows and what values they take; nil = any JSON.
    public static let known: [String: [String]?] = [
        "theme": ["system", "light", "dark"],
        "accent": ["system", "blue", "green", "orange", "graphite", "purple"],
        "density": ["compact", "normal"],
        "font_size": ["small", "normal", "large"],
        "start_page": ["overview", "problems", "events", "staff", "audit"],
        "locale": ["ru", "en"],
        "timezone": nil,
        "time_format": ["24h", "12h"],
        "date_format": ["dd.mm.yyyy", "yyyy-mm-dd"],
        "units_traffic": ["bits", "bytes"],
        "chart_default_period": ["1h", "6h", "24h", "7d", "30d"],
        "map_mode_default": nil,
        "map_layers_default": nil,
        "pinned_objects": nil,
        "saved_filters": nil,
        "sidebar_order": nil,
        "sound": ["on", "off"],
        "reduce_motion": nil,
    ]

    static func check(_ key: String, _ value: String) throws {
        let base = key.hasPrefix("table_columns.") ? "table_columns" : key
        guard base == "table_columns" || Self.known.keys.contains(base) else {
            throw AccountError.badRequest("Неизвестная настройка \(key)")
        }
        guard value.utf8.count <= 4096, (try? JSONSerialization.jsonObject(with: Data(value.utf8),
                                                                          options: .fragmentsAllowed)) != nil else {
            throw AccountError.badRequest("Неверное значение настройки \(key)")
        }
        if case let .some(.some(allowed)) = Self.known[base] {
            guard allowed.map(JSON.string).contains(value) else {
                throw AccountError.badRequest("Настройка \(key) принимает: \(allowed.joined(separator: ", "))")
            }
        }
    }

    /// {"values": {...merged...}, "defaults": {...}, "locked": [...], "mine": {...}}
    public func json(for account: Account) async throws -> String {
        try await db.scalar("""
            SELECT json_build_object(
              'defaults', coalesce((SELECT json_object_agg(key, value) FROM acc.default_preference), '{}'),
              'locked', coalesce((SELECT json_agg(key) FROM acc.default_preference WHERE locked), '[]'),
              'mine', coalesce((SELECT json_object_agg(key, value) FROM acc.preference WHERE account_id = \(account.id)), '{}'),
              'values', coalesce((
                 SELECT json_object_agg(k, v) FROM (
                   SELECT d.key AS k, CASE WHEN d.locked OR p.value IS NULL THEN d.value ELSE p.value END AS v
                   FROM acc.default_preference d
                   LEFT JOIN acc.preference p ON p.key = d.key AND p.account_id = \(account.id)
                   UNION ALL
                   SELECT p.key, p.value FROM acc.preference p
                   WHERE p.account_id = \(account.id)
                     AND NOT EXISTS (SELECT 1 FROM acc.default_preference d WHERE d.key = p.key)) x), '{}'))::text
            """, as: String.self) ?? "{}"
    }

    /// Saves some of a person's own settings; a JSON null removes one (back to the default).
    public func set(_ actor: Actor, _ values: [String: String?]) async throws {
        guard let a = actor.account else { throw AccountError.unauthorized("Войдите заново") }
        for (k, v) in values { if let v { try Self.check(k, v) } }
        var locked = Set<String>()
        for try await k in try await db.query("SELECT key FROM acc.default_preference WHERE locked").decode(String.self) {
            locked.insert(k)
        }
        if !a.isOwner, let k = values.keys.first(where: locked.contains) {
            throw AccountError.forbidden("Настройку «\(k)» закрепил владелец")
        }
        try await db.transaction { conn in
            for (k, v) in values {
                if let v {
                    try await conn.query("""
                        INSERT INTO acc.preference (account_id, key, value) VALUES (\(a.id), \(k), \(v)::jsonb)
                        ON CONFLICT (account_id, key) DO UPDATE SET value = EXCLUDED.value, updated_at = now()
                        """, logger: logger)
                } else {
                    try await conn.query("DELETE FROM acc.preference WHERE account_id = \(a.id) AND key = \(k)",
                                         logger: logger)
                }
            }
        }
    }

    public struct Default: Codable, Sendable {
        public var value: String
        public var locked: Bool
    }

    /// The owner's defaults for everyone, and which of them staff cannot change.
    public func setDefaults(_ actor: Actor, _ values: [String: Default?]) async throws {
        guard actor.account?.isOwner == true else { throw AccountError.forbidden("Это может только владелец") }
        for (k, v) in values { if let v { try Self.check(k, v.value) } }
        try await db.transaction { conn in
            for (k, v) in values {
                if let v {
                    try await conn.query("""
                        INSERT INTO acc.default_preference (key, value, locked) VALUES (\(k), \(v.value)::jsonb, \(v.locked))
                        ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, locked = EXCLUDED.locked, updated_at = now()
                        """, logger: logger)
                } else {
                    try await conn.query("DELETE FROM acc.default_preference WHERE key = \(k)", logger: logger)
                }
            }
            try await audit.write(.init("defaults_changed", objectType: "app",
                                        detail: values.mapValues { $0.map { "\($0.value)\($0.locked ? " 🔒" : "")" } ?? "—" }),
                                  by: actor, on: conn)
        }
    }

    // MARK: The installation

    public func orgJSON() async throws -> String {
        try await db.scalar("""
            SELECT json_build_object('company_name', company_name, 'brand_color', brand_color,
                'report_footer', report_footer, 'contact_email', contact_email, 'contact_phone', contact_phone,
                'default_timezone', default_timezone, 'default_locale', default_locale, 'require_mfa', require_mfa,
                'session_timeout_minutes', session_timeout_minutes, 'logo_file_id', logo_file_id,
                'updated_at', updated_at)::text
            FROM sys.org_settings
            """, as: String.self) ?? "{}"
    }

    public struct Org: Codable, Sendable {
        public var companyName: String?
        public var brandColor: String?
        public var reportFooter: String?
        public var contactEmail: String?
        public var contactPhone: String?
        public var defaultTimezone: String?
        public var sessionTimeoutMinutes: Int?

        enum CodingKeys: String, CodingKey {
            case companyName = "company_name", brandColor = "brand_color", reportFooter = "report_footer"
            case contactEmail = "contact_email", contactPhone = "contact_phone"
            case defaultTimezone = "default_timezone", sessionTimeoutMinutes = "session_timeout_minutes"
        }
    }

    public func setOrg(_ actor: Actor, _ o: Org) async throws {
        guard actor.account?.isOwner == true else { throw AccountError.forbidden("Это может только владелец") }
        if let c = o.brandColor, !c.isEmpty, c.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) == nil {
            throw AccountError.badRequest("Цвет укажите как #RRGGBB")
        }
        if let m = o.sessionTimeoutMinutes, !(15...10080).contains(m) {
            throw AccountError.badRequest("Выход после бездействия: от 15 минут до 7 дней")
        }
        if let tz = o.defaultTimezone, TimeZone(identifier: tz) == nil {
            throw AccountError.badRequest("Неизвестный часовой пояс \(tz)")
        }
        try await db.query("""
            UPDATE sys.org_settings SET
              company_name = coalesce(\(o.companyName), company_name),
              brand_color = CASE WHEN \(o.brandColor)::text IS NULL THEN brand_color ELSE nullif(\(o.brandColor), '') END,
              report_footer = coalesce(\(o.reportFooter), report_footer),
              contact_email = CASE WHEN \(o.contactEmail)::text IS NULL THEN contact_email ELSE nullif(\(o.contactEmail), '') END,
              contact_phone = CASE WHEN \(o.contactPhone)::text IS NULL THEN contact_phone ELSE nullif(\(o.contactPhone), '') END,
              default_timezone = coalesce(\(o.defaultTimezone), default_timezone),
              session_timeout_minutes = coalesce(\(o.sessionTimeoutMinutes), session_timeout_minutes),
              updated_at = now(), updated_by = \(actor.account!.id)
            """)
        var detail: [String: String] = [:]
        if let v = o.companyName { detail["company_name"] = v }
        if let v = o.sessionTimeoutMinutes { detail["session_timeout_minutes"] = String(v) }
        await audit.write(.init("org_settings_changed", objectType: "app", detail: detail), by: actor)
    }

    // MARK: Notifications (ntf.prefs)

    public func notifyJSON(for account: Account) async throws -> String {
        try await db.scalar("""
            SELECT json_build_object('min_severity', coalesce(p.min_severity, 1), 'timezone', p.timezone,
                'quiet_from', to_char(p.quiet_from, 'HH24:MI'), 'quiet_to', to_char(p.quiet_to, 'HH24:MI'),
                'quiet_days', coalesce(p.quiet_days, '{1,2,3,4,5,6,7}'),
                'critical_in_quiet', coalesce(p.critical_in_quiet, true), 'on_duty_only', coalesce(p.on_duty_only, false),
                'digest_enabled', coalesce(p.digest_enabled, true),
                'digest_time', to_char(coalesce(p.digest_time, '09:00'), 'HH24:MI'),
                'channels', coalesce(p.channels, '{telegram,macos}'))::text
            FROM (SELECT 1) one LEFT JOIN ntf.prefs p ON p.account_id = \(account.id)
            """, as: String.self) ?? "{}"
    }

    public struct Notify: Codable, Sendable {
        public var minSeverity: Int?
        public var quietFrom: String?
        public var quietTo: String?
        public var quietDays: [Int]?
        public var criticalInQuiet: Bool?
        public var onDutyOnly: Bool?
        public var digestEnabled: Bool?
        public var digestTime: String?
        public var channels: [String]?

        enum CodingKeys: String, CodingKey {
            case minSeverity = "min_severity", quietFrom = "quiet_from", quietTo = "quiet_to", quietDays = "quiet_days"
            case criticalInQuiet = "critical_in_quiet", onDutyOnly = "on_duty_only", digestEnabled = "digest_enabled"
            case digestTime = "digest_time", channels
        }
    }

    static func time(_ s: String?) throws -> String? {
        guard let s, !s.isEmpty else { return nil }
        guard s.range(of: "^([01][0-9]|2[0-3]):[0-5][0-9]$", options: .regularExpression) != nil else {
            throw AccountError.badRequest("Время укажите как ЧЧ:ММ")
        }
        return s
    }

    public func setNotify(_ actor: Actor, _ n: Notify) async throws {
        guard let a = actor.account else { throw AccountError.unauthorized("Войдите заново") }
        if let s = n.minSeverity, ![1, 2].contains(s) { throw AccountError.badRequest("Важность: 1 или 2") }
        if let d = n.quietDays, d.contains(where: { !(1...7).contains($0) }) { throw AccountError.badRequest("Дни недели: 1–7") }
        if let c = n.channels, c.contains(where: { !["telegram", "macos", "email", "push"].contains($0) }) {
            throw AccountError.badRequest("Неизвестный канал")
        }
        let qf = try Self.time(n.quietFrom), qt = try Self.time(n.quietTo), dt = try Self.time(n.digestTime)
        // Empty strings clear the quiet hours.
        let clearQuiet = n.quietFrom == "" || n.quietTo == ""
        try await db.query("""
            INSERT INTO ntf.prefs (account_id) VALUES (\(a.id)) ON CONFLICT (account_id) DO NOTHING
            """)
        try await db.query("""
            UPDATE ntf.prefs SET
              min_severity = coalesce(\(n.minSeverity), min_severity),
              quiet_from = CASE WHEN \(clearQuiet) THEN NULL ELSE coalesce(\(qf)::time, quiet_from) END,
              quiet_to = CASE WHEN \(clearQuiet) THEN NULL ELSE coalesce(\(qt)::time, quiet_to) END,
              quiet_days = coalesce(\(n.quietDays.map { $0.map(Int16.init) })::smallint[], quiet_days),
              critical_in_quiet = coalesce(\(n.criticalInQuiet), critical_in_quiet),
              on_duty_only = coalesce(\(n.onDutyOnly), on_duty_only),
              digest_enabled = coalesce(\(n.digestEnabled), digest_enabled),
              digest_time = coalesce(\(dt)::time, digest_time),
              channels = coalesce(\(n.channels)::text[], channels)
            WHERE account_id = \(a.id)
            """)
    }
}
