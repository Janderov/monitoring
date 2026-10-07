import Foundation
import XCTest
@testable import MonitorCore

/// Keychain items in memory, counting reads the way macOS counts prompts.
final class FakeItems: SecretItems, @unchecked Sendable {
    private let lock = NSLock()
    var items: [String: Data]
    var reads: [String] = []
    var deny: Set<String> = []

    init(_ items: [String: String] = [:]) { self.items = items.mapValues { Data($0.utf8) } }

    struct Denied: Error {}

    func read(_ account: String) throws -> Data? {
        try lock.withLock {
            reads.append(account)
            if deny.contains(account) { throw Denied() }
            return items[account]
        }
    }
    func write(_ data: Data, for account: String) throws { lock.withLock { items[account] = data } }
    func delete(_ account: String) throws { lock.withLock { _ = items.removeValue(forKey: account) } }
    func accounts() throws -> [String] { lock.withLock { Array(items.keys) } }
}

final class VaultSecretsTests: XCTestCase {
    func testMovesOldItemsIntoOneVault() throws {
        let items = FakeItems(["agent-token:nl": "t1", "ssh-password:us": "p2", "site-auth:x": "a3"])
        let vault = VaultSecrets(items: items)
        XCTAssertEqual(try vault.get("agent-token:nl"), "t1")
        XCTAssertEqual(try vault.get("ssh-password:us"), "p2")
        XCTAssertEqual(try vault.get("missing"), nil)
        XCTAssertEqual(Array(items.items.keys), [VaultSecrets.vaultAccount])

        // A new run (a new build) reads the vault only: one prompt.
        let items2 = FakeItems()
        items2.items = items.items
        let next = VaultSecrets(items: items2)
        XCTAssertEqual(try next.get("site-auth:x"), "a3")
        XCTAssertEqual(try next.get("agent-token:nl"), "t1")
        XCTAssertEqual(items2.reads, [VaultSecrets.vaultAccount])
    }

    func testSetAndRemoveWriteTheVault() throws {
        let items = FakeItems()
        let vault = VaultSecrets(items: items)
        try vault.set("tok", for: "agent-token:a")
        try vault.set("pw", for: "ssh-password:a")
        try vault.remove("ssh-password:a")
        try vault.remove("never-set")
        let saved = try JSONDecoder().decode([String: String].self, from: items.items[VaultSecrets.vaultAccount]!)
        XCTAssertEqual(saved, ["agent-token:a": "tok"])
        XCTAssertEqual(try VaultSecrets(items: items).get("agent-token:a"), "tok")
    }

    func testDeniedOldItemKeepsEverythingForNextTry() throws {
        let items = FakeItems(["agent-token:nl": "t1", "admin-key": "{}"])
        items.deny = ["admin-key"]
        let vault = VaultSecrets(items: items)
        XCTAssertThrowsError(try vault.get("agent-token:nl"))
        XCTAssertNil(items.items[VaultSecrets.vaultAccount])
        XCTAssertEqual(items.items.count, 2)

        items.deny = []
        XCTAssertEqual(try vault.get("admin-key"), "{}")
        XCTAssertEqual(Array(items.items.keys), [VaultSecrets.vaultAccount])
    }
}
