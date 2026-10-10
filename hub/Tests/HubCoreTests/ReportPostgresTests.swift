import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Logging
import MonitorReports
import NIOHTTP1
import PostgresNIO
import XCTest
@testable import HubCore

/// Monthly reports on a real PostgreSQL (HUB_TEST_PG=1, as PostgresTests; the
/// database is wiped). The sample rows are MonitorReports' SQL check seed:
/// one client with a site, a moved site, a server, a month of day totals,
/// incidents, forecasts and backups. With HUB_TEST_PDF=http://host:3000 the
/// PDF is printed by a real Gotenberg.
final class ReportPostgresTests: XCTestCase {
    var env: [String: String] { ProcessInfo.processInfo.environment }
    let client = UUID(uuidString: "00000000-0000-0000-0000-00000000c001")!
    let shop = UUID(uuidString: "00000000-0000-0000-0000-0000000000d1")!
    let moscow = TimeZone(identifier: "Europe/Moscow")!

    func testReportsOnARealDatabase() async throws {
        guard env["HUB_TEST_PG"] == "1" else { throw XCTSkip("HUB_TEST_PG=1 not set") }
        do { try await everything() } catch { XCTFail(HubError.describe(error)) }
    }

    static func fresh(_ db: Database, config: HubConfig) async throws {
        for s in ["sys", "acc", "inv", "mon", "ops", "ntf", "rep"] {
            try await db.query(PostgresQuery(unsafeSQL: "DROP SCHEMA IF EXISTS \(s) CASCADE"))
        }
        try await db.query("DROP TABLE IF EXISTS public.schema_migrations")
        try await db.query("DROP FUNCTION IF EXISTS public.uuidv7()")
        if let version = try await db.scalar("SELECT current_setting('server_version_num')::int", as: Int32.self), version < 180000 {
            try await db.query("CREATE FUNCTION public.uuidv7() RETURNS uuid LANGUAGE sql AS 'SELECT gen_random_uuid()'")
        }
        _ = try await Migrator.migrate(db, dir: config.migrationsDir)
        _ = try await Partitions.ensure(db, now: Date())
    }

