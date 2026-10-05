import Foundation

/// The agent install bundle shipped inside Monitor.app (Contents/Resources/agent):
/// Linux binaries, install.sh, the systemd unit and SHA256SUMS.
public enum AgentBundle {
    public static var url: URL? {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("agent", isDirectory: true),
              FileManager.default.fileExists(atPath: dir.appendingPathComponent("install.sh").path)
        else { return nil }
        return dir
    }
}

public enum InstallStep: String, CaseIterable, Sendable {
    case connect, prepare, upload, install, firewall, verify

    public var title: String {
        switch self {
        case .connect: return "Подключение по SSH"
        case .prepare: return "Подготовка"
        case .upload: return "Копирование агента"
        case .install: return "Установка службы"
        case .firewall: return "Открытие порта"
        case .verify: return "Проверка связи с агентом"
        }
    }
}

public enum StepState: Equatable, Sendable {
    case running
    case done(String?)
    case skipped(String)
    case failed(String)
}

public struct InstallResult: Equatable, Sendable {
    /// Address the app should poll (HostName when an ssh alias was used).
    public var host: String
    public var port: Int
    public var token: String
    public var fingerprint: String
    public var version: String
    /// The agent was already there; its token and certificate were kept.
    public var upgraded: Bool
    public var firewallOpened: Bool
    /// The Mac reached the agent with this token and fingerprint. False
    /// usually means a hosting firewall in front of the server.
    public var verified: Bool

    /// A server entry ready for `ConfigRepository.upsertServer`.
    public func server(id: String, name: String, group: String? = nil, tags: [String]? = nil) -> ServerConfig {
        ServerConfig(id: id, name: name, host: host, port: port, token: token, fingerprint: fingerprint,
                     group: group, tags: tags)
    }
}

