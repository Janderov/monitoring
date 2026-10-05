import Foundation
import XCTest
@testable import MonitorCore

/// Plays an agent: serves history/snapshot from a list, or fails.
final class FakeAgent: AgentTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _history: [Snapshot] = []
    private var _down = false
    private var _requests: [String] = []

    var history: [Snapshot] {
        get { lock.withLock { _history } }
        set { lock.withLock { _history = newValue } }
    }
    var down: Bool {
        get { lock.withLock { _down } }
        set { lock.withLock { _down = newValue } }
    }
    var requests: [String] { lock.withLock { _requests } }

    func send(_ server: ServerConfig, method: String, path: String, body: Data?) async throws -> (Int, Data) {
        let (down, history) = lock.withLock { () -> (Bool, [Snapshot]) in
            _requests.append("\(method) \(path)")
            return (_down, _history)
        }
        if down { throw AgentError.http(502, "down") }
        if path.hasPrefix("/v1/history") {
            let since = Double(path.split(separator: "=").last!)!
            let page = HistoryPage(snapshots: history.filter { $0.time.timeIntervalSince1970 > since }, more: false)
            return (200, try AgentJSON.encoder.encode(page))
        }
        if path == "/v1/health" { return (200, Data(#"{"status":"ok","version":"3-merge","agent_uptime_s":1}"#.utf8)) }
        if path == "/v1/snapshot" { return (200, try AgentJSON.encoder.encode(history.last!)) }
        if method == "PUT", path == "/v1/checks" || path == "/v1/settings" { return (200, body ?? Data()) }
        return (404, Data())
    }
}

final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [AlertEvent] = []
    private var _statuses: [ServerStatus] = []
    var events: [AlertEvent] { lock.withLock { _events } }
    var statuses: [ServerStatus] { lock.withLock { _statuses } }
    func add(_ e: [AlertEvent]) { lock.withLock { _events += e } }
    func set(_ s: [ServerStatus]) { lock.withLock { _statuses = s } }
}

final class PollerTests: XCTestCase {
    func testBackfillAlertAndRecover() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let agent = FakeAgent()
        agent.history = (0..<10).map { Fixtures.snapshot(time: t0.addingTimeInterval(TimeInterval($0 * 60))) }
        let store = try Store(path: dir.appendingPathComponent("m.sqlite").path)
        let out = Collector()
        let poller = Poller(client: AgentClient(transport: agent), store: store,
                            onUpdate: { out.set($0) }, onEvents: { out.add($0) })
        var other = Fixtures.server
        other.id = "ru"
        await poller.setServers([Fixtures.server, other])

        // The Mac was asleep for 5 hours: the missed minutes are backfilled
        // and rolled up into hourly rows.
        let now = t0.addingTimeInterval(5 * 3600)
        await poller.pollAll(now: now)
        let stored = try await store.samples("nl", from: t0, to: now)
        XCTAssertEqual(stored.count, 10)
        let hours = try await store.hourly("nl", from: t0.addingTimeInterval(-3600), to: t0.addingTimeInterval(600))
        XCTAssertEqual(hours.map(\.samples).reduce(0, +), 10)
        XCTAssertEqual(out.statuses.map(\.level), [.ok, .ok])
        XCTAssertEqual(out.statuses.first?.snapshot?.hostname, "wise")

        // Next poll asks only for what is new.
        await poller.pollAll(now: now.addingTimeInterval(60))
        XCTAssertTrue(agent.requests.contains("GET /v1/history?since=\(Int(t0.timeIntervalSince1970) + 540)"))

        // Both servers (one agent fake) unreachable: looks like the Mac is offline, no alerts.
        agent.down = true
        for m in 2..<6 { await poller.pollAll(now: now.addingTimeInterval(TimeInterval(m * 60))) }
        XCTAssertTrue(out.events.isEmpty)

        // Only one server down: alert after 3 polls.
        await poller.setServers([Fixtures.server])
        for m in 6..<9 { await poller.pollAll(now: now.addingTimeInterval(TimeInterval(m * 60))) }
        XCTAssertEqual(out.events.map(\.kind), [.fired])
        XCTAssertEqual(out.statuses.first?.level, .critical)
        XCTAssertNotNil(out.statuses.first?.error)

        agent.down = false
        await poller.pollAll(now: now.addingTimeInterval(9 * 60))
        XCTAssertEqual(out.events.map(\.kind), [.fired, .resolved])
        XCTAssertEqual(out.statuses.first?.level, .ok)
        let logged = try await store.events()
        XCTAssertEqual(logged.count, 2)
    }

    func testFastRefreshBetweenFullRounds() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let agent = FakeAgent()
        var snap = Fixtures.snapshot(time: t0)
        snap.intervalS = 60
        agent.history = [snap]
        let store = try Store(path: dir.appendingPathComponent("m.sqlite").path)
        let out = Collector()
        let poller = Poller(client: AgentClient(transport: agent), store: store,
                            onUpdate: { out.set($0) }, onEvents: { out.add($0) })
        await poller.setServers([Fixtures.server])
        await poller.setRefreshInterval(15)

        // The first tick is a full round and asks the agent to sample faster.
        let pause = await poller.tick(now: t0)
        XCTAssertEqual(pause, 15)
        XCTAssertTrue(agent.requests.contains("PUT /v1/settings"))

        // In between: only the current snapshot, nothing stored.
        var faster = Fixtures.snapshot(time: t0.addingTimeInterval(15))
        faster.intervalS = 15
        agent.history = [snap, faster]
        let before = agent.requests.count
        _ = await poller.tick(now: t0.addingTimeInterval(15))
        XCTAssertEqual(Array(agent.requests.dropFirst(before)), ["GET /v1/snapshot"])
        XCTAssertEqual(out.statuses.first?.snapshot?.time, faster.time)
        let stored = try await store.samples("nl", from: t0.addingTimeInterval(-60), to: t0.addingTimeInterval(60))
        XCTAssertEqual(stored.count, 1)

        // A minute after the last full round comes the next one; the agent
        // already samples at 15 s, so nothing is pushed.
        let mark = agent.requests.count
        _ = await poller.tick(now: t0.addingTimeInterval(60))
        let full = Array(agent.requests.dropFirst(mark))
        XCTAssertTrue(full.contains { $0.hasPrefix("GET /v1/history") })
        XCTAssertFalse(full.contains("PUT /v1/settings"))
    }

    func testOldAgentGetsNoSettings() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = FakeAgent()
        agent.history = [Fixtures.snapshot(time: Date(timeIntervalSince1970: 1_790_000_000))]
        let store = try Store(path: dir.appendingPathComponent("m.sqlite").path)
        let poller = Poller(client: AgentClient(transport: agent), store: store,
                            onUpdate: { _ in }, onEvents: { _ in })
        await poller.setServers([Fixtures.server])
        await poller.setRefreshInterval(10)
        await poller.pollAll(now: Date(timeIntervalSince1970: 1_790_000_060))
        XCTAssertFalse(agent.requests.contains("PUT /v1/settings"))
    }
}
