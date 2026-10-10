import Foundation
import XCTest
@testable import MonitorReports

let msk = TimeZone(identifier: "Europe/Moscow")!

/// "2026-09-23 03:12" in Moscow.
func at(_ s: String) -> Date {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = msk
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.date(from: s)!
}

let shop = UUID(), main = UUID(), app = UUID(), db = UUID()
let september = ReportPeriod.month(containing: at("2026-09-15 12:00"), timeZone: msk)
let generated = at("2026-10-01 06:00")

/// The sample report Mihail saw, as rows.
func sampleInput() -> ReportInput {
    var siteDays: [ReportInput.SiteDay] = []
    var serverDays: [ReportInput.ServerDay] = []
    var diskDays: [ReportInput.DiskDay] = []
    for (i, d) in september.days.enumerated() {
        siteDays.append(.init(siteID: main, day: d, checksTotal: 4320, checksOK: d == "2026-09-17" ? 4300 : 4320, latencyAvgMs: 310))
        siteDays.append(.init(siteID: shop, day: d, checksTotal: 4320, checksOK: d == "2026-09-23" ? 4306 : 4320,
                              downtimeSeconds: d == "2026-09-23" ? 840 : 0, latencyAvgMs: 580))
        serverDays.append(.init(serverID: app, day: d, cpuMax: 64, memMax: 71, diskMaxPct: 58, reboots: d == "2026-09-06" ? 1 : 0,
                                checksTotal: 1440, checksOK: 1440))
        serverDays.append(.init(serverID: db, day: d, cpuMax: 41, memMax: 62, diskMaxPct: 76, checksTotal: 1440, checksOK: 1440))
        // app's disk grows 1.3 %/day until the cleanup on the 11th.
        let pct = i < 10 ? 78 + Double(i) * 1.3 : 55 + Double(i - 10) * 0.16
        diskDays.append(.init(serverID: app, mount: "/", day: d, usedBytes: Int64(pct * 1_000_000), totalBytes: 100_000_000))
        // db grows 0.4 %/day: about two months left at the end of September.
        diskDays.append(.init(serverID: db, mount: "/", day: d, usedBytes: Int64((64 + Double(i) * 0.4) * 1_000_000), totalBytes: 100_000_000))
    }
    var backups: [ReportInput.BackupRun] = []
    for d in 1...30 {
        backups.append(.init(serverName: "db.example.com", target: "Магазин", startedAt: at(String(format: "2026-09-%02d 02:00", d)),
                             ok: true, sizeBytes: 1_900_000_000))
        backups.append(.init(serverName: "db.example.com", target: "CRM", startedAt: at(String(format: "2026-09-%02d 02:10", d)),
                             ok: d != 14, sizeBytes: 250_000_000))
    }
    return ReportInput(
        clientName: "ООО «Пример»", signature: "Михаил Дмитраков", footer: "Связь: Telegram или почта из договора",
        period: september, slaTarget: 0.999,
        sites: [.init(id: main, name: "example.com", note: "основной", tlsExpiry: at("2026-12-11 00:00"), domainExpiry: at("2026-11-16 12:00")),
                .init(id: shop, name: "shop.example.com", note: "магазин", tlsExpiry: at("2026-12-19 12:00"), domainExpiry: at("2026-11-16 12:00"))],
        siteDays: siteDays,
        servers: [.init(id: app, name: "app.example.com", note: "сайты"), .init(id: db, name: "db.example.com", note: "база")],
        serverDays: serverDays, diskDays: diskDays,
        incidents: [.init(objectName: "shop.example.com", kind: "down", severity: 2, message: "Не открывался",
                          startedAt: at("2026-09-23 03:12"), endedAt: at("2026-09-23 03:26"),
                          cause: "Ночное обновление каталога заняло всю память.", resolution: "Запуск перенесён на 05:00.")],
        forecasts: [
            .init(objectName: "app.example.com", objectID: app, kind: "disk_full", line: "Журналы росли на 2,1 ГБ в сутки",
                  dueAt: at("2026-09-18 12:00"), firstSeenAt: at("2026-09-04 10:00"), status: "prevented",
                  closedAt: at("2026-09-11 15:00"), note: "удалены старые журналы, +18 ГБ"),
            .init(objectName: "shop.example.com", kind: "tls_expiry", line: "Автопродление сломалось",
                  dueAt: at("2026-09-29 00:00"), firstSeenAt: at("2026-09-15 09:00"), status: "prevented",
                  closedAt: at("2026-09-20 11:00"), note: "исправлено автопродление"),
            // Prevented last month: not this report's.
            .init(objectName: "app.example.com", kind: "tls_expiry", line: "старое", dueAt: nil, firstSeenAt: at("2026-08-01 09:00"),
                  status: "prevented", closedAt: at("2026-08-20 11:00")),
            .init(objectName: "example.com", kind: "domain_expiry", line: "Домен истекает 16 ноября",
                  dueAt: at("2026-11-16 12:00"), firstSeenAt: at("2026-09-17 09:00"), status: "open"),
            // Too far ahead for «скоро».
            .init(objectName: "mail.example.com", kind: "disk_full", line: "далеко", dueAt: at("2027-06-01 00:00"),
                  firstSeenAt: at("2026-09-01 00:00"), status: "open"),
        ],
        backups: backups,
        work: [.init(doneAt: at("2026-09-11 15:00"), text: "Очищены старые журналы, включена ротация."),
               .init(doneAt: at("2026-09-06 03:00"), text: "Обновления безопасности на всех серверах.")])
}

