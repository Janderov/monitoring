import Foundation
import Logging
import XCTest
@testable import HubCore

final class SQLScriptTests: XCTestCase {
    func testSplitsOnSemicolonsOutsideQuotesCommentsAndDollarBodies() {
        let sql = """
        -- a comment; with a semicolon
        CREATE TABLE a (x text DEFAULT 'a;b');
        /* block; comment /* nested; */ still */
        CREATE FUNCTION f() RETURNS int LANGUAGE plpgsql AS $$
        BEGIN
          RETURN 1; -- inside the body
        END $$;
        CREATE FUNCTION g() RETURNS text LANGUAGE sql AS $body$ SELECT 'x;y' $body$;
        SELECT $1, "we;ird"; -- positional parameter is not a dollar quote
        -- trailing comment only
        """
        let st = SQLScript.statements(sql)
        XCTAssertEqual(st.count, 4)
        XCTAssertTrue(st[0].hasSuffix("CREATE TABLE a (x text DEFAULT 'a;b');"))
        XCTAssertTrue(st[1].contains("RETURN 1; -- inside the body"))
        XCTAssertTrue(st[1].hasSuffix("END $$;"))
        XCTAssertTrue(st[2].contains("$body$ SELECT 'x;y' $body$"))
        XCTAssertTrue(st[3].hasPrefix("SELECT $1, \"we;ird\";"))
    }

    func testDoubledQuotes() {
        let st = SQLScript.statements("SELECT 'it''s; fine'; SELECT 2;")
        XCTAssertEqual(st, ["SELECT 'it''s; fine';", "SELECT 2;"])
    }
}

final class SecretBoxTests: XCTestCase {
    let key = Data(repeating: 7, count: 32)

    func testRoundTrip() throws {
        let box = try SecretBox(key: key)
        let id = UUID()
        let sealed = try box.seal("token-123", id: id, kind: "agent_token")
        XCTAssertEqual(sealed.nonce.count, 12)
        XCTAssertFalse(String(decoding: sealed.ciphertext, as: UTF8.self).contains("token-123"))
        XCTAssertEqual(try box.open(sealed, id: id, kind: "agent_token"), "token-123")
    }

    func testSealedValueIsBoundToItsRow() throws {
        let box = try SecretBox(key: key)
        let id = UUID()
        let sealed = try box.seal("secret", id: id, kind: "agent_token")
        XCTAssertThrowsError(try box.open(sealed, id: UUID(), kind: "agent_token"))
        XCTAssertThrowsError(try box.open(sealed, id: id, kind: "site_password"))
        XCTAssertThrowsError(try SecretBox(key: Data(repeating: 8, count: 32)).open(sealed, id: id, kind: "agent_token"))
    }

    func testRejectsShortKey() {
        XCTAssertThrowsError(try SecretBox(key: Data(repeating: 1, count: 16)))
    }
}

final class PartitionsTests: XCTestCase {
    let t = ISO8601DateFormatter().date(from: "2026-10-10T23:30:00Z")!

    func testNamesAndBounds() {
        let day = Partitions.start(of: t, step: .day)
        XCTAssertEqual(Partitions.partitionName("mon.server_sample", start: day, step: .day), "mon.server_sample_20261010")
        XCTAssertEqual(Partitions.next(day, step: .day), ISO8601DateFormatter().date(from: "2026-10-11T00:00:00Z"))
        let month = Partitions.start(of: t, step: .month)
        XCTAssertEqual(Partitions.partitionName("ops.event", start: month, step: .month), "ops.event_202610")
    }

    func testStartsCoverRange() {
        let s = Partitions.starts(from: t.addingTimeInterval(-2 * 86_400), to: t.addingTimeInterval(7 * 86_400), step: .day)
        XCTAssertEqual(s.count, 10)
        XCTAssertEqual(Partitions.starts(from: t, to: t.addingTimeInterval(40 * 86_400), step: .month).count, 2)
    }
}

final class ConfigTests: XCTestCase {
    func testReadsCredentialsFromFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("creds-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 3, count: 32).base64EncodedString().write(to: dir.appendingPathComponent("secret-key"),
                                                                      atomically: true, encoding: .utf8)
        try "https://hc-ping.com/abc\n".write(to: dir.appendingPathComponent("heartbeat-url"), atomically: true, encoding: .utf8)
        let c = try HubConfig.fromEnvironment(["CREDENTIALS_DIRECTORY": dir.path, "PGHOST": "db"])
        XCTAssertEqual(c.secretKey?.count, 32)
        XCTAssertEqual(c.heartbeatURL?.absoluteString, "https://hc-ping.com/abc")
        XCTAssertEqual(c.dbHost, "db")
        XCTAssertFalse(c.dbTLS)
    }

    func testRejectsBadKey() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("creds-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "short".write(to: dir.appendingPathComponent("secret-key"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try HubConfig.fromEnvironment(["CREDENTIALS_DIRECTORY": dir.path]))
    }

    func testObjectsFromAlertIDs() {
        let u = UUID()
        XCTAssertEqual(PostgresPollStore.object(u.uuidString.lowercased()).type, "server")
        XCTAssertEqual(PostgresPollStore.object("site:" + u.uuidString).id, u)
        XCTAssertEqual(PostgresPollStore.object("nl", servers: ["nl": u]).id, u)
        XCTAssertEqual(PostgresPollStore.object("site:shop", sites: ["shop": u]).type, "site")
        XCTAssertEqual(PostgresPollStore.object("away").type, "hub")
    }
}

final class ReportWebTests: XCTestCase {
    let web = ReportWeb(open: { _ in nil }, pdf: nil, logger: Logger(label: "test"))

    func testOnlyReportLinks() async {
        for uri in ["/", "/r/", "/r/short", "/r/AAAAAAAAAAAAAAAAAAAAAA", "/r/AAAAAAAAAAAAAAAAAAAAAA/pdf",
                    "/r/AAAAAAAAAAAAAAAAAAAAAA/x", "/r/../../etc/passwd", "/r/AAAAAAAAAAAAAAAAAAAA%2F"] {
            let r = await web.respond(method: .GET, uri: uri)
            XCTAssertEqual(r.status, .notFound, uri)
        }
        let post = await web.respond(method: .POST, uri: "/r/AAAAAAAAAAAAAAAAAAAAAA")
        XCTAssertEqual(post.status, .methodNotAllowed)
    }

    func testPDFKeyChangesWithThePage() {
        let id = UUID()
        XCTAssertEqual(ReportPDF.key(id, html: "a"), ReportPDF.key(id, html: "a"))
        XCTAssertNotEqual(ReportPDF.key(id, html: "a"), ReportPDF.key(id, html: "b"))
        XCTAssertTrue(ReportPDF.key(id, html: "a").hasPrefix("reports/\(id.uuidString.lowercased())-"))
    }
}
