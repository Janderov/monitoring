#if canImport(SwiftUI) && canImport(AppKit)
import Charts
import MonitorCore
import SwiftUI

// MARK: - Restart

/// Confirms a container restart (`container` set) or a server reboot.
/// Runs over SSH from the Mac; errors stay in the sheet.
struct RestartSheet: View {
    @ObservedObject var model: AppModel
    var server: ServerConfig
    var container: String?
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var needsPassword = false
    @State private var busy = false
    @State private var error: String?

    private var title: String {
        if let container { return "Перезапустить контейнер «\(container)»?" }
        return "Перезагрузить сервер «\(server.name)»?"
    }

    private var detail: String {
        if container != nil {
            return "Контейнер остановится и запустится снова. Пока он поднимается, его сервис будет недоступен."
        }
        return "Сервер перезагрузится. Около минуты он будет недоступен, и приложение покажет его красным, пока он не загрузится."
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Сервер", value: "\(server.name) · \(server.host)")
                } header: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.headline)
                        Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 4)
                }
                if needsPassword {
                    Section {
                        SecureField("Пароль SSH", text: $password)
                    } footer: {
                        Text("Нужен, если на сервер входят по паролю. Используется только сейчас.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        if !needsPassword {
                            Button("Ввести пароль SSH") { needsPassword = true }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 200)
            Divider()
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Button(container == nil ? "Перезагрузить" : "Перезапустить", role: .destructive, action: run)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
            }
            .padding(16)
        }
        .frame(width: 460)
    }

    private func run() {
        busy = true
        error = nil
        let pass = needsPassword && !password.isEmpty ? password : nil
        Task {
            do {
                if let container {
                    try await model.backend.restartContainer(server: server, container: container, password: pass)
                } else {
                    try await model.backend.rebootServer(server: server, password: pass)
                }
                password = ""
                busy = false
                dismiss()
            } catch {
                self.error = String(describing: error)
                busy = false
            }
        }
    }
}

// MARK: - Databases

struct DatabasesTab: View {
    @ObservedObject var model: AppModel
    var server: ServerConfig
    /// Nil when the agent is too old to report databases.
    var databases: [Snapshot.Database]?
    /// Nil when the agent is too old to report backups.
    var backups: [Snapshot.Backup]?

    var body: some View {
        if let databases, !databases.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(databases, id: \.container) { db in
                    DatabaseBox(db: db) {
                        BackupRow(model: model, server: server, db: db, backups: backups)
                    }
                }
            }
        } else if databases == nil {
            EmptyNote(title: "Нет данных о базах",
                      detail: "Обновите агента: старые версии не показывают базы данных").frame(height: 120)
        } else {
            EmptyNote(title: "Баз данных не найдено",
                      detail: "Ищутся контейнеры PostgreSQL и MySQL").frame(height: 120)
        }
    }
}

private struct DatabaseBox<Footer: View>: View {
    var db: Snapshot.Database
    @ViewBuilder var footer: Footer

    private var engine: String {
        switch db.engine.lowercased() {
        case "postgresql": return "PostgreSQL"
        case "mysql": return "MySQL"
        default: return db.engine
        }
    }

    private var load: Double? {
        guard let m = db.maxConnections, m > 0 else { return nil }
        return Double(db.connections) / Double(m) * 100
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if let e = db.error {
                    Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 24) {
                    Fact(title: "Подключения", value: db.maxConnections.map { "\(db.connections) из \($0)" } ?? "\(db.connections)")
                    Fact(title: "Всего на диске", value: Fmt.bytes(UInt64(clamping: db.totalBytes)))
                    Spacer(minLength: 0)
                }
                if let load {
                    ProgressView(value: min(load, 100), total: 100)
                        .tint(load >= 80 ? .orange : .accentColor)
                }
                let sizes = (db.databases ?? []).sorted { $0.sizeBytes > $1.sizeBytes }
                if !sizes.isEmpty {
                    Table(sizes) {
                        TableColumn("База") { s in Text(s.name).lineLimit(1) }
                        TableColumn("Размер") { s in Text(Fmt.bytes(UInt64(clamping: s.sizeBytes))).monospacedDigit() }
                            .width(min: 80, ideal: 110)
                    }
                    .fitRows(sizes.count, max: 12)
                }
                footer
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 7) {
                StatusDot(level: db.error == nil ? .ok : .warning)
                Text("\(engine) · \(db.container)").font(.callout.weight(.semibold)).lineLimit(1)
            }
        }
    }
}

extension Snapshot.Database.Size: Identifiable { public var id: String { name } }

// MARK: - Latency to other servers

/// Round trip from this server to the agents of the others, one line per server.
struct LinkLatencyBox: View {
    @ObservedObject var model: AppModel
    var serverID: String
    var period: Period
    var reload: String

    struct Point: Identifiable {
        var time: Date
        var latency: Double
        var peer: String
        var segment: Int
        var id: String { "\(peer)|\(time.timeIntervalSince1970)" }
    }

    @State private var points: [Point] = []
    @State private var now: [(peer: String, text: String)] = []

    var body: some View {
        GroupBox {
            if points.isEmpty {
                Text("Нет данных за период. Задержка появится после обновления агентов.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Chart(points) { p in
                    LineMark(x: .value("Время", p.time), y: .value("мс", p.latency),
                             series: .value("Линия", "\(p.peer)-\(p.segment)"))
                        .foregroundStyle(by: .value("Сервер", p.peer))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.monotone)
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.ms(d)).font(.caption2) } }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisValueLabel(format: period.usesHourly ? .dateTime.day().month(.abbreviated) : .dateTime.hour().minute())
                    }
                }
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 140)
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text("Задержка до серверов").font(.callout.weight(.semibold)).lineLimit(1)
                if !now.isEmpty {
                    Text(now.map { "\($0.peer) \($0.text)" }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
            }
        }
        .task(id: reload) { await load() }
    }

    private func name(_ id: String) -> String { model.status(id)?.server.name ?? id }

    private func load() async {
        let to = Date(), from = to.addingTimeInterval(-period.seconds)
        let rows = (try? await model.backend.linkSamples(serverID, from: from, to: to)) ?? []
        // Minute checks are averaged into buckets so a week stays readable.
        let bucket = period.bucket
        var sums: [String: [TimeInterval: (Double, Int)]] = [:]
        var latest: [String: Store.LinkSample] = [:]
        for r in rows {
            latest[r.peerID] = r
            guard r.ok, let ms = r.latencyMs else { continue }
            let t = (r.time.timeIntervalSince1970 / bucket).rounded(.down) * bucket
            let cur = sums[r.peerID, default: [:]][t] ?? (0, 0)
            sums[r.peerID, default: [:]][t] = (cur.0 + ms, cur.1 + 1)
        }
        var out: [Point] = []
        for (peer, byTime) in sums {
            var segment = 0
            var last: TimeInterval?
            for t in byTime.keys.sorted() {
                if let last, t - last > bucket * 3 { segment += 1 }
                last = t
                let v = byTime[t]!
                out.append(Point(time: Date(timeIntervalSince1970: t), latency: v.0 / Double(v.1),
                                 peer: name(peer), segment: segment))
            }
        }
        points = out
        now = latest.values.sorted { name($0.peerID) < name($1.peerID) }.map { s in
            (name(s.peerID), s.ok ? (s.latencyMs.map(Fmt.ms) ?? "—") : "недоступен")
        }
    }
}
#endif
