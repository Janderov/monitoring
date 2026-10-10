#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import Charts
import MonitorCore
import SwiftUI

struct SitesTable: View {
    @ObservedObject var model: AppModel
    var sites: [SiteSummary]
    @Binding var selection: String?

    var body: some View {
        Table(sites, selection: $selection) {
            TableColumn("Сайт") { s in
                HStack(spacing: 7) { StatusDot(level: s.level()); Text(s.name).lineLimit(1) }
            }
            TableColumn("Клиент") { s in ClientTags(clients: model.ownerClients(site: s.id)) }.width(min: 60, ideal: 90)
            TableColumn("Код") { s in Text(s.statusCode.map(String.init) ?? "—").monospacedDigit() }.width(min: 40, ideal: 50)
            TableColumn("Ответ, среднее") { s in Text(s.averageLatency.map(Fmt.ms) ?? "—").monospacedDigit() }
            TableColumn("Откуда проверяется") { s in
                Text(s.origins.map { origin($0) }.joined(separator: ", ")).foregroundStyle(.secondary).lineLimit(1)
            }
            TableColumn("SSL") { s in days(s.tlsExpiry, warn: 14) }.width(min: 40, ideal: 56)
            TableColumn("Домен") { s in days(s.domainExpiry, warn: 30) }.width(min: 40, ideal: 60)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let site = sites.first(where: { $0.id == id }) {
                if let url = URL(string: site.url) {
                    Button("Открыть в браузере") { NSWorkspace.shared.open(url) }
                }
                Button("Изменить…") { model.present(.editSite(id)) }
            } else {
                Button("Добавить сайт…") { model.present(.addSite) }
            }
        } primaryAction: { ids in
            if let id = ids.first {
                model.section = .sites
                model.selectedSiteID = id
            }
        }
    }

    private func origin(_ o: SiteSummary.Origin) -> String {
        let name = o.server.flatMap { Country.detect($0)?.code } ?? o.serverName
        if o.check == nil { return "\(name) ?" }
        return o.ok ? name : "\(name) ✕"
    }

    private func days(_ date: Date?, warn: Int) -> some View {
        let d = date.map { Fmt.days(until: $0) }
        return Text(d.map { "\($0) д" } ?? "—").monospacedDigit()
            .foregroundStyle((d ?? Int.max) <= warn ? Color.orange : Color.primary)
    }
}

/// Sites: list on the left, the selected site on the right.
struct SitesScreen: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let sites = model.scopedSites
        HSplitView {
            SitesTable(model: model, sites: sites, selection: $model.selectedSiteID)
                .frame(minWidth: 320, idealWidth: 420, maxWidth: 560)
            Group {
                if let id = model.selectedSiteID, let site = sites.first(where: { $0.id == id }) {
                    SiteDetail(model: model, site: site)
                } else if sites.isEmpty {
                    EmptyNote(title: "Сайтов пока нет", detail: "Каждый сайт проверяется раз в минуту со всех серверов",
                              actionTitle: "Добавить сайт…", action: { model.present(.addSite) })
                } else {
                    EmptyNote(title: "Выберите сайт")
                }
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
        }
        .navigationTitle("Сайты")
        .navigationSubtitle("\(sites.count) · проверка раз в минуту с каждого сервера")
    }
}

private struct SiteDetail: View {
    @ObservedObject var model: AppModel
    var site: SiteSummary
    @AppStorage("sitePeriod") private var period: SitePeriod = .day

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(site.name).font(.title2.weight(.semibold)).lineLimit(1)
                            StatusBadge(level: site.level())
                        }
                        Text(site.url).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    if let url = URL(string: site.url) {
                        Button("Открыть в браузере") { NSWorkspace.shared.open(url) }
                    }
                    Button("Изменить…") { model.present(.editSite(site.id)) }
                }
                ForEach(site.alerts, id: \.key) { a in
                    AlertStrip(level: a.severity.level, text: a.message, trailing: Fmt.since(a.since))
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 20, alignment: .leading)],
                          alignment: .leading, spacing: 10) {
                    Group {
                        Fact(title: "Отвечают", value: "\(site.origins.filter(\.ok).count) из \(site.origins.count)")
                        Fact(title: "Среднее время ответа", value: site.averageLatency.map(Fmt.ms) ?? "—")
                        Fact(title: "SSL до", value: date(site.tlsExpiry))
                        Fact(title: site.domain.map { "Домен \($0) до" } ?? "Домен до",
                             value: site.domainExpiry.map { date($0) } ?? (site.domainError ?? "—"))
                    }
                }
                SiteHistory(model: model, site: site, period: $period)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func date(_ d: Date?) -> String {
        d.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—"
    }
}

