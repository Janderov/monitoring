#if canImport(SwiftUI) && canImport(AppKit)
import MonitorCore
import SwiftUI

/// AmneziaVPN on all servers: protocols on top, clients of the selected one below.
struct VPNScreen: View {
    @ObservedObject var model: AppModel
    @State private var selection: String?

    private struct Row: Identifiable {
        var server: ServerConfig
        var vpn: Snapshot.VPN
        var id: String { "\(server.id)|\(vpn.container)" }
    }

    private var allRows: [Row] {
        model.visible.flatMap { s in (s.snapshot?.vpn ?? []).map { Row(server: s.server, vpn: $0) } }
    }

    var body: some View {
        let rows = allRows
        VSplitView {
            Table(rows, selection: $selection) {
                TableColumn("Сервер") { r in
                    HStack(spacing: 7) {
                        StatusDot(level: r.vpn.running ? .ok : .critical)
                        Text(r.server.name)
                    }
                }
                TableColumn("Контейнер") { r in Text(r.vpn.container).foregroundStyle(.secondary) }
                TableColumn("Протокол") { r in Text(r.vpn.protocol) }
                TableColumn("Состояние") { r in Text(r.vpn.running ? "работает" : "остановлен") }
                TableColumn("Клиенты") { r in
                    Text(r.vpn.clientsKnown == true ? "\(r.vpn.clients)" : "не читаются").monospacedDigit()
                        .foregroundStyle(r.vpn.clientsKnown == true ? .primary : .secondary)
                }
                TableColumn("Онлайн") { r in
                    Text(r.vpn.clientsKnown == true ? "\(r.vpn.activeClients)" : "—").monospacedDigit()
                }
                TableColumn("Трафик ↓ / ↑") { r in
                    Text(r.vpn.clientsKnown == true ? "\(Fmt.bytes(r.vpn.rxBytes)) / \(Fmt.bytes(r.vpn.txBytes))" : "—")
                        .monospacedDigit()
                }
            }
            .frame(minHeight: 140, idealHeight: 220)

            Group {
                if let id = selection, let r = rows.first(where: { $0.id == id }) {
                    if let peers = r.vpn.peers, !peers.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Клиенты \(r.vpn.protocol) на \(r.server.name)").font(.headline)
                                VPNClientsPanel(model: model, serverID: r.server.id, peers: peers)
                                    .id(r.id)
                            }
                            .padding(16)
                        }
                    } else {
                        EmptyNote(title: "Список клиентов для \(r.vpn.protocol) пока не читается")
                    }
                } else {
                    EmptyNote(title: rows.isEmpty ? "AmneziaVPN не найден ни на одном сервере" : "Выберите протокол, чтобы увидеть клиентов",
                              detail: rows.isEmpty ? nil : "Создание и удаление ключей появится следующим шагом")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle("VPN")
        .navigationSubtitle(subtitle(rows))
        .onAppear {
            if selection == nil { selection = rows.first(where: { $0.vpn.clientsKnown == true })?.id }
        }
    }

    private func subtitle(_ rows: [Row]) -> String {
        let total = rows.reduce(0) { $0 + $1.vpn.clients }
        let online = rows.reduce(0) { $0 + $1.vpn.activeClients }
        return "\(online) онлайн из \(total)"
    }
}
#endif
