import Foundation
import XCTest
@testable import MonitorCore

final class MapToolsTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func testWhatIfFollowsCascades() {
        let chains = [
            NetworkChain(nodes: ["mac", "nl", "us"], active: true),
            NetworkChain(nodes: ["ru", "nl", "us"], active: true),
            NetworkChain(nodes: ["mac", "ru"], active: true),
        ]
        let clients: [(serverID: String, active: Bool)] = [("nl", true), ("nl", false), ("ru", true), ("de", true)]
        let us = WhatIf.impact(off: "us", chains: chains, clients: clients,
                               siteHosts: ["shop": "ru"], siteChecks: ["shop": ["us", "nl"]])
        XCTAssertEqual(us.brokenChains.count, 2)
        // RU clients enter the RU -> NL -> US cascade; NL is not the start of any broken path.
        XCTAssertEqual(us.clientsLost, 1)
        XCTAssertEqual(us.clientsTotal, 4)
        XCTAssertEqual(us.sites, [])
        XCTAssertEqual(us.checks, ["shop"])
        // From the Mac there is still Mac -> RU; from RU there is no other path.
        XCTAssertEqual(us.hasBackup, false)

        let nl = WhatIf.impact(off: "nl", chains: chains, clients: clients, siteHosts: [:], siteChecks: [:])
        XCTAssertEqual(nl.clientsLost, 3)
        XCTAssertEqual(nl.clientsLostOnline, 2)

        let de = WhatIf.impact(off: "de", chains: chains, clients: clients, siteHosts: [:], siteChecks: [:])
        XCTAssertTrue(de.brokenChains.isEmpty)
        XCTAssertNil(de.hasBackup)
        XCTAssertEqual(de.clientsLost, 1)

