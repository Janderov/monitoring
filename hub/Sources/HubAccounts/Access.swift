import Foundation
import HubCore
import Logging
import NIOCore
import PostgresNIO

/// Permissions: the catalog, role templates, grants, the one check every
/// action goes through, and approvals of dangerous actions by the owner.
/// The decision itself is the database's acc.permission_mode(), so the hub,
/// reports and anything later answer the same way.
public struct Access: Sendable {
    public let db: Database
    public let accounts: Accounts
    var audit: Audit { accounts.audit }
    var logger: Logger { db.logger }

    public init(accounts: Accounts) {
        self.accounts = accounts
        self.db = accounts.db
    }

    /// Only the owner gives these: they open everything else.
    public static let ownerOnlyGrants: Set<String> = ["manage_staff", "manage_billing", "view_secrets"]

    // MARK: The check

    public func mode(_ account: Account, _ permission: String, objectType: String = "app",
                     objectID: UUID? = nil) async throws -> PermissionMode {
        if account.isOwner { return account.status == .active ? .allow : .deny }
        let text = try await db.scalar("""
            SELECT acc.permission_mode(\(account.id), \(permission), \(objectType), \(objectID))
            """, as: String.self)
        return text.flatMap(PermissionMode.init(rawValue:)) ?? .deny
    }

    public func danger(_ permission: String) async throws -> Int {
        guard let d = try await db.scalar("SELECT danger_level::int FROM acc.permission WHERE code = \(permission)",
                                          as: Int.self) else {
            throw AccountError.internal("неизвестное право \(permission)")
        }
        return d
    }

    public enum Decision: Sendable, Equatable {
        case allowed
        /// Sent to the owner; the action runs after the owner agrees.
        case waitingForOwner(approvalID: UUID)
    }

    public struct Target: Sendable {
        public var type: String
        public var id: UUID?
        public var name: String
        public init(type: String, id: UUID? = nil, name: String = "") { self.type = type; self.id = id; self.name = name }
        public static let app = Target(type: "app", name: "Хаб")
    }

    /// The gate for every action: refuses, asks for a fresh phone code
    /// (danger level 2), or turns the action into a request to the owner.
    /// Refusals and requests go to the audit log here; the caller logs the
    /// outcome of an allowed action.
    public func authorize(_ actor: Actor, _ permission: String, on target: Target = .app,
                          code: String?, reason: String = "", detail: [String: String] = [:]) async throws -> Decision {
        guard let a = actor.account else { throw AccountError.unauthorized("Войдите заново") }
        let m = try await mode(a, permission, objectType: target.type, objectID: target.id)
        if m == .deny {
            await audit.write(.init(permission, objectType: target.type, objectID: target.id, objectName: target.name,
                                    detail: detail, result: .denied), by: actor)
            throw AccountError.forbidden("Нет прав: \(try await title(permission))")
        }
        if try await danger(permission) >= Danger.stepUpLevel { try await accounts.stepUp(actor, code: code) }
        if m == .approval {
            let id = try await requestApproval(actor, permission, target: target, reason: reason, detail: detail)
            return .waitingForOwner(approvalID: id)
        }
        return .allowed
    }

    func title(_ permission: String) async throws -> String {
        try await db.scalar("SELECT lower(title) FROM acc.permission WHERE code = \(permission)", as: String.self) ?? permission
    }

    // MARK: Catalog and templates

    public func permissionsJSON() async throws -> String {
        try await db.scalar("""
            SELECT json_agg(json_build_object('code', code, 'group', grp, 'title', title, 'danger', danger_level,
                                              'owner_only', code = ANY(\(Array(Self.ownerOnlyGrants))))
                            ORDER BY sort)::text
            FROM acc.permission
            """, as: String.self) ?? "[]"
    }

    public func templatesJSON() async throws -> String {
        try await db.scalar("""
            SELECT coalesce(json_agg(json_build_object(
                'id', t.id, 'name', t.name, 'description', t.description, 'built_in', t.built_in,
                'permissions', coalesce((SELECT json_object_agg(permission_code, mode)
                                         FROM acc.role_template_permission WHERE template_id = t.id), '{}'),
                'used_by', (SELECT count(DISTINCT account_id) FROM acc.access_grant WHERE template_id = t.id))
              ORDER BY t.built_in DESC, t.name), '[]')::text
            FROM acc.role_template t
            """, as: String.self) ?? "[]"
    }

