import Foundation
import HubCore
import Logging
import NIOCore
import PostgresNIO

/// Counts wrong passwords and codes per login, and holds the short-lived
/// "password was right, now the code" tickets. In memory: a restart of the
/// hub only forgets them, which is safe.
public actor LoginGuard {
    struct Failures { var count: Int; var lockedUntil: Date? }
    var failures: [String: Failures] = [:]
    var tickets: [String: (account: UUID, expires: Date)] = [:]

    public init() {}

    func check(_ login: String, now: Date) throws {
        if let until = failures[login.lowercased()]?.lockedUntil, until > now {
            let minutes = Int((until.timeIntervalSince(now) / 60).rounded(.up))
            throw AccountError.tooMany("Слишком много неудачных попыток. Попробуйте через \(minutes) мин.")
        }
    }

    func failed(_ login: String, now: Date) {
        var f = failures[login.lowercased()] ?? Failures(count: 0, lockedUntil: nil)
        if let until = f.lockedUntil, until <= now { f = Failures(count: 0, lockedUntil: nil) }
        f.count += 1
        if f.count >= Lifetimes.maxFailures { f.lockedUntil = now.addingTimeInterval(Lifetimes.lockout) }
        failures[login.lowercased()] = f
    }

    func succeeded(_ login: String) { failures[login.lowercased()] = nil }

    func issueTicket(for account: UUID, now: Date) -> String {
        tickets = tickets.filter { $0.value.expires > now }
        let t = Tokens.make()
        tickets[t] = (account, now.addingTimeInterval(Lifetimes.loginTicket))
        return t
    }

    func ticket(_ t: String, now: Date) -> UUID? {
        guard let v = tickets[t], v.expires > now else { return nil }
        return v.account
    }

    func useTicket(_ t: String) { tickets[t] = nil }
}

/// People and their logins: invites, password + code from the phone,
/// sessions. Every step that matters goes to the audit log.
public struct Accounts: Sendable {
    public let db: Database
    public let box: SecretBox?
    public let audit: Audit
    public let guardian: LoginGuard
    /// Shown in the phone app next to the code.
    public let issuer: String
    public let now: @Sendable () -> Date

    public init(db: Database, box: SecretBox?, guardian: LoginGuard = LoginGuard(), issuer: String = "Мониторинг",
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.db = db; self.box = box; self.audit = Audit(db: db); self.guardian = guardian
        self.issuer = issuer; self.now = now
    }

    var logger: Logger { db.logger }

    // MARK: Reading accounts

    static let accountColumns = "a.id, a.login::text, a.display_name, a.kind, a.status, a.access_expires_at"

    static func decodeAccount(_ row: PostgresRow) throws -> Account {
        let (id, login, name, kind, status, expires) = try row.decode((UUID, String, String, String, String, Date?).self)
        return Account(id: id, login: login, displayName: name, kind: AccountKind(rawValue: kind) ?? .staff,
                       status: AccountStatus(rawValue: status) ?? .disabled, accessExpiresAt: expires)
    }

    public func account(_ id: UUID) async throws -> Account? {
        for try await row in try await db.query("SELECT \(unescaped: Self.accountColumns) FROM acc.account a WHERE a.id = \(id)") {
            return try Self.decodeAccount(row)
        }
        return nil
    }

    func account(login: String) async throws -> Account? {
        for try await row in try await db.query(
            "SELECT \(unescaped: Self.accountColumns) FROM acc.account a WHERE a.login = \(login)::citext") {
            return try Self.decodeAccount(row)
        }
        return nil
    }

    public func owner() async throws -> Account? {
        for try await row in try await db.query("SELECT \(unescaped: Self.accountColumns) FROM acc.account a WHERE a.kind = 'owner'") {
            return try Self.decodeAccount(row)
        }
        return nil
    }

    // MARK: Invites

