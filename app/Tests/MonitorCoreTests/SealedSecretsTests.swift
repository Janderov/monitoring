import Foundation
import XCTest
@testable import MonitorCore

final class SealedSecretsTests: XCTestCase {
    let agentKey = SecretKey.agentToken("nl")
    let sshKey = SecretKey.sshPassword("nl")
    let siteKey = SecretKey.siteAuth("shop")

    /// The plain store with what a user has saved before any admin key.
    func savedBefore() throws -> MemorySecrets {
        let base = MemorySecrets()
        try base.set("agent-token-value", for: agentKey)
        try base.set("ssh-pass-value", for: sshKey)
        try base.set("site-pass-value", for: siteKey)
        try base.set("ghp-token-value", for: SecretKey.githubToken)
        return base
    }

    /// Nothing sealed may be readable in the clear anywhere in the store.
    func assertNoPlaintext(_ base: MemorySecrets, file: StaticString = #filePath, line: UInt = #line) throws {
        for account in try base.accounts() {
            let v = try base.get(account) ?? ""
            for secret in ["ssh-pass-value", "site-pass-value", "ghp-token-value"] {
                XCTAssertFalse(v.contains(secret), "\(secret) in the clear under \(account)", file: file, line: line)
            }
        }
    }

    func testSealOpenCloseUnseal() throws {
        let base = try savedBefore()
        let sealed = SealedSecrets(base: base)
        XCTAssertFalse(sealed.isSealed)
        XCTAssertEqual(try sealed.get(sshKey), "ssh-pass-value", "before sealing everything passes through")

        let key = KeyWrap.newDataKey()
        try sealed.seal(with: key)
        XCTAssertTrue(sealed.isSealed)
        try assertNoPlaintext(base)
        XCTAssertNil(try base.get(sshKey))
        XCTAssertEqual(try sealed.get(sshKey), "ssh-pass-value")

        sealed.close()
        XCTAssertThrowsError(try sealed.get(sshKey)) { XCTAssertTrue($0 is SecretsLockedError) }
        XCTAssertThrowsError(try sealed.get(SecretKey.githubToken)) { XCTAssertTrue($0 is SecretsLockedError) }
        XCTAssertThrowsError(try sealed.set("x", for: siteKey)) { XCTAssertTrue($0 is SecretsLockedError) }
        XCTAssertEqual(try sealed.get(agentKey), "agent-token-value", "agent tokens stay readable for monitoring")

        XCTAssertThrowsError(try sealed.open(with: KeyWrap.newDataKey())) { XCTAssertEqual($0 as? SealError, .wrongKey) }
        try sealed.open(with: key)
        try sealed.set("new-ssh", for: sshKey)
        try sealed.remove(siteKey)
        try assertNoPlaintext(base)
        XCTAssertFalse(try base.get(SealedSecrets.boxAccount)!.contains("new-ssh"))

        // A second instance (next launch) starts closed and opens with the key.
        let next = SealedSecrets(base: base)
        XCTAssertThrowsError(try next.get(sshKey))
        try next.open(with: key)
        XCTAssertEqual(try next.get(sshKey), "new-ssh")
        XCTAssertNil(try next.get(siteKey))

        try next.unseal()
        XCTAssertFalse(next.isSealed)
        XCTAssertEqual(try base.get(sshKey), "new-ssh")
        XCTAssertEqual(try base.get(SecretKey.githubToken), "ghp-token-value")
    }

    func testOpenMovesStrayPlaintextIn() throws {
        let base = try savedBefore()
        let key = KeyWrap.newDataKey()
        try SealedSecrets(base: base).seal(with: key)
        try base.set("stray", for: SecretKey.sshPassword("us")) // e.g. an interrupted seal
        let s = SealedSecrets(base: base)
        try s.open(with: key)
        XCTAssertNil(try base.get(SecretKey.sshPassword("us")))
        XCTAssertEqual(try s.get(SecretKey.sshPassword("us")), "stray")
    }

    func testKeyWrap() throws {
        let dk = KeyWrap.newDataKey()
        let secret = Digest.randomBytes(32)
        let w = try KeyWrap.wrap(dk, with: secret, context: "token")
        XCTAssertEqual(try KeyWrap.unwrap(w, with: secret, context: "token"), dk)
        XCTAssertThrowsError(try KeyWrap.unwrap(w, with: Digest.randomBytes(32), context: "token"))
        XCTAssertThrowsError(try KeyWrap.unwrap(w, with: secret, context: "recovery"))
    }

    // MARK: with the admin lock

