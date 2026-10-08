import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import MonitorCore

/// Stage 4: forecasts arrive by themselves, and an outside service notices
/// when the Mac stops checking.
final class ForecastTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func testForecastLists() {
        let soon: [(server: String, item: SoonItem)] = [
            ("wise1", SoonItem(kind: .tls, name: "shop.example.com", date: t0.addingTimeInterval(10 * 86400))),
            ("wise1", SoonItem(kind: .disk, name: "диск", date: t0.addingTimeInterval(1.5 * 86400))),
            // A month away: not yet.
            ("nl", SoonItem(kind: .domain, name: "far.example.com", date: t0.addingTimeInterval(25 * 86400))),
        ]
        let care: [(server: String, note: CareNote)] = [
            ("wise1", CareNote(kind: .oldBackup, text: "Бэкап базы pg: 3 дн назад", warn: true, subject: "pg")),
            ("nl", CareNote(kind: .updates, text: "Обновлений Ubuntu: 4", warn: false)),
            ("us", CareNote(kind: .security, text: "Обновлений безопасности: 2", warn: true)),
        ]
        let items = Forecast.items(soon: soon, care: care, now: t0)
        XCTAssertEqual(items.map(\.line), [
            "Диск wise1 заполнится завтра",
            "SSL shop.example.com истекает через 10 дн",
            "wise1: бэкап базы pg: 3 дн назад",
            "us: обновлений безопасности: 2",
        ])
        XCTAssertEqual(items.filter(\.urgent).map(\.line), ["Диск wise1 заполнится завтра"])
        let n = Forecast.notice(items)
        XCTAssertEqual(n?.title, "Прогноз: требует внимания 4")
        XCTAssertNil(Forecast.notice([]), "nothing to say, no notification")

        // The urgent one goes out once a day, not every minute.
        let first = Forecast.dueNow(items, sent: [:], now: t0)
        XCTAssertEqual(first.due.count, 1)
        XCTAssertTrue(Forecast.dueNow(items, sent: first.sent, now: t0.addingTimeInterval(600)).due.isEmpty)
        XCTAssertEqual(Forecast.dueNow(items, sent: first.sent, now: t0.addingTimeInterval(86400 + 60)).due.count, 1)
    }

    func testHeartbeatAddress() {
        XCTAssertNotNil(Heartbeat.parse(" https://hc-ping.com/0f3e2a1b-0000-4000-8000-000000000000 "))
        XCTAssertNil(Heartbeat.parse("http://hc-ping.com/abc"), "https only")
        XCTAssertNil(Heartbeat.parse("https://user:pass@hc-ping.com/abc"))
        XCTAssertNil(Heartbeat.parse("hc-ping.com/abc"))
    }

    func testHeartbeatRequests() throws {
        let base = try XCTUnwrap(URL(string: "https://hc-ping.com/abc"))
        let ok = try XCTUnwrap(Heartbeat.request(base, health: PollerHealth(), servers: (3, 3), sites: (4, 4)))
        XCTAssertEqual(ok.url?.absoluteString, "https://hc-ping.com/abc")
        XCTAssertEqual(String(decoding: ok.httpBody ?? Data(), as: UTF8.self), "серверы 3 из 3 в норме, сайты 4 из 4")

        XCTAssertNil(Heartbeat.request(base, health: PollerHealth(macOffline: true), servers: (0, 3), sites: (0, 0)),
                     "no network: silence raises the alarm")
        let db = try XCTUnwrap(Heartbeat.request(base, health: PollerHealth(storeError: "disk full"), servers: (3, 3), sites: (0, 0)))
        XCTAssertEqual(db.url?.absoluteString, "https://hc-ping.com/abc/fail")
        let empty = try XCTUnwrap(Heartbeat.request(base, health: PollerHealth(), servers: (0, 0), sites: (0, 0)))
        XCTAssertEqual(empty.url?.lastPathComponent, "fail", "a list with no servers watches nothing")
        XCTAssertEqual(Heartbeat.sleepNote(base).url?.absoluteString, "https://hc-ping.com/abc/log")
    }

    func testHeartbeatOncePerMinute() async throws {
        let sent = PingCounter()
        let sender = HeartbeatSender { _ in sent.add(); return 200 }
        let base = try XCTUnwrap(URL(string: "https://hc-ping.com/abc"))
        let r = Heartbeat.request(base, health: PollerHealth(), servers: (1, 1), sites: (0, 0))
        await sender.tick(r, now: t0)
        await sender.tick(r, now: t0.addingTimeInterval(10))
        XCTAssertEqual(sent.value, 1, "screen updates every 10 s, pings once a minute")
        let s = await sender.tick(r, now: t0.addingTimeInterval(60))
        XCTAssertEqual(sent.value, 2)
        XCTAssertEqual(s.lastSent, t0.addingTimeInterval(60))
        XCTAssertNil(s.error)

        let failing = HeartbeatSender { _ in 404 }
        let bad = await failing.tick(r, now: t0)
        XCTAssertNil(bad.lastSent)
        XCTAssertEqual(bad.error?.contains("404"), true)
    }

    func testTransferCarriesHeartbeat() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("servers.json")
        try Data(ServersFile.example.utf8).write(to: url)
        let secrets = MemorySecrets([SecretKey.heartbeat: "https://hc-ping.com/abc"])
        let contents = try await ConfigRepository(url: url, secrets: secrets).exportContents(now: t0)
        XCTAssertEqual(contents.secrets[SecretKey.heartbeat], "https://hc-ping.com/abc")
    }
}

private final class PingCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}
