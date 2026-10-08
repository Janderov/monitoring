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
    /// The map fills the screen: no sidebar, no toolbar, no panels.
    @Published public var wallMode = false
    /// Admin key (Rutoken) state; nil until the backend has started.
    @Published public private(set) var admin: AdminLockStatus?
    /// Keeps the lock screen up after unlocking, while it asks to change the
    /// factory PIN.
    @Published public var holdLockScreen = false
    /// A recovery code made by the last unlock, shown once on the lock
    /// screen. Kept here rather than in the view so a redraw cannot lose it.
    @Published public var pendingRecoveryCode: String?

    public let backend: MonitorBackend
    /// Posts a notification that does not come from the poller (the morning
    /// summary); redacted while the app is locked, as alerts are.
    var notifyDirect: (@Sendable ([AlertEvent]) -> Void)?
    public let locations: ServerLocations
    public let updates: UpdateModel
    /// This Mac's own connections to the servers, for the map.
    public let mac = MacLinksModel()
    /// Country and network of addresses outside the app, for grey map pins.
    let external = ExternalOwners(lookup: IPLookup())
    /// Checks from this Mac to each server, for the map.
    public let probes = MacProbeModel()
    /// Which server each site runs on, for the map.
    let siteHosts = SiteHostsModel()
    /// The map's "Разбор" tools: checks from Russian cities, where packets
    /// are lost, VPN clients' cities, what runs out soon.
    let cityChecks = CityCheckModel()
    let traces = TraceModel()
    let clientCities = ClientCities()
    let soon = SoonModel()
    /// Traffic of every VPN peer, from the counters in consecutive snapshots.
    @Published public private(set) var peerRates = RateMeter()

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
        let gate = LockGate()
        // Until the lock reports in, a key set up earlier means locked.
        gate.set(AppModel.keySetUp())
        // Locked: say that something happened, never which server or what.
        let post: @Sendable ([AlertEvent]) -> Void = { events in
            notify(gate.isLocked ? events.map(LockGate.redact) : events)
        }
        self.init(backend: LocalBackend(notify: post), gate: gate)
        notifyDirect = post
    }

    public convenience init(backend: MonitorBackend) {
        self.init(backend: backend, gate: LockGate())
    }

    init(backend: MonitorBackend, gate: LockGate) {
        self.lockGate = gate
        self.keyAtLaunch = AppModel.keySetUp()
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
                    var rates = self.peerRates
                    let fed = rates.add(list)
                    rates.keep(fed)
                    self.peerRates = rates
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
        if let lock = backend.adminLock {
            admin = await lock.status()
            noteLock(admin)
            await lock.setOnChange { [unowned self] status in
                Task { @MainActor in
                    self.admin = status
                    self.noteLock(status)
                }
            }
            // Site logins sealed while locked reach the agents after unlock.
            await lock.setOnSecretsOpened { [unowned self] in
                Task { @MainActor in
                    self.updates.refresh()
                    await self.reload()
                }
            }
        }
        await reload()
        Task { await MorningDigest.checkLoop(self) }
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

    public func setRefreshInterval(_ seconds: TimeInterval) {
        Task { await backend.setRefreshInterval(seconds) }
    }

    /// Single permission check for every button. The rules live in the
    /// core's Access; today the only user is the owner.
    public func can(_ action: UserAction, _ server: ServerConfig? = nil) -> Bool {
        // Locked by the admin key: nothing is shown, so nothing can be done.
        if showsLockScreen { return false }
        return Access.can(.owner, action, server.map(ObjectRef.server))
    }

    /// An admin key is set up and not unlocked right now.
    public var isLocked: Bool { admin?.state == .locked }

    /// Nothing but «Вставьте ваш токен» is shown: no servers, no data.
    /// Before the backend has started, a key set up earlier counts as locked,
    /// so data never flashes on screen at launch.
    public var showsLockScreen: Bool {
        isLocked || holdLockScreen || pendingRecoveryCode != nil || (admin == nil && keyAtLaunch)
    }

    private let keyAtLaunch: Bool

    static func keySetUp() -> Bool { (try? KeychainSecrets().get(SecretKey.adminKey)) != nil }

    /// Read by the notification path, which runs off the main thread.
    let lockGate: LockGate

    private func noteLock(_ status: AdminLockStatus?) {
        let locked = status?.state == .locked
        lockGate.set(locked)
        // The GitHub token is sealed: it becomes readable only after unlock.
        updates.refresh()
        // Forms show server details; close them when the token goes.
        if locked { sheet = nil }
    }

    public func lockNow() {
        Task { await backend.adminLock?.lock() }
    }

    /// Settings open as a section of the main window.
    public func showSettings() {
        filter = nil
        section = .settings
    }

    public func status(_ id: String) -> ServerStatus? { statuses.first { $0.id == id } }

    // MARK: Actions

    /// Opens Terminal with an SSH session, with the server's saved SSH user,
    /// port and key (or its ~/.ssh/config block). When this network closes
    /// the server's SSH port, the session goes through another of our servers
    /// that is reachable, and Terminal says so.
    public func openSSH(_ server: ServerConfig) {
        guard can(.ssh, server) else { return }
        let config = SSHConfigFile.entries()
        let target = sshTarget(server, config: config)
        // Servers whose agent reaches this one go first.
        let rest = statuses.filter { $0.id != server.id }
        let reaching = rest.filter { s in s.snapshot?.checks?.contains { $0.id == server.peerCheckID && $0.ok } == true }
        let others = (reaching + rest.filter { s in !reaching.contains { $0.id == s.id } })
            .map { (status: $0, target: sshTarget($0.server, config: config)) }
        let port = { (t: SSHTarget) in t.port ?? config.first { $0.alias == t.host }?.port ?? 22 }
        let backend = backend
        Task {
            var jump: (name: String, target: SSHTarget)?
            let direct = await Self.reachable(server.host, port(target))
            if !direct {
                for o in others {
                    if await Self.reachable(o.status.server.host, port(o.target)) {
                        jump = (o.status.server.name, o.target)
                        break
                    }
                }
            }
            var lines = ["clear"]
            if let jump {
                lines.append("echo " + TerminalSSH.quote("Из этой сети порт SSH сервера «\(server.name)» закрыт, захожу через «\(jump.name)»."))
            }
            if !direct, jump == nil {
                lines.append("echo " + TerminalSSH.quote("Порт SSH сервера «\(server.name)» не отвечает из этой сети, а обойти через другой сервер не получилось. Пробую напрямую."))
            }
            lines.append("exec " + TerminalSSH.command(target, jump: jump?.target))
            Self.runInTerminal(lines, name: "ssh-\(server.id)")
            let how = jump.map { " через \($0.name)" } ?? ""
            _ = try? await backend.audited(.ssh, on: .server(server), detail: "\(target.user ?? "")@\(target.host)\(how)") {}
        }
    }

    private func sshTarget(_ server: ServerConfig, config: [SSHConfigEntry]) -> SSHTarget {
        let d = UserDefaults.standard
        let user = d.string(forKey: "sshUser.\(server.id)") ?? d.string(forKey: "sshUser.default") ?? "root"
        return TerminalSSH.target(for: server, user: user, config: config)
    }

    private nonisolated static func reachable(_ host: String, _ port: Int) async -> Bool {
        await Task.detached { MacProbeModel.connectTime(host: host, port: port, timeout: 3) != nil }.value
    }

    /// A .command file opens in Terminal, which needs no permission to
    /// control other apps. It lives in this user's private temporary folder.
    private static func runInTerminal(_ lines: [String], name: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".command")
        let text = "#!/bin/zsh\n" + lines.joined(separator: "\n") + "\n"
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch { return }
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    public func copyAddress(_ server: ServerConfig) {
        guard !showsLockScreen else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(server.host, forType: .string)
    }

    // MARK: Editing

    public var siteConfigs: [SiteConfig] { siteStatuses.map(\.site) }

    /// Opens the add/edit form in the main window (also from the menu bar).
    public func present(_ sheet: EditSheet) {
        guard !showsLockScreen else { return }
        self.sheet = sheet
    }

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
    case addServer, editServer(String), reinstallAgent(String), updateAgents, addSite, editSite(String)
    /// Add server with the address already filled in (an unknown node on the map).
    case addServerAt(String)
    /// Server id and container name.
    case restartContainer(String, String), rebootServer(String)
    public var id: String {
        switch self {
        case .addServer: return "add-server"
        case .addServerAt(let host): return "add-server-\(host)"
        case .editServer(let id): return "server-\(id)"
        case .reinstallAgent(let id): return "reinstall-\(id)"
        case .updateAgents: return "update-agents"
        case .addSite: return "add-site"
        case .editSite(let id): return "site-\(id)"
        case .restartContainer(let id, let c): return "restart-\(id)-\(c)"
        case .rebootServer(let id): return "reboot-\(id)"
        }
    }
}

public enum AppSection: Hashable, Sendable {
    case overview, map, problems, servers, sites, vpn, journal, settings
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
/// Whether the app is locked, for code that runs off the main thread.
final class LockGate: @unchecked Sendable {
    private let lock = NSLock()
    private var locked = false

    var isLocked: Bool { lock.withLock { locked } }
    func set(_ value: Bool) { lock.withLock { locked = value } }

    static func redact(_ e: AlertEvent) -> AlertEvent {
        var r = e
        r.serverID = "locked"
        r.serverName = "Монитор"
        r.key = "locked"
        r.message = "есть изменения, вставьте токен, чтобы посмотреть"
        return r
    }
}
#endif
