#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import MonitorCore
import SwiftUI

/// Tables inside a scrolling page need an explicit height: the header plus
/// every row, so nothing is cut and there is no scroll inside the page.
/// Only past `max` rows does the table scroll on its own.
func tableHeight(_ rows: Int, max: Int = 16) -> CGFloat {
    CGFloat(Swift.min(Swift.max(rows, 1), max)) * TableMetrics.row + TableMetrics.header
}

enum TableMetrics {
    /// A row of the inset table style with its spacing; generous, since a
    /// short gap below the last row is better than a clipped one.
    static let row: CGFloat = 28
    static let header: CGFloat = 34
}

extension View {
    func fitRows(_ rows: Int, max: Int = 16) -> some View {
        frame(height: tableHeight(rows, max: max))
            .scrollDisabled(rows <= max)
    }
}

struct ServicesTab: View {
    var services: [Snapshot.Service]

    var body: some View {
        if services.isEmpty {
            EmptyNote(title: "Сервисы не настроены", detail: "Базы данных и другие службы задаются в конфиге агента").frame(height: 120)
        } else {
            Table(services) {
                TableColumn("Сервис") { s in
                    HStack(spacing: 7) {
                        StatusDot(level: s.processRunning && (s.port == nil || s.portOpen) ? .ok : .critical)
                        Text(s.name)
                    }
                }
                TableColumn("Тип") { s in Text(s.kind).foregroundStyle(.secondary) }
                TableColumn("Процесс") { s in Text(s.processRunning ? "запущен" : "не запущен") }
                TableColumn("Порт") { s in
                    Text(s.port.map { "\($0) · \(s.portOpen ? "отвечает" : "закрыт")" } ?? "—").monospacedDigit()
                }
                TableColumn("Задержка") { s in Text(s.latencyMs.map(Fmt.ms) ?? "—").monospacedDigit() }
                TableColumn("Ошибка") { s in Text(s.error ?? "").foregroundStyle(.secondary) }
            }
            .fitRows(services.count)
        }
    }
}

struct ContainersTab: View {
    @ObservedObject var model: AppModel
    var server: ServerConfig
    var containers: [Snapshot.Container]

    var body: some View {
        if containers.isEmpty {
            EmptyNote(title: "Контейнеров нет", detail: "или Docker не найден на сервере").frame(height: 120)
        } else {
            Table(containers) {
                TableColumn("Контейнер") { c in
                    HStack(spacing: 7) {
                        StatusDot(level: c.state == "running" ? (c.health == "unhealthy" ? .warning : .ok) : .critical)
                        Text(c.name)
                    }
                }
                TableColumn("Образ") { c in Text(c.image).foregroundStyle(.secondary).lineLimit(1).help(c.image) }
                TableColumn("Состояние") { c in Text(stateText(c)).lineLimit(1) }
                TableColumn("CPU") { c in
                    Text(c.cpuPercent.map(Fmt.percent) ?? "—").monospacedDigit()
                }
                .width(min: 50, ideal: 60)
                TableColumn("Память") { c in
                    Text(memText(c)).monospacedDigit().lineLimit(1)
                        .help(c.memLimitBytes.map { "Лимит контейнера: \(Fmt.bytes($0))" } ?? "")
                }
                .width(min: 70, ideal: 110)
                TableColumn("Статус") { c in Text(c.status).foregroundStyle(.secondary).lineLimit(1).help(c.status) }
                TableColumn("") { c in
                    if model.can(.restart, server) {
                        Button("Перезапустить…") { model.present(.restartContainer(server.id, c.name)) }
                            .controlSize(.small)
                    }
                }
                .width(min: 110, ideal: 120)
            }
            .fitRows(containers.count, max: 20)
        }
    }

    private func stateText(_ c: Snapshot.Container) -> String {
        guard let h = c.health, !h.isEmpty else { return c.state }
        return "\(c.state) · \(h)"
    }

    /// "120 МБ", or "120 МБ из 512 МБ" when the container has a memory limit.
    private func memText(_ c: Snapshot.Container) -> String {
        guard let m = c.memBytes else { return "—" }
        guard let l = c.memLimitBytes else { return Fmt.bytes(m) }
        return "\(Fmt.bytes(m)) из \(Fmt.bytes(l))"
    }
}

