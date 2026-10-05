#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import MonitorCore
import SwiftUI

/// Servers: sortable table on the left, the selected server on the right.
struct ServersScreen: View {
    @ObservedObject var model: AppModel
    @State private var sort = [KeyPathComparator(\ServerRowData.severity, order: .reverse)]
    @State private var search = ""

    var body: some View {
        HSplitView {
            table
                .frame(minWidth: 360, idealWidth: 600, maxWidth: 640)
            Group {
                if let id = model.selectedServerID, let s = model.status(id) {
                    ServerDetail(model: model, status: s)
                        .id(id)
                } else {
                    if model.statuses.isEmpty {
                        EmptyNote(title: "Серверов пока нет", detail: nil,
                                  actionTitle: "Добавить сервер…", action: { model.present(.addServer) })
                    } else {
                        EmptyNote(title: "Выберите сервер")
                    }
                }
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
        }
        .navigationTitle(model.filter.map(filterTitle) ?? "Серверы")
        .navigationSubtitle(subtitle)
        .searchable(text: $search, placement: .toolbar, prompt: "Поиск")
    }

    private var rows: [ServerRowData] {
        model.visible
            .filter { search.isEmpty || $0.server.name.localizedCaseInsensitiveContains(search)
                || $0.server.host.contains(search) }
            .map(ServerRowData.init)
            .sorted(using: sort)
    }

    private var subtitle: String {
        let n = model.visible.count
        if let t = model.lastRound { return "\(n) · опрос \(Fmt.relative(t))" }
        return "\(n)"
    }

    private func filterTitle(_ f: Filter) -> String {
        switch f {
        case .group(let g): return g
        case .tag(let t): return "#\(t)"
        }
    }

    private var table: some View {
        Table(rows, selection: $model.selectedServerID, sortOrder: $sort) {
            TableColumn("Имя", value: \.name) { r in
                HStack(spacing: 7) {
                    StatusDot(level: r.status.level)
                    Text(r.name)
                }
            }
            .width(min: 110, ideal: 150)
            TableColumn("Группа", value: \.group) { r in Text(r.group).foregroundStyle(.secondary).help(r.group) }
                .width(min: 60, ideal: 96)
            TableColumn("CPU", value: \.cpu) { r in metric(r.cpu, warn: r.status.alerts.contains { $0.key.hasPrefix("cpu") }) }
                .width(min: 44, ideal: 52)
            TableColumn("Память", value: \.mem) { r in metric(r.mem, warn: r.status.alerts.contains { $0.key.hasPrefix("mem") }) }
                .width(min: 50, ideal: 60)
            TableColumn("Диск", value: \.disk) { r in metric(r.disk, warn: r.status.alerts.contains { $0.key.hasPrefix("disk") }) }
                .width(min: 44, ideal: 52)
            TableColumn("Load", value: \.load) { r in
                Text(r.status.snapshot.map { String(format: "%.2f", $0.load.one) } ?? "—").monospacedDigit()
            }
            .width(min: 40, ideal: 48)
            TableColumn("Аптайм", value: \.uptime) { r in
                Text(r.status.snapshot.map { Fmt.duration($0.uptimeSeconds) } ?? "—").foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 56, ideal: 64)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let s = model.status(id) {
                ServerContextMenu(model: model, server: s.server)
            }
        } primaryAction: { ids in
            if let id = ids.first, let s = model.status(id) { model.openSSH(s.server) }
        }
    }

    private func metric(_ v: Double, warn: Bool) -> some View {
        Text(v < 0 ? "—" : Fmt.percent(v))
            .monospacedDigit()
            .foregroundStyle(warn ? Color.orange : (v < 0 ? Color.secondary : Color.primary))
            .fontWeight(warn ? .semibold : .regular)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Sortable values for the table; -1 means "no data" and sorts last.
struct ServerRowData: Identifiable {
    var status: ServerStatus
    var id: String { status.id }
    var name: String { status.server.name }
    var group: String { status.server.group ?? "" }
    var severity: Int { status.level.rawValue }
    var cpu: Double { status.snapshot?.cpu.usagePercent ?? -1 }
    var mem: Double { status.snapshot?.memory.usedPercent ?? -1 }
    var disk: Double { status.snapshot?.maxDiskPercent ?? -1 }
    var load: Double { status.snapshot?.load.one ?? -1 }
    var uptime: Double { status.snapshot?.uptimeSeconds ?? -1 }

    init(_ s: ServerStatus) { status = s }
}

struct ServerContextMenu: View {
    @ObservedObject var model: AppModel
    var server: ServerConfig

    var body: some View {
        if model.can(.ssh, server) {
            Button("Открыть SSH") { model.openSSH(server) }
        }
        Button("Скопировать адрес") { model.copyAddress(server) }
        Button("Опросить сейчас") { Task { await model.pollNow() } }
        Divider()
        Button("Показать на карте") {
            model.selectedServerID = server.id
            model.section = .map
        }
        if model.can(.editConfig, server) {
            Divider()
            Button("Изменить…") { model.present(.editServer(server.id)) }
        }
        if model.can(.installAgent, server), model.backend.canInstallAgent {
            Button("Переустановить агента…") { model.present(.reinstallAgent(server.id)) }
        }
    }
}
#endif
