#if canImport(SwiftUI) && canImport(AppKit)
import CoreLocation
import Foundation
import MonitorCore
import SwiftUI

/// A hop of a chain that leads outside the app: one of our servers (or this
/// Mac's proxy) keeps connections to an address that is none of our servers.
struct ExternalHop: Hashable, Identifiable {
    var id: String { fromID + "->" + ip }
    /// A server id, or `MacLinksModel.pinID`.
    var fromID: String
    var ip: String
    var ports: [Int]
    var connections: Int
    /// Containers on a server, or the program on the Mac.
    var via: [String]

    /// Ports that are housekeeping, not a chain: DNS, NTP.
    static let ignoredPorts: Set<Int> = [53, 123]

    /// Built from servers' own sockets (`links`) and from the Mac programs
    /// that already carry traffic to our servers. Forwarded client traffic
    /// is left out on purpose: it is the whole internet.
    @MainActor static func compute(_ model: AppModel) -> [ExternalHop] {
        let servers = model.statuses.map(\.server)
        let ours = Set(servers.map(\.host))
        var out: [ExternalHop] = []
        for s in model.statuses {
            for l in s.snapshot?.links ?? [] where !ours.contains(l.remoteIp) {
                let ports = l.ports.filter { !ignoredPorts.contains($0) && $0 != 22 }
                guard !ports.isEmpty else { continue }
                out.append(.init(fromID: s.id, ip: l.remoteIp, ports: ports, connections: l.connections, via: l.via))
            }
        }
        for l in model.mac.unknown(model.statuses) {
            let ports = l.ports.filter { !ignoredPorts.contains($0) }
            guard !ports.isEmpty else { continue }
            out.append(.init(fromID: MacLinksModel.pinID, ip: l.remoteIP, ports: ports,
                             connections: l.connections, via: [l.process]))
        }
        return Array(out.sorted { $0.connections > $1.connections }.prefix(30))
    }
}

/// Unknown addresses grouped by country, one grey pin each.
struct ExternalPin: Identifiable {
    var country: Country
    var coordinate: CLLocationCoordinate2D
    var hops: [ExternalHop]
    var id: String { ExternalPin.prefix + country.code }

    static let prefix = "ext-"

    @MainActor static func group(_ hops: [ExternalHop], owners: [String: IPOwner],
                                 avoiding pins: [CLLocationCoordinate2D]) -> [ExternalPin] {
        var byCountry: [String: ExternalPin] = [:]
        for h in hops {
            guard let code = owners[h.ip]?.country,
                  let c = Country.known.first(where: { $0.code == code }) else { continue }
            let base = c.coordinate
            let busy = pins.contains { abs($0.latitude - base.latitude) < 1 && abs($0.longitude - base.longitude) < 1 }
            let at = busy ? CLLocationCoordinate2D(latitude: base.latitude + 2.5, longitude: base.longitude) : base
            byCountry[code, default: ExternalPin(country: c, coordinate: at, hops: [])].hops.append(h)
        }
        return byCountry.values.sorted { $0.id < $1.id }
    }
}

/// Owners of unknown addresses, looked up over RDAP as they appear.
@MainActor
final class ExternalOwners: ObservableObject {
    @Published private(set) var owners: [String: IPOwner] = [:]
    private let lookup: IPLookup

    init(lookup: IPLookup) { self.lookup = lookup }

    func resolve(_ ips: [String]) async {
        for ip in ips where owners[ip] == nil {
            if Task.isCancelled { return }
            if let o = await lookup.owner(of: ip) { owners[ip] = o }
        }
    }
}

/// The panel for a grey pin: which unknown addresses are there and who
/// reaches them.
struct ExternalInspector: View {
    @ObservedObject var model: AppModel
    var pin: ExternalPin
    var owners: [String: IPOwner]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Чужие узлы · \(pin.country.name)", systemImage: "questionmark.circle").font(.headline)
                    Text("Сюда ведут цепочки, но этих адресов нет среди ваших серверов. Если это ваш сервер, добавьте его, и он встанет на карту как обычный.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(pin.hops) { h in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(h.ip).monospacedDigit().lineLimit(1)
                            Spacer(minLength: 6)
                            if let n = owners[h.ip]?.network {
                                Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Text(ExternalPin.describeFrom(h, model) + " · порт " + h.ports.map(String.init).joined(separator: ", ")
                             + " · соединений: \(h.connections)")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                }
            }
            .padding(16)
        }
    }
}

extension ExternalPin {
    @MainActor static func describeFrom(_ h: ExternalHop, _ model: AppModel) -> String {
        let from = h.fromID == MacLinksModel.pinID ? "Этот Mac" : (model.status(h.fromID)?.server.name ?? h.fromID)
        return "от: \(from)" + (h.via.isEmpty ? "" : " (\(h.via.joined(separator: ", ")))")
    }
}
#endif
