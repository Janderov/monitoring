import Foundation
import XCTest
@testable import MonitorCore

final class RoutesTests: XCTestCase {
    func server(_ id: String, _ host: String) -> ServerConfig {
        ServerConfig(id: id, name: id, host: host, token: "t", fingerprint: "f")
    }

    func testForwardedAndInbound() {
        // NL forwards client traffic (NAT) to the US; RU sees US connecting in.
        var nl = Fixtures.snapshot()
        nl.forwards = [.init(remoteIp: "192.0.2.130", ports: [443], protos: ["tcp"], connections: 12,
                             via: ["nat:host"]),
                       .init(remoteIp: "142.250.1.1", ports: [443], protos: ["udp"], connections: 40,
                             via: ["nat:host"])]
        var us = Fixtures.snapshot()
        // The US also sees NL coming in: the same traffic, counted once.
        us.inbound = [.init(remoteIp: "192.0.2.110", ports: [443], protos: ["tcp"], connections: 10, via: ["host"]),
                      .init(remoteIp: "192.0.2.121", ports: [22, 9443], protos: ["tcp"], connections: 1,
                            via: ["host"])]
        var ru = Fixtures.snapshot()
        ru.inbound = [.init(remoteIp: "192.0.2.130", ports: [8443], protos: ["tcp"], connections: 3, via: ["host"])]
        let statuses = [
            ServerStatus(server: server("nl", "192.0.2.110"), snapshot: nl, lastSeen: nil, error: nil, alerts: []),
            ServerStatus(server: server("ru", "192.0.2.121"), snapshot: ru, lastSeen: nil, error: nil, alerts: []),
            ServerStatus(server: server("us", "192.0.2.130"), snapshot: us, lastSeen: nil, error: nil, alerts: []),
        ]
        let routes = VPNRoutes.compute(statuses)
        XCTAssertEqual(routes.map(\.id), ["nl->us", "us->ru"])
        XCTAssertEqual(routes[0].via, ["nat:host"])
        XCTAssertEqual(routes[0].connections, 12)
        XCTAssertEqual(routes[1].ports, [8443])
    }

    func testTunnelAndRelay() throws {
        var nl = Fixtures.snapshot()
        // Entry NL: a WireGuard peer that routes everything to the US server...
        nl.vpn![0].peers!.append(.init(name: nil, publicKey: "US=", latestHandshake: nil, active: true,
                                       rxBytes: 1, txBytes: 2, endpoint: "192.0.2.130:51820",
                                       allowedIps: "0.0.0.0/0, ::/0"))
        // ...plus a client whose endpoint happens to be the RU server: not a cascade.
        nl.vpn![0].peers!.append(.init(name: nil, publicKey: "C=", latestHandshake: nil, active: true,
                                       rxBytes: 1, txBytes: 2, endpoint: "192.0.2.121:40000",
                                       allowedIps: "10.8.1.9/32"))
        var ru = Fixtures.snapshot()
        ru.links = [
            .init(remoteIp: "192.0.2.110", ports: [443], protos: ["tcp"], connections: 4, via: ["amnezia-xray"]),
            .init(remoteIp: "192.0.2.130", ports: [22, 9443], protos: ["tcp"], connections: 1, via: ["host"]),
            .init(remoteIp: "8.8.8.8", ports: [53], protos: ["udp"], connections: 1, via: ["host"]),
        ]
        let statuses = [
            ServerStatus(server: server("nl", "192.0.2.110"), snapshot: nl, lastSeen: nil, error: nil, alerts: []),
            ServerStatus(server: server("ru", "192.0.2.121"), snapshot: ru, lastSeen: nil, error: nil, alerts: []),
            ServerStatus(server: server("us", "192.0.2.130"), snapshot: nil, lastSeen: nil, error: nil, alerts: []),
        ]
        let routes = VPNRoutes.compute(statuses)
        XCTAssertEqual(routes.map(\.id), ["nl->us", "ru->nl"])
        XCTAssertEqual(routes[0].kind, .tunnel)
        XCTAssertEqual(routes[0].via, ["amnezia-awg2"])
        XCTAssertTrue(routes[0].active)
        XCTAssertEqual(routes[1].kind, .relay)
        XCTAssertEqual(routes[1].ports, [443])
        XCTAssertEqual(routes[1].connections, 4)
    }

    func testDecodesAgentFields() throws {
        let json = Fixtures.snapshotJSON().replacingOccurrences(
            of: #""active": true, "rx_bytes": 1, "tx_bytes": 2}]}]"#,
            with: #""active": true, "rx_bytes": 1, "tx_bytes": 2, "endpoint": "1.2.3.4:5", "allowed_ips": "0.0.0.0/0"}]}],"#
                + #""links": [{"remote_ip": "1.2.3.4", "ports": [443], "protos": ["tcp"], "connections": 2, "via": ["host"]}]"#)
        let s = try AgentJSON.decoder.decode(Snapshot.self, from: Data(json.utf8))
        XCTAssertEqual(s.vpn?.first?.peers?.first?.allowedIps, "0.0.0.0/0")
        XCTAssertEqual(s.links?.first?.remoteIp, "1.2.3.4")
        XCTAssertEqual(VPNRoutes.splitEndpoint("[2001:db8::1]:51820")?.0, "2001:db8::1")
    }
}
