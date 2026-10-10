import Foundation
import HubCore
import Logging
import NIOCore
import PostgresNIO

/// The owner's (and managers') side: people, their invites, turning access
/// off and on, starting a lost login over.
public struct Staff: Sendable {
    public let access: Access
    var accounts: Accounts { access.accounts }
    var db: Database { access.db }
    var audit: Audit { accounts.audit }
    var logger: Logger { db.logger }

    public init(access: Access) { self.access = access }

    /// manage_staff is danger level 2: every change asks for a fresh code.
    func authorize(_ actor: Actor, code: String?, target: Account? = nil) async throws {
        guard let me = actor.account else { throw AccountError.unauthorized("Войдите заново") }
        if let t = target {
            if t.isOwner && !me.isOwner { throw AccountError.forbidden("Владельца меняет только он сам") }
            if t.id == me.id && !me.isOwner { throw AccountError.forbidden("Свои права и доступ меняет только владелец") }
        }
        let decision = try await access.authorize(actor, "manage_staff", on: .init(type: "account", id: target?.id,
                                                                                   name: target?.login ?? ""),
                                                  code: code)
        guard decision == .allowed else {
            throw AccountError.forbidden("Запрос отправлен владельцу: изменения сотрудников — по согласованию")
        }
    }

    /// The same check as every staff change, for changes made elsewhere (a person's SSH key).
    public func authorizeChange(_ actor: Actor, target id: UUID, code: String?) async throws {
        try await authorize(actor, code: code, target: try await load(id))
    }

    public func canManage(_ actor: Actor) async throws -> Bool {
        guard let me = actor.account else { return false }
        return try await access.mode(me, "manage_staff") != .deny
    }

    public func listJSON() async throws -> String {
        try await db.scalar("""
            SELECT coalesce(json_agg(json_build_object(
                'id', a.id, 'login', a.login, 'display_name', a.display_name, 'email', a.email, 'kind', a.kind,
                'status', a.status, 'access_expires_at', a.access_expires_at, 'note', a.note,
                'created_at', a.created_at, 'last_login_at', a.last_login_at, 'disabled_at', a.disabled_at,
                'last_seen', (SELECT json_build_object('at', s.last_seen_at, 'device', s.device_name)
                              FROM acc.session s WHERE s.account_id = a.id ORDER BY s.last_seen_at DESC LIMIT 1),
                'sessions', (SELECT count(*) FROM acc.session s WHERE s.account_id = a.id AND s.revoked_at IS NULL
                               AND s.expires_at > now()),
                'mfa', EXISTS (SELECT 1 FROM acc.account_mfa m WHERE m.account_id = a.id AND m.confirmed_at IS NOT NULL),
                'invite_expires_at', (SELECT max(expires_at) FROM acc.invite i WHERE i.account_id = a.id
                                        AND i.used_at IS NULL),
                'roles', (SELECT coalesce(json_agg(DISTINCT t.name), '[]') FROM acc.access_grant g
                          JOIN acc.role_template t ON t.id = g.template_id WHERE g.account_id = a.id),
                'scopes', (SELECT coalesce(json_agg(CASE g.scope_type
                              WHEN 'all' THEN 'Все объекты'
                              WHEN 'client' THEN (SELECT name FROM inv.client WHERE id = g.scope_id)
                              WHEN 'server' THEN (SELECT name FROM inv.server WHERE id = g.scope_id)
                              WHEN 'site' THEN (SELECT name FROM inv.site WHERE id = g.scope_id) END
                            ORDER BY g.scope_type), '[]')
                           FROM acc.access_grant g WHERE g.account_id = a.id))
              ORDER BY a.kind = 'owner' DESC, a.status = 'disabled', a.display_name), '[]')::text
            FROM acc.account a
            """, as: String.self) ?? "[]"
    }

    public func detailJSON(_ id: UUID) async throws -> String {
        guard let row = try await db.scalar("""
            SELECT json_build_object(
                'id', a.id, 'login', a.login, 'display_name', a.display_name, 'email', a.email, 'kind', a.kind,
                'status', a.status, 'access_expires_at', a.access_expires_at, 'note', a.note,
                'created_at', a.created_at, 'last_login_at', a.last_login_at,
                'created_by', (SELECT display_name FROM acc.account WHERE id = a.created_by),
                'mfa', EXISTS (SELECT 1 FROM acc.account_mfa m WHERE m.account_id = a.id AND m.confirmed_at IS NOT NULL),
                'invite_expires_at', (SELECT max(expires_at) FROM acc.invite i WHERE i.account_id = a.id
                                        AND i.used_at IS NULL))::text
            FROM acc.account a WHERE a.id = \(id)
            """, as: String.self) else { throw AccountError.notFound("Сотрудник не найден") }
        let grants = try await access.grantsJSON(id)
        let sessions = try await accounts.sessionsJSON(id, current: nil)
        let keys = try await SSHKeys.listJSON(db, account: id)
        return "{\"account\":\(row),\"grants\":\(grants),\"sessions\":\(sessions),\"ssh_keys\":\(keys)}"
    }

