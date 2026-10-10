import Foundation

/// Turns the rows of one client and one month into the report snapshot.
/// Pure: the same input gives the same report, so it is tested without a database.
public enum ReportBuilder {
    /// How far ahead «Скоро потребует внимания» looks.
    public static let attentionHorizon: TimeInterval = 90 * 86400
    /// Certificates and domains closer than this are listed even without a forecast.
    public static let expiryHorizonDays = 60
    /// Days of disk history the runway is fitted on.
    static let runwayWindow = 14

    public static func build(_ input: ReportInput, now: Date) -> ClientReport {
        let p = input.period
        let sites = input.sites.sorted { $0.name < $1.name }.map { site(input, $0, now: now) }
        let servers = input.servers.sorted { $0.name < $1.name }.map { server(input, $0) }
        let incidents = self.incidents(input, now: now)
        let prevented = self.prevented(input)
        let backups = self.backups(input, now: now)

        let siteChecks = input.siteDays.reduce(into: (0, 0)) { $0.0 += $1.checksOK; $0.1 += $1.checksTotal }
        let serverChecks = input.serverDays.reduce(into: (0, 0)) { $0.0 += $1.checksOK; $0.1 += $1.checksTotal }
        let totals = ClientReport.Totals(
            siteUptime: siteChecks.1 > 0 ? Double(siteChecks.0) / Double(siteChecks.1) : nil,
            serverUptime: serverChecks.1 > 0 ? Double(serverChecks.0) / Double(serverChecks.1) : nil,
            siteCount: sites.count, serverCount: servers.count, incidents: incidents.count,
            downtimeSeconds: input.incidents.filter { $0.kind == "down" }.reduce(0) { $0 + clipped($1, p, now: now) },
            prevented: prevented.count, slaTarget: input.slaTarget)

        let status = self.status(totals, incidents, backups)
        return ClientReport(
            clientName: input.clientName, periodStart: p.start, periodEnd: p.end, generatedAt: now,
            signature: input.signature, footer: input.footer, status: status,
            headline: headline(status, totals), detail: incidents.count == 1 ? "\(incidents[0].object): \(incidents[0].title.lowercasedFirst)." : nil,
            totals: totals, prevented: prevented, sites: sites, servers: servers,
            diskCharts: diskCharts(input),
            incidents: incidents, backups: backups,
            work: input.work.sorted { $0.doneAt < $1.doneAt }.map { .init(day: ReportPeriod.day($0.doneAt, p.timeZone), text: $0.text) },
            attention: attention(input, now: now))
    }

    // MARK: - Parts

