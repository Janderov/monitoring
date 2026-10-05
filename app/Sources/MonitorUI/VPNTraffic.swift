#if canImport(SwiftUI) && canImport(AppKit)
import Charts
import MonitorCore
import SwiftUI

/// Clients of one VPN with what each used today and this month, counted by
/// the Mac per day, and a daily chart for the client picked in the table.
struct VPNClientsPanel: View {
    @ObservedObject var model: AppModel
    var serverID: String
    var peers: [Snapshot.VPN.Peer]
    var onDelete: ((String, String) async throws -> Void)?
    @State private var traffic = PeerTraffic()
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PeersTable(peers: peers, traffic: traffic, onDelete: onDelete, selection: $selection)
            if let key = selection, let peer = peers.first(where: { $0.publicKey == key }) {
                ClientDailyChart(model: model, serverID: serverID, peer: peer)
            } else if !peers.isEmpty {
                Text(traffic.counted ? "Выберите клиента, чтобы увидеть трафик по дням."
                                     : "Трафик по дням считается с этого обновления; первые цифры появятся через пару минут.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: model.lastRound) { await load() }
    }

    private func load() async {
        let now = Date()
        let cal = Calendar.current
        let monthStart = cal.dateInterval(of: .month, for: now)?.start ?? cal.startOfDay(for: now)
        let today = (try? await model.backend.vpnTraffic(serverID, from: now, to: now)) ?? [:]
        let month = (try? await model.backend.vpnTraffic(serverID, from: monthStart, to: now)) ?? [:]
        let t = PeerTraffic(today: today, month: month)
        if t != traffic { traffic = t }
    }
}

/// Download and upload per day for one client, last 30 days.
struct ClientDailyChart: View {
    @ObservedObject var model: AppModel
    var serverID: String
    var peer: Snapshot.VPN.Peer
    @State private var days: [Day] = []

    struct Day: Identifiable {
        var date: Date
        var kind: String
        var bytes: Double
        var id: String { "\(date.timeIntervalSince1970)|\(kind)" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(peer.name ?? "Клиент") по дням").font(.callout.weight(.semibold))
                Spacer()
                Text(summary).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if days.isEmpty {
                Text("Пока нет данных: Mac считает трафик по дням с этого обновления.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            } else {
                Chart(days) { d in
                    BarMark(x: .value("День", d.date, unit: .day), y: .value("Объём", d.bytes))
                        .foregroundStyle(by: .value("Направление", d.kind))
                }
                .chartForegroundStyleScale(["Скачал": Color.accentColor, "Отдал": Color.orange])
                .chartYAxis {
                    AxisMarks { v in
                        AxisGridLine()
                        AxisValueLabel { if let b = v.as(Double.self) { Text(Fmt.bytes(UInt64(max(0, b)))) } }
                    }
                }
                .chartXAxis { AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                } }
                .frame(height: 160)
            }
        }
        .task(id: "\(peer.publicKey)|\(model.lastRound?.timeIntervalSince1970 ?? 0)") { await load() }
    }

    private var summary: String {
        let down = days.filter { $0.kind == "Скачал" }.reduce(0) { $0 + $1.bytes }
        let up = days.filter { $0.kind == "Отдал" }.reduce(0) { $0 + $1.bytes }
        return "за 30 дней: ↓ \(Fmt.bytes(UInt64(down))) · ↑ \(Fmt.bytes(UInt64(up)))"
    }

    private func load() async {
        let now = Date()
        let from = Calendar.current.date(byAdding: .day, value: -29, to: Calendar.current.startOfDay(for: now)) ?? now
        let rows = (try? await model.backend.vpnDaily(serverID, publicKey: peer.publicKey, from: from, to: now)) ?? []
        // Store rx is the client's upload, tx its download.
        days = rows.flatMap { r in
            [Day(date: r.day, kind: "Скачал", bytes: Double(r.usage.tx)),
             Day(date: r.day, kind: "Отдал", bytes: Double(r.usage.rx))]
        }
    }
}
#endif
