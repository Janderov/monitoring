#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import CoreLocation
import Foundation
import MapKit
import MonitorCore
import SwiftUI
import UniformTypeIdentifiers

// The map's modes and the tools of its "Разбор" mode: what breaks if a
// server goes away, checks from Russian cities, where packets are lost,
// VPN clients by city, what runs out soon, the picture of the map.

/// What the map is for right now. The map stays calm in "Сейчас"; the past
/// and the troubleshooting tools each have their own mode.
enum MapMode: String, CaseIterable, Identifiable {
    case now, history, diagnose
    var id: String { rawValue }

    var title: String {
        switch self {
        case .now: return "Сейчас"
        case .history: return "История"
        case .diagnose: return "Разбор"
        }
    }
}

/// Sections of the panel next to a server pin.
enum InspectorTab: String, CaseIterable, Identifiable {
    case summary, paths, checks
    var id: String { rawValue }

    var title: String {
        switch self {
        case .summary: return "Сводка"
        case .paths: return "Пути"
        case .checks: return "Проверки"
        }
    }
}

/// A server switched off "on paper" in the Разбор mode: what the map draws red.
struct WhatIfDraw {
    var off: String
    var impact: WhatIfImpact

    /// A line between two nodes (servers or this Mac) stops carrying traffic.
    func hits(_ from: String, _ to: String) -> Bool {
        from == off || to == off || impact.brokenChains.contains { $0.contains(from: from, to: to) }
    }

    /// Clients of this server lose their connection.
    func cutsClients(of serverID: String) -> Bool {
        serverID == off || impact.brokenChains.contains { $0.nodes.first == serverID }
    }
}

// MARK: - checks from Russian cities

/// A TCP connect to the server's agent port from check-host.net probes in
/// Russian cities, on demand: shows where providers block the server.
@MainActor
final class CityCheckModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        var id: String
        var city: String
        var result: CheckHost.Result
    }

    struct Run: Equatable {
        var rows: [Row] = []
        var running = true
        var error: String?
        var time = Date()
    }

    struct Failure: Error {
        var text: String
        init(_ text: String) { self.text = text }
    }

    @Published private(set) var runs: [String: Run] = [:]
    private var nodes: [CheckHost.Node] = []
    private var tasks: [String: Task<Void, Never>] = [:]

    func check(_ server: ServerConfig) {
        tasks[server.id]?.cancel()
        let id = server.id
        let target = server.host + ":" + String(server.port)
        runs[id] = Run()
        tasks[id] = Task {
            do {
                if nodes.isEmpty { nodes = CheckHost.nodes(try await Self.get("/nodes/hosts")) }
                let probes = nodes
                guard !probes.isEmpty else { throw Failure("Сервис проверки не назвал ни одного города в России.") }
                let names = Self.labels(probes)
                var path = "/check-tcp?host=" + (target.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? target)
                for n in probes { path += "&node=" + n.id }
                guard let request = CheckHost.requestID(try await Self.get(path)) else {
                    throw Failure("Сервис проверки не принял запрос.")
                }
                runs[id]?.rows = probes.map { Row(id: $0.id, city: names[$0.id] ?? $0.city, result: .pending) }
                for _ in 0..<12 {
                    try await Task.sleep(for: .seconds(2))
                    let res = CheckHost.results(try await Self.get("/check-result/" + request))
                    runs[id]?.rows = probes.map { Row(id: $0.id, city: names[$0.id] ?? $0.city, result: res[$0.id] ?? .pending) }
                    if probes.allSatisfy({ (res[$0.id] ?? .pending) != .pending }) { break }
                }
                runs[id]?.running = false
                runs[id]?.time = Date()
            } catch is CancellationError {
                return
            } catch {
                runs[id]?.running = false
                runs[id]?.error = (error as? Failure)?.text ?? "Не удалось проверить: \(error.localizedDescription)"
            }
        }
    }

    nonisolated static func get(_ path: String) async throws -> Data {
        guard let url = URL(string: CheckHost.base + path) else { throw Failure("Неверный адрес проверки.") }
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: r)
        if let h = response as? HTTPURLResponse, h.statusCode != 200 {
            throw Failure("Сервис проверки ответил \(h.statusCode).")
        }
        return data
    }

    /// City names in Russian; two probes in one city get a number.
    static func labels(_ nodes: [CheckHost.Node]) -> [String: String] {
        var seen: [String: Int] = [:]
        var out: [String: String] = [:]
        for n in nodes {
            let name = cities[n.city] ?? n.city
            seen[name, default: 0] += 1
            out[n.id] = seen[name]! > 1 ? "\(name) \(seen[name]!)" : name
        }
        return out
    }

    static let cities = [
        "Moscow": "Москва", "Saint Petersburg": "Петербург", "St Petersburg": "Петербург",
        "Saint-Petersburg": "Петербург", "Ekaterinburg": "Екатеринбург", "Yekaterinburg": "Екатеринбург",
        "Novosibirsk": "Новосибирск", "Kazan": "Казань", "Nizhny Novgorod": "Нижний Новгород",
        "Krasnodar": "Краснодар", "Rostov-on-Don": "Ростов-на-Дону", "Samara": "Самара",
        "Chelyabinsk": "Челябинск", "Vladivostok": "Владивосток", "Khabarovsk": "Хабаровск", "Omsk": "Омск",
        "Perm": "Пермь", "Ufa": "Уфа", "Krasnoyarsk": "Красноярск", "Voronezh": "Воронеж",
        "Volgograd": "Волгоград", "Irkutsk": "Иркутск", "Tyumen": "Тюмень", "Saratov": "Саратов",
        "Tula": "Тула", "Kaliningrad": "Калининград", "Sochi": "Сочи", "Murmansk": "Мурманск",
    ]
}

