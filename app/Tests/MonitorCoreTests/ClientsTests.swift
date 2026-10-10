import Foundation
import XCTest
@testable import MonitorCore

final class ClientsTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    var day: TimeInterval { 86_400 }

    private func book() -> (ClientBook, own: String, vector: String, romashka: String) {
        var b = ClientBook()
        b.ensureInternal(now: t0)
        let v = Client(name: "Студия Вектор", shortName: "Вектор", createdAt: t0)
        let r = Client(name: "Пекарня Ромашка", color: .orange, createdAt: t0)
        b.upsert(v)
        b.upsert(r)
        return (b, b.internalClient!.id, v.id, r.id)
    }

    func testInternalClientIsAddedOnce() {
        var b = ClientBook()
        let first = b.ensureInternal()
        let second = b.ensureInternal()
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertEqual(b.clients.filter(\.isInternal).count, 1)
        XCTAssertEqual(b.internalClient?.name, "Своё")
    }

    func testUnassignedObjectsBelongToInternal() {
        let (b, own, _, _) = book()
        XCTAssertEqual(b.owners(server: "wise1"), [own])
        XCTAssertEqual(b.owners(site: "shop"), [own])
        XCTAssertEqual(b.owners(vpnKey: "KEY="), [own])
    }

    func testHostedSiteMakesServerShared() {
        var (b, own, vector, romashka) = book()
        b.setOwners(.server, "wise1", [own: nil], now: t0)
        b.setOwners(.site, "vector.ru", [vector: nil], now: t0)
        b.setOwners(.site, "bake.ru", [romashka: nil], now: t0)
        let hosting = ["vector.ru": "wise1", "bake.ru": "wise1", "other.ru": "nl"]
        let now = t0 + day
        XCTAssertEqual(Set(b.owners(server: "wise1", hosting: hosting, at: now)), [own, vector, romashka])
        // A server with only a client's site is that client's, not «Своё».
        XCTAssertEqual(b.owners(server: "nl", hosting: ["vector.ru": "nl"], at: now), [vector])
        XCTAssertEqual(b.owners(site: "vector.ru", at: now), [vector])
    }

    func testSharesFillTheRestEqually() {
        var (b, own, vector, romashka) = book()
        b.setOwners(.server, "wise1", [own: 50, vector: nil, romashka: nil], now: t0)
        let s = b.shares(server: "wise1", at: t0 + day)
        XCTAssertEqual(s[own] ?? 0, 50, accuracy: 0.001)
        XCTAssertEqual(s[vector] ?? 0, 25, accuracy: 0.001)
        XCTAssertEqual(s[romashka] ?? 0, 25, accuracy: 0.001)

        // Given shares that do not reach 100 are scaled up.
        b.setOwners(.server, "nl", [own: 30, vector: 30], now: t0)
        let n = b.shares(server: "nl", at: t0 + day)
        XCTAssertEqual(n[own] ?? 0, 50, accuracy: 0.001)
        XCTAssertEqual(n.values.reduce(0, +), 100, accuracy: 0.001)

        // Unassigned: all of it is «Своё».
        XCTAssertEqual(b.shares(server: "us", at: t0)[own] ?? 0, 100, accuracy: 0.001)
    }

    func testCostShare() {
        var (b, own, vector, _) = book()
        b.setOwners(.server, "wise1", [own: nil, vector: nil], now: t0)
        let wise = ServerConfig(id: "wise1", name: "wise1", host: "198.51.100.1", token: "", fingerprint: "",
                                cost: ServerCost(monthly: 1200, currency: "₽"))
        let us = ServerConfig(id: "us", name: "US", host: "198.51.100.2", token: "", fingerprint: "",
                              cost: ServerCost(monthly: 6, currency: "$"))
        let c = b.costShare(of: vector, servers: [wise, us], at: t0 + day)
        XCTAssertEqual(c["₽"] ?? 0, 600, accuracy: 0.001)
        XCTAssertNil(c["$"])
        XCTAssertEqual(b.costShare(of: own, servers: [wise, us], at: t0 + day)["$"] ?? 0, 6, accuracy: 0.001)
    }

    func testMovingAnObjectKeepsHistory() {
        var (b, _, vector, romashka) = book()
        b.setOwners(.site, "shop.ru", [vector: nil], now: t0)
        let moved = t0 + 10 * day
        b.setOwners(.site, "shop.ru", [romashka: nil], now: moved)
        XCTAssertEqual(b.owners(site: "shop.ru", at: t0 + day), [vector])
        XCTAssertEqual(b.owners(site: "shop.ru", at: moved + day), [romashka])
        XCTAssertEqual(b.assets.filter { $0.assetID == "shop.ru" }.count, 2)

        // Setting the same owners again changes nothing.
        let before = b.assets
        b.setOwners(.site, "shop.ru", [romashka: nil], now: moved + 2 * day)
        XCTAssertEqual(b.assets, before)
    }

    func testChangingAShareOpensANewRow() {
        var (b, own, vector, _) = book()
        b.setOwners(.server, "wise1", [own: nil, vector: nil], now: t0)
        b.setOwners(.server, "wise1", [own: nil, vector: 20], now: t0 + day)
        XCTAssertEqual(b.shares(server: "wise1", at: t0 + 2 * day)[vector] ?? 0, 20, accuracy: 0.001)
        XCTAssertEqual(b.shares(server: "wise1", at: t0 + day / 2)[vector] ?? 0, 50, accuracy: 0.001)
    }

    func testAddAndRemoveOwner() {
        var (b, own, vector, _) = book()
        b.addOwner(own, .server, "wise1", now: t0)
        b.addOwner(vector, .server, "wise1", now: t0 + day)
        b.addOwner(vector, .server, "wise1", now: t0 + day)
        XCTAssertEqual(Set(b.owners(server: "wise1", at: t0 + 2 * day)), [own, vector])
        b.removeOwner(own, .server, "wise1", now: t0 + 3 * day)
        XCTAssertEqual(b.owners(server: "wise1", at: t0 + 4 * day), [vector])
        XCTAssertEqual(Set(b.owners(server: "wise1", at: t0 + 2 * day)), [own, vector])
    }

    func testAssignedTwiceTheSameMomentLeavesNoEmptyRows() {
        var (b, _, vector, romashka) = book()
        b.setOwners(.site, "shop.ru", [vector: nil], now: t0)
        b.setOwners(.site, "shop.ru", [romashka: nil], now: t0)
        XCTAssertEqual(b.assets.filter { $0.assetID == "shop.ru" }.count, 1)
        XCTAssertEqual(b.owners(site: "shop.ru", at: t0), [romashka])
    }

    func testArchiveEndsAssignments() {
        var (b, own, vector, _) = book()
        b.setOwners(.site, "shop.ru", [vector: nil], now: t0)
        b.archive(vector, now: t0 + day)
        XCTAssertEqual(b.owners(site: "shop.ru", at: t0 + 2 * day), [own])
        XCTAssertFalse(b.current.contains { $0.id == vector })
        b.archive(own, now: t0 + day)
        XCTAssertNotNil(b.internalClient)
        XCTAssertNil(b.internalClient?.archivedAt)
    }

    func testCurrentPutsInternalFirst() {
        let (b, own, _, _) = book()
        XCTAssertEqual(b.current.first?.id, own)
        XCTAssertEqual(Array(b.current.map(\.name).dropFirst()), ["Пекарня Ромашка", "Студия Вектор"])
    }

    func testContractHistory() {
        var c = Client(name: "Вектор")
        c.contracts = [
            ClientContract(planName: "Старт", monthlyPrice: 3000, startedOn: t0, endedOn: t0 + 30 * day),
            ClientContract(planName: "Базовый", monthlyPrice: 4000, startedOn: t0 + 30 * day),
        ]
        XCTAssertEqual(c.contract(at: t0 + day)?.monthlyPrice, 3000)
        XCTAssertEqual(c.contract(at: t0 + 40 * day)?.planName, "Базовый")
        XCTAssertNil(c.contract(at: t0 - day))
        XCTAssertEqual(Client(name: "Ромашка", shortName: "  ").label, "Ромашка")
    }

    func testRepositoryRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = ClientsRepository(url: dir.appendingPathComponent("clients.json"))

        var b = try repo.load()
        XCTAssertEqual(b.clients.count, 1, "a missing file is «Своё» only")
        var v = Client(name: "Студия Вектор", createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        v.contacts = [ClientContact(name: "Анна", role: .owner, email: "anna@example.com", receivesReport: true)]
        v.contracts = [ClientContract(planName: "Базовый", monthlyPrice: 4000, billingDay: 5,
                                      startedOn: Date(timeIntervalSince1970: 1_790_000_000), slaUptime: 99.5)]
        b.upsert(v)
        b.setOwners(.vpnKey, "PUB=", [v.id: nil], now: Date(timeIntervalSince1970: 1_790_000_000))
        try repo.save(b)
        let loaded = try repo.load()
        XCTAssertEqual(loaded.clients.count, 2)
        XCTAssertEqual(loaded.client(v.id), v)
        XCTAssertEqual(loaded.assets, b.assets)
        // Dates are kept to the second: a second round changes nothing.
        try repo.save(loaded)
        XCTAssertEqual(try repo.load(), loaded)

        let raw = String(decoding: try Data(contentsOf: repo.url), as: UTF8.self)
        XCTAssertTrue(raw.contains("\"vpn_key\""))
    }
}
