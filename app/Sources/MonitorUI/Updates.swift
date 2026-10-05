#if canImport(SwiftUI) && canImport(AppKit)
import Foundation
import MonitorCore

/// "Проверить обновления": the newest green build of main from GitHub,
/// downloaded and swapped in by the core's AppUpdater. Checked on launch and
/// every few hours while a token is saved.
@MainActor
public final class UpdateModel: ObservableObject {
    public enum State: Equatable {
        case idle, noToken, checking, upToDate(Date), available(AppUpdate)
        case downloading(AppUpdate), failed(String)
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var hasToken = false

    private let secrets: SecretStore
    static let interval: UInt64 = 6 * 3600

    init(secrets: SecretStore) {
        self.secrets = secrets
        hasToken = token != nil
        if !hasToken { state = .noToken }
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

    /// Empty forgets the token.
    public func setToken(_ value: String) throws {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { try secrets.remove(SecretKey.githubToken) } else { try secrets.set(t, for: SecretKey.githubToken) }
        hasToken = !t.isEmpty
        state = hasToken ? .idle : .noToken
    }

    public func check() async {
        guard let token else { state = .noToken; return }
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
        state = .downloading(update)
        do {
            let u = AppUpdater(token: token)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MonitorUpdate")
            let file = try await u.download(update, into: dir)
            try u.install(file)
        } catch {
            state = .failed(String(describing: error))
        }
    }

    public var statusText: String {
        switch state {
        case .idle: return ""
        case .noToken: return "Нужен токен GitHub"
        case .checking: return "Проверяю…"
        case .upToDate(let d): return "Установлена последняя сборка · проверено \(Fmt.relative(d))"
        case .available(let u): return "Доступно обновление: \(u.title.isEmpty ? u.version : u.title)"
        case .downloading(let u): return "Скачиваю \(Fmt.bytes(UInt64(max(u.sizeBytes, 0))))…"
        case .failed(let e): return e
        }
    }
}
#endif
