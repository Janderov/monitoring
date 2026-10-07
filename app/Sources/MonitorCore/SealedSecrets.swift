import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

extension SecretKey {
    /// Secrets that let someone act on the servers or the repository: SSH and
    /// site passwords and the GitHub token. Once an admin key is set up they
    /// are encrypted with a key that only the token (or the recovery code)
    /// can open. Agent tokens stay readable, so monitoring and notifications
    /// keep working while the app is locked.
    public static func isSealed(_ account: String) -> Bool {
        account.hasPrefix("ssh-password:") || account.hasPrefix("site-auth:") || account == githubToken
    }
}

public struct SecretsLockedError: Error, CustomStringConvertible, Sendable {
    public init() {}
    public var description: String { "пароли зашифрованы ключом администратора: вставьте Рутокен и введите PIN" }
}

/// A store that can list its account names, so sealing can find what to move.
public protocol SecretListing {
    func accounts() throws -> [String]
}

/// A store whose sealed secrets can be locked away (see `SealedSecrets`).
public protocol SealingStore: SecretStore {
    var sealing: SealedSecrets { get }
}

/// Keeps the secrets `SecretKey.isSealed` names in one AES-GCM box (account
/// "sealed" of the underlying store) instead of in the clear. The box key is
/// held only in memory while the admin lock is open, so without the token
/// nobody, the app included, can read them; anything else passes through.
///
/// Before `seal` is first called (no admin key yet) everything stays in the
/// clear, as before.
public final class SealedSecrets: SealingStore, @unchecked Sendable {
    public static let boxAccount = "sealed"

    private let base: SecretStore
    private let lock = NSLock()
    private var key: SymmetricKey?
    private var contents: [String: String]?

    public init(base: SecretStore) { self.base = base }

    public var sealing: SealedSecrets { self }

    /// The sealed secrets are in the box (an admin key was set up).
    public var isSealed: Bool { lock.withLock { (try? base.get(Self.boxAccount)) != nil } }
    /// The box key is in memory: sealed secrets can be read and changed.
    public var isOpen: Bool { lock.withLock { key != nil } }

    public func get(_ account: String) throws -> String? {
        guard SecretKey.isSealed(account) else { return try base.get(account) }
        return try lock.withLock {
            guard try base.get(Self.boxAccount) != nil else { return try base.get(account) }
            guard let contents else { throw SecretsLockedError() }
            return contents[account]
        }
    }

    public func set(_ value: String, for account: String) throws {
        guard SecretKey.isSealed(account) else { return try base.set(value, for: account) }
        try lock.withLock {
            guard try base.get(Self.boxAccount) != nil else { return try base.set(value, for: account) }
            guard var all = contents else { throw SecretsLockedError() }
            all[account] = value
            try save(all)
        }
    }

    /// Removing while locked leaves the old value in the box: it is
    /// encrypted, and the next change while open drops nothing else.
    public func remove(_ account: String) throws {
        guard SecretKey.isSealed(account) else { return try base.remove(account) }
        try lock.withLock {
            try base.remove(account)
            guard var all = contents, all[account] != nil else { return }
            all[account] = nil
            try save(all)
        }
    }

    /// Moves the sealed secrets into a new box under `key` and keeps it open.
    /// Throws if a box already exists (open it instead).
    public func seal(with key: [UInt8]) throws {
        try lock.withLock {
            guard try base.get(Self.boxAccount) == nil else { throw SealError.alreadySealed }
            let all = try plaintextSealed()
            self.key = SymmetricKey(data: key)
            do { try save(all) } catch { self.key = nil; throw error }
            for account in all.keys { try base.remove(account) }
        }
    }

