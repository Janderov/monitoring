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
}

public final class MemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]

    public init(_ values: [String: String] = [:]) { self.values = values }

    public func get(_ account: String) throws -> String? { lock.withLock { values[account] } }
    public func set(_ value: String, for account: String) throws { lock.withLock { values[account] = value } }
    public func remove(_ account: String) throws { lock.withLock { _ = values.removeValue(forKey: account) } }
}

#if canImport(Security)
/// Generic passwords in the login keychain under service com.janderov.monitor.
/// The app is signed ad hoc, so after installing a new build macOS asks once
/// whether it may read them; "Always Allow" keeps it quiet until the next build.
public struct KeychainSecrets: SecretStore {
    public let service: String

    public init(service: String = "com.janderov.monitor") { self.service = service }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func get(_ account: String) throws -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainError(status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func set(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(account)
            q[kSecValueData as String] = data
            q[kSecAttrLabel as String] = "Мониторинг: \(account)"
            let added = SecItemAdd(q as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(added) }
        } else if status != errSecSuccess {
            throw KeychainError(status)
        }
    }

    public func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status) }
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
