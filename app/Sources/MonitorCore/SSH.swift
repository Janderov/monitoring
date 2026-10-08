import Foundation

/// How to log in to a server over SSH. Anything left out comes from
/// ~/.ssh/config, the same as typing `ssh host` in Terminal.
public struct SSHTarget: Codable, Equatable, Sendable {
    /// IP, name, or a Host alias from ~/.ssh/config.
    public var host: String
    public var port: Int?
    public var user: String?
    /// Private key path; `~` is allowed.
    public var identityFile: String?

    public init(host: String, port: Int? = nil, user: String? = nil, identityFile: String? = nil) {
        self.host = host; self.port = port; self.user = user; self.identityFile = identityFile
    }

    enum CodingKeys: String, CodingKey { case host, port, user, identityFile }

    /// Options for ssh(1); scp(1) takes the same ones except the port flag.
    func options(forSCP: Bool = false) -> [String] {
        var out: [String] = []
        if let port { out += [forSCP ? "-P" : "-p", String(port)] }
        if let user, !user.isEmpty { out += ["-o", "User=\(user)"] }
        if let identityFile, !identityFile.isEmpty {
            out += ["-i", (identityFile as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"]
        }
        return out
    }
}

// MARK: - ~/.ssh/config

/// One `Host` block of ~/.ssh/config, for prefilling the add-server form.
public struct SSHConfigEntry: Equatable, Sendable {
    public var alias: String
    public var hostName: String?
    public var user: String?
    public var port: Int?
    public var identityFile: String?
}

public enum SSHConfigFile {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
    }

    public static func entries(at url: URL = defaultURL) -> [SSHConfigEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }

    /// Host blocks without wildcards; `Match` blocks and includes are ignored.
    public static func parse(_ text: String) -> [SSHConfigEntry] {
        var out: [SSHConfigEntry] = []
        var current: [SSHConfigEntry] = []
        func flush() { out += current; current = [] }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t=\""))
            switch key {
            case "host":
                flush()
                current = value.split(separator: " ").map(String.init)
                    .filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }
                    .map { SSHConfigEntry(alias: $0) }
            case "match":
                flush()
            default:
                for i in current.indices {
                    switch key {
                    case "hostname": current[i].hostName = current[i].hostName ?? value
                    case "user": current[i].user = current[i].user ?? value
                    case "port": current[i].port = current[i].port ?? Int(value)
                    case "identityfile": current[i].identityFile = current[i].identityFile ?? value
                    default: break
                    }
                }
            }
        }
        flush()
        return out
    }

    /// A target for what was typed in the form. When an entry's alias or
    /// HostName matches, its user, port and key are filled in, so typing the
    /// IP of a server that has an alias still uses the right key.
    public static func target(forHost host: String, entries: [SSHConfigEntry]? = nil) -> SSHTarget {
        let list = entries ?? self.entries()
        let h = host.trimmingCharacters(in: .whitespaces)
        if let e = list.first(where: { $0.alias == h }) {
            // ssh applies the alias itself; only report what it will use.
            return SSHTarget(host: h, port: e.port, user: e.user, identityFile: e.identityFile)
        }
        if let e = list.first(where: { $0.hostName?.lowercased() == h.lowercased() }) {
            return SSHTarget(host: h, port: e.port, user: e.user, identityFile: e.identityFile)
        }
        return SSHTarget(host: h)
    }
}

public enum SSHKeys {
    /// Private keys in ~/.ssh: files that have a matching .pub next to them.
    public static func list(in dir: URL = FileManager.default.homeDirectoryForCurrentUser
                                .appendingPathComponent(".ssh")) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let set = Set(names)
        return names.filter { !$0.hasSuffix(".pub") && set.contains($0 + ".pub") }
            .sorted()
            .map { "~/.ssh/" + $0 }
    }
}

// MARK: - running ssh

public struct SSHOutput: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
}

/// Runs commands on a server. The real one calls /usr/bin/ssh and scp;
/// tests substitute a fake.
public protocol SSHRunner: Sendable {
    /// Runs a shell command on the server. A non-zero exit is returned, not
    /// thrown; failing to connect throws `SSHError`.
    func run(_ target: SSHTarget, password: String?, command: String, stdin: Data?) async throws -> SSHOutput
    /// Copies local files into a directory on the server.
    func upload(_ target: SSHTarget, password: String?, files: [URL], to remoteDir: String) async throws
    /// The address ssh actually connects to (HostName from ~/.ssh/config).
    func resolveHost(_ target: SSHTarget) async -> String
    /// Closes the shared connection, if any.
    func close(_ target: SSHTarget) async
}