extension Snapshot.Container: Identifiable {}
extension Snapshot.Service: Identifiable { public var id: String { name } }
extension Snapshot.Process: Identifiable { public var id: Int { pid } }
extension Snapshot.VPN: Identifiable { public var id: String { container } }

struct ProcessesTab: View {
    var processes: [Snapshot.Process]

    var body: some View {
        if processes.isEmpty {
            EmptyNote(title: "Нет данных о процессах").frame(height: 120)
        } else {
            Table(processes) {
                TableColumn("PID") { p in Text(String(p.pid)).monospacedDigit() }.width(70)
                TableColumn("Процесс") { p in Text(p.name) }
                TableColumn("CPU") { p in Text(Fmt.percent(p.cpuPercent)).monospacedDigit() }.width(70)
                TableColumn("Память") { p in Text(Fmt.bytes(p.rssBytes)).monospacedDigit() }.width(90)
            }
            .fitRows(processes.count, max: 20)
        }
    }
}

struct VPNTab: View {
    @ObservedObject var model: AppModel
    var server: ServerConfig
    var vpn: [Snapshot.VPN]
    /// Outgoing connections to public addresses: where a cascade would go.
    var links: [Snapshot.Link] = []
    @State private var newKeyFor: String?

    /// AmneziaWG containers can have keys added and removed from the Mac.
    private func managed(_ v: Snapshot.VPN) -> Bool {
        v.protocol.lowercased().hasPrefix("awg") && model.can(.manageVPNKeys, server)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            containers
            OutgoingLinks(model: model, links: links)
        }
    }

    @ViewBuilder private var containers: some View {
        if vpn.isEmpty {
            EmptyNote(title: "AmneziaVPN на этом сервере не найден").frame(height: 120)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                Table(vpn) {
                    TableColumn("Контейнер") { v in
                        HStack(spacing: 7) {
                            StatusDot(level: v.running ? .ok : .critical)
                            Text(v.container)
                        }
                    }
                    TableColumn("Протокол") { v in Text(v.protocol) }
                    TableColumn("Состояние") { v in Text(v.running ? "работает" : "остановлен") }
                    TableColumn("Клиенты") { v in
                        Text(v.clientsKnown == true ? "\(v.clients), активны \(v.activeClients)" : "не читаются")
                            .foregroundStyle(v.clientsKnown == true ? .primary : .secondary)
                    }
                    TableColumn("Трафик ↓ / ↑") { v in
                        Text(v.clientsKnown == true ? "\(Fmt.bytes(v.rxBytes)) / \(Fmt.bytes(v.txBytes))" : "—").monospacedDigit()
                    }
                }
                .fitRows(vpn.count)

                ForEach(vpn.filter { !($0.peers ?? []).isEmpty || managed($0) }, id: \.container) { v in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Клиенты \(v.protocol) · \(v.container)").font(.callout.weight(.semibold))
                            Spacer()
                            if managed(v) {
                                Button("Новый ключ…") { newKeyFor = v.container }
                                    .disabled(!v.running)
                            }
                        }
                        if (v.peers ?? []).isEmpty {
                            Text("Ключей пока нет").foregroundStyle(.secondary)
                        } else {
                            VPNClientsPanel(model: model, serverID: server.id, peers: v.peers ?? [],
                                            onDelete: managed(v) ? { [server] key, name in
                                try await model.backend.deleteVPNKey(server: server, container: v.container,
                                                                     publicKey: key, name: name, password: nil)
                            } : nil)
                        }
                    }
                }
            }
            .sheet(item: Binding(get: { newKeyFor.map(ContainerRef.init) }, set: { newKeyFor = $0?.id })) { ref in
                NewVPNKeySheet(model: model, server: server, container: ref.id)
            }
        }
    }
}

struct ContainerRef: Identifiable { var id: String }

