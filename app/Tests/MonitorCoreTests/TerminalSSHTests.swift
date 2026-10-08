import XCTest
@testable import MonitorCore

final class TerminalSSHTests: XCTestCase {
    private func server(_ host: String, ssh: SSHTarget? = nil) -> ServerConfig {
        ServerConfig(id: "s", name: "S", host: host, token: "", fingerprint: "", ssh: ssh)
    }

    func testTargetUsesSavedSettingsThenConfigThenAddress() {
        let config = [SSHConfigEntry(alias: "proxy-us", hostName: "203.0.113.5", user: "admin", port: nil,
                                     identityFile: "~/.ssh/id_us")]
        let saved = SSHTarget(host: "198.51.100.2", port: 2222, identityFile: "~/.ssh/k")
        XCTAssertEqual(TerminalSSH.target(for: server("198.51.100.2", ssh: saved), user: "root", config: config),
                       SSHTarget(host: "198.51.100.2", port: 2222, user: "root", identityFile: "~/.ssh/k"))
        // The config block names the key and user; the app adds nothing.
        XCTAssertEqual(TerminalSSH.target(for: server("203.0.113.5"), user: "root", config: config),
                       SSHTarget(host: "proxy-us"))
        XCTAssertEqual(TerminalSSH.target(for: server("192.0.2.9"), user: "ubuntu", config: config),
                       SSHTarget(host: "192.0.2.9", user: "ubuntu"))
    }

    func testCommandQuotesAndJumps() {
        let target = SSHTarget(host: "198.51.100.2", user: "root", identityFile: "/Users/m/My Keys/k")
        XCTAssertEqual(TerminalSSH.command(target),
                       "ssh -o User=root -i '/Users/m/My Keys/k' -o IdentitiesOnly=yes 198.51.100.2")
        let jump = SSHTarget(host: "203.0.113.5", port: 2200, user: "root")
        XCTAssertEqual(TerminalSSH.command(SSHTarget(host: "198.51.100.2", user: "root"), jump: jump),
                       "ssh -o User=root -o 'ProxyCommand=ssh -p 2200 -o User=root -W %h:%p 203.0.113.5' 198.51.100.2")
    }

    func testQuote() {
        XCTAssertEqual(TerminalSSH.quote("it's"), "'it'\\''s'")
        XCTAssertEqual(TerminalSSH.quote(""), "''")
    }
}
