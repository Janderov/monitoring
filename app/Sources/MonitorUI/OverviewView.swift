#if canImport(SwiftUI) && canImport(AppKit)
import Charts
import MonitorCore
import SwiftUI

/// The answer to "is everything fine?" on one page.
struct OverviewView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let err = model.configError {
                    AlertStrip(level: .warning, text: err, trailing: nil)
                }
                summary
                problems
                servers
                sites
            }
            .padding(20)
        }
        .navigationTitle("Обзор")
        .navigationSubtitle(model.lastRound.map { "опрос \(Fmt.relative($0))" } ?? "")
    }

    private var summary: some View {
        let crit = model.problems.filter { $0.alert.severity == .critical }.count
        let down = model.statuses.filter { $0.alerts.contains { $0.key == "down" } }.count
        let vpnOnline = model.statuses.reduce(0) { $0 + ($1.snapshot?.vpnActiveClients ?? 0) }
        let vpnTotal = model.statuses.reduce(0) { s, st in s + (st.snapshot?.vpn?.reduce(0) { $0 + $1.clients } ?? 0) }
        let sites = model.sites
        return GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 0) {
                GridRow {
                    stat("Серверы", "\(model.statuses.count)", down > 0 ? "\(down) не отвечает" : "все отвечают", down > 0)
                    stat("Сайты", "\(sites.count)",
                         sites.contains { $0.level() == .critical } ? "есть недоступные" : "все отвечают",
                         sites.contains { $0.level() == .critical })
                    stat("VPN-клиенты онлайн", "\(vpnOnline)", vpnTotal > 0 ? "из \(vpnTotal)" : "нет данных", false)
                    stat("Активные проблемы", "\(model.problems.count)",
                         crit > 0 ? "\(crit) критичных" : (model.problems.isEmpty ? "нет" : "только предупреждения"), crit > 0)
                }
            }
        }
    }

    private func stat(_ title: String, _ value: String, _ note: String, _ bad: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(note).font(.caption).foregroundStyle(bad ? Color.red : Color.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
    }

    private var problems: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Активные проблемы").font(.headline)
            if model.problems.isEmpty {
                Text("Проблем нет").foregroundStyle(.secondary)
            } else {
                ProblemsTable(model: model)
                    .frame(height: tableHeight(model.problems.count, max: 8))
            }
        }
    }

    private var servers: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Серверы").font(.headline)
                Text("CPU за последний час").font(.caption).foregroundStyle(.secondary)
            }
            Table(model.statuses) {
                TableColumn("Имя") { s in
                    HStack(spacing: 7) { StatusDot(level: s.level); Text(s.server.name) }
                }
                TableColumn("Страна") { s in Text(s.country?.name ?? s.server.group ?? "—").foregroundStyle(.secondary) }
                TableColumn("CPU, 1 ч") { s in Sparkline(model: model, serverID: s.id, tick: s.lastSeen) }
                    .width(min: 120, ideal: 150)
                TableColumn("CPU") { s in num(s.snapshot.map { Fmt.percent($0.cpu.usagePercent) }) }
                TableColumn("Память") { s in num(s.snapshot.map { Fmt.percent($0.memory.usedPercent) }) }
                TableColumn("Диск") { s in num(s.snapshot.map { Fmt.percent($0.maxDiskPercent) }) }
                TableColumn("Сеть ↓ / ↑") { s in
                    num(s.snapshot.map { "\(Fmt.rate($0.network.rxBytesPerSec)) / \(Fmt.rate($0.network.txBytesPerSec))" })
                }
                TableColumn("Аптайм") { s in num(s.snapshot.map { Fmt.duration($0.uptimeSeconds) }) }
            }
            .frame(height: tableHeight(model.statuses.count, max: 12))
            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                if let id = ids.first { model.show(server: id) }
            }
        }
    }

    @ViewBuilder private var sites: some View {
        let sites = model.sites
        if !sites.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Сайты").font(.headline)
                    Text("время ответа с каждого сервера").font(.caption).foregroundStyle(.secondary)
                }
                SitesTable(model: model, sites: sites, selection: .constant(nil))
                    .frame(height: tableHeight(sites.count, max: 8))
            }
        }
    }

    private func num(_ s: String?) -> some View {
        Text(s ?? "—").monospacedDigit().foregroundStyle(s == nil ? Color.secondary : Color.primary)
    }
}

/// CPU of the last hour as a tiny line.
struct Sparkline: View {
    @ObservedObject var model: AppModel
    var serverID: String
    var tick: Date?
    @State private var values: [Store.Sample] = []

    var body: some View {
        Chart(values, id: \.time) { s in
            LineMark(x: .value("t", s.time), y: .value("cpu", s.cpu))
                .foregroundStyle(Color.blue)
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...100)
        .frame(height: 18)
        .task(id: tick) {
            let now = Date()
            values = (try? await model.backend.samples(serverID, from: now.addingTimeInterval(-3600), to: now)) ?? []
        }
    }
}

struct ProblemsTable: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Table(model.problems) {
            TableColumn("Важность") { p in
                HStack(spacing: 6) {
                    StatusDot(level: p.alert.severity.level)
                    Text(p.alert.severity == .critical ? "Критично" : "Внимание")
                        .foregroundStyle(p.alert.severity.level.textColor).fontWeight(.medium)
                }
            }
            .width(min: 100, ideal: 110)
            TableColumn("Объект") { p in Text(p.status.server.name) }.width(min: 80, ideal: 120)
            TableColumn("Что случилось") { p in Text(p.alert.message) }
            TableColumn("Началось") { p in Text(Fmt.time(p.alert.since)).foregroundStyle(.secondary).monospacedDigit() }
                .width(min: 70, ideal: 90)
            TableColumn("Длится") { p in Text(Fmt.since(p.alert.since)).monospacedDigit() }.width(min: 70, ideal: 90)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let p = model.problems.first(where: { $0.id == id }) {
                ServerContextMenu(model: model, server: p.status.server)
                Button("Открыть сервер") { model.show(server: p.status.id) }
            }
        } primaryAction: { ids in
            if let id = ids.first, let p = model.problems.first(where: { $0.id == id }) { model.show(server: p.status.id) }
        }
    }
}

struct ProblemsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if model.problems.isEmpty {
                EmptyNote(title: "Проблем нет", detail: model.statuses.isEmpty ? nil : "Все серверы в норме")
            } else {
                ProblemsTable(model: model)
            }
        }
        .navigationTitle("Проблемы")
        .navigationSubtitle("\(model.problems.count)")
    }
}

struct JournalView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        EventsList(model: model, serverID: nil, limit: 1000)
            .navigationTitle("Журнал")
            .navigationSubtitle("оповещения всех серверов")
    }
}
#endif