    /// Opens the box with `key`; wrong key or a damaged box throws. Sealed
    /// secrets left in the clear (an interrupted `seal`) are moved in.
    public func open(with key: [UInt8]) throws {
        try lock.withLock {
            guard let box = try base.get(Self.boxAccount) else { throw SealError.notSealed }
            let k = SymmetricKey(data: key)
            var all = try Self.decrypt(box, key: k)
            self.key = k
            contents = all
            let stray = try plaintextSealed()
            guard !stray.isEmpty else { return }
            all.merge(stray) { inBox, _ in inBox }
            try save(all)
            for account in stray.keys { try base.remove(account) }
        }
    }

    /// Forgets the key: sealed secrets cannot be read until `open`.
    public func close() {
        lock.withLock {
            key = nil
            contents = nil
        }
    }

    /// Puts the sealed secrets back in the clear and deletes the box (the
    /// admin key is being turned off). Needs the box open.
    public func unseal() throws {
        try lock.withLock {
            guard try base.get(Self.boxAccount) != nil else { return }
            guard let all = contents else { throw SecretsLockedError() }
            for (account, value) in all { try base.set(value, for: account) }
            try base.remove(Self.boxAccount)
            key = nil
            contents = nil
        }
    }

    /// Deletes a box that can no longer be opened (its wrapped keys are gone).
    public func discard() throws {
        try lock.withLock {
            try base.remove(Self.boxAccount)
            key = nil
            contents = nil
        }
    }

    private func plaintextSealed() throws -> [String: String] {
        guard let listing = base as? SecretListing else { return [:] }
        var out: [String: String] = [:]
        for account in try listing.accounts() where SecretKey.isSealed(account) {
            if let v = try base.get(account) { out[account] = v }
        }
        return out
    }

    private func save(_ all: [String: String]) throws {
        guard let key else { throw SecretsLockedError() }
        try base.set(try Self.encrypt(all, key: key), for: Self.boxAccount)
        contents = all
    }

    static func encrypt(_ all: [String: String], key: SymmetricKey) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let box = try AES.GCM.seal(try enc.encode(all), using: key)
        guard let combined = box.combined else { throw SealError.damaged }
        return combined.base64EncodedString()
    }

    static func decrypt(_ text: String, key: SymmetricKey) throws -> [String: String] {
        guard let data = Data(base64Encoded: text) else { throw SealError.damaged }
        let plain: Data
        do { plain = try AES.GCM.open(try AES.GCM.SealedBox(combined: data), using: key) } catch { throw SealError.wrongKey }
        return try JSONDecoder().decode([String: String].self, from: plain)
    }
}

public enum SealError: Error, Equatable, CustomStringConvertible, Sendable {
    case alreadySealed, notSealed, wrongKey, damaged

    public var description: String {
        switch self {
        case .alreadySealed: return "пароли уже зашифрованы"
        case .notSealed: return "пароли не зашифрованы"
        case .wrongKey: return "ключ не подходит к зашифрованным паролям"
        case .damaged: return "зашифрованные пароли повреждены"
        }
    }
}

/// The box key, wrapped (AES-GCM) for keeping next to the admin key record:
/// once with a key derived from the secret on the token, once with one
/// derived from the recovery code.
public enum KeyWrap {
    public static func newDataKey() -> [UInt8] { Digest.randomBytes(32) }

    public static func wrap(_ dataKey: [UInt8], with secret: [UInt8], context: String) throws -> String {
        let box = try AES.GCM.seal(Data(dataKey), using: derive(secret, context))
        guard let combined = box.combined else { throw SealError.damaged }
        return combined.base64EncodedString()
    }

    public static func unwrap(_ wrapped: String, with secret: [UInt8], context: String) throws -> [UInt8] {
        guard let data = Data(base64Encoded: wrapped) else { throw SealError.damaged }
        do {
            return Array(try AES.GCM.open(try AES.GCM.SealedBox(combined: data), using: derive(secret, context)))
        } catch {
            throw SealError.wrongKey
        }
    }

    private static func derive(_ secret: [UInt8], _ context: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret),
                               salt: Data("com.janderov.monitor/sealed".utf8),
                               info: Data(context.utf8), outputByteCount: 32)
    }
}
