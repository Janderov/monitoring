#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import MonitorCore
import SwiftUI

// MARK: - Model

extension AppModel {
    /// Site id -> id of the server it runs on, from DNS.
    var hosting: [String: String] { siteHosts.server }

    public func loadClients() async {
        do {
            clientBook = try await backend.loadClients()
            clientsError = nil
        } catch {
            clientsError = "clients.json: \(error)"
        }
        if let id = clientScope, clientBook.client(id)?.archivedAt != nil { clientScope = nil }
    }

    /// Saves the whole book (the action log gets `detail`) and shows it.
    public func saveClients(_ book: ClientBook, detail: String) async throws {
        try await backend.saveClients(book, detail: detail)
        clientBook = book
        if let id = clientScope, book.client(id)?.archivedAt != nil { clientScope = nil }
    }

    public func client(_ id: String?) -> Client? { id.flatMap { clientBook.client($0) } }

    /// The client chosen in the sidebar.
    public var scopeClient: Client? { client(clientScope) }

    /// Who a server serves: its own clients, owners of the sites running on
    /// it, and owners of VPN keys on it (they see the server their VPN runs
    /// on; the cost share stays with the server's own clients).
    public func owners(server id: String) -> [String] {
        var out = clientBook.owners(server: id, hosting: hosting)
        for key in vpnKeys(on: id) {
            for c in clientBook.rows(.vpnKey, key.publicKey).map(\.clientID) where !out.contains(c) { out.append(c) }
        }
        return out
    }

    public func owners(site id: String) -> [String] { clientBook.owners(site: id) }

    public func ownerClients(server id: String) -> [Client] { owners(server: id).compactMap { client($0) } }
    public func ownerClients(site id: String) -> [Client] { owners(site: id).compactMap { client($0) } }

    public func ownerClients(_ p: Problem) -> [Client] {
        if let s = p.server { return ownerClients(server: s.id) }
        return ownerClients(site: p.siteID ?? "")
    }

    /// VPN keys the agent reports on a server.
    func vpnKeys(on serverID: String) -> [Snapshot.VPN.Peer] {
        (status(serverID)?.snapshot?.vpn ?? []).flatMap { $0.peers ?? [] }
    }

    /// Every VPN key on every server.
    var allVPNKeys: [VPNKeyItem] {
        statuses.flatMap { s in vpnKeys(on: s.id).map { VPNKeyItem(server: s.server, peer: $0) } }
    }

    public func inScope(server id: String) -> Bool {
        guard let c = clientScope else { return true }
        return owners(server: id).contains(c)
    }

    public func inScope(site id: String) -> Bool {
        guard let c = clientScope else { return true }
        return owners(site: id).contains(c)
    }

    /// For journal rows: a server id, "site:<id>", or something of this Mac
    /// (shown with «Своё»).
    public func inScope(object id: String) -> Bool {
        guard clientScope != nil else { return true }
        if status(id) != nil { return inScope(server: id) }
        if let site = siteStatuses.first(where: { SiteStatus.alertID($0.site.id) == id }) { return inScope(site: site.site.id) }
        return scopeClient?.isInternal == true
    }

    public var scopedStatuses: [ServerStatus] { statuses.filter { inScope(server: $0.id) } }
    public var scopedSites: [SiteSummary] { sites.filter { inScope(site: $0.status.site.id) } }

    public var scopedProblems: [Problem] {
        problems.filter { p in
            if let s = p.server { return inScope(server: s.id) }
            return inScope(site: p.siteID ?? "")
        }
    }

    /// Opens a client's card.
    public func show(client id: String) {
        filter = nil
        section = .clients
        selectedClientID = id
    }
}

/// A VPN key and the server it is on.
struct VPNKeyItem: Identifiable {
    var server: ServerConfig
    var peer: Snapshot.VPN.Peer
    var id: String { server.id + "|" + peer.publicKey }
}