// MARK: - where packets are lost

/// `traceroute` from this Mac to a server, on demand.
@MainActor
final class TraceModel: ObservableObject {
    struct Run: Equatable {
        var hops: [TraceHop] = []
        var running = true
        var error: String?
        var time = Date()
    }

    @Published private(set) var runs: [String: Run] = [:]

    func run(_ server: ServerConfig) {
        guard runs[server.id]?.running != true else { return }
        let id = server.id
        let host = server.host
        runs[id] = Run()
        Task {
            let text = await Task.detached(priority: .utility) { () -> String? in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/traceroute")
                // Three probes per step, a second each, at most 24 steps.
                p.arguments = ["-n", "-q", "3", "-w", "1", "-m", "24", host]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { return nil }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return String(decoding: data, as: UTF8.self)
            }.value
            let hops = text.map(Traceroute.parse) ?? []
            var run = Run(hops: hops, running: false, error: nil, time: Date())
            if text == nil { run.error = "Не удалось запустить traceroute." }
            else if hops.isEmpty { run.error = "traceroute ничего не вернул." }
            runs[id] = run
        }
    }
}

// MARK: - VPN clients by city

/// Cities of VPN clients' addresses, looked up once per address.
@MainActor
final class ClientCities: ObservableObject {
    @Published private(set) var cities: [String: IPCity] = [:]
    private var asked: Set<String> = []

    func request(_ ips: [String]) {
        let new = ips.filter { !asked.contains($0) && !Self.isPrivate($0) }
        guard !new.isEmpty else { return }
        asked.formUnion(new)
        Task {
            for ip in new {
                guard let url = IPWho.url(ip),
                      let r = try? await URLSession.shared.data(from: url),
                      let city = IPWho.parse(r.0) else { continue }
                cities[ip] = city
            }
        }
    }

    static func isPrivate(_ ip: String) -> Bool {
        let p = ip.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return ip.hasPrefix("fe80") || ip.hasPrefix("fd") }
        return p[0] == 10 || p[0] == 127 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && (16...31).contains(p[1]))
            || (p[0] == 100 && (64...127).contains(p[1]))
    }
}

// MARK: - what runs out soon

