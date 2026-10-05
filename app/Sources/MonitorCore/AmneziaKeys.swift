import Foundation

/// A client key of an AmneziaWG server, as the AmneziaVPN app lists it.
public struct AWGClient: Equatable, Identifiable, Sendable {
    public var id: String { publicKey }
    public var publicKey: String
    public var name: String
    /// Tunnel address, e.g. "10.8.1.5/32".
    public var address: String?
    public var created: String?
}

/// A new key ready to hand to a device: the AmneziaWG config text, which the
/// AmneziaVPN and AmneziaWG apps import as a file or as a QR code of the text.
public struct AWGNewClient: Equatable, Sendable {
    public var client: AWGClient
    public var config: String
    /// Suggested file name, e.g. "iphone-misha.conf".
    public var fileName: String
    /// The same key as an AmneziaVPN "vpn://" link, nil if it could not be built.
    public var amneziaLink: String? = nil
}

/// Creates and deletes AmneziaWG client keys in an AmneziaVPN container over
/// SSH from the Mac, the same edit the AmneziaVPN app makes: a [Peer] in the
/// server config plus a line in clientsTable, applied with `syncconf` so
/// connected clients are not dropped. Both files are backed up first (the
/// last five copies are kept) and restored if applying fails. The agent stays
/// read-only.
public actor AmneziaKeys {
    private let ssh: SSHRunner
    private let target: SSHTarget
    private let password: String?
    /// Address clients connect to; the server's public IP.
    private let endpointHost: String
    /// Shown as the server's name in the AmneziaVPN app after importing a link.
    private let serverName: String?

    public init(ssh: SSHRunner = ProcessSSH(), target: SSHTarget, password: String? = nil, endpointHost: String,
                serverName: String? = nil) {
        self.ssh = ssh
        self.target = target
        self.password = password
        self.endpointHost = endpointHost
        self.serverName = serverName
    }

    public init(server: ServerConfig, ssh: SSHRunner = ProcessSSH(), password: String? = nil) {
        self.init(ssh: ssh, target: server.sshTarget, password: password, endpointHost: server.host,
                  serverName: server.name)
    }

    public func list(container: String) async throws -> [AWGClient] {
        let state = try await read(container, newKeys: false)
        return state.clients
    }

    public func create(container: String, name: String) async throws -> AWGNewClient {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw AWGError("укажите имя ключа") }
        let state = try await read(container, newKeys: true)
        guard let keys = state.newKeys else { throw AWGError("сервер не выдал новые ключи") }
        guard let ip = state.config.freeAddress() else { throw AWGError("в подсети VPN не осталось свободных адресов") }
        let psk = state.psk ?? keys.psk

        var conf = state.config
        conf.addPeer(publicKey: keys.publicKey, presharedKey: psk, allowedIPs: "\(ip)/32")
        let table = try ClientsTable.adding(state.clientsTable, publicKey: keys.publicKey, name: clean,
                                            created: ClientsTable.dateString(Date()))
        try await write(container, state: state, conf: conf, table: table)

        let client = AWGClient(publicKey: keys.publicKey, name: clean, address: "\(ip)/32",
                               created: ClientsTable.dateString(Date()))
        let text = state.config.clientConfig(privateKey: keys.privateKey, address: "\(ip)/32",
                                             serverPublicKey: state.serverPublicKey, presharedKey: psk,
                                             endpoint: "\(endpointHost):\(state.config.listenPort ?? "51820")")
        let port = state.config.listenPort ?? "51820"
        var obfuscation: [String: String] = [:]
        for k in WGConfig.awgKeys { if let v = WGConfig.value(k, in: state.config.interface) { obfuscation[k] = v } }
        let link = try? AmneziaLink.make(.init(
            description: serverName ?? endpointHost, hostName: endpointHost, port: port, container: container,
            clientIP: ip, clientPrivateKey: keys.privateKey, clientPublicKey: keys.publicKey,
            presharedKey: psk, serverPublicKey: state.serverPublicKey, obfuscation: obfuscation, config: text))
        return AWGNewClient(client: client, config: text, fileName: Self.fileName(clean), amneziaLink: link)
    }

    public func delete(container: String, publicKey: String) async throws {
        let state = try await read(container, newKeys: false)
        var conf = state.config
        guard conf.removePeer(publicKey: publicKey) else { throw AWGError("такого ключа на сервере нет") }
        let table = try ClientsTable.removing(state.clientsTable, publicKey: publicKey)
        try await write(container, state: state, conf: conf, table: table)
    }

    // MARK: - remote side

    struct State {
        var dir: String
        var confPath: String
        var tool: String
        var config: WGConfig
        var clientsTable: String
        var serverPublicKey: String
        var psk: String?
        var newKeys: (privateKey: String, publicKey: String, psk: String)?

        var clients: [AWGClient] {
            let names = ClientsTable.entries(clientsTable)
            return config.peers.map { p in
                AWGClient(publicKey: p.publicKey, name: names[p.publicKey]?.name ?? "без имени",
                          address: p.allowedIPs, created: names[p.publicKey]?.created)
            }
        }
    }

    /// Runs a script inside the container as root.
    private func exec(_ container: String, _ script: String) async throws -> String {
        guard container.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }) else {
            throw AWGError("странное имя контейнера \(container)")
        }
        let cmd = "if [ \"$(id -u)\" = 0 ]; then S=; else S='sudo -n'; fi; $S docker exec -i \(container) sh -s"
        let out = try await ssh.run(target, password: password, command: cmd, stdin: Data(script.utf8))
        guard out.status == 0 else {
            let why = out.stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "код \(out.status)"
            throw AWGError("команда в контейнере \(container) не выполнилась: \(why)")
        }
        return out.stdout
    }

    static let locate = """
        T=$(ls /opt/amnezia/*/clientsTable 2>/dev/null | head -n 1)
        if [ -n "$T" ]; then D=$(dirname "$T"); else D=$(dirname "$(ls /opt/amnezia/*/*.conf | head -n 1)"); fi
        CONF=$(ls "$D"/*.conf | head -n 1)
        [ -f "$CONF" ] || { echo "no AmneziaWG config in /opt/amnezia" >&2; exit 1; }
        WG=wg; command -v awg >/dev/null 2>&1 && WG=awg
        IF=$(basename "$CONF" .conf)

        """

    private func read(_ container: String, newKeys: Bool) async throws -> State {
        let script = "set -e\n" + Self.locate + """
            echo "dir=$D"; echo "conf=$CONF"; echo "tool=$WG"
            echo "@@conf"; cat "$CONF"
            echo "@@clients"; cat "$D/clientsTable" 2>/dev/null || echo "[]"
            echo "@@serverpub"; cat "$D/wireguard_server_public_key.key" 2>/dev/null || $WG show "$IF" public-key
            echo "@@psk"; cat "$D/wireguard_psk.key" 2>/dev/null || true
            \(newKeys ? "echo \"@@keys\"; K=$($WG genkey); echo \"$K\"; echo \"$K\" | $WG pubkey; $WG genpsk" : "")
            echo "@@end"
            """
        return try Self.parseState(try await exec(container, script))
    }

    static func parseState(_ out: String) throws -> State {
        var head: [String: String] = [:]
        var parts: [String: [String]] = [:]
        var section: String?
        for line in out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("@@") { section = String(line.dropFirst(2)); parts[section!] = []; continue }
            if let s = section { parts[s, default: []].append(line) } else if let i = line.firstIndex(of: "=") {
                head[String(line[..<i])] = String(line[line.index(after: i)...])
            }
        }
        func text(_ k: String) -> String { (parts[k] ?? []).joined(separator: "\n") }
        func first(_ k: String) -> String? {
            (parts[k] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        }
        guard parts["end"] != nil, let dir = head["dir"], let conf = head["conf"], let tool = head["tool"],
              let pub = first("serverpub")
        else { throw AWGError("не удалось прочитать настройки AmneziaWG на сервере") }
        var state = State(dir: dir, confPath: conf, tool: tool, config: WGConfig(text("conf")),
                          clientsTable: text("clients").trimmingCharacters(in: .whitespacesAndNewlines),
                          serverPublicKey: pub, psk: first("psk"))
        if let k = parts["keys"]?.map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }),
           k.count == 3 {
            state.newKeys = (k[0], k[1], k[2])
        }
        if state.clientsTable.isEmpty { state.clientsTable = "[]" }
        return state
    }

    /// Replaces both files and applies the config; restores them on failure.
    private func write(_ container: String, state: State, conf: WGConfig, table: String) async throws {
        let b64conf = Data(conf.text.utf8).base64EncodedString()
        let b64strip = Data(conf.stripped().utf8).base64EncodedString()
        let b64table = Data(table.utf8).base64EncodedString()
        let script = "set -e\n" + Self.locate + """
            [ "$CONF" = "\(state.confPath)" ] || { echo "config moved" >&2; exit 1; }
            TS=$(date +%Y%m%d-%H%M%S)
            cp -p "$CONF" "$CONF.bak-$TS"
            [ -f "$D/clientsTable" ] && cp -p "$D/clientsTable" "$D/clientsTable.bak-$TS"
            base64 -d > "$CONF.new" <<'B64'
            \(b64conf)
            B64
            base64 -d > "$D/clientsTable.new" <<'B64'
            \(b64table)
            B64
            base64 -d > /tmp/monitor-awg-strip.conf <<'B64'
            \(b64strip)
            B64
            chmod 600 "$CONF.new" /tmp/monitor-awg-strip.conf
            if $WG syncconf "$IF" /tmp/monitor-awg-strip.conf; then
              mv "$CONF.new" "$CONF"; mv "$D/clientsTable.new" "$D/clientsTable"
              rm -f /tmp/monitor-awg-strip.conf
              ls -t "$CONF".bak-* 2>/dev/null | tail -n +6 | xargs rm -f
              ls -t "$D"/clientsTable.bak-* 2>/dev/null | tail -n +6 | xargs rm -f
              echo ok
            else
              rm -f "$CONF.new" "$D/clientsTable.new" /tmp/monitor-awg-strip.conf
              $WG syncconf "$IF" "$CONF" 2>/dev/null || true
              echo "syncconf failed, nothing changed" >&2; exit 1
            fi
            """
        let out = try await exec(container, script)
        guard out.contains("ok") else { throw AWGError("сервер не подтвердил изменение") }
    }

    static func fileName(_ name: String) -> String {
        var s = ""
        for ch in name.lowercased() {
            if ch.isLetter || ch.isNumber { s.append(ch) } else if !s.hasSuffix("-") { s.append("-") }
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return (s.isEmpty ? "amnezia" : String(s.prefix(32))) + ".conf"
    }
}

