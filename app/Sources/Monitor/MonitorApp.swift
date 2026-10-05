#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import MonitorCore
import MonitorUI
import SwiftUI
import UserNotifications

@main
struct MonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let notifier: Notifier
    @StateObject private var model: AppModel

    init() {
        SingleInstance.takeOver()
        let notifier = Notifier()
        notifier.requestPermission()
        self.notifier = notifier
        _model = StateObject(wrappedValue: AppModel(notify: { notifier.post($0) }))
    }

    var body: some Scene {
        Window("Монитор", id: MainWindow.id) {
            MainWindow(model: model)
                .background(ReopenHook())
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            MonitorCommands(model: model)
            CommandGroup(replacing: .appSettings) { SettingsCommand() }
        }

        Window("Настройки", id: SettingsView.id) {
            SettingsView(model: model)
                .background(ReopenHook())
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarContent(model: model)
                .background(ReopenHook())
        } label: {
            Image(nsImage: MenuBarIcon.image(for: model.overall))
        }
        .menuBarExtraStyle(.window)
    }
}

/// Opening the app again (Dock icon, Finder, Launchpad) while it runs with no
/// window shows the main window. SwiftUI does not reopen a closed `Window`
/// scene by itself, so the delegate keeps an `openWindow` action from whichever
/// of our views appeared last; it stays valid after that view goes away.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var openMain: (() -> Void)?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening an already open Window scene only brings it to the front.
        if let open = Self.openMain {
            NSApp.activate(ignoringOtherApps: true)
            open()
        }
        return true
    }
}

private struct ReopenHook: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear.onAppear {
            AppDelegate.openMain = { [openWindow] in openWindow(id: MainWindow.id) }
        }
    }
}

/// ⌘, opens the settings window.
private struct SettingsCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Настройки…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: SettingsView.id)
        }
        .keyboardShortcut(",")
    }
}

/// Only one copy runs: a newly launched build quits the older ones, so two
/// apps never poll and write the same database, and an old build does not
/// linger in memory. When this copy runs from Applications, a quit copy that
/// ran from elsewhere (Downloads, a build folder) goes to the Trash, so it
/// does not linger on disk either; the Trash keeps it recoverable.
enum SingleInstance {
    static func takeOver() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != me }
        guard !others.isEmpty else { return }
        let ownPath = Bundle.main.bundleURL.standardizedFileURL.path
        // Only when this copy is the installed one; a test copy launched from
        // Downloads must never trash the one in Applications.
        let installed = ownPath.hasPrefix("/Applications/")
        let oldBundles = others.compactMap { $0.bundleURL?.standardizedFileURL }
            .filter { installed && $0.path != ownPath && !$0.path.hasPrefix("/Applications/") }

        others.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while others.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        others.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }

        for url in Set(oldBundles) where url.pathExtension == "app"
            && FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
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