/// Installs or upgrades the agent on a server over SSH from the Mac, the same
/// steps as agent/scripts/remote-install.sh, then reads back the token and
/// certificate fingerprint so nothing has to be copied by hand.
public actor AgentInstaller {
    private let client: AgentClient
    private let ssh: SSHRunner
    private let bundle: URL?
    /// Pause between connection attempts while the agent starts.
    private let verifyDelays: [UInt64]

    public init(client: AgentClient, ssh: SSHRunner = ProcessSSH(), bundle: URL? = AgentBundle.url,
                verifyDelays: [UInt64] = [1, 2, 3, 4].map { $0 * 1_000_000_000 }) {
        self.client = client
        self.ssh = ssh
        self.bundle = bundle
        self.verifyDelays = verifyDelays
    }

    static let confPath = "/etc/monitor-agent/config.json"

    /// Throws `InstallError` naming the failed step; `progress` has already
    /// been told `.failed` for it.
    public func install(_ target: SSHTarget, password: String?, agentPort: Int = 9443,
                        progress: @escaping @Sendable (InstallStep, StepState) -> Void) async throws -> InstallResult {
        var step = InstallStep.connect
        defer { Task { [ssh] in await ssh.close(target) } }
        do {
            // connect: who we are, what the server is, whether the agent is there.
            progress(.connect, .running)
            let probe = try await sh(target, password, """
                echo "arch=$(uname -m)"; echo "uid=$(id -u)"
                if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then echo sudo=ok; fi
                if command -v systemctl >/dev/null 2>&1; then echo systemd=ok; fi
                if [ -f \(Self.confPath) ]; then echo agent=yes; fi
                . /etc/os-release 2>/dev/null && echo "os=$PRETTY_NAME"
                """)
            let facts = Self.keyValues(probe.stdout)
            let root = facts["uid"] == "0"
            guard root || facts["sudo"] == "ok" else {
                throw InstallError(step, "нужен вход под root или пользователь с sudo без пароля")
            }
            guard facts["systemd"] == "ok" else { throw InstallError(step, "на сервере нет systemd") }
            let arch: String
            switch facts["arch"] {
            case "x86_64": arch = "amd64"
            case "aarch64", "arm64": arch = "arm64"
            default: throw InstallError(step, "процессор \(facts["arch"] ?? "?") не поддерживается")
            }
            let upgrading = facts["agent"] == "yes"
            progress(.connect, .done([facts["os"], facts["arch"]].compactMap { $0 }.joined(separator: ", ")))
            let sudo = root ? "" : "sudo -n "

            // prepare: local bundle, remote temp dir, the new token (used only on first install).
            step = .prepare
            progress(.prepare, .running)
            guard let bundle else { throw InstallError(step, "в приложении нет файлов агента, соберите его заново") }
            let files = ["monitor-agent-linux-\(arch)", "monitor-agent.service", "install.sh", "SHA256SUMS"]
                .map { bundle.appendingPathComponent($0) }
            for f in files where !FileManager.default.fileExists(atPath: f.path) {
                throw InstallError(step, "в приложении нет файла \(f.lastPathComponent)")
            }
            let dir = try await sh(target, password, "mktemp -d /tmp/monitor-agent-install.XXXXXX")
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard dir.hasPrefix("/tmp/monitor-agent-install.") else {
                throw InstallError(step, "не удалось создать временную папку на сервере")
            }
            let newToken = Self.randomToken()
            _ = try await sh(target, password, "umask 077 && cat > \(dir)/token",
                             stdin: Data((newToken + "\n").utf8))
            progress(.prepare, .done(upgrading ? "агент уже установлен, обновлю его" : nil))

            step = .upload
            progress(.upload, .running)
            try await ssh.upload(target, password: password, files: files, to: dir)
            progress(.upload, .done(nil))

            // install: the temp dir (with the token) is removed whatever happens.
            step = .install
            progress(.install, .running)
            let host = await ssh.resolveHost(target)
            let out = try await ssh.run(target, password: password, command: """
                \(sudo)bash \(dir)/install.sh --token-file \(dir)/token --port \(agentPort) --host \(Self.quote(host))
                rc=$?; rm -rf \(dir); exit $rc
                """, stdin: nil)
            guard out.status == 0 else {
                let why = (out.stderr + out.stdout).split(whereSeparator: \.isNewline).last.map(String.init)
                throw InstallError(step, "установка не удалась: \(why ?? "код \(out.status)")")
            }
            let lines = Self.keyValues(out.stdout, separator: ":")
            guard let fingerprint = lines["fingerprint"], Fingerprint.bytes(fingerprint) != nil else {
                throw InstallError(step, "установщик не сообщил отпечаток сертификата")
            }
            // The token from the agent's own config: on an upgrade it is the
            // old one, which the Mac may have lost.
            let conf = try await sh(target, password, "\(sudo)cat \(Self.confPath)")
            guard let agentConf = Self.agentConfig(conf.stdout) else {
                throw InstallError(step, "не удалось прочитать токен агента")
            }
            let port = agentConf.port ?? agentPort
            let version = out.stdout.split(whereSeparator: \.isNewline)
                .first { $0.hasPrefix("monitor-agent ") && $0.contains("installed") }
                .map { $0.split(separator: " ")[1] }.map(String.init) ?? ""
            progress(.install, .done(version.isEmpty ? nil : "версия \(version)"))

            step = .firewall
            progress(.firewall, .running)
            let fw = try await sh(target, password, """
                if ! command -v ufw >/dev/null 2>&1 || ! \(sudo)ufw status | grep -q "Status: active"; then echo off
                elif \(sudo)ufw status | grep -Eq "^\(port)(/tcp)?[[:space:]]+ALLOW"; then echo open
                else \(sudo)ufw allow \(port)/tcp >/dev/null && echo opened; fi
                """).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            switch fw {
            case "opened": progress(.firewall, .done("открыл порт \(port) в ufw"))
            case "open": progress(.firewall, .skipped("порт \(port) уже открыт"))
            default: progress(.firewall, .skipped("ufw выключен"))
            }

            var result = InstallResult(host: host, port: port, token: agentConf.token, fingerprint: fingerprint,
                                       version: version, upgraded: upgrading, firewallOpened: fw == "opened",
                                       verified: false)

            // verify: the agent may need a moment after restart.
            step = .verify
            progress(.verify, .running)
            let server = result.server(id: "install-check", name: host)
            var lastError: Error?
            for delay in [0] + verifyDelays {
                if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                do {
                    let h = try await client.health(server)
                    result.verified = true
                    if result.version.isEmpty { result.version = h.version }
                    break
                } catch {
                    lastError = error
                }
            }
            if result.verified {
                progress(.verify, .done(nil))
            } else {
                progress(.verify, .failed("агент работает, но с этого Mac порт \(port) недоступен. "
                                          + "Проверьте файрвол в панели хостера. "
                                          + "(\(lastError.map { "\($0)" } ?? "нет ответа"))"))
            }
            return result
        } catch let e as InstallError {
            progress(e.step, .failed(e.message))
            throw e
        } catch {
            let e = InstallError(step, "\(error)")
            progress(step, .failed(e.message))
            throw e
        }
    }

    private func sh(_ t: SSHTarget, _ pw: String?, _ cmd: String, stdin: Data? = nil) async throws -> SSHOutput {
        let out = try await ssh.run(t, password: pw, command: cmd, stdin: stdin)
        guard out.status == 0 else {
            let why = out.stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "код \(out.status)"
            throw SSHError("команда на сервере не выполнилась: \(why)")
        }
        return out
    }

    static func keyValues(_ text: String, separator: Character = "=") -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let i = line.firstIndex(of: separator) else { continue }
            let k = line[..<i].trimmingCharacters(in: .whitespaces)
            if out[k] == nil { out[k] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces) }
        }
        return out
    }

    static func agentConfig(_ json: String) -> (token: String, port: Int?)? {
        struct Conf: Decodable { var token: String?; var listen: String? }
        guard let c = try? JSONDecoder().decode(Conf.self, from: Data(json.utf8)),
              let token = c.token, token.count >= 32 else { return nil }
        let port = c.listen.flatMap { $0.split(separator: ":").last }.flatMap { Int($0) }
        return (token, port)
    }

    static func randomToken() -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &g)) }.joined()
    }

    /// Single-quotes a value for the remote shell.
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

public struct InstallError: Error, CustomStringConvertible, Sendable {
    public var step: InstallStep
    public var message: String
    init(_ step: InstallStep, _ message: String) { self.step = step; self.message = message }
    public var description: String { "\(step.title): \(message)" }
}
