import Foundation
import XCTest
@testable import MonitorCore

final class StoreTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func newStore() throws -> Store { try Store(path: dir.appendingPathComponent("m.sqlite").path) }

    let hour0 = Date(timeIntervalSince1970: 1_790_002_800) // on an hour boundary

    func testSamplesRollupAndLatest() async throws {
        let store = try newStore()
        let snaps = (0..<90).map { m in
            Fixtures.snapshot(time: hour0.addingTimeInterval(TimeInterval(m * 60)), cpu: m < 60 ? 10 : 50)
        }
        try await store.addSamples("nl", snaps)
        try await store.addSamples("nl", Array(snaps.suffix(5))) // re-delivered history is idempotent
        let last = try await store.lastSampleTime("nl")
        XCTAssertEqual(last, snaps.last?.time)
        let none = try await store.lastSampleTime("ru")
        XCTAssertNil(none)

        try await store.addPoll("nl", at: hour0, ok: true, error: nil)
        try await store.addPoll("nl", at: hour0.addingTimeInterval(60), ok: false, error: "таймаут")
        try await store.rollup(since: hour0, now: hour0.addingTimeInterval(5400))

        let hours = try await store.hourly("nl", from: hour0, to: hour0.addingTimeInterval(7200))
        XCTAssertEqual(hours.count, 2)
        XCTAssertEqual(hours[0].samples, 60)
        XCTAssertEqual(hours[0].cpuAvg, 10, accuracy: 0.01)
        XCTAssertEqual(hours[1].cpuMax, 50, accuracy: 0.01)
        XCTAssertEqual(hours[1].samples, 30)
        XCTAssertEqual(hours[0].pollsOK, 1)
        XCTAssertEqual(hours[0].pollsTotal, 2)
        XCTAssertEqual(hours[0].vpnMax, 3)

        try await store.setLatest("nl", snaps[0])
        let latest = try await store.latest("nl")
        XCTAssertEqual(latest?.hostname, "wise")
        XCTAssertEqual(latest?.vpn?.first?.clients, 24)
        XCTAssertEqual(latest!.time.timeIntervalSince1970, snaps[0].time.timeIntervalSince1970, accuracy: 0.001)
    }

    func testRetentionAndPersistence() async throws {
        var store: Store? = try newStore()
        let old = hour0.addingTimeInterval(-40 * 86400)
        try await store!.addSamples("nl", [Fixtures.snapshot(time: old), Fixtures.snapshot(time: hour0)])
        try await store!.addEvent(AlertEvent(serverID: "nl", serverName: "Нидерланды", key: "down", kind: .fired,
                                             severity: .critical, message: "агент не отвечает", time: hour0))
        try await store!.rollup(since: old, now: hour0)
        let samples = try await store!.samples("nl", from: old.addingTimeInterval(-1), to: hour0)
        XCTAssertEqual(samples.map(\.time), [hour0])
        store = nil

        // Reopen: data survives an app restart.
        let reopened = try newStore()
        let events = try await reopened.events()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .fired)
        XCTAssertEqual(events[0].severity, .critical)
        XCTAssertEqual(events[0].message, "агент не отвечает")
        XCTAssertEqual(events[0].actor, "system")
        let ruEvents = try await reopened.events(serverID: "ru")
        XCTAssertEqual(ruEvents.count, 0)
        // The old sample's hour is kept in hourly (1 year retention).
        let oldHours = try await reopened.hourly("nl", from: old.addingTimeInterval(-3600), to: old)
        XCTAssertEqual(oldHours.count, 1)

        try await reopened.forget(serverID: "nl")
        let gone = try await reopened.lastSampleTime("nl")
        XCTAssertNil(gone)
        let kept = try await reopened.events()
        XCTAssertEqual(kept.count, 1) // the log stays
    }

    func testSchemaVersionAndNewerDatabaseRejected() async throws {
        let path = dir.appendingPathComponent("m.sqlite").path
        _ = try Store(path: path)
        let db = try SQLiteDB(path: path)
        XCTAssertEqual(try db.prepare("PRAGMA user_version").rows().first?.int(0), Int64(Store.schemaVersion))
        _ = try Store(path: path) // reopening re-runs nothing

        try db.exec("PRAGMA user_version = \(Store.schemaVersion + 1)")
        XCTAssertThrowsError(try Store(path: path))
    }

    func testOldPasswordSiteFailuresAreRepaired() async throws {
        let path = dir.appendingPathComponent("m.sqlite").path
        _ = try Store(path: path)
        let db = try SQLiteDB(path: path)
        try db.exec("""
        INSERT INTO site_samples VALUES ('t', 'nl', 1, 0, 401, 200, '401 Unauthorized');
        INSERT INTO site_samples VALUES ('t', 'nl', 2, 0, 502, 200, '502 Bad Gateway');
        INSERT INTO events (server_id, ts, key, kind, severity, message)
          VALUES ('site-t', 1, 'down', 'fired', 2, 'сайт t недоступен: 401 Unauthorized');
        INSERT INTO events (server_id, ts, key, kind, severity, message)
          VALUES ('site-t', 2, 'down', 'fired', 2, 'сайт t недоступен: 502 Bad Gateway');
        PRAGMA user_version = 4;
        """)
        _ = try Store(path: path)
        let ok = try db.prepare("SELECT ok FROM site_samples ORDER BY ts").rows().map { $0.int(0) }
        XCTAssertEqual(ok, [1, 0])
        let left = try db.prepare("SELECT message FROM events").rows().map { $0.text(0) }
        XCTAssertEqual(left, ["сайт t недоступен: 502 Bad Gateway"])
    }

    func testVPNTrafficPerDay() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Store(path: dir.appendingPathComponent("m.sqlite").path)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Moscow")!

        let day1 = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21 17:13 MSK
        func snap(_ t: Date, rx: UInt64, tx: UInt64) -> Snapshot {
            var s = Fixtures.snapshot(time: t)
            s.vpn?[0].peers?[0].rxBytes = rx
            s.vpn?[0].peers?[0].txBytes = tx
            return s
        }
        // The first sighting only sets the baseline.
        try await store.addVPNTraffic("nl", snap(day1, rx: 1_000, tx: 5_000), calendar: cal)
        try await store.addVPNTraffic("nl", snap(day1.addingTimeInterval(60), rx: 1_500, tx: 9_000), calendar: cal)
        // Next day the VPN restarted: counters start again from zero.
        let day2 = day1.addingTimeInterval(86400)
        try await store.addVPNTraffic("nl", snap(day2, rx: 200, tx: 300), calendar: cal)

        let today = try await store.vpnTraffic("nl", from: day2, to: day2, calendar: cal)
        XCTAssertEqual(today["k="], Store.VPNUsage(rx: 200, tx: 300))
        let both = try await store.vpnTraffic("nl", from: day1, to: day2, calendar: cal)
        XCTAssertEqual(both["k="], Store.VPNUsage(rx: 700, tx: 4_300))
        let daily = try await store.vpnDaily("nl", publicKey: "k=", from: day1, to: day2, calendar: cal)
        XCTAssertEqual(daily.map(\.usage.total), [4_500, 500])

        try await store.forget(serverID: "nl")
        let gone = try await store.vpnTraffic("nl", from: day1, to: day2, calendar: cal)
        XCTAssertTrue(gone.isEmpty)
    }
}
