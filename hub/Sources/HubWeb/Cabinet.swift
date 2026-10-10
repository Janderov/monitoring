import Foundation
import HubAccounts
import HubCore
import Hummingbird
import Logging

/// The cabinet's JSON API: logging in, signing up by invite, one's own
/// settings, and for the owner (and managers) people, rights, templates,
/// approvals and the audit log.
public struct CabinetModule: WebModule {
    public init() {}

    public func register(_ router: Router<WebContext>, deps: WebDeps) {
        registerLogin(router, deps)
        registerMe(router, deps)
        registerStaff(router, deps)
        registerOwner(router, deps)
    }

    // MARK: Logging in and signing up

    struct LoginBody: Decodable { var login: String; var password: String }
    struct CodeBody: Decodable { var ticket: String?; var code: String }
    struct PasswordBody: Decodable { var password: String }

    func registerLogin(_ router: Router<WebContext>, _ d: WebDeps) {
        router.post("/api/auth/login") { req, ctx in
            let b = try await Web.body(req, as: LoginBody.self)
            switch try await d.accounts.login(login: b.login.trimmingCharacters(in: .whitespaces),
                                              password: b.password, ip: d.auth.ip(req, ctx), device: d.auth.device(req)) {
            case .needCode(let ticket):
                return Web.json("{\"step\":\"code\",\"ticket\":\(JSON.string(ticket))}")
            }
        }
        router.post("/api/auth/code") { req, ctx in
            let b = try await Web.body(req, as: CodeBody.self)
            guard let ticket = b.ticket else { throw AccountError.badRequest("Введите пароль ещё раз") }
            let (account, token) = try await d.accounts.loginCode(ticket: ticket, code: b.code, ip: d.auth.ip(req, ctx),
                                                                   device: d.auth.device(req))
            return Web.json("{\"ok\":true,\"account\":\(JSON.encode(account))}", cookie: d.auth.sessionCookie(token))
        }
        router.post("/api/auth/logout") { req, ctx in
            if let a = try await d.auth.current(req, ctx) { try await d.accounts.logout(a) }
            return Web.json("{\"ok\":true}", cookie: d.auth.clearCookie())
        }
        router.get("/api/invite/{token}") { _, ctx in
            let info = try await d.accounts.invite(ctx.parameters.get("token") ?? "")
            return Web.encode(info)
        }
        router.post("/api/invite/{token}/password") { req, ctx in
            let b = try await Web.body(req, as: PasswordBody.self)
            let e = try await d.accounts.acceptPassword(token: ctx.parameters.get("token") ?? "", password: b.password)
            return Web.json("{\"otpauth_uri\":\(JSON.string(e.otpauthURI)),\"secret\":\(JSON.string(e.secret))}")
        }
        router.post("/api/invite/{token}/code") { req, ctx in
            let b = try await Web.body(req, as: CodeBody.self)
            let w = try await d.accounts.acceptTOTP(token: ctx.parameters.get("token") ?? "", code: b.code,
                                                    ip: d.auth.ip(req, ctx), device: d.auth.device(req))
            return Web.json("{\"ok\":true,\"recovery_codes\":\(JSON.encode(w.recoveryCodes)),\"account\":\(JSON.encode(w.account))}",
                            cookie: d.auth.sessionCookie(w.sessionToken))
        }
    }

    // MARK: One's own

    struct ChangePassword: Decodable { var current: String; var new: String }
    struct NewKey: Decodable { var key: String; var label: String? }

