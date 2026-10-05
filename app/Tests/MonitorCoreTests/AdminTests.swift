import Foundation
import XCTest
@testable import MonitorCore

final class ConfigRepositoryTests: XCTestCase {
    var dir: URL!
    var url: URL { dir.appendingPathComponent("servers.json") }
    let token = String(repeating: "ab", count: 32)
    let fp = String(repeating: "AB:", count: 31) + "AB"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testPlaintextTokensMoveToSecretStore() async throws {
        let json = """
        {"servers":[{"id":"nl","name":"NL","host":"203.0.113.10","port":9443,"token":"\(token)",
                     "fingerprint":"\(fp)","thresholds":{"disk_percent":80}}],
         "sites":[{"id":"shop","name":"Магазин","url":"https://shop.example.com","from":["nl"]}]}
        """
        try Data(json.utf8).write(to: url)
        let secrets = MemorySecrets()
        let repo = ConfigRepository(url: url, secrets: secrets)

        let file = try await repo.load()
        XCTAssertEqual(file.servers[0].token, token)
        XCTAssertEqual(try secrets.get(SecretKey.agentToken("nl")), token)
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(onDisk.contains(token), onDisk)
        XCTAssertTrue(onDisk.contains("\"disk_percent\" : 80"), onDisk)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        // Reading again takes the token from the store.
        let again = try await repo.load()
        XCTAssertEqual(again.servers[0].token, token)
        XCTAssertEqual(again.servers[0].thresholds?.diskPercent, 80)
        XCTAssertEqual(again.sites?.first?.from, ["nl"])
    }

    func testAddEditRemove() async throws {
        try Data(ServersFile.example.utf8).write(to: url)
        let secrets = MemorySecrets()
        let repo = ConfigRepository(url: url, secrets: secrets)

        var nl = ServerConfig(id: "nl", name: "Нидерланды", host: "203.0.113.10", token: token, fingerprint: fp)
        try await repo.upsertServer(nl)
        try await repo.upsertServer(ServerConfig(id: "us", name: "США", host: "198.51.100.7", token: token,
                                                 fingerprint: fp))
        try await repo.upsertSite(SiteConfig(id: "shop", name: "Магазин", url: "https://shop.example.com",
                                             from: ["nl", "us"]))
        nl.name = "NL-1"
        var file = try await repo.upsertServer(nl)
        XCTAssertEqual(file.servers.map(\.name), ["NL-1", "США"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".bak"))

        // A broken site is refused and the file stays as it was.
        do {
            try await repo.upsertSite(SiteConfig(id: "bad", name: "Плохой", url: "ftp://x", from: nil))
            XCTFail("expected validation error")
        } catch {}
        let kept = try await repo.load()
        XCTAssertEqual(kept.sites?.map(\.id), ["shop"])

        file = try await repo.removeServer(id: "us")
        XCTAssertEqual(file.servers.map(\.id), ["nl"])
        XCTAssertEqual(file.sites?.first?.from, ["nl"])
        XCTAssertNil(try secrets.get(SecretKey.agentToken("us")))

        file = try await repo.removeServer(id: "nl")
        XCTAssertNil(file.sites?.first?.from) // checked from all servers again
        file = try await repo.removeSite(id: "shop")
        XCTAssertEqual(file.sites?.count, 0)
    }

    func testMissingTokenCanStillBeReplacedOrDeleted() async throws {
        let json = #"{"servers":[{"id":"nl","name":"NL","host":"h","port":9443,"fingerprint":"\#(fp)"}]}"#
        try Data(json.utf8).write(to: url)
        let repo = ConfigRepository(url: url, secrets: MemorySecrets())
        do { _ = try await repo.load(); XCTFail("expected missing token") } catch {
            XCTAssertTrue("\(error)".contains("Связке ключей"), "\(error)")
        }
        let fixed = try await repo.upsertServer(ServerConfig(id: "nl", name: "NL", host: "h", token: token,
                                                             fingerprint: fp))
        XCTAssertEqual(fixed.servers.first?.token, token)
    }

    func testNewIDs() {
        let file = ServersFile(servers: [Fixtures.server], sites: [SiteConfig(id: "shop", name: "", url: "")])
        XCTAssertEqual(file.newServerID(from: "155.212.164.127"), "155-212-164-127")
        XCTAssertEqual(file.newServerID(from: "Нидерланды"), "srv")
        XCTAssertEqual(file.newServerID(from: "NL"), "nl-2")
        XCTAssertEqual(file.newSiteID(from: "shop"), "shop-2")
    }
}

final class SSHConfigTests: XCTestCase {
    let config = """
    Host *
      ServerAliveInterval 30
    Host us vultr-us
      HostName 149.28.225.248
      User root
      IdentityFile ~/.ssh/id_ed25519_arpm
    Host wise1
      HostName=155.212.164.127
      Port 2222
    Match host foo
      User nobody
    """

    func testParse() {
        let e = SSHConfigFile.parse(config)
        XCTAssertEqual(e.map(\.alias), ["us", "vultr-us", "wise1"])
        XCTAssertEqual(e[0].identityFile, "~/.ssh/id_ed25519_arpm")
        XCTAssertEqual(e[2].port, 2222)
        XCTAssertEqual(e[2].hostName, "155.212.164.127")
    }

