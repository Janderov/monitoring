import CArgon2
import Crypto
import Foundation

/// Passwords are kept only as argon2id hashes (the encoded "$argon2id$…"
/// string carries its own salt and cost, so the cost can be raised later
/// without breaking old hashes).
public enum PasswordHash {
    /// OWASP's minimum for argon2id: 19 MiB, 2 passes. Fits a 1 GB VPS even
    /// when several people log in at once.
    public static let memoryKiB: UInt32 = 19_456
    public static let passes: UInt32 = 2

    public static func make(_ password: String) throws -> String {
        let salt = Tokens.random(16)
        let pwd = Array(password.utf8)
        let len = argon2_encodedlen(passes, memoryKiB, 1, UInt32(salt.count), 32, Argon2_id)
        var out = [CChar](repeating: 0, count: len)
        let rc = argon2id_hash_encoded(passes, memoryKiB, 1, pwd, pwd.count, salt, salt.count, 32, &out, len)
        guard rc == ARGON2_OK.rawValue else { throw AccountError.internal("argon2: \(rc)") }
        return String(cString: out)
    }

    public static func verify(_ password: String, hash: String) -> Bool {
        let pwd = Array(password.utf8)
        return hash.withCString { argon2id_verify($0, pwd, pwd.count) } == ARGON2_OK.rawValue
    }

    /// What the cabinet says when a new password is not good enough; nil = fine.
    public static func weakness(_ password: String, login: String) -> String? {
        if password.count < 12 { return "Пароль должен быть не короче 12 символов" }
        if password.lowercased().contains(login.lowercased()) { return "Пароль не должен содержать логин" }
        if Set(password).count < 5 { return "Слишком простой пароль" }
        return nil
    }
}

/// Random tokens for sessions, invites and login steps. Only their SHA-256
/// goes to the database, so a copy of it lets nobody in.
public enum Tokens {
    public static func random(_ count: Int) -> [UInt8] {
        var g = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: 0...255, using: &g) }
    }

    /// 32 random bytes as URL-safe base64 without padding (43 characters).
    public static func make() -> String { base64url(random(32)) }

    public static func hash(_ token: String) -> [UInt8] { Array(SHA256.hash(data: Data(token.utf8))) }

    public static func base64url(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Recovery codes: 10 characters people can type, like "k7m2-x9qp-4t".
    public static func recoveryCode() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        var g = SystemRandomNumberGenerator()
        let chars = (0..<10).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &g)] }
        return String(chars[0..<4]) + "-" + String(chars[4..<8]) + "-" + String(chars[8..<10])
    }

    public static func normalizeRecovery(_ code: String) -> String {
        code.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

/// Time-based one-time codes (RFC 6238: SHA-1, 6 digits, 30 seconds), the
/// kind "Яндекс Ключ", Google Authenticator and Apple Passwords show.
public enum TOTP {
    public static let period: TimeInterval = 30
    public static let digits = 6

    public static func newSecret() -> [UInt8] { Tokens.random(20) }

    public static func step(_ date: Date) -> Int64 { Int64(floor(date.timeIntervalSince1970 / period)) }

    public static func code(secret: [UInt8], step: Int64) -> String {
        var counter = UInt64(bitPattern: step).bigEndian
        let message = withUnsafeBytes(of: &counter) { Data($0) }
        let mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: secret)))
        let offset = Int(mac[mac.count - 1] & 0x0f)
        let value = (UInt32(mac[offset] & 0x7f) << 24) | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])
        return String(format: "%06u", value % 1_000_000)
    }

    /// The matching time step, allowing one step of clock drift either way;
    /// steps at or before `after` are refused so a seen code cannot be reused.
    public static func match(_ code: String, secret: [UInt8], at date: Date, after: Int64? = nil) -> Int64? {
        let digitsOnly = code.filter(\.isNumber)
        guard digitsOnly.count == digits else { return nil }
        let now = step(date)
        for s in [now, now - 1, now + 1] where after.map({ s > $0 }) ?? true {
            if constantTimeEqual(Array(Self.code(secret: secret, step: s).utf8), Array(digitsOnly.utf8)) { return s }
        }
        return nil
    }

    /// otpauth://totp/Мониторинг:login?secret=…&issuer=Мониторинг
    public static func uri(secret: [UInt8], login: String, issuer: String) -> String {
        let label = "\(issuer):\(login)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? login
        let iss = issuer.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? issuer
        return "otpauth://totp/\(label)?secret=\(Base32.encode(secret))&issuer=\(iss)&algorithm=SHA1&digits=6&period=30"
    }

    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in a.indices { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}

public enum Base32 {
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    public static func encode(_ bytes: [UInt8]) -> String {
        var out = "", buffer = 0, bits = 0
        for b in bytes {
            buffer = (buffer << 8) | Int(b); bits += 8
            while bits >= 5 { out.append(alphabet[(buffer >> (bits - 5)) & 31]); bits -= 5 }
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return out
    }

    public static func decode(_ text: String) -> [UInt8]? {
        var out: [UInt8] = [], buffer = 0, bits = 0
        for ch in text.uppercased() where ch != "=" && ch != " " {
            guard let v = alphabet.firstIndex(of: ch) else { return nil }
            buffer = (buffer << 5) | v; bits += 5
            if bits >= 8 { out.append(UInt8((buffer >> (bits - 8)) & 0xff)); bits -= 8 }
        }
        return out
    }
}