/// Disk forecasts from the hourly history, refreshed at most twice an hour.
@MainActor
final class SoonModel: ObservableObject {
    /// Server id -> days until the disk is full.
    @Published private(set) var diskDays: [String: Double] = [:]
    private var checkedAt: Date?

    func refresh(_ model: AppModel) {
        if let c = checkedAt, Date().timeIntervalSince(c) < 1800 { return }
        checkedAt = Date()
        let ids = model.statuses.map(\.id)
        let backend = model.backend
        Task {
            let now = Date()
            var out: [String: Double] = [:]
            for id in ids {
                let rows = (try? await backend.hourly(id, from: now.addingTimeInterval(-14 * 86400), to: now)) ?? []
                if let d = DiskForecast.daysUntilFull(rows.map { (time: $0.hour, percent: $0.diskMax) }, now: now) {
                    out[id] = d
                }
            }
            diskDays = out
        }
    }

    func items(for serverID: String, model: AppModel) -> [SoonItem] {
        let hosted = model.sites.filter { model.siteHosts.server[$0.id] == serverID }
        return Soon.items(sites: hosted.map { (name: $0.name, tls: $0.tlsExpiry, domain: $0.domainExpiry) },
                          diskDays: diskDays[serverID], now: Date())
    }
}

// MARK: - panel sections

/// Small grey caption over a group of rows, as elsewhere in the panel.
struct PanelCaption: View {
    var text: String
    var body: some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }
}

/// "Скоро": certificates, domains and the disk running out.
struct SoonSection: View {
    var items: [SoonItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PanelCaption(text: "Скоро")
            if items.isEmpty {
                Text("Ничего не истекает в ближайший месяц").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(items) { i in
                let days = Fmt.days(until: i.date)
                HStack {
                    if i.date.timeIntervalSinceNow <= Soon.badgeWindow {
                        StatusDot(level: .warning)
                    }
                    Text(title(i)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(days <= 0 ? "сейчас" : "через \(days) дн")
                        .foregroundStyle(days <= 7 ? Color.orange : Color.primary).monospacedDigit()
                }
                .font(.callout)
                .help(i.date.formatted(date: .long, time: .omitted))
            }
        }
    }

    private func title(_ i: SoonItem) -> String {
        switch i.kind {
        case .tls: return "SSL \(i.name)"
        case .domain: return "Домен \(i.name)"
        case .disk: return "Диск заполнится"
        }
    }
}

/// "Где теряются пакеты": traceroute from this Mac.
struct TraceSection: View {
    var server: ServerConfig
    @ObservedObject var traces: TraceModel
    /// The Mac reaches the server through a VPN tunnel.
    var throughVPN: Bool

