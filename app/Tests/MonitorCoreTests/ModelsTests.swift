import Foundation
import XCTest
@testable import MonitorCore

final class ModelsTests: XCTestCase {
    func testDecodeAgentSnapshot() throws {
        let s = try AgentJSON.decoder.decode(Snapshot.self, from: Data(Fixtures.snapshotJSON().utf8))
        XCTAssertEqual(s.hostname, "wise")
        XCTAssertEqual(s.time.timeIntervalSince1970.truncatingRemainder(dividingBy: 1), 0.414284339, accuracy: 1e-6)
        XCTAssertEqual(s.cpu.usagePercent, 12.5)
        XCTAssertEqual(s.network.rxBytesPerSec, 10.5)
        XCTAssertEqual(s.vpn?.first?.clientsKnown, true)
        XCTAssertEqual(s.vpnActiveClients, 3)
        XCTAssertEqual(s.maxDiskPercent, 41.2)
        XCTAssertEqual(s.services?.first?.port, 443)
        XCTAssertNotNil(s.checks?.first?.tlsExpiry)
        XCTAssertNotNil(s.vpn?.first?.peers?.first?.latestHandshake)
    }

    func testDecodeMinimalSnapshot() throws {
        // Older agents and hosts without Docker omit the optional sections.
        let json = """
        {"time":"2026-10-05T07:58:28Z","hostname":"h","uptime_seconds":1,"boot_time":"2026-10-05T07:58:27Z",
         "cpu":{"cores":1,"usage_percent":0,"iowait_percent":0,"steal_percent":0},
         "memory":{"total_bytes":1,"available_bytes":1,"used_percent":0,"swap_total_bytes":0,"swap_free_bytes":0},
         "load":{"one":0,"five":0,"fifteen":0},"disks":null,
         "network":{"rx_bytes":0,"tx_bytes":0,"rx_bytes_per_sec":0,"tx_bytes_per_sec":0,"interfaces":null}}
        """
        let s = try AgentJSON.decoder.decode(Snapshot.self, from: Data(json.utf8))
        XCTAssertNil(s.vpn)
        XCTAssertEqual(s.maxDiskPercent, 0)
        XCTAssertEqual(s.vpnActiveClients, 0)
    }

    func testRFC3339RoundTrip() {
        let d = Date(timeIntervalSince1970: 1_790_000_000.25)
        let back = AgentJSON.parseRFC3339(AgentJSON.formatRFC3339(d))
        XCTAssertEqual(back!.timeIntervalSince1970, d.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNil(AgentJSON.parseRFC3339("yesterday"))
        XCTAssertEqual(AgentJSON.parseRFC3339("2026-10-05T10:00:00+03:00")?.timeIntervalSince1970,
                       AgentJSON.parseRFC3339("2026-10-05T07:00:00Z")?.timeIntervalSince1970)
    }

    func testFingerprint() {
        let colon = String(repeating: "ab:", count: 31) + "ab"
        let plain = String(repeating: "AB", count: 32)
        XCTAssertEqual(Fingerprint.bytes(colon), Fingerprint.bytes(plain))
        XCTAssertTrue(Fingerprint.matches(colon, sha256: Array(repeating: 0xAB, count: 32)))
        XCTAssertFalse(Fingerprint.matches(colon, sha256: Array(repeating: 0xAC, count: 32)))
        XCTAssertNil(Fingerprint.bytes("ab:cd"))
    }

    func testServersFileValidation() throws {
        var file = ServersFile(servers: [Fixtures.server])
        XCTAssertNoThrow(try file.validate())

        file.servers.append(Fixtures.server)
        XCTAssertThrowsError(try file.validate()) // duplicate id

        var bad = Fixtures.server
        bad.token = "short"
        XCTAssertThrowsError(try ServersFile(servers: [bad]).validate())

        // The file written on first launch is empty; servers come from the app.
        let example = try ServersFile.decode(Data(ServersFile.example.utf8))
        XCTAssertNoThrow(try example.validate())
        XCTAssertTrue(example.servers.isEmpty)

        // Placeholders from the old hand-edited example are still caught.
        var placeholder = Fixtures.server
        placeholder.token = "PASTE-TOKEN-FROM-remote-install.sh"
        XCTAssertThrowsError(try ServersFile(servers: [placeholder]).validate()) { err in
            XCTAssertTrue("\(err)".contains("пример"), "\(err)")
        }
    }

    func testServerThresholdOverridesDecode() throws {
        let json = """
        {"servers":[{"id":"a","name":"A","host":"h","port":9443,"token":"\(String(repeating: "t", count: 40))",
          "fingerprint":"\(String(repeating: "00", count: 32))","thresholds":{"disk_percent":80}}]}
        """
        let file = try ServersFile.decode(Data(json.utf8))
        XCTAssertEqual(file.servers[0].thresholds?.resolved.diskPercent, 80)
        XCTAssertEqual(file.servers[0].thresholds?.resolved.cpuPercent, 90)
    }
}
