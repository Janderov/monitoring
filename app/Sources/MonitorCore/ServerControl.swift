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

    /// Installs the backup script, dumps the container now and returns the
    /// file it wrote. The newest 7 dumps of each container are kept.
    @discardableResult
    public func backup(container: String, engine: String) async throws -> String {
        guard Self.isSafeName(container) else { throw ControlError("странное имя контейнера \(container)") }
        guard Self.engines.contains(engine) else { throw ControlError("бэкап \(engine) не поддерживается") }
        let out = try await run(Self.sudo + Self.installScript + " && $S \(Self.scriptPath) \(container) \(engine)",
                                what: "бэкап \(container)", stdin: Data(Self.script.utf8))
        return out.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
    }

    /// A cron job that dumps the container every night at 03:17 server time.
    public func setNightlyBackup(container: String, engine: String, on: Bool) async throws {
        guard Self.isSafeName(container) else { throw ControlError("странное имя контейнера \(container)") }
        guard Self.engines.contains(engine) else { throw ControlError("бэкап \(engine) не поддерживается") }
        let cron = "/etc/cron.d/" + Self.cronName(container)
        if on {
            let line = "17 3 * * * root \(Self.scriptPath) \(container) \(engine) >/dev/null 2>&1\n"
            try await run(Self.sudo + Self.installScript + " && printf '%s' '\(line)' | $S tee \(cron) >/dev/null && $S chmod 644 \(cron)",
                          what: "ночной бэкап \(container)", stdin: Data(Self.script.utf8))
        } else {
            try await run(Self.sudo + "$S rm -f \(cron)", what: "отключение ночного бэкапа \(container)")
        }
    }

    static let engines: Set<String> = ["postgresql", "mysql"]
    static let scriptPath = "/usr/local/sbin/monitor-backup"
    /// Reads the script from stdin into place.
    static let installScript = "$S tee \(scriptPath) >/dev/null && $S chmod 755 \(scriptPath)"

    /// cron skips files with dots in /etc/cron.d.
    static func cronName(_ container: String) -> String {
        "monitor-backup-" + container.replacingOccurrences(of: ".", with: "_")
    }

    /// Dumps one database container into /var/backups/monitor. A failed dump
    /// leaves no file behind, so an empty dump never looks like a backup.
    static let script = """
    #!/bin/sh
    # monitor-backup <container> <postgresql|mysql>: dump one database
    # container into /var/backups/monitor and keep the newest 7.
    # Written by the monitoring app on the Mac.
    set -eu
    c="$1"; e="$2"; d=/var/backups/monitor
    mkdir -p "$d"; chmod 755 "$d"
    tmp="$d/.tmp-$c"; f="$d/$c-$(date -u +%Y%m%d-%H%M%S).sql.gz"
    trap 'rm -f "$tmp" "$f.part"' EXIT
    if [ "$e" = mysql ]; then
      docker exec "$c" sh -c 'exec mysqldump --all-databases --single-transaction -uroot -p"$MYSQL_ROOT_PASSWORD"' > "$tmp"
    else
      docker exec "$c" sh -c 'exec pg_dumpall -U "${POSTGRES_USER:-postgres}"' > "$tmp"
    fi
    [ -s "$tmp" ] || { echo "пустой дамп" >&2; exit 1; }
    gzip -c "$tmp" > "$f.part"
    chmod 640 "$f.part"
    mv "$f.part" "$f"
    ls -1t "$d/$c"-*.sql.gz | tail -n +8 | xargs -r rm -f --
    echo "$f"

    """

    @discardableResult
    private func run(_ command: String, what: String, stdin: Data? = nil) async throws -> String {
        let out = try await ssh.run(target, password: password, command: command, stdin: stdin)
        guard out.status == 0 else {
            let why = out.stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "код \(out.status)"
            if why.contains("a password is required") {
                throw ControlError("\(what): пользователю \(target.user ?? "root") нужен sudo без пароля")
            }
            throw ControlError("\(what) не удалась: \(why)")
        }
        return out.stdout
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
