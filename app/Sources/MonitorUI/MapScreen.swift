#if canImport(SwiftUI) && canImport(AppKit)
import MapKit
import MonitorCore
import SwiftUI

/// Servers on a world map, with the pings agents make to each other. The
/// point is to tell "the server is down" (nobody reaches it) from "it is
/// blocked in one country" (only that country fails).
struct MapScreen: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var locations: ServerLocations
    @ObservedObject private var mac: MacLinksModel
    @ObservedObject private var external: ExternalOwners
    @State private var position: MapCameraPosition = .automatic
    @State private var center: CLLocationCoordinate2D?
    @State private var selectedPin: String?
    @AppStorage("map.links") private var showLinks = true
    @AppStorage("map.routes") private var showRoutes = true
    @AppStorage("map.onlyProblems") private var onlyProblems = false
    @AppStorage("map.mac") private var showMac = true
    @AppStorage("map.external") private var showExternal = true
    @AppStorage("map.clients") private var showClients = true

    init(model: AppModel) {
        self.model = model
        self.locations = model.locations
        self.mac = model.mac
        self.external = model.external
    }

    /// Servers sharing a place become one pin with a number.
    private struct Pin: Identifiable {
        var id: String
        var coordinate: CLLocationCoordinate2D
        var statuses: [ServerStatus]
        var level: ServerStatus.Level { statuses.map(\.level).max() ?? .unknown }
        var title: String { statuses.map(\.server.name).joined(separator: ", ") }
    }

    private var pins: [Pin] {
        var byPlace: [String: Pin] = [:]
        for s in model.visible {
            if onlyProblems && s.alerts.isEmpty { continue }
            guard let c = locations.coordinate(for: s.server) else { continue }
            let key = String(format: "%.2f,%.2f", c.latitude, c.longitude)
            byPlace[key, default: Pin(id: key, coordinate: c, statuses: [])].statuses.append(s)
        }
        return byPlace.values.sorted { $0.id < $1.id }
    }

    private var unplaced: [ServerStatus] {
        model.visible.filter { locations.coordinate(for: $0.server) == nil }
    }

    private func macCoordinate(_ pins: [Pin]) -> CLLocationCoordinate2D {
        locations.manual(MacLinksModel.pinID) ?? mac.defaultCoordinate(avoiding: pins.map(\.coordinate))
    }

    var body: some View {
        let pins = pins
        let routes = showRoutes ? model.routes : []
        let macAt = macCoordinate(pins)
        let macRoutes = showMac ? mac.routes(model.statuses) : []
        let hops = showExternal ? ExternalHop.compute(model).filter { showMac || $0.fromID != MacLinksModel.pinID } : []
        let extPins = ExternalPin.group(hops, owners: external.owners, avoiding: pins.map(\.coordinate))
        let spots = showClients ? VPNClientSpot.compute(model) : []
        let clientPins = ClientPin.group(spots, owners: external.owners, avoiding: pins.map(\.coordinate))
        HStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Map(position: $position, selection: $selectedPin) {
                    linkLayer()
                    routeLayer(routes)
                    macRouteLayer(macRoutes, from: macAt)
                    clientLayer(clientPins)
                    externalLayer(extPins, mac: macAt)
                    macPin(macAt)
                    serverPins(pins)
                }
                .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
                .mapControls {
                    MapZoomStepper()
                    MapCompass()
                    MapScaleView()
                }
                .onMapCameraChange { ctx in center = ctx.region.center }

                layers
                    .padding(12)
            }
            inspector(pins: pins, clientPins: clientPins, extPins: extPins)
        }
        .navigationTitle("Карта")
        .navigationSubtitle("\(model.visible.count) серверов" + (routes.isEmpty ? "" : " · маршрутов VPN: \(routes.count)"))
        .toolbar {
            ToolbarItem {
                Picker("Показать", selection: $onlyProblems) {
                    Text("Все").tag(false)
                    Text("Только проблемы").tag(true)
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                Button { withAnimation { position = .automatic } } label: {
                    Label("Показать все серверы", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .help("Показать все серверы")
            }
        }
        .task(id: showMac) {
            if showMac { await mac.run() }
        }
        .onChange(of: spots.map(\.ip), initial: true) { _, ips in external.request(ips, first: true) }
        .onChange(of: hops.map(\.ip), initial: true) { _, ips in external.request(ips) }
        .onAppear {
            locations.resetMovedOnce(model.visible.map(\.server))
            // Opening the map from a server's menu selects its pin.
            if let id = model.selectedServerID, let pin = pins.first(where: { $0.statuses.contains { $0.id == id } }) {
                selectedPin = pin.id
            }
        }
    }

    @ViewBuilder
    private func inspector(pins: [Pin], clientPins: [ClientPin], extPins: [ExternalPin]) -> some View {
        if let id = selectedPin, let pin = clientPins.first(where: { $0.id == id }) {
            Divider()
            ClientsInspector(model: model, pin: pin, owners: external.owners)
                .frame(width: 300)
        } else if let id = selectedPin, let pin = extPins.first(where: { $0.id == id }) {
            Divider()
            ExternalInspector(model: model, pin: pin, owners: external.owners)
                .frame(width: 300)
        } else if selectedPin == MacLinksModel.pinID, showMac {
            Divider()
            MacInspector(model: model, mac: mac, center: center)
                .frame(width: 300)
        } else if let id = selectedPin, let pin = pins.first(where: { $0.id == id }) {
            Divider()
            MapInspector(model: model, statuses: pin.statuses, center: center)
                .frame(width: 300)
        } else if !unplaced.isEmpty {
            Divider()
            UnplacedList(model: model, statuses: unplaced, center: center)
                .frame(width: 260)
        }
    }

    @MapContentBuilder
    private func linkLayer() -> some MapContent {
        if showLinks {
            ForEach(model.links) { link in
                if let a = locations.coordinate(for: link.from), let b = locations.coordinate(for: link.to) {
                    MapPolyline(coordinates: [a, b], contourStyle: .geodesic)
                        .stroke(link.check.ok ? Color.secondary.opacity(0.6) : Color.red,
                                style: StrokeStyle(lineWidth: 1.5, dash: link.check.ok ? [] : [5, 4]))
                }
            }
            // One label per pair of servers, on the arc's middle.
            ForEach(LinkPair.group(model.links)) { pair in
                if let a = locations.coordinate(for: pair.a), let b = locations.coordinate(for: pair.b) {
                    Annotation("", coordinate: LinkPair.greatCircleMidpoint(a, b), anchor: .center) {
                        Text(pair.label)
                            .font(.caption2.weight(.medium)).monospacedDigit()
                            .foregroundStyle(pair.ok ? Color.primary : Color.red)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.regularMaterial, in: Capsule())
                            .help(pair.detail)
                    }
                }
            }
        }
    }

    @MapContentBuilder
    private func routeLayer(_ routes: [VPNRoute]) -> some MapContent {
        ForEach(routes) { r in
            if let a = coordinate(r.fromID), let b = coordinate(r.toID), !same(a, b) {
                // Straight on the map, so the arrow in the middle points along it.
                MapPolyline(coordinates: [a, b], contourStyle: .straight)
                    .stroke(RouteStyle.color(r),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: r.kind == .relay ? [7, 5] : []))
                Annotation("", coordinate: RouteStyle.midpoint(a, b), anchor: .center) {
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(RouteStyle.color(r))
                        .rotationEffect(RouteStyle.angle(a, b))
                        .help(RouteStyle.describe(r, model))
                }
            }
        }
    }

    @MapContentBuilder
    private func macRouteLayer(_ macRoutes: [MacRoute], from macAt: CLLocationCoordinate2D) -> some MapContent {
        ForEach(macRoutes) { r in
            // Through the Mac's VPN the hop starts at that server;
            // the Mac -> VPN server arrow is a route of its own.
            let a = r.viaID.flatMap { coordinate($0) } ?? macAt
            if let b = coordinate(r.toID), !same(a, b) {
                MapPolyline(coordinates: [a, b], contourStyle: .straight)
                    .stroke(RouteStyle.color(r), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                Annotation("", coordinate: RouteStyle.midpoint(a, b), anchor: .center) {
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(RouteStyle.color(r))
                        .rotationEffect(RouteStyle.angle(a, b))
                        .help(RouteStyle.describe(r, model))
                }
            }
        }
    }

    @MapContentBuilder
    private func clientLayer(_ clientPins: [ClientPin]) -> some MapContent {
        ForEach(clientPins) { pin in
            ForEach(pin.serverIDs, id: \.self) { sid in
                if let b = coordinate(sid), !same(pin.coordinate, b) {
                    MapPolyline(coordinates: [pin.coordinate, b], contourStyle: .geodesic)
                        .stroke(pin.active(to: sid) ? RouteStyle.clientTint.opacity(0.8) : Color.gray.opacity(0.4),
                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }
            }
            Annotation("", coordinate: pin.coordinate, anchor: .center) {
                ClientPinView(pin: pin)
            }
            .tag(pin.id)
        }
    }

    @MapContentBuilder
    private func externalLayer(_ extPins: [ExternalPin], mac macAt: CLLocationCoordinate2D) -> some MapContent {
        ForEach(extPins) { pin in
            ForEach(pin.sources, id: \.self) { from in
                if let a = from == MacLinksModel.pinID ? Optional(macAt) : coordinate(from), !same(a, pin.coordinate) {
                    MapPolyline(coordinates: [a, pin.coordinate], contourStyle: .straight)
                        .stroke(Color.gray.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                }
            }
            Annotation(pin.title, coordinate: pin.coordinate, anchor: .center) {
                Image(systemName: pin.service == nil ? "questionmark" : "globe")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Color.gray, in: Circle())
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                    .help(pin.service.map { "\($0): конечная точка, адресов \(pin.hops.count)" }
                          ?? pin.hops.map(\.ip).joined(separator: ", "))
            }
            .tag(pin.id)
        }
    }

    @MapContentBuilder
    private func macPin(_ macAt: CLLocationCoordinate2D) -> some MapContent {
        if showMac {
            Annotation("Этот Mac", coordinate: macAt, anchor: .center) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(RouteStyle.macTint, in: Circle())
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
            }
            .tag(MacLinksModel.pinID)
        }
    }

    @MapContentBuilder
    private func serverPins(_ pins: [Pin]) -> some MapContent {
        ForEach(pins) { pin in
            Annotation(pin.title, coordinate: pin.coordinate, anchor: .center) {
                PinView(level: pin.level, count: pin.statuses.count)
            }
            .tag(pin.id)
        }
    }

    private var layers: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Связи и задержки", isOn: $showLinks)
            if showLinks, model.links.isEmpty, model.statuses.count > 1 {
                hint("Серверы пока не проверяют друг друга, поэтому линий нет.")
            }
            Toggle("Маршруты VPN", isOn: $showRoutes)
            if showRoutes, model.routes.isEmpty, let why = noRoutesReason {
                hint(why)
            }
            if showRoutes {
                HStack(spacing: 10) {
                    routeLegend(dash: [], "туннель")
                    routeLegend(dash: [4, 3], "пересылка")
                }
                .font(.caption)
            }
            Toggle("Клиенты VPN", isOn: $showClients)
            Toggle("Чужие узлы", isOn: $showExternal)
            Toggle("Этот Mac", isOn: $showMac)
            if showMac {
                HStack(spacing: 4) {
                    Path { p in p.move(to: .init(x: 0, y: 4)); p.addLine(to: .init(x: 18, y: 4)) }
                        .stroke(RouteStyle.macTint, style: StrokeStyle(lineWidth: 2.5))
                        .frame(width: 18, height: 8)
                    Text("трафик с этого Mac").foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            Divider()
            HStack(spacing: 12) {
                legend(.ok, "в норме")
                legend(.warning, "внимание")
                legend(.critical, "критично")
            }
            .font(.caption)
        }
        .toggleStyle(.checkbox)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .fixedSize()
    }

    /// Routes need agent 0.4+; an older agent and "no cascades" look the
    /// same in the snapshot, so the hint names both.
    private var noRoutesReason: String? {
        if model.statuses.allSatisfy({ $0.snapshot == nil }) { return nil }
        return "Каскадов между серверами не видно. Если они настроены, обновите агентов: кнопка «Обновить агентов» вверху окна."
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption).foregroundStyle(.secondary)
            .frame(width: 220, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func routeLegend(dash: [CGFloat], _ t: String) -> some View {
        HStack(spacing: 4) {
            Path { p in p.move(to: .init(x: 0, y: 4)); p.addLine(to: .init(x: 18, y: 4)) }
                .stroke(RouteStyle.tint, style: StrokeStyle(lineWidth: 2.5, dash: dash))
                .frame(width: 18, height: 8)
            Text(t).foregroundStyle(.secondary)
        }
    }

    private func coordinate(_ serverID: String) -> CLLocationCoordinate2D? {
        model.status(serverID).flatMap { locations.coordinate(for: $0.server) }
    }

    private func same(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
        abs(a.latitude - b.latitude) < 0.01 && abs(a.longitude - b.longitude) < 0.01
    }

    private func legend(_ l: ServerStatus.Level, _ t: String) -> some View {
        HStack(spacing: 4) { StatusDot(level: l); Text(t).foregroundStyle(.secondary) }
    }
}

/// Both directions between two servers, shown as one latency label.
struct LinkPair: Identifiable {
    var a: ServerConfig
    var b: ServerConfig
    var links: [ServerLink]
    var id: String { a.id + "|" + b.id }

    var ok: Bool { links.allSatisfy(\.check.ok) }

    var label: String {
        let ms = links.filter(\.check.ok).map(\.check.latencyMs)
        if !ok { return ms.isEmpty ? "нет связи" : "частично" }
        guard !ms.isEmpty else { return "—" }
        return Fmt.ms(ms.reduce(0, +) / Double(ms.count))
    }

    var detail: String {
        links.map { l in
            "\(l.from.name) → \(l.to.name): " + (l.check.ok ? Fmt.ms(l.check.latencyMs) : (l.check.error ?? "нет ответа"))
        }.joined(separator: "\n")
    }

    static func group(_ links: [ServerLink]) -> [LinkPair] {
        var pairs: [String: LinkPair] = [:]
        for l in links {
            let (a, b) = l.from.id < l.to.id ? (l.from, l.to) : (l.to, l.from)
            pairs[a.id + "|" + b.id, default: LinkPair(a: a, b: b, links: [])].links.append(l)
        }
        return pairs.values.sorted { $0.id < $1.id }
    }

    /// The point halfway along the great circle, where a geodesic line passes.
    static func greatCircleMidpoint(_ p: CLLocationCoordinate2D, _ q: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let r = Double.pi / 180
        let lat1 = p.latitude * r, lon1 = p.longitude * r, lat2 = q.latitude * r
        let dLon = (q.longitude - p.longitude) * r
        let bx = cos(lat2) * cos(dLon), by = cos(lat2) * sin(dLon)
        let lat = atan2(sin(lat1) + sin(lat2), sqrt((cos(lat1) + bx) * (cos(lat1) + bx) + by * by))
        let lon = lon1 + atan2(by, cos(lat1) + bx)
        return .init(latitude: lat / r, longitude: lon / r)
    }
}

/// How a VPN route looks: one tint, solid for a tunnel, dashed for a relay,
/// faded while idle.
enum RouteStyle {
    static let tint = Color.indigo
    static let macTint = Color.teal
    static let clientTint = Color.orange

    static func color(_ r: VPNRoute) -> Color { r.active ? tint : tint.opacity(0.35) }

    static func midpoint(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let y = (mercator(a.latitude) + mercator(b.latitude)) / 2
        return .init(latitude: atan(sinh(y)) * 180 / .pi, longitude: (a.longitude + b.longitude) / 2)
    }

    /// Screen direction of a straight line on a north-up Mercator map.
    static func angle(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Angle {
        let dx = (b.longitude - a.longitude) * .pi / 180
        let dy = mercator(b.latitude) - mercator(a.latitude)
        return .radians(-atan2(dy, dx))
    }

    private static func mercator(_ lat: Double) -> Double {
        log(tan(.pi / 4 + lat * .pi / 360))
    }

    static func detail(_ r: VPNRoute) -> String {
        var parts = [r.kind == .tunnel ? "туннель" : "пересылка", r.active ? "активен" : "простаивает"]
        if !r.via.isEmpty { parts.append(r.via.joined(separator: ", ")) }
        if !r.ports.isEmpty { parts.append("порт " + r.ports.map(String.init).joined(separator: ", ")) }
        if r.connections > 0 { parts.append("соединений: \(r.connections)") }
        return parts.joined(separator: " · ")
    }

    @MainActor static func describe(_ r: VPNRoute, _ model: AppModel) -> String {
        let from = model.status(r.fromID)?.server.name ?? r.fromID
        let to = model.status(r.toID)?.server.name ?? r.toID
        return "\(from) → \(to)\n" + detail(r)
    }

    static func color(_ r: MacRoute) -> Color { r.active ? macTint : macTint.opacity(0.4) }

    static func detail(_ r: MacRoute) -> String {
        var parts = [r.processes.joined(separator: ", ")]
        if !r.active { return parts[0] + " · по настройкам, сейчас без трафика" }
        if !r.ports.isEmpty { parts.append("порт " + r.ports.map(String.init).joined(separator: ", ")) }
        parts.append("соединений: \(r.connections)")
        return parts.joined(separator: " · ")
    }

    @MainActor static func path(_ r: MacRoute, _ model: AppModel) -> String {
        let name = { (id: String) in model.status(id)?.server.name ?? id }
        return (["Этот Mac"] + (r.viaID.map { [name($0)] } ?? []) + [name(r.toID)]).joined(separator: " → ")
    }

    @MainActor static func describe(_ r: MacRoute, _ model: AppModel) -> String {
        path(r, model) + "\n" + detail(r)
    }
}

private struct PinView: View {
    var level: ServerStatus.Level
    var count: Int

    var body: some View {
        ZStack {
            if level == .critical {
                Circle().fill(level.color.opacity(0.18)).frame(width: 34, height: 34)
            }
            Circle()
                .fill(level.color)
                .frame(width: count > 1 ? 22 : 14, height: count > 1 ? 22 : 14)
                .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
                .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
            if count > 1 {
                Text("\(count)").font(.caption2.weight(.bold)).foregroundStyle(.white)
            }
        }
        .accessibilityLabel("\(count) серв., \(level.label)")
    }
}

/// The panel next to the map for the selected pin.
private struct MapInspector: View {
    @ObservedObject var model: AppModel
    var statuses: [ServerStatus]
    var center: CLLocationCoordinate2D?
    /// The server whose pin is about to move to the map's center, and where.
    @State private var confirmMove: (id: String, to: CLLocationCoordinate2D)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(statuses) { s in serverBlock(s) }
            }
            .padding(16)
        }
    }

    private func serverBlock(_ s: ServerStatus) -> some View {
        let reach = model.reachability(of: s.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusDot(level: s.level, size: 10)
                Text(s.server.name).font(.headline).lineLimit(1)
                Spacer()
            }
            Text([s.country?.name, s.server.group, s.server.host].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(s.alerts, id: \.key) { a in
                AlertStrip(level: a.severity.level, text: a.message, trailing: Fmt.since(a.since)).font(.callout)
            }
            if !reach.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Доступность с других серверов").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(reach) { l in
                        HStack {
                            StatusDot(level: l.check.ok ? .ok : .critical)
                            Text(l.from.name).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(l.check.ok ? Fmt.ms(l.check.latencyMs) : "нет ответа")
                                .foregroundStyle(l.check.ok ? Color.primary : Color.red).monospacedDigit()
                        }
                        .font(.callout)
                    }
                    if let verdict = verdict(s, reach) {
                        Text(verdict).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            let routes = model.routes(of: s.id)
            if !routes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Маршруты VPN").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(routes) { r in
                        let outgoing = r.fromID == s.id
                        let other = model.status(outgoing ? r.toID : r.fromID)?.server.name ?? (outgoing ? r.toID : r.fromID)
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: outgoing ? "arrow.up.right" : "arrow.down.left")
                                .foregroundStyle(RouteStyle.color(r))
                            VStack(alignment: .leading, spacing: 1) {
                                Text((outgoing ? "выход через " : "вход с ") + other).lineLimit(1)
                                Text(RouteStyle.detail(r)).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .font(.callout)
                    }
                }
            }
            if let snap = s.snapshot {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow { Text("CPU").foregroundStyle(.secondary); Text(Fmt.percent(snap.cpu.usagePercent)) }
                    GridRow { Text("Память").foregroundStyle(.secondary); Text(Fmt.percent(snap.memory.usedPercent)) }
                    GridRow { Text("Диск").foregroundStyle(.secondary); Text(Fmt.percent(snap.maxDiskPercent)) }
                    if snap.vpnActiveClients > 0 {
                        GridRow { Text("VPN онлайн").foregroundStyle(.secondary); Text("\(snap.vpnActiveClients)") }
                    }
                }
                .font(.callout).monospacedDigit()
            }
            HStack {
                if model.can(.ssh, s.server) {
                    Button { model.openSSH(s.server) } label: { Label("SSH", systemImage: "terminal") }
                        .buttonStyle(.borderedProminent)
                }
                Button("Открыть сервер") { model.show(server: s.id) }
            }
            if model.can(.editConfig, s.server) {
                HStack(spacing: 12) {
                    if let center {
                        Button("Переместить в центр карты…") { confirmMove = (s.id, center) }
                    }
                    // A pin moved by hand stays there until put back; the
                    // country's place is the default.
                    if model.locations.isMoved(s.id), Country.detect(s.server) != nil {
                        Button("Вернуть на место") { model.locations.set(nil, for: s.id) }
                    }
                }
                .buttonStyle(.link).font(.caption)
                .confirmationDialog("Переместить «\(s.server.name)» в центр карты?",
                                    isPresented: Binding(get: { confirmMove?.id == s.id }, set: { if !$0 { confirmMove = nil } })) {
                    Button("Переместить") { if let c = confirmMove { model.locations.set(c.to, for: c.id) } }
                } message: {
                    Text("Точка сервера останется там, пока вы не нажмёте «Вернуть на место».")
                }
            }
        }
    }

    /// Down everywhere vs blocked from one place.
    private func verdict(_ s: ServerStatus, _ reach: [ServerLink]) -> String? {
        let failed = reach.filter { !$0.check.ok }
        if failed.isEmpty { return nil }
        if failed.count == reach.count {
            return "Сервер не видит никто, значит, скорее всего, он лёг, а не заблокирован."
        }
        let from = failed.map { Country.detect($0.from)?.name ?? $0.from.name }.joined(separator: ", ")
        return "Не отвечает только для: \(from). Похоже на блокировку или проблему сети, а не на падение."
    }
}

/// Servers whose country could not be guessed: place them by hand.
private struct UnplacedList: View {
    @ObservedObject var model: AppModel
    var statuses: [ServerStatus]
    var center: CLLocationCoordinate2D?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Без места на карте").font(.headline)
            Text("Укажите страну в group или tags сервера, или передвиньте карту и нажмите «Сюда».")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(statuses) { s in
                HStack {
                    StatusDot(level: s.level)
                    Text(s.server.name)
                    Spacer()
                    Button("Сюда") { if let center { model.locations.set(center, for: s.id) } }
                        .disabled(center == nil || !model.can(.editConfig, s.server))
                        .controlSize(.small)
                }
            }
            Spacer()
        }
        .padding(16)
    }
}
#endif
