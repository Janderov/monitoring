import Foundation
import XCTest
@testable import MonitorCore

final class SitesTests: XCTestCase {
    let now = AgentJSON.parseRFC3339("2026-10-05T10:00:00Z")!

    func testRegistrableDomain() {
        XCTAssertEqual(DomainName.registrable("www.biotech.ru"), "biotech.ru")
        XCTAssertEqual(DomainName.registrable("shop.example.com"), "example.com")
        XCTAssertEqual(DomainName.registrable("a.b.example.co.uk"), "example.co.uk")
        XCTAssertEqual(DomainName.registrable("my.firm.msk.ru"), "firm.msk.ru")
        XCTAssertNil(DomainName.registrable("155.212.164.127"))
        XCTAssertNil(DomainName.registrable("localhost"))
        XCTAssertNil(DomainName.registrable("пример.рф"))
        XCTAssertEqual(DomainName.whoisServer(for: "biotech.ru"), "whois.tcinet.ru")
        XCTAssertNil(DomainName.whoisServer(for: "example.com"))
    }

    func testParseRDAP() {
        let json = """
        {"objectClassName":"domain","ldhName":"EXAMPLE.COM","events":[
          {"eventAction":"registration","eventDate":"1995-08-14T04:00:00Z"},
          {"eventAction":"expiration","eventDate":"2027-08-13T04:00:00Z"}]}
        """
        XCTAssertEqual(DomainName.parseRDAP(Data(json.utf8)), AgentJSON.parseRFC3339("2027-08-13T04:00:00Z"))
        XCTAssertNil(DomainName.parseRDAP(Data("{}".utf8)))
    }

    func testParseWhois() {
        let tcinet = """
        % TCI Whois Service. Terms of use:
        domain:        BIOTECH.RU
        state:         REGISTERED, DELEGATED, VERIFIED
        created:       2004-01-01T10:00:00Z
        paid-till:     2026-10-15T21:00:00Z
        free-date:     2026-11-16
        """
        XCTAssertEqual(DomainName.parseWhois(tcinet), AgentJSON.parseRFC3339("2026-10-15T21:00:00Z"))
        let gtld = "   Registry Expiry Date: 2028-01-02T03:04:05Z\n"
        XCTAssertEqual(DomainName.parseWhois(gtld), AgentJSON.parseRFC3339("2028-01-02T03:04:05Z"))
        XCTAssertEqual(DomainName.parseWhois("expires: 2027-03-01\n"), AgentJSON.parseRFC3339("2027-03-01T00:00:00Z"))
        XCTAssertNil(DomainName.parseWhois("No entries found"))
    }

    func check(ok: Bool, tls: Date? = nil) -> Snapshot.Check {
        Snapshot.Check(id: "site-shop", kind: "http", target: "https://shop.example.com", ok: ok,
                       statusCode: ok ? 200 : 502, latencyMs: 80, tlsExpiry: tls, error: nil)
    }

    func status(_ checks: [Snapshot.Check?], domainExpiry: Date? = nil) -> SiteStatus {
        let site = SiteConfig(id: "shop", name: "Магазин", url: "https://shop.example.com")
        let origins = checks.enumerated().map { i, c in
            SiteStatus.Origin(serverID: "s\(i)", serverName: ["Россия", "Нидерланды", "США"][i], check: c)
        }
        return SiteStatus(site: site, origins: origins, domain: "example.com", domainExpiry: domainExpiry,
                          domainError: nil, alerts: [])
    }