    func testAdminKeySealsPasswordsAndOnlyTheTokenOrCodeOpensThem() async throws {
        let tokens = FakeTokens()
        _ = tokens.insert("49184CCA", pin: "24681357")
        let base = try savedBefore()
        let lock = AdminLock(key: RutokenLiteKey(driver: tokens), secrets: SealedSecrets(base: base))
        let code = try await lock.enroll(pin: "24681357").recoveryCode
        try assertNoPlaintext(base)
        let record = try XCTUnwrap(try base.get(SecretKey.adminKey))
        XCTAssertTrue(record.contains("sealKeyByToken") && record.contains("sealKeyByRecovery"))

        // Next launch: locked, sealed passwords unreadable, agents still polled.
        var store = SealedSecrets(base: base)
        var again = AdminLock(key: RutokenLiteKey(driver: tokens), secrets: store)
        XCTAssertThrowsError(try store.get(sshKey))
        XCTAssertEqual(try store.get(agentKey), "agent-token-value")

        let opened = Flag()
        await again.setOnSecretsOpened { opened.set() }
        let r = try await again.unlock(pin: "24681357")
        XCTAssertNil(r.newRecoveryCode)
        XCTAssertTrue(opened.value)
        XCTAssertEqual(try store.get(sshKey), "ssh-pass-value")

        // Pulling the token locks and closes them again.
        tokens.pull("49184CCA")
        await again.check()
        XCTAssertThrowsError(try store.get(sshKey))

        // The recovery code opens them without the token.
        store = SealedSecrets(base: base)
        again = AdminLock(key: RutokenLiteKey(driver: tokens), secrets: store)
        try await again.unlock(recoveryCode: code)
        XCTAssertEqual(try store.get(siteKey), "site-pass-value")

        // A new token (the old one lost) keeps the same passwords.
        _ = tokens.insert("NEWTOKEN", pin: "13579246")
        let fresh = try await again.enroll(pin: "13579246")
        await again.lock()
        XCTAssertThrowsError(try store.get(sshKey))
        _ = try await again.unlock(pin: "13579246")
        XCTAssertEqual(try store.get(sshKey), "ssh-pass-value")

        // A new recovery code replaces the old one for the passwords too.
        let newer = try await again.newRecoveryCode()
        await again.lock()
        store = SealedSecrets(base: base)
        again = AdminLock(key: RutokenLiteKey(driver: tokens), secrets: store)
        do { try await again.unlock(recoveryCode: fresh.recoveryCode); XCTFail() } catch {}
        try await again.unlock(recoveryCode: newer)
        XCTAssertEqual(try store.get(SecretKey.githubToken), "ghp-token-value")

        // Turning the key off puts them back in the clear.
        try await again.disable()
        XCTAssertFalse(store.isSealed)
        XCTAssertEqual(try base.get(sshKey), "ssh-pass-value")
    }

    func testRecordFromBeforeSealingSealsOnNextTokenUnlock() async throws {
        let tokens = FakeTokens()
        _ = tokens.insert("49184CCA", pin: "24681357")
        let base = try savedBefore()
        // Set up by the previous version: no sealing, no wrapped keys.
        let oldCode = try await AdminLock(key: RutokenLiteKey(driver: tokens), secrets: base)
            .enroll(pin: "24681357").recoveryCode
        var rec = try AdminLock.decode(try XCTUnwrap(try base.get(SecretKey.adminKey)))
        rec.sealKeyByToken = nil
        rec.sealKeyByRecovery = nil
        try base.set(try AdminLock.encode(rec), for: SecretKey.adminKey)

        let store = SealedSecrets(base: base)
        let lock = AdminLock(key: RutokenLiteKey(driver: tokens), secrets: store)
        let r = try await lock.unlock(pin: "24681357")
        let newCode = try XCTUnwrap(r.newRecoveryCode, "a new recovery code is shown once")
        XCTAssertTrue(store.isSealed)
        try assertNoPlaintext(base)
        XCTAssertEqual(try store.get(sshKey), "ssh-pass-value")

        await lock.lock()
        let next = AdminLock(key: RutokenLiteKey(driver: tokens), secrets: SealedSecrets(base: base))
        do { try await next.unlock(recoveryCode: oldCode); XCTFail("old code must stop working") } catch {}
        try await next.unlock(recoveryCode: newCode)
        let n = try await next.unlock(pin: "24681357")
        XCTAssertNil(n.newRecoveryCode, "only once")
    }

    func testLockedSiteLoginsAreHeldNotDropped() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("servers.json")
        try Data(ServersFile.example.utf8).write(to: url)

        let base = MemorySecrets()
        let key = KeyWrap.newDataKey()
        let open = SealedSecrets(base: base)
        try open.seal(with: key)
        let repo = ConfigRepository(url: url, secrets: open)
        try await repo.upsertSite(SiteConfig(id: "shop", name: "Магазин", url: "https://shop.example.com",
                                             authUser: "u", authPassword: "s3cret"))
        try assertNoPlaintext(base)

        let locked = ConfigRepository(url: url, secrets: SealedSecrets(base: base))
        let sites = try await locked.load().sites ?? []
        let site = try XCTUnwrap(sites.first { $0.id == "shop" })
        XCTAssertTrue(site.authLocked)
        XCTAssertNil(site.basicAuth)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    func set() { lock.withLock { on = true } }
    var value: Bool { lock.withLock { on } }
}
