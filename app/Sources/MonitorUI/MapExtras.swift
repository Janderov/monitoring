#if canImport(SwiftUI) && canImport(AppKit)
import CoreLocation
import Darwin
import Foundation
import MonitorCore
import SwiftUI

// The map's extra layers: checks from this Mac, sites around their server,
// traffic on the lines, whole paths and the map as it was in the past.

// MARK: - checks from this Mac

/// A TCP connect from this Mac to each server's agent port, every 30 s while
/// the map is open. Next to the servers' checks of each other it tells
/// "blocked for this Mac's provider" from "down".
@MainActor
public final class MacProbeModel: ObservableObject {
    public struct Probe: Equatable, Sendable {
        /// Nil when the server did not answer.
        public var latencyMs: Double?
        /// The interface macOS sends this traffic through, e.g. "en0" or "utun4".
        public var interface: String?
        public var time: Date
        public var ok: Bool { latencyMs != nil }
        public var throughVPN: Bool { MacRouting.isTunnel(interface) }
    }

    @Published public private(set) var probes: [String: Probe] = [:]
    @Published public private(set) var running = false
    private var targets: [ServerConfig] = []

    func setTargets(_ servers: [ServerConfig]) { targets = servers }

    /// Repeats until the calling task is cancelled (the map closes).
    func run() async {
        while !Task.isCancelled {
            await probeAll()
            try? await Task.sleep(for: .seconds(30))
        }
    }

    func probeAll() async {
        guard !running, !targets.isEmpty else { return }
        running = true
        let list = targets
        let found = await withTaskGroup(of: (String, Probe).self) { group in
            for s in list {
                group.addTask {
                    let ms = MacProbeModel.connectTime(host: s.host, port: s.port, timeout: 5)
                    let iface = MacProbeModel.interface(to: s.host)
                    return (s.id, Probe(latencyMs: ms, interface: iface, time: Date()))
                }
            }
            var out: [String: Probe] = [:]
            for await (id, p) in group { out[id] = p }
            return out
        }
        probes = found
        running = false
    }

    /// Milliseconds to open a TCP connection, nil on failure or timeout.
    nonisolated static func connectTime(host: String, port: Int, timeout: Double) -> Double? {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let ai = res else { return nil }
        defer { freeaddrinfo(res) }
        let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        let start = DispatchTime.now()
        if connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) != 0 {
            guard errno == EINPROGRESS else { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, Int32(timeout * 1000)) == 1 else { return nil }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0, err == 0 else { return nil }
        }
        return Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    nonisolated static func interface(to host: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/route")
        p.arguments = ["-n", "get", host]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return MacRouting.interface(routeGet: String(decoding: data, as: UTF8.self))
    }
}

// MARK: - sites

/// Which server each site runs on: the site's DNS addresses compared with
/// the servers' ones, every 10 minutes at most.
@MainActor
final class SiteHostsModel: ObservableObject {
    /// Site id -> id of the server it runs on.
    @Published private(set) var server: [String: String] = [:]
    /// Site id -> its addresses, for the country of a site hosted elsewhere.
    @Published private(set) var addresses: [String: [String]] = [:]
    private var key = ""
    private var checkedAt: Date?

    func refresh(sites: [SiteConfig], servers: [ServerConfig]) {
        let k = (sites.map { $0.id + "=" + $0.url } + servers.map { $0.id + "=" + $0.host }).joined(separator: ",")
        if k == key, let c = checkedAt, Date().timeIntervalSince(c) < 600 { return }
        key = k
        checkedAt = Date()
        Task {
            let found = await Task.detached(priority: .utility) { () -> ([String: String], [String: [String]]) in
                let known = servers.map { (id: $0.id, addresses: SiteHostsModel.resolve($0.host)) }
                var host: [String: String] = [:]
                var addrs: [String: [String]] = [:]
                for s in sites {
                    guard let h = SiteHosting.host(of: s.url) else { continue }
                    let a = SiteHostsModel.resolve(h)
                    addrs[s.id] = a
                    host[s.id] = SiteHosting.server(siteAddresses: a, servers: known)
                }
                return (host, addrs)
            }.value
            server = found.0
            addresses = found.1
        }
    }