    func at(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = moscow
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    func everything() async throws {
        var logger = Logger(label: "test")
        logger.logLevel = .warning
        let config = try HubConfig.fromEnvironment(env)
        let db = Database(config, logger: logger)
        let runner = Task { await db.run() }
        defer { runner.cancel() }
        try await Self.fresh(db, config: config)

        let seed = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../app/Tests/sql/reports-seed.sql")
        for statement in SQLScript.statements(try String(contentsOf: seed, encoding: .utf8)) {
            try await db.query(PostgresQuery(unsafeSQL: statement))
        }

        // Day totals from raw checks: two points; ten minutes both fail (down),
        // ten more only one fails (blocked somewhere, not down).
        let now = Date()
        let hour = Date(timeIntervalSince1970: (now.addingTimeInterval(-86_400).timeIntervalSince1970 / 3600).rounded(.down) * 3600)
        try await db.query("INSERT INTO inv.probe (id, kind, name) VALUES (\(UUID()), 'hub', 'Хаб'), (\(UUID()), 'mac', 'Mac')")
        try await db.query("""
            INSERT INTO mon.site_check (site_id, probe_id, ts, ok, latency_ms)
            SELECT \(shop), p.id, \(hour)::timestamptz + make_interval(mins => m), m >= 10 AND (m >= 20 OR p.kind = 'hub'), 300
            FROM inv.probe p, generate_series(0, 29) m
            """)
        try await PostgresPollStore(db: db).rollup(since: hour, now: now)
        let rows = try await DailyRollup.run(db)
        XCTAssertEqual(rows["site_daily"], 1)
        let day = ReportPeriod.day(hour, moscow)
        for try await (total, ok, down) in try await db.query("""
            SELECT checks_total, checks_ok, downtime_s FROM mon.site_daily WHERE site_id = \(shop) AND day = \(SQLDay(day))
            """).decode((Int, Int, Int).self) {
            XCTAssertEqual(total, 60)
            XCTAssertEqual(ok, 30)
            XCTAssertEqual(down, 600)
        }
        // Running again changes nothing.
        try await DailyRollup.run(db)
        let count = try await db.scalar("SELECT count(*) FROM mon.site_daily WHERE site_id = \(shop) AND day >= '2026-10-03'", as: Int64.self)
        XCTAssertEqual(count, 1)

        // The job: the 2nd of October makes September's draft for the client,
        // not for your own infrastructure; once only.
        let store = PostgresReportStore(db: db)
        let made = try await ReportJob.run(store: store, now: at("2026-10-02 07:00"))
        XCTAssertEqual(made.map(\.clientName), ["ООО «Пример»"])
        XCTAssertEqual(made.first?.status, .issues)
        let again = try await ReportJob.run(store: store, now: at("2026-10-02 08:00"))
        XCTAssertEqual(again, [])
        let id = made[0].reportID
        let drafts = try await store.drafts()
        XCTAssertEqual(drafts.map(\.id), [id])
        XCTAssertEqual(drafts.first?.periodStart, "2026-09-01")

        let stored = try await store.report(id)
        let r = try XCTUnwrap(stored?.report)
        XCTAssertEqual(r.signature, "Михаил Дмитраков")
        XCTAssertEqual(r.periodStart, "2026-09-01")
        XCTAssertEqual(r.totals.slaTarget, 0.999)
        XCTAssertEqual(r.sites.map(\.name), ["moved.example.com", "shop.example.com"])
        XCTAssertEqual(r.servers.map(\.name), ["app.example.com"])
        XCTAssertEqual(r.incidents.map(\.object), ["shop.example.com"])
        XCTAssertEqual(r.prevented.count, 1)
        XCTAssertEqual(r.work.map(\.text), ["Очищены журналы"])
        XCTAssertEqual(r.backups.first?.missedDays, [])
        // The moved site's domain is not the client's to renew any more.
        XCTAssertEqual(r.attention.map(\.title), ["Продлить домен shop.example.com"])

        // A draft never opens by a link, even one made by hand.
        try await store.setComment(id, "Спокойный месяц")
        let early = ReportToken.make()
        try await store.db.query(try .sql(ReportSQL.insertLink, ["report", id, nil, Data(early.hash), nil, Int32(30)]))
        let hidden = try await store.open(early)
        XCTAssertNil(hidden)

        // Approve and send: a link for the client.
        let sent = try await store.send(id, by: nil)
        let token = try XCTUnwrap(sent)
        let twice = try await store.send(id, by: nil)
        XCTAssertNil(twice)
        let maybeOpened = try await store.open(token)
        let opened = try XCTUnwrap(maybeOpened)
        XCTAssertEqual(opened.id, id)
        XCTAssertEqual(opened.comment, "Спокойный месяц")
        XCTAssertEqual(opened.report, r)
        let visits = try await db.scalar("SELECT open_count::int8 FROM rep.report_link WHERE token_hash = \(ByteBuffer(bytes: token.hash))", as: Int64.self)
        XCTAssertEqual(visits, 1)
        // The CLI refuses to replace what the client already sees.
        do {
            _ = try await ReportCommand.run(["make", "ООО «Пример»", "2026-09"], db: db, config: config)
            XCTFail("a sent report must not be replaced")
        } catch {}

        // The page and the PDF, cached on disk after the first print.
        let files = FileManager.default.temporaryDirectory.appendingPathComponent("hub-files-\(UUID())")
        defer { try? FileManager.default.removeItem(at: files) }
        let printed = Counter()
        let render: ReportPDF.Render
        if let url = env["HUB_TEST_PDF"].flatMap(URL.init(string:)) {
            let real = ReportPDF.gotenberg(url)
            render = { html in await printed.add(); return try await real(html) }
        } else {
            render = { _ in await printed.add(); return Data("%PDF-1.4 test".utf8) }
        }
        let pdf = ReportPDF(store: store, filesDir: files, render: render)
        let web = ReportWeb(open: { try await store.open($0) }, pdf: { try await pdf.pdf($0) }, logger: logger)
        let page = await web.respond(method: .GET, uri: "/r/\(token.value)")
        XCTAssertEqual(page.status, .ok)
        let html = String(decoding: page.body, as: UTF8.self)
        XCTAssertTrue(html.contains("ООО «Пример»"))
        XCTAssertTrue(html.contains("Спокойный месяц"))
        XCTAssertTrue(html.contains("/r/\(token.value)/pdf"))
        let file = await web.respond(method: .GET, uri: "/r/\(token.value)/pdf")
        XCTAssertEqual(file.status, .ok)
        XCTAssertTrue(file.body.starts(with: Data("%PDF".utf8)))
        let cached = await web.respond(method: .GET, uri: "/r/\(token.value)/pdf")
        XCTAssertEqual(cached.body, file.body)
        let renders = await printed.value
        XCTAssertEqual(renders, 1)
        let kept = try await db.scalar("SELECT count(*) FROM sys.file f JOIN rep.client_report r ON r.pdf_file_id = f.id", as: Int64.self)
        XCTAssertEqual(kept, 1)
        if env["HUB_TEST_PDF"] != nil {
            try file.body.write(to: URL(fileURLWithPath: env["HUB_TEST_PDF_OUT"] ?? "/tmp/report-test.pdf"))
        }

        // A permanent client link opens the newest sent report.
        let permanent = try await store.clientLink(client, by: nil)
        let newest = try await store.open(permanent)
        XCTAssertEqual(newest?.id, id)

        // Revoked: the same page as an unknown link.
        let revoked = try await store.revoke(token, by: nil)
        XCTAssertTrue(revoked)
        let gone = await web.respond(method: .GET, uri: "/r/\(token.value)")
        XCTAssertEqual(gone.status, .notFound)

        // The owner hears about new drafts in Telegram once per hour.
        let owner = UUID()
        try await db.query("INSERT INTO acc.account (id, login, display_name, kind, status) VALUES (\(owner), 'owner', 'Владелец', 'owner', 'active')")
        try await db.query("INSERT INTO ntf.telegram_link (account_id, chat_id) VALUES (\(owner), 1001)")
        let queued = try await store.queueNotice("Отчёты за сентябрь готовы: 1.", now: now)
        XCTAssertEqual(queued, 1)
        let repeated = try await store.queueNotice("Отчёты за сентябрь готовы: 1.", now: now)
        XCTAssertEqual(repeated, 0)
        let text = try await db.scalar("SELECT payload#>>'{message,text}' FROM ntf.delivery WHERE kind = 'report'", as: String.self)
        XCTAssertEqual(text, "Отчёты за сентябрь готовы: 1.")

        // The command line.
        let sig = try await ReportCommand.run(["signature"], db: db, config: config)
        XCTAssertEqual(sig, "подпись: «Михаил Дмитраков»")
        let remade = try await ReportCommand.run(["make", "ООО «Пример»", "2026-08"], db: db, config: config)
        XCTAssertTrue(remade.contains("2026-08"), remade)
        let list = try await ReportCommand.run(["drafts"], db: db, config: config)
        XCTAssertTrue(list.contains("2026-08") && list.contains("ООО «Пример»"), list)
    }
}

actor Counter {
    var value = 0
    func add() { value += 1 }
}

