#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import MonitorCore
import SwiftUI

/// Owns the poller and turns its callbacks into UI state. Notifications are
/// delivered through `notify` so this module stays free of UserNotifications.
@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var statuses: [ServerStatus] = []
    @Published public private(set) var configError: String?

    public private(set) var store: Store?
    private var poller: Poller?
    private let notify: @Sendable ([AlertEvent]) -> Void

    public var overall: ServerStatus.Level {
        if configError != nil { return .warning }
        return statuses.map(\.level).max() ?? .unknown
    }

    public init(notify: @escaping @Sendable ([AlertEvent]) -> Void) {
        self.notify = notify
        Task { await start() }
    }

    private func start() async {
        do {
            try DataFolder.prepare()
            let store = try Store(path: DataFolder.database.path)
            let poller = Poller(
                client: AgentClient(transport: PinnedTransport()), store: store,
                // The model lives as long as the app, so unowned is safe here.
                onUpdate: { [unowned self] list in Task { @MainActor in self.statuses = list } },
                onEvents: notify)
            self.store = store
            self.poller = poller
            await reload()
            await poller.start()
        } catch {
            configError = "Не удалось открыть данные: \(error)"
        }
    }

    /// Re-reads servers.json and polls right away.
    public func reload() async {
        guard let poller else { return }
        do {
            let file = try ServersFile.load(from: DataFolder.serversFile)
            configError = nil
            await poller.setServers(file.servers)
            await poller.pollAll(now: Date())
        } catch {
            configError = "servers.json: \(error)"
        }
    }

    public func openConfig() { NSWorkspace.shared.open(DataFolder.serversFile) }
    public func openDataFolder() { NSWorkspace.shared.open(DataFolder.url) }
}
#endif
