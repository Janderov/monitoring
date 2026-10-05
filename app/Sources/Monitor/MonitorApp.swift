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
        Window("Монитор", id: MainWindow.id) {
            MainWindow(model: model)
        }
        .defaultSize(width: 1180, height: 760)
        .commands { MonitorCommands(model: model) }

        Settings {
            SettingsView(model: model)
        }

        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Image(nsImage: MenuBarIcon.image(for: model.overall))
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

#else
// The app is macOS-only; on Linux (CI) only MonitorCore and its tests matter.
@main
enum MonitorApp {
    static func main() { print("Monitor runs on macOS only.") }
}
#endif