    /// The owner's first link, made on the server's command line. With
    /// `reset` it also starts over a lost password or phone.
    public func ownerInvite(login: String, name: String, reset: Bool) async throws -> String {
        let token = Tokens.make()
        let expires = now().addingTimeInterval(Lifetimes.invite)
        let existing = try await owner()
        if let o = existing, o.status == .active, !reset {
            throw AccountError.conflict("Владелец уже есть (\(o.login)). Чтобы сбросить его вход, добавьте --reset")
        }
        try await db.transaction { conn in
            let id: UUID
            if let o = existing {
                id = o.id
                try await Self.wipeLogin(id, conn: conn, logger: logger)
                try await conn.query("UPDATE acc.account SET status = 'invited' WHERE id = \(id)", logger: logger)
            } else {
                id = try await conn.one("""
                    INSERT INTO acc.account (login, display_name, kind, status)
                    VALUES (\(login)::citext, \(name), 'owner', 'invited') RETURNING id
                    """, as: UUID.self)!
            }
            try await conn.query("""
                INSERT INTO acc.invite (account_id, token_hash, expires_at, created_by)
                VALUES (\(id), \(ByteBuffer(bytes: Tokens.hash(token))), \(expires), \(id))
                """, logger: logger)
            try await audit.write(.init(reset ? "owner_reset" : "owner_invite", objectType: "account", objectID: id,
                                        objectName: existing?.login ?? login), by: .system, on: conn)
        }
        return token
    }

    /// A new link for a person who has not finished signing up, or whose
    /// login was reset. Older links stop working.
    func newInvite(for id: UUID, by actor: Actor, conn: PostgresConnection) async throws -> String {
        let token = Tokens.make()
        try await conn.query("UPDATE acc.invite SET used_at = now() WHERE account_id = \(id) AND used_at IS NULL",
                             logger: logger)
        try await conn.query("""
            INSERT INTO acc.invite (account_id, token_hash, expires_at, created_by)
            VALUES (\(id), \(ByteBuffer(bytes: Tokens.hash(token))), \(now().addingTimeInterval(Lifetimes.invite)),
                    \(actor.account?.id ?? id))
            """, logger: logger)
        return token
    }

    static func wipeLogin(_ id: UUID, conn: PostgresConnection, logger: Logger) async throws {
        try await conn.query("DELETE FROM acc.account_password WHERE account_id = \(id)", logger: logger)
        try await conn.query("""
            WITH gone AS (DELETE FROM acc.account_mfa WHERE account_id = \(id) RETURNING secret_id)
            DELETE FROM sys.secret WHERE id IN (SELECT secret_id FROM gone)
            """, logger: logger)
        try await conn.query("DELETE FROM acc.recovery_code WHERE account_id = \(id)", logger: logger)
        try await conn.query("UPDATE acc.session SET revoked_at = now() WHERE account_id = \(id) AND revoked_at IS NULL",
                             logger: logger)
        try await conn.query("UPDATE acc.invite SET used_at = now() WHERE account_id = \(id) AND used_at IS NULL",
                             logger: logger)
    }

    public struct InviteInfo: Codable, Sendable {
        public var login: String
        public var displayName: String
        public var expiresAt: Date
        /// The password is set; next is the code from the phone.
        public var passwordSet: Bool
    }

    func inviteAccount(_ token: String) async throws -> (account: Account, expires: Date) {
        let rows = try await db.query("""
            SELECT \(unescaped: Self.accountColumns), i.expires_at FROM acc.invite i
            JOIN acc.account a ON a.id = i.account_id
            WHERE i.token_hash = \(ByteBuffer(bytes: Tokens.hash(token))) AND i.used_at IS NULL
            """)
        for try await row in rows {
            let account = try Self.decodeAccount(row)
            let expires = try row.decode((UUID, String, String, String, String, Date?, Date).self).6
            guard expires > now() else { throw AccountError.notFound("Срок ссылки-приглашения истёк. Попросите новую.") }
            guard account.status != .disabled else { throw AccountError.forbidden("Доступ отключён") }
            return (account, expires)
        }
        throw AccountError.notFound("Ссылка-приглашение недействительна или уже использована")
    }

    public func invite(_ token: String) async throws -> InviteInfo {
        let (a, expires) = try await inviteAccount(token)
        let hasPassword = try await db.scalar(
            "SELECT count(*) FROM acc.account_password WHERE account_id = \(a.id)", as: Int.self) ?? 0
        return InviteInfo(login: a.login, displayName: a.displayName, expiresAt: expires, passwordSet: hasPassword > 0)
    }

    public struct Enrolment: Codable, Sendable {
        public var otpauthURI: String
        public var secret: String
    }