    nonisolated static func resolve(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return [] }
        defer { freeaddrinfo(res) }
        var out: [String] = []
        for p in sequence(first: first, next: { $0.pointee.ai_next }) {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(p.pointee.ai_addr, p.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                let s = String(cString: buf)
                if !out.contains(s) { out.append(s) }
            }
        }
        return out
    }
}

/// Sites drawn around one place on the map: the pin of the server they run
/// on, or the country of a hosting that is not ours.
struct SiteCluster: Identifiable {
    var id: String
    var coordinate: CLLocationCoordinate2D
    var sites: [SiteSummary]
    /// The sites run on one of our servers (otherwise on a hosting elsewhere).
    var onServer: Bool
    var place: String

    static let prefix = "sites-"
}

/// How a site looks on the map now, or at the moment the history shows.
enum SiteMark {
    static func level(_ s: SiteSummary, history: [String: Bool]?) -> ServerStatus.Level {
        guard let history else { return s.level() }
        if history.isEmpty { return .unknown }
        let failed = history.values.filter { !$0 }.count
        if failed == 0 { return .ok }
        return failed == history.count ? .critical : .warning
    }
}

/// Small square site icons in a ring around a point.
struct SiteRingView: View {
    var cluster: SiteCluster
    var levels: [String: ServerStatus.Level]
    var select: (String) -> Void

    /// Upper half first: the pin's title is below it.
    private static let angles: [Double] = [-90, -50, -130, -10, -170, 30, 150, -70, -110, -30, -150]

    var body: some View {
        ZStack {
            if !cluster.onServer {
                Circle().fill(Color.gray.opacity(0.5)).frame(width: 6, height: 6)
            }
            ForEach(Array(cluster.sites.enumerated()), id: \.element.id) { i, s in
                let ring = i / Self.angles.count
                let a = Self.angles[i % Self.angles.count] * .pi / 180
                let r: CGFloat = (cluster.onServer ? 30 : 20) + CGFloat(ring) * 18
                Button { select(s.id) } label: { icon(s) }
                    .buttonStyle(.plain)
                    .offset(x: CGFloat(cos(a)) * r, y: CGFloat(sin(a)) * r)
            }
        }
        .frame(width: side, height: side)
    }

    /// Big enough for the outer ring, so every icon is inside the annotation.
    private var side: CGFloat {
        let rings = CGFloat(max(0, cluster.sites.count - 1) / Self.angles.count)
        return 2 * ((cluster.onServer ? 30 : 20) + rings * 18 + 12)
    }

    private func tip(_ s: SiteSummary, problem: Bool) -> String {
        var t = s.name + ": "
        t += problem ? (s.problem ?? "есть проблемы") : "открывается"
        if !cluster.onServer { t += " · хостинг: " + cluster.place }
        return t
    }

    private func icon(_ s: SiteSummary) -> some View {
        let level = levels[s.id] ?? .unknown
        let problem = level == .warning || level == .critical
        return Image(systemName: "globe")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(problem ? Color.white : Color.secondary)
            .frame(width: 17, height: 17)
            .background(problem ? level.color : Color(nsColor: .windowBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(problem ? Color.white : Color.secondary.opacity(0.6),
                                                                    lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            .help(tip(s, problem: problem))
            .contentShape(Rectangle())
    }
}

/// The panel for a site picked on the map.
struct SiteInspector: View {
    @ObservedObject var model: AppModel
    var site: SiteSummary
    var cluster: SiteCluster?
    var history: [String: Bool]?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        StatusDot(level: SiteMark.level(site, history: history), size: 10)
                        Text(site.name).font(.headline).lineLimit(1)
                    }
                    Text(site.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if let c = cluster {
                        Text(c.onServer ? "Работает на сервере \(c.place)" : "Хостинг не на ваших серверах: \(c.place)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(history == nil ? "Открывается из" : "Открывался из").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(site.origins) { o in
                        HStack {
                            let ok = history.map { $0[o.serverID] } ?? (o.check.map(\.ok))
                            StatusDot(level: ok.map { $0 ? ServerStatus.Level.ok : ServerStatus.Level.critical } ?? ServerStatus.Level.unknown)
                            Text(o.place).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(value(o, ok: ok)).foregroundStyle(ok == false ? Color.red : Color.primary).monospacedDigit()
                        }
                        .font(.callout)
                    }
                }
                if history == nil, let p = site.problem {
                    AlertStrip(level: site.level(), text: p, trailing: nil).font(.callout)
                }
                Button("Открыть сайт в приложении") {
                    model.selectedSiteID = site.id
                    model.section = .sites
                }
            }
            .padding(16)
        }
    }

