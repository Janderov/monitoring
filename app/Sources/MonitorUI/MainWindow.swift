#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import MonitorCore
import SwiftUI

/// The main window: sidebar with sections, groups and tags; content on the right.
public struct MainWindow: View {
    public static let id = "main"
    @ObservedObject var model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            detail
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button { Task { await model.pollNow() } } label: {
                            Label("Опросить сейчас", systemImage: "arrow.clockwise")
                        }
                        .help("Опросить сейчас (⌘R)")
                        Menu {
                            Button("Открыть servers.json") { model.openConfig() }
                            Button("Перечитать список серверов") { Task { await model.reload() } }
                        } label: {
                            Label("Добавить сервер", systemImage: "plus")
                        }
                        .help("Пока серверы добавляются в servers.json; форма появится следующим шагом")
                    }
                }
        }
        .frame(minWidth: 900, minHeight: 560)
    }

    @ViewBuilder private var detail: some View {
        switch model.section {
        case .overview: OverviewView(model: model)
        case .map: MapScreen(model: model)
        case .problems: ProblemsView(model: model)
        case .servers: ServersScreen(model: model)
        case .sites: SitesScreen(model: model)
        case .vpn: VPNScreen(model: model)
        case .journal: JournalView(model: model)
        }
    }
}

private struct Sidebar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List(selection: selection) {
            Section {
                row(.overview, "Обзор", "square.grid.2x2")
                row(.map, "Карта", "map")
                row(.problems, "Проблемы", "exclamationmark.triangle", badge: model.problems.count)
                row(.servers, "Серверы", "server.rack", count: model.statuses.count)
                row(.sites, "Сайты", "globe", count: model.sites.count)
                row(.vpn, "VPN", "lock.shield", count: vpnClients)
                row(.journal, "Журнал", "list.bullet.rectangle")
            }
            if !model.groups.isEmpty {
                Section("Группы") {
                    ForEach(model.groups, id: \.self) { g in
                        Label(g, systemImage: "folder")
                            .badge(model.statuses.filter { $0.server.group == g }.count)
                            .tag(SidebarTag.filter(.group(g)))
                    }
                }
            }
            if !model.tags.isEmpty {
                Section("Теги") {
                    ForEach(model.tags, id: \.self) { t in
                        Label(t, systemImage: "tag").tag(SidebarTag.filter(.tag(t)))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var vpnClients: Int {
        model.statuses.reduce(0) { sum, s in sum + (s.snapshot?.vpn?.reduce(0) { $0 + $1.clients } ?? 0) }
    }

    private func row(_ s: AppSection, _ title: String, _ icon: String, badge alerts: Int = 0, count: Int = 0) -> some View {
        var text: Text?
        if alerts > 0 {
            text = Text("\(alerts)").foregroundColor(.red)
        } else if count > 0 {
            text = Text("\(count)")
        }
        return Label(title, systemImage: icon)
            .badge(text)
            .tag(SidebarTag.section(s))
    }

    /// One selection for sections and filters: picking a group shows its servers.
    private var selection: Binding<SidebarTag?> {
        Binding {
            if let f = model.filter { return .filter(f) }
            return .section(model.section)
        } set: { tag in
            switch tag {
            case .section(let s)?:
                model.filter = nil
                model.section = s
            case .filter(let f)?:
                model.filter = f
                if model.section != .servers && model.section != .map { model.section = .servers }
            case nil:
                break
            }
        }
    }
}

private enum SidebarTag: Hashable {
    case section(AppSection)
    case filter(Filter)
}

/// Menu commands with the shortcuts from docs/design-context.md.
public struct MonitorCommands: Commands {
    @ObservedObject var model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some Commands {
        CommandMenu("Вид") {
            Button("Обзор") { go(.overview) }.keyboardShortcut("1")
            Button("Карта") { go(.map) }.keyboardShortcut("2")
            Button("Проблемы") { go(.problems) }.keyboardShortcut("3")
            Button("Серверы") { go(.servers) }.keyboardShortcut("4")
            Button("Сайты") { go(.sites) }.keyboardShortcut("5")
            Button("VPN") { go(.vpn) }.keyboardShortcut("6")
            Button("Журнал") { go(.journal) }.keyboardShortcut("7")
            Divider()
            Button("Опросить сейчас") { Task { await model.pollNow() } }.keyboardShortcut("r")
        }
        CommandMenu("Сервер") {
            Button("Открыть SSH") {
                if let id = model.selectedServerID, let s = model.status(id) { model.openSSH(s.server) }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(model.selectedServerID == nil)
            Button("Скопировать адрес") {
                if let id = model.selectedServerID, let s = model.status(id) { model.copyAddress(s.server) }
            }
            .disabled(model.selectedServerID == nil)
        }
    }

    private func go(_ s: AppSection) {
        model.filter = nil
        model.section = s
    }
}
#endif
