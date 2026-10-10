import Foundation
import MonitorCore

/// A client's report from what this Mac already keeps, until the hub runs:
/// raw site checks (30 days), hourly server rollups (a year), the event log,
/// clients.json and today's forecast. Fewer facts than the hub will have
/// (no history of forecasts, so no «Предотвращено»; days older than 30 days
/// show as «нет данных» for sites), but honest about it, and enough to send
/// a client a real report by hand.
public enum LocalReport {
    public struct Source: Sendable {
        public var signature: String
        public var footer: String
        public var servers: [ServerConfig]
        public var sites: [SiteConfig]
        /// Site id -> id of the server it runs on.
        public var hosting: [String: String]
        public var hourly: [String: [Store.Hourly]]
        public var siteSamples: [String: [Store.SiteSample]]
        /// Events of servers (by id) and sites (by `SiteStatus.alertID`), any order.
        public var events: [Store.LoggedEvent]
        public var tlsExpiry: [String: Date]
        public var domainExpiry: [String: Date]
        /// What runs out soon, by the server's or site's name (`Soon.items`).
        public var soon: [(object: String, item: SoonItem)]

        public init(signature: String, footer: String = "", servers: [ServerConfig], sites: [SiteConfig],
                    hosting: [String: String] = [:], hourly: [String: [Store.Hourly]] = [:],
                    siteSamples: [String: [Store.SiteSample]] = [:], events: [Store.LoggedEvent] = [],
                    tlsExpiry: [String: Date] = [:], domainExpiry: [String: Date] = [:],
                    soon: [(object: String, item: SoonItem)] = []) {
            self.signature = signature; self.footer = footer; self.servers = servers; self.sites = sites
            self.hosting = hosting; self.hourly = hourly; self.siteSamples = siteSamples; self.events = events
            self.tlsExpiry = tlsExpiry; self.domainExpiry = domainExpiry; self.soon = soon
        }
    }

    /// The client's sites and servers at any time in the period: their own
    /// rows, plus the servers their sites run on.
    public static func objects(_ client: Client, book: ClientBook, period: ReportPeriod, servers: [ServerConfig],
                               sites: [SiteConfig], hosting: [String: String]) -> (servers: [ServerConfig], sites: [SiteConfig]) {
        let rows = book.assets.filter {
            $0.clientID == client.id && $0.since < period.to && ($0.until.map { $0 > period.from } ?? true)
        }
        let siteIDs = Set(rows.filter { $0.type == .site }.map(\.assetID))
        var serverIDs = Set(rows.filter { $0.type == .server }.map(\.assetID))
        for id in siteIDs { if let s = hosting[id] { serverIDs.insert(s) } }
        return (servers.filter { serverIDs.contains($0.id) }, sites.filter { siteIDs.contains($0.id) })
    }

