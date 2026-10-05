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
    @State private var position: MapCameraPosition = .automatic
    @State private var center: CLLocationCoordinate2D?
    @State private var selectedPin: String?
    @AppStorage("map.links") private var showLinks = true
    @AppStorage("map.onlyProblems") private var onlyProblems = false

    init(model: AppModel) {
        self.model = model
        self.locations = model.locations
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

    var body: some View {
        let pins = pins
        HStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Map(position: $position, selection: $selectedPin) {
                    if showLinks {
                        ForEach(model.links) { link in
                            if let a = locations.coordinate(for: link.from), let b = locations.coordinate(for: link.to) {
                                MapPolyline(coordinates: [a, b], contourStyle: .geodesic)
                                    .stroke(link.check.ok ? Color.secondary.opacity(0.6) : Color.red,
                                            style: StrokeStyle(lineWidth: 1.5, dash: link.check.ok ? [] : [5, 4]))
                            }
                        }
                    }
                    ForEach(pins) { pin in
                        Annotation(pin.title, coordinate: pin.coordinate, anchor: .center) {
                            PinView(level: pin.level, count: pin.statuses.count)
                        }
                        .tag(pin.id)
                    }
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
            if let id = selectedPin, let pin = pins.first(where: { $0.id == id }) {
                Divider()
                MapInspector(model: model, statuses: pin.statuses, center: center)
                    .frame(width: 300)
            } else if !unplaced.isEmpty {
                Divider()
                UnplacedList(model: model, statuses: unplaced, center: center)
                    .frame(width: 260)
            }
        }
        .navigationTitle("Карта")
        .navigationSubtitle("\(model.visible.count) серверов · линии: пинг между серверами")
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
        .onAppear {
            // Opening the map from a server's menu selects its pin.
            if let id = model.selectedServerID, let pin = pins.first(where: { $0.statuses.contains { $0.id == id } }) {
                selectedPin = pin.id
            }
        }
    }

    private var layers: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Связи и задержки", isOn: $showLinks)
            Toggle("Маршруты VPN", isOn: .constant(false))
                .disabled(true)
                .help("Появится, когда агент научится видеть каскады между серверами")
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

    private func legend(_ l: ServerStatus.Level, _ t: String) -> some View {
        HStack(spacing: 4) { StatusDot(level: l); Text(t).foregroundStyle(.secondary) }
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
                Text(s.server.name).font(.headline)
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
                            Text(l.from.name)
                            Spacer()
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
            if let center, model.can(.editConfig, s.server) {
                Button("Переместить в центр карты") { model.locations.set(center, for: s.id) }
                    .buttonStyle(.link).font(.caption)
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
