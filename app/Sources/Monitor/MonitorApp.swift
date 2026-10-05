#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import MonitorCore
import MonitorUI
import SwiftUI
import UserNotifications

@main
struct MonitorApp: App {
    private let notifier: Notifier
    @StateObject private var model: AppModel

    init() {
        let notifier = Notifier()
        notifier.requestPermission()
        self.notifier = notifier
        _model = StateObject(wrappedValue: AppModel(notify: { notifier.post($0) }))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            Image(nsImage: StatusDot.image(for: model.overall))
        }
        .menuBarExtraStyle(.window)
    }
}

/// macOS notifications. They need a real app bundle (Monitor.app); when the
/// binary runs bare (swift run) they are skipped.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    func requestPermission() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(_ events: [AlertEvent]) {
        guard available else { return }
        for e in events {
            let content = UNMutableNotificationContent()
            content.title = e.title
            content.body = e.body
            content.sound = e.kind == .resolved ? nil : .default
            content.threadIdentifier = e.serverID
            let id = "\(e.serverID)|\(e.key)|\(e.time.timeIntervalSince1970)"
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    // Show banners even though a menu bar app counts as "in the foreground".
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}

enum StatusDot {
    static func color(_ level: ServerStatus.Level) -> NSColor {
        switch level {
        case .ok: return .systemGreen
        case .warning: return .systemYellow
        case .critical: return .systemRed
        case .unknown: return .systemGray
        }
    }

    /// A colored (non-template) dot so the menu bar shows the state color.
    static func image(for level: ServerStatus.Level) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        let img = NSImage(size: size, flipped: false) { rect in
            color(level).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            return true
        }
        img.isTemplate = false
        img.accessibilityDescription = "Мониторинг"
        return img
    }
}

struct MenuView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let err = model.configError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.statuses.isEmpty && model.configError == nil {
                Text("Серверов пока нет. Добавьте их в servers.json.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.statuses) { ServerRow(status: $0) }
            Divider()
            HStack {
                Button("servers.json") { model.openConfig() }
                Button("Папка данных") { model.openDataFolder() }
                Button("Перечитать") { Task { await model.reload() } }
                Spacer()
                Button("Выход") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(width: 380)
    }
}

struct ServerRow: View {
    let status: ServerStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(Color(nsColor: StatusDot.color(status.level))).frame(width: 9, height: 9)
                Text(status.server.name).fontWeight(.medium)
                if let g = status.server.group { Text(g).foregroundStyle(.secondary).font(.caption) }
                Spacer()
                if let seen = status.lastSeen {
                    Text(seen, style: .relative).foregroundStyle(.secondary).font(.caption)
                }
            }
            if let s = status.snapshot {
                Text(summary(s)).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(status.alerts, id: \.key) { a in
                Text("• \(a.message)").font(.caption)
                    .foregroundStyle(a.severity == .critical ? Color.red : Color.orange)
            }
            if let err = status.error, !status.alerts.contains(where: { $0.key == "down" }) {
                Text(err).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func summary(_ s: Snapshot) -> String {
        var parts = [
            String(format: "CPU %.0f%%", s.cpu.usagePercent),
            String(format: "RAM %.0f%%", s.memory.usedPercent),
            String(format: "диск %.0f%%", s.maxDiskPercent),
        ]
        if let vpn = s.vpn, vpn.contains(where: { $0.clientsKnown == true }) {
            parts.append("VPN \(s.vpnActiveClients) онлайн")
        }
        return parts.joined(separator: " · ")
    }
}
#else
// The app is macOS-only; on Linux (CI) only MonitorCore and its tests matter.
@main
enum MonitorApp {
    static func main() { print("Monitor runs on macOS only.") }
}
#endif
