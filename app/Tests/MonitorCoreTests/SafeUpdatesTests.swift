import Foundation
import XCTest
@testable import MonitorCore

/// Updates that can be undone: agents roll back on their own, outdated ones
/// are visible, the app updates from releases and keeps the previous build.
final class SafeUpdatesTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func testFrozenSamplesRaiseStaleAlert() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = FakeAgent()
        agent.history = [Fixtures.snapshot(time: t0)]
        let store = try Store(path: dir.appendingPathComponent("m.sqlite").path)
        let out = Collector()
        let poller = Poller(client: AgentClient(transport: agent), store: store,
                            onUpdate: { out.set($0) }, onEvents: { out.add($0) })
        await poller.setServers([Fixtures.server])
        // The agent answers every minute with the same sample: its sampling hangs.
        for m in 0...5 { await poller.pollAll(now: t0.addingTimeInterval(TimeInterval(m * 60))) }
        XCTAssertEqual(out.events.map(\.key), ["stale"])
        XCTAssertEqual(out.statuses.first?.alerts.map(\.key), ["stale"])

        // Sampling resumes: cleared after two good rounds.
        agent.history.append(Fixtures.snapshot(time: t0.addingTimeInterval(360)))
        await poller.pollAll(now: t0.addingTimeInterval(360))
        agent.history.append(Fixtures.snapshot(time: t0.addingTimeInterval(420)))
        await poller.pollAll(now: t0.addingTimeInterval(420))
        XCTAssertEqual(out.events.map(\.kind), [.fired, .resolved])
    }

    func testRollbackMessage() {
        let out = """
            monitor-agent 20261008-abc installed
            rollback: the new agent did not start; its last log lines:
            rollback:   load certificate: open /etc/monitor-agent/cert.pem: permission denied
            rollback: previous version 20261001-def restored
            """
        let why = AgentInstaller.rollbackMessage(out)
        XCTAssertEqual(why?.hasPrefix("новая версия агента не запустилась, вернул прежнюю"), true)
        XCTAssertEqual(why?.contains("permission denied"), true)
        XCTAssertNil(AgentInstaller.rollbackMessage("all fine"))
        XCTAssertEqual(AgentInstaller.rollbackMessage("rollback: the new agent did not start"), "агент не запустился")
    }

    func testOutdatedAgents() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "20261008-abc1234\n".write(to: dir.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
        let bundled = AgentBundle.version(in: dir)
        XCTAssertEqual(bundled, "20261008-abc1234")

        var snap = Fixtures.snapshot()
        XCTAssertTrue(AgentBundle.outdated(snap, bundled: bundled), "an agent that reports no version is old")
        snap.agentVersion = "20261008-abc1234"
        XCTAssertFalse(AgentBundle.outdated(snap, bundled: bundled))
        snap.agentVersion = "20261001-0000000"
        XCTAssertTrue(AgentBundle.outdated(snap, bundled: bundled))
        XCTAssertFalse(AgentBundle.outdated(snap, bundled: nil), "no bundled agent: nothing to compare")
        XCTAssertFalse(AgentBundle.outdated(nil, bundled: bundled))

        let json = Fixtures.snapshotJSON().replacingOccurrences(of: #""hostname": "wise","#,
                                                                 with: #""hostname": "wise", "agent_version": "v9","#)
        XCTAssertEqual(try AgentJSON.decoder.decode(Snapshot.self, from: Data(json.utf8)).agentVersion, "v9")
    }

    let releases = """
    [{"tag_name":"build-124","name":"Сборка 124: Безопасные обновления","draft":false,
      "target_commitish":"cd6cb2f0123456789abcdef0123456789abcdef0","published_at":"2026-10-08T13:00:00Z",
      "assets":[{"name":"Monitor.zip","size":5100000,
                 "browser_download_url":"https://github.com/Janderov/monitoring/releases/download/build-124/Monitor.zip"}]},
     {"tag_name":"build-120","name":"Сборка 120: старое","draft":false,
      "target_commitish":"4ff6ded0123456789abcdef0123456789abcdef0","published_at":"2026-10-07T13:00:00Z",
      "assets":[{"name":"Monitor.zip","size":5000000,
                 "browser_download_url":"https://github.com/Janderov/monitoring/releases/download/build-120/Monitor.zip"}]}]
    """

    func testUpdatesFromReleases() async throws {
        let h = FakeHTTP()
        h.responses = ["/releases?": (200, releases)]
        let updater = AppUpdater(token: "tok", http: h)
        let u = try await updater.check(current: "1.120-dev-4ff6ded")
        XCTAssertEqual(u?.build, 124)
        XCTAssertEqual(u?.title, "Безопасные обновления")
        XCTAssertEqual(u?.version, "1.124-dev-cd6cb2f")
        XCTAssertFalse(h.requests.contains { $0.contains("/actions/") }, "releases need no artifacts")

        // The same build, or a newer one (a PR build): nothing to do.
        let same = try await updater.check(current: "1.124-dev-cd6cb2f")
        XCTAssertNil(same)
        let newer = try await updater.check(current: "1.130-dev-1234567")
        XCTAssertNil(newer)
        XCTAssertEqual(AppUpdater.build(fromVersion: "1.124-dev-cd6cb2f"), 124)
        XCTAssertNil(AppUpdater.build(fromVersion: "0.0.0-dev-cd6cb2f"))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try await updater.download(u!, into: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(h.requests.last, "https://github.com/Janderov/monitoring/releases/download/build-124/Monitor.zip")
    }

    func testDatabaseCopy() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Store(path: dir.appendingPathComponent("m.sqlite").path)
        try await store.setValue("kept", for: "probe")
        let copyURL = dir.appendingPathComponent("copy.sqlite")
        try await store.copy(to: copyURL)
        try await store.copy(to: copyURL)  // an old copy is replaced
        let copy = try Store(path: copyURL.path)
        let value = try await copy.value("probe")
        XCTAssertEqual(value, "kept")
    }
}
