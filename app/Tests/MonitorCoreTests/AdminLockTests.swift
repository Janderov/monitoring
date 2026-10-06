import Foundation
import XCTest
@testable import MonitorCore

final class DigestTests: XCTestCase {
    func testKnownVectors() {
        XCTAssertEqual(Digest.sha256Hex([]), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(Digest.sha256Hex(Array("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(Digest.sha256Hex(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(Digest.sha256Hex([UInt8](repeating: 0x61, count: 1000)),
                       "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
        XCTAssertTrue(Digest.equal([1, 2], [1, 2]))
        XCTAssertFalse(Digest.equal([1, 2], [1, 3]))
        XCTAssertFalse(Digest.equal([1], [1, 2]))
    }

    func testRecoveryCode() {
        let code = RecoveryCode.make()
        XCTAssertEqual(code.count, 29)
        XCTAssertEqual(code.split(separator: "-").count, 6)
        XCTAssertNotEqual(code, RecoveryCode.make())
        let h = RecoveryCode.hash(code, salt: "s")
        XCTAssertEqual(RecoveryCode.hash(code.lowercased().replacingOccurrences(of: "-", with: " "), salt: "s"), h)
        XCTAssertNotEqual(RecoveryCode.hash(code, salt: "t"), h)
        XCTAssertEqual(RecoveryCode.normalize("ab-oi l"), "AB011")
    }
}

/// A token in memory that behaves like Rutoken: private data under a PIN,
/// ten tries, then locked.
final class FakeTokens: TokenDriver, @unchecked Sendable {
    final class Token {
        var info: TokenInfo
        var pin: String
        var tries = 10
        var data: [String: [UInt8]] = [:]
        init(serial: String, slot: UInt, pin: String) {
            info = TokenInfo(slot: slot, serial: serial, label: "Rutoken Lite", model: "Rutoken Lite")
            self.pin = pin
        }
    }

    private let lock = NSLock()
    var inserted: [Token] = []
    var driverInstalled = true

    func insert(_ serial: String, pin: String = "12345678") -> Token {
        let t = Token(serial: serial, slot: UInt(inserted.count + 1), pin: pin)
        lock.withLock { inserted.append(t) }
        return t
    }

    func pull(_ serial: String) { lock.withLock { inserted.removeAll { $0.info.serial == serial } } }

    func tokens() throws -> [TokenInfo] {
        guard driverInstalled else { throw TokenError.noDriver }
        return lock.withLock { inserted.map(\.info) }
    }

    func withSession<T>(slot: UInt, pin: String, _ body: (TokenSession) throws -> T) throws -> T {
        guard let t = lock.withLock({ inserted.first { $0.info.slot == slot } }) else { throw TokenError.noToken }
        guard t.tries > 0 else { throw TokenError.pinLocked }
        guard pin == t.pin else {
            t.tries -= 1
            if t.tries == 0 { throw TokenError.pinLocked }
            throw TokenError.wrongPIN(finalTry: t.tries == 1)
        }
        t.tries = 10
        return try body(Session(t: t))
    }

    struct Session: TokenSession {
        let t: Token
        func readData(label: String) throws -> [UInt8]? { t.data[label] }
        func writeData(label: String, application: String, value: [UInt8]) throws { t.data[label] = value }
        func deleteData(label: String) throws { t.data[label] = nil }
        func changePIN(old: String, new: String) throws {
            guard new.count >= 6 else { throw TokenError.pinLength }
            t.pin = new
        }
    }
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [AdminLockStatus] = []
    func add(_ s: AdminLockStatus) { lock.withLock { items.append(s) } }
    var all: [AdminLockStatus] { lock.withLock { items } }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t += s } }
}

final class AdminLockTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testOffUntilEnrolledThenLockedOnNextStart() async throws {
        let tokens = FakeTokens()
        let token = tokens.insert("0A1B2C3D")
        let secrets = MemorySecrets()
        let store = try Store(path: dir.appendingPathComponent("m.db").path)
        let lock = AdminLock(key: RutokenLiteKey(driver: tokens), secrets: secrets, store: store)

        let status0 = await lock.status()
        XCTAssertEqual(status0.state, .off)
        try await lock.authorize(.restart)

        let enrolled = try await lock.enroll(pin: "12345678")
        XCTAssertTrue(enrolled.defaultPIN, "factory PIN is flagged")
        XCTAssertEqual(token.data[RutokenLiteKey.label]?.count, 32)
        let status1 = await lock.status()
        XCTAssertEqual(status1.state, .unlocked)
        XCTAssertEqual(status1.keyID, "0A1B2C3D")

        // Keychain holds hashes only, never the token secret or the code.
        let saved = try XCTUnwrap(try secrets.get(SecretKey.adminKey))
        XCTAssertFalse(saved.contains(RecoveryCode.normalize(enrolled.recoveryCode)))
        let secretHex = token.data[RutokenLiteKey.label]!.map { String(format: "%02x", $0) }.joined()
        XCTAssertFalse(saved.contains(secretHex))
        XCTAssertTrue(saved.contains(Digest.sha256Hex(token.data[RutokenLiteKey.label]!)))

        // Next launch starts locked.
        let again = AdminLock(key: RutokenLiteKey(driver: tokens), secrets: secrets, store: store)
        let status2 = await again.status()
        XCTAssertEqual(status2.state, .locked)
        do { try await again.authorize(.manageVPNKeys); XCTFail() } catch { XCTAssertEqual(error as? AdminLockError, .locked) }
        for action in [UserAction.view, .ssh] {
            do { try await again.authorize(action); XCTFail("\(action) while locked") } catch {}
        }
        try await again.authorize(.adminLogin)

        do { _ = try await again.unlock(pin: "000000"); XCTFail() } catch {
            XCTAssertEqual(error as? TokenError, .wrongPIN(finalTry: false))
        }
        try await again.changePIN(old: "12345678", new: "246810")
        let r = try await again.unlock(pin: "246810")
        XCTAssertFalse(r.defaultPIN)
        try await again.authorize(.restart)

        let log = try await store.actions(limit: 10)
        XCTAssertEqual(log.filter { $0.action == .adminLogin }.map(\.result), [.done, .failed])
        XCTAssertFalse(log.contains { $0.detail.contains("246810") || ($0.error ?? "").contains("246810") })
    }

    func testPullingTheTokenLocks() async throws {
        let tokens = FakeTokens()
        let token = tokens.insert("AAA")
        let lock = AdminLock(key: RutokenLiteKey(driver: tokens), secrets: MemorySecrets())
        _ = try await lock.enroll(pin: "12345678")
        tokens.pull("AAA")
        do { try await lock.authorize(.editConfig); XCTFail() } catch { XCTAssertEqual(error as? AdminLockError, .locked) }
        let s = await lock.status()
        XCTAssertEqual(s.state, .locked)

        tokens.inserted.append(token)
        _ = try await lock.unlock(pin: "12345678")
        await lock.check()
        let s1 = await lock.status()
        XCTAssertEqual(s1.state, .unlocked)
        tokens.pull("AAA")
        await lock.check()
        let s2 = await lock.status()
        XCTAssertEqual(s2.state, .locked)
    }

    func testWatchingSeesTheTokenGoInAndOut() async throws {
        let tokens = FakeTokens()
        let mine = tokens.insert("MINE")
        let secrets = MemorySecrets()
        _ = try await AdminLock(key: RutokenLiteKey(driver: tokens), secrets: secrets).enroll(pin: "12345678")
        tokens.pull("MINE")

        let lock = AdminLock(key: RutokenLiteKey(driver: tokens), secrets: secrets)
        let seen = Recorder()
        await lock.setOnChange { seen.add($0) }
        await lock.check()
        var s = await lock.status()
        XCTAssertEqual(s.state, .locked)
        XCTAssertEqual(s.presence, .none)

        _ = tokens.insert("OTHER")
        await lock.check()
        s = await lock.status()
        XCTAssertEqual(s.presence, .other)
        tokens.pull("OTHER")

        tokens.inserted.append(mine)
        await lock.check()
        s = await lock.status()
        XCTAssertEqual(s.presence, .mine)
        XCTAssertEqual(seen.all.map(\.presence), [.other, .mine], "the lock screen hears every change")

        _ = try await lock.unlock(pin: "12345678")
        await lock.check()
        s = await lock.status()
        XCTAssertEqual(s.state, .unlocked, "no idle timeout by default")

        tokens.pull("MINE")
        await lock.check()
        s = await lock.status()
        XCTAssertEqual(s.state, .locked)
        XCTAssertEqual(s.presence, .none)
        XCTAssertEqual(seen.all.last?.state, .locked)

        tokens.driverInstalled = false
        await lock.check()
        s = await lock.status()
        XCTAssertEqual(s.presence, .noDriver)
    }

    func testIdleTimeoutLocks() async throws {
        let tokens = FakeTokens()
        _ = tokens.insert("AAA")
        let clock = TestClock()
        let lock = AdminLock(key: RutokenLiteKey(driver: tokens), secrets: MemorySecrets(), idle: 600,
                             now: { clock.now })
        _ = try await lock.enroll(pin: "12345678")
        clock.advance(500)
        try await lock.authorize(.restart)
        clock.advance(500)
        try await lock.authorize(.restart) // activity extended the session
        clock.advance(601)
        do { try await lock.authorize(.restart); XCTFail() } catch { XCTAssertEqual(error as? AdminLockError, .locked) }
    }

    func testWrongTokenAndWipedToken() async throws {
        let tokens = FakeTokens()
        let mine = tokens.insert("MINE")
        let secrets = MemorySecrets()
        _ = try await AdminLock(key: RutokenLiteKey(driver: tokens), secrets: secrets).enroll(pin: "12345678")
        tokens.pull("MINE")
        _ = tokens.insert("OTHER")
        let lock = AdminLock(key: RutokenLiteKey(driver: tokens), secrets: secrets)
        do { _ = try await lock.unlock(pin: "12345678"); XCTFail() } catch { XCTAssertEqual(error as? AdminLockError, .wrongKey) }

        tokens.pull("OTHER")
        do { _ = try await lock.unlock(pin: "12345678"); XCTFail() } catch { XCTAssertEqual(error as? TokenError, .noToken) }

        tokens.inserted.append(mine)
        mine.data[RutokenLiteKey.label] = Digest.randomBytes(32)
        do { _ = try await lock.unlock(pin: "12345678"); XCTFail() } catch { XCTAssertEqual(error as? AdminLockError, .wrongKey) }
        mine.data = [:]
        do { _ = try await lock.unlock(pin: "12345678"); XCTFail() } catch { XCTAssertEqual(error as? AdminLockError, .noKeyData) }
    }

    func testRecoveryCodeOpensWithoutTokenAndAllowsNewToken() async throws {
        let tokens = FakeTokens()
        _ = tokens.insert("LOST")
        let secrets = MemorySecrets()
        let code = try await AdminLock(key: RutokenLiteKey(driver: tokens), secrets: secrets)
            .enroll(pin: "12345678").recoveryCode
        tokens.pull("LOST")

        let lock = AdminLock(key: RutokenLiteKey(driver: tokens), secrets: secrets)
        do { try await lock.unlock(recoveryCode: "0000-0000-0000-0000-0000-0000"); XCTFail() } catch {
            XCTAssertEqual(error as? AdminLockError, .wrongRecoveryCode)
        }
        try await lock.unlock(recoveryCode: code.lowercased())
        let s = await lock.status()
        XCTAssertTrue(s.unlockedByRecovery)
        try await lock.authorize(.restart)
        await lock.check()
        let still = await lock.status()
        XCTAssertEqual(still.state, .unlocked, "no token needed after a recovery unlock")

        _ = tokens.insert("NEW", pin: "13579246")
        let fresh = try await lock.enroll(pin: "13579246")
        XCTAssertFalse(fresh.defaultPIN)
        XCTAssertNotEqual(fresh.recoveryCode, code)
        let s2 = await lock.status()
        XCTAssertEqual(s2.keyID, "NEW")
        XCTAssertFalse(s2.unlockedByRecovery)
    }

    func testRecoveryUnlockExpiresWhenIdle() async throws {
        let tokens = FakeTokens()
        _ = tokens.insert("LOST")
        let secrets = MemorySecrets()
        let clock = TestClock()
        let code = try await AdminLock(key: RutokenLiteKey(driver: tokens), secrets: secrets, now: { clock.now })
            .enroll(pin: "12345678").recoveryCode
        let lock = AdminLock(key: RutokenLiteKey(driver: tokens), secrets: secrets, now: { clock.now })
        _ = try await lock.unlock(pin: "12345678")
        clock.advance(AdminLock.recoveryIdle * 4)
        await lock.check()
        var s = await lock.status()
        XCTAssertEqual(s.state, .unlocked, "a token unlock does not time out")

        await lock.lock()
        tokens.pull("LOST")
        try await lock.unlock(recoveryCode: code)
        clock.advance(AdminLock.recoveryIdle + 1)
        await lock.check()
        s = await lock.status()
        XCTAssertEqual(s.state, .locked)
    }

    func testEnrollNeedsOneTokenAndUnlockedApp() async throws {
        let tokens = FakeTokens()
        let secrets = MemorySecrets()
        let lock = AdminLock(key: RutokenLiteKey(driver: tokens), secrets: secrets)
        do { _ = try await lock.enroll(pin: "12345678"); XCTFail() } catch { XCTAssertEqual(error as? TokenError, .noToken) }
        _ = tokens.insert("A"); _ = tokens.insert("B")
        do { _ = try await lock.enroll(pin: "12345678"); XCTFail() } catch { XCTAssertEqual(error as? AdminLockError, .severalTokens) }
        tokens.pull("B")
        _ = try await lock.enroll(pin: "12345678")
        await lock.lock()
        do { _ = try await lock.enroll(pin: "12345678"); XCTFail() } catch { XCTAssertEqual(error as? AdminLockError, .locked) }
        do { try await lock.disable(); XCTFail() } catch { XCTAssertEqual(error as? AdminLockError, .locked) }
        _ = try await lock.unlock(pin: "12345678")
        try await lock.disable()
        XCTAssertNil(try secrets.get(SecretKey.adminKey))
        let s = await lock.status()
        XCTAssertEqual(s.state, .off)
    }

    func testNoDriver() async {
        let tokens = FakeTokens()
        tokens.driverInstalled = false
        let lock = AdminLock(key: RutokenLiteKey(driver: tokens), secrets: MemorySecrets())
        do { _ = try await lock.insertedTokens(); XCTFail() } catch { XCTAssertEqual(error as? TokenError, .noDriver) }
    }

    func testAuditorRefusesChangesWhileLocked() async throws {
        let tokens = FakeTokens()
        _ = tokens.insert("AAA")
        let secrets = MemorySecrets()
        _ = try await AdminLock(key: RutokenLiteKey(driver: tokens), secrets: secrets).enroll(pin: "12345678")
        let store = try Store(path: dir.appendingPathComponent("a.db").path)
        let lock = AdminLock(key: RutokenLiteKey(driver: tokens), secrets: secrets, store: store)
        let auditor = Auditor(store: store, lock: lock)

        do {
            _ = try await auditor.perform(.restart, on: .app, detail: "перезагрузка") { XCTFail("ran while locked") }
            XCTFail()
        } catch { XCTAssertEqual(error as? AdminLockError, .locked) }
        let denied = try await store.actions(limit: 1)[0]
        XCTAssertEqual(denied.result, .denied)
        XCTAssertEqual(denied.action, .restart)

        _ = try await lock.unlock(pin: "12345678")
        let ran = try await auditor.perform(.restart, on: .app, detail: "перезагрузка") { true }
        XCTAssertTrue(ran)
    }
}

/// The real dlopen code against SoftHSM, a software PKCS#11 token (apt
/// package softhsm2). Skipped where it is not installed.
final class PKCS11Tests: XCTestCase {
    static let softhsm = ["/usr/lib/softhsm/libsofthsm2.so", "/usr/lib/x86_64-linux-gnu/softhsm/libsofthsm2.so",
                          "/usr/lib/aarch64-linux-gnu/softhsm/libsofthsm2.so"]