final class ReportPeriodTests: XCTestCase {
    func testPreviousMonthInClientZone() {
        // 1 October 06:00 in Moscow is still 30 September in UTC... no: 03:00 UTC on the 1st.
        let p = ReportPeriod.previousMonth(before: generated, timeZone: msk)
        XCTAssertEqual(p.start, "2026-09-01")
        XCTAssertEqual(p.end, "2026-09-30")
        XCTAssertEqual(p.days.count, 30)
        XCTAssertEqual(p.from, at("2026-09-01 00:00"))
        XCTAssertEqual(p.to, at("2026-10-01 00:00"))
        XCTAssertEqual(p.dueAt(dayOfMonth: 1), at("2026-10-01 06:00"))
        XCTAssertEqual(p.dueAt(dayOfMonth: 5), at("2026-10-05 06:00"))
        XCTAssertEqual(p.dayIndex(at("2026-09-11 15:00")), 10)
        XCTAssertNil(p.dayIndex(at("2026-10-01 00:00")))
    }

    func testFebruaryAndYearTurn() {
        let feb = ReportPeriod.previousMonth(before: at("2027-03-02 10:00"), timeZone: msk)
        XCTAssertEqual(feb.end, "2027-02-28")
        let dec = ReportPeriod.previousMonth(before: at("2027-01-01 10:00"), timeZone: msk)
        XCTAssertEqual([dec.start, dec.end], ["2026-12-01", "2026-12-31"])
    }
}

final class ReportBuilderTests: XCTestCase {
    let r = ReportBuilder.build(sampleInput(), now: generated)

    func testTotalsAndHeadline() {
        XCTAssertEqual(r.totals.incidents, 1)
        XCTAssertEqual(r.totals.downtimeSeconds, 14 * 60)
        XCTAssertEqual(r.totals.prevented, 2)
        XCTAssertEqual(r.totals.serverUptime, 1)
        // 34 failed checks of 259 200, rounded down.
        XCTAssertEqual(Fmt.percent(r.totals.siteUptime), "99,98 %")
        // A short outage within the SLA, and a missed backup: «issues», not «critical».
        XCTAssertEqual(r.status, .issues)
        XCTAssertEqual(r.headline, "Сбоев: 1, простой 14 мин. Предотвращено проблем: 2.")
        XCTAssertEqual(r.detail, "shop.example.com: не открывался.")
    }

    func testSitesMarkEveryDay() {
        let shopRow = r.sites.first { $0.name == "shop.example.com" }!
        XCTAssertEqual(shopRow.days.count, 30)
        XCTAssertEqual(shopRow.days[22], .down)
        XCTAssertEqual(shopRow.days.filter { $0 == .ok }.count, 29)
        let mainRow = r.sites.first { $0.name == "example.com" }!
        XCTAssertEqual(mainRow.days[16], .errors)
        XCTAssertEqual(mainRow.domainDays, 46)
        XCTAssertEqual(mainRow.latencyMs, 310)
    }

    func testServersAndRunway() {
        let dbRow = r.servers.first { $0.name == "db.example.com" }!
        XCTAssertEqual(dbRow.diskMax, 76)
        // 75.6 % at 0.4 %/day: about two months.
        XCTAssertEqual(dbRow.diskRunwayDays, 61)
        XCTAssertEqual(Fmt.runway(dbRow.diskRunwayDays), "~2 мес.")
        let appRow = r.servers.first { $0.name == "app.example.com" }!
        XCTAssertEqual(appRow.reboots, 1)
        // After the cleanup it grows 0.16 %/day from 58 %.
        XCTAssertEqual(Fmt.runway(appRow.diskRunwayDays), "~9 мес.")
    }

    func testPreventedOnlyThisMonthWithChart() {
        XCTAssertEqual(r.prevented.map(\.title), ["Диск app.example.com заполнился бы", "SSL-сертификат shop.example.com истёк бы"])
        XCTAssertEqual(r.prevented[0].fix, "удалены старые журналы, +18 ГБ")
        XCTAssertEqual(r.diskCharts.count, 1)
        let c = r.diskCharts[0]
        XCTAssertEqual(c.fixDay, 10)
        XCTAssertEqual(c.percent.count, 30)
        XCTAssertEqual(c.wouldFillDay!, 17.5, accuracy: 0.01)
    }