public struct SSHError: Error, CustomStringConvertible, Equatable, Sendable {
    public var description: String
    public init(_ d: String) { description = d }

    /// A readable reason from ssh's stderr.
    public static func from(stderr: String, host: String) -> SSHError {
        let s = stderr.lowercased()
        if s.contains("remote host identification has changed") {
            return SSHError("ключ сервера \(host) изменился с прошлого входа. Если сервер переустанавливали, "
                            + "удалите старую запись: ssh-keygen -R \(host)")
        }
        if s.contains("permission denied") || s.contains("too many authentication failures") {
            return SSHError("сервер \(host) не принял ключ или пароль")
        }
        if s.contains("could not resolve hostname") { return SSHError("не удалось найти адрес \(host)") }
        if s.contains("connection refused") { return SSHError("\(host) отклонил подключение по SSH") }
        if s.contains("timed out") || s.contains("no route to host") || s.contains("network is unreachable") {
            return SSHError("\(host) не отвечает по SSH")
        }
        if s.contains("host key verification failed") {
            return SSHError("не удалось проверить ключ сервера \(host)")
        }
        let last = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "неизвестная ошибка"
        return SSHError("SSH \(host): \(last)")
    }
}

/// /usr/bin/ssh with a shared connection per server, so a password is typed
/// once per install. Without a password ssh runs in batch mode and fails fast
/// instead of waiting for input nobody can give. New host keys are accepted
/// on first contact and checked afterwards, like answering "yes" in Terminal.
public final class ProcessSSH: SSHRunner, @unchecked Sendable {
    private let sshPath: String
    private let scpPath: String
    private let timeout: TimeInterval
    /// Short path: the control socket path must fit in 104 bytes on macOS.
    private let controlDir: String

    public init(sshPath: String = "/usr/bin/ssh", scpPath: String = "/usr/bin/scp", timeout: TimeInterval = 300) {
        self.sshPath = sshPath
        self.scpPath = scpPath
        self.timeout = timeout
        controlDir = "/tmp/monitor-ssh-\(getuid())"
    }