extension ClientColor {
    var color: Color {
        switch self {
        case .gray: return .gray
        case .blue: return .blue
        case .orange: return .orange
        case .green: return .green
        case .purple: return .purple
        case .pink: return .pink
        case .teal: return .teal
        case .red: return .red
        case .yellow: return .yellow
        case .brown: return .brown
        }
    }
}

// MARK: - Small views

/// A client's colour dot and short name.
struct ClientTag: View {
    var client: Client

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(client.color.color).frame(width: 7, height: 7)
            Text(client.label).lineLimit(1)
        }
    }
}

/// The first owner and "+2"; all of them on hover.
struct ClientTags: View {
    var clients: [Client]

    var body: some View {
        HStack(spacing: 4) {
            if let first = clients.first {
                ClientTag(client: first)
                if clients.count > 1 {
                    Text("+\(clients.count - 1)").foregroundStyle(.secondary)
                }
            }
        }
        .help(clients.map(\.name).joined(separator: ", "))
    }
}

/// The sidebar's «Клиент» picker: one client on every screen, or all.
struct ClientScopePicker: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.scopeClient?.color.color ?? Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
            Picker("Клиент", selection: $model.clientScope) {
                Text("Все клиенты").tag(String?.none)
                Divider()
                ForEach(model.clientBook.current) { c in
                    Text(c.name).tag(Optional(c.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .help("Показывать только объекты одного клиента на всех экранах")
    }
}

// MARK: - Screen

/// Clients: table on the left, the selected client's card on the right.
struct ClientsScreen: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HSplitView {
            ClientsTable(model: model)
                .frame(minWidth: 360, idealWidth: 560, maxWidth: 680)
            Group {
                if let c = model.client(model.selectedClientID), c.archivedAt == nil {
                    ClientDetail(model: model, client: c)
                        .id(c.id)
                } else {
                    EmptyNote(title: "Выберите клиента", detail: nil,
                              actionTitle: "Добавить клиента…", action: { model.present(.addClient) })
                }
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
        }
        .navigationTitle("Клиенты")
        .navigationSubtitle("\(model.clientBook.current.count)")
        .toolbar {
            ToolbarItem {
                Button { model.present(.addClient) } label: {
                    Label("Добавить клиента", systemImage: "person.badge.plus")
                }
                .help("Добавить клиента")
            }
        }
    }
}

/// One line of the clients table.
struct ClientRow: Identifiable {
    var client: Client
    var servers: Int
    var sites: Int
    var vpnKeys: Int
    var problems: Int
    var level: ServerStatus.Level
    var id: String { client.id }

    @MainActor
    init(_ c: Client, model: AppModel) {
        client = c
        let servers = model.statuses.filter { model.owners(server: $0.id).contains(c.id) }
        let sites = model.siteStatuses.filter { model.owners(site: $0.site.id).contains(c.id) }
        self.servers = servers.count
        self.sites = sites.count
        vpnKeys = model.allVPNKeys.filter { model.clientBook.owners(vpnKey: $0.peer.publicKey).contains(c.id) }.count
        problems = servers.reduce(0) { $0 + $1.alerts.count } + sites.reduce(0) { $0 + $1.alerts.count }
        level = (servers.map(\.level) + sites.map(\.level)).max() ?? .unknown
    }
}

private struct ClientsTable: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let rows = model.clientBook.current.map { ClientRow($0, model: model) }
        Table(rows, selection: $model.selectedClientID) {
            TableColumn("") { r in StatusDot(level: r.client.state == .active ? r.level : .unknown) }
                .width(16)
            TableColumn("Клиент") { r in
                HStack(spacing: 6) {
                    ClientTag(client: r.client)
                    if r.client.label != r.client.name {
                        Text(r.client.name).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if r.client.state != .active {
                        Text(r.client.state == .paused ? "пауза" : "завершён").foregroundStyle(.secondary)
                    }
                }
            }
            .width(min: 140, ideal: 200)
            TableColumn("Серверы") { r in Text("\(r.servers)").monospacedDigit() }.width(min: 50, ideal: 60)
            TableColumn("Сайты") { r in Text("\(r.sites)").monospacedDigit() }.width(min: 44, ideal: 50)
            TableColumn("VPN") { r in Text("\(r.vpnKeys)").monospacedDigit() }.width(min: 36, ideal: 44)
            TableColumn("Проблемы") { r in
                Text(r.problems == 0 ? "—" : "\(r.problems)")
                    .foregroundStyle(r.problems == 0 ? Color.secondary : r.level.textColor).monospacedDigit()
            }
            .width(min: 60, ideal: 70)
            TableColumn("Тариф") { r in
                Text(r.client.contract().map { Money.text($0.monthlyPrice, $0.currency) } ?? "—")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 60, ideal: 80)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first {
                Button("Показать только его") { model.clientScope = id; model.section = .overview }
                Button("Изменить…") { model.present(.editClient(id)) }
            }
        }
    }
}

