#if canImport(SwiftUI) && canImport(AppKit)
import CoreLocation
import Darwin
import Foundation
import MonitorCore
import SwiftUI

/// Where this Mac sends traffic right now, read from `netstat` every few
/// seconds while the map is open. Nothing to configure: a local proxy such
/// as gost or the AmneziaVPN app shows up by itself.
@MainActor
public final class MacLinksModel: ObservableObject {
    @Published public private(set) var links: [MacLink] = []
    /// IPv4 addresses of this Mac's VPN interfaces (utun*).
    @Published public private(set) var tunnelAddresses: [String] = []
    /// Command line and config file of each local proxy, by program name.
    /// Kept in memory only and searched just for our servers' addresses.
    private var proxySettings: [String: String] = [:]
    @Published public private(set) var updated: Date?
    /// Bytes per second of each connection, between two readings.
    @Published public private(set) var rates = RateMeter()

    public static let pinID = "this-mac"

    /// Refreshes until the calling task is cancelled (the map closes).
    func run() async {
        while !Task.isCancelled {
            let (found, tunnels, settings) = await Task.detached(priority: .utility) {
                let (links, proxies) = MacLinksModel.read()
                return (links, MacLinksModel.tunnelAddresses(), MacLinksModel.settings(of: proxies))
            }.value
            let now = Date()
            var meter = rates
            var keys = Set<String>()
            for l in found {
                for (k, c) in RateMeter.connectionKeys(l) {
                    meter.add(k, c, at: now)
                    keys.insert(k)
                }
            }
            meter.keep(keys)
            rates = meter
            links = found
            tunnelAddresses = tunnels
            proxySettings = settings
            updated = Date()
            try? await Task.sleep(for: .seconds(10))
        }
    }

    public func routes(_ statuses: [ServerStatus]) -> [MacRoute] {
        let servers = statuses.map(\.server)
        let through = LocalLinks.tunnelServers(localAddresses: tunnelAddresses, statuses: statuses)
        let live = LocalLinks.merge(LocalLinks.routes(links, servers: servers, through: through),
                                    LocalLinks.tunnelRoutes(localAddresses: tunnelAddresses, statuses: statuses))
        let idle = LocalLinks.configuredRoutes(proxySettings, servers: servers)
            .filter { r in !live.contains { $0.toID == r.toID } }
        return LocalLinks.merge(live, idle)
    }
    /// Other addresses reached by the programs that also carry traffic to
    /// our servers (gost, AmneziaVPN): likely chain hops not added yet.
    /// Browsers talking to websites directly are left out.
    public func unknown(_ statuses: [ServerStatus]) -> [MacLink] {
        let servers = statuses.map(\.server)
        let carriers = Set(LocalLinks.routes(links, servers: servers).flatMap(\.processes))
        return LocalLinks.unknown(links, servers: servers).filter { carriers.contains($0.process) }
    }

    nonisolated private static func read() -> ([MacLink], [LocalProxy]) {
        let me = ProcessInfo.processInfo.processIdentifier
        var links: [MacLink] = []
        var proxies: [LocalProxy] = []
        for family in ["inet", "inet6"] {
            let out = netstat(family)
            links += LocalLinks.parse(out, ownPID: me, name: processName)
            proxies += LocalLinks.localProxies(out, ownPID: me)
        }
        links = links.map { var l = $0; l.process = pretty(l.process); return l }
        return (links, proxies)
    }

    /// Arguments of each proxy plus the config file it names (-C/--config).
    /// Processes of other users are not readable and are skipped.
    nonisolated private static func settings(of proxies: [LocalProxy]) -> [String: String] {
        var out: [String: String] = [:]
        for p in proxies {
            guard let args = arguments(p.pid) else { continue }
            var text = args.joined(separator: " ")
            for (i, a) in args.enumerated() where (a == "-C" || a == "--config" || a == "-c") && i + 1 < args.count {
                let path = (args[i + 1] as NSString).expandingTildeInPath
                if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                   (attrs[.size] as? Int ?? 0) < 1_000_000,
                   let file = try? String(contentsOfFile: path, encoding: .utf8) {
                    text += "\n" + file
                }
            }
            out[pretty(p.process), default: ""] += text
        }
        return out
    }

    nonisolated private static func arguments(_ pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        // After argc: the executable path, padding NULs, then argv strings.
        let parts = buf[4..<size].split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        return Array(parts.dropFirst().prefix(Int(argc)))
    }