/// Where this server connects to on the internet, and through which
/// container. A cascade to another of our servers shows up here first.
struct OutgoingLinks: View {
    @ObservedObject var model: AppModel
    var links: [Snapshot.Link]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Исходящие соединения").font(.callout.weight(.semibold))
            if links.isEmpty {
                Text("Сервер сейчас никуда не соединяется сам, кроме служебных проверок. Каскада через него нет, или агент старый.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Table(links.map(LinkRow.init)) {
                    TableColumn("Куда") { r in
                        if let s = server(r.link.remoteIp) {
                            Label("\(s.name) (\(r.link.remoteIp))", systemImage: "server.rack")
                        } else {
                            Text(r.link.remoteIp).textSelection(.enabled)
                        }
                    }
                    TableColumn("Порты") { r in Text(r.link.ports.map(String.init).joined(separator: ", ")).monospacedDigit() }
                        .width(min: 60, ideal: 90)
                    TableColumn("Протокол") { r in Text(r.link.protos.joined(separator: ", ")) }
                        .width(min: 60, ideal: 70)
                    TableColumn("Через") { r in Text(r.link.via.joined(separator: ", ")).foregroundStyle(.secondary) }
                    TableColumn("Соединений") { r in Text("\(r.link.connections)").monospacedDigit() }
                        .width(min: 70, ideal: 80)
                }
                .fitRows(links.count, max: 12)
            }
        }
    }

    private func server(_ ip: String) -> ServerConfig? {
        model.statuses.first { $0.server.host == ip }?.server
    }
}

struct LinkRow: Identifiable {
    var link: Snapshot.Link
    var id: String { link.remoteIp }
    init(_ l: Snapshot.Link) { link = l }
}

struct PeersTable: View {
    var peers: [Snapshot.VPN.Peer]
    /// Traffic counted by the Mac per day; empty until the first rounds.
    var traffic = PeerTraffic()
    /// Set when keys in this container can be deleted.
    var onDelete: ((String, String) async throws -> Void)?
    @Binding var selection: String?
    @State private var sort = [KeyPathComparator(\PeerRow.lastSeen, order: .reverse)]
    @State private var confirm: PeerRow?
    @State private var deleting: String?
    @State private var error: String?

    var body: some View {
        let rows = peers.map { PeerRow($0, traffic) }.sorted(using: sort)
        Table(rows, selection: $selection, sortOrder: $sort) {
            TableColumn("Клиент", value: \.name) { p in
                HStack(spacing: 7) {
                    StatusDot(level: p.peer.active ? .ok : .unknown)
                    Text(p.name)
                    if deleting == p.id { ProgressView().controlSize(.mini) }
                }
            }
            TableColumn("Последнее подключение", value: \.lastSeen) { p in
                Text(p.peer.latestHandshake.map { (p.peer.active ? "активен · " : "") + Fmt.relative($0) } ?? "никогда")
                    .foregroundStyle(p.peer.active ? .primary : .secondary)
            }
            TableColumn("Сегодня ↓ / ↑", value: \.todayTotal) { p in usage(p.today) }
            TableColumn("За месяц ↓ / ↑", value: \.monthTotal) { p in usage(p.month) }
            TableColumn("С запуска VPN ↓ / ↑", value: \.tx) { p in
                Text("\(Fmt.bytes(p.peer.txBytes)) / \(Fmt.bytes(p.peer.rxBytes))").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 150)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                Button("Скопировать публичный ключ") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(row.peer.publicKey, forType: .string)
                }
                if onDelete != nil {
                    Divider()
                    Button("Удалить ключ…", role: .destructive) { confirm = row }
                        .disabled(deleting != nil)
                }
            }
        }
        .fitRows(peers.count, max: 24)
        .confirmationDialog("Удалить ключ «\(confirm?.name ?? "")»?", isPresented: Binding(
            get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Удалить", role: .destructive) {
                if let row = confirm { remove(row.peer.publicKey, name: row.name) }
                confirm = nil
            }
        } message: {
            Text("Устройство с этим ключом сразу перестанет подключаться к VPN. Отменить это нельзя, только выдать новый ключ.")
        }
        .alert("Ключ не удалён", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    /// Download / upload as the client sees it (Store rx is client upload).
    private func usage(_ u: Store.VPNUsage?) -> some View {
        Text(u.map { "\(Fmt.bytes($0.tx)) / \(Fmt.bytes($0.rx))" } ?? "—").monospacedDigit()
            .help(traffic.counted ? "" : "Mac считает трафик по дням с этого обновления")
    }

    private func remove(_ publicKey: String, name: String) {
        guard let onDelete else { return }
        deleting = publicKey
        Task {
            do { try await onDelete(publicKey, name) } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
            deleting = nil
        }
    }
}

