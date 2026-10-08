import Foundation
import XCTest
@testable import MonitorCore

/// The monitoring tells the truth: alerts calm down only below the limit,
/// survive a restart of the app, and a pause of the Mac is summed up.
final class ReliabilityTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    let server = Fixtures.server

    func at(_ minute: Int) -> Date { t0.addingTimeInterval(TimeInterval(minute) * 60) }

    func tempStore() throws -> (Store, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try Store(path: dir.appendingPathComponent("m.sqlite").path), dir)
    }

    func testDiskAlertClearsOnlyBelowTheLimit() {
        var e = AlertEngine()
        _ = e.process(server: server, outcome: .snapshot(Fixtures.snapshot(disk: 91)), now: at(0))
        XCTAssertEqual(e.process(server: server, outcome: .snapshot(Fixtures.snapshot(disk: 91)), now: at(1)).map(\.kind),
                       [.fired])
        // 88% is under the 90% limit but not 5 points under: still on, no ringing.
        for m in 2..<6 {
            XCTAssertEqual(e.process(server: server, outcome: .snapshot(Fixtures.snapshot(disk: 88)), now: at(m)), [])
        }
        XCTAssertEqual(e.active(server.id).map(\.key), ["disk:/"])
        _ = e.process(server: server, outcome: .snapshot(Fixtures.snapshot(disk: 84)), now: at(6))
        XCTAssertEqual(e.process(server: server, outcome: .snapshot(Fixtures.snapshot(disk: 84)), now: at(7)).map(\.kind),
                       [.resolved])
        // Fresh start: 88% alone raises nothing.
        XCTAssertTrue(Rules.conditions(.snapshot(Fixtures.snapshot(disk: 88)), thresholds: nil, now: t0).isEmpty)
    }

    func testWarningsRemindDaily() {
        var e = AlertEngine()
        _ = e.process(server: server, outcome: .snapshot(Fixtures.snapshot(disk: 95)), now: at(0))
        _ = e.process(server: server, outcome: .snapshot(Fixtures.snapshot(disk: 95)), now: at(1))
        var reminders = 0
        for m in 2...(25 * 60) {
            reminders += e.process(server: server, outcome: .snapshot(Fixtures.snapshot(disk: 95)), now: at(m))
                .filter { $0.kind == .reminder }.count
        }
        XCTAssertEqual(reminders, 1)
    }

    func testEngineStateSurvivesSaveAndRestore() {
        var e = AlertEngine()
        for m in 0..<3 { _ = e.process(server: server, outcome: .failure("x"), now: at(m)) }
        XCTAssertEqual(e.active(server.id).map(\.key), ["down"])
        var again = AlertEngine()
        again.restore(e.saved()!)
        XCTAssertEqual(again.active(server.id).map(\.key), ["down"])
        // Still down: nothing new to say; back up: one "снова в норме".
        XCTAssertEqual(again.process(server: server, outcome: .failure("x"), now: at(3)), [])
        XCTAssertEqual(again.process(server: server, outcome: .snapshot(Fixtures.snapshot()), now: at(4)).map(\.kind),
                       [.resolved])
    }

    func testRestartDoesNotAnnounceOngoingAlertsAgain() async throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = FakeAgent()
        agent.history = [Fixtures.snapshot(time: at(0), disk: 95)]
        let first = Collector()
        let poller = Poller(client: AgentClient(transport: agent), store: store,
                            onUpdate: { first.set($0) }, onEvents: { first.add($0) })
        await poller.setServers([server])
        await poller.pollAll(now: at(0))
        agent.history.append(Fixtures.snapshot(time: at(1), disk: 95))
        await poller.pollAll(now: at(1))
        XCTAssertEqual(first.events.map(\.kind), [.fired])

        // The app restarts: same database, a new poller.
        let second = Collector()
        let restarted = Poller(client: AgentClient(transport: agent), store: store,
                               onUpdate: { second.set($0) }, onEvents: { second.add($0) })
        await restarted.setServers([server])
        agent.history.append(Fixtures.snapshot(time: at(2), disk: 95))
        await restarted.pollAll(now: at(2))
        XCTAssertTrue(second.events.isEmpty)
        XCTAssertEqual(second.statuses.first?.alerts.map(\.key), ["disk:/"])
        let health = await restarted.currentHealth()
        XCTAssertEqual(health.lastGoodRound, at(2))
        XCTAssertNil(health.problem)
    }

    func testOfflineMacIsReportedNotHidden() async throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = FakeAgent()
        agent.history = [Fixtures.snapshot(time: at(0))]
        let poller = Poller(client: AgentClient(transport: agent), store: store,
                            onUpdate: { _ in }, onEvents: { _ in })
        var other = server
        other.id = "ru"
        await poller.setServers([server, other])
        await poller.pollAll(now: at(0))
        agent.down = true
        await poller.pollAll(now: at(1))
        let health = await poller.currentHealth()
        XCTAssertTrue(health.macOffline)
        XCTAssertNotNil(health.problem)
        XCTAssertEqual(health.lastGoodRound, at(0))
    }

    func testPauseIsSummedUp() async throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        func sample(_ m: Int, bootedAt boot: Date) -> Snapshot {
            var s = Fixtures.snapshot(time: at(m))
            s.bootTime = boot
            return s
        }
        let agent = FakeAgent()
        agent.history = [sample(0, bootedAt: at(-1440))]
        let out = Collector()
        let poller = Poller(client: AgentClient(transport: agent), store: store,
                            onUpdate: { _ in }, onEvents: { out.add($0) })
        await poller.setServers([server])
        await poller.pollAll(now: at(0))

        // The Mac sleeps two hours; meanwhile the server stops for 30 minutes
        // and comes back rebooted.
        agent.history += (1...30).map { sample($0, bootedAt: at(-1440)) }
            + (60...120).map { sample($0, bootedAt: at(59)) }
        await poller.pollAll(now: at(120))
        let away = out.events.filter { $0.key == AwaySummary.key }
        XCTAssertEqual(away.count, 1)
        XCTAssertTrue(away.first?.message.contains("перезагрузился") == true)
        XCTAssertTrue(away.first?.message.contains("не было данных") == true)
        let logged = try await store.events()
        XCTAssertTrue(logged.contains { $0.key == AwaySummary.key })
    }

    func testQuietPauseIsLoggedWithoutNotification() async throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = FakeAgent()
        agent.history = (0...60).map { Fixtures.snapshot(time: at($0)) }
        let out = Collector()
        let poller = Poller(client: AgentClient(transport: agent), store: store,
                            onUpdate: { _ in }, onEvents: { out.add($0) })
        await poller.setServers([server])
        await poller.pollAll(now: at(0))
        await poller.pollAll(now: at(60))
        XCTAssertTrue(out.events.isEmpty)
        let logged = try await store.events()
        XCTAssertTrue(logged.contains { $0.key == AwaySummary.key && $0.message.contains("всё было в норме") })
    }

    func testSiteFailuresInSummary() {
        let site = SiteConfig(id: "shop", name: "shop.example.com", url: "https://shop.example.com")
        let samples = (1...10).map { m -> Snapshot in
            var s = Fixtures.snapshot(time: at(m))
            s.checks?[0].id = site.checkID
            s.checks?[0].ok = m > 6
            return s
        }
        let lines = AwaySummary.lines(from: at(0), seen: [.init(server: server, before: Fixtures.snapshot(time: at(0)),
                                                                samples: samples)], sites: [site])
        XCTAssertEqual(lines, ["shop.example.com не открывался ~6 мин"])
    }
}
