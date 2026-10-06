import Foundation

/// Owner login with a hardware key. Until a key is set up nothing changes;
/// once it is, the app starts locked and shows nothing until the key is
/// inserted and its PIN entered. Pulling the key out locks it again at once
/// (`startWatching` polls the token every second). `Auditor.perform` also
/// asks `AdminLock.authorize` before every change, so nothing slips through
/// a screen that forgot to hide.

/// What proves the owner is at the Mac. Rutoken Lite today (`RutokenLiteKey`);
/// a FIDO2 key (Rutoken MFA) can replace it later behind the same protocol.
public protocol AdminKey: Sendable {
    /// Stored with the record, so a later key type can tell old records apart.
    var kind: String { get }
    func inserted() throws -> [TokenInfo]
    /// Puts a fresh secret on the only inserted token and returns what the
    /// app keeps to recognise it later. Nothing secret is returned.
    func enroll(pin: String) throws -> EnrolledKey
    /// Throws unless the token with this id is inserted, the PIN opens it and
    /// it holds the secret matching `proof`.
    func verify(pin: String, keyID: String, proof: String) throws -> TokenInfo
    func changePIN(keyID: String, old: String, new: String) throws
}

public struct EnrolledKey: Equatable, Sendable {
    public var keyID: String
    public var keyName: String
    /// SHA-256 of the secret on the token, hex.
    public var proof: String
    public var token: TokenInfo
}

public enum AdminLockError: Error, Equatable, CustomStringConvertible, Sendable {
    case locked
    case notSetUp
    case severalTokens
    case wrongKey
    case noKeyData
    case wrongRecoveryCode

    public var description: String {
        switch self {
        case .locked: return "нужен ключ администратора: вставьте Рутокен и введите PIN"
        case .notSetUp: return "ключ администратора не настроен"
        case .severalTokens: return "вставлено несколько токенов, оставьте один"
        case .wrongKey: return "это не тот токен, который записан как ключ администратора"
        case .noKeyData: return "на токене нет ключа администратора, возможно, его очистили"
        case .wrongRecoveryCode: return "неверный код восстановления"
        }
    }
}

/// The secret is a private data object: reading it needs the PIN, and the
/// app keeps only its hash.
public struct RutokenLiteKey: AdminKey {
    public static let label = "monitor-admin-key"
    public static let application = "com.janderov.monitor"

    public let driver: TokenDriver
    public var kind: String { "rutoken-lite" }

    public init(driver: TokenDriver = PKCS11()) { self.driver = driver }

    public func inserted() throws -> [TokenInfo] { try driver.tokens() }

    public func enroll(pin: String) throws -> EnrolledKey {
        let tokens = try driver.tokens()
        guard let token = tokens.first else { throw TokenError.noToken }
        guard tokens.count == 1 else { throw AdminLockError.severalTokens }
        let secret = Digest.randomBytes(32)
        try driver.withSession(slot: token.slot, pin: pin) { s in
            try s.writeData(label: Self.label, application: Self.application, value: secret)
            guard let back = try s.readData(label: Self.label), Digest.equal(back, secret) else {
                throw TokenError.failed("проверка записи", 0)
            }
        }
        let name = token.label.isEmpty ? token.model : token.label
        return EnrolledKey(keyID: token.serial, keyName: name.isEmpty ? "Рутокен" : name,
                           proof: Digest.sha256Hex(secret), token: token)
    }

    public func verify(pin: String, keyID: String, proof: String) throws -> TokenInfo {
        let token = try find(keyID)
        let secret = try driver.withSession(slot: token.slot, pin: pin) { try $0.readData(label: Self.label) }
        guard let secret else { throw AdminLockError.noKeyData }
        guard Digest.equal(Array(Digest.sha256Hex(secret).utf8), Array(proof.utf8)) else { throw AdminLockError.wrongKey }
        return token
    }

    public func changePIN(keyID: String, old: String, new: String) throws {
        let token = try find(keyID)
        try driver.withSession(slot: token.slot, pin: old) { try $0.changePIN(old: old, new: new) }
    }

    private func find(_ keyID: String) throws -> TokenInfo {
        let tokens = try driver.tokens()
        if let t = tokens.first(where: { $0.serial == keyID }) { return t }
        throw tokens.isEmpty ? TokenError.noToken : AdminLockError.wrongKey
    }
}

/// What the app remembers about the key, in Keychain. No secrets: the token
/// secret and the recovery code are stored only as hashes.
public struct AdminKeyRecord: Codable, Equatable, Sendable {
    public var kind: String
    public var keyID: String
    public var keyName: String
    public var proof: String
    public var recoverySalt: String
    public var recoveryHash: String
    public var enrolledAt: Date
}

/// A one-time-shown code that unlocks the app when the token is lost.
public enum RecoveryCode {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// 24 characters (120 bits) in groups of four: "7KQ2-…".
    public static func make() -> String {
        let chars = Digest.randomBytes(24).map { alphabet[Int($0 & 31)] }
        return stride(from: 0, to: 24, by: 4).map { String(chars[$0..<$0 + 4]) }.joined(separator: "-")
    }