/// Rx is what the server received from the client (client upload), Tx what it
/// sent (client download), so the columns are swapped from the client's view.
/// Per-client traffic for today and this month, by public key.
struct PeerTraffic: Equatable {
    var today: [String: Store.VPNUsage] = [:]
    var month: [String: Store.VPNUsage] = [:]
    /// The Mac has counted something on this server already.
    var counted: Bool { !month.isEmpty }
}

struct PeerRow: Identifiable {
    var peer: Snapshot.VPN.Peer
    var today: Store.VPNUsage?
    var month: Store.VPNUsage?
    var id: String { peer.publicKey }
    var todayTotal: Double { Double(today?.total ?? 0) }
    var monthTotal: Double { Double(month?.total ?? 0) }
    var name: String { peer.name ?? String(peer.publicKey.prefix(10)) + "…" }
    var lastSeen: Double { peer.latestHandshake?.timeIntervalSince1970 ?? 0 }
    var rx: Double { Double(peer.rxBytes) }
    var tx: Double { Double(peer.txBytes) }

    init(_ p: Snapshot.VPN.Peer, _ t: PeerTraffic = PeerTraffic()) {
        peer = p
        today = t.today[p.publicKey]
        month = t.month[p.publicKey]
    }
}

struct ChecksTab: View {
    @ObservedObject var model: AppModel
    var checks: [Snapshot.Check]

    var body: some View {
        if checks.isEmpty {
            EmptyNote(title: "Этот сервер ничего не проверяет", detail: "Сайты и соседние серверы задаются в конфиге агента").frame(height: 120)
        } else {
            Table(checks) {
                TableColumn("Цель") { c in
                    HStack(spacing: 7) {
                        StatusDot(level: c.ok ? .ok : .critical)
                        Text(name(c))
                    }
                }
                TableColumn("Тип") { c in Text(c.kind == "http" ? "сайт" : "сервер").foregroundStyle(.secondary) }
                TableColumn("Код") { c in Text(c.statusCode.map(String.init) ?? "—").monospacedDigit() }
                TableColumn("Время") { c in Text(c.ok ? Fmt.ms(c.latencyMs) : "—").monospacedDigit() }
                TableColumn("SSL") { c in Text(c.tlsExpiry.map { "\(Fmt.days(until: $0)) д" } ?? "—").monospacedDigit() }
                TableColumn("Ошибка") { c in Text(c.error ?? "").foregroundStyle(.secondary) }
            }
            .fitRows(checks.count)
        }
    }

    private func name(_ c: Snapshot.Check) -> String {
        if c.kind == "tcp" {
            let host = c.target.split(separator: ":").first.map(String.init) ?? c.target
            if let s = model.statuses.first(where: { $0.server.host == host }) { return s.server.name }
        }
        return c.target
    }
}

extension Snapshot.Check: Identifiable {}

/// Alert history and server events (reboots, containers), for one server or
/// for all. Filters narrow the list by object, by kind and by text.
struct EventsList: View {
    @ObservedObject var model: AppModel
    var serverID: String?
    var limit = 200
    @State private var events: [Store.LoggedEvent] = []
    @State private var object = ""
    @State private var filter = KindFilter.all
    @State private var search = ""

    enum KindFilter: String, CaseIterable, Identifiable {
        case all = "Все", critical = "Критичные", warning = "Предупреждения", server = "События сервера"
        var id: String { rawValue }
    }

