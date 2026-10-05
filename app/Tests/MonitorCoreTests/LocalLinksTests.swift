import Foundation
import XCTest
@testable import MonitorCore

final class LocalLinksTests: XCTestCase {
    // Trimmed `netstat -anv -f inet` from macOS 14: gost to the US (Google)
    // and NL, the app's own agent poll, an SSH session, LAN and listeners.
    let sample = """
    Active Internet connections (including servers)
    Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)       rxbytes      txbytes  rhiwat  shiwat    process:pid   state  options           gencnt    flags   flags1 usscnt rtncnt fltrs
    tcp4       0      0  192.168.1.10.60123     149.28.225.248.8443    ESTABLISHED     6123       4012  131072  131760     gost:812  00102 00000020 00000000000a1b2c 00000080 04000900      1      0 000001
    tcp4       0      0  192.168.1.10.60124     149.28.225.248.8443    ESTABLISHED     6123       4012  131072  131760     gost:812  00102 00000020 00000000000a1b2c 00000080 04000900      1      0 000001
    tcp4       0      0  192.168.1.10.60125     103.54.19.175.443      ESTABLISHED     6123       4012  131072  131760     gost:812  00102 00000020 00000000000a1b2c 00000080 04000900      1      0 000001
    tcp4       0      0  192.168.1.10.60126     103.54.19.175.9443     ESTABLISHED     6123       4012  131072  131760  Monitor:400  00102 00000020 00000000000a1b2c 00000080 04000900      1      0 000001
    tcp4       0      0  192.168.1.10.60127     155.212.164.127.22     ESTABLISHED     6123       4012  131072  131760      ssh:900  00102 00000020 00000000000a1b2c 00000080 04000900      1      0 000001
    tcp4       0      0  192.168.1.10.60128     192.168.1.1.80         ESTABLISHED     6123       4012  131072  131760   Safari:77  00102 00000020 00000000000a1b2c 00000080 04000900      1      0 000001
    tcp4       0      0  127.0.0.1.1080         *.*                    LISTEN             0          0  131072  131072     gost:812  00100 00000006 0000000000000001 00000000 00000800      1      0 000001
    tcp4       0      0  192.168.1.10.60129     8.8.4.4.443            TIME_WAIT          0          0  131072  131760     gost:812  00102 00000020 00000000000a1b2c 00000080 04000900      1      0 000001
    udp4       0      0  192.168.1.10.53001     103.54.19.175.32253                       100        200  786896    9216  AmneziaVPN:300 00000 00000000 00000000000a1b2d 00000000 00000800      1      0 000001
    udp4       0      0  *.5353                 *.*                                         0          0  786896    9216  mDNSResponder:1 00000 00000000 00000000000a1b2e 00000000 00000800      1      0 000001
    """

    func testParseGroupsByProgramAndDropsNoise() {
        let links = LocalLinks.parse(sample, ownPID: 400)
        XCTAssertEqual(links.count, 3)
        let us = links.first { $0.remoteIP == "149.28.225.248" }
        XCTAssertEqual(us?.process, "gost")
        XCTAssertEqual(us?.connections, 2)
        XCTAssertEqual(us?.ports, [8443])
        let nl = links.filter { $0.remoteIP == "103.54.19.175" }.sorted { $0.process < $1.process }
        XCTAssertEqual(nl.map(\.process), ["AmneziaVPN", "gost"])
        XCTAssertEqual(nl.first?.protos, ["udp"])
    }

    func testBarePidColumnUsesResolver() {
        let old = """
        Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)      rhiwat  shiwat    pid   epid
        tcp4       0      0  10.0.0.2.5000          103.54.19.175.443      ESTABLISHED  131072  131760    812      0
        """
        let links = LocalLinks.parse(old, name: { $0 == 812 ? "gost" : nil })
        XCTAssertEqual(links.map(\.process), ["gost"])
    }

    func testRoutesMatchServersAndSkipAgentPort() {
        let servers = [
            ServerConfig(id: "nl", name: "NL", host: "103.54.19.175", token: "t", fingerprint: "f"),
            ServerConfig(id: "us", name: "US", host: "149.28.225.248", token: "t", fingerprint: "f"),
        ]
        let links = LocalLinks.parse(sample)
        let routes = LocalLinks.routes(links, servers: servers)
        XCTAssertEqual(routes.map(\.toID), ["nl", "us"])
        XCTAssertEqual(routes[0].processes, ["AmneziaVPN", "gost"])
        XCTAssertFalse(routes[0].ports.contains(9443))
        XCTAssertEqual(LocalLinks.unknown(links, servers: servers).count, 0)
    }

    func testAddresses() {
        XCTAssertEqual(LocalLinks.splitAddress("1.2.3.4.443")?.1, 443)
        XCTAssertEqual(LocalLinks.splitAddress("2001:db8::1.443")?.0, "2001:db8::1")
        XCTAssertNil(LocalLinks.splitAddress("*.*"))
        XCTAssertFalse(LocalLinks.isPublic("172.20.0.1"))
        XCTAssertFalse(LocalLinks.isPublic("100.100.1.1"))
        XCTAssertTrue(LocalLinks.isPublic("172.32.0.1"))
    }
}
