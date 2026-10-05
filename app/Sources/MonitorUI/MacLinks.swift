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
    @Published public private(set) var updated: Date?

    public static let pinID = "this-mac"

    /// Refreshes until the calling task is cancelled (the map closes).
    func run() async {
        while !Task.isCancelled {
            let found = await Task.detached(priority: .utility) { MacLinksModel.read() }.value
            links = found
            updated = Date()
            try? await Task.sleep(for: .seconds(10))
        }
    }

    public func routes(_ servers: [ServerConfig]) -> [MacRoute] { LocalLinks.routes(links, servers: servers) }
    /// Other addresses reached by the programs that also carry traffic to
    /// our servers (gost, AmneziaVPN): likely chain hops not added yet.
    /// Browsers talking to websites directly are left out.
    public func unknown(_ servers: [ServerConfig]) -> [MacLink] {
        let carriers = Set(routes(servers).flatMap(\.processes))
        return LocalLinks.unknown(links, servers: servers).filter { carriers.contains($0.process) }
    }

    nonisolated private static func read() -> [MacLink] {
        let me = ProcessInfo.processInfo.processIdentifier
        return ["inet", "inet6"].flatMap { family in
            LocalLinks.parse(netstat(family), ownPID: me, name: processName)
        }
        .map { var l = $0; l.process = pretty(l.process); return l }
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

    /// Default place: the country of the Mac's region settings, nudged off a
    /// server pin in the same city. The user can move it like any pin.
    func defaultCoordinate(avoiding pins: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {
        let code = Locale.current.region?.identifier ?? "RU"
        let base = (Country.known.first { $0.code == code } ?? Country.known[0]).coordinate
        let busy = pins.contains { abs($0.latitude - base.latitude) < 1 && abs($0.longitude - base.longitude) < 1 }
        return busy ? .init(latitude: base.latitude - 2.5, longitude: base.longitude) : base
    }
}

/// The panel next to the map for the "this Mac" pin: which of our servers
/// it goes through, and which other addresses it talks to.
struct MacInspector: View {
    @ObservedObject var model: AppModel
    @ObservedObject var mac: MacLinksModel
    var center: CLLocationCoordinate2D?

    var body: some View {
        let servers = model.statuses.map(\.server)
        let routes = mac.routes(servers)
        let other = Array(mac.unknown(servers).prefix(12))
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
                                Text(model.status(r.toID)?.server.name ?? r.toID).lineLimit(1)
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