        let withBackup = chains + [NetworkChain(nodes: ["ru", "de"], active: true)]
        XCTAssertEqual(WhatIf.impact(off: "us", chains: withBackup, clients: [], siteHosts: [:], siteChecks: [:]).hasBackup, true)
    }

    func testCheckHostNodesAndResults() {
        let nodes = Data("""
        {"nodes": {
          "ru1.node.check-host.net": {"asn": "AS1", "ip": "192.0.2.1", "location": ["ru", "Russia", "Moscow"]},
          "ru4.node.check-host.net": {"asn": "AS2", "ip": "192.0.2.4", "location": ["ru", "Russia", "Ekaterinburg"]},
          "de1.node.check-host.net": {"asn": "AS3", "ip": "192.0.2.9", "location": ["de", "Germany", "Nuremberg"]}
        }}
        """.utf8)
        let ru = CheckHost.nodes(nodes)
        XCTAssertEqual(ru.map(\.city), ["Ekaterinburg", "Moscow"])
        XCTAssertEqual(ru.first?.country, "RU")

        XCTAssertEqual(CheckHost.requestID(Data(#"{"ok":1,"request_id":"a1b2","nodes":{}}"#.utf8)), "a1b2")

        let results = CheckHost.results(Data("""
        {"ru1.node.check-host.net": [{"time": 0.048, "address": "203.0.113.10"}],
         "ru4.node.check-host.net": [{"error": "Connection timed out"}],
         "ru2.node.check-host.net": null,
         "ru3.node.check-host.net": [[{"time": 0.31}]]}
        """.utf8))
        guard case .ok(let ms)? = results["ru1.node.check-host.net"] else { return XCTFail() }
        XCTAssertEqual(ms, 48, accuracy: 0.01)
        XCTAssertEqual(results["ru4.node.check-host.net"], .failed("Connection timed out"))
        XCTAssertEqual(results["ru2.node.check-host.net"], .pending)
        guard case .ok(let ms3)? = results["ru3.node.check-host.net"] else { return XCTFail() }
        XCTAssertEqual(ms3, 310, accuracy: 0.01)
        XCTAssertEqual(CheckHost.describe("Connection timed out"), "не отвечает")
    }

    func testTracerouteParseAndCulprit() {
        let out = """
        traceroute to 203.0.113.10 (203.0.113.10), 24 hops max, 52 byte packets
         1  192.168.1.1  1.512 ms  1.201 ms  1.188 ms
         2  * * *
         3  198.51.100.1  9.120 ms  9.001 ms  8.950 ms
         4  198.51.100.9  140.2 ms *  139.8 ms
         5  203.0.113.10  148.0 ms *  147.1 ms !H
        """
        let hops = Traceroute.parse(out)
        XCTAssertEqual(hops.map(\.number), [1, 2, 3, 4, 5])
        XCTAssertEqual(hops[0].ip, "192.168.1.1")
        XCTAssertEqual(hops[0].rtts.count, 3)
        XCTAssertNil(hops[1].ip)
        XCTAssertEqual(hops[1].loss, 1)
        XCTAssertEqual(hops[3].lost, 1)
        XCTAssertEqual(hops[4].averageMs ?? 0, 147.55, accuracy: 0.01)
        // Hop 2 skips replies but hop 3 is fine: the loss starts at hop 4.
        XCTAssertEqual(Traceroute.culprit(hops)?.number, 4)

        let clean = Traceroute.parse(" 1  192.168.1.1  1.5 ms  1.2 ms  1.1 ms\n 2  203.0.113.10  40 ms  41 ms  40 ms")
        XCTAssertNil(Traceroute.culprit(clean))
    }

    func testDiskForecast() {
        // 1% a day for two weeks, from 60%.
        let points = (0..<56).map { i in
            (time: t0.addingTimeInterval(Double(i) * 6 * 3600), percent: 60 + Double(i) * 0.25)
        }
        let now = points.last!.time
        let days = DiskForecast.daysUntilFull(points, now: now)
        XCTAssertEqual(days ?? 0, (95 - 73.75) / 1, accuracy: 0.5)

        let flat = points.map { (time: $0.time, percent: 50.0) }
        XCTAssertNil(DiskForecast.daysUntilFull(flat, now: now))
        XCTAssertNil(DiskForecast.daysUntilFull(Array(points.prefix(5)), now: points[4].time), "too little history")
        let full = points.map { (time: $0.time, percent: 96.0) }
        XCTAssertEqual(DiskForecast.daysUntilFull(full, now: now), 0)
    }

    func testSoonItems() {
        let items = Soon.items(sites: [(name: "shop", tls: t0.addingTimeInterval(9 * 86400), domain: t0.addingTimeInterval(200 * 86400))],
                               diskDays: 20, now: t0)
        XCTAssertEqual(items.map(\.kind), [.tls, .disk])
        XCTAssertTrue(Soon.badge(items, now: t0))
        XCTAssertFalse(Soon.badge([SoonItem(kind: .disk, name: "диск", date: t0.addingTimeInterval(20 * 86400))], now: t0))
    }

    func testHistoryMarks() {
        func ev(_ key: String, _ kind: AlertEvent.Kind, _ sev: Severity, _ at: TimeInterval) -> Store.LoggedEvent {
            Store.LoggedEvent(serverID: "nl", time: t0.addingTimeInterval(at), key: key, kind: kind,
                              severity: sev, message: key, actor: "system")
        }
        let events = [
            ev("down", .fired, .critical, 300),
            ev("down", .resolved, .critical, 400),
            ev("reboot", .info, .warning, 100),
            ev("ctr:web", .info, .warning, 150),
            ev("disk", .fired, .warning, 200),
            ev("disk", .reminder, .warning, 250),
            ev("cpu", .fired, .warning, 9_000),
        ]
        let marks = MapMoment.marks(events, from: t0, to: t0.addingTimeInterval(1000))
        XCTAssertEqual(marks.map(\.kind), [.reboot, .warning, .down])
    }

    func testIPWho() {
        let city = IPWho.parse(Data("""
        {"ip":"198.51.100.7","success":true,"city":"Kazan","country_code":"ru","latitude":55.79,"longitude":49.12}
        """.utf8))
        XCTAssertEqual(city?.city, "Kazan")
        XCTAssertEqual(city?.country, "RU")
        XCTAssertEqual(city?.latitude ?? 0, 55.79, accuracy: 0.001)
        XCTAssertNil(IPWho.parse(Data(#"{"ip":"10.0.0.1","success":false,"message":"Reserved range"}"#.utf8)))
    }

    func testHostCareDecodesAndNotes() throws {
        var snap = Fixtures.snapshot(time: t0)
        XCTAssertEqual(Care.notes(snap, now: t0), [], "an older agent reports no care data")
        let json = Data("""
        {"system": {"os": "Ubuntu 24.04.1 LTS", "updates_pending": 14, "security_updates": 5, "reboot_required": true,
                    "reboot_packages": ["linux-base"], "updates_checked_at": "2026-10-08T06:00:00.123456789Z"},
         "ssh": {"failed_day": 1200, "sources": [{"ip": "198.51.100.7", "count": 900}],
                 "logins": [{"time": "2026-10-08T09:14:00Z", "user": "root", "ip": "192.0.2.10", "method": "publickey"}],
                 "source": "/var/log/auth.log"},
         "backups": [{"container": "other-db", "newest": "2026-10-01T03:17:00Z", "newest_bytes": 100, "count": 1, "total_bytes": 100}]}
        """.utf8)
        struct Care3: Decodable { var system: Snapshot.System?; var ssh: Snapshot.SSHLog?; var backups: [Snapshot.Backup]? }
        let c = try AgentJSON.decoder.decode(Care3.self, from: json)
        XCTAssertEqual(c.system?.securityUpdates, 5)
        XCTAssertNotNil(c.system?.updatesCheckedAt)
        XCTAssertEqual(c.ssh?.failedDay, 1200)
        XCTAssertEqual(c.ssh?.logins?.first?.method, "publickey")
        XCTAssertEqual(c.backups?.first?.newestBytes, 100)

        snap.system = c.system
        snap.ssh = c.ssh
        snap.backups = c.backups
        let notes = Care.notes(snap, now: t0)
        XCTAssertEqual(notes.map(\.kind), [.reboot, .security, .noBackup, .sshNoise])
        XCTAssertEqual(notes.filter(\.warn).count, 3)

        snap.backups = [Snapshot.Backup(container: "shop-db", newest: t0.addingTimeInterval(-3 * 86400),
                                        newestBytes: 1, count: 1, totalBytes: 1, nightly: true)]
        XCTAssertEqual(Care.notes(snap, now: t0).first { $0.subject == "shop-db" }?.kind, .oldBackup)
        snap.backups![0].newest = t0.addingTimeInterval(-3600)
        XCTAssertNil(Care.notes(snap, now: t0).first { $0.subject == "shop-db" })
    }

    func testPaymentDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        func day(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d))! }
        let cost = ServerCost(monthly: 6, currency: "€", payDay: 31)
        XCTAssertEqual(cost.nextPayment(after: day(2026, 2, 10), calendar: cal), day(2026, 2, 28))
        XCTAssertEqual(cost.nextPayment(after: day(2026, 10, 31).addingTimeInterval(3600), calendar: cal), day(2026, 10, 31))
        XCTAssertEqual(ServerCost(monthly: 6, currency: "€", payDay: 5).nextPayment(after: day(2026, 10, 8), calendar: cal),
                       day(2026, 11, 5))
        XCTAssertNil(ServerCost(monthly: 6, currency: "€").nextPayment(after: t0, calendar: cal))

        let soon = Soon.items(sites: [], diskDays: nil, payment: t0.addingTimeInterval(10 * 86400), now: t0)
        XCTAssertEqual(soon.map(\.kind), [.payment])
        XCTAssertFalse(Soon.badge(soon, now: t0), "a payment gets the dot only 3 days ahead")
        XCTAssertTrue(Soon.badge(soon, now: t0.addingTimeInterval(8 * 86400)))
    }

    func testMorningSummary() {
        let events = [
            Store.LoggedEvent(serverID: "nl", time: t0.addingTimeInterval(-3600), key: "down", kind: .fired,
                              severity: .critical, message: "", actor: "system"),
            Store.LoggedEvent(serverID: "nl", time: t0.addingTimeInterval(-7200), key: "reboot", kind: .info,
                              severity: .warning, message: "", actor: "system"),
            Store.LoggedEvent(serverID: "nl", time: t0.addingTimeInterval(-3 * 86400), key: "down", kind: .fired,
                              severity: .critical, message: "", actor: "system"),
        ]
        let note = CareNote(kind: .reboot, text: "Нужна перезагрузка после обновлений", warn: true)
        let m = MorningSummary.build(servers: [("NL", true), ("US", true)], sites: (4, 4), events: events,
                                     soon: [("wise1", SoonItem(kind: .tls, name: "shop", date: t0.addingTimeInterval(5 * 86400)))],
                                     care: [("NL", note)], now: t0)
        XCTAssertEqual(m.title, "Утренняя сводка: всё в порядке")
        XCTAssertEqual(m.body.split(separator: "\n").map(String.init), [
            "Серверы 2 из 2 в норме · сайты 4 из 4",
            "За сутки: сбоев 1, перезагрузок 1",
            "Скоро: SSL shop (wise1) через 5 дн",
            "Внимание: NL, нужна перезагрузка после обновлений",
        ])
        let bad = MorningSummary.build(servers: [("NL", false)], sites: (3, 4), events: [], soon: [], care: [], now: t0)
        XCTAssertEqual(bad.title, "Утренняя сводка: проблем 2")
        XCTAssertTrue(bad.body.contains("Сейчас с проблемой: NL"))
        XCTAssertTrue(bad.body.contains("За сутки сбоев не было"))

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let nine = cal.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 9, minute: 5))!
        XCTAssertTrue(MorningSummary.due(now: nine, hour: 9, lastSent: nil, calendar: cal))
        XCTAssertFalse(MorningSummary.due(now: nine.addingTimeInterval(-3600), hour: 9, lastSent: nil, calendar: cal))
        XCTAssertFalse(MorningSummary.due(now: nine, hour: 9, lastSent: nine.addingTimeInterval(-60), calendar: cal))
        XCTAssertTrue(MorningSummary.due(now: nine, hour: 9, lastSent: nine.addingTimeInterval(-86400), calendar: cal))
    }
}
