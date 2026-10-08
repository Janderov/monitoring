#if canImport(SwiftUI) && canImport(AppKit)
import Foundation
import MonitorCore

/// "Проверить обновления": the newest green build of main from GitHub,
/// downloaded and swapped in by the core's AppUpdater. Checked on launch and
/// every few hours while a token is saved.
@MainActor
public final class UpdateModel: ObservableObject {
    public enum State: Equatable {
        /// `locked`: the token is sealed by the admin key, which is not open.
        case idle, noToken, locked, checking, upToDate(Date), available(AppUpdate)
        case downloading(AppUpdate), failed(String)
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var hasToken = false

    private let secrets: SecretStore
    private let backend: MonitorBackend
    static let interval: UInt64 = 6 * 3600

    init(secrets: SecretStore, backend: MonitorBackend) {
        self.secrets = secrets
        self.backend = backend
        refresh()
        Task { [weak self] in
            while let self {
                if self.hasToken, !self.busy { await self.check() }
                try? await Task.sleep(nanoseconds: Self.interval * 1_000_000_000)
            }
        }
    }

    public var available: AppUpdate? {
        if case .available(let u) = state { return u }
        return nil
    }

    public var busy: Bool {
        switch state {
        case .checking, .downloading: return true
        default: return false
        }
    }

    private var token: String? {
        guard let t = try? secrets.get(SecretKey.githubToken), !t.isEmpty else { return nil }
        return t
    }

    /// Re-reads whether a token is saved. The token is sealed by the admin
    /// key, so at launch it is unreadable until the Rutoken is unlocked; the
    /// app calls this again whenever the lock opens or closes.
    public func refresh() {
        let had = hasToken
        var locked = false
        do {
            hasToken = !((try secrets.get(SecretKey.githubToken)) ?? "").isEmpty
        } catch is SecretsLockedError {
            hasToken = false
            locked = true
        } catch {
            hasToken = false
        }
        if busy { return }
        if !hasToken {
            state = locked ? .locked : .noToken
        } else if state == .noToken || state == .locked {
            state = .idle
        }
        if hasToken && !had { Task { await check() } }
    }

    /// Empty forgets the token.
    public func setToken(_ value: String) throws {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { try secrets.remove(SecretKey.githubToken) } else { try secrets.set(t, for: SecretKey.githubToken) }
        hasToken = !t.isEmpty
        state = hasToken ? .idle : .noToken
    }

    public func check() async {
        guard let token else { refresh(); return }
        state = .checking
        do {
            if let u = try await AppUpdater(token: token).check() { state = .available(u) } else { state = .upToDate(Date()) }
        } catch {
            state = .failed(String(describing: error))
        }
    }

    /// Downloads and installs; the new copy then quits this one.
    public func install() async {
        guard let token, let update = available else { return }
        // macOS runs a quarantined app from Downloads off a read-only copy
        // (App Translocation), so the updater cannot replace it.
        if Bundle.main.bundlePath.contains("/AppTranslocation/") {
            state = .failed("macOS запустила приложение из временной копии, обновить её нельзя. Закройте приложение, перетащите его в Finder в папку «Программы» и запустите оттуда.")
            return
        }
        state = .downloading(update)
        do {
            let u = AppUpdater(token: token)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MonitorUpdate")
            try await backend.audited(.updateApp, on: .app, detail: update.version) {
                let file = try await u.download(update, into: dir)
                try u.install(file)
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    public var statusText: String {
        switch state {
        case .idle: return ""
        case .noToken: return "Нужен токен GitHub"
        case .locked: return "Токен зашифрован ключом администратора: вставьте Рутокен и введите PIN, тогда можно проверить обновления"
        case .checking: return "Проверяю…"
        case .upToDate(let d): return "Установлена последняя сборка · проверено \(Fmt.relative(d))"
        case .available(let u): return "Доступно обновление: \(u.title.isEmpty ? u.version : u.title)"
        case .downloading(let u): return "Скачиваю \(Fmt.bytes(UInt64(max(u.sizeBytes, 0))))…"
        case .failed(let e): return e
        }
    }
}
#endif