    private func common(_ target: SSHTarget, password: String?, forSCP: Bool = false) -> [String] {
        try? FileManager.default.createDirectory(atPath: controlDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        var args = target.options(forSCP: forSCP)
        args += ["-o", "StrictHostKeyChecking=accept-new",
                 "-o", "ConnectTimeout=15",
                 "-o", "ServerAliveInterval=15",
                 "-o", "ControlMaster=auto",
                 "-o", "ControlPath=\(controlDir)/%C",
                 "-o", "ControlPersist=60"]
        args += password == nil ? ["-o", "BatchMode=yes"] : ["-o", "NumberOfPasswordPrompts=1"]
        return args
    }

    public func run(_ target: SSHTarget, password: String?, command: String, stdin: Data?) async throws -> SSHOutput {
        let out = try await exec(sshPath, common(target, password: password) + [target.host, command],
                                 password: password, stdin: stdin)
        // 255 is ssh's own failure (connection, auth), not the command's.
        if out.status == 255 { throw SSHError.from(stderr: out.stderr, host: target.host) }
        return out
    }

    public func upload(_ target: SSHTarget, password: String?, files: [URL], to remoteDir: String) async throws {
        let dest = "\(target.host.contains(":") ? "[\(target.host)]" : target.host):\(remoteDir)/"
        let out = try await exec(scpPath, ["-q"] + common(target, password: password, forSCP: true)
                                    + files.map(\.path) + [dest], password: password, stdin: nil)
        if out.status != 0 {
            if out.stderr.lowercased().contains("permission denied"), !out.stderr.contains("ssh:") {
                throw SSHError("не удалось скопировать файлы в \(remoteDir): нет прав")
            }
            throw SSHError.from(stderr: out.stderr, host: target.host)
        }
    }

    public func resolveHost(_ target: SSHTarget) async -> String {
        let out = try? await exec(sshPath, ["-G"] + target.options() + [target.host], password: nil, stdin: nil)
        let line = out?.stdout.split(whereSeparator: \.isNewline).first { $0.hasPrefix("hostname ") }
        return line.map { String($0.dropFirst("hostname ".count)) } ?? target.host
    }

    public func close(_ target: SSHTarget) async {
        _ = try? await exec(sshPath, target.options() + ["-o", "ControlPath=\(controlDir)/%C", "-O", "exit",
                                                         target.host], password: nil, stdin: nil)
    }

    /// Runs a process with a deadline. A password reaches ssh through
    /// SSH_ASKPASS reading it from this process's environment; it is never on
    /// the command line or on disk.
    private func exec(_ path: String, _ args: [String], password: String?, stdin: Data?) async throws -> SSHOutput {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        var askpass: URL?
        if let password {
            let script = URL(fileURLWithPath: controlDir).appendingPathComponent("askpass-\(UUID().uuidString)")
            let body = "#!/bin/sh\nprintf '%s\\n' \"$MONITOR_SSH_PASSWORD\"\n"
            guard FileManager.default.createFile(atPath: script.path, contents: Data(body.utf8),
                                                 attributes: [.posixPermissions: 0o700]) else {
                throw SSHError("не удалось подготовить ввод пароля")
            }
            askpass = script
            env["SSH_ASKPASS"] = script.path
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = env["DISPLAY"] ?? ":0"
            env["MONITOR_SSH_PASSWORD"] = password
        }
        p.environment = env
        defer { if let askpass { try? FileManager.default.removeItem(at: askpass) } }

        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = inPipe
        let collected = Collected()

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SSHOutput, Error>) in
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                collected.setOut(outPipe.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                collected.setErr(errPipe.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }
            p.terminationHandler = { proc in
                group.notify(queue: .global()) {
                    let (o, e) = collected.values()
                    cont.resume(returning: SSHOutput(status: proc.terminationStatus,
                                                     stdout: String(decoding: o, as: UTF8.self),
                                                     stderr: String(decoding: e, as: UTF8.self)))
                }
            }
            do {
                try p.run()
            } catch {
                p.terminationHandler = nil
                cont.resume(throwing: SSHError("не удалось запустить \(path): \(error.localizedDescription)"))
                return
            }
            if let stdin { inPipe.fileHandleForWriting.write(stdin) }
            try? inPipe.fileHandleForWriting.close()
            let deadline = timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + deadline) {
                if p.isRunning { p.terminate() }
            }
        }
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data(), err = Data()
        func setOut(_ d: Data) { lock.withLock { out = d } }
        func setErr(_ d: Data) { lock.withLock { err = d } }
        func values() -> (Data, Data) { lock.withLock { (out, err) } }
    }
}

// MARK: - SSH in Terminal

/// The `ssh` command the SSH button runs in Terminal.
public enum TerminalSSH {
    /// Where to log in to a server: its saved SSH settings, else a
    /// ~/.ssh/config block for its address (so the key named there is used),
    /// else the address itself. `user` fills in a missing login name.
    public static func target(for server: ServerConfig, user: String, config: [SSHConfigEntry]) -> SSHTarget {
        if var t = server.ssh {
            if t.user?.isEmpty ?? true, !hasUser(t.host, config) { t.user = user }
            return t
        }
        if let e = config.first(where: { $0.hostName == server.host || $0.alias == server.host }) {
            return SSHTarget(host: e.alias, user: e.user == nil ? user : nil)
        }
        return SSHTarget(host: server.host, user: user)
    }

    private static func hasUser(_ host: String, _ config: [SSHConfigEntry]) -> Bool {
        config.contains { $0.alias == host && $0.user != nil }
    }

    /// `ssh … host`, shell-quoted; through `jump` (logging in there with its
    /// own settings) when the server's SSH port is closed on this network.
    public static func command(_ target: SSHTarget, jump: SSHTarget? = nil) -> String {
        var args = ["ssh"] + target.options()
        if let jump {
            let inner = (["ssh"] + jump.options() + ["-W", "%h:%p", jump.host]).map(quote).joined(separator: " ")
            args += ["-o", "ProxyCommand=" + inner]
        }
        args.append(target.host)
        return args.map(quote).joined(separator: " ")
    }

    /// Single quotes unless the word is plainly safe.
    public static func quote(_ s: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.,/:=@%+")
        if !s.isEmpty, s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