    private func value(_ o: SiteSummary.Origin, ok: Bool?) -> String {
        guard let ok else { return "нет данных" }
        if history != nil { return ok ? "открывался" : "не открывался" }
        guard let c = o.check else { return "нет данных" }
        return ok ? Fmt.ms(c.latencyMs) : (c.error ?? c.statusCode.map { "HTTP \($0)" } ?? "нет ответа")
    }
}

// MARK: - traffic

enum TrafficStyle {
    /// "12,4 Мбит/с", "820 кбит/с".
    static func text(_ r: RateMeter.Rate) -> String { bits(r.total) }

    static func bits(_ bytesPerSec: Double) -> String {
        let mbit = bytesPerSec * 8 / 1_000_000
        if mbit >= 10 { return String(format: "%.0f Мбит/с", mbit) }
        if mbit >= 1 { return String(format: "%.1f Мбит/с", mbit).replacingOccurrences(of: ".", with: ",") }
        return String(format: "%.0f кбит/с", bytesPerSec * 8 / 1000)
    }

    /// "↓ 9,7 · ↑ 1,2 Мбит/с" seen from the side whose counter it is.
    static func detail(_ r: RateMeter.Rate, downIsTx: Bool) -> String {
        let down = downIsTx ? r.tx : r.rx, up = downIsTx ? r.rx : r.tx
        return "↓ " + bits(down) + " · ↑ " + bits(up)
    }

    /// Thicker lines carry more: 1 Мбит/с a bit, 100 Мбит/с a lot.
    static func width(_ r: RateMeter.Rate?, base: CGFloat) -> CGFloat {
        guard let r else { return base }
        let mbit = r.total * 8 / 1_000_000
        return base + min(6, CGFloat(log2(1 + mbit)) * 1.2)
    }

    /// Below this a line is idle, not worth a label.
    static func worthShowing(_ r: RateMeter.Rate?) -> Bool { (r?.total ?? 0) * 8 >= 20_000 }
}

/// Traffic on each kind of line, from counters the app already has.
@MainActor
enum Traffic {
    /// A cascade between servers. A tunnel is the entry server's peer
    /// counter; a relay has no counter of its own, so the exit server's
    /// whole traffic stands in for it (`approximate`).
    static func route(_ r: VPNRoute, model: AppModel) -> (rate: RateMeter.Rate, approximate: Bool)? {
        guard let from = model.status(r.fromID), let to = model.status(r.toID) else { return nil }
        if r.kind == .tunnel {
            var keys: [String] = []
            for vpn in from.snapshot?.vpn ?? [] {
                for p in vpn.peers ?? [] where p.endpoint.flatMap(VPNClientSpot.host) == to.server.host {
                    keys.append(RateMeter.peerKey(server: from.id, publicKey: p.publicKey))
                }
            }
            if let rate = model.peerRates.sum(keys) { return (rate, false) }
        }
        guard let n = to.snapshot?.network else { return nil }
        return (RateMeter.Rate(rx: n.rxBytesPerSec, tx: n.txBytesPerSec), true)
    }

