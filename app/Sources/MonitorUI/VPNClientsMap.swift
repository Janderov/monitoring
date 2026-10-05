#if canImport(SwiftUI) && canImport(AppKit)
import CoreLocation
import Foundation
import MonitorCore
import SwiftUI

/// A VPN key that has connected from somewhere: the agent reports the
/// address each AmneziaWG/WireGuard peer last came from.
struct VPNClientSpot: Hashable, Identifiable {
    var id: String { serverID + "/" + publicKey }
    var serverID: String
    var container: String
    var name: String?
    var publicKey: String
    var ip: String
    var active: Bool
    var lastSeen: Date?

    var title: String { name ?? "ключ \(publicKey.prefix(6))…" }

    /// Peers with an endpoint, except cascades (0.0.0.0/0 to another server)
    /// and this Mac's own tunnel, which the map already draws.
    @MainActor static func compute(_ model: AppModel) -> [VPNClientSpot] {
        let ours = Set(model.statuses.map(\.server.host))
        let mine = Set(model.mac.tunnelAddresses.map { $0 + "/32" })
        var out: [VPNClientSpot] = []
        for s in model.statuses {
            for vpn in s.snapshot?.vpn ?? [] {
                for p in vpn.peers ?? [] {
                    let allowed = (p.allowedIps ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    guard !allowed.contains("0.0.0.0/0"), !allowed.contains(where: mine.contains),
                          let ep = p.endpoint, let ip = host(of: ep), !ours.contains(ip) else { continue }
                    out.append(.init(serverID: s.id, container: vpn.container, name: p.name, publicKey: p.publicKey,
                                     ip: ip, active: p.active, lastSeen: p.latestHandshake))
                }
            }
        }
        return out
    }

    /// "1.2.3.4:5000" or "[2001:db8::1]:5000" -> the address.
    static func host(of endpoint: String) -> String? {
        if endpoint.hasPrefix("["), let close = endpoint.firstIndex(of: "]") {
            return String(endpoint[endpoint.index(after: endpoint.startIndex)..<close])
        }
        guard let i = endpoint.lastIndex(of: ":") else { return nil }
        return String(endpoint[..<i])
    }
}

/// VPN clients of one country: one pin with a count, a line to each server
/// they use.
struct ClientPin: Identifiable {
    var country: Country
    var coordinate: CLLocationCoordinate2D
    var clients: [VPNClientSpot]
    var id: String { ClientPin.prefix + country.code }

    static let prefix = "clients-"

    var activeCount: Int { clients.filter(\.active).count }
    var serverIDs: [String] { Array(Set(clients.map(\.serverID))).sorted() }
    func active(to serverID: String) -> Bool { clients.contains { $0.serverID == serverID && $0.active } }

    /// Grouped by the country of each client's address; nudged off server
    /// pins in the same city (to the south-east, unknown nodes go north).
    static func group(_ spots: [VPNClientSpot], owners: [String: IPOwner],
                      avoiding pins: [CLLocationCoordinate2D]) -> [ClientPin] {
        var byCountry: [String: ClientPin] = [:]
        for c in spots {
            guard let code = owners[c.ip]?.country,
                  let country = Country.known.first(where: { $0.code == code }) else { continue }
            let base = country.coordinate
            let busy = pins.contains { abs($0.latitude - base.latitude) < 1 && abs($0.longitude - base.longitude) < 1 }
            let at = busy ? CLLocationCoordinate2D(latitude: base.latitude - 1.5, longitude: base.longitude + 3) : base
            byCountry[code, default: ClientPin(country: country, coordinate: at, clients: [])].clients.append(c)
        }
        return byCountry.values.sorted { $0.id < $1.id }
    }
}

/// The small pin: a person icon with the number of clients.
struct ClientPinView: View {
    var pin: ClientPin

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "person.fill").font(.system(size: 9, weight: .semibold))
            Text("\(pin.clients.count)").font(.caption2.weight(.bold)).monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(pin.activeCount > 0 ? RouteStyle.clientTint : Color.gray, in: Capsule())
        .overlay(Capsule().strokeBorder(.white, lineWidth: 1.5))
        .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
        .help("\(pin.country.name): клиентов \(pin.clients.count), сейчас в сети \(pin.activeCount)")
    }
}

/// The panel for a clients pin.
struct ClientsInspector: View {
    @ObservedObject var model: AppModel
    var pin: ClientPin
    var owners: [String: IPOwner]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Клиенты VPN · \(pin.country.name)", systemImage: "person.2").font(.headline)
                    Text("Сейчас в сети \(pin.activeCount) из \(pin.clients.count). Страна определена по адресу, с которого ключ подключался последний раз.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(pin.clients.sorted { ($0.active ? 0 : 1, $0.title) < ($1.active ? 0 : 1, $1.title) }) { c in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        StatusDot(level: c.active ? .ok : .unknown)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.title).lineLimit(1)
                            Text(detail(c)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .font(.callout)
                }
            }
            .padding(16)
        }
    }

    private func detail(_ c: VPNClientSpot) -> String {
        var parts = [model.status(c.serverID)?.server.name ?? c.serverID]
        if let net = owners[c.ip]?.network { parts.append(net) }
        if c.active { parts.append("в сети") } else if let d = c.lastSeen { parts.append("был \(Fmt.relative(d))") }
        return parts.joined(separator: " · ")
    }
}
#endif
