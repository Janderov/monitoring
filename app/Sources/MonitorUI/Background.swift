#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import MonitorCore
import ServiceManagement

/// Keeps the monitoring running like a service: it starts with the Mac, App
/// Nap does not slow it down, and it polls as soon as the Mac wakes.
@MainActor
enum Background {
    /// Set once start at login was turned on for the first time; after that
    /// only the switch in Settings changes it.
    static let launchSetKey = "launchAtLogin.set"
    private static var activity: NSObjectProtocol?
    private static var wakeObserver: NSObjectProtocol?

    static func start(_ model: AppModel) {
        guard Bundle.main.bundleIdentifier != nil, wakeObserver == nil else { return }
        // A menu bar app with no window in front is napped by macOS, and its
        // once-a-minute timer slips to several minutes.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "Мониторинг серверов")
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                // Wi-Fi comes back a few seconds after waking up.
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                await model.pollNow()
            }
        }
        if !UserDefaults.standard.bool(forKey: launchSetKey), Bundle.main.bundleURL.path.hasPrefix("/Applications/") {
            UserDefaults.standard.set(true, forKey: launchSetKey)
            setLaunchAtLogin(true)
        }
    }

    static var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns the error to show, nil when it worked.
    @discardableResult
    static func setLaunchAtLogin(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
#endif
