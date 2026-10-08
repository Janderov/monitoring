import Foundation

/// An outgoing connection from this Mac to a public address, grouped by the
/// program that makes it (gost, AmneziaVPN...). The map draws the ones that
/// reach our servers as arrows from "this Mac", so a split such as
/// "Google via the US, the rest via NL" shows up without any setup.
public struct MacLink: Hashable, Sendable {
    public var remoteIP: String
    /// Program name as macOS reports it, or "pid 123" when it does not.
    public var process: String
    public var ports: [Int]
    public var protos: [String]
    public var connections: Int
    /// This Mac's addresses the connections leave from; a VPN tunnel
    /// address means they go through that VPN server first.
    public var localIPs: [String] = []
    /// Bytes received and sent so far by each connection, keyed by its local
    /// address and port; empty when netstat prints no byte columns.
    public var counters: [String: ByteCounter] = [:]
}

/// Running byte counters of one connection or interface.
public struct ByteCounter: Hashable, Sendable {
    public var rx: UInt64
    public var tx: UInt64

    public init(rx: UInt64, tx: UInt64) { self.rx = rx; self.tx = tx }
}

/// This Mac's traffic to one of our servers, either straight or through
/// another of our servers (the Mac's VPN): Mac -> via -> to.
public struct MacRoute: Equatable, Identifiable, Sendable {
    public var id: String { (viaID.map { $0 + ">" } ?? "") + toID }
    public var toID: String
    public var processes: [String]
    public var ports: [Int]
    public var connections: Int
    /// The server whose VPN tunnel this traffic goes through first.
    public var viaID: String? = nil
    /// Live traffic now; false for a route only found in a proxy's settings.
    public var active: Bool { connections > 0 }
}

/// A program on this Mac that listens on localhost: a local proxy such as
/// gost, whose settings name the servers it forwards to.
public struct LocalProxy: Hashable, Sendable {
    public var process: String
    public var pid: Int32
}

public enum LocalLinks {
    /// An interactive SSH session to a server is not traffic going through
    /// it. SSH used as a proxy transport (gost, ssh -D) is, so only the
    /// plain `ssh` client on port 22 is dropped.
    static func isSSHSession(_ process: String, port: Int) -> Bool { port == 22 && process == "ssh" }

    /// Parses `netstat -anv` (macOS) into outgoing connections to public
    /// addresses. `ownPID` drops this app's own requests (agent polls, site
    /// checks); `name` resolves a bare pid when netstat prints no name.
    public static func parse(_ netstat: String, ownPID: Int32? = nil,
                             name: (Int32) -> String? = { _ in nil }) -> [MacLink] {
        var restHeader: [String] = []
        var agg: [String: MacLink] = [:]
        for line in netstat.split(separator: "\n") {
            let t = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let proto = t.first else { continue }
            if proto == "Proto", let i = t.firstIndex(of: "(state)") {
                restHeader = Array(t[(i + 1)...])
                continue
            }
            let isTCP = proto.hasPrefix("tcp")
            guard isTCP || proto.hasPrefix("udp"), t.count >= 5 else { continue }
            var restStart = 5
            if t.count > 5, isState(t[5]) {
                guard !isTCP || ["ESTABLISHED", "SYN_SENT"].contains(t[5]) else { continue }
                restStart = 6
            } else if isTCP {
                continue
            }
            guard let (ip, port) = splitAddress(t[4]), isPublic(ip) else { continue }
            let rest = Array(t[min(restStart, t.count)...])
            let (procName, pid) = process(rest, header: restHeader)
            if let pid, pid == ownPID { continue }
            let label = procName ?? pid.flatMap(name) ?? pid.map { "pid \($0)" } ?? "?"
            if isSSHSession(label, port: port) { continue }
            let key = ip + "|" + label
            var l = agg[key] ?? MacLink(remoteIP: ip, process: label, ports: [], protos: [], connections: 0)
            if let (local, _) = splitAddress(t[3]), !l.localIPs.contains(local) { l.localIPs.append(local) }
            if !l.ports.contains(port) { l.ports.append(port); l.ports.sort() }
            let p = isTCP ? "tcp" : "udp"
            if !l.protos.contains(p) { l.protos.append(p); l.protos.sort() }
            l.connections += 1
            if let rx = column("rxbytes", rest, restHeader).flatMap(UInt64.init),
               let tx = column("txbytes", rest, restHeader).flatMap(UInt64.init) {
                l.counters[p + " " + t[3]] = ByteCounter(rx: rx, tx: tx)
            }
            agg[key] = l
        }
        return agg.values.sorted { ($0.connections, $1.remoteIP) > ($1.connections, $0.remoteIP) }
    }