    public struct TemplateInput: Codable, Sendable {
        public var name: String
        public var description: String?
        public var permissions: [String: PermissionMode]
    }

    public func saveTemplate(_ actor: Actor, id: UUID?, _ input: TemplateInput) async throws -> UUID {
        try requireOwner(actor)
        let name = input.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw AccountError.badRequest("Укажите название шаблона") }
        try await checkCodes(Array(input.permissions.keys))
        return try await db.transaction { conn in
            let tid: UUID
            if let id {
                guard let t = try await conn.one("""
                    UPDATE acc.role_template SET name = \(name), description = \(input.description ?? "")
                    WHERE id = \(id) RETURNING id
                    """, as: UUID.self) else { throw AccountError.notFound("Шаблон не найден") }
                tid = t
                try await conn.query("DELETE FROM acc.role_template_permission WHERE template_id = \(tid)", logger: logger)
            } else {
                tid = try await conn.one("""
                    INSERT INTO acc.role_template (name, description, created_by)
                    VALUES (\(name), \(input.description ?? ""), \(actor.account?.id)) RETURNING id
                    """, as: UUID.self)!
            }
            for (code, mode) in input.permissions where mode != .deny {
                try await conn.query("""
                    INSERT INTO acc.role_template_permission (template_id, permission_code, mode)
                    VALUES (\(tid), \(code), \(mode.rawValue))
                    """, logger: logger)
            }
            try await audit.write(.init(id == nil ? "template_created" : "template_changed", objectType: "role_template",
                                        objectID: tid, objectName: name, detail: Self.summary(input.permissions)),
                                  by: actor, on: conn)
            return tid
        }
    }

    public func deleteTemplate(_ actor: Actor, id: UUID) async throws {
        try requireOwner(actor)
        let row = try await db.query("SELECT name, built_in FROM acc.role_template WHERE id = \(id)")
        var found: (String, Bool)?
        for try await r in row.decode((String, Bool).self) { found = r }
        guard let (name, builtIn) = found else { throw AccountError.notFound("Шаблон не найден") }
        guard !builtIn else { throw AccountError.badRequest("Встроенный шаблон нельзя удалить, только изменить") }
        // Grants made from it keep their permissions (template_id becomes null).
        try await db.query("DELETE FROM acc.role_template WHERE id = \(id)")
        await audit.write(.init("template_deleted", objectType: "role_template", objectID: id, objectName: name), by: actor)
    }

    func checkCodes(_ codes: [String]) async throws {
        let known = try await db.query("SELECT code FROM acc.permission")
        var set = Set<String>()
        for try await c in known.decode(String.self) { set.insert(c) }
        if let bad = codes.first(where: { !set.contains($0) }) { throw AccountError.badRequest("Неизвестное право \(bad)") }
    }

    static func summary(_ p: [String: PermissionMode]) -> [String: String] {
        let allow = p.filter { $0.value == .allow }.keys.sorted().joined(separator: ",")
        let approval = p.filter { $0.value == .approval }.keys.sorted().joined(separator: ",")
        return ["allow": allow, "approval": approval]
    }

    func requireOwner(_ actor: Actor) throws {
        guard actor.account?.isOwner == true else { throw AccountError.forbidden("Это может только владелец") }
    }

    // MARK: Grants

    public struct GrantInput: Codable, Sendable, Equatable {
        /// all, client, server, site
        public var scopeType: String
        public var scopeID: UUID?
        public var templateID: UUID?
        public var expiresAt: Date?
        public var permissions: [String: PermissionMode]

        public init(scopeType: String, scopeID: UUID? = nil, templateID: UUID? = nil, expiresAt: Date? = nil,
                    permissions: [String: PermissionMode]) {
            self.scopeType = scopeType; self.scopeID = scopeID; self.templateID = templateID
            self.expiresAt = expiresAt; self.permissions = permissions
        }

        enum CodingKeys: String, CodingKey {
            case scopeType = "scope_type", scopeID = "scope_id", templateID = "template_id"
            case expiresAt = "expires_at", permissions
        }
    }

    /// A person's grants with the scope's name, for the rights screen.
    public func grantsJSON(_ account: UUID) async throws -> String {
        try await db.scalar("""
            SELECT coalesce(json_agg(json_build_object(
                'id', g.id, 'scope_type', g.scope_type, 'scope_id', g.scope_id,
                'scope_name', CASE g.scope_type
                    WHEN 'all' THEN 'Все объекты'
                    WHEN 'client' THEN (SELECT name FROM inv.client WHERE id = g.scope_id)
                    WHEN 'server' THEN (SELECT name FROM inv.server WHERE id = g.scope_id)
                    WHEN 'site' THEN (SELECT name FROM inv.site WHERE id = g.scope_id) END,
                'template_id', g.template_id,
                'template_name', (SELECT name FROM acc.role_template WHERE id = g.template_id),
                'expires_at', g.expires_at,
                'permissions', coalesce((SELECT json_object_agg(permission_code, mode)
                                         FROM acc.grant_permission WHERE grant_id = g.id), '{}'))
              ORDER BY CASE g.scope_type WHEN 'all' THEN 0 WHEN 'client' THEN 1 ELSE 2 END, g.created_at), '[]')::text
            FROM acc.access_grant g WHERE g.account_id = \(account)
            """, as: String.self) ?? "[]"
    }

    /// Replaces all of a person's grants at once (the rights screen saves the
    /// whole picture), checks the scopes exist, and refreshes where the
    /// person's SSH key should be.
    public func setGrants(_ actor: Actor, account target: Account, _ grants: [GrantInput]) async throws {
        guard let me = actor.account else { throw AccountError.unauthorized("Войдите заново") }
        guard !target.isOwner else { throw AccountError.badRequest("У владельца все права, их не настраивают") }
        guard target.id != me.id else { throw AccountError.forbidden("Свои права меняет только владелец") }
        var seen = Set<String>()
        for g in grants {
            guard ["all", "client", "server", "site"].contains(g.scopeType) else {
                throw AccountError.badRequest("Неизвестная область \(g.scopeType)")
            }
            guard (g.scopeType == "all") == (g.scopeID == nil) else { throw AccountError.badRequest("Не выбрана область") }
            guard seen.insert("\(g.scopeType)/\(g.scopeID?.uuidString ?? "")").inserted else {
                throw AccountError.badRequest("Одна и та же область указана дважды")
            }
            try await checkCodes(Array(g.permissions.keys))
            if !me.isOwner, g.permissions.contains(where: { Self.ownerOnlyGrants.contains($0.key) && $0.value != .deny }) {
                throw AccountError.forbidden("Право управлять сотрудниками, деньгами и паролями даёт только владелец")
            }
        }
        try await db.transaction { conn in
            try await conn.query("DELETE FROM acc.access_grant WHERE account_id = \(target.id)", logger: logger)
            for g in grants {
                if let sid = g.scopeID {
                    let table = ["client": "inv.client", "server": "inv.server", "site": "inv.site"][g.scopeType]!
                    guard try await conn.one("SELECT 1 FROM \(unescaped: table) WHERE id = \(sid)", as: Int.self) != nil else {
                        throw AccountError.badRequest("Объект для прав не найден (\(g.scopeType))")
                    }
                }
                let gid = try await conn.one("""
                    INSERT INTO acc.access_grant (account_id, scope_type, scope_id, template_id, created_by, expires_at)
                    VALUES (\(target.id), \(g.scopeType), \(g.scopeID), \(g.templateID), \(me.id), \(g.expiresAt))
                    RETURNING id
                    """, as: UUID.self)!
                for (code, mode) in g.permissions {
                    // "No" at the narrowest level must be stored: it overrides a wider "yes".
                    if mode == .deny && g.scopeType == "all" { continue }
                    try await conn.query("""
                        INSERT INTO acc.grant_permission (grant_id, permission_code, mode)
                        VALUES (\(gid), \(code), \(mode.rawValue))
                        """, logger: logger)
                }
            }
            let text = grants.map { g in "\(g.scopeType)\(g.scopeID.map { ":" + $0.uuidString } ?? ""): "
                + Self.summary(g.permissions).map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; ") }
            try await audit.write(.init("grants_changed", objectType: "account", objectID: target.id,
                                        objectName: target.login, detail: ["grants": text.joined(separator: " | ")]),
                                  by: actor, on: conn)
            try await SSHKeys.sync(account: target.id, conn: conn)
        }
    }

    // MARK: Approvals

    func requestApproval(_ actor: Actor, _ permission: String, target: Target, reason: String,
                         detail: [String: String]) async throws -> UUID {
        guard let a = actor.account else { throw AccountError.unauthorized("Войдите заново") }
        var withReason = detail
        if !target.name.isEmpty { withReason["object_name"] = target.name }
        let id = try await db.scalar("""
            INSERT INTO acc.approval_request (requested_by, permission_code, object_type, object_id, detail, reason,
                                              expires_at)
            VALUES (\(a.id), \(permission), \(target.type), \(target.id), \(JSON.object(withReason))::jsonb, \(reason),
                    \(accounts.now().addingTimeInterval(Lifetimes.approval)))
            RETURNING id
            """, as: UUID.self)!
        await audit.write(.init(permission, objectType: target.type, objectID: target.id, objectName: target.name,
                                detail: detail.merging(["reason": reason]) { a, _ in a }, result: .pending_approval,
                                approvalID: id), by: actor)
        return id
    }

    /// The owner sees every request, others their own.
    public func approvalsJSON(_ actor: Actor, status: String?) async throws -> String {
        guard let a = actor.account else { throw AccountError.unauthorized("Войдите заново") }
        try await db.query("""
            UPDATE acc.approval_request SET status = 'expired' WHERE status = 'pending' AND expires_at <= now()
            """)
        return try await db.scalar("""
            SELECT coalesce(json_agg(json_build_object(
                'id', r.id, 'permission', r.permission_code, 'permission_title', p.title, 'danger', p.danger_level,
                'object_type', r.object_type, 'object_id', r.object_id,
                'object_name', coalesce(r.detail->>'object_name', ''), 'detail', r.detail, 'reason', r.reason,
                'status', r.status, 'created_at', r.created_at, 'expires_at', r.expires_at,
                'requested_by', json_build_object('id', a.id, 'name', a.display_name, 'login', a.login),
                'decided_by', (SELECT display_name FROM acc.account WHERE id = r.decided_by), 'decided_at', r.decided_at)
              ORDER BY r.created_at DESC), '[]')::text
            FROM acc.approval_request r
            JOIN acc.permission p ON p.code = r.permission_code
            JOIN acc.account a ON a.id = r.requested_by
            WHERE (\(a.isOwner) OR r.requested_by = \(a.id))
              AND (\(status)::text IS NULL OR r.status = \(status))
              AND r.created_at > now() - interval '30 days'
            """, as: String.self) ?? "[]"
    }

    /// The owner says yes or no. Saying yes is itself a dangerous action:
    /// it needs a fresh code. Whoever runs the action later marks it
    /// executed with `markExecuted`.
    public func decide(_ actor: Actor, id: UUID, approve: Bool, code: String?) async throws {
        try requireOwner(actor)
        if approve { try await accounts.stepUp(actor, code: code) }
        let rows = try await db.query("""
            UPDATE acc.approval_request SET status = \(approve ? "approved" : "rejected"), decided_by = \(actor.account!.id),
                   decided_at = now()
            WHERE id = \(id) AND status = 'pending' AND expires_at > now()
            RETURNING permission_code, object_type, object_id, coalesce(detail->>'object_name', '')
            """)
        var found: (String, String, UUID?, String)?
        for try await r in rows.decode((String, String, UUID?, String).self) { found = r }
        guard let (perm, type, oid, name) = found else {
            throw AccountError.notFound("Запрос уже решён или его срок истёк")
        }
        await audit.write(.init(approve ? "approval_granted" : "approval_rejected", objectType: type, objectID: oid,
                                objectName: name, detail: ["permission": perm], approvalID: id), by: actor)
    }

    /// An approved request is used once.
    public func takeApproved(_ actor: Actor, id: UUID, permission: String) async throws -> Bool {
        guard let a = actor.account else { return false }
        return try await db.scalar("""
            UPDATE acc.approval_request SET status = 'executed'
            WHERE id = \(id) AND requested_by = \(a.id) AND permission_code = \(permission) AND status = 'approved'
            RETURNING 1
            """, as: Int.self) != nil
    }
}
