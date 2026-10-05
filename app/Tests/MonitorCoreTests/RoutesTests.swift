import Foundation
import XCTest
@testable import MonitorCore

final class RoutesTests: XCTestCase {
    func server(_ id: String, _ host: String) -> ServerConfig {
        ServerConfig(id: id, name: id, host: host, token: "t", fingerprint: "f")
    }

    func testTunnelAndRelay() throws {
        var nl = Fixtures.snapshot()
        // Entry NL: a WireGuard peer that routes everything to the US server...
        nl.vpn![0].peers!.append(.init(name: nil, publicKey: "US=", latestHandshake: nil, active: true,
                                       rxBytes: 1, txBytes: 2, endpoint: "149.28.225.248:51820",
                                       allowedIps: "0.0.0.0/0, ::/0"))
        // ...plus a client whose endpoint happens to be the RU server: not a cascade.
        nl.vpn![0].peers!.append(.init(name: nil, publicKey: "C=", latestHandshake: nil, active: true,
                                       rxBytes: 1, txBytes: 2, endpoint: "155.212.164.127:40000",
                                       allowedIps: "10.8.1.9/32"))
        var ru = Fixtures.snapshot()
        ru.links = [
            .init(remoteIp: "103.54.19.175", ports: [443], protos: ["tcp"], connections: 4, via: ["amnezia-xray"]),
            .init(remoteIp: "149.28.225.248", ports: [22, 9443], protos: ["tcp"], connections: 1, via: ["host"]),
            .init(remoteIp: "8.8.8.8", ports: [53], protos: ["udp"], connections: 1, via: ["host"]),
        ]
        let statuses = [
            ServerStatus(server: server("nl", "103.54.19.175"), snapshot: nl, lastSeen: nil, error: nil, alerts: []),
            ServerStatus(server: server("ru", "155.212.164.127"), snapshot: ru, lastSeen: nil, error: nil, alerts: []),
            ServerStatus(server: server("us", "149.28.225.248"), snapshot: nil, lastSeen: nil, error: nil, alerts: []),
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