    /// This Mac's traffic on a route: its VPN tunnel as the server's peer
    /// counter sees it, plus its programs' connections to that server.
    static func mac(_ r: MacRoute, model: AppModel) -> RateMeter.Rate? {
        guard let to = model.status(r.toID) else { return nil }
        var total: RateMeter.Rate?
        func add(_ x: RateMeter.Rate?) { if let x { total = (total ?? RateMeter.Rate(rx: 0, tx: 0)) + x } }
        if r.viaID == nil {
            let mine = Set(model.mac.tunnelAddresses.map { $0 + "/32" })
            var keys: [String] = []
            for vpn in to.snapshot?.vpn ?? [] {
                for p in vpn.peers ?? [] where p.active {
                    let allowed = (p.allowedIps ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    if allowed.contains(where: mine.contains) { keys.append(RateMeter.peerKey(server: to.id, publicKey: p.publicKey)) }
                }
            }
            // Seen from the server: rx is what the Mac sent. Turn it around.
            if let peer = model.peerRates.sum(keys) { add(RateMeter.Rate(rx: peer.tx, tx: peer.rx)) }
        }
        var keys: [String] = []
        for l in model.mac.links where l.remoteIP == to.server.host && r.processes.contains(l.process) {
            keys += RateMeter.connectionKeys(l).keys
        }
        add(model.mac.rates.sum(keys))
        return total
    }

    /// VPN clients of one pin that use one server, from the server's side.
    static func clients(_ pin: ClientPin, server: String, model: AppModel) -> RateMeter.Rate? {
        let keys = pin.clients.filter { $0.serverID == server }
            .map { RateMeter.peerKey(server: server, publicKey: $0.publicKey) }
        return model.peerRates.sum(keys)
    }
}

/// A rate label on a line.
struct TrafficLabel: View {
    var text: String
    var tint: Color
    var help: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold)).monospacedDigit()
            .foregroundStyle(tint)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.regularMaterial, in: Capsule())
            .help(help)
    }
}

// MARK: - whole path

/// The panel for a path through our servers: every hop with its latency,
/// the total, where sites see the traffic come from.
struct PathInspector: View {
    @ObservedObject var model: AppModel
    @ObservedObject var probes: MacProbeModel
    @ObservedObject var external: ExternalOwners
    var chain: NetworkChain

    private struct Hop: Identifiable {
        var id: String
        var to: String
        var latencyMs: Double?
        /// The hop was measured and failed.
        var failed: Bool
        var how: String
    }

    var body: some View {
        let list = hopList()
        let measured = list.compactMap(\.latencyMs)
        let slow = list.filter { $0.latencyMs != nil }.max { ($0.latencyMs ?? 0) < ($1.latencyMs ?? 0) }
        let end = endpoint()
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ВЕСЬ ПУТЬ").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text((chain.nodes.map(name) + (end.map { [$0] } ?? [])).joined(separator: " → "))
                        .font(.headline).fixedSize(horizontal: false, vertical: true)
                    if !chain.active {
                        Text("Сейчас по этому пути нет трафика, он найден по настройкам.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    node(chain.nodes[0], latency: nil, failed: false, sub: subtitle(chain.nodes[0], how: nil))
                    ForEach(list) { h in
                        connector
                        node(h.to, latency: h.latencyMs, failed: h.failed, sub: subtitle(h.to, how: h.how))
                    }
                    if let end {
                        connector
                        endNode(end)
                    }
                }
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                    GridRow {
                        Text("Задержка всего пути").foregroundStyle(.secondary)
                        if list.contains(where: \.failed) {
                            Text("путь оборван").foregroundStyle(.red)
                        } else {
                            Text(measured.isEmpty ? "—" : Fmt.ms(measured.reduce(0, +))
                                 + (measured.count < list.count ? " +" : ""))
                                .help(measured.count < list.count ? "Не все звенья измерены" : "Сумма звеньев")
                        }
                    }
                    GridRow {
                        Text("Сайты видят вас из").foregroundStyle(.secondary)
                        Text(model.status(chain.nodes.last ?? "").flatMap { Country.detect($0.server)?.name } ?? "—")
                    }
                    if let slow, list.count > 1, let from = list.firstIndex(where: { $0.id == slow.id }) {
                        GridRow {
                            Text("Самое медленное звено").foregroundStyle(.secondary)
                            Text(name(chain.nodes[from]) + " → " + name(slow.to))
                        }
                    }
                    if let r = firstHopRate() {
                        GridRow {
                            Text("Трафик сейчас").foregroundStyle(.secondary)
                            Text(TrafficStyle.text(r)).help(TrafficStyle.detail(r, downIsTx: false))
                        }
                    }
                }
                .font(.callout).monospacedDigit()
                HStack(spacing: 8) {
                    Button("Проверить путь сейчас") {
                        Task {
                            await probes.probeAll()
                            await model.pollNow()
                        }
                    }
                    .disabled(probes.running)
                    if probes.running { ProgressView().controlSize(.small) }
                }
                if let t = probes.probes.values.map(\.time).max() {
                    Text("Проверено \(Fmt.relative(t))").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
    }

    private var connector: some View {
        Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 2, height: 14).padding(.leading, 4)
    }

