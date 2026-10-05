#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import MonitorCore
import SwiftUI

/// Tables inside the scrolling detail need an explicit height.
func tableHeight(_ rows: Int, max: Int = 16) -> CGFloat { CGFloat(Swift.min(Swift.max(rows, 1), max)) * 24 + 32 }

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
            .frame(height: tableHeight(services.count))
        }
    }
}

struct ContainersTab: View {
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
                TableColumn("Образ") { c in Text(c.image).foregroundStyle(.secondary).lineLimit(1) }
                TableColumn("Состояние") { c in Text(c.state) }
                TableColumn("Health") { c in Text(c.health ?? "—") }
                TableColumn("Статус") { c in Text(c.status).foregroundStyle(.secondary) }
            }
            .frame(height: tableHeight(containers.count, max: 20))
        }
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
            .frame(height: tableHeight(processes.count, max: 20))
        }
    }
}

struct VPNTab: View {
    @ObservedObject var model: AppModel
    var server: ServerConfig
    var vpn: [Snapshot.VPN]
    @State private var newKeyFor: String?

    /// AmneziaWG containers can have keys added and removed from the Mac.
    private func managed(_ v: Snapshot.VPN) -> Bool {
        v.protocol.lowercased().hasPrefix("awg") && model.can(.manageVPNKeys, server)
    }

    var body: some View {
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
                .frame(height: tableHeight(vpn.count))

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
                            PeersTable(peers: v.peers ?? [], onDelete: managed(v) ? { [server] key in
                                try await model.backend.deleteVPNKey(server: server, container: v.container,
                                                                     publicKey: key, password: nil)
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

struct PeersTable: View {
    var peers: [Snapshot.VPN.Peer]
    /// Set when keys in this container can be deleted.
    var onDelete: ((String) async throws -> Void)?
    @State private var sort = [KeyPathComparator(\PeerRow.lastSeen, order: .reverse)]
    @State private var confirm: PeerRow?
    @State private var deleting: String?
    @State private var error: String?

    var body: some View {
        let rows = peers.map(PeerRow.init).sorted(using: sort)
        Table(rows, sortOrder: $sort) {
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
            TableColumn("Скачал ↓", value: \.tx) { p in Text(Fmt.bytes(p.peer.txBytes)).monospacedDigit() }
            TableColumn("Отдал ↑", value: \.rx) { p in Text(Fmt.bytes(p.peer.rxBytes)).monospacedDigit() }
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
        .frame(height: tableHeight(peers.count, max: 24))
        .confirmationDialog("Удалить ключ «\(confirm?.name ?? "")»?", isPresented: Binding(
            get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Удалить", role: .destructive) {
                if let row = confirm { remove(row.peer.publicKey) }
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

    private func remove(_ publicKey: String) {
        guard let onDelete else { return }
        deleting = publicKey
        Task {
            do { try await onDelete(publicKey) } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
            deleting = nil
        }
    }
}

/// Rx is what the server received from the client (client upload), Tx what it
/// sent (client download), so the columns are swapped from the client's view.
struct PeerRow: Identifiable {
    var peer: Snapshot.VPN.Peer
    var id: String { peer.publicKey }
    var name: String { peer.name ?? String(peer.publicKey.prefix(10)) + "…" }
    var lastSeen: Double { peer.latestHandshake?.timeIntervalSince1970 ?? 0 }
    var rx: Double { Double(peer.rxBytes) }
    var tx: Double { Double(peer.txBytes) }

    init(_ p: Snapshot.VPN.Peer) { peer = p }
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
            .frame(height: tableHeight(checks.count))
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

/// Alert history, for one server or for all.
struct EventsList: View {
    @ObservedObject var model: AppModel
    var serverID: String?
    var limit = 200
    @State private var events: [Store.LoggedEvent] = []

    var body: some View {
        Group {
            if events.isEmpty {
                EmptyNote(title: "Событий пока нет").frame(minHeight: 120)
            } else {
                if serverID == nil {
                    Table(rows) {
                        TableColumn("Время") { r in Text(Fmt.time(r.event.time)).monospacedDigit() }.width(min: 90, ideal: 110)
                        TableColumn("Важность") { r in kind(r.event) }.width(min: 110, ideal: 130)
                        TableColumn("Сервер") { r in Text(model.objectName(r.event.serverID)) }
                            .width(min: 70, ideal: 100)
                        TableColumn("Что") { r in Text(r.event.message) }
                    }
                } else {
                    Table(rows) {
                        TableColumn("Время") { r in Text(Fmt.time(r.event.time)).monospacedDigit() }.width(min: 90, ideal: 110)
                        TableColumn("Важность") { r in kind(r.event) }.width(min: 110, ideal: 130)
                        TableColumn("Что") { r in Text(r.event.message) }
                    }
                    .frame(height: tableHeight(events.count, max: 20))
                }
            }
        }
        .task(id: model.lastRound) {
            events = (try? await model.backend.events(limit: limit, serverID: serverID)) ?? []
        }
    }

    private var rows: [EventRow] { events.enumerated().map { EventRow(index: $0.offset, event: $0.element) } }

    private func kind(_ e: Store.LoggedEvent) -> some View {
        HStack(spacing: 6) {
            StatusDot(level: e.kind == .resolved ? .ok : e.severity.level)
            Text(kindLabel(e))
        }
    }

    private func kindLabel(_ e: Store.LoggedEvent) -> String {
        switch e.kind {
        case .fired: return e.severity == .critical ? "Критично" : "Внимание"
        case .reminder: return "Напоминание"
        case .resolved: return "Снова в норме"
        }
    }
}

struct EventRow: Identifiable {
    var index: Int
    var event: Store.LoggedEvent
    var id: Int { index }
}
#endif