    func testTargetForTypedHost() {
        let e = SSHConfigFile.parse(config)
        let byIP = SSHConfigFile.target(forHost: "149.28.225.248", entries: e)
        XCTAssertEqual(byIP.identityFile, "~/.ssh/id_ed25519_arpm")
        XCTAssertEqual(byIP.user, "root")
        XCTAssertEqual(SSHConfigFile.target(forHost: "wise1", entries: e).port, 2222)
        XCTAssertEqual(SSHConfigFile.target(forHost: "203.0.113.1", entries: e), SSHTarget(host: "203.0.113.1"))
        let opts = byIP.options()
        XCTAssertTrue(opts.contains("IdentitiesOnly=yes"))
        XCTAssertEqual(SSHTarget(host: "h", port: 2222).options(forSCP: true), ["-P", "2222"])
    }

    func testErrorsAreReadable() {
        XCTAssertTrue(SSHError.from(stderr: "root@1.2.3.4: Permission denied (publickey).", host: "1.2.3.4")
            .description.contains("не принял"))
        XCTAssertTrue(SSHError.from(stderr: "ssh: connect to host 1.2.3.4 port 22: Operation timed out",
                                    host: "1.2.3.4").description.contains("не отвечает"))
    }
}

final class FakeSSH: SSHRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [String] = []
    private var _uploads: [String] = []
    var commands: [String] { lock.withLock { _commands } }
    var uploads: [String] { lock.withLock { _uploads } }
    var uid = "0"
    var existingAgent = false
    let token = String(repeating: "cd", count: 32)
    let fingerprint = String(repeating: "EF:", count: 31) + "EF"

    func run(_ target: SSHTarget, password: String?, command: String, stdin: Data?) async throws -> SSHOutput {
        lock.withLock { _commands.append(command) }
        func ok(_ s: String) -> SSHOutput { SSHOutput(status: 0, stdout: s, stderr: "") }
        if command.contains("uname -m") {
            return ok("arch=x86_64\nuid=\(uid)\nsystemd=ok\n\(existingAgent ? "agent=yes\n" : "")os=Ubuntu 24.04 LTS\n")
        }
        if command.hasPrefix("mktemp") { return ok("/tmp/monitor-agent-install.Ab12\n") }
        if command.contains("install.sh") {
            return ok("config: \(existingAgent ? "kept (existing token and certificate)" : "created")\n"
                      + "monitor-agent 3-merge installed and running\nfingerprint: \(fingerprint)\n")
        }
        if command.contains("cat /etc/monitor-agent/config.json") {
            return ok(#"{"listen":":9443","token":"\#(token)","cert_file":"/etc/monitor-agent/cert.pem"}"#)
        }
        if command.contains("ufw") { return ok("opened\n") }
        return ok("")
    }

    func upload(_ target: SSHTarget, password: String?, files: [URL], to remoteDir: String) async throws {
        lock.withLock { _uploads += files.map(\.lastPathComponent) }
    }

    func resolveHost(_ target: SSHTarget) async -> String { "203.0.113.10" }
    func close(_ target: SSHTarget) async {}
}

final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _steps: [(InstallStep, StepState)] = []
    var steps: [(InstallStep, StepState)] { lock.withLock { _steps } }
    func add(_ s: InstallStep, _ st: StepState) { lock.withLock { _steps.append((s, st)) } }
    func final(_ s: InstallStep) -> StepState? { steps.last { $0.0 == s }?.1 }
}

final class AgentInstallerTests: XCTestCase {
    var bundle: URL!

