#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import MonitorCore
import SwiftUI

/// UI state over a `MonitorBackend`. Screens read from here and never talk to
/// the poller or the database directly.
@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var statuses: [ServerStatus] = []
    @Published public private(set) var siteStatuses: [SiteStatus] = []
    @Published public private(set) var configError: String?
    /// Time of the last finished polling round, for "опрос 12 с назад".
    @Published public private(set) var lastRound: Date?

    /// Navigation shared by the main window and the menu bar ("open this server").
    @Published public var section: AppSection = .overview
    @Published public var selectedServerID: String?
    @Published public var selectedSiteID: String?
    /// Sidebar filter by group or tag; nil shows everything.
    @Published public var filter: Filter?
    /// The add or edit form shown over the main window.
    @Published public var sheet: EditSheet?

    public let backend: MonitorBackend
    public let locations: ServerLocations
    public let updates: UpdateModel
    /// This Mac's own connections to the servers, for the map.
    public let mac = MacLinksModel()
    /// Country and network of addresses outside the app, for grey map pins.
    let external = ExternalOwners(lookup: IPLookup())

    public var overall: ServerStatus.Level {
        if configError != nil { return .warning }
        return statuses.map(\.level).max() ?? .unknown
    }

    /// Problems across all servers, worst and oldest first.
    public var problems: [Problem] {
        statuses.flatMap { s in s.alerts.map { Problem(status: s, alert: $0) } }
            .sorted { ($0.alert.severity, $1.alert.since) > ($1.alert.severity, $0.alert.since) }
    }

    public convenience init(notify: @escaping @Sendable ([AlertEvent]) -> Void) {
        self.init(backend: LocalBackend(notify: notify))
    }

    public init(backend: MonitorBackend) {
        self.backend = backend
        self.locations = ServerLocations()
        self.updates = UpdateModel(secrets: KeychainSecrets(), backend: backend)
        Task { await start() }
    }

    private func start() async {
        do {
            // The model lives as long as the app, so unowned is safe here.
            try await backend.start(onUpdate: { [unowned self] list in
                Task { @MainActor in
                    self.statuses = list
                    self.lastRound = Date()
                }
            }, onSites: { [unowned self] list in
                Task { @MainActor in self.siteStatuses = list }
            })
        } catch {
            configError = "Не удалось открыть данные: \(describe(error))"
            return
        }
        await reload()
    }

    /// Re-reads servers.json and polls right away.
    public func reload() async {
        do {
            try await backend.reload()
            configError = nil
        } catch {
            configError = "servers.json: \(describe(error))"
        }
    }

    public func pollNow() async { await backend.pollNow() }

    /// Single permission check for every button. The rules live in the
    /// core's Access; today the only user is the owner.
    public func can(_ action: UserAction, _ server: ServerConfig? = nil) -> Bool {
        Access.can(.owner, action, server.map(ObjectRef.server))
    }

    public func status(_ id: String) -> ServerStatus? { statuses.first { $0.id == id } }

    // MARK: Actions

    /// Opens Terminal with an SSH session (Terminal handles ssh:// links).
    public func openSSH(_ server: ServerConfig) {
        guard can(.ssh, server) else { return }
        let user = server.ssh?.user ?? UserDefaults.standard.string(forKey: "sshUser.\(server.id)")
            ?? UserDefaults.standard.string(forKey: "sshUser.default") ?? "root"
        var c = URLComponents()
        c.scheme = "ssh"
        c.user = user
        c.host = server.host
        c.port = server.ssh?.port.flatMap { $0 == 22 ? nil : $0 }
        guard let url = c.url else { return }
        NSWorkspace.shared.open(url)
        let backend = backend
        Task { _ = try? await backend.audited(.ssh, on: .server(server), detail: "\(user)@\(server.host)") {} }
    }

    public func copyAddress(_ server: ServerConfig) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(server.host, forType: .string)
    }

    // MARK: Editing

    public var siteConfigs: [SiteConfig] { siteStatuses.map(\.site) }

    /// Opens the add/edit form in the main window (also from the menu bar).
    public func present(_ sheet: EditSheet) { self.sheet = sheet }

    /// A short readable id for a new server, from its name or address.
    public func newServerID(from text: String) -> String {
        ServersFile(servers: statuses.map(\.server), sites: siteConfigs).newServerID(from: text)
    }

    public func save(server: ServerConfig) async throws {
        try await backend.upsertServer(server)
        configError = nil
    }

    public func delete(server id: String) async throws {
        try await backend.removeServer(id: id)
        if selectedServerID == id { selectedServerID = nil }
        locations.set(nil, for: id)
    }

    public func save(site: SiteConfig) async throws {
        try await backend.upsertSite(site)
        configError = nil
    }

    public func delete(site id: String) async throws {
        try await backend.removeSite(id: id)
        if selectedSiteID == id { selectedSiteID = nil }
    }

    public func openConfig() { NSWorkspace.shared.open(DataFolder.serversFile) }
    public func openDataFolder() { NSWorkspace.shared.open(DataFolder.url) }

    private func describe(_ error: Error) -> String { String(describing: error) }
}

public enum EditSheet: Identifiable, Hashable, Sendable {
    case addServer, editServer(String), reinstallAgent(String), addSite, editSite(String)
    public var id: String {
        switch self {
        case .addServer: return "add-server"
        case .editServer(let id): return "server-\(id)"
        case .reinstallAgent(let id): return "reinstall-\(id)"
        case .addSite: return "add-site"
        case .editSite(let id): return "site-\(id)"
        }
    }
}

public enum AppSection: Hashable, Sendable {
    case overview, map, problems, servers, sites, vpn, journal
}

public enum Filter: Hashable, Sendable {
    case group(String), tag(String)

    func matches(_ s: ServerConfig) -> Bool {
        switch self {
        case .group(let g): return s.group == g
        case .tag(let t): return s.tags?.contains(t) == true
        }
    }
}

extension AppModel {
    /// Statuses after the sidebar filter.
    public var visible: [ServerStatus] {
        guard let filter else { return statuses }
        return statuses.filter { filter.matches($0.server) }
    }

    public var groups: [String] { Array(Set(statuses.compactMap(\.server.group))).sorted() }
    public var tags: [String] { Array(Set(statuses.flatMap { $0.server.tags ?? [] })).sorted() }

    public func show(server id: String) {
        section = .servers
        selectedServerID = id
    }
}

public struct Problem: Identifiable, Sendable {
    public var status: ServerStatus
    public var alert: ActiveAlert
    public var id: String { "\(status.id)|\(alert.key)" }
}
#endif