    private func node(_ id: String, latency: Double?, failed: Bool, sub: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if id == MacLinksModel.pinID {
                Circle().fill(RouteStyle.macTint).frame(width: 10, height: 10)
            } else {
                StatusDot(level: model.status(id)?.level ?? .unknown, size: 10)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(name(id)).font(.callout.weight(.semibold)).lineLimit(1)
                Text(sub).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if failed {
                Text("нет ответа").font(.callout).foregroundStyle(.red)
            } else if let latency {
                Text(Fmt.ms(latency)).font(.callout).monospacedDigit()
            }
        }
    }

    private func endNode(_ title: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(Color.gray).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                Text("конечная точка, куда чаще всего ходит последний сервер").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func name(_ id: String) -> String {
        id == MacLinksModel.pinID ? "Этот Mac" : (model.status(id)?.server.name ?? id)
    }

    private func subtitle(_ id: String, how: String?) -> String {
        var parts: [String] = []
        if id == MacLinksModel.pinID {
            if let a = model.mac.tunnelAddresses.first { parts.append("адрес в VPN \(a)") }
        } else if let s = model.status(id) {
            if let c = Country.detect(s.server) { parts.append(c.name) }
        }
        if let how, !how.isEmpty { parts.append(how) }
        return parts.joined(separator: " · ")
    }

    private func hopList() -> [Hop] {
        let macRoutes = model.mac.routes(model.statuses)
        return chain.hops.enumerated().map { pair -> Hop in
            let i = pair.offset
            let h = pair.element
            if h.from == MacLinksModel.pinID {
                let p = probes.probes[h.to]
                let how = macRoutes.first { $0.toID == h.to && $0.viaID == nil }.map { $0.processes.joined(separator: ", ") }
                return Hop(id: "\(i)", to: h.to, latencyMs: p?.latencyMs, failed: p.map { !$0.ok } ?? false, how: how ?? "")
            }
            let link = model.links.first { $0.from.id == h.from && $0.to.id == h.to }
                ?? model.links.first { $0.from.id == h.to && $0.to.id == h.from }
            var how = ""
            if let r = macRoutes.first(where: { $0.toID == h.to && $0.viaID == h.from }) {
                how = r.processes.joined(separator: ", ") + (r.ports.isEmpty ? "" : ", порт " + r.ports.map(String.init).joined(separator: ", "))
            } else if let r = model.routes.first(where: { $0.fromID == h.from && $0.toID == h.to }) {
                how = RouteStyle.detail(r)
            }
            let ok = link?.check.ok
            return Hop(id: "\(i)", to: h.to, latencyMs: ok == true ? link?.check.latencyMs : nil,
                       failed: ok == false, how: how)
        }
    }

    /// The busiest address outside our servers that the last server talks to.
    private func endpoint() -> String? {
        guard let last = chain.nodes.last else { return nil }
        let found = ExternalHop.compute(model).filter { $0.fromID == last }
        guard let top = found.max(by: { $0.connections < $1.connections }) else { return nil }
        let owner = external.owners[top.ip]
        return ExternalPin.service(of: owner)
            ?? owner?.country.flatMap { code in Country.known.first { $0.code == code }?.name }
            ?? top.ip
    }

    private func firstHopRate() -> RateMeter.Rate? {
        guard let first = chain.hops.first else { return nil }
        if first.from == MacLinksModel.pinID {
            let routes = model.mac.routes(model.statuses)
            let rs = routes.filter { $0.toID == first.to || $0.viaID == first.to }
            let found = rs.compactMap { Traffic.mac($0, model: model) }
            return found.isEmpty ? nil : found.reduce(RateMeter.Rate(rx: 0, tx: 0), +)
        }
        return model.routes.first { $0.fromID == first.from && $0.toID == first.to }
            .flatMap { Traffic.route($0, model: model)?.rate }
    }
}

// MARK: - history

/// The map at a moment of the last 30 days, from what the database keeps:
/// checks between servers, alerts, CPU and site checks. Routes, clients and
/// traffic are only known now.
@MainActor
final class MapHistoryModel: ObservableObject {
    struct Moment {
        /// Server id -> peer id -> the check.
        var links: [String: [String: Store.LinkSample]] = [:]
        var alerts: [String: Severity] = [:]
        var cpu: [String: Double] = [:]
        /// Site id -> server id -> opened.
        var sites: [String: [String: Bool]] = [:]
        /// Servers with any data at that moment.
        var seen: Set<String> = []
    }