// MARK: - Card

struct ClientDetail: View {
    @ObservedObject var model: AppModel
    var client: Client
    @State private var error: String?

    private var servers: [ServerStatus] { model.statuses.filter { model.owners(server: $0.id).contains(client.id) } }
    private var sites: [SiteStatus] { model.siteStatuses.filter { model.owners(site: $0.site.id).contains(client.id) } }
    private var keys: [VPNKeyItem] {
        model.allVPNKeys.filter { model.clientBook.owners(vpnKey: $0.peer.publicKey).contains(client.id) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                stats
                if let error { Text(error).foregroundStyle(.red) }
                objects
                HStack(alignment: .top, spacing: 16) {
                    contacts
                    contract
                }
                if let notes = client.notes, !notes.isEmpty {
                    GroupBox("Заметки") {
                        Text(notes).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                }
            }
            .padding(20)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Circle().fill(client.color.color).frame(width: 10, height: 10)
                    Text(client.name).font(.title2.weight(.semibold))
                }
                Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Изменить…") { model.present(.editClient(client.id)) }
            Button("Показать только его") {
                model.clientScope = client.id
                model.section = .overview
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if client.isInternal { parts.append("ваши серверы, сайты и VPN") }
        if let l = client.legalName { parts.append(l) }
        if let inn = client.inn { parts.append("ИНН \(inn)") }
        if !client.isInternal { parts.append("клиент с \(Fmt.day(client.createdAt))") }
        if let tz = client.timezone { parts.append(tz) }
        if client.state == .paused { parts.append("пауза: без отчёта и ночных уведомлений") }
        return parts.joined(separator: " · ")
    }

    private var stats: some View {
        let problems = servers.reduce(0) { $0 + $1.alerts.count } + sites.reduce(0) { $0 + $1.alerts.count }
        let cost = model.clientBook.costShare(of: client.id, servers: model.statuses.map(\.server), hosting: model.hosting)
        return HStack(spacing: 28) {
            stat(problems == 0 ? "нет" : "\(problems)", "проблем сейчас", warn: problems > 0)
            stat("\(servers.count) · \(sites.count) · \(keys.count)", "серверы · сайты · VPN")
            if !cost.isEmpty {
                stat(cost.sorted { $0.key < $1.key }.map { Money.text($0.value.rounded(), $0.key) }.joined(separator: " · "),
                     "доля стоимости серверов")
            }
            if let c = client.contract() {
                stat(Money.text(c.monthlyPrice, c.currency), "тариф «\(c.planName)» в месяц")
            }
        }
    }

    private func stat(_ value: String, _ caption: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline).monospacedDigit().foregroundStyle(warn ? Color.orange : Color.primary)
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Objects

    private var objects: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                if servers.isEmpty && sites.isEmpty && keys.isEmpty {
                    Text("Пока ничего. Добавьте серверы, сайты или VPN-ключи этого клиента.")
                        .foregroundStyle(.secondary)
                }
                ForEach(servers) { s in serverRow(s) }
                ForEach(sites, id: \.site.id) { s in siteRow(s) }
                ForEach(keys) { k in keyRow(k.server, k.peer) }
                addMenu.padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Объекты")
        }
    }

    private func serverRow(_ s: ServerStatus) -> some View {
        let explicit = model.clientBook.rows(.server, s.id).first { $0.clientID == client.id }
        let others = model.ownerClients(server: s.id).filter { $0.id != client.id }
        let share = model.clientBook.shares(server: s.id, hosting: model.hosting)[client.id]
        return HStack(spacing: 8) {
            StatusDot(level: s.level)
            Button(s.server.name) { model.show(server: s.id) }.buttonStyle(.link)
            Text(serverNote(s, explicit: explicit != nil, others: others)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if explicit != nil {
                if !others.isEmpty || share != nil {
                    ShareField(percent: explicit?.sharePercent, effective: share) { v in
                        update { $0.setShare(client.id, server: s.id, v) }
                    }
                }
                removeButton { $0.removeOwner(client.id, .server, s.id) }
            }
        }
    }

    private func serverNote(_ s: ServerStatus, explicit: Bool, others: [Client]) -> String {
        var parts = ["сервер"]
        if !explicit {
            let hosted = model.siteStatuses.filter { model.hosting[$0.site.id] == s.id && model.owners(site: $0.site.id).contains(client.id) }
            if let site = hosted.first {
                parts.append("на нём сайт \(site.site.name)")
            } else {
                parts.append("на нём VPN-ключи клиента")
            }
        }
        if !others.isEmpty { parts.append("общий с " + others.map(\.label).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private func siteRow(_ s: SiteStatus) -> some View {
        HStack(spacing: 8) {
            StatusDot(level: s.level)
            Button(s.site.name) { model.show(site: s.site.id) }.buttonStyle(.link)
            Text(siteNote(s)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if model.clientBook.rows(.site, s.site.id).contains(where: { $0.clientID == client.id }) {
                removeButton { $0.removeOwner(client.id, .site, s.site.id) }
            }
        }
    }

    private func siteNote(_ s: SiteStatus) -> String {
        if let a = s.alerts.max(by: { $0.severity < $1.severity }) { return a.message }
        return "сайт"
    }

    private func keyRow(_ server: ServerConfig, _ peer: Snapshot.VPN.Peer) -> some View {
        HStack(spacing: 8) {
            Circle().fill(peer.active ? Color.green : Color.secondary.opacity(0.5)).frame(width: 8, height: 8)
            Text(peer.name ?? String(peer.publicKey.prefix(8)))
            Text("VPN-ключ на \(server.name)").foregroundStyle(.secondary)
            Spacer()
            if model.clientBook.rows(.vpnKey, peer.publicKey).contains(where: { $0.clientID == client.id }) {
                removeButton { $0.removeOwner(client.id, .vpnKey, peer.publicKey) }
            }
        }
    }

    private func removeButton(_ change: @escaping (inout ClientBook) -> Void) -> some View {
        Button { update(change) } label: { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless)
            .help("Убрать у этого клиента")
    }

    /// Everything not assigned to this client yet, by kind.
    private var addMenu: some View {
        let book = model.clientBook
        let freeServers = model.statuses.filter { s in !book.rows(.server, s.id).contains { $0.clientID == client.id } }
        let freeSites = model.siteStatuses.filter { s in !book.rows(.site, s.site.id).contains { $0.clientID == client.id } }
        let freeKeys = model.allVPNKeys
            .filter { k in !book.rows(.vpnKey, k.peer.publicKey).contains { $0.clientID == client.id } }
        return Menu("Добавить объект…") {
            Section("Серверы") {
                ForEach(freeServers) { s in
                    Button(s.server.name) { update { $0.addOwner(client.id, .server, s.id) } }
                }
            }
            Section("Сайты") {
                ForEach(freeSites, id: \.site.id) { s in
                    Button(s.site.name + ownersNote(.site, s.site.id)) {
                        // A site has one client: it moves here.
                        update { $0.setOwners(.site, s.site.id, [client.id: nil]) }
                    }
                }
            }
            if !freeKeys.isEmpty {
                Section("VPN-ключи") {
                    ForEach(freeKeys) { k in
                        Button((k.peer.name ?? String(k.peer.publicKey.prefix(8))) + " · " + k.server.name
                               + ownersNote(.vpnKey, k.peer.publicKey)) {
                            update { $0.setOwners(.vpnKey, k.peer.publicKey, [client.id: nil]) }
                        }
                    }
                }
            }
        }
        .fixedSize()
    }

    /// " (сейчас у Вектор)" when the object moves from another client.
    private func ownersNote(_ type: AssetType, _ id: String) -> String {
        let names = model.clientBook.rows(type, id).compactMap { model.client($0.clientID)?.label }
        return names.isEmpty ? "" : " (сейчас у \(names.joined(separator: ", ")))"
    }

    private func update(_ change: (inout ClientBook) -> Void) {
        var book = model.clientBook
        change(&book)
        guard book != model.clientBook else { return }
        error = nil
        Task {
            do { try await model.saveClients(book, detail: "объекты клиента «\(client.name)»") }
            catch { self.error = (error as? LocalizedError)?.errorDescription ?? String(describing: error) }
        }
    }

    // MARK: Contacts and contract

    private var contacts: some View {
        GroupBox("Контакты") {
            VStack(alignment: .leading, spacing: 8) {
                if client.contacts.isEmpty {
                    Text("Нет").foregroundStyle(.secondary)
                }
                ForEach(client.contacts) { c in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(c.name).fontWeight(.medium)
                            Text(c.role.title).foregroundStyle(.secondary)
                        }
                        let ways = [c.phone, c.email, c.telegram.map { "Telegram \($0)" }].compactMap { $0 }
                        if !ways.isEmpty { Text(ways.joined(separator: " · ")).font(.callout).textSelection(.enabled) }
                        let gets = [c.receivesReport ? "отчёт" : nil, c.receivesAlerts ? "аварии" : nil].compactMap { $0 }
                        if !gets.isEmpty { Text("получает: " + gets.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var contract: some View {
        GroupBox("Договор") {
            VStack(alignment: .leading, spacing: 4) {
                if let c = client.contract() {
                    row("Тариф", "\(c.planName), \(Money.text(c.monthlyPrice, c.currency)) в месяц")
                    if let d = c.billingDay { row("Оплата", "до \(d) числа") }
                    if let s = c.slaUptime { row("Обещанная доступность", String(format: "%.2f %%", s)) }
                    if let r = c.reportDay { row("Отчёт", "\(r) числа") }
                    row("С", Fmt.day(c.startedOn))
                    if client.contracts.count > 1 {
                        Text("Прошлых тарифов: \(client.contracts.count - 1)").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(client.isInternal ? "Не нужен" : "Тариф не задан").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
            Text(v)
        }
    }
}

/// A server's share in percent; empty means "split equally".
private struct ShareField: View {
    var percent: Double?
    var effective: Double?
    var commit: (Double?) -> Void
    @State private var text = ""

    var body: some View {
        HStack(spacing: 3) {
            TextField("", text: $text, prompt: Text(effective.map { String(format: "%.0f", $0) } ?? "поровну"))
                .frame(width: 52)
                .multilineTextAlignment(.trailing)
                .onSubmit(save)
            Text("%").foregroundStyle(.secondary)
        }
        .help("Доля стоимости сервера для отчёта. Пусто: поровну между клиентами")
        .onAppear { text = percent.map { String(format: "%g", $0) } ?? "" }
    }

    private func save() {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if t.isEmpty { commit(nil); return }
        if let v = Double(t), (0...100).contains(v) { commit(v) }
    }
}

extension ClientBook {
    /// Changes one client's share of a server, keeping the other owners.
    mutating func setShare(_ clientID: String, server id: String, _ share: Double?, now: Date = Date()) {
        var map: [String: Double?] = [:]
        for r in rows(.server, id, at: now) { map[r.clientID] = r.sharePercent }
        map[clientID] = .some(share)
        setOwners(.server, id, map, now: now)
    }
}
#endif