    /// Links that reach our servers, one route per server. A server's agent
    /// port only carries monitoring, so it does not count. `through` maps a
    /// Mac tunnel address to the server of that VPN (see `tunnelServers`).
    public static func routes(_ links: [MacLink], servers: [ServerConfig],
                              through: [String: String] = [:]) -> [MacRoute] {
        var byIP: [String: ServerConfig] = [:]
        for s in servers { byIP[s.host] = s }
        var out: [String: MacRoute] = [:]
        for l in links {
            guard let s = byIP[l.remoteIP] else { continue }
            let ports = l.ports.filter { $0 != s.port }
            guard !ports.isEmpty else { continue }
            let via = l.localIPs.lazy.compactMap { through[$0] }.first.flatMap { $0 == s.id ? nil : $0 }
            var r = MacRoute(toID: s.id, processes: [], ports: [], connections: 0, viaID: via)
            r = out[r.id] ?? r
            if !r.processes.contains(l.process) { r.processes.append(l.process); r.processes.sort() }
            r.ports = Array(Set(r.ports + ports)).sorted()
            r.connections += l.connections
            out[r.id] = r
        }
        return out.values.sorted { $0.id < $1.id }
    }

    /// Programs listening on 127.0.0.1 or ::1 (local proxies).
    public static func localProxies(_ netstat: String, ownPID: Int32? = nil) -> [LocalProxy] {
        var restHeader: [String] = []
        var out: Set<LocalProxy> = []
        for line in netstat.split(separator: "\n") {
            let t = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let proto = t.first else { continue }
            if proto == "Proto", let i = t.firstIndex(of: "(state)") { restHeader = Array(t[(i + 1)...]); continue }
            guard proto.hasPrefix("tcp"), t.count > 6, t[5] == "LISTEN" else { continue }
            guard let (ip, _) = splitAddress(t[3]), ip == "127.0.0.1" || ip == "::1" else { continue }
            let (name, pid) = process(Array(t[6...]), header: restHeader)
            guard let name, let pid, pid != ownPID else { continue }
            out.insert(LocalProxy(process: name, pid: pid))
        }
        return out.sorted { $0.pid < $1.pid }
    }

    /// Servers named in local proxies' settings (command line, config file):
    /// the route exists even while no traffic flows. Only our servers' hosts
    /// are looked for, so nothing else from the settings is kept.
    public static func configuredRoutes(_ settings: [String: String], servers: [ServerConfig]) -> [MacRoute] {
        var out: [String: MacRoute] = [:]
        for (process, text) in settings {
            for s in servers where mentions(text, host: s.host) {
                var r = out[s.id] ?? MacRoute(toID: s.id, processes: [], ports: [], connections: 0)
                if !r.processes.contains(process) { r.processes.append(process); r.processes.sort() }
                out[s.id] = r
            }
        }
        return out.values.sorted { $0.toID < $1.toID }
    }