    var body: some View {
        let run = traces.runs[server.id]
        VStack(alignment: .leading, spacing: 6) {
            PanelCaption(text: "Где теряются пакеты (этот Mac → \(server.name))")
            if let run, !run.hops.isEmpty {
                let culprit = Traceroute.culprit(run.hops)
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                    ForEach(run.hops, id: \.number) { h in
                        let bad = culprit.map { h.number >= $0.number } ?? false
                        GridRow {
                            Text("\(h.number)").foregroundStyle(.secondary)
                            Text(h.ip ?? "не отвечает").lineLimit(1)
                                .foregroundStyle(h.ip == nil ? Color.secondary : Color.primary)
                            Text(h.averageMs.map(Fmt.ms) ?? "—").gridColumnAlignment(.trailing)
                            Text(h.lost == 0 ? "0%" : Fmt.percent(h.loss * 100)).gridColumnAlignment(.trailing)
                        }
                        .foregroundStyle(bad ? Color.red : Color.primary)
                    }
                }
                .font(.caption).monospacedDigit()
                Text(verdict(run.hops, culprit))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if run?.running != true {
                Text("Покажет каждый шаг пути от этого Mac до сервера и место, где пропадают пакеты.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let e = run?.error {
                Text(e).font(.caption).foregroundStyle(.red)
            }
            if throughVPN {
                Text("Mac ходит к этому серверу через VPN, поэтому путь показан внутри туннеля.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(run == nil ? "Проверить путь" : "Проверить ещё раз") { traces.run(server) }
                    .disabled(run?.running == true)
                if run?.running == true {
                    ProgressView().controlSize(.small)
                    Text("до минуты").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func verdict(_ hops: [TraceHop], _ culprit: TraceHop?) -> String {
        guard let c = culprit else {
            return "Пакеты не теряются. Если шаг посередине «не отвечает», это роутер, который молчит на проверки, а не потери."
        }
        if hops.last?.ip == nil, hops.last?.rtts.isEmpty == true {
            return "Путь обрывается после шага \(max(c.number - 1, 0)). Дальше ответа нет."
        }
        return "Потери начинаются на шаге \(c.number)" + (c.ip.map { " (\($0))" } ?? "")
            + " и держатся до сервера. Если это не ваш сервер, остаётся ждать или менять маршрут."
    }
}

/// "Из городов России": check-host.net probes.
struct CitySection: View {
    var server: ServerConfig
    @ObservedObject var checks: CityCheckModel

    var body: some View {
        let run = checks.runs[server.id]
        VStack(alignment: .leading, spacing: 6) {
            PanelCaption(text: "Из городов России")
            if let run, !run.rows.isEmpty {
                ForEach(run.rows) { r in
                    HStack {
                        StatusDot(level: level(r.result))
                        Text(r.city).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(text(r.result)).foregroundStyle(color(r.result)).monospacedDigit()
                    }
                    .font(.callout)
                }
                if !run.running, let v = verdict(run.rows) {
                    Text(v).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else if run?.running != true {
                Text("Проверит порт агента из нескольких городов через сервис check-host.net. Так видно, где провайдеры блокируют сервер.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let e = run?.error {
                Text(e).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(run == nil ? "Проверить из городов" : "Проверить ещё раз") { checks.check(server) }
                    .disabled(run?.running == true)
                if run?.running == true { ProgressView().controlSize(.small) }
                if let run, !run.running, run.error == nil {
                    Text(Fmt.relative(run.time)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func level(_ r: CheckHost.Result) -> ServerStatus.Level {
        switch r {
        case .ok(let ms): return ms > 250 ? .warning : .ok
        case .failed: return .critical
        case .pending: return .unknown
        }
    }

    private func text(_ r: CheckHost.Result) -> String {
        switch r {
        case .ok(let ms): return Fmt.ms(ms)
        case .failed(let e): return CheckHost.describe(e)
        case .pending: return "проверяю…"
        }
    }

    private func color(_ r: CheckHost.Result) -> Color {
        switch level(r) {
        case .critical: return .red
        case .warning: return .orange
        case .unknown: return .secondary
        case .ok: return .primary
        }
    }

    private func verdict(_ rows: [CityCheckModel.Row]) -> String? {
        let failed = rows.filter { if case .failed = $0.result { return true } else { return false } }
        if failed.isEmpty { return "Сервер открыт из всех проверенных городов." }
        if failed.count == rows.count { return "Ни один город не достучался. Скорее всего, сервер или порт закрыт для всех, а не блокировка." }
        return "Не открывается из: " + failed.map(\.city).joined(separator: ", ") + ". Похоже на блокировку у провайдеров там."
    }
}

/// "Что если выключить": the consequences, drawn on the map on demand.
struct WhatIfSection: View {
    @ObservedObject var model: AppModel
    var server: ServerConfig
    var impact: WhatIfImpact?
    /// The map shows this server switched off.
    var shown: Bool
    var toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelCaption(text: "Что если выключить")
            Text("Ничего не выключается по-настоящему: карта только показывает, что сломается.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if shown, let i = impact {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    row("Клиенты VPN", i.clientsLost == 0 ? "не затронуты" : "\(i.clientsLost) из \(i.clientsTotal) без связи",
                        bad: i.clientsLost > 0)
                    row("Пути", i.brokenChains.isEmpty ? "не затронуты" : "оборвётся \(i.brokenChains.count)",
                        bad: !i.brokenChains.isEmpty)
                    row("Сайты на нём", i.sites.isEmpty ? "нет" : names(i.sites), bad: !i.sites.isEmpty)
                    if !i.checks.isEmpty {
                        row("Проверки сайтов", "минус одна страна у \(i.checks.count)", bad: false)
                    }
                    if let backup = i.hasBackup {
                        row("Запасной путь", backup ? "есть" : "нет", bad: !backup)
                    }
                }
                .font(.callout)
                ForEach(i.brokenChains) { c in
                    Text(c.nodes.map(name).joined(separator: " → "))
                        .font(.caption).foregroundStyle(.red).lineLimit(1)
                }
            }
            Button(shown ? "Убрать с карты" : "Показать на карте", action: toggle)
        }
    }

    private func row(_ k: String, _ v: String, bad: Bool) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).foregroundStyle(bad ? Color.red : Color.primary)
        }
    }

    private func names(_ siteIDs: [String]) -> String {
        siteIDs.map { id in model.sites.first { $0.id == id }?.name ?? id }.joined(separator: ", ")
    }

    private func name(_ id: String) -> String {
        id == MacLinksModel.pinID ? "Этот Mac" : (model.status(id)?.server.name ?? id)
    }
}

// MARK: - picture of the map

/// The map drawn into a picture with its pins and lines: MapKit's own view
/// cannot be captured, so the snapshot redraws what matters on top of a map
/// image of the same area.
struct MapPicture {
    struct Dot {
        var at: CLLocationCoordinate2D
        var name: String
        var color: NSColor
    }

    struct Line {
        var from: CLLocationCoordinate2D
        var to: CLLocationCoordinate2D
        var color: NSColor
        var width: CGFloat
        var dashed: Bool
    }

    var region: MKCoordinateRegion
    var dots: [Dot]
    var lines: [Line]
    var caption: String

    func render() async -> NSImage? {
        let o = MKMapSnapshotter.Options()
        o.region = region
        o.size = NSSize(width: 1600, height: 1000)
        o.mapType = .mutedStandard
        o.pointOfInterestFilter = .excludingAll
        o.appearance = NSAppearance(named: .aqua)
        guard let snap = try? await MKMapSnapshotter(options: o).start() else { return nil }
        let base = snap.image
        let dots = dots, lines = lines, caption = caption
        return NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            for l in lines {
                let p = NSBezierPath()
                p.move(to: snap.point(for: l.from))
                p.line(to: snap.point(for: l.to))
                p.lineWidth = l.width
                p.lineCapStyle = .round
                if l.dashed {
                    var dash: [CGFloat] = [6, 5]
                    p.setLineDash(&dash, count: 2, phase: 0)
                }
                l.color.setStroke()
                p.stroke()
            }
            let label: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.black,
                .strokeColor: NSColor.white,
                .strokeWidth: -3.0,
            ]
            for d in dots {
                let c = snap.point(for: d.at)
                let circle = NSBezierPath(ovalIn: NSRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16))
                d.color.setFill()
                circle.fill()
                NSColor.white.setStroke()
                circle.lineWidth = 2.5
                circle.stroke()
                (d.name as NSString).draw(at: NSPoint(x: c.x + 11, y: c.y - 8), withAttributes: label)
            }
            let text = caption as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black]
            let size = text.size(withAttributes: attrs)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: NSRect(x: 12, y: 12, width: size.width + 16, height: size.height + 8),
                         xRadius: 6, yRadius: 6).fill()
            text.draw(at: NSPoint(x: 20, y: 16), withAttributes: attrs)
            return true
        }
    }

    @MainActor static func save(_ image: NSImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let stamp = Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute())
            .replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "Карта \(stamp).png"
        guard panel.runModal() == .OK, let url = panel.url,
              let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    @MainActor static func copy(_ image: NSImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }
}

// MARK: - wall mode

enum WallMode {
    /// Fills the screen with the map: the window goes full screen, the
    /// sidebar, toolbar and panels hide.
    @MainActor static func set(_ on: Bool, model: AppModel) {
        model.wallMode = on
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        if on != window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    }
}
#endif