    func registerMe(_ router: Router<WebContext>, _ d: WebDeps) {
        router.get("/api/me") { req, ctx in
            let actor = try await d.auth.require(req, ctx)
            let a = actor.account!
            var can: [String: String] = [:]
            for p in ["manage_staff", "view_logs", "alerts_ack"] {
                can[p] = try await d.access.mode(a, p).rawValue
            }
            let prefs = try await d.preferences.json(for: a)
            let org = try await d.db.scalar("SELECT json_build_object('company_name', company_name, 'brand_color', brand_color)::text FROM sys.org_settings", as: String.self) ?? "{}"
            let pending = a.isOwner
                ? try await d.db.scalar("SELECT count(*)::int FROM acc.approval_request WHERE status = 'pending' AND expires_at > now()", as: Int.self) ?? 0
                : 0
            return Web.json("""
                {"account":\(JSON.encode(a)),"can":\(JSON.encode(can)),"prefs":\(prefs),"org":\(org),\
                "pending_approvals":\(pending),"version":\(JSON.string(HubVersion.current))}
                """)
        }
        router.get("/api/me/prefs") { req, ctx in
            let a = try await d.auth.require(req, ctx)
            return Web.json(try await d.preferences.json(for: a.account!))
        }
        router.put("/api/me/prefs") { req, ctx in
            let a = try await d.auth.require(req, ctx)
            let values = try await Self.rawValues(req)
            try await d.preferences.set(a, values)
            return Web.json(try await d.preferences.json(for: a.account!))
        }
        router.get("/api/me/notify") { req, ctx in
            let a = try await d.auth.require(req, ctx)
            return Web.json(try await d.preferences.notifyJSON(for: a.account!))
        }
        router.put("/api/me/notify") { req, ctx in
            let a = try await d.auth.require(req, ctx)
            try await d.preferences.setNotify(a, try await Web.body(req, as: Preferences.Notify.self))
            return Web.json(try await d.preferences.notifyJSON(for: a.account!))
        }
        router.get("/api/me/sessions") { req, ctx in
            let a = try await d.auth.require(req, ctx)
            return Web.json(try await d.accounts.sessionsJSON(a.account!.id, current: a.sessionID))
        }
        router.delete("/api/me/sessions/{id}") { req, ctx in
            let a = try await d.auth.require(req, ctx)
            try await d.accounts.revokeSession(try Web.uuid(ctx), of: a.account!.id, by: a)
            return Web.ok()
        }
        router.post("/api/me/password") { req, ctx in
            let a = try await d.auth.require(req, ctx)
            let b = try await Web.body(req, as: ChangePassword.self)
            try await d.accounts.changePassword(a, current: b.current, new: b.new, code: d.auth.code(req))
            return Web.ok()
        }
        router.post("/api/me/recovery-codes") { req, ctx in
            let a = try await d.auth.require(req, ctx)
            let codes = try await d.accounts.newRecoveryCodes(a, code: d.auth.code(req))
            return Web.json("{\"recovery_codes\":\(JSON.encode(codes))}")
        }
        router.get("/api/me/ssh-keys") { req, ctx in
            let a = try await d.auth.require(req, ctx)
            return Web.json(try await SSHKeys.listJSON(d.db, account: a.account!.id))
        }
        router.post("/api/me/ssh-keys") { req, ctx in
            let a = try await d.auth.require(req, ctx)
            let b = try await Web.body(req, as: NewKey.self)
            let id = try await SSHKeys.add(d.accounts, actor: a, text: b.key, label: b.label ?? "")
            return Web.json("{\"id\":\(JSON.string(id.uuidString))}")
        }
        router.delete("/api/me/ssh-keys/{id}") { req, ctx in
            let a = try await d.auth.require(req, ctx)
            try await SSHKeys.revoke(d.accounts, actor: a, keyID: try Web.uuid(ctx), of: a.account!.id)
            return Web.ok()
        }
        router.get("/api/overview") { req, ctx in
            let a = try await d.auth.require(req, ctx)
            return Web.json(try await d.overview.json(for: a.account!))
        }
        router.post("/api/incidents/{id}/ack") { req, ctx in
            let a = try await d.auth.require(req, ctx)
            try await d.overview.ack(a, incident: try Web.uuid(ctx))
            return Web.ok()
        }
        router.get("/api/audit") { req, ctx in
            let a = try await d.auth.require(req, ctx)
            let q = req.uri.queryParameters
            func id(_ k: String) -> UUID? { q.get(k).flatMap { UUID(uuidString: $0) } }
            func text(_ k: String) -> String? { q.get(k).flatMap { $0.isEmpty ? nil : $0 } }
            let f = Overview.AuditFilter(actor: id("actor"), object: id("object"), client: id("client"),
                                         action: text("action"), result: text("result"), search: text("q"),
                                         before: text("before").flatMap(JSON.parseDate),
                                         limit: q.get("limit").flatMap { Int($0) } ?? 200)
            return Web.json(try await d.overview.auditJSON(a, f))
        }
        router.get("/api/approvals") { req, ctx in
            let a = try await d.auth.require(req, ctx)
            let status = req.uri.queryParameters.get("status").flatMap { $0.isEmpty ? nil : $0 }
            return Web.json(try await d.access.approvalsJSON(a, status: status))
        }
        router.get("/api/permissions") { req, ctx in
            _ = try await d.auth.require(req, ctx)
            return Web.json(try await d.access.permissionsJSON())
        }
    }