    public struct NewPerson: Codable, Sendable {
        public var login: String
        public var displayName: String
        public var email: String?
        public var note: String?
        public var accessExpiresAt: Date?
        public var grants: [Access.GrantInput]

        public init(login: String, displayName: String, email: String? = nil, note: String? = nil,
                    accessExpiresAt: Date? = nil, grants: [Access.GrantInput]) {
            self.login = login; self.displayName = displayName; self.email = email; self.note = note
            self.accessExpiresAt = accessExpiresAt; self.grants = grants
        }

        enum CodingKeys: String, CodingKey {
            case login, displayName = "display_name", email, note, accessExpiresAt = "access_expires_at", grants
        }
    }

    static func validLogin(_ s: String) -> Bool {
        let ok = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        return (3...32).contains(s.count) && s.lowercased().unicodeScalars.allSatisfy { ok.contains($0) }
    }

    /// Creates the person (not active until they follow the link) with their
    /// grants, and returns the invite token for the link.
    public func create(_ actor: Actor, _ p: NewPerson, code: String?) async throws -> (id: UUID, token: String) {
        let login = p.login.trimmingCharacters(in: .whitespaces).lowercased()
        let name = p.displayName.trimmingCharacters(in: .whitespaces)
        guard Self.validLogin(login) else {
            throw AccountError.badRequest("Логин: 3–32 латинские буквы, цифры, точка, дефис или подчёркивание")
        }
        guard !name.isEmpty else { throw AccountError.badRequest("Укажите имя") }
        if let e = p.accessExpiresAt, e <= accounts.now() { throw AccountError.badRequest("Дата «доступ до» уже прошла") }
        try await authorize(actor, code: code)
        if try await accounts.account(login: login) != nil { throw AccountError.conflict("Логин \(login) уже занят") }
        let id = try await db.transaction { conn -> UUID in
            let id = try await conn.one("""
                INSERT INTO acc.account (login, display_name, email, kind, status, access_expires_at, note, created_by)
                VALUES (\(login)::citext, \(name), \(p.email)::citext, 'staff', 'invited', \(p.accessExpiresAt),
                        \(p.note ?? ""), \(actor.account!.id))
                RETURNING id
                """, as: UUID.self)!
            try await audit.write(.init("staff_created", objectType: "account", objectID: id, objectName: login,
                                        detail: ["name": name]), by: actor, on: conn)
            return id
        }
        let target = Account(id: id, login: login, displayName: name, kind: .staff, status: .invited,
                             accessExpiresAt: p.accessExpiresAt)
        do {
            try await access.setGrants(actor, account: target, p.grants)
        } catch {
            try? await db.query("DELETE FROM acc.account WHERE id = \(id) AND status = 'invited'")
            throw error
        }
        let token = try await db.transaction { conn in try await accounts.newInvite(for: id, by: actor, conn: conn) }
        return (id, token)
    }

    func load(_ id: UUID) async throws -> Account {
        guard let a = try await accounts.account(id) else { throw AccountError.notFound("Сотрудник не найден") }
        return a
    }

