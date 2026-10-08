import Foundation
import XCTest
@testable import MonitorCore

final class ServerControlTests: XCTestCase {
    final class Recorder: SSHRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var _commands: [String] = []
        var commands: [String] { lock.withLock { _commands } }
        var result = SSHOutput(status: 0, stdout: "", stderr: "")

        func run(_ target: SSHTarget, password: String?, command: String, stdin: Data?) async throws -> SSHOutput {
            lock.withLock { _commands.append(command) }
            return result
        }
        func upload(_ target: SSHTarget, password: String?, files: [URL], to remoteDir: String) async throws {}
        func resolveHost(_ target: SSHTarget) async -> String { target.host }
        func close(_ target: SSHTarget) async {}
    }

    func testRestartAndReboot() async throws {
        let ssh = Recorder()
        let control = ServerControl(server: Fixtures.server, ssh: ssh)
        try await control.restartContainer("amnezia-awg2")
        try await control.reboot()
        XCTAssertTrue(ssh.commands[0].hasSuffix("$S docker restart amnezia-awg2 >/dev/null"))
        XCTAssertTrue(ssh.commands[1].contains("systemctl reboot"))
        XCTAssertTrue(ssh.commands[1].hasSuffix("&"), "reboot must not hold the SSH session")
    }

    func testRejectsOddNamesAndReportsSudo() async throws {
        let ssh = Recorder()
        let control = ServerControl(server: Fixtures.server, ssh: ssh)
        for bad in ["", "-rm", "a;reboot", "x y", "$(id)"] {
            do {
                try await control.restartContainer(bad)
                XCTFail("accepted \(bad)")
            } catch is ControlError {}
        }
        XCTAssertTrue(ssh.commands.isEmpty)

        ssh.result = SSHOutput(status: 1, stdout: "", stderr: "sudo: a password is required\n")
        do {
            try await control.restartContainer("web")
            XCTFail("should fail")
        } catch let e as ControlError {
            XCTAssertTrue(e.description.contains("sudo без пароля"), e.description)
        }
    }

    func testBackupAndNightlyJob() async throws {
        let ssh = Recorder()
        ssh.result = SSHOutput(status: 0, stdout: "/var/backups/monitor/db-1-20261008-031700.sql.gz\n", stderr: "")
        let control = ServerControl(server: Fixtures.server, ssh: ssh)
        let file = try await control.backup(container: "db-1", engine: "postgresql")
        XCTAssertEqual(file, "/var/backups/monitor/db-1-20261008-031700.sql.gz")
        XCTAssertTrue(ssh.commands[0].contains("tee /usr/local/sbin/monitor-backup"))
        XCTAssertTrue(ssh.commands[0].hasSuffix("$S /usr/local/sbin/monitor-backup db-1 postgresql"))

        try await control.setNightlyBackup(container: "pg.main", engine: "mysql", on: true)
        XCTAssertTrue(ssh.commands[1].contains("/etc/cron.d/monitor-backup-pg_main"))
        XCTAssertTrue(ssh.commands[1].contains("17 3 * * * root /usr/local/sbin/monitor-backup pg.main mysql"))
        try await control.setNightlyBackup(container: "pg.main", engine: "mysql", on: false)
        XCTAssertTrue(ssh.commands[2].hasSuffix("$S rm -f /etc/cron.d/monitor-backup-pg_main"))

        for (c, e) in [("a;b", "postgresql"), ("db", "redis")] {
            do {
                try await control.backup(container: c, engine: e)
                XCTFail("accepted \(c) \(e)")
            } catch is ControlError {}
        }
        XCTAssertEqual(ssh.commands.count, 3)
        XCTAssertTrue(ServerControl.script.hasPrefix("#!/bin/sh\n"))
    }
}