    var body: some View {
        let shown = filtered
        VStack(alignment: .leading, spacing: 0) {
            filterBar(count: shown.count)
                .padding(.horizontal, serverID == nil ? 16 : 0)
                .padding(.vertical, 8)
            if serverID == nil { Divider() }
            if shown.isEmpty {
                EmptyNote(title: events.isEmpty ? "Событий пока нет" : "Ничего не найдено",
                          detail: events.isEmpty
                            ? "Здесь появятся оповещения, перезагрузки и изменения контейнеров." : nil)
                    .frame(minHeight: 120)
            } else if serverID == nil {
                Table(rows(shown)) {
                    TableColumn("Время") { r in Text(Fmt.time(r.event.time)).monospacedDigit() }.width(min: 90, ideal: 110)
                    TableColumn("Тип") { r in kind(r.event) }.width(min: 120, ideal: 140)
                    TableColumn("Объект") { r in Text(model.objectName(r.event.serverID)).lineLimit(1) }
                        .width(min: 70, ideal: 110)
                    TableColumn("Что") { r in Text(r.event.message).lineLimit(1).help(r.event.message) }
                }
            } else {
                Table(rows(shown)) {
                    TableColumn("Время") { r in Text(Fmt.time(r.event.time)).monospacedDigit() }.width(min: 90, ideal: 110)
                    TableColumn("Тип") { r in kind(r.event) }.width(min: 120, ideal: 140)
                    TableColumn("Что") { r in Text(r.event.message).lineLimit(1).help(r.event.message) }
                }
                .fitRows(shown.count, max: 20)
            }
        }
        .task(id: model.lastRound) {
            events = (try? await model.backend.events(limit: limit, serverID: serverID)) ?? []
        }
    }

    private func filterBar(count: Int) -> some View {
        // Wraps the search field under the pickers when the pane is narrow.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                pickers
                searchField.frame(minWidth: 140, maxWidth: 220)
                Spacer(minLength: 0)
                Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    pickers
                    Spacer(minLength: 0)
                    Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
                }
                searchField
            }
        }
    }

    @ViewBuilder private var pickers: some View {
        if serverID == nil {
            Picker("Объект", selection: $object) {
                Text("Все").tag("")
                if !model.statuses.isEmpty {
                    Section("Серверы") {
                        ForEach(model.statuses, id: \.id) { Text($0.server.name).tag($0.id) }
                    }
                }
                if !model.siteStatuses.isEmpty {
                    Section("Сайты") {
                        ForEach(model.siteStatuses, id: \.id) { Text($0.site.name).tag(SiteStatus.alertID($0.id)) }
                    }
                }
            }
            .fixedSize()
        }
        Picker("Тип", selection: $filter) {
            ForEach(KindFilter.allCases) { Text($0.rawValue).tag($0) }
        }
        .fixedSize()
    }

    private var searchField: some View {
        TextField("Поиск", text: $search).textFieldStyle(.roundedBorder)
    }

    private var filtered: [Store.LoggedEvent] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return events.filter { e in
            guard object.isEmpty || e.serverID == object else { return false }
            switch filter {
            case .all: break
            case .critical: if e.kind == .info || e.severity != .critical { return false }
            case .warning: if e.kind == .info || e.severity != .warning { return false }
            case .server: if e.kind != .info { return false }
            }
            return q.isEmpty || e.message.localizedCaseInsensitiveContains(q)
                || model.objectName(e.serverID).localizedCaseInsensitiveContains(q)
        }
    }

    private func rows(_ list: [Store.LoggedEvent]) -> [EventRow] {
        list.enumerated().map { EventRow(index: $0.offset, event: $0.element) }
    }

    private func kind(_ e: Store.LoggedEvent) -> some View {
        HStack(spacing: 6) {
            StatusDot(level: level(e))
            Text(kindLabel(e)).lineLimit(1)
        }
    }

    private func level(_ e: Store.LoggedEvent) -> ServerStatus.Level {
        switch e.kind {
        case .resolved: return .ok
        case .info: return .unknown
        case .fired, .reminder: return e.severity.level
        }
    }

    private func kindLabel(_ e: Store.LoggedEvent) -> String {
        switch e.kind {
        case .fired: return e.severity == .critical ? "Критично" : "Внимание"
        case .reminder: return "Напоминание"
        case .resolved: return "Снова в норме"
        case .info: return e.key == "reboot" ? "Перезагрузка" : "Контейнер"
        }
    }
}

struct EventRow: Identifiable {
    var index: Int
    var event: Store.LoggedEvent
    var id: Int { index }
}
#endif
