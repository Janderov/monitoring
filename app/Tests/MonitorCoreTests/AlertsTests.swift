import Foundation
import XCTest
@testable import MonitorCore

final class AlertsTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    let server = Fixtures.server

    func at(_ minute: Int) -> Date { t0.addingTimeInterval(TimeInterval(minute) * 60) }

    func testDownFiresAfterThreeFailuresThenRecoversOnce() {
        var e = AlertEngine()
        XCTAssertEqual(e.process(server: server, outcome: .failure("timeout"), now: at(0)), [])
        XCTAssertEqual(e.process(server: server, outcome: .failure("timeout"), now: at(1)), [])
        let fired = e.process(server: server, outcome: .failure("timeout"), now: at(2))
        XCTAssertEqual(fired.map(\.kind), [.fired])
        XCTAssertEqual(fired.first?.key, "down")
        XCTAssertEqual(fired.first?.severity, .critical)
        XCTAssertEqual(e.active(server.id).map(\.key), ["down"])

        // No repeats until the reminder interval passes.
        for m in 3..<32 { XCTAssertEqual(e.process(server: server, outcome: .failure("timeout"), now: at(m)), []) }
        XCTAssertEqual(e.process(server: server, outcome: .failure("timeout"), now: at(32)).map(\.kind), [.reminder])

        let back = e.process(server: server, outcome: .snapshot(Fixtures.snapshot(time: at(33))), now: at(33))
        XCTAssertEqual(back.map(\.kind), [.resolved])
        XCTAssertEqual(back.first?.body.hasPrefix("снова в норме"), true)
        XCTAssertEqual(e.process(server: server, outcome: .snapshot(Fixtures.snapshot()), now: at(34)), [])
        XCTAssertTrue(e.active(server.id).isEmpty)
    }

    func testShortBlipIsSilent() {
        var e = AlertEngine()
        XCTAssertEqual(e.process(server: server, outcome: .failure("x"), now: at(0)), [])
        XCTAssertEqual(e.process(server: server, outcome: .failure("x"), now: at(1)), [])
        XCTAssertEqual(e.process(server: server, outcome: .snapshot(Fixtures.snapshot()), now: at(2)), [])
        XCTAssertEqual(e.process(server: server, outcome: .failure("x"), now: at(3)), [])
    }

    func testCPUNeedsFiveMinutes() {
        var e = AlertEngine()
        for m in 0..<4 {
            XCTAssertEqual(e.process(server: server, outcome: .snapshot(Fixtures.snapshot(cpu: 97)), now: at(m)), [])
        }
        let fired = e.process(server: server, outcome: .snapshot(Fixtures.snapshot(cpu: 97)), now: at(4))
        XCTAssertEqual(fired.map(\.key), ["cpu"])
        XCTAssertEqual(fired.first?.severity, .warning)
    }

    func testResolveNeedsTwoGoodPolls() {
        var e = AlertEngine()
        _ = e.process(server: server, outcome: .snapshot(Fixtures.snapshot(disk: 95)), now: at(0))
        XCTAssertEqual(e.process(server: server, outcome: .snapshot(Fixtures.snapshot(disk: 95)), now: at(1)).map(\.key),
                       ["disk:/"])
        XCTAssertEqual(e.process(server: server, outcome: .snapshot(Fixtures.snapshot(disk: 80)), now: at(2)), [])
        // Flaps back: still the same alert, no new notification.
        XCTAssertEqual(e.process(server: server, outcome: .snapshot(Fixtures.snapshot(disk: 95)), now: at(3)), [])
        XCTAssertEqual(e.process(server: server, outcome: .snapshot(Fixtures.snapshot(disk: 80)), now: at(4)), [])
        XCTAssertEqual(e.process(server: server, outcome: .snapshot(Fixtures.snapshot(disk: 80)), now: at(5)).map(\.kind),
                       [.resolved])
    }

    func testOutageDoesNotResolveOtherAlerts() {
        var e = AlertEngine()
        _ = e.process(server: server, outcome: .snapshot(Fixtures.snapshot(vpnRunning: false)), now: at(0))
        XCTAssertEqual(e.process(server: server, outcome: .snapshot(Fixtures.snapshot(vpnRunning: false)),
                                 now: at(1)).map(\.key), ["vpn:amnezia-awg2"])
        for m in 2..<6 { _ = e.process(server: server, outcome: .failure("x"), now: at(m)) }
        XCTAssertEqual(Set(e.active(server.id).map(\.key)), ["down", "vpn:amnezia-awg2"])
        XCTAssertEqual(e.active(server.id).first?.severity, .critical)
    }

    func testPerServerThresholdOverride() {
        var s = server
        s.thresholds = Thresholds(diskPercent: 40)
        let c = Rules.conditions(.snapshot(Fixtures.snapshot(disk: 41.2)), thresholds: s.thresholds, now: t0)
        XCTAssertEqual(c.map(\.key), ["disk:/"])
        XCTAssertTrue(Rules.conditions(.snapshot(Fixtures.snapshot(disk: 41.2)), thresholds: nil, now: t0).isEmpty)
    }

    func testTLSExpirySoon() {
        // Fixture certificate expires 2027-01-01; check from 10 days before.
        let now = AgentJSON.parseRFC3339("2026-12-22T00:00:00Z")!
        let c = Rules.conditions(.snapshot(Fixtures.snapshot()), thresholds: nil, now: now)
        XCTAssertEqual(c.map(\.key), ["tls:site"])
        XCTAssertTrue(c[0].message.contains("10"))
    }

    func testServiceAndCheckFailures() {
        var snap = Fixtures.snapshot()
        snap.services?[0].portOpen = false
        snap.checks?[0].ok = false
        snap.checks?[0].statusCode = 502
        snap.containers?[0].health = "unhealthy"
        let keys = Rules.conditions(.snapshot(snap), thresholds: nil, now: t0).map(\.key)
        XCTAssertEqual(Set(keys), ["svc:nginx", "check:site", "ctr:amnezia-awg2"])
    }
}
