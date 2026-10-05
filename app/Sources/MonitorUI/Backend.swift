#if canImport(SwiftUI) && canImport(AppKit)
import Foundation
import MonitorCore

/// The only door from the screens to the "brain". Today it is `LocalBackend`
/// (poller and SQLite inside this app); later a client of the hub on a Mac mini
/// implements the same protocol and the screens stay as they are.
public protocol MonitorBackend: AnyObject, Sendable {
    /// Opens the data and starts polling; `onUpdate` and `onSites` receive the
    /// full lists after every round. The lists themselves are loaded by `reload`.
    func start(onUpdate: @escaping @Sendable ([ServerStatus]) -> Void,
               onSites: @escaping @Sendable ([SiteStatus]) -> Void) async throws
    /// Re-reads the server list and polls right away.
    func reload() async throws
    func pollNow() async
    func samples(_ serverID: String, from: Date, to: Date) async throws -> [Store.Sample]
    func hourly(_ serverID: String, from: Date, to: Date) async throws -> [Store.Hourly]
    func events(limit: Int, serverID: String?) async throws -> [Store.LoggedEvent]
    func siteSamples(_ siteID: String, from: Date, to: Date) async throws -> [Store.SiteSample]
}

/// Poller and Store running in this process.
public final class LocalBackend: MonitorBackend, @unchecked Sendable {
    private let notify: @Sendable ([AlertEvent]) -> Void
    private var store: Store?
    private var poller: Poller?

    public init(notify: @escaping @Sendable ([AlertEvent]) -> Void) {
        self.notify = notify
    }

    public func start(onUpdate: @escaping @Sendable ([ServerStatus]) -> Void,
                      onSites: @escaping @Sendable ([SiteStatus]) -> Void) async throws {
        try DataFolder.prepare()
        let store = try Store(path: DataFolder.database.path)
        let poller = Poller(client: AgentClient(transport: PinnedTransport()), store: store,
                            onUpdate: onUpdate, onEvents: notify)
        self.store = store
        self.poller = poller
        await poller.setSitesHandler(onSites)
        await poller.start()
    }

    public func reload() async throws {
        guard let poller else { return }
        let file = try ServersFile.load(from: DataFolder.serversFile)
        await poller.setConfig(file)
        await poller.pollAll(now: Date())
    }

    public func pollNow() async {
        await poller?.pollAll(now: Date())
    }

    public func samples(_ serverID: String, from: Date, to: Date) async throws -> [Store.Sample] {
        try await store?.samples(serverID, from: from, to: to) ?? []
    }

    public func hourly(_ serverID: String, from: Date, to: Date) async throws -> [Store.Hourly] {
        try await store?.hourly(serverID, from: from, to: to) ?? []
    }

    public func events(limit: Int, serverID: String?) async throws -> [Store.LoggedEvent] {
        try await store?.events(limit: limit, serverID: serverID) ?? []
    }

    public func siteSamples(_ siteID: String, from: Date, to: Date) async throws -> [Store.SiteSample] {
        try await store?.siteSamples(siteID, from: from, to: to) ?? []
    }
}

/// Things a person can do. Every button that changes something or reaches a
/// server asks `AppModel.can` first, so roles can be added in one place later.
public enum UserAction: Sendable {
    case view, ssh, manageVPNKeys, installAgent, editConfig
}
#endif