    func testBackupsCountMissedDays() {
        let crm = r.backups.first { $0.target == "CRM" }!
        XCTAssertEqual(crm.good, 29)
        XCTAssertEqual(crm.expected, 30)
        XCTAssertEqual(crm.missedDays, ["2026-09-14"])
        XCTAssertTrue(r.backups.first { $0.target == "Магазин" }!.missedDays.isEmpty)
    }

    func testAttentionSoonestFirstWithoutDuplicates() {
        // The open domain forecast covers example.com; shop.example.com's domain comes from the expiry date.
        XCTAssertEqual(r.attention.map(\.title), ["Продлить домен example.com", "Продлить домен shop.example.com"])
        XCTAssertTrue(r.attention.allSatisfy(\.needsClient))
    }

    func testWorkSortedByDate() {
        XCTAssertEqual(r.work.map(\.day), ["2026-09-06", "2026-09-11"])
    }

    func testCleanMonth() {
        var input = sampleInput()
        input.incidents = []
        input.forecasts = []
        input.backups = input.backups.map { var b = $0; b.ok = true; return b }
        input.siteDays = input.siteDays.map { var d = $0; d.checksOK = d.checksTotal; d.downtimeSeconds = 0; return d }
        let clean = ReportBuilder.build(input, now: generated)
        XCTAssertEqual(clean.status, .ok)
        XCTAssertEqual(clean.headline, "Всё работало без сбоев.")
        XCTAssertNil(clean.detail)
    }

    func testOngoingOutageIsCriticalAndClippedToPeriod() {
        var input = sampleInput()
        input.incidents = [.init(objectName: "example.com", kind: "down", severity: 2, message: "Не отвечает",
                                 startedAt: at("2026-08-31 23:00"), endedAt: nil)]
        let bad = ReportBuilder.build(input, now: generated)
        XCTAssertEqual(bad.status, .critical)
        XCTAssertTrue(bad.incidents[0].ongoing)
        XCTAssertEqual(bad.totals.downtimeSeconds, 30 * 86400)
    }

    func testSnapshotRoundTrips() throws {
        XCTAssertEqual(try ReportJob.decode(ReportJob.encode(r)), r)
    }
}

final class ReportPageTests: XCTestCase {
    let r = ReportBuilder.build(sampleInput(), now: generated)

    func testWebPageHasEverySection() {
        let html = ReportPage.html(r, comment: "Спокойный месяц.", mode: .web(pdfURL: "/r/x/pdf"), timeZone: msk)
        for text in ["ООО «Пример»", "сентябрь 2026", "Предотвращено", "Диск app.example.com заполнился бы около 18 сент.",
                     "99,98 %", "цель 99,9 % выполнена", "Резервные копии", "1 пропуск: 14 сент.", "Работы за месяц",
                     "06.09", "Скоро потребует внимания", "нужно ваше решение", "От администратора", "Спокойный месяц.",
                     "Михаил Дмитраков", "Скачать PDF", "prefers-color-scheme: dark", "<svg", "noindex"] {
            XCTAssertTrue(html.contains(text), "missing \(text)")
        }
        XCTAssertFalse(html.contains("<script"))
    }

    func testPDFIsAlwaysLight() {
        let html = ReportPage.html(r, mode: .pdf, timeZone: msk)
        XCTAssertFalse(html.contains("prefers-color-scheme"))
        XCTAssertTrue(html.contains("@page{size:A4"))
        XCTAssertFalse(html.contains("Скачать PDF"))
        XCTAssertFalse(html.contains("От администратора"))
    }

    func testEverythingIsEscaped() {
        var input = sampleInput()
        input.clientName = "<script>alert(1)</script>"
        input.work = [.init(doneAt: at("2026-09-02 10:00"), text: "a & \"b\" <img src=x>")]
        let html = ReportPage.html(ReportBuilder.build(input, now: generated), comment: "<b>hi</b>\nnext", mode: .pdf, timeZone: msk)
        XCTAssertFalse(html.contains("<script>alert"))
        XCTAssertFalse(html.contains("<img src=x>"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("a &amp; &quot;b&quot;"))
        XCTAssertTrue(html.contains("&lt;b&gt;hi&lt;/b&gt;<br>next"))
    }

    func testSectionsCanBeTurnedOff() {
        let sections = ReportJob.sections(["backups": false, "work_done": false, "uptime": true])
        let html = ReportPage.html(r, mode: .pdf, timeZone: msk, sections: sections)
        XCTAssertFalse(html.contains("Резервные копии"))
        XCTAssertFalse(html.contains("Работы за месяц"))
        XCTAssertTrue(html.contains("Сайты"))
    }

    func testNoIncidentsSaysSo() {
        var input = sampleInput()
        input.incidents = []
        let html = ReportPage.html(ReportBuilder.build(input, now: generated), mode: .pdf, timeZone: msk)
        XCTAssertTrue(html.contains("Сбоев не было"))
    }
}

final class ReportFormatTests: XCTestCase {
    func testPercentNeverRoundsUpToFull() {
        XCTAssertEqual(Fmt.percent(1), "100 %")
        XCTAssertEqual(Fmt.percent(0.99999), "99,99 %")
        XCTAssertEqual(Fmt.percent(0.999), "99,9 %")
        XCTAssertEqual(Fmt.percent(0.95), "95 %")
        XCTAssertEqual(Fmt.percent(nil), "нет данных")
    }

