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

/// Addresses outside the app, one pin per country, or per well-known
/// service: Google, Cloudflare and the like are where traffic ends, not
/// servers of a chain, so they get one named pin instead of a list of IPs.
struct ExternalPin: Identifiable {
    var country: Country
    var coordinate: CLLocationCoordinate2D
    var hops: [ExternalHop]
    /// The service's name when the addresses belong to one, e.g. "Google".
    var service: String?
    var id: String { ExternalPin.prefix + (service ?? country.code) }

    static let prefix = "ext-"

    /// Where lines start: each server (or the Mac) once.
    var sources: [String] { Array(Set(hops.map(\.fromID))).sorted() }
    var title: String { service ?? country.name }

    /// Registry network names of big services (RDAP "name"), by prefix.
    static let services: [(String, String)] = [
        ("GOOGLE", "Google"), ("CLOUDFLARE", "Cloudflare"), ("AMAZON", "Amazon"), ("AWS", "Amazon"),
        ("MICROSOFT", "Microsoft"), ("MSFT", "Microsoft"), ("AKAMAI", "Akamai"), ("FACEBOOK", "Meta"),
        ("META", "Meta"), ("APPLE", "Apple"), ("TELEGRAM", "Telegram"), ("GITHUB", "GitHub"),
        ("FASTLY", "Fastly"), ("OPENAI", "OpenAI"), ("ANTHROPIC", "Anthropic"), ("YANDEX", "Яндекс"),
        ("VK-", "VK"), ("NETFLIX", "Netflix"), ("TWITTER", "X"), ("DIGITALOCEAN-CDN", "DigitalOcean"),
    ]

    static func service(of owner: IPOwner?) -> String? {
        guard let n = owner?.network?.uppercased() else { return nil }
        return services.first { n.hasPrefix($0.0) }?.1
    }

    @MainActor static func group(_ hops: [ExternalHop], owners: [String: IPOwner],
                                 avoiding pins: [CLLocationCoordinate2D]) -> [ExternalPin] {
        var byKey: [String: ExternalPin] = [:]
        for h in hops {
            guard let code = owners[h.ip]?.country,
                  let c = Country.known.first(where: { $0.code == code }) else { continue }
            let svc = service(of: owners[h.ip])
            let base = c.coordinate
            let busy = pins.contains { abs($0.latitude - base.latitude) < 1 && abs($0.longitude - base.longitude) < 1 }
            // Unknown nodes go north of a busy city, services north-west.
            var at = busy ? CLLocationCoordinate2D(latitude: base.latitude + 2.5, longitude: base.longitude) : base
            if svc != nil { at.longitude -= 4 }
            let key = svc ?? code
            byKey[key, default: ExternalPin(country: c, coordinate: at, hops: [], service: svc)].hops.append(h)
        }
        return byKey.values.sorted { $0.id < $1.id }
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
                if let service = pin.service {
                    serviceBody(service)
                } else {
                    unknownBody
                }
            }
            .padding(16)
        }
    }

    /// A known service: where the traffic ends. One line per source with
    /// how many of its addresses are used; the IPs themselves don't matter.
    private func serviceBody(_ service: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Label("\(service) · конечная точка", systemImage: "globe").font(.headline)
                Text("Это не сервер цепочки, а сам сервис \(service), куда в итоге уходит трафик. Ничего делать не нужно.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(pin.sources, id: \.self) { from in
                let hs = pin.hops.filter { $0.fromID == from }
                let ports = Array(Set(hs.flatMap(\.ports))).sorted().map(String.init).joined(separator: ", ")
                VStack(alignment: .leading, spacing: 2) {
                    Text(ExternalPin.describeFrom(hs[0], model)).lineLimit(1)
                    Text("адресов: \(hs.count) · порт \(ports) · соединений: \(hs.map(\.connections).reduce(0, +))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }

    private var unknownBody: some View {
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
    }
}

extension ExternalPin {
    @MainActor static func describeFrom(_ h: ExternalHop, _ model: AppModel) -> String {
        let from = h.fromID == MacLinksModel.pinID ? "Этот Mac" : (model.status(h.fromID)?.server.name ?? h.fromID)
        return "от: \(from)" + (h.via.isEmpty ? "" : " (\(h.via.joined(separator: ", ")))")
    }
}
#endif
