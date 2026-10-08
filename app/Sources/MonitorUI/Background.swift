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
    private static var sleepObserver: NSObjectProtocol?

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
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in model.heartbeat.goingToSleep() }
        }
        Task { @MainActor in
            while true {
                remindCertificate(model)
                await copyDatabase(model)
                try? await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000)
            }
        }
        if !UserDefaults.standard.bool(forKey: launchSetKey), Bundle.main.bundleURL.path.hasPrefix("/Applications/") {
            UserDefaults.standard.set(true, forKey: launchSetKey)
            setLaunchAtLogin(true)
        }
    }

    /// Once a day while the signing certificate has under 30 days left:
    /// after it expires, CI builds can no longer be installed as updates.
    static func remindCertificate(_ model: AppModel) {
        guard model.updates.signingExpiresSoon, let expiry = model.updates.signingExpiry else { return }
        let key = "certificate.remindedDay"
        let today = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        guard UserDefaults.standard.double(forKey: key) != today else { return }
        UserDefaults.standard.set(today, forKey: key)
        let left = max(Int(expiry.timeIntervalSinceNow / 86400), 0)
        model.notifyDirect?([AlertEvent(serverID: "app", serverName: "Сертификат подписи", key: "certificate", kind: .info,
                                        severity: .warning,
                                        message: "истекает через \(left) дн. Выпустите новый по инструкции docs/signing.md, иначе обновления остановятся",
                                        time: Date())])
    }

    /// A copy of the database once a day, kept for two days, so a damaged
    /// file (a full disk, a crash) loses at most a day.
    static func copyDatabase(_ model: AppModel, now: Date = Date()) async {
        let url = DataFolder.dailyCopy(now)
        if let made = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
           Calendar.current.isDate(made, inSameDayAs: now) { return }
        try? await model.backend.copyDatabase(to: url)
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