    override func setUpWithError() throws {
        bundle = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        for f in ["monitor-agent-linux-amd64", "monitor-agent-linux-arm64", "monitor-agent.service",
                  "install.sh", "SHA256SUMS"] {
            try Data("x".utf8).write(to: bundle.appendingPathComponent(f))
        }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: bundle) }

    func testFirstInstall() async throws {
        let ssh = FakeSSH()
        let log = StepLog()
        let installer = AgentInstaller(client: AgentClient(transport: FakeAgent()), ssh: ssh, bundle: bundle)
        let r = try await installer.install(SSHTarget(host: "us"), password: nil) { log.add($0, $1) }

        XCTAssertEqual(r.host, "203.0.113.10")
        XCTAssertEqual(r.port, 9443)
        XCTAssertEqual(r.token, ssh.token)
        XCTAssertEqual(r.fingerprint, ssh.fingerprint)
        XCTAssertEqual(r.version, "3-merge")
        XCTAssertFalse(r.upgraded)
        XCTAssertTrue(r.firewallOpened)
        XCTAssertTrue(r.verified)
        XCTAssertEqual(ssh.uploads, ["monitor-agent-linux-amd64", "monitor-agent.service", "install.sh", "SHA256SUMS"])
        // Root needs no sudo; the temp dir is cleaned up in the same command.
        let install = ssh.commands.first { $0.contains("install.sh") }!
        XCTAssertTrue(install.hasPrefix("bash /tmp/monitor-agent-install.Ab12/install.sh"), install)
        XCTAssertTrue(install.contains("rm -rf /tmp/monitor-agent-install.Ab12"))
        for step in InstallStep.allCases {
            switch log.final(step) {
            case .done?: break
            case let other: XCTFail("\(step): \(String(describing: other))")
            }
        }
        let server = r.server(id: "us", name: "США")
        XCTAssertNoThrow(try ServersFile(servers: [server]).validate())
    }

    func testNeedsRootOrSudo() async {
        let ssh = FakeSSH()
        ssh.uid = "1000"
        let log = StepLog()
        let installer = AgentInstaller(client: AgentClient(transport: FakeAgent()), ssh: ssh, bundle: bundle)
        do {
            _ = try await installer.install(SSHTarget(host: "h", user: "ubuntu"), password: nil) { log.add($0, $1) }
            XCTFail("expected failure")
        } catch let e as InstallError {
            XCTAssertEqual(e.step, .connect)
            XCTAssertTrue(e.message.contains("sudo"))
        } catch { XCTFail("\(error)") }
        if case .failed? = log.final(.connect) {} else { XCTFail("connect not marked failed") }
        XCTAssertTrue(ssh.uploads.isEmpty)
    }

    func testUnreachableAgentIsReportedNotThrown() async throws {
        let agent = FakeAgent()
        agent.down = true
        let ssh = FakeSSH()
        ssh.existingAgent = true
        let log = StepLog()
        let installer = AgentInstaller(client: AgentClient(transport: agent), ssh: ssh, bundle: bundle,
                                       verifyDelays: [])
        let r = try await installer.install(SSHTarget(host: "h"), password: nil) { log.add($0, $1) }
        XCTAssertTrue(r.upgraded)
        XCTAssertFalse(r.verified)
        XCTAssertEqual(r.token, ssh.token) // recovered from the server
        if case .failed(let why)? = log.final(.verify) {
            XCTAssertTrue(why.contains("хостера"), why)
        } else { XCTFail("verify not marked failed") }
    }

    func testMissingBundle() async {
        let installer = AgentInstaller(client: AgentClient(transport: FakeAgent()), ssh: FakeSSH(), bundle: nil)
        do {
            _ = try await installer.install(SSHTarget(host: "h"), password: nil) { _, _ in }
            XCTFail("expected failure")
        } catch let e as InstallError {
            XCTAssertEqual(e.step, .prepare)
        } catch { XCTFail("\(error)") }
    }

    func testHelpers() {
        XCTAssertEqual(AgentInstaller.randomToken().count, 64)
        XCTAssertEqual(AgentInstaller.quote("a'b"), #"'a'\''b'"#)
        XCTAssertEqual(AgentInstaller.agentConfig(#"{"listen":":9555","token":"\#(String(repeating: "a", count: 64))"}"#)?.port, 9555)
        XCTAssertNil(AgentInstaller.agentConfig(#"{"token":"short"}"#))
    }
}

final class ProcessSSHTests: XCTestCase {
    /// A stand-in for /usr/bin/ssh that echoes what it was given.
    func testRunPassesOptionsStdinAndPassword() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("ssh")
        let script = """
        #!/bin/sh
        echo "args=$*"
        echo "askpass=$("$SSH_ASKPASS" 2>/dev/null)"
        echo "stdin=$(cat)"
        if echo "$*" | grep -q fail; then echo "Permission denied (publickey)." >&2; exit 255; fi
        exit 3
        """
        FileManager.default.createFile(atPath: fake.path, contents: Data(script.utf8),
                                       attributes: [.posixPermissions: 0o755])
        let ssh = ProcessSSH(sshPath: fake.path, scpPath: fake.path, timeout: 10)
        let out = try await ssh.run(SSHTarget(host: "h", port: 2222, user: "root"), password: "s3cret",
                                    command: "echo hi", stdin: Data("tok".utf8))
        XCTAssertEqual(out.status, 3)
        XCTAssertTrue(out.stdout.contains("-p 2222 -o User=root"), out.stdout)
        XCTAssertTrue(out.stdout.contains("NumberOfPasswordPrompts=1"), out.stdout)
        XCTAssertTrue(out.stdout.contains("h echo hi"), out.stdout)
        XCTAssertTrue(out.stdout.contains("askpass=s3cret"), out.stdout)
        XCTAssertTrue(out.stdout.contains("stdin=tok"), out.stdout)
        XCTAssertFalse(out.stdout.contains("args=") && out.stdout.contains("s3cret -"), "password on command line")

        let batch = try await ssh.run(SSHTarget(host: "h"), password: nil, command: "true", stdin: nil)
        XCTAssertTrue(batch.stdout.contains("BatchMode=yes"), batch.stdout)

        do {
            _ = try await ssh.run(SSHTarget(host: "fail"), password: nil, command: "true", stdin: nil)
            XCTFail("expected SSHError")
        } catch let e as SSHError {
            XCTAssertTrue(e.description.contains("не принял"), e.description)
        }
    }
}