    func testPasswordProtectedSiteIsUp() throws {
        // Older agents report 401/403 as a failure.
        let json = #"""
        [{"id":"site-a","kind":"http","target":"https://a.example.com","ok":false,"status_code":401,
          "latency_ms":120,"error":"401 Unauthorized"},
         {"id":"site-b","kind":"http","target":"https://b.example.com","ok":false,"status_code":502,
          "latency_ms":80,"error":"502 Bad Gateway"}]
        """#
        let checks = try AgentJSON.decoder.decode([Snapshot.Check].self, from: Data(json.utf8))
        XCTAssertTrue(checks[0].ok)
        XCTAssertNil(checks[0].error)
        XCTAssertEqual(checks[0].statusCode, 401)
        XCTAssertFalse(checks[1].ok)
        XCTAssertEqual(checks[1].error, "502 Bad Gateway")
    }

    func testSiteRules() {
        XCTAssertTrue(SiteRules.conditions(status([check(ok: true), check(ok: true)]), now: now).isEmpty)

        let all = SiteRules.conditions(status([check(ok: false), check(ok: false), nil]), now: now)
        XCTAssertEqual(all.map(\.key), ["down"])
        XCTAssertEqual(all.first?.severity, .critical)
        XCTAssertTrue(all[0].message.contains("HTTP 502"))

        let blocked = SiteRules.conditions(status([check(ok: false), check(ok: true)]), now: now)
        XCTAssertEqual(blocked.map(\.key), ["from:s0"])
        XCTAssertEqual(blocked.first?.severity, .warning)
        XCTAssertTrue(blocked[0].message.contains("Россия"))

        // No agent has reported yet: nothing to judge.
        XCTAssertTrue(SiteRules.conditions(status([nil, nil]), now: now).isEmpty)
        XCTAssertEqual(status([nil]).level, .unknown)

        let soon = now.addingTimeInterval(5 * 86400)
        let expiring = SiteRules.conditions(status([check(ok: true, tls: soon)], domainExpiry: soon), now: now)
        XCTAssertEqual(expiring.map(\.key), ["tls", "domain"])
        XCTAssertEqual(expiring.last?.after, 1)
        XCTAssertTrue(expiring.last!.message.contains("example.com"))
    }

    func testSitesInServersFile() throws {
        let token = String(repeating: "a", count: 64), fp = String(repeating: "00", count: 32)
        let json = """
        {"servers":[{"id":"nl","name":"NL","host":"h","port":9443,"token":"\(token)","fingerprint":"\(fp)"}],
         "sites":[{"id":"shop","name":"Магазин","url":"https://shop.example.com","from":["nl"],
                   "thresholds":{"domain_days":30}}]}
        """
        let file = try ServersFile.decode(Data(json.utf8))
        XCTAssertNoThrow(try file.validate())
        XCTAssertEqual(file.sites?.first?.thresholds?.resolved.domainDays, 30)
        XCTAssertEqual(file.sites?.first?.checkID, "site-shop")

        var bad = file
        bad.sites?[0].from = ["us"]
        XCTAssertThrowsError(try bad.validate())
        bad = file
        bad.sites?[0].url = "shop.example.com"
        XCTAssertThrowsError(try bad.validate())
    }

    func testServerRulesIgnoreManagedSiteChecks() {
        var snap = Fixtures.snapshot()
        snap.checks = [check(ok: false)]
        XCTAssertTrue(Rules.conditions(.snapshot(snap), thresholds: nil, now: now).isEmpty)
    }
}

final class FakeDomains: DomainLookupTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] { lock.withLock { _calls } }

    func rdap(_ domain: String) async throws -> Data {
        lock.withLock { _calls.append("rdap \(domain)") }
        return Data(#"{"events":[{"eventAction":"expiration","eventDate":"2026-10-12T00:00:00Z"}]}"#.utf8)
    }

    func whois(server: String, query: String) async throws -> String {
        lock.withLock { _calls.append("whois \(server) \(query)") }
        return "paid-till: 2027-01-01T00:00:00Z\n"
    }
}

final class DomainExpiryTests: XCTestCase {
    func testLookupCachesAndPicksProtocol() async {
        let fake = FakeDomains()
        let d = DomainExpiry(transport: fake)
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let due = await d.due(["example.com", "biotech.ru"], now: t0)
        XCTAssertEqual(due, ["biotech.ru", "example.com"])
        let com = await d.lookup("example.com", now: t0)
        let ru = await d.lookup("biotech.ru", now: t0)
        XCTAssertEqual(com.expiry, AgentJSON.parseRFC3339("2026-10-12T00:00:00Z"))
        XCTAssertEqual(ru.expiry, AgentJSON.parseRFC3339("2027-01-01T00:00:00Z"))
        XCTAssertEqual(fake.calls, ["rdap example.com", "whois whois.tcinet.ru biotech.ru"])
        let none = await d.due(["example.com", "biotech.ru"], now: t0.addingTimeInterval(3600))
        XCTAssertEqual(none, [])
        let again = await d.due(["example.com"], now: t0.addingTimeInterval(13 * 3600))
        XCTAssertEqual(again, ["example.com"])
    }
}

final class SitePollerTests: XCTestCase {
    func testPushesTargetsOnceAndAlertsOnSite() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        func snap(_ minute: Int, ok: Bool) -> Snapshot {
            var s = Fixtures.snapshot(time: t0.addingTimeInterval(TimeInterval(minute * 60)))
            s.checks = [Snapshot.Check(id: "site-shop", kind: "http", target: "https://shop.example.com", ok: ok,
                                       statusCode: ok ? 200 : 503, latencyMs: 90, tlsExpiry: nil, error: nil)]
            return s
        }
        let agent = FakeAgent()
        agent.history = [snap(0, ok: true)]
        let store = try Store(path: dir.appendingPathComponent("m.sqlite").path)
        let out = Collector()
        let sitesOut = SitesCollector()
        let poller = Poller(client: AgentClient(transport: agent), store: store, domainLookup: FakeDomains(),
                            onUpdate: { out.set($0) }, onEvents: { out.add($0) })
        await poller.setSitesHandler { sitesOut.set($0) }
        await poller.setConfig(ServersFile(servers: [Fixtures.server],
                                           sites: [SiteConfig(id: "shop", name: "Магазин",
                                                              url: "https://shop.example.com")]))

        await poller.pollAll(now: t0.addingTimeInterval(60))
        await poller.pollAll(now: t0.addingTimeInterval(120))
        XCTAssertEqual(agent.requests.filter { $0 == "PUT /v1/checks" }.count, 1)
        XCTAssertEqual(sitesOut.sites.first?.level, .ok)
        XCTAssertEqual(sitesOut.sites.first?.origins.first?.check?.statusCode, 200)
        XCTAssertEqual(sitesOut.sites.first?.domain, "example.com")

        agent.history.append(snap(3, ok: false))
        await poller.pollAll(now: t0.addingTimeInterval(180))
        await poller.pollAll(now: t0.addingTimeInterval(240))
        XCTAssertEqual(out.events.map(\.key), ["down"])
        XCTAssertEqual(out.events.first?.serverID, "site:shop")
        XCTAssertEqual(sitesOut.sites.first?.level, .critical)

        let samples = try await store.siteSamples("shop", from: t0, to: t0.addingTimeInterval(600))
        XCTAssertEqual(samples.map(\.ok), [true, false])

        // The domain lookup runs in the background; its date shows up on a later round.
        try await Task.sleep(nanoseconds: 200_000_000)
        await poller.pollAll(now: t0.addingTimeInterval(300))
        XCTAssertEqual(sitesOut.sites.first?.domainExpiry, AgentJSON.parseRFC3339("2026-10-12T00:00:00Z"))
        let persisted = try await store.domains()
        XCTAssertNotNil(persisted["example.com"]?.expiry)
    }
}

final class SitesCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _sites: [SiteStatus] = []
    var sites: [SiteStatus] { lock.withLock { _sites } }
    func set(_ s: [SiteStatus]) { lock.withLock { _sites = s } }
}