    static let span: TimeInterval = 30 * 86400

    /// Nil shows the map as it is now.
    @Published private(set) var time: Date?
    @Published private(set) var moment: Moment?
    @Published private(set) var loading = false
    @Published private(set) var playing = false
    /// Problems and reboots over the 30 days, as marks on the slider.
    @Published private(set) var marks: [HistoryMark] = []
    private var events: [Store.LoggedEvent] = []
    private var eventsLoaded: Date?
    private var task: Task<Void, Never>?
    private var player: Task<Void, Never>?

    func show(_ t: Date?, model: AppModel) {
        time = t
        task?.cancel()
        guard let t else {
            moment = nil
            loading = false
            return
        }
        let servers = model.statuses.map(\.server)
        let sites = model.siteConfigs
        let backend = model.backend
        task = Task {
            try? await Task.sleep(for: .milliseconds(120))
            if Task.isCancelled { return }
            loading = true
            if eventsLoaded.map({ Date().timeIntervalSince($0) > 300 }) ?? true {
                events = (try? await backend.events(limit: 20_000, serverID: nil)) ?? []
                eventsLoaded = Date()
            }
            let from = t.addingTimeInterval(-900)
            var m = Moment()
            for s in servers {
                let links = MapMoment.links((try? await backend.linkSamples(s.id, from: from, to: t)) ?? [], at: t)
                if !links.isEmpty { m.links[s.id] = links; m.seen.insert(s.id) }
                if let smp = MapMoment.sample((try? await backend.samples(s.id, from: from, to: t)) ?? [], at: t) {
                    m.cpu[s.id] = smp.cpu
                    m.seen.insert(s.id)
                }
            }
            for site in sites {
                let checks = MapMoment.site((try? await backend.siteSamples(site.id, from: from, to: t)) ?? [], at: t)
                m.sites[site.id] = checks.mapValues(\.ok)
            }
            m.alerts = MapMoment.alerts(events, at: t)
            if Task.isCancelled { return }
            moment = m
            loading = false
        }
    }

    /// Steps an hour forward several times a second, from the shown moment
    /// (or 30 days ago) up to now.
    func togglePlay(model: AppModel) {
        if playing { stop(); return }
        playing = true
        let start = (time ?? Date().addingTimeInterval(-Self.span))
        player = Task {
            var t = start
            while !Task.isCancelled {
                t = t.addingTimeInterval(3600)
                if t >= Date() { show(nil, model: model); break }
                show(t, model: model)
                try? await Task.sleep(for: .milliseconds(400))
            }
            playing = false
        }
    }

