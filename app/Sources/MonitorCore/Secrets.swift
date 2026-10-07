import Foundation
#if canImport(Security)
import Security
#endif

/// Where agent tokens and saved SSH passwords live: Keychain on macOS,
/// memory in tests and previews.
public protocol SecretStore: Sendable {
    func get(_ account: String) throws -> String?
    func set(_ value: String, for account: String) throws
    func remove(_ account: String) throws
}

/// Account names under which secrets are stored.
public enum SecretKey {
    public static func agentToken(_ serverID: String) -> String { "agent-token:" + serverID }
    public static func sshPassword(_ serverID: String) -> String { "ssh-password:" + serverID }
    public static func siteAuth(_ siteID: String) -> String { "site-auth:" + siteID }
    /// AdminKeyRecord as JSON: token serial and hashes, no secrets.
    public static let adminKey = "admin-key"
}

public final class MemorySecrets: SecretStore, SecretListing, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]

    public init(_ values: [String: String] = [:]) { self.values = values }

    public func get(_ account: String) throws -> String? { lock.withLock { values[account] } }
    public func set(_ value: String, for account: String) throws { lock.withLock { values[account] = value } }
    public func remove(_ account: String) throws { lock.withLock { _ = values.removeValue(forKey: account) } }
    public func accounts() throws -> [String] { lock.withLock { Array(values.keys) } }
}

/// Raw items of one secret store: in Keychain, one generic password per
/// account under the app's service.
public protocol SecretItems: Sendable {
    func read(_ account: String) throws -> Data?
    func write(_ data: Data, for account: String) throws
    func delete(_ account: String) throws
    /// Account names only; listing reads no secrets, so it never prompts.
    func accounts() throws -> [String]
}

/// All secrets in one item, "vault", as a JSON dictionary.
///
/// The app is signed ad hoc, so every new build is a stranger to Keychain
/// and macOS asks for the login password once per item it reads. With one
/// item per server token, SSH and site password that was a dozen prompts
/// after each update; with the vault it is one. The vault is read once and
/// kept in memory, so a plain "Allow" also covers the whole run.
///
/// Items saved by older versions (one per account) are moved into the vault
/// the first time it is missing, then deleted.
public final class VaultSecrets: SecretStore, SecretListing, @unchecked Sendable {
    public static let vaultAccount = "vault"

    private let items: SecretItems
    private let lock = NSLock()
    private var cache: [String: String]?

    public init(items: SecretItems) { self.items = items }

    public func get(_ account: String) throws -> String? {
        try lock.withLock { try loaded()[account] }
    }

    public func set(_ value: String, for account: String) throws {
        try lock.withLock {
            var all = try loaded()
            guard all[account] != value else { return }
            all[account] = value
            try save(all)
        }
    }

    public func remove(_ account: String) throws {
        try lock.withLock {
            var all = try loaded()
            guard all.removeValue(forKey: account) != nil else { return }
            try save(all)
        }
    }

    public func accounts() throws -> [String] {
        try lock.withLock { Array(try loaded().keys) }
    }

    private func loaded() throws -> [String: String] {
        if let cache { return cache }
        if let data = try items.read(Self.vaultAccount) {
            let all = try JSONDecoder().decode([String: String].self, from: data)
            cache = all
            return all
        }
        // First run of a version with the vault: gather the old items. If
        // one cannot be read (the prompt was denied), nothing is written or
        // deleted, and the move is tried again next time.
        let legacy = try items.accounts().filter { $0 != Self.vaultAccount }
        var all: [String: String] = [:]
        for account in legacy {
            if let data = try items.read(account) { all[account] = String(decoding: data, as: UTF8.self) }
        }
        try save(all)
        for account in legacy { try? items.delete(account) }
        return all
    }

    private func save(_ all: [String: String]) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        try items.write(try enc.encode(all), for: Self.vaultAccount)
        cache = all
    }
}

#if canImport(Security)
/// Secrets in the login keychain under service com.janderov.monitor, all in
/// one vault item (see VaultSecrets), with SSH and site passwords and the
/// GitHub token sealed by the admin key (see SealedSecrets). Every instance
/// for a service shares one vault, so the item is read once per run and an
/// unlock opens the sealed secrets for every screen.
public struct KeychainSecrets: SealingStore {
    public let service: String
    private let vault: SealedSecrets

    private final class Vaults: @unchecked Sendable {
        let lock = NSLock()
        var byService: [String: SealedSecrets] = [:]
    }
    private static let vaults = Vaults()

    public init(service: String = "com.janderov.monitor") {
        self.service = service
        let vaults = Self.vaults
        vault = vaults.lock.withLock {
            if let v = vaults.byService[service] { return v }
            let v = SealedSecrets(base: VaultSecrets(items: KeychainItems(service: service)))
            vaults.byService[service] = v
            return v
        }
    }

    public func get(_ account: String) throws -> String? { try vault.get(account) }
    public func set(_ value: String, for account: String) throws { try vault.set(value, for: account) }
    public func remove(_ account: String) throws { try vault.remove(account) }
    public var sealing: SealedSecrets { vault }
}

/// Generic passwords in the login keychain, one per account.
struct KeychainItems: SecretItems {
    let service: String

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read(_ account: String) throws -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainError(status) }
        return data
    }

    func write(_ data: Data, for account: String) throws {
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(account)
            q[kSecValueData as String] = data
            q[kSecAttrLabel as String] = account == VaultSecrets.vaultAccount
                ? "Мониторинг: пароли и токены" : "Мониторинг: \(account)"
            let added = SecItemAdd(q as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(added) }
        } else if status != errSecSuccess {
            throw KeychainError(status)
        }
    }

    func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status) }
    }

    func accounts() throws -> [String] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitAll]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let rows = out as? [[String: Any]] else { throw KeychainError(status) }
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

public struct KeychainError: Error, CustomStringConvertible, Sendable {
    public var status: OSStatus
    init(_ status: OSStatus) { self.status = status }
    public var description: String {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "код \(status)"
        return "Связка ключей: \(text)"
    }
}
#endif