public struct AWGError: Error, CustomStringConvertible, Sendable {
    public var description: String
    public init(_ d: String) { description = d }
}

// MARK: - config file

/// An AmneziaWG (WireGuard) config kept as text, so comments and unknown
/// keys survive edits.
public struct WGConfig: Equatable, Sendable {
    public private(set) var text: String

    public init(_ text: String) { self.text = text }

    struct Section { var name: String; var lines: [String] }

    var sections: [Section] {
        var out: [Section] = [Section(name: "", lines: [])]
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("["), t.hasSuffix("]") {
                out.append(Section(name: String(t.dropFirst().dropLast()).lowercased(), lines: [line]))
            } else {
                out[out.count - 1].lines.append(line)
            }
        }
        return out
    }

    static func value(_ key: String, in lines: [String]) -> String? {
        for line in lines {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespaces).lowercased() == key.lowercased() {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    var interface: [String] { sections.first { $0.name == "interface" }?.lines ?? [] }

    public var listenPort: String? { Self.value("ListenPort", in: interface) }

    public struct Peer: Equatable, Sendable { public var publicKey: String; public var allowedIPs: String? }

    public var peers: [Peer] {
        sections.filter { $0.name == "peer" }.compactMap { s in
            Self.value("PublicKey", in: s.lines).map { Peer(publicKey: $0, allowedIPs: Self.value("AllowedIPs", in: s.lines)) }
        }
    }

    public mutating func addPeer(publicKey: String, presharedKey: String, allowedIPs: String) {
        var t = text
        while t.hasSuffix("\n\n") { t.removeLast() }
        if !t.hasSuffix("\n") { t += "\n" }
        t += "\n[Peer]\nPublicKey = \(publicKey)\nPresharedKey = \(presharedKey)\nAllowedIPs = \(allowedIPs)\n"
        text = t
    }

    /// Removes the [Peer] with this key; false when there is none.
    public mutating func removePeer(publicKey: String) -> Bool {
        var found = false
        let kept = sections.filter { s in
            guard s.name == "peer", Self.value("PublicKey", in: s.lines) == publicKey else { return true }
            found = true
            return false
        }
        guard found else { return false }
        text = kept.flatMap(\.lines).joined(separator: "\n")
        return true
    }

    /// The config without the wg-quick keys, as `wg syncconf` expects.
    public func stripped() -> String {
        let quickOnly: Set<String> = ["address", "dns", "mtu", "table", "preup", "postup", "predown",
                                      "postdown", "saveconfig"]
        return text.components(separatedBy: "\n").filter { line in
            let key = line.split(separator: "=", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            return !quickOnly.contains(key)
        }.joined(separator: "\n")
    }

    /// The lowest unused host address in the interface subnet (from .2).
    public func freeAddress() -> String? {
        guard let addr = Self.value("Address", in: interface)?.split(separator: ",").first
            .map({ $0.trimmingCharacters(in: .whitespaces) }),
              let (base, bits) = Self.parseCIDR(addr), bits >= 16, bits <= 30 else { return nil }
        let own = Self.parseCIDR(addr).map { $0.0 }
        var used = Set<UInt32>()
        if let own { used.insert(own) }
        for p in peers {
            for ip in (p.allowedIPs ?? "").split(separator: ",") {
                if let (a, _) = Self.parseCIDR(ip.trimmingCharacters(in: .whitespaces)) { used.insert(a) }
            }
        }
        let mask: UInt32 = bits == 0 ? 0 : ~UInt32(0) << (32 - UInt32(bits))
        let network = base & mask
        let broadcast = network | ~mask
        var a = network + 2
        while a < broadcast {
            if !used.contains(a) { return Self.format(a) }
            a += 1
        }
        return nil
    }

    static func parseCIDR(_ s: String) -> (UInt32, Int)? {
        let parts = s.split(separator: "/")
        let octets = parts[0].split(separator: ".").compactMap { UInt32($0) }
        guard octets.count == 4, octets.allSatisfy({ $0 < 256 }) else { return nil }
        let bits = parts.count > 1 ? Int(parts[1]) ?? 32 : 32
        return (octets.reduce(0) { $0 << 8 | $1 }, bits)
    }

    static func format(_ a: UInt32) -> String {
        [24, 16, 8, 0].map { String((a >> UInt32($0)) & 255) }.joined(separator: ".")
    }

    /// Obfuscation settings the client must share with the server.
    static let awgKeys = ["Jc", "Jmin", "Jmax", "S1", "S2", "S3", "S4", "H1", "H2", "H3", "H4",
                          "I1", "I2", "I3", "I4", "I5"]

    public func clientConfig(privateKey: String, address: String, serverPublicKey: String,
                             presharedKey: String, endpoint: String) -> String {
        var lines = ["[Interface]", "Address = \(address)", "DNS = 1.1.1.1, 1.0.0.1", "PrivateKey = \(privateKey)"]
        for k in Self.awgKeys { if let v = Self.value(k, in: interface) { lines.append("\(k) = \(v)") } }
        lines += ["", "[Peer]", "PublicKey = \(serverPublicKey)", "PresharedKey = \(presharedKey)",
                  "AllowedIPs = 0.0.0.0/0, ::/0", "Endpoint = \(endpoint)", "PersistentKeepalive = 25", ""]
        return lines.joined(separator: "\n")
    }
}

// MARK: - clientsTable

/// The AmneziaVPN app's list of client names: a JSON array of
/// {"clientId": <public key>, "userData": {"clientName": ..., "creationDate": ...}}.
/// Other fields are kept as they are.
enum ClientsTable {
    static func array(_ json: String) throws -> [Any] {
        let data = Data((json.isEmpty ? "[]" : json).utf8)
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw AWGError("clientsTable на сервере не похож на список")
        }
        return arr
    }

    static func encode(_ arr: [Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted]), as: UTF8.self)
    }

    static func entries(_ json: String) -> [String: (name: String, created: String?)] {
        var out: [String: (name: String, created: String?)] = [:]
        for case let e as [String: Any] in (try? array(json)) ?? [] {
            guard let id = e["clientId"] as? String, let user = e["userData"] as? [String: Any],
                  let name = user["clientName"] as? String else { continue }
            out[id] = (name, user["creationDate"] as? String)
        }
        return out
    }

    static func adding(_ json: String, publicKey: String, name: String, created: String) throws -> String {
        var arr = try array(json)
        arr.append(["clientId": publicKey, "userData": ["clientName": name, "creationDate": created]])
        return try encode(arr)
    }

    static func removing(_ json: String, publicKey: String) throws -> String {
        try encode(try array(json).filter { ($0 as? [String: Any])?["clientId"] as? String != publicKey })
    }

    /// Same style as the AmneziaVPN app: "Mon Oct 5 11:00:00 2026".
    static func dateString(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f.string(from: d)
    }
}