    nonisolated private static func tunnelAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var out: [String] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard String(cString: ifa.ifa_name).hasPrefix("utun"), let sa = ifa.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: host))
            }
        }
        return out
    }

    nonisolated private static func netstat(_ family: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        p.arguments = ["-anv", "-f", family]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated private static func processName(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    /// Readable names for the usual suspects.
    nonisolated private static func pretty(_ name: String) -> String {
        let l = name.lowercased()
        if l.contains("amnezia") { return "AmneziaVPN" }
        if l.hasPrefix("gost") { return "gost" }
        if l.contains("xray") || l.contains("v2ray") { return "xray" }
        return name
    }

    /// Default place: the country of the Mac's time zone (region settings
    /// are often left on another country), nudged off a server pin in the
    /// same city. The user can move it like any pin.
    func defaultCoordinate(avoiding pins: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {
        let code = Self.country(ofTimeZone: TimeZone.current.identifier) ?? Locale.current.region?.identifier ?? "RU"
        let base = (Country.known.first { $0.code == code } ?? Country.known[0]).coordinate
        let busy = pins.contains { abs($0.latitude - base.latitude) < 1 && abs($0.longitude - base.longitude) < 1 }
        return busy ? .init(latitude: base.latitude - 2.5, longitude: base.longitude) : base
    }

    nonisolated static func country(ofTimeZone id: String) -> String? {
        let city = id.split(separator: "/").last.map(String.init) ?? id
        if russianZones.contains(city) { return "RU" }
        let byCity = ["Amsterdam": "NL", "Berlin": "DE", "Helsinki": "FI", "London": "GB", "Paris": "FR",
                      "Warsaw": "PL", "Stockholm": "SE", "Istanbul": "TR", "Almaty": "KZ", "Dubai": "AE",
                      "Singapore": "SG", "Tokyo": "JP", "New_York": "US", "Chicago": "US", "Denver": "US",
                      "Los_Angeles": "US", "Tbilisi": "GE", "Yerevan": "AM", "Riga": "LV", "Vilnius": "LT",
                      "Tallinn": "EE", "Kyiv": "UA", "Kiev": "UA", "Belgrade": "RS", "Prague": "CZ"]
        return byCity[city]
    }

    private nonisolated static let russianZones: Set<String> = [
        "Moscow", "Kaliningrad", "Samara", "Volgograd", "Saratov", "Ulyanovsk", "Astrakhan", "Kirov",
        "Yekaterinburg", "Omsk", "Novosibirsk", "Barnaul", "Tomsk", "Novokuznetsk", "Krasnoyarsk",
        "Irkutsk", "Chita", "Yakutsk", "Khandyga", "Vladivostok", "Ust-Nera", "Magadan", "Sakhalin",
        "Srednekolymsk", "Kamchatka", "Anadyr", "Simferopol",
    ]
}

/// The panel next to the map for the "this Mac" pin: which of our servers
/// it goes through, and which other addresses it talks to.
struct MacInspector: View {
    @ObservedObject var model: AppModel
    @ObservedObject var mac: MacLinksModel
    var center: CLLocationCoordinate2D?

    var body: some View {
        let routes = mac.routes(model.statuses)
        let other = Array(mac.unknown(model.statuses).prefix(12))
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Этот Mac", systemImage: "laptopcomputer").font(.headline)
                    if let d = mac.updated {
                        Text("Соединения обновлены \(Fmt.relative(d))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Через ваши серверы").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if routes.isEmpty {
                        Text("Сейчас Mac не ходит в интернет через ваши серверы.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(routes) { r in
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: "arrow.up.right").foregroundStyle(RouteStyle.macTint)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(RouteStyle.path(r, model)).lineLimit(2)
                                Text(RouteStyle.detail(r)).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .font(.callout)
                    }
                }
                if !other.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Другие адреса").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text("Сюда же ходят те же программы, но этих адресов нет среди ваших серверов. Если это ваш сервер, добавьте его, и стрелка появится сама.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        ForEach(other, id: \.self) { l in
                            HStack {
                                Text(l.remoteIP).monospacedDigit().lineLimit(1)
                                Spacer(minLength: 6)
                                Text(l.process).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .font(.callout)
                            .help("порт " + l.ports.map(String.init).joined(separator: ", ") + " · соединений: \(l.connections)")
                        }
                    }
                }
                if let center {
                    Button("Переместить в центр карты") { model.locations.set(center, for: MacLinksModel.pinID) }
                        .buttonStyle(.link).font(.caption)
                }
            }
            .padding(16)
        }
    }
}
#endif
