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
    @ObservedObject private var probes: MacProbeModel
    @ObservedObject private var siteHosts: SiteHostsModel
    @StateObject private var history = MapHistoryModel()
    @State private var showHistory = false
    @State private var position: MapCameraPosition = .automatic
    @State private var center: CLLocationCoordinate2D?
    @State private var selectedPin: String?
    @AppStorage("map.links") private var showLinks = true
    @AppStorage("map.routes") private var showRoutes = true
    @AppStorage("map.onlyProblems") private var onlyProblems = false
    @AppStorage("map.mac") private var showMac = true
    @AppStorage("map.external") private var showExternal = true
    @AppStorage("map.clients") private var showClients = true
    @AppStorage("map.traffic") private var showTraffic = true
    @AppStorage("map.sites") private var showSites = true
    @AppStorage("map.load") private var showLoad = true
    @AppStorage("map.macChecks") private var showMacChecks = true

    init(model: AppModel) {
        self.model = model
        self.locations = model.locations
        self.mac = model.mac
        self.external = model.external
        self.probes = model.probes
        self.siteHosts = model.siteHosts
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

    /// The history slider shows a past moment: live-only layers step aside.
    private var inPast: Bool { showHistory && history.time != nil }

    var body: some View {
        let pins = pins
        let live = !inPast
        let routes = showRoutes && live ? model.routes : []
        let macAt = macCoordinate(pins)
        let macRoutes = showMac && live ? mac.routes(model.statuses) : []
        let hops = showExternal && live ? ExternalHop.compute(model).filter { showMac || $0.fromID != MacLinksModel.pinID } : []
        let extPins = ExternalPin.group(hops, owners: external.owners, avoiding: pins.map(\.coordinate))
        let spots = showClients && live ? VPNClientSpot.compute(model) : []
        let clientPins = ClientPin.group(spots, owners: external.owners, avoiding: pins.map(\.coordinate))
        let chains = NetworkChains.build(macID: MacLinksModel.pinID, macRoutes: macRoutes, routes: routes)
        let chosen = chains.first { PathKey.id($0) == selectedPin }
        let clusters = showSites ? siteClusters(pins) : []
        HStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Map(position: $position, selection: $selectedPin) {
                    linkLayers()
                    pathLayer(chosen, mac: macAt)
                    routeLayer(routes, chains: chains)
                    macRouteLayer(macRoutes, from: macAt, chains: chains)
                    macCheckLayer(macAt)
                    clientLayer(clientPins)
                    externalLayer(extPins, mac: macAt)
                    siteLayer(clusters)
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
                .overlay(alignment: .bottom) {
                    if showHistory {
                        HistoryBar(history: history, model: model)
                            .frame(maxWidth: 720)
                            .padding(12)
                    }
                }

                layers
                    .padding(12)
            }
            inspector(pins: pins, clientPins: clientPins, extPins: extPins, chosen: chosen, clusters: clusters)
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
                Toggle(isOn: $showHistory) {
                    Label("История", systemImage: "clock.arrow.circlepath")
                }
                .help("Карта за последние 30 дней")
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
        .task {
            probes.setTargets(model.statuses.map(\.server))
            await probes.run()
        }
        .onChange(of: model.statuses.map(\.server), initial: true) { _, servers in
            probes.setTargets(servers)
            siteHosts.refresh(sites: model.siteConfigs, servers: servers)
        }
        .onChange(of: model.siteConfigs, initial: true) { _, sites in
            siteHosts.refresh(sites: sites, servers: model.statuses.map(\.server))
        }
        .onChange(of: siteHosts.addresses.values.compactMap(\.first).sorted()) { _, ips in external.request(ips) }
        .onChange(of: showHistory) { _, on in
            if !on {
                history.stop()
                history.show(nil, model: model)
            }
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
    private func inspector(pins: [Pin], clientPins: [ClientPin], extPins: [ExternalPin],
                           chosen: NetworkChain?, clusters: [SiteCluster]) -> some View {
        if let chain = chosen {
            Divider()
            PathInspector(model: model, probes: probes, external: external, chain: chain)
                .frame(width: 300)
        } else if let id = selectedPin, id.hasPrefix(SiteKey.prefix),
                  let site = model.sites.first(where: { SiteKey.id($0.id) == id }) {
            Divider()
            SiteInspector(model: model, site: site,
                          cluster: clusters.first { c in c.sites.contains { $0.id == site.id } },
                          history: siteHistory(site.id))
                .frame(width: 300)
        } else if let id = selectedPin, let pin = clientPins.first(where: { $0.id == id }) {
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
            MapInspector(model: model, probes: probes, statuses: pin.statuses, center: center)
                .frame(width: 300)
        } else if !unplaced.isEmpty {
            Divider()
            UnplacedList(model: model, statuses: unplaced, center: center)
                .frame(width: 260)
        }
    }

    @MapContentBuilder
    private func linkLayers() -> some MapContent {
        if inPast { pastLinkLayer() }
        if !inPast { linkLayer() }
    }

    /// Checks between servers at the moment the history shows.
    @MapContentBuilder
    private func pastLinkLayer() -> some MapContent {
        if showLinks, let m = history.moment {
            ForEach(PastLink.build(m, model.statuses)) { l in
                if let a = coordinate(l.fromID), let b = coordinate(l.toID) {
                    MapPolyline(coordinates: [a, b], contourStyle: .geodesic)
                        .stroke(l.ok ? Color.secondary.opacity(0.6) : Color.red,
                                style: StrokeStyle(lineWidth: 1.5, dash: l.ok ? [] : [5, 4]))
                    Annotation("", coordinate: LinkPair.greatCircleMidpoint(a, b), anchor: .center) {
                        Text(l.label)
                            .font(.caption2.weight(.medium)).monospacedDigit()
                            .foregroundStyle(l.ok ? Color.primary : Color.red)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.regularMaterial, in: Capsule())
                    }
                }
            }
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
    private func routeLayer(_ routes: [VPNRoute], chains: [NetworkChain]) -> some MapContent {
        ForEach(routes) { r in
            if let a = coordinate(r.fromID), let b = coordinate(r.toID), !same(a, b) {
                let traffic = showTraffic ? Traffic.route(r, model: model) : nil
                // Straight on the map, so the arrow in the middle points along it.
                MapPolyline(coordinates: [a, b], contourStyle: .straight)
                    .stroke(RouteStyle.color(r),
                            style: StrokeStyle(lineWidth: TrafficStyle.width(traffic?.rate, base: 3), lineCap: .round,
                                               dash: r.kind == .relay ? [7, 5] : []))
                Annotation("", coordinate: RouteStyle.midpoint(a, b), anchor: .center) {
                    RouteArrow(color: RouteStyle.color(r), angle: RouteStyle.angle(a, b), size: 13,
                               help: RouteStyle.describe(r, model) + "\nНажмите, чтобы увидеть весь путь",
                               label: routeLabel(traffic), labelHelp: routeLabelHelp(r, traffic)) {
                        selectPath(from: r.fromID, to: r.toID, chains)
                    }
                }
            }
        }
    }

    private func macLabel(_ rate: RateMeter.Rate?) -> String? {
        guard let rate, TrafficStyle.worthShowing(rate) else { return nil }
        return TrafficStyle.text(rate)
    }

    private func routeLabel(_ t: (rate: RateMeter.Rate, approximate: Bool)?) -> String? {
        guard let t, TrafficStyle.worthShowing(t.rate) else { return nil }
        return (t.approximate ? "≈ " : "") + TrafficStyle.text(t.rate)
    }

    private func routeLabelHelp(_ r: VPNRoute, _ t: (rate: RateMeter.Rate, approximate: Bool)?) -> String {
        guard let t else { return "" }
        var text = TrafficStyle.detail(t.rate, downIsTx: false)
        if t.approximate {
            let name = model.status(r.toID)?.server.name ?? r.toID
            text += "\nВесь трафик сервера \(name): отдельного счётчика у этой пересылки нет"
        }
        return text
    }

    /// The path a hop belongs to, shown in the panel on the right.
    private func selectPath(from: String, to: String, _ chains: [NetworkChain]) {
        if let c = chains.first(where: { $0.contains(from: from, to: to) }) { selectedPin = PathKey.id(c) }
    }

    /// The chosen path drawn under the routes as a wide light band.
    @MapContentBuilder
    private func pathLayer(_ chain: NetworkChain?, mac macAt: CLLocationCoordinate2D) -> some MapContent {
        if let chain {
            let points = chain.nodes.compactMap { $0 == MacLinksModel.pinID ? Optional(macAt) : coordinate($0) }
            MapPolyline(coordinates: points, contourStyle: .straight)
                .stroke(Color.accentColor.opacity(0.28), style: StrokeStyle(lineWidth: 14, lineCap: .round, lineJoin: .round))
        }
    }

    /// Lines from this Mac to each server with the time to connect.
    @MapContentBuilder
    private func macCheckLayer(_ macAt: CLLocationCoordinate2D) -> some MapContent {
        if showMacChecks, showMac, !inPast {
            ForEach(model.visible) { s in
                if let p = probes.probes[s.id], let b = coordinate(s.id), !same(macAt, b) {
                    MapPolyline(coordinates: [macAt, b], contourStyle: .geodesic)
                        .stroke(p.ok ? RouteStyle.macTint.opacity(0.45) : Color.red.opacity(0.8),
                                style: StrokeStyle(lineWidth: 1.2, dash: [2, 4]))
                    Annotation("", coordinate: MacCheck.labelPoint(macAt, b), anchor: .center) {
                        TrafficLabel(text: MacCheck.label(p), tint: p.ok ? RouteStyle.macTint : .red,
                                     help: MacCheck.help(p, s.server.name))
                    }
                }
            }
        }
    }

    @MapContentBuilder
    private func siteLayer(_ clusters: [SiteCluster]) -> some MapContent {
        let levels = siteLevels()
        ForEach(clusters) { c in
            Annotation("", coordinate: c.coordinate, anchor: .center) {
                SiteRingView(cluster: c, levels: levels) { id in selectedPin = SiteKey.id(id) }
            }
        }
    }

    private func siteHistory(_ siteID: String) -> [String: Bool]? {
        inPast ? (history.moment?.sites[siteID] ?? [:]) : nil
    }

    private func siteLevels() -> [String: ServerStatus.Level] {
        var out: [String: ServerStatus.Level] = [:]
        for s in model.sites { out[s.id] = SiteMark.level(s, history: siteHistory(s.id)) }
        return out
    }

    /// Sites around the pin of the server they run on; sites hosted
    /// elsewhere near the country of their address.
    private func siteClusters(_ pins: [Pin]) -> [SiteCluster] {
        let levels = siteLevels()
        var byKey: [String: SiteCluster] = [:]
        for site in model.sites {
            if onlyProblems, let l = levels[site.id], l != .warning, l != .critical { continue }
            if let sid = siteHosts.server[site.id] {
                guard let pin = pins.first(where: { $0.statuses.contains { $0.id == sid } }) else { continue }
                byKey[pin.id, default: SiteCluster(id: SiteCluster.prefix + pin.id, coordinate: pin.coordinate,
                                                   sites: [], onServer: true, place: pin.title)].sites.append(site)
            } else if let ip = siteHosts.addresses[site.id]?.first, let code = external.owners[ip]?.country,
                      let country = Country.known.first(where: { $0.code == code }) {
                let key = "ext-" + code
                let at = CLLocationCoordinate2D(latitude: country.lat + 1.8, longitude: country.lon - 3)
                byKey[key, default: SiteCluster(id: SiteCluster.prefix + key, coordinate: at,
                                                sites: [], onServer: false, place: country.name)].sites.append(site)
            }
        }
        return byKey.values.sorted { $0.id < $1.id }
    }

    @MapContentBuilder
    private func macRouteLayer(_ macRoutes: [MacRoute], from macAt: CLLocationCoordinate2D,
                               chains: [NetworkChain]) -> some MapContent {
        ForEach(macRoutes) { r in
            // Through the Mac's VPN the hop starts at that server;
            // the Mac -> VPN server arrow is a route of its own.
            let a = r.viaID.flatMap { coordinate($0) } ?? macAt
            if let b = coordinate(r.toID), !same(a, b) {
                let rate = showTraffic ? Traffic.mac(r, model: model) : nil
                MapPolyline(coordinates: [a, b], contourStyle: .straight)
                    .stroke(RouteStyle.color(r), style: StrokeStyle(lineWidth: TrafficStyle.width(rate, base: 2.5), lineCap: .round))
                Annotation("", coordinate: RouteStyle.midpoint(a, b), anchor: .center) {
                    RouteArrow(color: RouteStyle.color(r), angle: RouteStyle.angle(a, b), size: 12,
                               help: RouteStyle.describe(r, model) + "\nНажмите, чтобы увидеть весь путь",
                               label: macLabel(rate), labelHelp: rate.map { TrafficStyle.detail($0, downIsTx: false) } ?? "") {
                        selectPath(from: r.viaID ?? MacLinksModel.pinID, to: r.toID, chains)
                    }
                }
            }
        }
    }

    @MapContentBuilder
    private func clientLayer(_ clientPins: [ClientPin]) -> some MapContent {
        ForEach(clientPins) { pin in
            ForEach(pin.serverIDs, id: \.self) { sid in
                if let b = coordinate(sid), !same(pin.coordinate, b) {
                    let rate = showTraffic ? Traffic.clients(pin, server: sid, model: model) : nil
                    MapPolyline(coordinates: [pin.coordinate, b], contourStyle: .geodesic)
                        .stroke(pin.active(to: sid) ? RouteStyle.clientTint.opacity(0.8) : Color.gray.opacity(0.4),
                                style: StrokeStyle(lineWidth: TrafficStyle.width(rate, base: 1.5), lineCap: .round))
                    if let rate, TrafficStyle.worthShowing(rate) {
                        Annotation("", coordinate: LinkPair.greatCircleMidpoint(pin.coordinate, b), anchor: .center) {
                            TrafficLabel(text: TrafficStyle.text(rate), tint: RouteStyle.clientTint,
                                         help: "Клиенты VPN: " + TrafficStyle.detail(rate, downIsTx: true))
                        }
                    }
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
                PinView(level: level(of: pin), count: pin.statuses.count, load: load(of: pin))
            }
            .tag(pin.id)
        }
    }

    /// Now, or at the moment the history shows.
    private func level(of pin: Pin) -> ServerStatus.Level {
        inPast ? (pin.statuses.map { history.level($0.id) }.max() ?? .unknown) : pin.level
    }

    /// The busiest CPU among the pin's servers, in percent.
    private func load(of pin: Pin) -> Double? {
        guard showLoad else { return nil }
        let values = pin.statuses.compactMap { s in
            inPast ? history.moment?.cpu[s.id] : s.snapshot?.cpu.usagePercent
        }
        return values.max()
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
            Toggle("Сайты", isOn: $showSites)
            Toggle("Загрузка процессора", isOn: $showLoad)
            Toggle("Трафик на линиях", isOn: $showTraffic)
            Toggle("Этот Mac", isOn: $showMac)
            if showMac {
                Toggle("Проверка с этого Mac", isOn: $showMacChecks)
                    .padding(.leading, 16)
            }
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
    /// CPU in percent, drawn as a ring; nil hides the ring.
    var load: Double? = nil

    var body: some View {
        let size: CGFloat = count > 1 ? 22 : 14
        ZStack {
            if level == .critical {
                Circle().fill(level.color.opacity(0.18)).frame(width: 34, height: 34)
            }
            if let load {
                Circle()
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 3)
                    .frame(width: size + 9, height: size + 9)
                Circle()
                    .trim(from: 0, to: min(1, max(0.03, load / 100)))
                    .stroke(load >= 70 ? Color.orange : Color.indigo, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: size + 9, height: size + 9)
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
        .help(load.map { "Процессор \(Fmt.percent($0))" } ?? "")
    }
}

/// The panel next to the map for the selected pin.
private struct MapInspector: View {
    @ObservedObject var model: AppModel
    @ObservedObject var probes: MacProbeModel
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
            if let p = probes.probes[s.id] {
                VStack(alignment: .leading, spacing: 4) {
                    Text("С этого Mac").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    HStack {
                        StatusDot(level: p.ok ? .ok : .critical)
                        Text(p.throughVPN ? "через VPN" : "напрямую").lineLimit(1)
                        Spacer(minLength: 6)
                        Text(p.latencyMs.map(Fmt.ms) ?? "нет ответа")
                            .foregroundStyle(p.ok ? Color.primary : Color.red).monospacedDigit()
                    }
                    .font(.callout)
                    .help(MacCheck.help(p, s.server.name))
                    if let verdict = macVerdict(p, reach) {
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

    /// The Mac cannot reach a server the other servers see: blocked on the
    /// Mac's side. Through a VPN it says nothing about the Mac's country.
    private func macVerdict(_ p: MacProbeModel.Probe, _ reach: [ServerLink]) -> String? {
        guard !p.ok else { return nil }
        if p.throughVPN { return "Mac ходит к этому серверу через VPN, поэтому проверка не показывает, открыт ли он из вашей страны." }
        guard reach.contains(where: \.check.ok) else { return nil }
        return "Другие серверы его видят, а этот Mac нет. Похоже, сервер блокирует ваш провайдер или страна."
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