    public static func input(_ client: Client, book: ClientBook, source s: Source, period p: ReportPeriod) -> ReportInput {
        let (servers, sites) = objects(client, book: book, period: p, servers: s.servers, sites: s.sites, hosting: s.hosting)
        var ids: [String: UUID] = [:]
        func uuid(_ id: String) -> UUID {
            if let u = ids[id] { return u }
            let u = UUID(uuidString: id) ?? UUID()
            ids[id] = u
            return u
        }

        var siteDays: [ReportInput.SiteDay] = []
        for site in sites {
            let samples = (s.siteSamples[site.id] ?? []).filter { $0.time >= p.from && $0.time < p.to }
            for (day, rows) in Dictionary(grouping: samples, by: { ReportPeriod.day($0.time, p.timeZone) }) {
                siteDays.append(siteDay(uuid(site.id), day, rows))
            }
        }

        var serverDays: [ReportInput.ServerDay] = []
        var diskDays: [ReportInput.DiskDay] = []
        let reboots = Dictionary(grouping: s.events.filter { $0.key == "reboot" && $0.time >= p.from && $0.time < p.to },
                                 by: { "\($0.serverID)|\(ReportPeriod.day($0.time, p.timeZone))" }).mapValues(\.count)
        for server in servers {
            let hours = s.hourly[server.id] ?? []
            for (day, rows) in Dictionary(grouping: hours, by: { ReportPeriod.day($0.hour, p.timeZone) }) {
                if day >= p.start && day <= p.end {
                    serverDays.append(.init(serverID: uuid(server.id), day: day, cpuMax: rows.map(\.cpuMax).max(),
                                            memMax: rows.map(\.memMax).max(), diskMaxPct: rows.map(\.diskMax).max(),
                                            reboots: reboots["\(server.id)|\(day)"] ?? 0,
                                            checksTotal: rows.reduce(0) { $0 + $1.pollsTotal },
                                            checksOK: rows.reduce(0) { $0 + $1.pollsOK }))
                }
                // The fullest disk of the day; percent kept as parts of 10 000.
                if let disk = rows.map(\.diskMax).max() {
                    diskDays.append(.init(serverID: uuid(server.id), mount: "/", day: day,
                                          usedBytes: Int64((disk * 100).rounded()), totalBytes: 10_000))
                }
            }
        }

        // Outages from the event log: «fired» to the next «resolved» of the same key.
        let names = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0.name) }
                               + sites.map { (SiteStatus.alertID($0.id), $0.name) })
        var incidents: [ReportInput.IncidentRow] = []
        for ((object, key), events) in Dictionary(grouping: s.events.filter { names[$0.serverID] != nil && $0.key == "down" },
                                                  by: { Pair($0.serverID, $0.key) }).map({ (($0.key.a, $0.key.b), $0.value) }) {
            var open: Store.LoggedEvent?
            for e in events.sorted(by: { $0.time < $1.time }) {
                switch e.kind {
                case .fired: if open == nil { open = e }
                case .resolved:
                    if let o = open { incidents.append(row(names[object]!, key, o, end: e.time)); open = nil }
                default: break
                }
            }
            if let o = open { incidents.append(row(names[object]!, key, o, end: nil)) }
        }

        // Today's forecast for the client's objects: what the client will hear about next.
        let objectNames = Set(servers.map(\.name) + sites.map(\.name))
        let forecasts: [ReportInput.ForecastRow] = s.soon.compactMap { f in
            // A site's line names the server it runs on; that server may host other clients' sites too.
            let object = f.item.kind == .disk ? f.object : f.item.name
            guard objectNames.contains(object) else { return nil }
            let kind: String
            switch f.item.kind {
            case .tls: kind = "tls_expiry"
            case .domain: kind = "domain_expiry"
            case .disk: kind = "disk_full"
            // What the admin pays the hosting is not the client's business.
            case .payment: return nil
            }
            return .init(objectName: object, kind: kind, line: "",
                         dueAt: f.item.date, firstSeenAt: f.item.date, status: "open")
        }

        // Still the client's when the month ends (the servers: their own, or hosting such a site).
        let held = Set(book.assets.filter { $0.clientID == client.id && $0.since < p.to && ($0.until.map { $0 >= p.to } ?? true) }
            .map(\.assetID))
        let currentServers = held.union(sites.filter { held.contains($0.id) }.compactMap { s.hosting[$0.id] })

        let contract = client.contract(at: p.to.addingTimeInterval(-1))
        return ReportInput(
            clientName: client.legalName?.isEmpty == false ? client.legalName! : client.name,
            signature: s.signature, footer: s.footer, period: p,
            slaTarget: contract?.slaUptime.map { $0 / 100 },
            sites: sites.map { .init(id: uuid($0.id), name: $0.name, tlsExpiry: s.tlsExpiry[$0.id], domainExpiry: s.domainExpiry[$0.id],
                                     current: held.contains($0.id)) },
            siteDays: siteDays,
            servers: servers.map { .init(id: uuid($0.id), name: $0.name, current: currentServers.contains($0.id)) },
            serverDays: serverDays, diskDays: diskDays, incidents: incidents, forecasts: forecasts)
    }

    /// One day of one site from raw checks. A minute is down when every
    /// country that checked it failed and at least two did, or the only one
    /// did: the same rule as the alert («down from some countries» is a
    /// routing or blocking problem, not the site).
    static func siteDay(_ id: UUID, _ day: String, _ rows: [Store.SiteSample]) -> ReportInput.SiteDay {
        let checkers = Set(rows.map(\.serverID)).count
        var downMinutes = 0
        for (_, minute) in Dictionary(grouping: rows, by: { Int($0.time.timeIntervalSince1970) / 60 }) {
            let fails = minute.filter { !$0.ok }.count
            if fails == minute.count, fails >= 2 || checkers == 1 { downMinutes += 1 }
        }
        let ok = rows.filter(\.ok)
        return .init(siteID: id, day: day, checksTotal: rows.count, checksOK: ok.count, downtimeSeconds: downMinutes * 60,
                     latencyAvgMs: ok.isEmpty ? nil : ok.reduce(0) { $0 + $1.latencyMs } / Double(ok.count))
    }

    static func row(_ name: String, _ key: String, _ e: Store.LoggedEvent, end: Date?) -> ReportInput.IncidentRow {
        // «сайт shop недоступен: таймаут» → «Недоступен: таймаут» reads better after the name.
        var message = e.message
        if let r = message.range(of: name + " ") { message = String(message[r.upperBound...]) }
        return .init(objectName: name, kind: key, severity: e.severity.rawValue,
                     message: message.prefix(1).uppercased() + message.dropFirst(), startedAt: e.time, endedAt: end)
    }

    struct Pair: Hashable { var a: String, b: String; init(_ a: String, _ b: String) { self.a = a; self.b = b } }
}
