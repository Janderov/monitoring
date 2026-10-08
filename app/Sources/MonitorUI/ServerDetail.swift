#if canImport(SwiftUI) && canImport(AppKit)
import Charts
import MonitorCore
import SwiftUI

enum Period: String, CaseIterable, Identifiable {
    case hour = "1 ч", day = "24 ч", week = "7 д", month = "30 д", quarter = "90 д", year = "1 год"
    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .hour: return 3600
        case .day: return 86400
        case .week: return 7 * 86400
        case .month: return 30 * 86400
        case .quarter: return 90 * 86400
        case .year: return 365 * 86400
        }
    }

    /// Minute samples for short periods, hourly rollups for long ones (the
    /// minute data is kept 30 days, the hourly one a year).
    var usesHourly: Bool { self != .hour && self != .day }
    /// Points are averaged over this step so long periods stay readable.
    var bucket: TimeInterval {
        switch self {
        case .hour: return 60
        case .day: return 300
        case .week, .month: return 3600
        case .quarter: return 6 * 3600
        case .year: return 86400
        }
    }
    /// A gap longer than this breaks the line (the Mac slept, the agent was down).
    var gap: TimeInterval { usesHourly ? max(3 * 3600, bucket * 3) : 3 * 60 }
}

struct ServerDetail: View {
    enum Tab: String, CaseIterable, Identifiable {
        case metrics = "Метрики", services = "Сервисы", containers = "Контейнеры", databases = "Базы данных", vpn = "VPN",
             processes = "Процессы", checks = "Проверки", events = "События"
        var id: String { rawValue }
    }

    @ObservedObject var model: AppModel
    var status: ServerStatus
    @State private var tab: Tab = .metrics
    @AppStorage("period") private var period: Period = .day