    static func site(_ input: ReportInput, _ s: ReportInput.SiteInfo, now: Date) -> ClientReport.Site {
        let rows = input.siteDays.filter { $0.siteID == s.id }
        let byDay = Dictionary(rows.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        let days: [ClientReport.DayMark] = input.period.days.map { d in
            guard let r = byDay[d], r.checksTotal > 0 else { return .none }
            if r.downtimeSeconds > 0 { return .down }
            return r.checksOK < r.checksTotal ? .errors : .ok
        }
        let total = rows.reduce(0) { $0 + $1.checksTotal }
        let ok = rows.reduce(0) { $0 + $1.checksOK }
        let timed = rows.filter { $0.latencyAvgMs != nil && $0.checksTotal > 0 }
        let weight = timed.reduce(0) { $0 + $1.checksTotal }
        let latency = weight > 0 ? timed.reduce(0.0) { $0 + $1.latencyAvgMs! * Double($1.checksTotal) } / Double(weight) : nil
        return .init(name: s.name, note: s.note, uptime: total > 0 ? Double(ok) / Double(total) : nil, latencyMs: latency,
                     days: days, tlsDays: s.tlsExpiry.map { daysLeft($0, now) }, domainDays: s.domainExpiry.map { daysLeft($0, now) })
    }

    static func server(_ input: ReportInput, _ s: ReportInput.ServerInfo) -> ClientReport.Server {
        let rows = input.serverDays.filter { $0.serverID == s.id }
        let total = rows.reduce(0) { $0 + $1.checksTotal }
        let ok = rows.reduce(0) { $0 + $1.checksOK }
        return .init(name: s.name, note: s.note, uptime: total > 0 ? Double(ok) / Double(total) : nil,
                     cpuMax: rows.compactMap(\.cpuMax).max(), memMax: rows.compactMap(\.memMax).max(),
                     diskMax: rows.compactMap(\.diskMaxPct).max(), diskRunwayDays: runway(input, s.id),
                     reboots: rows.reduce(0) { $0 + $1.reboots })
    }

    /// Days until the soonest-full disk of a server is full, fitted on the last
    /// `runwayWindow` days up to the end of the period; nil when nothing grows.
    static func runway(_ input: ReportInput, _ serverID: UUID) -> Int? {
        let rows = input.diskDays.filter { $0.serverID == serverID && $0.day <= input.period.end }
        var best: Int?
        for (_, mountRows) in Dictionary(grouping: rows, by: \.mount) {
            let recent = mountRows.sorted { $0.day < $1.day }.suffix(runwayWindow)
            guard recent.count >= 3 else { continue }
            let ys = recent.map(\.percent)
            let xs = (0..<ys.count).map(Double.init)
            let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
            let den = zip(xs, xs).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - mx) }
            guard den > 0 else { continue }
            let slope = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / den
            guard slope > 0.01 else { continue }
            // The epsilon keeps 60.9999… from becoming 60.
            let days = Int(((100 - ys.last!) / slope + 1e-6).rounded(.down))
            best = min(best ?? .max, max(0, days))
        }
        return best
    }

    static func prevented(_ input: ReportInput) -> [ClientReport.Prevented] {
        input.forecasts
            .filter { $0.status == "prevented" && ($0.closedAt.map { $0 >= input.period.from && $0 < input.period.to } ?? false) }
            .sorted { $0.closedAt! < $1.closedAt! }
            .map { f in
                let title: String
                switch f.kind {
                case "disk_full": title = "Диск \(f.objectName) заполнился бы"
                case "tls_expiry": title = "SSL-сертификат \(f.objectName) истёк бы"
                case "domain_expiry": title = "Домен \(f.objectName) истёк бы"
                case "backup_stale": title = "Резервные копии \(f.objectName) перестали бы делаться"
                case "db_growth": title = "База на \(f.objectName) упёрлась бы в место"
                default: title = f.line
                }
                return .init(title: title, detail: f.kind.isKnownForecast ? f.line : nil, seenAt: f.firstSeenAt,
                             wouldHappenAt: f.dueAt, fixedAt: f.closedAt!, fix: f.note)
            }
    }

    static func diskCharts(_ input: ReportInput) -> [ClientReport.DiskChart] {
        let p = input.period
        let days = p.days
        var out: [ClientReport.DiskChart] = []
        for f in input.forecasts where f.kind == "disk_full" && f.status == "prevented" {
            guard let id = f.objectID, let closed = f.closedAt, p.dayIndex(closed) != nil else { continue }
            let rows = input.diskDays.filter { $0.serverID == id && $0.day >= p.start && $0.day <= p.end }
            guard let mount = Dictionary(grouping: rows, by: \.mount)
                .max(by: { ($0.value.map(\.percent).max() ?? 0) < ($1.value.map(\.percent).max() ?? 0) })?.key else { continue }
            let byDay = Dictionary(rows.filter { $0.mount == mount }.map { ($0.day, $0.percent) }, uniquingKeysWith: max)
            let wouldFill = f.dueAt.map { $0.timeIntervalSince(p.from) / 86400 }
            out.append(.init(server: f.objectName, mount: mount, percent: days.map { byDay[$0] },
                             wouldFillDay: wouldFill, fixDay: p.dayIndex(closed), fixLabel: f.note))
        }
        return out
    }

    static func incidents(_ input: ReportInput, now: Date) -> [ClientReport.Incident] {
        let p = input.period
        return input.incidents
            .filter { $0.startedAt < p.to && ($0.endedAt ?? now) > p.from }
            .sorted { $0.startedAt < $1.startedAt }
            .map { i in
                .init(object: i.objectName, title: i.message, startedAt: i.startedAt, durationSeconds: clipped(i, p, now: now),
                      ongoing: i.endedAt == nil, cause: i.cause, resolution: i.resolution, critical: i.severity >= 2)
            }
    }

    static func clipped(_ i: ReportInput.IncidentRow, _ p: ReportPeriod, now: Date) -> Int {
        let start = max(i.startedAt, p.from), end = min(i.endedAt ?? now, p.to)
        return max(0, Int(end.timeIntervalSince(start)))
    }

    static func backups(_ input: ReportInput, now: Date) -> [ClientReport.Backup] {
        let p = input.period
        let periodDays = p.days
        let lastDay = ReportPeriod.day(min(now, p.to.addingTimeInterval(-1)), p.timeZone)
        let groups = Dictionary(grouping: input.backups.filter { $0.startedAt >= p.from && $0.startedAt < p.to }) { "\($0.serverName)\u{0}\($0.target)" }
        return groups.values.map { runs -> ClientReport.Backup in
            let goodDays = Set(runs.filter(\.ok).map { ReportPeriod.day($0.startedAt, p.timeZone) })
            let firstDay = runs.map { ReportPeriod.day($0.startedAt, p.timeZone) }.min()!
            let expectedDays = periodDays.filter { $0 >= firstDay && $0 <= lastDay }
            let lastGood = runs.filter(\.ok).max { $0.startedAt < $1.startedAt }
            return .init(target: runs[0].target, server: runs[0].serverName, good: goodDays.count, expected: expectedDays.count,
                         last: lastGood?.startedAt, lastBytes: lastGood?.sizeBytes,
                         missedDays: expectedDays.filter { !goodDays.contains($0) })
        }.sorted { ($0.server, $0.target) < ($1.server, $1.target) }
    }

    static func attention(_ input: ReportInput, now: Date) -> [ClientReport.Attention] {
        var out: [ClientReport.Attention] = []
        var covered = Set<String>()
        for f in input.forecasts where f.status == "open" {
            if let due = f.dueAt, due.timeIntervalSince(now) > attentionHorizon { continue }
            let title: String
            switch f.kind {
            case "disk_full": title = "Место на диске \(f.objectName)"
            case "tls_expiry": title = "Продлить SSL-сертификат \(f.objectName)"
            case "domain_expiry": title = "Продлить домен \(f.objectName)"
            case "payment": title = "Оплатить \(f.objectName)"
            case "db_growth": title = "Рост базы на \(f.objectName)"
            default: title = f.line
            }
            covered.insert("\(f.kind)|\(f.objectName)")
            out.append(.init(title: title, detail: f.note ?? (f.kind.isKnownForecast ? f.line : nil), due: f.dueAt,
                             needsClient: ["domain_expiry", "payment", "db_growth"].contains(f.kind)))
        }
        for s in input.sites {
            if let d = s.domainExpiry, daysLeft(d, now) <= expiryHorizonDays, !covered.contains("domain_expiry|\(s.name)") {
                out.append(.init(title: "Продлить домен \(s.name)", detail: nil, due: d, needsClient: true))
            }
            if let d = s.tlsExpiry, daysLeft(d, now) <= expiryHorizonDays, !covered.contains("tls_expiry|\(s.name)") {
                out.append(.init(title: "Продлить SSL-сертификат \(s.name)", detail: nil, due: d, needsClient: false))
            }
        }
        // Soonest first; notes without a date at the end.
        return out.enumerated().sorted { a, b in
            switch (a.element.due, b.element.due) {
            case let (x?, y?): return x != y ? x < y : a.offset < b.offset
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a.offset < b.offset
            }
        }.map(\.element)
    }

    static func status(_ t: ClientReport.Totals, _ incidents: [ClientReport.Incident], _ backups: [ClientReport.Backup]) -> ClientReport.Status {
        if let sla = t.slaTarget, let up = t.siteUptime, up < sla { return .critical }
        if incidents.contains(where: { $0.critical && ($0.ongoing || $0.durationSeconds >= 3600) }) { return .critical }
        if !incidents.isEmpty || backups.contains(where: { !$0.missedDays.isEmpty }) { return .issues }
        return .ok
    }

    static func headline(_ s: ClientReport.Status, _ t: ClientReport.Totals) -> String {
        let prevented = t.prevented > 0 ? " Предотвращено проблем: \(t.prevented)." : ""
        if t.incidents == 0 {
            return s == .ok && prevented.isEmpty ? "Всё работало без сбоев." : "Сбоев не было." + prevented
        }
        let downtime = t.downtimeSeconds > 0 ? ", простой \(Fmt.duration(t.downtimeSeconds))" : ""
        return "Сбоев: \(t.incidents)\(downtime)." + prevented
    }

    static func daysLeft(_ date: Date, _ now: Date) -> Int {
        Int((date.timeIntervalSince(now) / 86400).rounded(.down))
    }
}

extension String {
    var isKnownForecast: Bool {
        ["disk_full", "tls_expiry", "domain_expiry", "backup_stale", "db_growth", "payment"].contains(self)
    }

    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
