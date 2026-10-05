import Foundation

/// Restarts a container or reboots a server over SSH. Like the VPN keys this
/// runs from the Mac with the user's SSH access; the agent stays read-only.
public actor ServerControl {
    private let ssh: SSHRunner
    private let target: SSHTarget
    private let password: String?

    public init(ssh: SSHRunner = ProcessSSH(), target: SSHTarget, password: String? = nil) {
        self.ssh = ssh
        self.target = target
        self.password = password
    }

    public init(server: ServerConfig, ssh: SSHRunner = ProcessSSH(), password: String? = nil) {
        self.init(ssh: ssh, target: server.sshTarget, password: password)
    }

    /// Root needs no sudo; anyone else needs passwordless sudo.
    static let sudo = "if [ \"$(id -u)\" = 0 ]; then S=; else S='sudo -n'; fi; "

    public func restartContainer(_ name: String) async throws {
        guard Self.isSafeName(name) else { throw ControlError("странное имя контейнера \(name)") }
        try await run(Self.sudo + "$S docker restart \(name) >/dev/null", what: "перезапуск \(name)")
    }

    /// Schedules the reboot a moment later and returns at once, so the SSH
    /// session ends cleanly instead of being cut by the reboot.
    public func reboot() async throws {
        try await run(Self.sudo + "$S nohup sh -c 'sleep 2; systemctl reboot' >/dev/null 2>&1 &",
                      what: "перезагрузка")
    }

    private func run(_ command: String, what: String) async throws {
        let out = try await ssh.run(target, password: password, command: command, stdin: nil)
        guard out.status == 0 else {
            let why = out.stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "код \(out.status)"
            if why.contains("a password is required") {
                throw ControlError("\(what): пользователю \(target.user ?? "root") нужен sudo без пароля")
            }
            throw ControlError("\(what) не удалась: \(why)")
        }
    }

    static func isSafeName(_ s: String) -> Bool {
        !s.isEmpty && !s.hasPrefix("-") && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }
}

public struct ControlError: Error, CustomStringConvertible, LocalizedError, Sendable {
    public var description: String
    public init(_ d: String) { description = d }
    public var errorDescription: String? { description }
}
