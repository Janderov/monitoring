import Foundation
import HTTPTypes
import HubAccounts
import HubCore
import HubWeb
import Hummingbird
import HummingbirdTesting
import Logging
import NIOCore
import PostgresNIO
import XCTest

/// A clock the test moves by hand, so codes from the phone can be made for
/// any 30-second step.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date()
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t += s; lock.unlock() }
}

/// The whole cabinet against a real PostgreSQL when HUB_TEST_PG=1 (same
/// variables as the hub). Uses its own database, monitor_accounts_test,
/// which is wiped.
final class CabinetTests: XCTestCase {
    var env: [String: String] { ProcessInfo.processInfo.environment }

    func testCabinetOnARealDatabase() async throws {
        guard env["HUB_TEST_PG"] == "1" else { throw XCTSkip("HUB_TEST_PG=1 not set") }
        do { try await everything() } catch { XCTFail(HubError.describe(error)) }
    }

    /// A browser: keeps the session cookie, sends the cabinet's header.
    struct Browser {
        let client: any TestClientProtocol
        var cookie: String?

        struct Reply {
            var status: HTTPResponse.Status
            var json: Any?
            var setCookie: String?
            var dict: [String: Any] { json as? [String: Any] ?? [:] }
            var list: [[String: Any]] { json as? [[String: Any]] ?? [] }
            var error: String { dict["error"] as? String ?? "" }
        }

        @discardableResult
        mutating func call(_ method: HTTPRequest.Method, _ uri: String, _ body: Any? = nil, code: String? = nil,
                           csrf: Bool = true) async throws -> Reply {
            var h: HTTPFields = [.contentType: "application/json"]
            if csrf { h[HTTPField.Name("X-Requested-With")!] = "cabinet" }
            if let cookie { h[.cookie] = cookie }
            if let code { h[HTTPField.Name("X-TOTP")!] = code }
            let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
            let r = try await client.execute(uri: uri, method: method, headers: h,
                                             body: data.map { ByteBuffer(bytes: Array($0)) }) { $0 }
            let set = r.headers[.setCookie]
            if let set, let pair = set.split(separator: ";").first {
                cookie = pair.hasSuffix("=") ? nil : String(pair)
            }
            let json = try? JSONSerialization.jsonObject(with: Data(r.body.readableBytesView), options: .fragmentsAllowed)
            return Reply(status: r.status, json: json, setCookie: set)
        }
    }

    func code(_ secret: String, _ clock: TestClock) -> String {
        TOTP.code(secret: Base32.decode(secret)!, step: TOTP.step(clock.now()))
    }