    public struct Changes: Codable, Sendable {
        public var displayName: String?
        public var email: String?
        public var note: String?
        /// Send an empty string to make access unlimited.
        public var accessExpiresAt: String?

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name", email, note, accessExpiresAt = "access_expires_at"
        }
    }

    public func update(_ actor: Actor, id: UUID, _ c: Changes, code: String?) async throws {
        let target = try await load(id)
        try await authorize(actor, code: code, target: target)
        var expires: Date?? = nil
        if let s = c.accessExpiresAt {
            if s.isEmpty { expires = .some(nil) } else {
                guard let d = JSON.parseDate(s) else { throw AccountError.badRequest("Не понял дату «доступ до»") }
                expires = .some(d)
            }
        }
        try await db.transaction { conn in
            try await conn.query("""
                UPDATE acc.account SET
                  display_name = coalesce(nullif(\(c.displayName), ''), display_name),
                  email = CASE WHEN \(c.email)::text IS NULL THEN email ELSE nullif(\(c.email), '')::citext END,
                  note = coalesce(\(c.note), note),
                  access_expires_at = CASE WHEN \(expires != nil) THEN \(expires ?? nil) ELSE access_expires_at END
                WHERE id = \(id)
                """, logger: logger)
            var detail: [String: String] = [:]
            if let n = c.displayName { detail["name"] = n }
            if let e = expires { detail["access_expires_at"] = e.map { ISO8601DateFormatter().string(from: $0) } ?? "без срока" }
            try await audit.write(.init("staff_changed", objectType: "account", objectID: id, objectName: target.login,
                                        detail: detail), by: actor, on: conn)
            try await SSHKeys.sync(account: id, conn: conn)
        }
    }

    public func setGrants(_ actor: Actor, id: UUID, _ grants: [Access.GrantInput], code: String?) async throws {
        let target = try await load(id)
        try await authorize(actor, code: code, target: target)
        try await access.setGrants(actor, account: target, grants)
    }

    /// Off at once: sessions end, SSH keys are queued for removal from every
    /// server. VPN keys the person made stay.
    public func disable(_ actor: Actor, id: UUID, code: String?) async throws {
        let target = try await load(id)
        guard !target.isOwner else { throw AccountError.badRequest("Владельца отключить нельзя") }
        try await authorize(actor, code: code, target: target)
        try await db.transaction { conn in
            try await conn.query("""
                UPDATE acc.account SET status = 'disabled', disabled_at = now(), disabled_by = \(actor.account!.id)
                WHERE id = \(id)
                """, logger: logger)
            try await conn.query("UPDATE acc.session SET revoked_at = now() WHERE account_id = \(id) AND revoked_at IS NULL",
                                 logger: logger)
            try await conn.query("UPDATE acc.invite SET used_at = now() WHERE account_id = \(id) AND used_at IS NULL",
                                 logger: logger)
            try await conn.query("""
                UPDATE acc.approval_request SET status = 'rejected', decided_at = now(), decided_by = \(actor.account!.id)
                WHERE requested_by = \(id) AND status = 'pending'
                """, logger: logger)
            try await SSHKeys.sync(account: id, conn: conn)
            try await audit.write(.init("staff_disabled", objectType: "account", objectID: id, objectName: target.login),
                                  by: actor, on: conn)
        }
    }

    /// Back on. If the person never finished signing up, a new link is made.
    public func enable(_ actor: Actor, id: UUID, code: String?) async throws -> String? {
        let target = try await load(id)
        try await authorize(actor, code: code, target: target)
        return try await db.transaction { conn in
            let hasLogin = try await conn.one("""
                SELECT 1 FROM acc.account_mfa WHERE account_id = \(id) AND confirmed_at IS NOT NULL LIMIT 1
                """, as: Int.self) != nil
            try await conn.query("""
                UPDATE acc.account SET status = \(hasLogin ? "active" : "invited"), disabled_at = NULL, disabled_by = NULL
                WHERE id = \(id)
                """, logger: logger)
            try await SSHKeys.sync(account: id, conn: conn)
            try await audit.write(.init("staff_enabled", objectType: "account", objectID: id, objectName: target.login),
                                  by: actor, on: conn)
            return hasLogin ? nil : try await accounts.newInvite(for: id, by: actor, conn: conn)
        }
    }

    /// Lost phone or forgotten password: the old login stops working and the
    /// person signs up again by a new link (grants stay).
    public func resetLogin(_ actor: Actor, id: UUID, code: String?) async throws -> String {
        let target = try await load(id)
        guard !target.isOwner else {
            throw AccountError.badRequest("Вход владельца сбрасывается на сервере: monitor-hub owner-invite --reset")
        }
        guard target.status != .disabled else { throw AccountError.badRequest("Сначала включите доступ") }
        try await authorize(actor, code: code, target: target)
        return try await db.transaction { conn in
            try await Accounts.wipeLogin(id, conn: conn, logger: logger)
            try await conn.query("UPDATE acc.account SET status = 'invited' WHERE id = \(id)", logger: logger)
            try await SSHKeys.sync(account: id, conn: conn)
            try await audit.write(.init("login_reset", objectType: "account", objectID: id, objectName: target.login),
                                  by: actor, on: conn)
            return try await accounts.newInvite(for: id, by: actor, conn: conn)
        }
    }

    /// A fresh link for someone who has not signed up yet (the old one stops).
    public func reinvite(_ actor: Actor, id: UUID, code: String?) async throws -> String {
        let target = try await load(id)
        guard target.status == .invited else { throw AccountError.badRequest("Человек уже зарегистрирован") }
        try await authorize(actor, code: code, target: target)
        return try await db.transaction { conn in
            let token = try await accounts.newInvite(for: id, by: actor, conn: conn)
            try await audit.write(.init("invite_renewed", objectType: "account", objectID: id, objectName: target.login),
                                  by: actor, on: conn)
            return token
        }
    }

    public func revokeSessions(_ actor: Actor, id: UUID, code: String?) async throws {
        let target = try await load(id)
        try await authorize(actor, code: code, target: target)
        try await db.query("UPDATE acc.session SET revoked_at = now() WHERE account_id = \(id) AND revoked_at IS NULL")
        await audit.write(.init("sessions_revoked", objectType: "account", objectID: id, objectName: target.login),
                          by: actor)
    }
}