    /// {"theme": "dark", "density": null}: each value kept as raw JSON text.
    static func rawValues(_ req: Request) async throws -> [String: String?] {
        let buffer = try await req.body.collect(upTo: 64 * 1024)
        guard let obj = try? JSONSerialization.jsonObject(with: Data(buffer.readableBytesView)) as? [String: Any] else {
            throw AccountError.badRequest("Ожидался объект настроек")
        }
        var out: [String: String?] = [:]
        for (k, v) in obj {
            if v is NSNull { out[k] = .some(nil); continue }
            let data = try JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed, .withoutEscapingSlashes])
            out[k] = String(decoding: data, as: UTF8.self)
        }
        return out
    }

    // MARK: People and rights

    struct GrantsBody: Decodable { var grants: [Access.GrantInput] }

    func managerActor(_ req: Request, _ ctx: WebContext, _ d: WebDeps) async throws -> Actor {
        let a = try await d.auth.require(req, ctx)
        guard try await d.staff.canManage(a) else { throw AccountError.forbidden("Нет прав: сотрудники и их права") }
        return a
    }

    func inviteJSON(_ token: String, _ d: WebDeps) -> String {
        let path = "/#/invite/\(token)"
        return "{\"invite_path\":\(JSON.string(path)),\"invite_url\":\(JSON.string(d.web.link(path)))}"
    }

    func registerStaff(_ router: Router<WebContext>, _ d: WebDeps) {
        router.get("/api/staff") { req, ctx in
            _ = try await managerActor(req, ctx, d)
            return Web.json(try await d.staff.listJSON())
        }
        router.post("/api/staff") { req, ctx in
            let a = try await managerActor(req, ctx, d)
            let p = try await Web.body(req, as: Staff.NewPerson.self)
            let (id, token) = try await d.staff.create(a, p, code: d.auth.code(req))
            return Web.json("{\"id\":\(JSON.string(id.uuidString)),\(inviteJSON(token, d).dropFirst())")
        }
        router.get("/api/staff/{id}") { req, ctx in
            _ = try await managerActor(req, ctx, d)
            return Web.json(try await d.staff.detailJSON(try Web.uuid(ctx)))
        }
        router.patch("/api/staff/{id}") { req, ctx in
            let a = try await managerActor(req, ctx, d)
            try await d.staff.update(a, id: try Web.uuid(ctx), try await Web.body(req, as: Staff.Changes.self),
                                     code: d.auth.code(req))
            return Web.ok()
        }
        router.put("/api/staff/{id}/grants") { req, ctx in
            let a = try await managerActor(req, ctx, d)
            let b = try await Web.body(req, as: GrantsBody.self)
            try await d.staff.setGrants(a, id: try Web.uuid(ctx), b.grants, code: d.auth.code(req))
            return Web.json(try await d.access.grantsJSON(try Web.uuid(ctx)))
        }
        router.post("/api/staff/{id}/disable") { req, ctx in
            let a = try await managerActor(req, ctx, d)
            try await d.staff.disable(a, id: try Web.uuid(ctx), code: d.auth.code(req))
            return Web.ok()
        }
        router.post("/api/staff/{id}/enable") { req, ctx in
            let a = try await managerActor(req, ctx, d)
            let token = try await d.staff.enable(a, id: try Web.uuid(ctx), code: d.auth.code(req))
            return Web.json(token.map { inviteJSON($0, d) } ?? "{\"ok\":true}")
        }
        router.post("/api/staff/{id}/reset") { req, ctx in
            let a = try await managerActor(req, ctx, d)
            return Web.json(inviteJSON(try await d.staff.resetLogin(a, id: try Web.uuid(ctx), code: d.auth.code(req)), d))
        }
        router.post("/api/staff/{id}/invite") { req, ctx in
            let a = try await managerActor(req, ctx, d)
            return Web.json(inviteJSON(try await d.staff.reinvite(a, id: try Web.uuid(ctx), code: d.auth.code(req)), d))
        }
        router.delete("/api/staff/{id}/sessions") { req, ctx in
            let a = try await managerActor(req, ctx, d)
            try await d.staff.revokeSessions(a, id: try Web.uuid(ctx), code: d.auth.code(req))
            return Web.ok()
        }
        router.delete("/api/staff/{id}/ssh-keys/{key}") { req, ctx in
            let a = try await managerActor(req, ctx, d)
            let target = try Web.uuid(ctx)
            try await d.staff.authorizeChange(a, target: target, code: d.auth.code(req))
            try await SSHKeys.revoke(d.accounts, actor: a, keyID: try Web.uuid(ctx, "key"), of: target)
            return Web.ok()
        }
        router.get("/api/scopes") { req, ctx in
            _ = try await managerActor(req, ctx, d)
            return Web.json(try await d.overview.scopesJSON())
        }
        router.get("/api/templates") { req, ctx in
            _ = try await managerActor(req, ctx, d)
            return Web.json(try await d.access.templatesJSON())
        }
    }

    // MARK: The owner's

    func registerOwner(_ router: Router<WebContext>, _ d: WebDeps) {
        router.post("/api/templates") { req, ctx in
            let a = try await d.auth.requireOwner(req, ctx)
            let id = try await d.access.saveTemplate(a, id: nil, try await Web.body(req, as: Access.TemplateInput.self))
            return Web.json("{\"id\":\(JSON.string(id.uuidString))}")
        }
        router.put("/api/templates/{id}") { req, ctx in
            let a = try await d.auth.requireOwner(req, ctx)
            _ = try await d.access.saveTemplate(a, id: try Web.uuid(ctx), try await Web.body(req, as: Access.TemplateInput.self))
            return Web.ok()
        }
        router.delete("/api/templates/{id}") { req, ctx in
            let a = try await d.auth.requireOwner(req, ctx)
            try await d.access.deleteTemplate(a, id: try Web.uuid(ctx))
            return Web.ok()
        }
        router.post("/api/approvals/{id}/approve") { req, ctx in
            let a = try await d.auth.requireOwner(req, ctx)
            try await d.access.decide(a, id: try Web.uuid(ctx), approve: true, code: d.auth.code(req))
            return Web.ok()
        }
        router.post("/api/approvals/{id}/reject") { req, ctx in
            let a = try await d.auth.requireOwner(req, ctx)
            try await d.access.decide(a, id: try Web.uuid(ctx), approve: false, code: nil)
            return Web.ok()
        }
        router.get("/api/org") { req, ctx in
            _ = try await d.auth.requireOwner(req, ctx)
            return Web.json(try await d.preferences.orgJSON())
        }
        router.put("/api/org") { req, ctx in
            let a = try await d.auth.requireOwner(req, ctx)
            try await d.preferences.setOrg(a, try await Web.body(req, as: Preferences.Org.self))
            return Web.json(try await d.preferences.orgJSON())
        }
        router.put("/api/org/defaults") { req, ctx in
            let a = try await d.auth.requireOwner(req, ctx)
            let b = try await Web.body(req, as: [String: Preferences.Default?].self)
            try await d.preferences.setDefaults(a, b)
            return Web.json(try await d.preferences.json(for: a.account!))
        }
    }
}