    func testDurationsAndSizes() {
        XCTAssertEqual(Fmt.duration(840), "14 мин")
        XCTAssertEqual(Fmt.duration(3900), "1 ч 5 мин")
        XCTAssertEqual(Fmt.duration(2 * 86400 + 3 * 3600), "2 дн 3 ч")
        XCTAssertEqual(Fmt.bytes(1_900_000_000), "1,8 ГБ")
        XCTAssertEqual(Fmt.bytes(250_000_000), "238 МБ")
        XCTAssertEqual(ReportPage.plural(1, "сайт", "сайта", "сайтов"), "сайт")
        XCTAssertEqual(ReportPage.plural(3, "сайт", "сайта", "сайтов"), "сайта")
        XCTAssertEqual(ReportPage.plural(11, "сайт", "сайта", "сайтов"), "сайтов")
    }
}

final class ReportTokenTests: XCTestCase {
    func testTokensAreRandomAndHashed() {
        let a = ReportToken.make(), b = ReportToken.make()
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.value.count, 22)
        XCTAssertEqual(ReportToken.parse(a.value), a)
        XCTAssertEqual(a.hash.count, 32)
        XCTAssertNotEqual(a.hash, b.hash)
        XCTAssertEqual(a.url(base: "https://hub.example.com/"), "https://hub.example.com/r/" + a.value)
    }

    func testParseRejectsAnythingElse() {
        XCTAssertNil(ReportToken.parse("short"))
        XCTAssertNil(ReportToken.parse("../../../../etc/passwd!!"))
        XCTAssertNil(ReportToken.parse(String(repeating: "я", count: 22)))
    }
}

final class ReportJobTests: XCTestCase {
    actor FakeStore: ReportStore {
        var due: [DueClient]
        var saved: [(UUID, String)] = []
        init(due: [DueClient]) { self.due = due }
        func dueClients(monthStart: String) async throws -> [DueClient] { due }
        func input(clientID: UUID, period: ReportPeriod) async throws -> ReportInput? {
            var i = sampleInput()
            i.period = period
            return i
        }
        func saveDraft(clientID: UUID, period: ReportPeriod, report: ClientReport, generatedBy: UUID?) async throws -> UUID {
            saved.append((clientID, period.start))
            return UUID()
        }
    }

    func testMakesDraftsOnlyWhenTheClientsDayHasCome() async throws {
        let now = at("2026-10-03 07:00")
        let early = DueClient(id: UUID(), timeZone: msk, dayOfMonth: 1)
        let later = DueClient(id: UUID(), timeZone: msk, dayOfMonth: 5)
        let store = FakeStore(due: [early, later])
        let made = try await ReportJob.run(store: store, now: now)
        XCTAssertEqual(made.count, 1)
        let saved = await store.saved
        XCTAssertEqual(saved.map(\.0), [early.id])
        XCTAssertEqual(saved.map(\.1), ["2026-09-01"])
        XCTAssertEqual(ReportJob.notice(made, period: september), "Отчёты за сентябрь готовы: 1. Проверьте и отправьте; сбои были у 1.")
    }
}

final class ReportPreviewTests: XCTestCase {
    /// `REPORT_PREVIEW=/path/dir swift test --filter ReportPreview` writes the
    /// sample as web and PDF pages, to look at them in a browser.
    func testWritePreview() throws {
        guard let dir = ProcessInfo.processInfo.environment["REPORT_PREVIEW"] else { return }
        let r = ReportBuilder.build(sampleInput(), now: generated)
        let comment = "Спокойный месяц. Главное на октябрь: решить с доменом до конца ноября."
        try ReportPage.html(r, comment: comment, mode: .web(pdfURL: "#"), timeZone: msk)
            .write(toFile: dir + "/report-web.html", atomically: true, encoding: .utf8)
        try ReportPage.html(r, comment: comment, mode: .pdf, timeZone: msk)
            .write(toFile: dir + "/report-pdf.html", atomically: true, encoding: .utf8)
    }
}