    private var snap: Snapshot? { status.snapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                ForEach(status.alerts, id: \.key) { a in
                    AlertStrip(level: a.severity.level, text: a.message, trailing: Fmt.since(a.since))
                }
                if let err = status.error, status.alerts.isEmpty {
                    AlertStrip(level: .unknown, text: "Последний опрос не удался: \(err)", trailing: nil)
                }
                ForEach(snap?.errors ?? [], id: \.self) { e in
                    Label(e, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
                facts
                // A segmented control cannot shrink below its labels, so a
                // narrow pane gets a pop-up menu instead of clipping.
                ViewThatFits(in: .horizontal) {
                    tabPicker.pickerStyle(.segmented).fixedSize()
                    tabPicker.pickerStyle(.menu).fixedSize()
                }
                if tab == .metrics {
                    HStack {
                        Spacer()
                        Picker("Период", selection: $period) {
                            ForEach(Period.allCases) { p in Text(p.rawValue).tag(p) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                content
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var tabPicker: some View {
        Picker("Раздел", selection: $tab) {
            ForEach(Tab.allCases) { t in Text(t.rawValue).tag(t) }
        }
        .labelsHidden()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(status.server.name).font(.title2.weight(.semibold)).lineLimit(1)
                    StatusBadge(level: status.level)
                }
                Text(subtitle).foregroundStyle(.secondary).monospacedDigit().lineLimit(2).textSelection(.enabled)
            }
            Spacer()
            if model.can(.ssh, status.server) {
                Button { model.openSSH(status.server) } label: { Label("SSH", systemImage: "terminal") }
                    .buttonStyle(.borderedProminent)
                    .help("Открыть Терминал с подключением (⇧⌘S)")
            }
            Button("Опросить") { Task { await model.pollNow() } }
            Menu {
                ServerContextMenu(model: model, server: status.server)
            } label: { Image(systemName: "ellipsis") }
                .menuIndicator(.hidden)
                .fixedSize()
        }
    }

    private var subtitle: String {
        var parts = [status.server.host]
        if let c = status.country { parts.append(c.name) }
        if let g = status.server.group, ![status.country?.code, status.country?.name].contains(g) { parts.append(g) }
        parts += status.server.tags ?? []
        return parts.joined(separator: " · ")
    }

    private var facts: some View {
        // Wraps onto more rows when the pane is narrow.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 20, alignment: .leading)],
                  alignment: .leading, spacing: 10) {
            Group {
                Fact(title: "Аптайм", value: snap.map { Fmt.duration($0.uptimeSeconds) } ?? "—")
                Fact(title: "Включён", value: snap.map { Fmt.time($0.bootTime) } ?? "—")
                Fact(title: "Load 1 · 5 · 15",
                     value: snap.map { String(format: "%.2f · %.2f · %.2f", $0.load.one, $0.load.five, $0.load.fifteen) } ?? "—")
                Fact(title: "Память", value: snap.map {
                    "\(Fmt.bytes($0.memory.totalBytes - min($0.memory.availableBytes, $0.memory.totalBytes))) из \(Fmt.bytes($0.memory.totalBytes))"
                } ?? "—")
                Fact(title: "Процессор", value: snap.map { "\($0.cpu.cores) ядер" } ?? "—")
                Fact(title: "Обновлено", value: status.lastSeen.map(Fmt.relative) ?? "нет данных")
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .metrics: MetricsTab(model: model, status: status, period: period)
        case .services: ServicesTab(services: snap?.services ?? [])
        case .containers: ContainersTab(model: model, server: status.server, containers: snap?.containers ?? [])
        case .databases: DatabasesTab(databases: snap?.databases)
        case .vpn: VPNTab(model: model, server: status.server, vpn: snap?.vpn ?? [], links: snap?.links ?? [])
        case .processes: ProcessesTab(processes: snap?.processes ?? [])
        case .checks: ChecksTab(model: model, checks: snap?.checks ?? [])
        case .events: EventsList(model: model, serverID: status.id)
        }
    }
}

// MARK: - Metrics

struct ChartPoint: Identifiable {
    var time: Date
    var value: Double
    var series: String
    var segment: Int
    var id: String { "\(series)|\(time.timeIntervalSince1970)" }
}

private struct MetricsTab: View {
    @ObservedObject var model: AppModel
    var status: ServerStatus
    var period: Period
    @State private var points: [String: [ChartPoint]] = [:]

    private var reloadKey: String { "\(status.id)|\(period.rawValue)|\(status.lastSeen?.timeIntervalSince1970 ?? 0)" }

    private var thresholds: Thresholds { status.server.thresholds?.resolved ?? Thresholds.defaults }

    var body: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                ChartBox(title: "CPU", value: status.snapshot.map { "сейчас \(Fmt.percent($0.cpu.usagePercent))" },
                         points: points["cpu"] ?? [], percent: true, threshold: thresholds.cpuPercent, period: period)
                ChartBox(title: "Память", value: status.snapshot.map { Fmt.percent($0.memory.usedPercent) },
                         points: points["mem"] ?? [], percent: true, threshold: thresholds.memoryPercent, period: period)
            }
            GridRow {
                ChartBox(title: "Сеть", value: status.snapshot.map {
                    "↓ \(Fmt.rate($0.network.rxBytesPerSec)) · ↑ \(Fmt.rate($0.network.txBytesPerSec))"
                }, points: (points["rx"] ?? []) + (points["tx"] ?? []), percent: false, threshold: nil, period: period,
                         legend: [LegendItem(name: "↓ входящий", color: .blue), LegendItem(name: "↑ исходящий", color: .primary)])
                DisksBox(disks: status.snapshot?.disks ?? [], threshold: thresholds.diskPercent)
            }
            GridRow {
                LinkLatencyBox(model: model, serverID: status.id, period: period, reload: reloadKey)
                    .gridCellColumns(2)
            }
            if (status.snapshot?.vpn ?? []).contains(where: { $0.clientsKnown == true }) {
                GridRow {
                    ChartBox(title: "VPN-клиенты онлайн", value: status.snapshot.map { "\($0.vpnActiveClients)" },
                             points: points["vpn"] ?? [], percent: false, threshold: nil, period: period, integer: true)
                        .gridCellColumns(2)
                }
            }
        }
        .task(id: reloadKey) { await load() }
    }

    private func load() async {
        let to = Date(), from = to.addingTimeInterval(-period.seconds)
        var rows: [(Date, [String: Double])] = []
        do {
            if period.usesHourly {
                rows = try await model.backend.hourly(status.id, from: from, to: to).map {
                    ($0.hour, ["cpu": $0.cpuAvg, "mem": $0.memAvg, "rx": $0.rxAvg, "tx": $0.txAvg, "vpn": Double($0.vpnMax)])
                }
            } else {
                rows = try await model.backend.samples(status.id, from: from, to: to).map {
                    ($0.time, ["cpu": $0.cpu, "mem": $0.mem, "rx": $0.rx, "tx": $0.tx, "vpn": Double($0.vpnClients)])
                }
            }
        } catch {
            rows = []
        }
        if period.bucket > 3600 { rows = Self.average(rows, over: period.bucket) }
        var out: [String: [ChartPoint]] = [:]
        var segment = 0
        var last: Date?
        for (t, values) in rows {
            if let last, t.timeIntervalSince(last) > period.gap { segment += 1 }
            last = t
            for (k, v) in values { out[k, default: []].append(ChartPoint(time: t, value: v, series: k, segment: segment)) }
        }
        points = out
    }

    /// Averages rows into buckets of `step` seconds, oldest first.
    static func average(_ rows: [(Date, [String: Double])], over step: TimeInterval) -> [(Date, [String: Double])] {
        var sums: [TimeInterval: (values: [String: Double], count: Int)] = [:]
        for (t, values) in rows {
            let key = (t.timeIntervalSince1970 / step).rounded(.down) * step
            var cur = sums[key] ?? ([:], 0)
            for (k, v) in values { cur.values[k, default: 0] += v }
            cur.count += 1
            sums[key] = cur
        }
        return sums.keys.sorted().map { key in
            let e = sums[key]!
            return (Date(timeIntervalSince1970: key), e.values.mapValues { $0 / Double(e.count) })
        }
    }
}

struct LegendItem {
    var name: String
    var color: Color
}

struct ChartBox: View {
    var title: String
    var value: String?
    var points: [ChartPoint]
    var percent: Bool
    var threshold: Double?
    var period: Period
    var legend: [LegendItem] = []
    var integer = false

