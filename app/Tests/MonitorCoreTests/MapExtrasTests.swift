import Foundation
import XCTest
@testable import MonitorCore

final class MapExtrasTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func testRateMeterSkipsRepeatsAndResets() {
        var m = RateMeter()
        m.add("a", ByteCounter(rx: 1000, tx: 500), at: t0)
        XCTAssertNil(m.rate("a"))
        m.add("a", ByteCounter(rx: 3000, tx: 1500), at: t0.addingTimeInterval(10))
        XCTAssertEqual(m.rate("a"), RateMeter.Rate(rx: 200, tx: 100))
        // The same snapshot again: the rate stays.
        m.add("a", ByteCounter(rx: 3000, tx: 1500), at: t0.addingTimeInterval(10))
        XCTAssertEqual(m.rate("a")?.total, 300)
        // Counter restarted: no rate until the next reading.
        m.add("a", ByteCounter(rx: 10, tx: 10), at: t0.addingTimeInterval(20))
        XCTAssertNil(m.rate("a"))
        m.add("a", ByteCounter(rx: 110, tx: 10), at: t0.addingTimeInterval(30))
        XCTAssertEqual(m.rate("a")?.rx, 10)
        m.keep([])
        XCTAssertNil(m.sum(["a"]))
    }

    func testRateMeterFeedsPeers() {
        var m = RateMeter()
        var snap = Fixtures.snapshot(time: t0)
        let s1 = ServerStatus(server: Fixtures.server, snapshot: snap, lastSeen: t0, error: nil, alerts: [])
        m.add([s1])
        snap.time = t0.addingTimeInterval(60)
        snap.vpn![0].peers![0].rxBytes = 601
        snap.vpn![0].peers![0].txBytes = 62
        let s2 = ServerStatus(server: Fixtures.server, snapshot: snap, lastSeen: t0, error: nil, alerts: [])
        let keys = m.add([s2])
        let key = RateMeter.peerKey(server: "nl", publicKey: "k=")
        XCTAssertEqual(keys, [key])
        XCTAssertEqual(m.rate(key), RateMeter.Rate(rx: 10, tx: 1))
    }

    func testNetstatByteCounters() {
        let out = """
        Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)       rxbytes      txbytes  rhiwat  shiwat    process:pid   state  options
        tcp4       0      0  192.168.1.10.60123     192.0.2.130.8443    ESTABLISHED     6123       4012  131072  131760     gost:812  00102 00000020
        tcp4       0      0  192.168.1.10.60124     192.0.2.130.8443    ESTABLISHED      100         50  131072  131760     gost:812  00102 00000020
        """
        let links = LocalLinks.parse(out)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].counters.count, 2)
        XCTAssertEqual(links[0].counters["tcp 192.168.1.10.60123"], ByteCounter(rx: 6123, tx: 4012))
        XCTAssertEqual(RateMeter.connectionKeys(links[0]).count, 2)
    }

    func testChainsFollowCascadesAndDropPrefixes() {
        let mac = "this-mac"
        let macRoutes = [
            MacRoute(toID: "nl", processes: ["VPN amnezia-awg2"], ports: [], connections: 1),
            MacRoute(toID: "us", processes: ["gost"], ports: [22], connections: 3, viaID: "nl"),
        ]
        let chains = NetworkChains.build(macID: mac, macRoutes: macRoutes, routes: [])
        XCTAssertEqual(chains.map(\.nodes), [[mac, "nl", "us"]])
        XCTAssertTrue(chains[0].contains(from: "nl", to: "us"))
        XCTAssertFalse(chains[0].contains(from: mac, to: "us"))

        // A server cascade: clients enter at RU, go out through NL, then US.
        let routes = [
            VPNRoute(fromID: "ru", toID: "nl", kind: .tunnel, via: [], ports: [], connections: 1, active: true),
            VPNRoute(fromID: "nl", toID: "us", kind: .relay, via: [], ports: [443], connections: 0, active: false),
        ]
        let more = NetworkChains.build(macID: mac, macRoutes: [macRoutes[0]], routes: routes)
        XCTAssertEqual(more.map(\.nodes), [[mac, "nl", "us"], ["ru", "nl", "us"]])
        XCTAssertFalse(more[1].active)
        XCTAssertEqual(more[1].hops.count, 2)
    }

    func testChainsStopOnLoops() {
        let routes = [
            VPNRoute(fromID: "a", toID: "b", kind: .relay, via: [], ports: [1], connections: 1, active: true),
            VPNRoute(fromID: "b", toID: "a", kind: .relay, via: [], ports: [1], connections: 1, active: true),
        ]
        let chains = NetworkChains.build(macID: "m", macRoutes: [MacRoute(toID: "a", processes: [], ports: [], connections: 1)],
                                         routes: routes)
        XCTAssertEqual(chains.map(\.nodes), [["m", "a", "b"]])
    }

    func testMomentAlerts() {
        func ev(_ server: String, _ key: String, _ kind: AlertEvent.Kind, _ sev: Severity, _ at: TimeInterval) -> Store.LoggedEvent {
            Store.LoggedEvent(serverID: server, time: t0.addingTimeInterval(at), key: key, kind: kind,
                              severity: sev, message: "", actor: "system")
        }
        let events = [
            ev("nl", "down", .fired, .critical, 100),
            ev("nl", "down", .resolved, .critical, 400),
            ev("nl", "disk", .fired, .warning, 200),
            ev("us", "boot", .info, .warning, 150),
        ]
        XCTAssertEqual(MapMoment.alerts(events, at: t0.addingTimeInterval(50)), [:])
        XCTAssertEqual(MapMoment.alerts(events, at: t0.addingTimeInterval(300)), ["nl": .critical])
        XCTAssertEqual(MapMoment.alerts(events, at: t0.addingTimeInterval(500)), ["nl": .warning])
    }

    func testMomentLinksAndSamples() {
        let samples = [
            Store.LinkSample(peerID: "us", time: t0, ok: true, latencyMs: 80),
            Store.LinkSample(peerID: "us", time: t0.addingTimeInterval(60), ok: false, latencyMs: nil),
            Store.LinkSample(peerID: "ru", time: t0.addingTimeInterval(-3600), ok: true, latencyMs: 40),
        ]
        let at = MapMoment.links(samples, at: t0.addingTimeInterval(90))
        XCTAssertEqual(at["us"]?.ok, false)
        XCTAssertNil(at["ru"], "older than the window")
        XCTAssertEqual(MapMoment.links(samples, at: t0.addingTimeInterval(30))["us"]?.latencyMs, 80)

        let cpu = [Store.Sample(time: t0, cpu: 10, mem: 0, disk: 0, load1: 0, rx: 0, tx: 0, vpnClients: 0),
                   Store.Sample(time: t0.addingTimeInterval(60), cpu: 70, mem: 0, disk: 0, load1: 0, rx: 0, tx: 0, vpnClients: 0)]
        XCTAssertEqual(MapMoment.sample(cpu, at: t0.addingTimeInterval(61))?.cpu, 70)
        XCTAssertNil(MapMoment.sample(cpu, at: t0.addingTimeInterval(-1)))

        let site = [Store.SiteSample(serverID: "us", time: t0, ok: false, statusCode: nil, latencyMs: 0, error: "timeout")]
        XCTAssertEqual(MapMoment.site(site, at: t0.addingTimeInterval(5))["us"]?.ok, false)
    }

    func testSiteHosting() {
        XCTAssertEqual(SiteHosting.host(of: "https://Shop.Example.com/path?x=1"), "shop.example.com")
        XCTAssertEqual(SiteHosting.host(of: "example.org"), "example.org")
        XCTAssertNil(SiteHosting.host(of: ""))
        let servers = [(id: "ru", addresses: ["198.51.100.7"]), (id: "nl", addresses: ["203.0.113.10"])]
        XCTAssertEqual(SiteHosting.server(siteAddresses: ["198.51.100.7"], servers: servers), "ru")
        XCTAssertNil(SiteHosting.server(siteAddresses: ["192.0.2.1"], servers: servers))
    }

    func testRouteInterface() {
        let out = """
           route to: 203.0.113.10
        destination: default
               mask: default
            gateway: 192.168.1.1
          interface: en0
              flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
        """
        XCTAssertEqual(MacRouting.interface(routeGet: out), "en0")
        XCTAssertNil(MacRouting.interface(routeGet: "route: writing to routing socket: not in table"))
        XCTAssertTrue(MacRouting.isTunnel("utun4"))
        XCTAssertFalse(MacRouting.isTunnel("en0"))
        XCTAssertFalse(MacRouting.isTunnel(nil))
    }
}