    /// Case, spaces, dashes and look-alike letters do not matter.
    public static func normalize(_ code: String) -> String {
        String(code.uppercased().compactMap { c -> Character? in
            switch c {
            case "-", " ", "\n", "\t": return nil
            case "O": return "0"
            case "I", "L": return "1"
            default: return c
            }
        })
    }

    public static func hash(_ code: String, salt: String) -> String {
        Digest.sha256Hex(Array((salt + normalize(code)).utf8))
    }
}

public enum AdminLockState: String, Equatable, Sendable {
    /// No key set up: the app works as before.
    case off
    case locked
    case unlocked
}

/// Which token is in the reader, for the lock screen.
public enum KeyPresence: String, Equatable, Sendable {
    /// The Rutoken driver is not installed.
    case noDriver
    /// Nothing inserted: «Вставьте ваш токен».
    case none
    /// The token set up as the key: ask for the PIN.
    case mine
    /// Some other token: «Это не ваш токен».
    case other
}

public struct AdminLockStatus: Equatable, Sendable {
    public var state: AdminLockState
    /// What is inserted now; refreshed by `startWatching`.
    public var presence: KeyPresence
    /// Name of the token set up as the key, e.g. "Rutoken Lite".
    public var keyName: String?
    /// Serial number of that token.
    public var keyID: String?
    /// Opened with the recovery code; the token does not have to be inserted.
    public var unlockedByRecovery: Bool
    /// The token still has the factory PIN (12345678): ask to change it.
    public var defaultPIN: Bool
}

/// Unlock result for the screen: whether to nag about the factory PIN.
public struct UnlockResult: Equatable, Sendable {
    public var defaultPIN: Bool
}

public struct EnrollResult: Equatable, Sendable {
    /// Show once and ask to write it down; it is not stored anywhere.
    public var recoveryCode: String
    public var defaultPIN: Bool
}

