#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import MonitorCore
import SwiftUI

/// The menu bar icon: a server symbol in the menu bar's own color, plus a
/// colored dot only when something needs attention.
public enum MenuBarIcon {
    public static func image(for level: ServerStatus.Level) -> NSImage {
        let size = NSSize(width: 20, height: 16)
        let img = NSImage(size: size, flipped: false) { rect in
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            guard let symbol = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return false }
            let s = symbol.size
            let r = NSRect(x: 1, y: (rect.height - s.height) / 2, width: s.width, height: s.height)
            // Tint the symbol with the menu bar text color of the current appearance.
            let tinted = NSImage(size: s, flipped: false) { tr in
                symbol.draw(in: tr)
                NSColor.labelColor.withAlphaComponent(level == .unknown ? 0.45 : 1).set()
                tr.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: r)
            if level == .warning || level == .critical {
                let d: CGFloat = 7
                let dot = NSRect(x: rect.width - d - 0.5, y: rect.height - d - 0.5, width: d, height: d)
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                (level == .critical ? NSColor.systemRed : NSColor.systemOrange).setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            return true
        }
        img.isTemplate = false
        img.accessibilityDescription = "Мониторинг: \(level.label)"
        return img
    }
}

/// The window that drops down from the menu bar icon.
public struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.horizontal, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let err = model.configError {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                    }
                    if !model.problems.isEmpty {
                        sectionTitle("Проблемы")
                        ForEach(model.problems) { p in problemRow(p) }
                    }
                    sectionTitle("Серверы")
                    if model.statuses.isEmpty {
                        Text("Серверов пока нет").foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 4)
                    }
                    ForEach(model.statuses) { s in serverRow(s) }
                    let sites = model.sites
                    if !sites.isEmpty {
                        sectionTitle("Сайты")
                        ForEach(sites) { site in siteRow(site) }
                    }
                }
                .padding(.bottom, 4)
            }
            .frame(maxHeight: 520)
            Divider().padding(.horizontal, 12)
            footer
        }
        .padding(.vertical, 6)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 10) {
            StatusDot(level: model.overall, size: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(summary).fontWeight(.semibold)
                if let t = model.lastRound {
                    Text("опрос \(Fmt.relative(t))").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { Task { await model.pollNow() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Опросить сейчас")
        }
        .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 8)
    }

    private var summary: String {
        let crit = model.problems.filter { $0.alert.severity == .critical }.count
        let warn = model.problems.count - crit
        if crit == 0 && warn == 0 { return model.statuses.isEmpty ? "Нет серверов" : "Всё в порядке" }
        var parts: [String] = []
        if crit > 0 { parts.append("\(crit) критично") }
        if warn > 0 { parts.append("\(warn) предупр.") }
        return parts.joined(separator: ", ")
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 2)
    }

    private func problemRow(_ p: Problem) -> some View {
        HoverRow(action: { open(server: p.status.id) }) {
            StatusDot(level: p.alert.severity.level)
            VStack(alignment: .leading, spacing: 1) {
                Text(p.status.server.name).fontWeight(.medium) + Text("  ") + Text(p.alert.message)
                Text(Fmt.since(p.alert.since)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if model.can(.ssh, p.status.server) {
                Button("SSH") { model.openSSH(p.status.server) }.controlSize(.small)
            }
        }
    }

    private func serverRow(_ s: ServerStatus) -> some View {
        HoverRow(action: { open(server: s.id) }) {
            StatusDot(level: s.level)
            Text(s.server.name)
            Spacer(minLength: 6)
            Text(s.keyFigure).font(.callout).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
        } hover: {
            if model.can(.ssh, s.server) {
                Button("SSH") { model.openSSH(s.server) }.controlSize(.small)
            }
        }
    }

    private func siteRow(_ site: SiteSummary) -> some View {
        HoverRow(action: {
            model.section = .sites
            model.selectedSiteID = site.id
            openMain()
        }) {
            StatusDot(level: site.level())
            Text(site.name)
            Spacer(minLength: 6)
            Text(site.problem ?? site.averageLatency.map(Fmt.ms) ?? "—")
                .font(.callout).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            MenuButton(title: "Открыть окно", shortcut: "⌘0") { openMain() }
            MenuButton(title: "Настройки…", shortcut: "⌘,") {
                NSApp.activate(ignoringOtherApps: true)
                // The SwiftUI Settings scene answers this action (openSettings needs a newer SDK).
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            MenuButton(title: "Выйти", shortcut: "⌘Q") { NSApp.terminate(nil) }
        }
        .padding(.top, 4)
    }

    private func open(server id: String) {
        model.show(server: id)
        openMain()
    }

    private func openMain() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: MainWindow.id)
    }
}

/// A full-width row that highlights on hover like a menu item.
private struct HoverRow<Content: View, Hover: View>: View {
    var action: () -> Void
    var content: Content
    var hover: Hover
    @State private var hovering = false

    init(action: @escaping () -> Void, @ViewBuilder content: () -> Content,
         @ViewBuilder hover: () -> Hover) {
        self.action = action
        self.content = content()
        self.hover = hover()
    }

    var body: some View {
        HStack(spacing: 9) {
            content
            if hovering { hover }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .padding(.horizontal, 6)
    }
}

extension HoverRow where Hover == EmptyView {
    init(action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.init(action: action, content: content, hover: { EmptyView() })
    }
}

private struct MenuButton: View {
    var title: String
    var shortcut: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(shortcut).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, 6)
    }
}
#endif
