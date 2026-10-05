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
}

/// This Mac's traffic to one of our servers.
public struct MacRoute: Equatable, Identifiable, Sendable {
    public var id: String { toID }
    public var toID: String
    public var processes: [String]
    public var ports: [Int]
    public var connections: Int
}

public enum LocalLinks {
    /// Remote ports that are not traffic going through a server: SSH sessions.
    static let ignoredPorts: Set<Int> = [22]

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
            guard let (ip, port) = splitAddress(t[4]), isPublic(ip), !ignoredPorts.contains(port) else { continue }
            let rest = Array(t[min(restStart, t.count)...])
            let (procName, pid) = process(rest, header: restHeader)
            if let pid, pid == ownPID { continue }
            let label = procName ?? pid.flatMap(name) ?? pid.map { "pid \($0)" } ?? "?"
            let key = ip + "|" + label
            var l = agg[key] ?? MacLink(remoteIP: ip, process: label, ports: [], protos: [], connections: 0)
            if !l.ports.contains(port) { l.ports.append(port); l.ports.sort() }
            let p = isTCP ? "tcp" : "udp"
            if !l.protos.contains(p) { l.protos.append(p); l.protos.sort() }
            l.connections += 1
            agg[key] = l
        }
        return agg.values.sorted { ($0.connections, $1.remoteIP) > ($1.connections, $0.remoteIP) }
    }

    /// Links that reach our servers, one route per server. A server's agent
    /// port only carries monitoring, so it does not count.
    public static func routes(_ links: [MacLink], servers: [ServerConfig]) -> [MacRoute] {
        var byIP: [String: ServerConfig] = [:]
        for s in servers { byIP[s.host] = s }
        var out: [String: MacRoute] = [:]
        for l in links {
            guard let s = byIP[l.remoteIP] else { continue }
            let ports = l.ports.filter { $0 != s.port }
            guard !ports.isEmpty else { continue }
            var r = out[s.id] ?? MacRoute(toID: s.id, processes: [], ports: [], connections: 0)
            if !r.processes.contains(l.process) { r.processes.append(l.process); r.processes.sort() }
            r.ports = Array(Set(r.ports + ports)).sorted()
            r.connections += l.connections
            out[s.id] = r
        }
        return out.values.sorted { $0.toID < $1.toID }
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