    func testDataObjectsAndPINOnSoftHSM() throws {
        guard let lib = Self.softhsm.first(where: { FileManager.default.fileExists(atPath: $0) }),
              FileManager.default.fileExists(atPath: "/usr/bin/softhsm2-util") else {
            throw XCTSkip("softhsm2 not installed")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let conf = dir.appendingPathComponent("softhsm2.conf")
        try "directories.tokendir = \(dir.path)\nobjectstore.backend = file\n".write(to: conf, atomically: true, encoding: .utf8)
        setenv("SOFTHSM2_CONF", conf.path, 1)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/softhsm2-util")
        p.arguments = ["--init-token", "--free", "--label", "Test", "--pin", "12345678", "--so-pin", "87654321"]
        p.standardOutput = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)

        XCTAssertThrowsError(try PKCS11(paths: ["/nonexistent/lib.so"]).tokens()) {
            XCTAssertEqual($0 as? TokenError, .noDriver)
        }

        let driver = PKCS11(paths: [lib])
        let tokens = try driver.tokens()
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens[0].label, "Test")
        XCTAssertFalse(tokens[0].serial.isEmpty)

        let key = RutokenLiteKey(driver: driver)
        let enrolled = try key.enroll(pin: "12345678")
        XCTAssertEqual(enrolled.keyID, tokens[0].serial)
        _ = try key.verify(pin: "12345678", keyID: enrolled.keyID, proof: enrolled.proof)
        XCTAssertThrowsError(try key.verify(pin: "11111111", keyID: enrolled.keyID, proof: enrolled.proof)) {
            XCTAssertEqual($0 as? TokenError, .wrongPIN(finalTry: false))
        }
        // Writing again replaces the object instead of adding a second one.
        let again = try key.enroll(pin: "12345678")
        XCTAssertNotEqual(again.proof, enrolled.proof)
        XCTAssertThrowsError(try key.verify(pin: "12345678", keyID: enrolled.keyID, proof: enrolled.proof))
        _ = try key.verify(pin: "12345678", keyID: again.keyID, proof: again.proof)

        try key.changePIN(keyID: again.keyID, old: "12345678", new: "24681357")
        _ = try key.verify(pin: "24681357", keyID: again.keyID, proof: again.proof)

        try driver.withSession(slot: tokens[0].slot, pin: "24681357") { s in
            try s.deleteData(label: RutokenLiteKey.label)
            XCTAssertNil(try s.readData(label: RutokenLiteKey.label))
        }
    }
}
