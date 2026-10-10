import Foundation
import XCTest
@testable import HubAccounts

final class CryptoTests: XCTestCase {
    /// RFC 6238 appendix B, SHA-1 secret "12345678901234567890".
    func testTOTPMatchesTheRFC() {
        let secret = Array("12345678901234567890".utf8)
        let cases: [(TimeInterval, String)] = [(59, "287082"), (1_111_111_109, "081804"), (1_234_567_890, "005924"),
                                               (2_000_000_000, "279037")]
        for (t, code) in cases {
            XCTAssertEqual(TOTP.code(secret: secret, step: TOTP.step(Date(timeIntervalSince1970: t))), code)
        }
    }

    func testTOTPAllowsOneStepOfDriftAndNoReuse() {
        let secret = TOTP.newSecret()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let step = TOTP.step(now)
        let previous = TOTP.code(secret: secret, step: step - 1)
        XCTAssertEqual(TOTP.match(previous, secret: secret, at: now), step - 1)
        XCTAssertNil(TOTP.match(TOTP.code(secret: secret, step: step - 2), secret: secret, at: now))
        // Once a step was used, it and older steps are refused.
        XCTAssertNil(TOTP.match(previous, secret: secret, at: now, after: step - 1))
        XCTAssertEqual(TOTP.match(TOTP.code(secret: secret, step: step), secret: secret, at: now, after: step - 1), step)
        // Spaces are fine, wrong length is not.
        let c = TOTP.code(secret: secret, step: step)
        XCTAssertEqual(TOTP.match(String(c.prefix(3)) + " " + String(c.suffix(3)), secret: secret, at: now), step)
        XCTAssertNil(TOTP.match("12345", secret: secret, at: now))
    }

    func testBase32RoundTripAndURI() {
        let bytes = Array("foobar".utf8)
        XCTAssertEqual(Base32.encode(bytes), "MZXW6YTBOI")
        XCTAssertEqual(Base32.decode("MZXW6YTBOI"), bytes)
        let secret = TOTP.newSecret()
        XCTAssertEqual(Base32.decode(Base32.encode(secret)), secret)
        let uri = TOTP.uri(secret: secret, login: "olga", issuer: "Мониторинг")
        XCTAssertTrue(uri.hasPrefix("otpauth://totp/"))
        XCTAssertTrue(uri.contains("secret=\(Base32.encode(secret))"))
        XCTAssertNotNil(URL(string: uri))
    }

    func testPasswordHashes() throws {
        let h = try PasswordHash.make("correct horse battery staple")
        XCTAssertTrue(h.hasPrefix("$argon2id$"))
        XCTAssertTrue(PasswordHash.verify("correct horse battery staple", hash: h))
        XCTAssertFalse(PasswordHash.verify("correct horse battery stapl", hash: h))
        XCTAssertFalse(PasswordHash.verify("x", hash: "garbage"))
        XCTAssertNotEqual(h, try PasswordHash.make("correct horse battery staple"))
        XCTAssertNotNil(PasswordHash.weakness("short", login: "olga"))
        XCTAssertNotNil(PasswordHash.weakness("olga-1234567890", login: "olga"))
        XCTAssertNotNil(PasswordHash.weakness("aaaaaaaaaaaaaaa", login: "olga"))
        XCTAssertNil(PasswordHash.weakness("Тихий-вечер-над-Невой", login: "olga"))
    }

    func testRecoveryCodes() {
        let c = Tokens.recoveryCode()
        XCTAssertEqual(c.count, 12)
        XCTAssertEqual(Tokens.normalizeRecovery(c.uppercased()), Tokens.normalizeRecovery(c))
        XCTAssertEqual(Accounts.recoveryHash(c), Accounts.recoveryHash(" " + c.replacingOccurrences(of: "-", with: "")))
        XCTAssertEqual(Tokens.make().count, 43)
    }

    func testSSHKeys() throws {
        // A real ed25519 public key (test vector, not anyone's).
        let line = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl olga@laptop"
        let k = try SSHKeys.parse(line)
        XCTAssertEqual(k.type, "ssh-ed25519")
        XCTAssertEqual(k.comment, "olga@laptop")
        XCTAssertTrue(k.fingerprint.hasPrefix("SHA256:"))
        XCTAssertEqual(k.fingerprint.count, 7 + 43)
        XCTAssertEqual(k.line, line)
        XCTAssertThrowsError(try SSHKeys.parse("command=\"rm -rf /\" " + line))
        XCTAssertThrowsError(try SSHKeys.parse("ssh-ed25519 notbase64!!"))
        // The label must match what is inside.
        XCTAssertThrowsError(try SSHKeys.parse(line.replacingOccurrences(of: "ssh-ed25519 ", with: "ssh-rsa ")))
        XCTAssertThrowsError(try SSHKeys.parse("-----BEGIN OPENSSH PRIVATE KEY-----"))
    }

    func testDeviceNames() {
        XCTAssertEqual(Accounts.deviceName("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0 Safari/537.36"),
                       "Chrome, Windows")
        XCTAssertEqual(Accounts.deviceName("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"),
                       "Safari, iPhone")
        XCTAssertEqual(Accounts.deviceName(nil), "")
    }

    func testPreferenceValues() {
        XCTAssertNoThrow(try Preferences.check("theme", "\"dark\""))
        XCTAssertThrowsError(try Preferences.check("theme", "\"pink\""))
        XCTAssertThrowsError(try Preferences.check("nonsense", "1"))
        XCTAssertNoThrow(try Preferences.check("table_columns.servers", "[\"name\",\"cpu\"]"))
        XCTAssertThrowsError(try Preferences.check("pinned_objects", "{not json"))
    }
}