public actor AdminLock {
    public static let factoryPIN = "12345678"
    /// A recovery-code unlock (no token in the reader) expires after this
    /// long without changes. A token unlock lasts while the token is in.
    public static let recoveryIdle: TimeInterval = 15 * 60

    private let key: AdminKey
    private let secrets: SecretStore
    private let store: Store?
    private let now: @Sendable () -> Date
    private let idle: TimeInterval?
    private var record: AdminKeyRecord?
    private var state: AdminLockState
    private var byRecovery = false
    private var defaultPIN = false
    private var lastActivity = Date.distantPast
    private var presence = KeyPresence.none
    private var onChange: (@Sendable (AdminLockStatus) -> Void)?
    private var watcher: Task<Void, Never>?

    public init(key: AdminKey = RutokenLiteKey(), secrets: SecretStore, store: Store? = nil,
                idle: TimeInterval? = nil, now: @escaping @Sendable () -> Date = Date.init) {
        self.key = key
        self.secrets = secrets
        self.store = store
        self.idle = idle
        self.now = now
        let saved = (try? secrets.get(SecretKey.adminKey)).flatMap { try? Self.decode($0) }
        record = saved
        state = saved == nil ? .off : .locked
    }

    public func status() -> AdminLockStatus {
        AdminLockStatus(state: state, presence: presence, keyName: record?.keyName, keyID: record?.keyID,
                        unlockedByRecovery: state == .unlocked && byRecovery, defaultPIN: defaultPIN)
    }

    public func setOnChange(_ handler: (@Sendable (AdminLockStatus) -> Void)?) { onChange = handler }

    /// Tokens inserted now, for the setup screen. Throws TokenError.noDriver
    /// when the Rutoken driver is not installed.
    public func insertedTokens() throws -> [TokenInfo] { try key.inserted() }

    /// Writes a new secret to the inserted token and makes it the key. Allowed
    /// when no key is set up, or when unlocked (to replace a lost token).
    public func enroll(pin: String) async throws -> EnrollResult {
        guard state != .locked else { throw AdminLockError.locked }
        do {
            let enrolled = try key.enroll(pin: pin)
            let code = RecoveryCode.make()
            let salt = Digest.randomBytes(16).map { String(format: "%02x", $0) }.joined()
            let rec = AdminKeyRecord(kind: key.kind, keyID: enrolled.keyID, keyName: enrolled.keyName,
                                     proof: enrolled.proof, recoverySalt: salt,
                                     recoveryHash: RecoveryCode.hash(code, salt: salt), enrolledAt: now())
            try secrets.set(try Self.encode(rec), for: SecretKey.adminKey)
            record = rec
            defaultPIN = pin == Self.factoryPIN || enrolled.token.pinToBeChanged
            open(byRecovery: false)
            await log(.manageAccess, "ключ администратора записан на токен \(rec.keyID)", nil)
            return EnrollResult(recoveryCode: code, defaultPIN: defaultPIN)
        } catch {
            await log(.manageAccess, "запись ключа администратора", error)
            throw error
        }
    }

    public func unlock(pin: String) async throws -> UnlockResult {
        guard let record else { throw AdminLockError.notSetUp }
        do {
            let token = try key.verify(pin: pin, keyID: record.keyID, proof: record.proof)
            defaultPIN = pin == Self.factoryPIN || token.pinToBeChanged
            open(byRecovery: false)
            await log(.adminLogin, "по ключу \(record.keyID)", nil)
            return UnlockResult(defaultPIN: defaultPIN)
        } catch {
            await log(.adminLogin, "по ключу \(record.keyID)", error)
            throw error
        }
    }

    /// Opens without the token, e.g. to set up a new one after a loss.
    public func unlock(recoveryCode: String) async throws {
        guard let record else { throw AdminLockError.notSetUp }
        guard Digest.equal(Array(RecoveryCode.hash(recoveryCode, salt: record.recoverySalt).utf8),
                           Array(record.recoveryHash.utf8)) else {
            await log(.adminLogin, "по коду восстановления", AdminLockError.wrongRecoveryCode)
            throw AdminLockError.wrongRecoveryCode
        }
        open(byRecovery: true)
        await log(.adminLogin, "по коду восстановления", nil)
    }

    public func lock() {
        guard state == .unlocked else { return }
        refreshPresence()
        state = .locked
        byRecovery = false
        changed()
    }

    /// Changes the token PIN (e.g. away from the factory 12345678).
    public func changePIN(old: String, new: String) async throws {
        guard let record else { throw AdminLockError.notSetUp }
        do {
            try key.changePIN(keyID: record.keyID, old: old, new: new)
            defaultPIN = new == Self.factoryPIN
            changed()
            await log(.manageAccess, "смена PIN токена \(record.keyID)", nil)
        } catch {
            await log(.manageAccess, "смена PIN токена \(record.keyID)", error)
            throw error
        }
    }

    /// A new recovery code replacing the old one. Needs the app unlocked.
    public func newRecoveryCode() async throws -> String {
        guard var rec = record else { throw AdminLockError.notSetUp }
        guard state == .unlocked else { throw AdminLockError.locked }
        let code = RecoveryCode.make()
        rec.recoveryHash = RecoveryCode.hash(code, salt: rec.recoverySalt)
        try secrets.set(try Self.encode(rec), for: SecretKey.adminKey)
        record = rec
        await log(.manageAccess, "новый код восстановления", nil)
        return code
    }

    /// Turns key login off; the app then works without it, as before setup.
    public func disable() async throws {
        guard record != nil else { return }
        guard state == .unlocked else { throw AdminLockError.locked }
        try secrets.remove(SecretKey.adminKey)
        record = nil
        state = .off
        byRecovery = false
        defaultPIN = false
        changed()
        await log(.manageAccess, "вход по ключу администратора отключён", nil)
    }

    /// Called before every change. Unlocked by the token means the token must
    /// still be inserted; with `idle` set, an unlock also expires after that
    /// long without changes.
    public func authorize(_ action: UserAction) throws {
        guard action.needsAdminKey, record != nil else { return }
        guard state == .unlocked else { throw AdminLockError.locked }
        if expired() {
            lock()
            throw AdminLockError.locked
        }
        if !byRecovery {
            refreshPresence()
            guard presence == .mine else {
                lock()
                throw AdminLockError.locked
            }
        }
        lastActivity = now()
    }

    /// Notices the token going in or out: locks at once when the key is
    /// pulled out, and tells the lock screen what is inserted.
    public func check() {
        guard record != nil else { return }
        let before = presence
        refreshPresence()
        if state == .unlocked, expired() || (!byRecovery && presence != .mine) { return lock() }
        if presence != before { changed() }
    }

    /// Runs `check` every second (by default) until `stopWatching`. Asking a
    /// PKCS#11 library which tokens are present is cheap.
    public func startWatching(every seconds: TimeInterval = 1) {
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                await self?.check()
            }
        }
    }

    public func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    private func expired() -> Bool {
        guard let limit = byRecovery ? min(idle ?? Self.recoveryIdle, Self.recoveryIdle) : idle else { return false }
        return now().timeIntervalSince(lastActivity) > limit
    }

    private func refreshPresence() {
        guard let record else { presence = .none; return }
        do {
            let tokens = try key.inserted()
            presence = tokens.contains { $0.serial == record.keyID } ? .mine : tokens.isEmpty ? .none : .other
        } catch TokenError.noDriver {
            presence = .noDriver
        } catch {
            presence = .none
        }
    }

    private func open(byRecovery: Bool) {
        refreshPresence()
        state = .unlocked
        self.byRecovery = byRecovery
        lastActivity = now()
        changed()
    }

    private func changed() {
        onChange?(status())
    }

    private func log(_ action: UserAction, _ detail: String, _ error: Error?) async {
        guard let store else { return }
        let rec = AuditRecord(id: UUID().uuidString, time: now(), actor: .owner, action: action, object: .app,
                              detail: detail, result: error == nil ? .done : .failed, error: error.map { "\($0)" })
        try? await store.addAction(rec)
    }

    static func encode(_ r: AdminKeyRecord) throws -> String {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        return String(decoding: try enc.encode(r), as: UTF8.self)
    }

    static func decode(_ s: String) throws -> AdminKeyRecord {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return try dec.decode(AdminKeyRecord.self, from: Data(s.utf8))
    }
}