    /// Loads the marks for the slider (the events are kept for 5 minutes).
    func loadMarks(model: AppModel) {
        let backend = model.backend
        Task {
            if eventsLoaded.map({ Date().timeIntervalSince($0) > 300 }) ?? true {
                events = (try? await backend.events(limit: 20_000, serverID: nil)) ?? []
                eventsLoaded = Date()
            }
            let now = Date()
            marks = MapMoment.marks(events, from: now.addingTimeInterval(-Self.span), to: now)
        }
    }

    func stop() {
        player?.cancel()
        player = nil
        playing = false
    }

    /// A server's pin level at the moment shown.
    func level(_ serverID: String) -> ServerStatus.Level {
        guard let m = moment else { return .unknown }
        if let s = m.alerts[serverID] { return s == .critical ? .critical : .warning }
        return m.seen.contains(serverID) ? .ok : .unknown
    }
}

/// The time slider at the bottom of the map.
struct HistoryBar: View {
    @ObservedObject var history: MapHistoryModel
    var model: AppModel

    var body: some View {
        let now = Date()
        let start = now.addingTimeInterval(-MapHistoryModel.span)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Button { history.togglePlay(model: model) } label: {
                    Image(systemName: history.playing ? "pause.fill" : "play.fill").frame(width: 14)
                }
                .help(history.playing ? "Остановить" : "Проиграть по часу")
                VStack(spacing: 1) {
                    Slider(value: Binding(
                        get: { (history.time ?? now).timeIntervalSince1970 },
                        set: { v in
                            history.stop()
                            // Snap to 10 minutes; the right end is "now".
                            let t = (v / 600).rounded() * 600
                            history.show(t >= now.timeIntervalSince1970 - 600 ? nil : Date(timeIntervalSince1970: t), model: model)
                        }), in: start.timeIntervalSince1970...now.timeIntervalSince1970)
                    HistoryMarks(marks: history.marks, start: start, end: now, model: model) { t in
                        history.stop()
                        history.show(t, model: model)
                    }
                }
                if history.loading { ProgressView().controlSize(.small) }
                Text(history.time.map { $0.formatted(.dateTime.day().month(.abbreviated).hour().minute()) } ?? "Сейчас")
                    .font(.callout.weight(.semibold)).monospacedDigit()
                    .frame(minWidth: 120, alignment: .trailing)
                Button("Сейчас") {
                    history.stop()
                    history.show(nil, model: model)
                }
                .disabled(history.time == nil)
            }
            if !history.marks.isEmpty {
                HStack(spacing: 12) {
                    markLegend(.red, "падение")
                    markLegend(.orange, "предупреждение")
                    markLegend(.secondary, "перезагрузка")
                    Text("нажмите на метку, чтобы перейти к моменту").foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            if history.time != nil {
                Text("Показано, как было: связи, задержки, проблемы, процессор и сайты. Маршруты, клиенты и трафик приложение видит только сейчас.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
    }

    private func markLegend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 3, height: 9)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

/// Ticks under the history slider: where problems began and servers
/// rebooted. A tick jumps the map to that moment.
@MainActor
struct HistoryMarks: View {
    var marks: [HistoryMark]
    var start: Date
    var end: Date
    var model: AppModel
    var jump: (Date) -> Void

    var body: some View {
        GeometryReader { geo in
            // The slider's track is inset by about half its knob.
            let inset: CGFloat = 8
            let width = max(1, geo.size.width - inset * 2)
            let span = max(1, end.timeIntervalSince(start))
            ForEach(Array(marks.enumerated()), id: \.offset) { _, m in
                let x = inset + width * CGFloat(m.time.timeIntervalSince(start) / span)
                RoundedRectangle(cornerRadius: 1)
                    .fill(color(m.kind))
                    .frame(width: 3, height: 9)
                    .frame(width: 9, height: 12)
                    .contentShape(Rectangle())
                    .position(x: x, y: 6)
                    .onTapGesture { jump(m.time) }
                    .help(help(m))
            }
        }
        .frame(height: 12)
    }

    private func color(_ k: HistoryMark.Kind) -> Color {
        switch k {
        case .down: return .red
        case .warning: return .orange
        case .reboot: return .secondary
        }
    }

    private func help(_ m: HistoryMark) -> String {
        let name = model.status(m.serverID)?.server.name ?? m.serverID
        return m.time.formatted(date: .abbreviated, time: .shortened) + " · " + name + "\n" + m.message
    }
}
#endif

#if canImport(SwiftUI) && canImport(AppKit)
/// Selection ids on the map for things that are not pins.
enum PathKey {
    static let prefix = "path:"
    static func id(_ c: NetworkChain) -> String { prefix + c.id }
}

enum SiteKey {
    static let prefix = "site:"
    static func id(_ siteID: String) -> String { prefix + siteID }
}
#endif

#if canImport(SwiftUI) && canImport(AppKit)
/// The arrow in the middle of a route: tap for the whole path; the traffic
/// on the route under it.
struct RouteArrow: View {
    var color: Color
    var angle: Angle
    var size: CGFloat
    var help: String
    var label: String?
    var labelHelp: String
    var action: () -> Void

    var body: some View {
        ZStack {
            Button(action: action) {
                Image(systemName: "arrowtriangle.right.fill")
                    .font(.system(size: size))
                    .foregroundStyle(color)
                    .rotationEffect(angle)
                    .frame(width: size + 8, height: size + 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
            if let label {
                TrafficLabel(text: label, tint: color, help: labelHelp)
                    .fixedSize()
                    .offset(y: size + 4)
            }
        }
    }
}

/// Labels of the checks from this Mac.
enum MacCheck {
    /// A third of the way from the Mac, clear of the latency labels between servers.
    static func labelPoint(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        .init(latitude: a.latitude + (b.latitude - a.latitude) / 3, longitude: a.longitude + (b.longitude - a.longitude) / 3)
    }

    static func label(_ p: MacProbeModel.Probe) -> String {
        guard let ms = p.latencyMs else { return "нет ответа" }
        return Fmt.ms(ms) + (p.throughVPN ? " · VPN" : "")
    }

    static func help(_ p: MacProbeModel.Probe, _ name: String) -> String {
        let how = p.throughVPN
            ? "через VPN (\(p.interface ?? "")), так что это не проверка из вашей страны"
            : "напрямую" + (p.interface.map { " (\($0))" } ?? "")
        return "Этот Mac → \(name): " + (p.ok ? "отвечает" : "не отвечает") + ", " + how
    }
}

/// One line between two servers at a past moment, both directions together.
struct PastLink: Identifiable {
    var fromID: String
    var toID: String
    var ok: Bool
    var label: String
    var id: String { fromID + "|" + toID }

    static func build(_ m: MapHistoryModel.Moment, _ statuses: [ServerStatus]) -> [PastLink] {
        let known = Set(statuses.map(\.id))
        var pairs: [String: [Store.LinkSample]] = [:]
        var ends: [String: (String, String)] = [:]
        for (from, peers) in m.links {
            for (peer, sample) in peers where known.contains(peer) && peer != from {
                let (a, b) = from < peer ? (from, peer) : (peer, from)
                pairs[a + "|" + b, default: []].append(sample)
                ends[a + "|" + b] = (a, b)
            }
        }
        return pairs.compactMap { (key, samples) -> PastLink? in
            guard let end = ends[key] else { return nil }
            let a = end.0, b = end.1
            let ok = samples.allSatisfy(\.ok)
            let ms = samples.filter(\.ok).compactMap(\.latencyMs)
            let label: String
            if !ok {
                label = ms.isEmpty ? "нет связи" : "частично"
            } else {
                label = ms.isEmpty ? "—" : Fmt.ms(ms.reduce(0, +) / Double(ms.count))
            }
            return PastLink(fromID: a, toID: b, ok: ok, label: label)
        }
        .sorted { $0.id < $1.id }
    }
}
#endif
