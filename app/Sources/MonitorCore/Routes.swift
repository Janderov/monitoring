import Foundation

/// Traffic from one of our servers to another: a VPN cascade (entry -> exit)
/// or another relay, drawn as an arrow on the map.
public struct VPNRoute: Equatable, Identifiable, Sendable {
    public enum Kind: Sendable {
        /// An AmneziaWG/WireGuard peer of the entry server that routes all
        /// traffic (0.0.0.0/0) to the exit server.
        case tunnel
        /// Traffic from the entry server to the exit server: its own
        /// connections (host or a container such as xray), client traffic it
        /// passes on through NAT, or connections the exit server sees coming
        /// in from it.
        case relay
    }

    public var id: String { fromID + "->" + toID }
    public var fromID: String
    public var toID: String
    public var kind: Kind
    /// Containers carrying the traffic, e.g. ["amnezia-xray"], ["host"], or
    /// ["nat:host"] for forwarded client traffic.
    public var via: [String]
    /// Remote ports on the exit server.
    public var ports: [Int]
    public var connections: Int
    /// A tunnel counts as active after a recent handshake; a relay while it
    /// has connections.
    public var active: Bool
}

public enum VPNRoutes {
    /// Remote ports that are not relaying: SSH sessions between servers.
    static let ignoredPorts: Set<Int> = [22]

    /// Routes between known servers, matched by IP address of `host`.
    public static func compute(_ statuses: [ServerStatus]) -> [VPNRoute] {
        var byIP: [String: String] = [:]
        for s in statuses { byIP[s.server.host] = s.server.id }

        var routes: [String: VPNRoute] = [:]
        func merge(_ r: VPNRoute) {
            guard var cur = routes[r.id] else { routes[r.id] = r; return }
            if r.kind == .tunnel { cur.kind = .tunnel }
            cur.via = Array(Set(cur.via + r.via)).sorted()
            cur.ports = Array(Set(cur.ports + r.ports)).sorted()
            // The same connections can be seen from both ends.
            cur.connections = max(cur.connections, r.connections)
            cur.active = cur.active || r.active
            routes[r.id] = cur
        }

        for s in statuses {
            guard let snap = s.snapshot else { continue }
            let from = s.server.id
            for vpn in snap.vpn ?? [] {
                for p in vpn.peers ?? [] {
                    guard let allowed = p.allowedIps, allowed.contains("0.0.0.0/0"),
                          let ep = p.endpoint, let (ip, port) = splitEndpoint(ep),
                          let to = byIP[ip], to != from else { continue }
                    merge(VPNRoute(fromID: from, toID: to, kind: .tunnel, via: [vpn.container], ports: [port],
                                   connections: 1, active: p.active))
                }
            }
            for l in (snap.links ?? []) + (snap.forwards ?? []) {
                guard let to = byIP[l.remoteIp], to != from else { continue }
                let ports = l.ports.filter { !ignoredPorts.contains($0) && $0 != port(of: to, in: statuses) }
                guard !ports.isEmpty else { continue }
                merge(VPNRoute(fromID: from, toID: to, kind: .relay, via: l.via, ports: ports,
                               connections: l.connections, active: l.connections > 0))
            }
            // Seen from the exit side: another of our servers connecting in.
            for l in snap.inbound ?? [] {
                guard let src = byIP[l.remoteIp], src != from else { continue }
                let ports = l.ports.filter { !ignoredPorts.contains($0) && $0 != s.server.port }
                guard !ports.isEmpty else { continue }
                merge(VPNRoute(fromID: src, toID: from, kind: .relay, via: [], ports: ports,
                               connections: l.connections, active: l.connections > 0))
            }
        }
        return routes.values.sorted { ($0.fromID, $0.toID) < ($1.fromID, $1.toID) }
    }

    /// The agent port of a server; probes to it are not relaying.
    private static func port(of id: String, in statuses: [ServerStatus]) -> Int? {
        statuses.first { $0.server.id == id }?.server.port
    }

    /// "1.2.3.4:51820" or "[2001:db8::1]:51820".
    static func splitEndpoint(_ s: String) -> (String, Int)? {
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            guard rest.hasPrefix(":"), let p = Int(rest.dropFirst()) else { return nil }
            return (host, p)
        }
        guard let i = s.lastIndex(of: ":"), let p = Int(s[s.index(after: i)...]) else { return nil }
        return (String(s[..<i]), p)
    }
}
