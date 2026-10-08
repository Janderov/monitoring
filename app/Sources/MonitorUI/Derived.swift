#if canImport(SwiftUI) && canImport(AppKit)
import Foundation
import MonitorCore

/// A site for the screens: the core's `SiteStatus` plus the server configs of
/// the places it is checked from (for country names).
public struct SiteSummary: Identifiable, Sendable {
    public struct Origin: Identifiable, Sendable {
        public var serverID: String
        public var serverName: String
        public var server: ServerConfig?
        /// Nil while the agent is unreachable or has not run the check yet.
        public var check: Snapshot.Check?
        public var id: String { serverID }
        public var ok: Bool { check?.ok == true }
        public var place: String { server.flatMap { Country.detect($0)?.name } ?? serverName }
    }

    public var status: SiteStatus
    public var origins: [Origin]

    public var id: String { status.id }
    public var name: String { status.site.name }
    public var url: String { status.site.url }
    public var tlsExpiry: Date? { status.tlsExpiry }
    public var domain: String? { status.domain }
    public var domainExpiry: Date? { status.domainExpiry }
    public var domainError: String? { status.domainError }
    public var alerts: [ActiveAlert] { status.alerts }

    public var checked: [Origin] { origins.filter { $0.check != nil } }

    public var averageLatency: Double? {
        let ok = origins.filter(\.ok).compactMap(\.check?.latencyMs)
        return ok.isEmpty ? nil : ok.reduce(0, +) / Double(ok.count)
    }

    public var statusCode: Int? { origins.compactMap(\.check?.statusCode).first }

    public func level() -> ServerStatus.Level { status.level }

    /// The worst alert in one line, or nil when all is fine.
    public var problem: String? {
        status.alerts.max { ($0.severity, $1.since) < ($1.severity, $0.since) }?.message
    }

    init(status: SiteStatus, servers: [ServerStatus]) {
        self.status = status
        origins = status.origins.map { o in
            Origin(serverID: o.serverID, serverName: o.serverName,
                   server: servers.first { $0.id == o.serverID }?.server, check: o.check)
        }
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
    public var sites: [SiteSummary] { siteStatuses.map { SiteSummary(status: $0, servers: statuses) } }
    public var links: [ServerLink] { ServerLink.build(from: statuses) }

    /// VPN cascades and relays between our servers (entry -> exit).
    public var routes: [VPNRoute] { VPNRoutes.compute(statuses) }

    public func routes(of serverID: String) -> [VPNRoute] {
        routes.filter { $0.fromID == serverID || $0.toID == serverID }
    }

    /// A readable name for an event's object: a server, or a site ("site:<id>").
    public func objectName(_ id: String) -> String {
        if let s = status(id) { return s.server.name }
        if let site = siteStatuses.first(where: { SiteStatus.alertID($0.id) == id }) { return site.site.name }
        if id == AwaySummary.sourceID { return "Этот Mac" }
        return id
    }

    /// Who can reach `serverID`: every link pointing at it.
    public func reachability(of serverID: String) -> [ServerLink] {
        links.filter { $0.to.id == serverID }
    }
}
#endif
