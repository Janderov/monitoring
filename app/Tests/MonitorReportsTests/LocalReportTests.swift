import Foundation
import MonitorCore
import XCTest
@testable import MonitorReports

final class LocalReportTests: XCTestCase {
    let client = Client(id: "c1", name: "Пример", legalName: "ООО «Пример»",
                        contracts: [ClientContract(planName: "Базовый", monthlyPrice: 5000, startedOn: at("2026-06-01 00:00"), slaUptime: 99.5)])
    let other = Client(id: "c2", name: "Другой")
    let app = ServerConfig(id: "app", name: "app.example.com", host: "203.0.113.10", token: "t", fingerprint: "f")
    let vpn = ServerConfig(id: "vpn", name: "vpn.example.net", host: "198.51.100.7", token: "t", fingerprint: "f")
    let shop = SiteConfig(id: "shop", name: "shop.example.com", url: "https://shop.example.com")
    let moved = SiteConfig(id: "moved", name: "moved.example.com", url: "https://moved.example.com")
    let foreign = SiteConfig(id: "foreign", name: "other.example.org", url: "https://other.example.org")

    var book: ClientBook {
        ClientBook(clients: [client, other], assets: [
            ClientAsset(clientID: "c1", type: .site, assetID: "shop", since: at("2026-06-01 00:00")),
            // Moved away on 15 September: still in September's report.
            ClientAsset(clientID: "c1", type: .site, assetID: "moved", since: at("2026-06-01 00:00"), until: at("2026-09-15 00:00")),
            // Moved away before September: not in it.
            ClientAsset(clientID: "c1", type: .server, assetID: "vpn", since: at("2026-06-01 00:00"), until: at("2026-08-01 00:00")),
            ClientAsset(clientID: "c2", type: .site, assetID: "foreign", since: at("2026-06-01 00:00")),
        ])
    }

    func source() -> LocalReport.Source {
        var samples: [Store.SiteSample] = []
        // Two countries check every minute of 23 September 03:00–03:59; both fail 03:12–03:25.
        for m in 0..<60 {
            let t = at("2026-09-23 03:00").addingTimeInterval(Double(m) * 60)
            let down = (12..<26).contains(m)
            samples.append(.init(serverID: "app", time: t, ok: !down, latencyMs: 500))
            samples.append(.init(serverID: "vpn", time: t.addingTimeInterval(5), ok: !down, latencyMs: 700))
        }
        // 24 September: only one country fails: blocked, not down.
        for m in 0..<10 {
            let t = at("2026-09-24 10:00").addingTimeInterval(Double(m) * 60)
            samples.append(.init(serverID: "app", time: t, ok: true, latencyMs: 400))
            samples.append(.init(serverID: "vpn", time: t, ok: false, latencyMs: 0))
        }
        var hourly: [Store.Hourly] = []
        for h in 0..<48 {
            hourly.append(.init(hour: at("2026-09-10 00:00").addingTimeInterval(Double(h) * 3600), cpuMax: h == 30 ? 88 : 40,
                                memMax: 60, diskMax: 70 + Double(h) / 10, pollsOK: h == 5 ? 50 : 60, pollsTotal: 60))
        }
        return LocalReport.Source(
            signature: "Михаил Дмитраков", servers: [app, vpn], sites: [shop, moved, foreign],
            hosting: ["shop": "app"], hourly: ["app": hourly], siteSamples: ["shop": samples],
            events: [
                .init(serverID: SiteStatus.alertID("shop"), time: at("2026-09-23 03:13"), key: "down", kind: .fired,
                      severity: .critical, message: "сайт shop.example.com недоступен: таймаут"),
                .init(serverID: SiteStatus.alertID("shop"), time: at("2026-09-23 03:26"), key: "down", kind: .resolved,
                      severity: .critical, message: "восстановлен"),
                .init(serverID: "app", time: at("2026-09-10 05:00"), key: "reboot", kind: .info, severity: .warning, message: "перезагружен"),
                // Someone else's site.
                .init(serverID: SiteStatus.alertID("foreign"), time: at("2026-09-23 03:13"), key: "down", kind: .fired,
                      severity: .critical, message: "сайт other.example.org недоступен"),
            ],
            domainExpiry: ["shop": at("2026-11-16 12:00")],
            soon: [(object: "app.example.com", item: SoonItem(kind: .disk, name: "/", date: at("2026-11-20 00:00"))),
                   (object: "app.example.com", item: SoonItem(kind: .payment, name: "app.example.com", date: at("2026-10-05 00:00"))),
                   (object: "vpn.example.net", item: SoonItem(kind: .disk, name: "/", date: at("2026-10-20 00:00")))])
    }

    func testObjectsFollowTheBookThroughThePeriod() {
        let o = LocalReport.objects(client, book: book, period: september, servers: [app, vpn], sites: [shop, moved, foreign],
                                    hosting: ["shop": "app"])
        XCTAssertEqual(o.sites.map(\.id), ["shop", "moved"])
        // app comes with the client's site running on it; vpn left before September.
        XCTAssertEqual(o.servers.map(\.id), ["app"])
    }

    func testBuildsAReportFromLocalData() {
        let input = LocalReport.input(client, book: book, source: source(), period: september)
        XCTAssertEqual(input.clientName, "ООО «Пример»")
        XCTAssertEqual(input.slaTarget, 0.995)
        let r = ReportBuilder.build(input, now: generated)

        let shopRow = r.sites.first { $0.name == "shop.example.com" }!
        XCTAssertEqual(shopRow.days[22], .down)
        XCTAssertEqual(shopRow.days[23], .errors)
        XCTAssertEqual(shopRow.days[0], .none)
        XCTAssertEqual(r.sites.first { $0.name == "moved.example.com" }!.uptime, nil)

        XCTAssertEqual(r.incidents.count, 1)
        XCTAssertEqual(r.incidents[0].object, "shop.example.com")
        XCTAssertEqual(r.incidents[0].title, "Недоступен: таймаут")
        XCTAssertEqual(r.incidents[0].durationSeconds, 13 * 60)
        // Down minutes counted from the checks: 03:12–03:25.
        XCTAssertEqual(r.totals.downtimeSeconds, 13 * 60)

        let appRow = r.servers[0]
        XCTAssertEqual(appRow.cpuMax, 88)
        XCTAssertEqual(appRow.reboots, 1)
        // 10 failed polls of 2 880.
        XCTAssertEqual(Fmt.percent(appRow.uptime), "99,65 %")

        // The disk forecast of the client's server, not the hosting payment, not another server.
        XCTAssertEqual(r.attention.map(\.title), ["Продлить домен shop.example.com", "Место на диске app.example.com"])
        XCTAssertTrue(r.prevented.isEmpty)
    }

    func testSiteDayDownNeedsEveryCountry() {
        let d = LocalReport.siteDay(UUID(), "2026-09-23", source().siteSamples["shop"]!.filter { $0.time < at("2026-09-24 00:00") })
        XCTAssertEqual(d.downtimeSeconds, 14 * 60)
        XCTAssertEqual(d.checksTotal, 120)
        XCTAssertEqual(d.checksOK, 92)
    }
}