    var body: some View {
        GroupBox {
            if points.isEmpty {
                Text("Нет данных за период").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    chart.frame(height: 120)
                    if !legend.isEmpty {
                        HStack(spacing: 12) {
                            ForEach(legend, id: \.name) { item in
                                HStack(spacing: 4) {
                                    RoundedRectangle(cornerRadius: 1).fill(item.color).frame(width: 12, height: 2)
                                    Text(item.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            // Title and value stack so a narrow pane never pushes the box wider.
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                if let value {
                    Text(value).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(points) { p in
                LineMark(x: .value("Время", p.time), y: .value(title, p.value),
                         series: .value("Линия", "\(p.series)-\(p.segment)"))
                    .foregroundStyle(p.series == "tx" ? Color.primary.opacity(0.7) : Color.blue)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
            }
            if let threshold {
                RuleMark(y: .value("Порог", threshold))
                    .foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartYScale(domain: percent ? 0...100 : 0...(maxValue * 1.15 + (integer ? 1 : 0)))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text(label(d)).font(.caption2) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel(format: period.usesHourly ? .dateTime.day().month(.abbreviated) : .dateTime.hour().minute())
            }
        }
    }

    private var maxValue: Double { max(points.map(\.value).max() ?? 1, 1) }

    private func label(_ v: Double) -> String {
        if percent { return Fmt.percent(v) }
        if integer { return String(Int(v)) }
        return Fmt.rate(v)
    }
}

private struct DisksBox: View {
    var disks: [Snapshot.Disk]
    var threshold: Double?

    var body: some View {
        GroupBox {
            if disks.isEmpty {
                Text("Нет данных").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(disks, id: \.mount) { d in
                        let over = d.usedPercent >= (threshold ?? 90)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(d.mount).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                                Text(d.fstype).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(Fmt.percent(d.usedPercent)).foregroundStyle(over ? Color.orange : Color.primary)
                                    .fontWeight(over ? .semibold : .regular)
                            }
                            .font(.callout).monospacedDigit()
                            ProgressView(value: min(d.usedPercent, 100), total: 100)
                                .tint(over ? .orange : .accentColor)
                            Text("\(Fmt.bytes(d.freeBytes)) свободно из \(Fmt.bytes(d.totalBytes))")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .top)
            }
        } label: {
            Text("Диски").font(.callout.weight(.semibold))
        }
    }
}
#endif