    /// Step 1 of signing up: the password. Returns what the phone app scans.
    public func acceptPassword(token: String, password: String) async throws -> Enrolment {
        let (a, _) = try await inviteAccount(token)
        if let w = PasswordHash.weakness(password, login: a.login) { throw AccountError.badRequest(w) }
        let hash = try PasswordHash.make(password)
        let secret = TOTP.newSecret()
        try await db.transaction { conn in
            try await conn.query("""
                INSERT INTO acc.account_password (account_id, hash) VALUES (\(a.id), \(hash))
                ON CONFLICT (account_id) DO UPDATE SET hash = EXCLUDED.hash, changed_at = now(), must_change = false
                """, logger: logger)
            try await conn.query("""
                WITH gone AS (DELETE FROM acc.account_mfa WHERE account_id = \(a.id) AND confirmed_at IS NULL
                              RETURNING secret_id)
                DELETE FROM sys.secret WHERE id IN (SELECT secret_id FROM gone)
                """, logger: logger)
            let secretID = try await storeSecret(secret, conn: conn)
            try await conn.query("""
                INSERT INTO acc.account_mfa (account_id, type, secret_id, label)
                VALUES (\(a.id), 'totp', \(secretID), 'Телефон')
                """, logger: logger)
        }
        return Enrolment(otpauthURI: TOTP.uri(secret: secret, login: a.login, issuer: issuer),
                         secret: Base32.encode(secret))
    }

    public struct Welcome: Sendable {
        public var account: Account
        public var recoveryCodes: [String]
        public var sessionToken: String
    }

    /// Step 2: the first code from the phone. The account becomes active,
    /// gets its one-time recovery codes and is logged in.
    public func acceptTOTP(token: String, code: String, ip: String?, device: String?) async throws -> Welcome {
        let (a, _) = try await inviteAccount(token)
        guard let (mfaID, secret, _) = try await totpSecret(a.id, confirmed: false) else {
            throw AccountError.badRequest("Сначала задайте пароль")
        }
        guard let step = TOTP.match(code, secret: secret, at: now()) else {
            throw AccountError.badRequest("Код не подходит. Проверьте время на телефоне и введите новый код.")
        }
        let codes = (0..<8).map { _ in Tokens.recoveryCode() }
        let session = Tokens.make()
        var active = a
        active.status = .active
        let actor = Actor(account: active, ip: ip, device: device)
        try await db.transaction { conn in
            // The new phone replaces an old one (after a reset there is none).
            try await conn.query("""
                WITH gone AS (DELETE FROM acc.account_mfa WHERE account_id = \(a.id) AND type = 'totp'
                              AND confirmed_at IS NOT NULL RETURNING secret_id)
                DELETE FROM sys.secret WHERE id IN (SELECT secret_id FROM gone)
                """, logger: logger)
            try await conn.query("""
                UPDATE acc.account_mfa SET confirmed_at = now(), last_step = \(step), last_used_at = now()
                WHERE id = \(mfaID)
                """, logger: logger)
            try await conn.query("DELETE FROM acc.recovery_code WHERE account_id = \(a.id)", logger: logger)
            for c in codes {
                try await conn.query("""
                    INSERT INTO acc.recovery_code (account_id, code_hash)
                    VALUES (\(a.id), \(Self.recoveryHash(c)))
                    """, logger: logger)
            }
            try await conn.query("""
                UPDATE acc.invite SET used_at = now() WHERE token_hash = \(ByteBuffer(bytes: Tokens.hash(token)))
                """, logger: logger)
            try await conn.query("""
                UPDATE acc.account SET status = 'active', last_login_at = now() WHERE id = \(a.id)
                """, logger: logger)
            let sid = try await insertSession(account: a.id, token: session, ip: ip, device: device, conn: conn)
            var withSession = actor
            withSession.sessionID = sid
            try await audit.write(.init("signup", objectType: "account", objectID: a.id, objectName: a.login),
                                  by: withSession, on: conn)
        }
        return Welcome(account: active, recoveryCodes: codes, sessionToken: session)
    }