    /// `host` appears in `text` as a whole address, not inside a longer one.
    static func mentions(_ text: String, host: String) -> Bool {
        guard !host.isEmpty else { return false }
        var from = text.startIndex
        while let r = text.range(of: host, range: from..<text.endIndex) {
            let before = r.lowerBound == text.startIndex ? nil : text[text.index(before: r.lowerBound)]
            let after = r.upperBound == text.endIndex ? nil : text[r.upperBound]
            func part(_ c: Character?) -> Bool { c.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } ?? false }
            let dotDigit = after == "." && text[r.upperBound...].dropFirst().first?.isNumber == true
            if !part(before), !part(after), before != ".", !dotDigit { return true }
            from = r.upperBound
        }
        return false
    }

    /// VPN tunnels of this Mac: macOS hides the VPN app's own socket, but the
    /// tunnel address the Mac got (e.g. 10.8.1.17 on a utun interface) is a
    /// peer of exactly one server's AmneziaWG/WireGuard. Amnezia gives every
    /// server the same 10.8.1.0/24, so only a peer with a live handshake counts.
    public static func tunnelRoutes(localAddresses: [String], statuses: [ServerStatus]) -> [MacRoute] {
        guard !localAddresses.isEmpty else { return [] }
        var out: [String: MacRoute] = [:]
        for s in statuses {
            for vpn in s.snapshot?.vpn ?? [] {
                for p in vpn.peers ?? [] where p.active {
                    guard localAddresses.contains(where: { peer(p, has: $0) }) else { continue }
                    var r = out[s.server.id] ?? MacRoute(toID: s.server.id, processes: [], ports: [], connections: 0)
                    let name = "VPN " + vpn.container
                    if !r.processes.contains(name) { r.processes.append(name) }
                    r.connections += 1
                    out[s.server.id] = r
                }
            }
        }
        return out.values.sorted { $0.toID < $1.toID }
    }

    /// Which server each of this Mac's tunnel addresses belongs to.
    public static func tunnelServers(localAddresses: [String], statuses: [ServerStatus]) -> [String: String] {
        var out: [String: String] = [:]
        for a in localAddresses {
            for s in statuses {
                let has = (s.snapshot?.vpn ?? []).contains { ($0.peers ?? []).contains { $0.active && peer($0, has: a) } }
                if has { out[a] = s.server.id; break }
            }
        }
        return out
    }

    private static func peer(_ p: Snapshot.VPN.Peer, has address: String) -> Bool {
        (p.allowedIps ?? "").split(separator: ",")
            .contains { $0.trimmingCharacters(in: .whitespaces) == address + "/32" }
    }

    /// Routes with the same path, as one.
    public static func merge(_ a: [MacRoute], _ b: [MacRoute]) -> [MacRoute] {
        var out: [String: MacRoute] = [:]
        for r in a + b {
            guard var cur = out[r.id] else { out[r.id] = r; continue }
            cur.processes = Array(Set(cur.processes + r.processes)).sorted()
            cur.ports = Array(Set(cur.ports + r.ports)).sorted()
            cur.connections += r.connections
            out[r.id] = cur
        }
        return out.values.sorted { $0.id < $1.id }
    }

    /// Links to addresses that are none of our servers, busiest first.
    public static func unknown(_ links: [MacLink], servers: [ServerConfig]) -> [MacLink] {
        let ours = Set(servers.map(\.host))
        return links.filter { !ours.contains($0.remoteIP) }
    }

    /// "gost:1234" (macOS 13+) or a bare "1234" in the pid column.
    private static func process(_ rest: [String], header: [String]) -> (String?, Int32?) {
        var value: String?
        if let i = header.firstIndex(where: { $0 == "pid" || $0 == "process:pid" }), i < rest.count {
            value = rest[i]
        } else {
            value = rest.first { v in
                guard let c = v.lastIndex(of: ":") else { return false }
                return c != v.startIndex && Int32(v[v.index(after: c)...]) != nil
            }
        }
        guard let v = value else { return (nil, nil) }
        if let c = v.lastIndex(of: ":") {
            let n = String(v[..<c])
            return (n.isEmpty ? nil : n, Int32(v[v.index(after: c)...]))
        }
        return (nil, Int32(v))
    }

    private static func column(_ name: String, _ rest: [String], _ header: [String]) -> String? {
        guard let i = header.firstIndex(of: name), i < rest.count else { return nil }
        return rest[i]
    }

    private static func isState(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isUppercase || $0 == "_" }
    }

    /// netstat joins address and port with a dot: "1.2.3.4.443", "2001:db8::1.443".
    static func splitAddress(_ s: String) -> (String, Int)? {
        guard let i = s.lastIndex(of: "."), let port = Int(s[s.index(after: i)...]) else { return nil }
        return (String(s[..<i]), port)
    }

    static func isPublic(_ ip: String) -> Bool {
        if ip.contains(":") {
            let l = ip.lowercased()
            return !(l == "::1" || l.hasPrefix("fe80") || l.hasPrefix("fc") || l.hasPrefix("fd") || l.contains("%"))
        }
        let o = ip.split(separator: ".").compactMap { Int($0) }
        guard o.count == 4 else { return false }
        switch (o[0], o[1]) {
        case (10, _), (127, _), (0, _), (169, 254), (192, 168): return false
        case (172, 16...31), (100, 64...127): return false
        case (224...255, _): return false
        default: return true
        }
    }
}
