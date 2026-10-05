#if canImport(SwiftUI) && canImport(AppKit)
import Foundation
import MonitorCore

/// A site as seen from every agent that checks it. Built from `Snapshot.checks`
/// until the core gets its own site checks (with history, RDAP and so on).
public struct SiteSummary: Identifiable, Sendable {
    public struct Origin: Identifiable, Sendable {
        public var server: ServerConfig
        public var check: Snapshot.Check
        public var id: String { server.id }
    }

    public var url: String
    public var origins: [Origin]
    public var id: String { url }

    public var name: String { URL(string: url)?.host ?? url }

    public var tlsExpiry: Date? { origins.compactMap(\.check.tlsExpiry).min() }

    public var averageLatency: Double? {
        let ok = origins.filter(\.check.ok).map(\.check.latencyMs)
        return ok.isEmpty ? nil : ok.reduce(0, +) / Double(ok.count)
    }

    public var statusCode: Int? { origins.compactMap(\.check.statusCode).first }

    public func level(tlsDays: Int = 14) -> ServerStatus.Level {
        if origins.isEmpty { return .unknown }
        let failed = origins.filter { !$0.check.ok }.count
        if failed == origins.count { return .critical }
        if failed > 0 { return .warning }
        if let exp = tlsExpiry, Fmt.days(until: exp) <= tlsDays { return .warning }
        return .ok
    }

    /// What is wrong, in one line, or nil when all is fine.
    public var problem: String? {
        let failed = origins.filter { !$0.check.ok }
        if !failed.isEmpty, failed.count == origins.count { return "не отвечает ни из одной страны" }
        if !failed.isEmpty {
            let from = failed.map { Country.detect($0.server)?.name ?? $0.server.name }.joined(separator: ", ")
            return "не отвечает из: \(from)"
        }
        if let exp = tlsExpiry, Fmt.days(until: exp) <= 14 { return "SSL истекает через \(Fmt.days(until: exp)) д" }
        return nil
    }

    static func build(from statuses: [ServerStatus]) -> [SiteSummary] {
        var byURL: [String: [Origin]] = [:]
        for s in statuses {
            for c in s.snapshot?.checks ?? [] where c.kind == "http" {
                byURL[c.target, default: []].append(Origin(server: s.server, check: c))
            }
        }
        return byURL.map { SiteSummary(url: $0.key, origins: $0.value.sorted { $0.server.name < $1.server.name }) }
            .sorted { $0.name < $1.name }
    }
}

/// A TCP check from one of our servers to another one: the lines on the map.
public struct ServerLink: Identifiable, Sendable {
    public var from: ServerConfig
    public var to: ServerConfig
    public var check: Snapshot.Check
    public var id: String { "\(from.id)>\(to.id)" }

    static func build(from statuses: [ServerStatus]) -> [ServerLink] {
        let servers = statuses.map(\.server)
        var out: [ServerLink] = []
        for s in statuses {
            for c in s.snapshot?.checks ?? [] where c.kind == "tcp" {
                let host = c.target.split(separator: ":").first.map(String.init) ?? c.target
                if let to = servers.first(where: { $0.host == host && $0.id != s.id }) {
                    out.append(ServerLink(from: s.server, to: to, check: c))
                }
            }
        }
        return out
    }
}

extension AppModel {
    public var sites: [SiteSummary] { SiteSummary.build(from: statuses) }
    public var links: [ServerLink] { ServerLink.build(from: statuses) }

    /// Who can reach `serverID`: every link pointing at it.
    public func reachability(of serverID: String) -> [ServerLink] {
        links.filter { $0.to.id == serverID }
    }
}
#endif
