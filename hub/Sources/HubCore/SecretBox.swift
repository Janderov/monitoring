import Crypto
import Foundation

/// Seals the secrets the hub needs without a person (agent tokens, site
/// passwords) for `sys.secret`: AES-256-GCM with the key from the hub's
/// credentials folder, so a copy of the database or a backup alone gives
/// nothing away. The row's id and kind are bound in as associated data: a
/// sealed value copied into another row does not open.
public struct SecretBox: Sendable {
    public static let keyVersion = 1
    let keyBytes: Data
    var key: SymmetricKey { SymmetricKey(data: keyBytes) }

    public init(key: Data) throws {
        guard key.count == 32 else { throw HubConfig.Error("ключ шифрования должен быть 32 байта") }
        self.keyBytes = key
    }

    public struct Sealed: Equatable, Sendable {
        /// Ciphertext followed by the 16-byte tag.
        public var ciphertext: [UInt8]
        public var nonce: [UInt8]
    }

    public func seal(_ plaintext: String, id: UUID, kind: String) throws -> Sealed {
        let box = try AES.GCM.seal(Data(plaintext.utf8), using: key, authenticating: Self.aad(id, kind))
        return Sealed(ciphertext: Array(box.ciphertext) + Array(box.tag), nonce: Array(box.nonce))
    }

    public func open(_ sealed: Sealed, id: UUID, kind: String) throws -> String {
        guard sealed.ciphertext.count >= 16 else { throw HubConfig.Error("секрет \(id) повреждён") }
        let body = sealed.ciphertext.dropLast(16), tag = sealed.ciphertext.suffix(16)
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: sealed.nonce), ciphertext: body, tag: tag)
            return String(decoding: try AES.GCM.open(box, using: key, authenticating: Self.aad(id, kind)), as: UTF8.self)
        } catch {
            throw HubConfig.Error("секрет \(id) не открывается этим ключом")
        }
    }

    static func aad(_ id: UUID, _ kind: String) -> Data {
        var d = withUnsafeBytes(of: id.uuid) { Data($0) }
        d.append(Data(kind.utf8))
        return d
    }
}