enum SitePeriod: String, CaseIterable, Identifiable {
    case day = "24 ч", week = "7 д", month = "30 д"
    var id: String { rawValue }
    var seconds: TimeInterval {
        switch self {
        case .day: return 86400
        case .week: return 7 * 86400
        case .month: return 30 * 86400
        }
    }
    /// Minute samples are averaged into buckets so long periods stay light.
    var bucket: TimeInterval {
        switch self {
        case .day: return 600
        case .week: return 3600
        case .month: return 4 * 3600
        }
    }
}

/// Per-country availability and response time over the period.
private struct SiteHistory: View {
    @ObservedObject var model: AppModel
    var site: SiteSummary
    @Binding var period: SitePeriod
    @State private var samples: [Store.SiteSample] = []

    private struct Point: Identifiable {
        var time: Date
        var latency: Double
        var place: String
        var id: String { "\(place)|\(time.timeIntervalSince1970)" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Доступность по странам").font(.headline)
                Spacer()
                Picker("Период", selection: $period) {
                    ForEach(SitePeriod.allCases) { p in Text(p.rawValue).tag(p) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            Table(site.origins) {
                TableColumn("Откуда") { o in
                    HStack(spacing: 7) {
                        StatusDot(level: o.check == nil ? .unknown : (o.ok ? .ok : .critical))
                        Text(o.place).lineLimit(1)
                        Text(o.serverName).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                TableColumn("Сейчас") { o in
                    Text(o.check.map { $0.ok ? Fmt.ms($0.latencyMs) : ($0.statusCode.map { "HTTP \($0)" } ?? "нет ответа") } ?? "нет данных")
                        .monospacedDigit().lineLimit(1)
                }
                .width(min: 70, ideal: 90)
                TableColumn("Доступность") { o in Text(uptime(o.serverID)).monospacedDigit() }
                    .width(min: 70, ideal: 90)
                TableColumn("Ошибка") { o in Text(o.check?.error ?? "").foregroundStyle(.secondary).lineLimit(1) }
            }
            .fitRows(site.origins.count, max: 10)

            GroupBox {
                let points = buckets()
                if points.isEmpty {
                    Text("Нет данных за период").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 140)
                } else {
                    Chart(points) { p in
                        LineMark(x: .value("Время", p.time), y: .value("мс", p.latency))
                            .foregroundStyle(by: .value("Откуда", p.place))
                            .lineStyle(StrokeStyle(lineWidth: 1.2))
                    }
                    .chartYAxis {
                        AxisMarks { v in
                            AxisGridLine().foregroundStyle(.quaternary)
                            AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.ms(d)) } }
                        }
                    }
                    .chartLegend(position: .bottom, alignment: .leading)
                    .frame(height: 160)
                }
            } label: {
                Text("Время ответа").font(.callout.weight(.semibold))
            }
        }
        .task(id: "\(site.id)|\(period.rawValue)|\(model.lastRound?.timeIntervalSince1970 ?? 0)") {
            let now = Date()
            samples = (try? await model.backend.siteSamples(site.id, from: now.addingTimeInterval(-period.seconds), to: now)) ?? []
        }
    }

    private func uptime(_ serverID: String) -> String {
        let mine = samples.filter { $0.serverID == serverID }
        if mine.isEmpty { return "—" }
        let ok = Double(mine.filter(\.ok).count) / Double(mine.count) * 100
        return ok >= 99.95 ? "100%" : String(format: "%.1f%%", ok)
    }

    /// Average response time of successful checks per place and bucket.
    private func buckets() -> [Point] {
        let names = Dictionary(site.origins.map { ($0.serverID, $0.place) }, uniquingKeysWith: { a, _ in a })
        var sums: [String: (Double, Int)] = [:]
        for s in samples where s.ok {
            let t = (s.time.timeIntervalSince1970 / period.bucket).rounded(.down) * period.bucket
            let key = "\(s.serverID)|\(t)"
            let cur = sums[key] ?? (0, 0)
            sums[key] = (cur.0 + s.latencyMs, cur.1 + 1)
        }
        return sums.compactMap { key, v -> Point? in
            let parts = key.split(separator: "|")
            guard parts.count == 2, let t = Double(parts[1]) else { return nil }
            let id = String(parts[0])
            return Point(time: Date(timeIntervalSince1970: t), latency: v.0 / Double(v.1), place: names[id] ?? id)
        }
        .sorted { $0.time < $1.time }
    }
}
#endif
