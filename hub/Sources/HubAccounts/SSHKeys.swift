import Crypto
import Foundation
import HubCore
import Logging
import NIOCore
import PostgresNIO

/// People's own SSH keys. The hub has no root access to servers, so it only
/// keeps the wish list in acc.staff_ssh_key_install ("this key should be on
/// that server" / "should be gone"); the owner's Mac, under the Rutoken,
/// carries it out and reports back.
public enum SSHKeys {
    public struct Parsed: Equatable, Sendable {
        public var type: String
        public var blob: [UInt8]
        public var comment: String
        /// SHA256:… as ssh-keygen -l prints it.
        public var fingerprint: String
        public var line: String { "\(type) \(Data(blob).base64EncodedString())" + (comment.isEmpty ? "" : " \(comment)") }
    }

    static let allowed = ["ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
                          "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com", "ssh-rsa"]

    /// One line of id_ed25519.pub. Options before the key type are refused:
    /// a pasted line must not smuggle in a forced command or a tunnel.
    public static func parse(_ text: String) throws -> Parsed {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 2)
            .map(String.init)
        guard parts.count >= 2, allowed.contains(parts[0]) else {
            throw AccountError.badRequest("Вставьте открытый ключ целиком: строку из файла id_ed25519.pub (начинается с ssh-ed25519)")
        }
        guard let blob = Data(base64Encoded: parts[1]), blob.count > 16 else {
            throw AccountError.badRequest("Ключ повреждён: не читается base64")
        }
        // The blob starts with its own type name; it must match the label.
        let bytes = Array(blob)
        let len = bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard bytes.count >= 4 + len, String(decoding: bytes[4..<(4 + len)], as: UTF8.self) == parts[0] else {
            throw AccountError.badRequest("Ключ повреждён: тип не совпадает с содержимым")
        }
        if parts[0] == "ssh-rsa", bytes.count < 270 { throw AccountError.badRequest("RSA-ключ короче 2048 бит не подойдёт") }
        let comment = parts.count > 2 ? String(parts[2].prefix(100)).filter { !$0.isNewline } : ""
        let fp = "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return Parsed(type: parts[0], blob: bytes, comment: comment, fingerprint: fp)
    }

    /// Recomputes where each of a person's keys should be: on every server
    /// where they may SSH without asking ("можно"); off everywhere else.
    /// Called after grants, keys or the person's status change.
    public static func sync(account: UUID, conn: PostgresConnection) async throws {
        try await conn.query("""
            INSERT INTO acc.staff_ssh_key_install AS i (key_id, server_id, want)
            SELECT k.id, s.id,
                   CASE WHEN a.status = 'active' AND k.revoked_at IS NULL
                             AND (a.access_expires_at IS NULL OR a.access_expires_at > now())
                             AND acc.permission_mode(a.id, 'ssh', 'server', s.id) = 'allow'
                        THEN 'installed' ELSE 'removed' END
            FROM acc.staff_ssh_key k
            JOIN acc.account a ON a.id = k.account_id
            CROSS JOIN inv.server s
            WHERE k.account_id = \(account) AND s.archived_at IS NULL
            ON CONFLICT (key_id, server_id) DO UPDATE SET want = EXCLUDED.want, updated_at = now()
              WHERE i.want <> EXCLUDED.want
            """, logger: Logger(label: "hub.accounts"))
        // Nothing to take off where it was never put.
        try await conn.query("""
            DELETE FROM acc.staff_ssh_key_install i USING acc.staff_ssh_key k
            WHERE i.key_id = k.id AND k.account_id = \(account) AND i.want = 'removed' AND i.installed_at IS NULL
            """, logger: Logger(label: "hub.accounts"))
    }

    public static func listJSON(_ db: Database, account: UUID) async throws -> String {
        try await db.scalar("""
            SELECT coalesce(json_agg(json_build_object(
                'id', k.id, 'label', k.label, 'fingerprint', k.fingerprint,
                'type', split_part(k.public_key, ' ', 1), 'created_at', k.created_at,
                'servers_wanted', (SELECT count(*) FROM acc.staff_ssh_key_install WHERE key_id = k.id AND want = 'installed'),
                'servers_installed', (SELECT count(*) FROM acc.staff_ssh_key_install
                                      WHERE key_id = k.id AND want = 'installed' AND installed_at IS NOT NULL
                                        AND (removed_at IS NULL OR removed_at < installed_at)),
                'pending', (SELECT count(*) FROM acc.staff_ssh_key_install i
                            WHERE i.key_id = k.id AND ((i.want = 'installed' AND i.installed_at IS NULL)
                               OR (i.want = 'removed' AND i.removed_at IS NULL))))
              ORDER BY k.created_at), '[]')::text
            FROM acc.staff_ssh_key k WHERE k.account_id = \(account) AND k.revoked_at IS NULL
            """, as: String.self) ?? "[]"
    }

    public static func add(_ accounts: Accounts, actor: Actor, text: String, label: String) async throws -> UUID {
        guard let a = actor.account else { throw AccountError.unauthorized("Войдите заново") }
        let key = try parse(text)
        let name = label.isEmpty ? key.comment : label
        return try await accounts.db.transaction { conn in
            if try await conn.one("SELECT 1 FROM acc.staff_ssh_key WHERE fingerprint = \(key.fingerprint)", as: Int.self) != nil {
                throw AccountError.conflict("Этот ключ уже добавлен")
            }
            let id = try await conn.one("""
                INSERT INTO acc.staff_ssh_key (account_id, public_key, fingerprint, label)
                VALUES (\(a.id), \(key.line), \(key.fingerprint), \(name)) RETURNING id
                """, as: UUID.self)!
            try await sync(account: a.id, conn: conn)
            try await accounts.audit.write(.init("ssh_key_added", objectType: "ssh_key", objectID: id, objectName: name,
                                                 detail: ["fingerprint": key.fingerprint]), by: actor, on: conn)
            return id
        }
    }

    public static func revoke(_ accounts: Accounts, actor: Actor, keyID: UUID, of account: UUID) async throws {
        try await accounts.db.transaction { conn in
            guard let fp = try await conn.one("""
                UPDATE acc.staff_ssh_key SET revoked_at = now()
                WHERE id = \(keyID) AND account_id = \(account) AND revoked_at IS NULL RETURNING fingerprint
                """, as: String.self) else { throw AccountError.notFound("Ключ не найден") }
            try await sync(account: account, conn: conn)
            try await accounts.audit.write(.init("ssh_key_revoked", objectType: "ssh_key", objectID: keyID,
                                                 detail: ["fingerprint": fp]), by: actor, on: conn)
        }
    }
}
