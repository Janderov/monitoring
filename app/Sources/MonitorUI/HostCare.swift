#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import MonitorCore
import SwiftUI

// Upkeep of a server, so problems are seen before they happen: database
// backups, pending updates and reboots, failed SSH logins, what the server
// costs; the morning summary and the small panel on the desktop.

// MARK: - backups

/// The backup line in a database box: when the last dump was made, a button
/// to make one now and the nightly switch.
struct BackupRow: View {
    @ObservedObject var model: AppModel
    var server: ServerConfig
    var db: Snapshot.Database
    /// Nil when the agent is too old to report backups.
    var backups: [Snapshot.Backup]?

    @State private var busy = false
    @State private var error: String?
    @State private var done: String?

    private var backup: Snapshot.Backup? { backups?.first { $0.container == db.container } }
    private var engine: String { db.engine.lowercased() }
    private var supported: Bool { ["postgresql", "mysql"].contains(engine) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusDot(level: level)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary).font(.callout)
                    if let b = backup, b.count > 0 {
                        Text("копий \(b.count) · всего \(Fmt.bytes(UInt64(clamping: b.totalBytes))) · хранятся последние 7")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if backups != nil, supported, model.can(.backup, server) {
                    if busy { ProgressView().controlSize(.small) }
                    Button("Сделать сейчас") { run { try await makeNow() } }
                        .disabled(busy)
                    Toggle("Каждую ночь", isOn: Binding(get: { backup?.nightly == true },
                                                        set: { on in run { try await setNightly(on) } }))
                        .toggleStyle(.checkbox)
                        .disabled(busy)
                        .help("Бэкап каждую ночь в 03:17 по времени сервера, хранятся последние 7")
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if let done {
                Text(done).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var level: ServerStatus.Level {
        guard backups != nil else { return .unknown }
        guard let newest = backup?.newest else { return .warning }
        return Date().timeIntervalSince(newest) > Care.backupAge ? .warning : .ok
    }

    private var summary: String {
        guard backups != nil else { return "Бэкапы: обновите агента, чтобы видеть их" }
        guard supported else { return "Бэкап для \(db.engine) не поддерживается" }
        guard let newest = backup?.newest else {
            return backup?.nightly == true ? "Бэкапа ещё нет, ночной включён" : "Бэкапа нет"
        }
        let size = backup.map { " · " + Fmt.bytes(UInt64(clamping: $0.newestBytes)) } ?? ""
        return "Последний бэкап \(Fmt.relative(newest))" + size + (backup?.nightly == true ? " · каждую ночь" : "")
    }

    private func run(_ body: @escaping () async throws -> Void) {
        busy = true
        error = nil
        done = nil
        Task {
            do { try await body() } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    private func makeNow() async throws {
        let file = try await model.backend.backupDatabase(server: server, container: db.container, engine: engine, password: nil)
        done = "Готово: " + (file.isEmpty ? "бэкап сделан" : file)
    }

    private func setNightly(_ on: Bool) async throws {
        try await model.backend.setNightlyBackup(server: server, container: db.container, engine: engine, on: on, password: nil)
        done = on ? "Ночной бэкап включён" : "Ночной бэкап выключен"
    }
}

// MARK: - "Обслуживание" tab

/// Updates, the reboot flag, SSH logins and the cost of one server.
struct CareTab: View {
    @ObservedObject var model: AppModel
    var status: ServerStatus

    private var snap: Snapshot? { status.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if snap?.system == nil {
                EmptyNote(title: "Нет данных об обслуживании",
                          detail: "Обновите агентов: кнопка «Обновить агентов» вверху окна").frame(height: 120)
            } else {
                attention
                updates
                ssh
            }
            CostBox(model: model, status: status)
        }
    }

    private var attention: some View {
        let notes = Care.notes(snap, now: Date())
        return GroupBox("Требует внимания") {
            VStack(alignment: .leading, spacing: 6) {
                if notes.isEmpty {
                    Text("Ничего: обновления стоят, бэкапы свежие").foregroundStyle(.secondary)
                }
                ForEach(notes) { n in
                    HStack(spacing: 8) {
                        StatusDot(level: n.warn ? .warning : .unknown)
                        Text(n.text)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.callout)
        }
    }

    @ViewBuilder
    private var updates: some View {
        if let sys = snap?.system {
            GroupBox("Обновления") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 24) {
                        Fact(title: "Система", value: sys.os ?? "—")
                        Fact(title: "Ждут установки", value: sys.updatesCheckedAt == nil ? "неизвестно" : "\(sys.updatesPending)")
                        Fact(title: "Безопасности", value: sys.updatesCheckedAt == nil ? "—" : "\(sys.securityUpdates)")
                        Fact(title: "Перезагрузка", value: sys.rebootRequired ? "нужна" : "не нужна")
                        Spacer(minLength: 0)
                    }
                    if sys.rebootRequired, let pkgs = sys.rebootPackages, !pkgs.isEmpty {
                        Text("Из-за пакетов: " + pkgs.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let t = sys.updatesCheckedAt {
                        Text("Ubuntu пересчитала обновления \(Fmt.relative(t)). Установить: sudo apt upgrade, по SSH.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var ssh: some View {
        if let log = snap?.ssh {
            GroupBox("Входы по SSH за сутки") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(log.failedDay == 0 ? "Чужих попыток входа не было"
                         : "Чужих попыток входа: \(log.failedDay)")
                        .font(.callout)
                    let sources = Array((log.sources ?? []).prefix(8))
                    if !sources.isEmpty {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                            ForEach(sources, id: \.ip) { s in
                                GridRow {
                                    Text(s.ip).monospacedDigit().textSelection(.enabled)
                                    Text(place(s.ip)).foregroundStyle(.secondary).lineLimit(1)
                                    Text("\(s.count)").monospacedDigit().gridColumnAlignment(.trailing)
                                }
                            }
                        }
                        .font(.caption)
                    }
                    if let logins = log.logins, !logins.isEmpty {
                        Text("Успешные входы").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(Array(logins.enumerated()), id: \.offset) { _, l in
                            Text("\(Fmt.time(l.time)) · \(l.user) с \(l.ip) · \(l.method == "publickey" ? "ключ" : l.method)")
                                .font(.caption).monospacedDigit()
                        }
                    }
                    Text("Боты пробуют входить на любой сервер. Опасно, если вход по паролю включён и пароль простой.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { model.external.request((log.sources ?? []).prefix(8).map(\.ip)) }
        }
    }

    private func place(_ ip: String) -> String {
        guard let o = model.external.owners[ip] else { return "" }
        let country = o.country.flatMap { c in Country.known.first { $0.code == c }?.name } ?? o.country ?? ""
        return [country, o.network ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: - cost

/// What the server costs a month, per VPN client, and when it is paid.
struct CostBox: View {
    @ObservedObject var model: AppModel
    var status: ServerStatus

    var body: some View {
        GroupBox("Стоимость") {
            VStack(alignment: .leading, spacing: 6) {
                if let cost = status.server.cost {
                    HStack(spacing: 24) {
                        Fact(title: "В месяц", value: Money.text(cost.monthly, cost.currency))
                        if let per = Money.perClient(cost, status) {
                            Fact(title: "На один ключ VPN", value: per)
                        }
                        if let next = cost.nextPayment(after: Date()) {
                            Fact(title: "Оплата", value: Money.when(next))
                        }
                        Spacer(minLength: 0)
                    }
                } else {
                    Text("Цена не указана").foregroundStyle(.secondary)
                }
                if model.can(.editConfig, status.server) {
                    Button(status.server.cost == nil ? "Указать цену…" : "Изменить…") {
                        model.present(.editServer(status.id))
                    }
                    .buttonStyle(.link).font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

enum Money {
    /// "сегодня", "завтра", "через 5 дн" for a calendar day.
    static func when(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let n = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: day)).day ?? 0
        switch n {
        case ...0: return "сегодня"
        case 1: return "завтра"
        default: return "через \(n) дн"
        }
    }

    static func text(_ v: Double, _ currency: String) -> String {
        let n = v.rounded() == v ? String(format: "%.0f", v) : String(format: "%.2f", v)
        return n + " " + currency
    }

    /// The server's price split over its VPN keys.
    static func perClient(_ cost: ServerCost, _ s: ServerStatus) -> String? {
        let keys = (s.snapshot?.vpn ?? []).reduce(0) { $0 + ($1.peers?.count ?? 0) }
        guard keys > 0 else { return nil }
        return text(cost.monthly / Double(keys), cost.currency)
    }

    /// Totals per currency over the servers with a price, e.g. "12 € · 900 ₽".
    static func total(_ servers: [ServerConfig]) -> String? {
        var by: [String: Double] = [:]
        for s in servers { if let c = s.cost { by[c.currency, default: 0] += c.monthly } }
        guard !by.isEmpty else { return nil }
        return by.sorted { $0.key < $1.key }.map { text($0.value, $0.key) }.joined(separator: " · ")
    }
}

// MARK: - morning summary

/// Sends the morning summary once a day after the chosen hour, while the app
/// runs (a Mac that slept through the morning sends it when it wakes).
@MainActor
enum MorningDigest {
    static let enabledKey = "digest.enabled"
    static let hourKey = "digest.hour"
    static let sentKey = "digest.lastSent"

    static func checkLoop(_ model: AppModel) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            await sendIfDue(model)
        }
    }

    static func sendIfDue(_ model: AppModel) async {
        let d = UserDefaults.standard
        let enabled = d.object(forKey: enabledKey) as? Bool ?? true
        let hour = d.object(forKey: hourKey) as? Int ?? 9
        let last = d.object(forKey: sentKey) as? Date
        guard enabled, !model.showsLockScreen, !model.statuses.isEmpty, model.lastRound != nil,
              MorningSummary.due(now: Date(), hour: hour, lastSent: last) else { return }
        d.set(Date(), forKey: sentKey)
        let s = await build(model)
        model.notifyDirect?([AlertEvent(serverID: "digest", serverName: s.title, key: "digest", kind: .info,
                                        severity: .warning, message: s.body, time: Date())])
    }

    static func build(_ model: AppModel) async -> MorningSummary {
        let now = Date()
        let events = (try? await model.backend.events(limit: 2000, serverID: nil)) ?? []
        var soon: [(server: String, item: SoonItem)] = []
        var care: [(server: String, note: CareNote)] = []
        for s in model.statuses {
            for i in model.soon.items(for: s.id, model: model) { soon.append((s.server.name, i)) }
            for n in Care.notes(s.snapshot, now: now) { care.append((s.server.name, n)) }
        }
        soon.sort { $0.item.date < $1.item.date }
        let sites = model.sites
        return MorningSummary.build(servers: model.statuses.map { (name: $0.server.name, ok: $0.alerts.isEmpty && $0.snapshot != nil) },
                                    sites: (ok: sites.filter { $0.alerts.isEmpty }.count, total: sites.count),
                                    events: events, soon: soon, care: care, now: now)
    }
}

// MARK: - the small panel on the desktop

/// A small always-visible panel: overall state, servers and sites with one
/// number each. Lives in its own window that floats over other windows.
public struct MiniPanel: View {
    public static let id = "mini"
    @ObservedObject var model: AppModel
    @AppStorage("mini.floating") private var floating = true

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                StatusDot(level: model.overall, size: 10)
                Text(headline).font(.headline).lineLimit(1)
                Spacer(minLength: 4)
            }
            Divider()
            if model.showsLockScreen {
                Text("Приложение заблокировано").foregroundStyle(.secondary)
            } else {
                ForEach(model.visible) { s in
                    HStack(spacing: 6) {
                        StatusDot(level: s.level)
                        Text(s.server.name).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(s.keyFigure).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
                    }
                    .font(.callout)
                }
                if !model.sites.isEmpty {
                    Divider()
                    let bad = model.sites.filter { !$0.alerts.isEmpty }
                    Text(bad.isEmpty ? "Сайты: все \(model.sites.count) отвечают"
                         : "Сайты с проблемой: " + bad.map(\.name).joined(separator: ", "))
                        .font(.caption).foregroundStyle(bad.isEmpty ? Color.secondary : Color.red)
                }
            }
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
        .background(FloatingWindow(floating: floating))
        .contextMenu {
            Toggle("Поверх всех окон", isOn: $floating)
        }
    }

    private var headline: String {
        if model.showsLockScreen { return "Монитор" }
        let n = model.problems.count
        return n == 0 ? "Всё в порядке" : "Проблем: \(n)"
    }
}

/// Keeps the panel's window above others and on every desktop.
private struct FloatingWindow: NSViewRepresentable {
    var floating: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let w = view.window else { return }
            w.level = floating ? .floating : .normal
            w.collectionBehavior.insert(.canJoinAllSpaces)
            w.isMovableByWindowBackground = true
        }
    }
}
#endif
