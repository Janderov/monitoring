import Foundation
import HTTPTypes
import HubCore
import HubWeb
import Hummingbird
import HummingbirdTesting
import Logging
import MonitorReports
import PostgresNIO
import XCTest

/// Client report links on the hub's one web server, against a real
/// PostgreSQL when HUB_TEST_PG=1. Uses its own database, monitor_reports_test,
/// which is wiped, and MonitorReports' SQL check seed.
final class ReportLinkTests: XCTestCase {
    var env: [String: String] { ProcessInfo.processInfo.environment }

    func testReportLinksOnTheWebServer() async throws {
        guard env["HUB_TEST_PG"] == "1" else { throw XCTSkip("HUB_TEST_PG=1 not set") }
        do { try await everything() } catch { XCTFail(HubError.describe(error)) }
    }

    func everything() async throws {
        var logger = Logger(label: "test")
        logger.logLevel = .warning
        var config = try HubConfig.fromEnvironment(env)
        config.pdfURL = nil
        let admin = Database(config, logger: logger)
        let adminRunner = Task { await admin.run() }
        try await admin.query("DROP DATABASE IF EXISTS monitor_reports_test WITH (FORCE)")
        try await admin.query("CREATE DATABASE monitor_reports_test")
        adminRunner.cancel()
        config.dbName = "monitor_reports_test"

        let db = Database(config, logger: logger)
        let runner = Task { await db.run() }
        defer { runner.cancel() }
        if let version = try await db.scalar("SELECT current_setting('server_version_num')::int", as: Int32.self), version < 180000 {
            try await db.query("CREATE FUNCTION public.uuidv7() RETURNS uuid LANGUAGE sql AS 'SELECT gen_random_uuid()'")
        }
        try await Migrator.migrate(db, dir: config.migrationsDir)
        let seed = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../app/Tests/sql/reports-seed.sql")
        for statement in SQLScript.statements(try String(contentsOf: seed, encoding: .utf8)) {
            try await db.query(PostgresQuery(unsafeSQL: statement))
        }

        // September's draft, then sent: a link.
        let store = PostgresReportStore(db: db)
        let f = ISO8601DateFormatter()
        let made = try await ReportJob.run(store: store, now: f.date(from: "2026-10-02T04:00:00Z")!)
        XCTAssertEqual(made.count, 1)
        let draft = try await store.drafts()
        XCTAssertEqual(draft.count, 1)
        let sent = try await store.send(made[0].reportID, by: nil)
        let token = try XCTUnwrap(sent)

        let web = WebConfig(webDir: URL(fileURLWithPath: "/nonexistent"))
        let deps = try WebDeps(config: config, web: web, db: db, logger: logger)
        let router = WebServer(config: config, web: web, modules: [ReportsWebModule()], logger: logger).router(deps: deps)
        try await Application(router: router).test(.router) { client in
            let page = try await client.execute(uri: "/r/\(token.value)", method: .get) { $0 }
            XCTAssertEqual(page.status, .ok)
            XCTAssertTrue(String(buffer: page.body).contains("ООО «Пример»"))
            XCTAssertEqual(page.headers[.contentType], "text/html; charset=utf-8")
            // The report's own, stricter policy survives the server's default.
            XCTAssertTrue(page.headers[HTTPField.Name("Content-Security-Policy")!]?.hasPrefix("default-src 'none'") == true)
            XCTAssertEqual(page.headers[HTTPField.Name("Referrer-Policy")!], "no-referrer")
            // No Gotenberg configured: no PDF link, and the PDF address is just «not found».
            XCTAssertFalse(String(buffer: page.body).contains("/pdf"))
            let pdf = try await client.execute(uri: "/r/\(token.value)/pdf", method: .get) { $0 }
            XCTAssertEqual(pdf.status, .notFound)
            let unknown = try await client.execute(uri: "/r/AAAAAAAAAAAAAAAAAAAAAA", method: .get) { $0 }
            XCTAssertEqual(unknown.status, .notFound)
            XCTAssertTrue(String(buffer: unknown.body).contains("Ссылка не действует"))
        }
    }
}