    static func recoveryHash(_ code: String) -> String {
        Tokens.hash(Tokens.normalizeRecovery(code)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Secrets

    func storeSecret(_ secret: [UInt8], conn: PostgresConnection) async throws -> UUID {
        guard let box else {
            throw AccountError.internal("На хабе нет ключа шифрования (secret-key): коды входа негде хранить")
        }
        let id = UUID()
        let sealed = try box.seal(Base32.encode(secret), id: id, kind: "totp")
        try await conn.query("""
            INSERT INTO sys.secret (id, kind, ciphertext, nonce, key_version, label)
            VALUES (\(id), 'totp', \(ByteBuffer(bytes: sealed.ciphertext)), \(ByteBuffer(bytes: sealed.nonce)), \(SecretBox.keyVersion),
                    'код входа')
            """, logger: logger)
        return id
    }

    /// The account's phone secret: (mfa row, secret, last accepted step).
    func totpSecret(_ account: UUID, confirmed: Bool) async throws -> (UUID, [UInt8], Int64?)? {
        guard let box else { throw AccountError.internal("На хабе нет ключа шифрования (secret-key)") }
        let rows = try await db.query("""
            SELECT m.id, s.id, s.ciphertext, s.nonce, m.last_step FROM acc.account_mfa m
            JOIN sys.secret s ON s.id = m.secret_id
            WHERE m.account_id = \(account) AND m.type = 'totp'
              AND (m.confirmed_at IS NOT NULL) = \(confirmed)
            ORDER BY m.created_at DESC LIMIT 1
            """)
        for try await (mfaID, secretID, cipher, nonce, last) in rows.decode((UUID, UUID, ByteBuffer, ByteBuffer, Int64?).self) {
            let text = try box.open(.init(ciphertext: Array(cipher.readableBytesView), nonce: Array(nonce.readableBytesView)), id: secretID, kind: "totp")
            guard let secret = Base32.decode(text) else { throw AccountError.internal("код входа повреждён") }
            return (mfaID, secret, last)
        }
        return nil
    }

    /// Checks a code from the phone and remembers its step, so the same code
    /// does not pass twice.
    func useTOTP(_ account: UUID, code: String) async throws -> Bool {
        guard let (mfaID, secret, last) = try await totpSecret(account, confirmed: true) else { return false }
        guard let step = TOTP.match(code, secret: secret, at: now(), after: last) else { return false }
        // Two requests with the same code at once: only one moves last_step.
        let updated = try await db.scalar("""
            UPDATE acc.account_mfa SET last_step = \(step), last_used_at = now()
            WHERE id = \(mfaID) AND (last_step IS NULL OR last_step < \(step)) RETURNING 1
            """, as: Int.self)
        return updated != nil
    }

    func useRecoveryCode(_ account: UUID, code: String) async throws -> Bool {
        try await db.scalar("""
            UPDATE acc.recovery_code SET used_at = now()
            WHERE id = (SELECT id FROM acc.recovery_code WHERE account_id = \(account)
                          AND code_hash = \(Self.recoveryHash(code)) AND used_at IS NULL LIMIT 1)
            RETURNING 1
            """, as: Int.self) != nil
    }

    /// A fresh code before a dangerous action (danger level 2).
    public func stepUp(_ actor: Actor, code: String?) async throws {
        guard let a = actor.account else { throw AccountError.unauthorized("Войдите заново") }
        guard let code, !code.isEmpty else { throw AccountError.needTOTP }
        guard try await useTOTP(a.id, code: code) else {
            await audit.write(.init("step_up_failed", objectType: "account", objectID: a.id, objectName: a.login,
                                    result: .denied), by: actor)
            throw AccountError.forbidden("Код не подходит. Подождите новый код и попробуйте ещё раз.")
        }
    }

    // MARK: Logging in

    public enum LoginStep: Sendable {
        /// The password was right; now the code from the phone.
        case needCode(ticket: String)
    }

    public func login(login: String, password: String, ip: String?, device: String?) async throws -> LoginStep {
        let t = now()
        try await guardian.check(login, now: t)
        let actor = Actor(account: nil, ip: ip, device: device)
        let found = try await account(login: login)
        var hash: String?
        if let a = found {
            hash = try await db.scalar("SELECT hash FROM acc.account_password WHERE account_id = \(a.id)", as: String.self)
        }
        // Same work whether or not the login exists, so timing does not tell.
        let ok = PasswordHash.verify(password, hash: hash ?? Self.dummyHash)
        guard let a = found, hash != nil, ok else {
            await guardian.failed(login, now: t)
            await audit.write(.init("login_failed", objectType: "account", objectID: found?.id, objectName: login,
                                    detail: ["step": "password"], result: .denied), by: actor)
            throw AccountError.unauthorized("Неверный логин или пароль")
        }
        try usable(a)
        return .needCode(ticket: await guardian.issueTicket(for: a.id, now: t))
    }

    static let dummyHash = (try? PasswordHash.make("not a password at all")) ?? ""

    func usable(_ a: Account) throws {
        switch a.status {
        case .disabled: throw AccountError.forbidden("Доступ отключён. Обратитесь к владельцу.")
        case .invited: throw AccountError.forbidden("Сначала завершите регистрацию по ссылке-приглашению")
        case .active: break
        }
        if let e = a.accessExpiresAt, e <= now() {
            throw AccountError.forbidden("Срок доступа закончился. Попросите владельца продлить.")
        }
    }

    /// The code from the phone (or a one-time recovery code) after the password.
    public func loginCode(ticket: String, code: String, ip: String?, device: String?) async throws
        -> (account: Account, token: String) {
        let t = now()
        guard let id = await guardian.ticket(ticket, now: t), let a = try await account(id) else {
            throw AccountError.unauthorized("Время на ввод кода вышло. Введите пароль ещё раз.")
        }
        try await guardian.check(a.login, now: t)
        try usable(a)
        var how = "totp"
        var ok = try await useTOTP(a.id, code: code)
        if !ok, code.filter(\.isLetter).count > 0, try await useRecoveryCode(a.id, code: code) {
            ok = true; how = "recovery_code"
        }
        guard ok else {
            await guardian.failed(a.login, now: t)
            await audit.write(.init("login_failed", objectType: "account", objectID: a.id, objectName: a.login,
                                    detail: ["step": "code"], result: .denied),
                              by: Actor(account: a, ip: ip, device: device))
            throw AccountError.unauthorized("Код не подходит")
        }
        await guardian.useTicket(ticket)
        await guardian.succeeded(a.login)
        let token = Tokens.make()
        try await db.transaction { conn in
            let sid = try await insertSession(account: a.id, token: token, ip: ip, device: device, conn: conn)
            try await conn.query("UPDATE acc.account SET last_login_at = now() WHERE id = \(a.id)", logger: logger)
            try await audit.write(.init("login", objectType: "account", objectID: a.id, objectName: a.login,
                                        detail: ["how": how]),
                                  by: Actor(account: a, sessionID: sid, ip: ip, device: device), on: conn)
        }
        return (a, token)
    }

    func insertSession(account: UUID, token: String, ip: String?, device: String?,
                       conn: PostgresConnection) async throws -> UUID {
        try await conn.one("""
            INSERT INTO acc.session (account_id, token_hash, device_name, ip, user_agent, expires_at)
            VALUES (\(account), \(ByteBuffer(bytes: Tokens.hash(token))), \(Self.deviceName(device)), \(ip)::inet, \(device),
                    \(now().addingTimeInterval(Lifetimes.sessionAbsolute)))
            RETURNING id
            """, as: UUID.self)!
    }

    /// "Chrome, Windows" out of a browser's User-Agent.
    public static func deviceName(_ ua: String?) -> String {
        guard let ua else { return "" }
        let browser = ["Edg/": "Edge", "YaBrowser": "Яндекс Браузер", "OPR/": "Opera", "Firefox/": "Firefox",
                       "Chrome/": "Chrome", "Safari/": "Safari"]
        let systems = ["iPhone": "iPhone", "iPad": "iPad", "Android": "Android", "Windows": "Windows",
                       "Mac OS X": "Mac", "Linux": "Linux"]
        let order = ["Edg/", "YaBrowser", "OPR/", "Firefox/", "Chrome/", "Safari/"]
        let b = order.first { ua.contains($0) }.flatMap { browser[$0] }
        let s = ["iPhone", "iPad", "Android", "Windows", "Mac OS X", "Linux"].first { ua.contains($0) }.flatMap { systems[$0] }
        return [b, s].compactMap { $0 }.joined(separator: ", ")
    }

    /// The person behind a session cookie, or nil when it has ended (logged
    /// out, idle too long, disabled, access expired).
    public func session(_ token: String) async throws -> (account: Account, sessionID: UUID)? {
        let rows = try await db.query("""
            UPDATE acc.session s SET last_seen_at = now()
            FROM acc.account a, sys.org_settings o
            WHERE s.token_hash = \(ByteBuffer(bytes: Tokens.hash(token))) AND s.revoked_at IS NULL AND s.expires_at > now()
              AND s.last_seen_at > now() - make_interval(mins => o.session_timeout_minutes)
              AND a.id = s.account_id AND a.status = 'active'
              AND (a.access_expires_at IS NULL OR a.access_expires_at > now())
            RETURNING \(unescaped: Self.accountColumns), s.id
            """)
        for try await row in rows {
            let account = try Self.decodeAccount(row)
            let sid = try row.decode((UUID, String, String, String, String, Date?, UUID).self).6
            return (account, sid)
        }
        return nil
    }

    public func logout(_ actor: Actor) async throws {
        guard let sid = actor.sessionID else { return }
        try await db.query("UPDATE acc.session SET revoked_at = now() WHERE id = \(sid) AND revoked_at IS NULL")
        await audit.write(.init("logout", objectType: "account", objectID: actor.account?.id,
                                objectName: actor.account?.login ?? ""), by: actor)
    }

    /// Own sessions: which devices are logged in.
    public func sessionsJSON(_ account: UUID, current: UUID?) async throws -> String {
        try await db.scalar("""
            SELECT coalesce(json_agg(json_build_object(
                'id', id, 'device', device_name, 'ip', host(ip), 'created_at', created_at,
                'last_seen_at', last_seen_at, 'current', id = \(current)) ORDER BY last_seen_at DESC), '[]')::text
            FROM acc.session WHERE account_id = \(account) AND revoked_at IS NULL AND expires_at > now()
            """, as: String.self) ?? "[]"
    }

    public func revokeSession(_ id: UUID, of account: UUID, by actor: Actor) async throws {
        let n = try await db.scalar("""
            UPDATE acc.session SET revoked_at = now() WHERE id = \(id) AND account_id = \(account)
              AND revoked_at IS NULL RETURNING 1
            """, as: Int.self)
        guard n != nil else { throw AccountError.notFound("Сеанс не найден") }
        await audit.write(.init("session_revoked", objectType: "account", objectID: account), by: actor)
    }

    public func changePassword(_ actor: Actor, current: String, new: String, code: String?) async throws {
        guard let a = actor.account else { throw AccountError.unauthorized("Войдите заново") }
        let hash = try await db.scalar("SELECT hash FROM acc.account_password WHERE account_id = \(a.id)", as: String.self)
        guard let hash, PasswordHash.verify(current, hash: hash) else {
            throw AccountError.badRequest("Текущий пароль неверный")
        }
        if let w = PasswordHash.weakness(new, login: a.login) { throw AccountError.badRequest(w) }
        try await stepUp(actor, code: code)
        let newHash = try PasswordHash.make(new)
        try await db.transaction { conn in
            try await conn.query("""
                UPDATE acc.account_password SET hash = \(newHash), changed_at = now(), must_change = false
                WHERE account_id = \(a.id)
                """, logger: logger)
            // Other devices log in again with the new password.
            try await conn.query("""
                UPDATE acc.session SET revoked_at = now()
                WHERE account_id = \(a.id) AND revoked_at IS NULL AND id IS DISTINCT FROM \(actor.sessionID)
                """, logger: logger)
            try await audit.write(.init("password_changed", objectType: "account", objectID: a.id, objectName: a.login),
                                  by: actor, on: conn)
        }
    }

    /// New recovery codes (the old ones stop working), after a fresh code.
    public func newRecoveryCodes(_ actor: Actor, code: String?) async throws -> [String] {
        guard let a = actor.account else { throw AccountError.unauthorized("Войдите заново") }
        try await stepUp(actor, code: code)
        let codes = (0..<8).map { _ in Tokens.recoveryCode() }
        try await db.transaction { conn in
            try await conn.query("DELETE FROM acc.recovery_code WHERE account_id = \(a.id)", logger: logger)
            for c in codes {
                try await conn.query("INSERT INTO acc.recovery_code (account_id, code_hash) VALUES (\(a.id), \(Self.recoveryHash(c)))",
                                     logger: logger)
            }
            try await audit.write(.init("recovery_codes_renewed", objectType: "account", objectID: a.id,
                                        objectName: a.login), by: actor, on: conn)
        }
        return codes
    }
}