    func everything() async throws {
        var logger = Logger(label: "test")
        logger.logLevel = .warning
        var config = try HubConfig.fromEnvironment(env)
        config.secretKey = Data(repeating: 7, count: 32)

        // A database of our own.
        let admin = Database(config, logger: logger)
        let adminRunner = Task { await admin.run() }
        try await admin.query("DROP DATABASE IF EXISTS monitor_accounts_test WITH (FORCE)")
        try await admin.query("CREATE DATABASE monitor_accounts_test")
        adminRunner.cancel()
        config.dbName = "monitor_accounts_test"

        let db = Database(config, logger: logger)
        let runner = Task { await db.run() }
        defer { runner.cancel() }
        if let version = try await db.scalar("SELECT current_setting('server_version_num')::int", as: Int32.self), version < 180000 {
            try await db.query("CREATE FUNCTION public.uuidv7() RETURNS uuid LANGUAGE sql AS 'SELECT gen_random_uuid()'")
        }
        try await Migrator.migrate(db, dir: config.migrationsDir)
        try await Partitions.ensure(db, now: Date())

        // One client with one server and one site, and a second client.
        let secretID = UUID()
        try await db.query("""
            INSERT INTO sys.secret (id, kind, ciphertext, nonce, key_version) VALUES (\(secretID), 'agent_token', '\\x00', '\\x00', 1)
            """)
        let clientA = try await db.scalar("INSERT INTO inv.client (name) VALUES ('Стал-КАД') RETURNING id", as: UUID.self)!
        let clientB = try await db.scalar("INSERT INTO inv.client (name) VALUES ('Биотех') RETURNING id", as: UUID.self)!
        let server = try await db.scalar("""
            INSERT INTO inv.server (name, host, agent_fingerprint, agent_token_id)
            VALUES ('wise1', '203.0.113.10', decode(repeat('ab', 32), 'hex'), \(secretID)) RETURNING id
            """, as: UUID.self)!
        let otherServer = try await db.scalar("""
            INSERT INTO inv.server (name, host, agent_fingerprint, agent_token_id)
            VALUES ('bio1', '203.0.113.11', decode(repeat('cd', 32), 'hex'), \(secretID)) RETURNING id
            """, as: UUID.self)!
        try await db.query("INSERT INTO inv.client_asset (client_id, asset_type, asset_id) VALUES (\(clientA), 'server', \(server))")
        try await db.query("INSERT INTO inv.client_asset (client_id, asset_type, asset_id) VALUES (\(clientB), 'server', \(otherServer))")

        let clock = TestClock()
        let web = WebConfig(webDir: URL(fileURLWithPath: "/nonexistent"))
        let deps = try WebDeps(config: config, web: web, db: db, logger: logger, now: { clock.now() })
        let router = WebServer(config: config, web: web, modules: [CabinetModule()], logger: logger).router(deps: deps)
        let app = Application(router: router)

        // The owner's link from the server's command line.
        let ownerToken = try await deps.accounts.ownerInvite(login: "mihail", name: "Михаил", reset: false)

        try await app.test(.router) { client in
            var owner = Browser(client: client)
            var r = try await owner.call(.get, "/api/invite/\(ownerToken)")
            XCTAssertEqual(r.status, .ok)
            XCTAssertEqual(r.dict["login"] as? String, "mihail")
            r = try await owner.call(.get, "/api/invite/nonsense"); XCTAssertEqual(r.status, .notFound)
            // Too short a password.
            r = try await owner.call(.post, "/api/invite/\(ownerToken)/password", ["password": "short"])
            XCTAssertEqual(r.status, .badRequest)
            r = try await owner.call(.post, "/api/invite/\(ownerToken)/password", ["password": "Тихий-вечер-над-Невой"])
            XCTAssertEqual(r.status, .ok, r.error)
            let ownerSecret = r.dict["secret"] as! String
            XCTAssertTrue((r.dict["otpauth_uri"] as! String).hasPrefix("otpauth://totp/"))
            r = try await owner.call(.post, "/api/invite/\(ownerToken)/code", ["code": "000000"])
            XCTAssertEqual(r.status, .badRequest)
            r = try await owner.call(.post, "/api/invite/\(ownerToken)/code", ["code": code(ownerSecret, clock)])
            XCTAssertEqual(r.status, .ok, r.error)
            XCTAssertEqual((r.dict["recovery_codes"] as? [String])?.count, 8)
            let recovery = (r.dict["recovery_codes"] as! [String])[0]
            XCTAssertNotNil(owner.cookie)
            // The link works once.
            r = try await owner.call(.get, "/api/invite/\(ownerToken)"); XCTAssertEqual(r.status, .notFound)

            r = try await owner.call(.get, "/api/me")
            XCTAssertEqual(r.status, .ok)
            XCTAssertEqual((r.dict["account"] as? [String: Any])?["kind"] as? String, "owner")
            XCTAssertEqual((r.dict["prefs"] as? [String: Any]).flatMap { $0["values"] as? [String: Any] }?["theme"] as? String,
                           "system")

            // Another site cannot drive the cabinet.
            r = try await owner.call(.post, "/api/auth/logout", csrf: false); XCTAssertEqual(r.status, .forbidden)

            // Templates and permissions.
            r = try await owner.call(.get, "/api/templates")
            let templates = r.list
            XCTAssertEqual(templates.count, 4)
            let adminTemplate = templates.first { $0["name"] as? String == "Админ" }!
            let adminPerms = adminTemplate["permissions"] as! [String: String]
            XCTAssertEqual(adminPerms["reboot_server"], "approval")
            r = try await owner.call(.get, "/api/permissions")
            XCTAssertEqual(r.list.count, 21)

            // A new person: Админ for client A only. Needs a fresh code.
            clock.advance(30)
            var full: [String: String] = [:]
            for p in r.list { full[p["code"] as! String] = adminPerms[p["code"] as! String] ?? "deny" }
            let person: [String: Any] = [
                "login": "Andrey", "display_name": "Андрей Смирнов",
                "access_expires_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(90 * 86400)),
                "grants": [["scope_type": "client", "scope_id": clientA.uuidString,
                            "template_id": adminTemplate["id"] as! String, "permissions": full]]]
            r = try await owner.call(.post, "/api/staff", person)
            XCTAssertEqual(r.status, .preconditionRequired)
            XCTAssertEqual(r.dict["need_code"] as? Bool, true)
            r = try await owner.call(.post, "/api/staff", person, code: code(ownerSecret, clock))
            XCTAssertEqual(r.status, .ok, r.error)
            let andreyID = UUID(uuidString: r.dict["id"] as! String)!
            let invitePath = r.dict["invite_path"] as! String
            let andreyToken = String(invitePath.dropFirst("/#/invite/".count))
            // The same code does not work twice.
            r = try await owner.call(.post, "/api/staff", ["login": "xenia", "display_name": "Ксения", "grants": []] as [String: Any],
                                     code: code(ownerSecret, clock))
            XCTAssertEqual(r.status, .forbidden)

            // Андрей signs up.
            var andrey = Browser(client: client)
            r = try await andrey.call(.post, "/api/invite/\(andreyToken)/password", ["password": "andrey"])
            XCTAssertEqual(r.status, .badRequest)
            r = try await andrey.call(.post, "/api/invite/\(andreyToken)/password", ["password": "сосны-у-залива-2026"])
            let andreySecret = r.dict["secret"] as! String
            r = try await andrey.call(.post, "/api/invite/\(andreyToken)/code", ["code": code(andreySecret, clock)])
            XCTAssertEqual(r.status, .ok, r.error)

            // He sees client A's server, not client B's; no staff screens.
            r = try await andrey.call(.get, "/api/overview")
            let names = (r.dict["servers"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            XCTAssertEqual(names, ["wise1"])
            r = try await andrey.call(.get, "/api/staff"); XCTAssertEqual(r.status, .forbidden)
            r = try await andrey.call(.get, "/api/me")
            XCTAssertEqual((r.dict["can"] as? [String: String])?["manage_staff"], "deny")

            // Rights as the database decides them.
            let andreyAccount = try await deps.accounts.account(andreyID)!
            var m = try await deps.access.mode(andreyAccount, "ssh", objectType: "server", objectID: server)
            XCTAssertEqual(m, .allow)
            m = try await deps.access.mode(andreyAccount, "ssh", objectType: "server", objectID: otherServer)
            XCTAssertEqual(m, .deny)
            m = try await deps.access.mode(andreyAccount, "reboot_server", objectType: "server", objectID: server)
            XCTAssertEqual(m, .approval)

            // A reboot "по согласованию": the request goes to the owner.
            clock.advance(30)
            let andreyActor = Actor(account: andreyAccount, ip: "198.51.100.7", device: "test")
            let decision = try await deps.access.authorize(andreyActor, "reboot_server",
                                                           on: .init(type: "server", id: server, name: "wise1"),
                                                           code: code(andreySecret, clock), reason: "память 98%")
            guard case .waitingForOwner(let approvalID) = decision else { return XCTFail("\(decision)") }
            r = try await owner.call(.get, "/api/approvals?status=pending")
            XCTAssertEqual(r.list.count, 1)
            XCTAssertEqual(r.list.first?["reason"] as? String, "память 98%")
            r = try await owner.call(.get, "/api/me")
            XCTAssertEqual(r.dict["pending_approvals"] as? Int, 1)
            r = try await andrey.call(.post, "/api/approvals/\(approvalID)/approve"); XCTAssertEqual(r.status, .forbidden)
            r = try await owner.call(.post, "/api/approvals/\(approvalID)/approve"); XCTAssertEqual(r.status, .preconditionRequired)
            clock.advance(30)
            r = try await owner.call(.post, "/api/approvals/\(approvalID)/approve", code: code(ownerSecret, clock))
            XCTAssertEqual(r.status, .ok, r.error)
            let taken = try await deps.access.takeApproved(andreyActor, id: approvalID, permission: "reboot_server")
            XCTAssertTrue(taken)
            let again = try await deps.access.takeApproved(andreyActor, id: approvalID, permission: "reboot_server")
            XCTAssertFalse(again)

            // His SSH key should go to wise1 only.
            r = try await andrey.call(.post, "/api/me/ssh-keys",
                                      ["key": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl andrey@pc"])
            XCTAssertEqual(r.status, .ok, r.error)
            r = try await andrey.call(.get, "/api/me/ssh-keys")
            XCTAssertEqual(r.list.first?["servers_wanted"] as? Int, 1)
            let wanted = try await db.scalar("""
                SELECT server_id FROM acc.staff_ssh_key_install WHERE want = 'installed'
                """, as: UUID.self)
            XCTAssertEqual(wanted, server)

            // Personal settings; the owner can lock one.
            r = try await andrey.call(.put, "/api/me/prefs", ["theme": "dark", "density": "normal"])
            XCTAssertEqual(r.status, .ok, r.error)
            XCTAssertEqual((r.dict["values"] as? [String: Any])?["theme"] as? String, "dark")
            r = try await andrey.call(.put, "/api/me/prefs", ["theme": "pink"]); XCTAssertEqual(r.status, .badRequest)
            r = try await owner.call(.put, "/api/org/defaults", ["theme": ["value": "\"light\"", "locked": true]])
            XCTAssertEqual(r.status, .ok, r.error)
            r = try await andrey.call(.get, "/api/me/prefs")
            XCTAssertEqual((r.dict["values"] as? [String: Any])?["theme"] as? String, "light")
            r = try await andrey.call(.put, "/api/me/prefs", ["theme": "dark"]); XCTAssertEqual(r.status, .forbidden)
            r = try await andrey.call(.put, "/api/me/notify", ["quiet_from": "23:00", "quiet_to": "08:00", "min_severity": 2])
            XCTAssertEqual(r.status, .ok, r.error)
            XCTAssertEqual(r.dict["quiet_from"] as? String, "23:00")

            // Logging in again: password, then the code; wrong passwords lock the login.
            r = try await andrey.call(.post, "/api/auth/logout"); XCTAssertEqual(r.status, .ok)
            XCTAssertNil(andrey.cookie)
            r = try await andrey.call(.get, "/api/me"); XCTAssertEqual(r.status, .unauthorized)
            r = try await andrey.call(.post, "/api/auth/login", ["login": "andrey", "password": "сосны-у-залива-2026"])
            XCTAssertEqual(r.status, .ok, r.error)
            let ticket = r.dict["ticket"] as! String
            r = try await andrey.call(.post, "/api/auth/code", ["ticket": ticket, "code": "123456"]); XCTAssertEqual(r.status, .unauthorized)
            clock.advance(30)
            r = try await andrey.call(.post, "/api/auth/code", ["ticket": ticket, "code": code(andreySecret, clock)])
            XCTAssertEqual(r.status, .ok, r.error)
            r = try await andrey.call(.get, "/api/me"); XCTAssertEqual(r.status, .ok)
            var stranger = Browser(client: client)
            for _ in 0..<5 {
                r = try await stranger.call(.post, "/api/auth/login", ["login": "andrey", "password": "guess-guess-guess"])
                XCTAssertEqual(r.status, .unauthorized)
            }
            r = try await stranger.call(.post, "/api/auth/login", ["login": "andrey", "password": "сосны-у-залива-2026"])
            XCTAssertEqual(r.status, .tooManyRequests)

            // The owner logs in with a recovery code instead of the phone.
            var ownerPhoneLost = Browser(client: client)
            r = try await ownerPhoneLost.call(.post, "/api/auth/login", ["login": "mihail", "password": "Тихий-вечер-над-Невой"])
            r = try await ownerPhoneLost.call(.post, "/api/auth/code", ["ticket": r.dict["ticket"] as! String, "code": recovery])
            XCTAssertEqual(r.status, .ok, r.error)

            // The owner's view of people.
            r = try await owner.call(.get, "/api/staff")
            XCTAssertEqual(r.list.count, 2)
            r = try await owner.call(.get, "/api/staff/\(andreyID)")
            XCTAssertEqual((r.dict["grants"] as? [[String: Any]])?.first?["scope_name"] as? String, "Стал-КАД")
            XCTAssertEqual((r.dict["sessions"] as? [[String: Any]])?.count, 1)

            // Rights changed to Наблюдатель everywhere: the key leaves (it never got there).
            clock.advance(30)
            let viewer = templates.first { $0["name"] as? String == "Наблюдатель" }!
            r = try await owner.call(.put, "/api/staff/\(andreyID)/grants",
                                     ["grants": [["scope_type": "all", "template_id": viewer["id"] as! String,
                                                  "permissions": viewer["permissions"] as! [String: String]]]],
                                     code: code(ownerSecret, clock))
            XCTAssertEqual(r.status, .ok, r.error)
            r = try await andrey.call(.get, "/api/overview")
            XCTAssertEqual((r.dict["servers"] as? [[String: Any]])?.count, 2)
            let installs = try await db.scalar("SELECT count(*)::int FROM acc.staff_ssh_key_install", as: Int.self)
            XCTAssertEqual(installs, 0)
            // Nobody but the owner hands out staff management.
            r = try await andrey.call(.put, "/api/staff/\(andreyID)/grants", ["grants": []] as [String: Any])
            XCTAssertEqual(r.status, .forbidden)

            // Off: his session ends at once.
            clock.advance(30)
            r = try await owner.call(.post, "/api/staff/\(andreyID)/disable", code: code(ownerSecret, clock))
            XCTAssertEqual(r.status, .ok, r.error)
            r = try await andrey.call(.get, "/api/me"); XCTAssertEqual(r.status, .unauthorized)
            r = try await andrey.call(.post, "/api/auth/login", ["login": "andrey", "password": "сосны-у-залива-2026"])
            XCTAssertNotEqual(r.status, .ok)

            // Reset: a new link, the old password no longer counts.
            clock.advance(30)
            r = try await owner.call(.post, "/api/staff/\(andreyID)/enable", code: code(ownerSecret, clock))
            XCTAssertEqual(r.status, .ok, r.error)
            clock.advance(30)
            r = try await owner.call(.post, "/api/staff/\(andreyID)/reset", code: code(ownerSecret, clock))
            XCTAssertEqual(r.status, .ok, r.error)
            XCTAssertNotNil(r.dict["invite_path"] as? String)

            // Everything is in the log; Андрей sees only his own lines.
            r = try await owner.call(.get, "/api/audit?limit=500")
            let actions = Set(r.list.compactMap { $0["action"] as? String })
            for a in ["owner_invite", "signup", "staff_created", "grants_changed", "login", "login_failed",
                      "reboot_server", "approval_granted", "ssh_key_added", "staff_disabled", "staff_enabled",
                      "login_reset", "step_up_failed"] {
                XCTAssertTrue(actions.contains(a), "no \(a) in the audit log")
            }
            let pending = r.list.first { $0["action"] as? String == "reboot_server" }
            XCTAssertEqual(pending?["result"] as? String, "pending_approval")
            XCTAssertEqual(pending?["ip"] as? String, "198.51.100.7")

            // Org settings are the owner's.
            r = try await owner.call(.put, "/api/org", ["company_name": "Михаил · мониторинг", "brand_color": "#0a64d6"])
            XCTAssertEqual(r.status, .ok, r.error)
            XCTAssertEqual(r.dict["company_name"] as? String, "Михаил · мониторинг")
            r = try await owner.call(.put, "/api/org", ["brand_color": "blue"]); XCTAssertEqual(r.status, .badRequest)
        }
    }
}
