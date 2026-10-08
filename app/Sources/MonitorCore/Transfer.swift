import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Moving the monitoring to another Mac (the Mac mini): servers and sites,
/// the secrets they use (agent tokens, SSH and site passwords) and the whole
/// history, in one file encrypted with a password the person chooses.
///
/// File: "MONITOR-TRANSFER-1\n", 16 bytes of salt, the PBKDF2 round count
/// (UInt32, big-endian), then AES-GCM (nonce, ciphertext, tag) over the
/// length of the JSON part (UInt32, big-endian), the JSON part and the
/// SQLite database.
public enum Transfer {
    public static let fileExtension = "monitortransfer"
    public static let minPasswordLength = 8
    static let magic = Data("MONITOR-TRANSFER-1\n".utf8)
    public static let iterations: UInt32 = 300_000

    public struct Contents: Codable, Equatable, Sendable {
        public var created: Date
        /// servers.json as written by the app, without tokens.
        public var servers: Data
        /// Secret store accounts (SecretKey) and their values.
        public var secrets: [String: String]

        public init(created: Date, servers: Data, secrets: [String: String]) {
            self.created = created; self.servers = servers; self.secrets = secrets
        }
    }

    public struct Error: Swift.Error, CustomStringConvertible, Sendable {
        public var description: String
        public init(_ d: String) { description = d }
    }

    public static func seal(_ contents: Contents, database: Data, password: String,
                            iterations: UInt32 = Transfer.iterations) throws -> Data {
        guard password.count >= minPasswordLength else {
            throw Error("пароль должен быть не короче \(minPasswordLength) символов")
        }
        let json = try JSONEncoder().encode(contents)
        var payload = Data()
        payload.append(bigEndian: UInt32(json.count))
        payload.append(json)
        payload.append(database)
        var salt = Data(count: 16)
        for i in salt.indices { salt[i] = UInt8.random(in: 0...255) }
        let key = derive(password, salt: salt, iterations: iterations)
        guard let sealed = try AES.GCM.seal(payload, using: key).combined else { throw Error("не удалось зашифровать") }
        var out = magic
        out.append(salt)
        out.append(bigEndian: iterations)
        out.append(sealed)
        return out
    }

    public static func open(_ file: Data, password: String) throws -> (contents: Contents, database: Data) {
        let data = Data(file)
        let head = magic.count + 16 + 4
        guard data.count > head, data.prefix(magic.count) == magic else {
            throw Error("это не файл переноса Монитора")
        }
        let salt = data.subdata(in: magic.count..<magic.count + 16)
        let rounds = data.subdata(in: magic.count + 16..<head).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        // A damaged count must not make the Mac compute for hours.
        guard (1_000...10_000_000).contains(rounds) else { throw Error("файл повреждён") }
        let payload: Data
        do {
            let box = try AES.GCM.SealedBox(combined: data.subdata(in: head..<data.count))
            payload = try AES.GCM.open(box, using: derive(password, salt: salt, iterations: rounds))
        } catch {
            throw Error("неверный пароль или файл повреждён")
        }
        guard payload.count >= 4 else { throw Error("файл повреждён") }
        let length = Int(payload.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard payload.count >= 4 + length else { throw Error("файл повреждён") }
        let start = payload.startIndex
        let contents = try JSONDecoder().decode(Contents.self, from: payload.subdata(in: start + 4..<start + 4 + length))
        return (contents, payload.subdata(in: start + 4 + length..<payload.endIndex))
    }

    /// PBKDF2-HMAC-SHA256, one 32-byte block (RFC 8018).
    static func derive(_ password: String, salt: Data, iterations: UInt32) -> SymmetricKey {
        let key = SymmetricKey(data: Data(password.utf8))
        var block = salt
        block.append(bigEndian: UInt32(1))
        var u = Data(HMAC<SHA256>.authenticationCode(for: block, using: key))
        var out = [UInt8](u)
        if iterations > 1 {
            for _ in 2...iterations {
                u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
                for (i, b) in u.enumerated() { out[i] ^= b }
            }
        }
        return SymmetricKey(data: out)
    }

    /// Puts a database brought by an import in place before the store opens
    /// it; the database it replaces is kept in `keep`.
    public static func applyPendingDatabase(pending: URL, database: URL, keep: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: pending.path) else { return }
        try fm.createDirectory(at: keep.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try? fm.removeItem(at: keep)
        if fm.fileExists(atPath: database.path) { try fm.moveItem(at: database, to: keep) }
        for suffix in ["-wal", "-shm"] { try? fm.removeItem(atPath: database.path + suffix) }
        try fm.moveItem(at: pending, to: database)
    }
}

extension Data {
    mutating func append(bigEndian value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}

extension ConfigRepository {
    /// The servers and sites with every secret they use. Fails while sealed
    /// passwords are locked: the person unlocks the app first.
    public func exportContents(now: Date = Date()) throws -> Transfer.Contents {
        let file = try load()
        var values: [String: String] = [:]
        for s in file.servers {
            if !s.token.isEmpty { values[SecretKey.agentToken(s.id)] = s.token }
            if let p = try secretStore.get(SecretKey.sshPassword(s.id)) { values[SecretKey.sshPassword(s.id)] = p }
        }
        for site in file.sites ?? [] where site.authUser != nil {
            if site.authLocked { throw SecretsLockedError() }
            if let p = site.authPassword { values[SecretKey.siteAuth(site.id)] = p }
        }
        var stripped = file
        for i in stripped.servers.indices { stripped.servers[i].token = "" }
        return Transfer.Contents(created: now, servers: try stripped.encoded(), secrets: values)
    }

    /// Replaces the servers and sites with the imported ones and saves their
    /// secrets. Nothing is written unless the whole list is valid.
    @discardableResult
    public func importContents(_ c: Transfer.Contents) throws -> ServersFile {
        var file = try ServersFile.decode(c.servers)
        for i in file.servers.indices {
            file.servers[i].token = c.secrets[SecretKey.agentToken(file.servers[i].id)] ?? file.servers[i].token
        }
        try file.validate()
        for (account, value) in c.secrets { try secretStore.set(value, for: account) }
        try replace(with: file)
        return file
    }
}
