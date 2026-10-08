import Foundation
import XCTest
@testable import MonitorCore

/// Ready for 50 servers: checks grow with the servers, the database stays
/// small and fast, one slow or broken server does not stop the rest, and
/// everything moves to another Mac in one file.
final class ScaleTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func server(_ i: Int) -> ServerConfig {
        var s = Fixtures.server
        s.id = "s\(i)"
        s.host = "198.51.100.\(i)"
        return s
    }

    func testFewPeersPerServer() {
        let small = (1...4).map(server)
        XCTAssertEqual(Poller.peers(of: small[0], servers: small).map(\.id), ["s2", "s3", "s4"], "a small setup checks everyone")

        let many = (1...50).map(server)
        var checkedBy: [String: Int] = [:]
        for s in many {
            let peers = Poller.peers(of: s, servers: many)
            XCTAssertEqual(peers.count, Poller.maxPeers)
            XCTAssertFalse(peers.contains { $0.id == s.id })
            for p in peers { checkedBy[p.id, default: 0] += 1 }
        }
        XCTAssertTrue(many.allSatisfy { (checkedBy[$0.id] ?? 0) >= 3 }, "every server is checked by a few others")

        // A server it has connections to (a VPN chain) is always among them.
        let chained = Poller.peers(of: many[0], servers: many, talksTo: ["198.51.100.30"])
        XCTAssertTrue(chained.contains { $0.id == "s30" })
        XCTAssertEqual(chained.count, Poller.maxPeers)
    }

    func testRefusedChecksAreShown() async throws {
        let dir = try tempDir()
        let agent = RefusingAgent()
        agent.history = [Fixtures.snapshot(time: t0)]
        let store = try Store(path: dir.appendingPathComponent("m.sqlite").path)
        let out = Collector()
        let poller = Poller(client: AgentClient(transport: agent), store: store,
                            onUpdate: { out.set($0) }, onEvents: { out.add($0) })
        await poller.setServers([Fixtures.server, server(7)])
        await poller.pollAll(now: t0)
        let status = out.statuses.first { $0.id == Fixtures.server.id }
        XCTAssertNotNil(status?.snapshot, "the server's own data still comes in")
        XCTAssertEqual(status?.checksError?.contains("at most 100 targets"), true)
    }

    func testSlowServerHasDeadline() async {
        let quick = await Poller.within(5) { 42 }
        XCTAssertEqual(quick, 42)
        let started = Date()
        let slow: Int? = await Poller.within(0.2) {
            // Ignores cancellation, like a request stuck in the network.
            let end = Date().addingTimeInterval(2)
            while Date() < end { usleep(50_000) }
            return 1
        }
        XCTAssertNil(slow)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "the round does not wait for it")
    }

    func testLinksKeptPerHourAndPrunedHourly() async throws {
        let dir = try tempDir()
        let store = try Store(path: dir.appendingPathComponent("m.sqlite").path)
        func snap(_ t: Date, ok: Bool, ms: Double) -> Snapshot {
            var s = Fixtures.snapshot(time: t)
            s.checks = [Snapshot.Check(id: "peer-us", kind: "tcp", target: "198.51.100.5:9443", ok: ok,
                                       latencyMs: ok ? ms : 0, error: ok ? nil : "timeout")]
            return s
        }
        let hour = Date(timeIntervalSince1970: (t0.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
        let old = [snap(hour, ok: true, ms: 80), snap(hour.addingTimeInterval(60), ok: true, ms: 100),
                   snap(hour.addingTimeInterval(120), ok: false, ms: 0)]
        let now = hour.addingTimeInterval(5 * 86400)
        let recent = snap(now.addingTimeInterval(-600), ok: true, ms: 90)
        try await store.addLinkSamples(serverID: "nl", old + [recent])
        try await store.rollup(since: hour, now: now)

        // Minute rows older than 3 days are gone; their hour is one sample.
        let all = try await store.linkSamples("nl", from: hour.addingTimeInterval(-3600), to: now)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.first?.ok, true, "2 of 3 checks passed")
        XCTAssertEqual(all.first?.latencyMs, 90)
        XCTAssertEqual(all.last?.time, recent.time)

        // A moment inside that hour on the map still finds it.
        let moment = hour.addingTimeInterval(2000)
        let at = try await store.linkSamples("nl", from: moment.addingTimeInterval(-900), to: moment)
        XCTAssertNotNil(MapMoment.links(at, at: moment)["us"])

        // Cleanup runs once an hour, not every round.
        try await store.addSamples("nl", [Fixtures.snapshot(time: now.addingTimeInterval(-40 * 86400))])
        try await store.rollup(since: now, now: now.addingTimeInterval(60))
        var kept = try await store.samples("nl", from: now.addingTimeInterval(-41 * 86400), to: now)
        XCTAssertEqual(kept.count, 1)
        try await store.rollup(since: now, now: now.addingTimeInterval(3601))
        kept = try await store.samples("nl", from: now.addingTimeInterval(-41 * 86400), to: now)
        XCTAssertEqual(kept.count, 0)
    }

    func testBrokenEntrySkipped() throws {
        let token = String(repeating: "a", count: 43), fp = String(repeating: "AB", count: 32)
        let json = """
        {"servers": [
          {"id": "nl", "name": "NL", "host": "203.0.113.10", "token": "\(token)", "fingerprint": "\(fp)"},
          {"id": "us", "name": "US", "token": "\(token)", "fingerprint": "\(fp)"},
          {"id": "ru", "name": "RU", "host": "203.0.113.12", "token": "short", "fingerprint": "\(fp)"},
          {"id": "nl", "name": "NL again", "host": "203.0.113.13", "token": "\(token)", "fingerprint": "\(fp)"}
        ],
        "sites": [
          {"id": "shop", "name": "Shop", "url": "https://shop.example.com"},
          {"id": "bad", "name": "Bad", "url": "ftp://example.com"}
        ]}
        """
        let (file, problems) = try ServersFile.decodeSkipping(Data(json.utf8))
        XCTAssertEqual(file.servers.map(\.id), ["nl"])
        XCTAssertEqual(file.sites?.map(\.id), ["shop"])
        XCTAssertEqual(problems.count, 4)
        XCTAssertTrue(problems[0].hasPrefix("сервер №2: нет поля «host»"), problems[0])
        XCTAssertTrue(problems.contains { $0.contains("сервер ru: токен слишком короткий") })
        XCTAssertTrue(problems.contains { $0.contains("повторяется") })
        XCTAssertThrowsError(try ServersFile.decodeSkipping(Data("{".utf8)), "not JSON at all")
    }

    func testPBKDF2() {
        // RFC 7914, section 11.
        let key = Transfer.derive("password", salt: Data("salt".utf8), iterations: 4096)
        let hex = key.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
    }

    func testTransferRoundTrip() async throws {
        let dir = try tempDir()
        let token = String(repeating: "b", count: 43)
        let old = MemorySecrets([SecretKey.agentToken("nl"): token, SecretKey.sshPassword("nl"): "ssh-pass",
                                 SecretKey.siteAuth("shop"): "site-pass"])
        for name in ["old.json", "new.json"] {
            try Data(ServersFile.example.utf8).write(to: dir.appendingPathComponent(name))
        }
        let oldConfig = ConfigRepository(url: dir.appendingPathComponent("old.json"), secrets: old)
        var nl = Fixtures.server
        nl.token = token
        try await oldConfig.upsertServer(nl)
        try await oldConfig.upsertSite(SiteConfig(id: "shop", name: "Shop", url: "https://shop.example.com",
                                                  authUser: "admin", authPassword: "site-pass"))
        let contents = try await oldConfig.exportContents(now: t0)
        XCTAssertFalse(String(decoding: contents.servers, as: UTF8.self).contains(token), "no token in servers.json")

        let database = Data("SQLite format 3\u{0}rows".utf8)
        let file = try Transfer.seal(contents, database: database, password: "correct horse", iterations: 2_000)
        XCTAssertNil(file.range(of: Data(token.utf8)), "encrypted")
        XCTAssertThrowsError(try Transfer.open(file, password: "wrong pass1")) {
            XCTAssertEqual(String(describing: $0), "неверный пароль или файл повреждён")
        }
        XCTAssertThrowsError(try Transfer.seal(contents, database: database, password: "short"))

        let (back, db) = try Transfer.open(file, password: "correct horse")
        XCTAssertEqual(back, contents)
        XCTAssertEqual(db, database)

        // On the new Mac: servers, sites and secrets at once.
        let fresh = MemorySecrets()
        let newConfig = ConfigRepository(url: dir.appendingPathComponent("new.json"), secrets: fresh)
        let imported = try await newConfig.importContents(back)
        XCTAssertEqual(imported.servers.map(\.id), ["nl"])
        XCTAssertEqual(try fresh.get(SecretKey.sshPassword("nl")), "ssh-pass")
        let loaded = try await newConfig.load()
        XCTAssertEqual(loaded.servers.first?.token, token)
        XCTAssertEqual(loaded.sites?.first?.authPassword, "site-pass")

        // The history goes in place before the store opens.
        let live = dir.appendingPathComponent("monitor.sqlite"), pending = dir.appendingPathComponent("import.sqlite")
        let keep = dir.appendingPathComponent("Previous/before.sqlite")
        try Data("old".utf8).write(to: live)
        try db.write(to: pending)
        try Transfer.applyPendingDatabase(pending: pending, database: live, keep: keep)
        XCTAssertEqual(try Data(contentsOf: live), database)
        XCTAssertEqual(try Data(contentsOf: keep), Data("old".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
    }
}

/// An agent that answers but refuses the check list, like one given too many targets.
final class RefusingAgent: AgentTransport, @unchecked Sendable {
    let inner = FakeAgent()
    var history: [Snapshot] {
        get { inner.history }
        set { inner.history = newValue }
    }

    func send(_ server: ServerConfig, method: String, path: String, body: Data?) async throws -> (Int, Data) {
        if method == "PUT", path == "/v1/checks" { return (400, Data("at most 100 targets\n".utf8)) }
        return try await inner.send(server, method: method, path: path, body: body)
    }
}
