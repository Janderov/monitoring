#if canImport(SwiftUI) && canImport(AppKit)
import Foundation
import MonitorCore

/// The only door from the screens to the "brain". Today it is `LocalBackend`
/// (poller and SQLite inside this app); later a client of the hub on a Mac mini
/// implements the same protocol and the screens stay as they are.
public protocol MonitorBackend: AnyObject, Sendable {
    /// Opens the data and starts polling; `onUpdate` and `onSites` receive the
    /// full lists after every round, `onHealth` whether polling itself works.
    /// The lists themselves are loaded by `reload`.
    func start(onUpdate: @escaping @Sendable ([ServerStatus]) -> Void,
               onSites: @escaping @Sendable ([SiteStatus]) -> Void,
               onHealth: @escaping @Sendable (PollerHealth) -> Void) async throws
    /// Re-reads the server list and polls right away.
    func reload() async throws
    func pollNow() async
    /// A copy of the database, made before an update.
    func copyDatabase(to url: URL) async throws
    /// How often the screens refresh and the agents sample (Poller.refreshChoices).
    func setRefreshInterval(_ seconds: TimeInterval) async
    func samples(_ serverID: String, from: Date, to: Date) async throws -> [Store.Sample]
    func hourly(_ serverID: String, from: Date, to: Date) async throws -> [Store.Hourly]
    func events(limit: Int, serverID: String?) async throws -> [Store.LoggedEvent]
    func siteSamples(_ siteID: String, from: Date, to: Date) async throws -> [Store.SiteSample]
    /// Latency checks from one server to the others (agent ports), oldest first.
    func linkSamples(_ serverID: String, from: Date, to: Date) async throws -> [Store.LinkSample]
    /// Traffic per VPN client (by public key) over the local days touching [from, to].
    func vpnTraffic(_ serverID: String, from: Date, to: Date) async throws -> [String: Store.VPNUsage]
    /// One client's traffic per day, oldest first.
    func vpnDaily(_ serverID: String, publicKey: String, from: Date, to: Date) async throws
        -> [(day: Date, usage: Store.VPNUsage)]

    // Editing the server and site lists. Each change is saved and applied
    // (the poller picks it up) before the call returns.
    func upsertServer(_ server: ServerConfig) async throws
    func removeServer(id: String) async throws
    func upsertSite(_ site: SiteConfig) async throws
    func removeSite(id: String) async throws

    /// False when this build has no agent files to upload; the form then
    /// offers only "the agent is already installed".
    var canInstallAgent: Bool { get }
    /// Installs or upgrades the agent over SSH. `progress` is called off the
    /// main thread. The password is used for this call only.
    func installAgent(_ target: SSHTarget, password: String?, agentPort: Int,
                      progress: @escaping @Sendable (InstallStep, StepState) -> Void) async throws -> InstallResult
    /// SSH password the person chose to keep in Keychain for this server.
    func savedPassword(serverID: String) -> String?
    /// Nil forgets the saved password.
    func setSavedPassword(_ password: String?, serverID: String) throws

    // AmneziaWG keys, over SSH from the Mac. Without a password the saved one
    // (if any) is used, otherwise the SSH key.
    func createVPNKey(server: ServerConfig, container: String, name: String,
                      password: String?) async throws -> AWGNewClient
    func deleteVPNKey(server: ServerConfig, container: String, publicKey: String, name: String,
                      password: String?) async throws

    // Restarts over SSH, with the same password rules; both go to the audit log.
    func restartContainer(server: ServerConfig, container: String, password: String?) async throws
    func rebootServer(server: ServerConfig, password: String?) async throws
    /// Dumps a database container now; returns the file on the server.
    func backupDatabase(server: ServerConfig, container: String, engine: String, password: String?) async throws -> String
    /// Turns the nightly dump of a database container on or off.
    func setNightlyBackup(server: ServerConfig, container: String, engine: String, on: Bool, password: String?) async throws

    /// Checks the permission, runs `body` and writes the outcome to the
    /// audit log ("Журнал действий").
    func audited<T: Sendable>(_ action: UserAction, on object: ObjectRef, detail: String,
                              _ body: @Sendable () async throws -> T) async throws -> T
    func auditLog(limit: Int, objectID: String?) async throws -> [AuditRecord]

    /// Owner login with a hardware key (Rutoken); nil before `start` or when
    /// this backend has none.
    var adminLock: AdminLock? { get }
}

public struct BackendError: LocalizedError {
    public var message: String
    public init(_ m: String) { message = m }
    public var errorDescription: String? { message }
}

/// Poller and Store running in this process.
public final class LocalBackend: MonitorBackend, @unchecked Sendable {
    private let notify: @Sendable ([AlertEvent]) -> Void
    private var store: Store?
    private var poller: Poller?
    private var auditor: Auditor?
    public private(set) var adminLock: AdminLock?
    private let secrets: SecretStore
    private let config: ConfigRepository

    public init(notify: @escaping @Sendable ([AlertEvent]) -> Void, secrets: SecretStore = KeychainSecrets()) {
        self.notify = notify
        self.secrets = secrets
        self.config = ConfigRepository(secrets: secrets)
    }

    public func start(onUpdate: @escaping @Sendable ([ServerStatus]) -> Void,
                      onSites: @escaping @Sendable ([SiteStatus]) -> Void,
                      onHealth: @escaping @Sendable (PollerHealth) -> Void) async throws {
        try DataFolder.prepare()
        let store = try Store(path: DataFolder.database.path)
        let poller = Poller(client: AgentClient(transport: PinnedTransport()), store: store,
                            onUpdate: onUpdate, onEvents: notify)
        self.store = store
        self.poller = poller
        let lock = AdminLock(secrets: secrets, store: store)
        self.adminLock = lock
        self.auditor = Auditor(store: store, lock: lock)
        // Locks again when the token is pulled out or after 15 idle minutes.
        await lock.startWatching()
        await poller.setSitesHandler(onSites)
        await poller.setHealthHandler(onHealth)
        let saved = UserDefaults.standard.double(forKey: Poller.refreshDefaultsKey)
        if saved > 0 { await poller.setRefreshInterval(saved) }
        await poller.start()
    }

    public func reload() async throws {
        guard let poller else { return }
        let file = try await config.load()
        await poller.setConfig(file)
        await poller.pollAll(now: Date())
    }

    public func pollNow() async {
        await poller?.pollAll(now: Date())
    }

    public func copyDatabase(to url: URL) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try await store?.copy(to: url)
    }

    public func setRefreshInterval(_ seconds: TimeInterval) async {
        UserDefaults.standard.set(seconds, forKey: Poller.refreshDefaultsKey)
        await poller?.setRefreshInterval(seconds)
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

    public func linkSamples(_ serverID: String, from: Date, to: Date) async throws -> [Store.LinkSample] {
        try await store?.linkSamples(serverID, from: from, to: to) ?? []
    }

    public func vpnTraffic(_ serverID: String, from: Date, to: Date) async throws -> [String: Store.VPNUsage] {
        try await store?.vpnTraffic(serverID, from: from, to: to) ?? [:]
    }

    public func vpnDaily(_ serverID: String, publicKey: String, from: Date, to: Date) async throws
        -> [(day: Date, usage: Store.VPNUsage)] {
        try await store?.vpnDaily(serverID, publicKey: publicKey, from: from, to: to) ?? []
    }

    // MARK: Editing servers.json

    // ConfigRepository keeps tokens in Keychain, validates and writes
    // atomically with a .bak copy; the poller then gets the new list. Every
    // change goes through the audit log.

    public func upsertServer(_ server: ServerConfig) async throws {
        let isNew = try await config.load().servers.contains { $0.id == server.id } == false
        _ = try await audited(.editConfig, on: .server(server), detail: isNew ? "добавлен" : "изменён") { [config] in
            try await config.upsertServer(server)
        }
        try await reload()
    }

    public func removeServer(id: String) async throws {
        let ref = try await serverRef(id)
        _ = try await audited(.editConfig, on: ref, detail: "удалён") { [config] in
            try await config.removeServer(id: id)
        }
        try await reload()
    }

    public func upsertSite(_ site: SiteConfig) async throws {
        let isNew = try await config.load().sites?.contains { $0.id == site.id } != true
        _ = try await audited(.editConfig, on: .site(site), detail: isNew ? "добавлен" : "изменён") { [config] in
            try await config.upsertSite(site)
        }
        try await reload()
    }

    public func removeSite(id: String) async throws {
        let site = try await config.load().sites?.first { $0.id == id }
        let ref = site.map(ObjectRef.site) ?? ObjectRef(type: .site, id: id, name: id)
        _ = try await audited(.editConfig, on: ref, detail: "удалён") { [config] in
            try await config.removeSite(id: id)
        }
        try await reload()
    }

    private func serverRef(_ id: String) async throws -> ObjectRef {
        let server = try? await config.load().servers.first { $0.id == id }
        return server.map(ObjectRef.server) ?? ObjectRef(type: .server, id: id, name: id)
    }

    // MARK: Audit

    public func audited<T: Sendable>(_ action: UserAction, on object: ObjectRef, detail: String,
                                     _ body: @Sendable () async throws -> T) async throws -> T {
        guard let auditor else {
            guard Access.can(.owner, action, object) else { throw BackendError("нет прав: \(action.title.lowercased())") }
            // Before start the admin key cannot be checked; never skip it.
            if action.needsAdminKey, (try? secrets.get(SecretKey.adminKey)) != nil {
                throw BackendError("приложение ещё запускается, повторите через несколько секунд")
            }
            return try await body()
        }
        return try await auditor.perform(action, on: object, detail: detail, body)
    }

    public func auditLog(limit: Int, objectID: String?) async throws -> [AuditRecord] {
        try await auditor?.recent(limit: limit, objectID: objectID) ?? []
    }

    // MARK: Agent install

    public var canInstallAgent: Bool { AgentBundle.url != nil }

    public func installAgent(_ target: SSHTarget, password: String?, agentPort: Int,
                             progress: @escaping @Sendable (InstallStep, StepState) -> Void) async throws -> InstallResult {
        let ref = ObjectRef(type: .server, id: target.host, name: target.host)
        return try await audited(.installAgent, on: ref, detail: "установка по SSH") {
            let installer = AgentInstaller(client: AgentClient(transport: PinnedTransport()))
            return try await installer.install(target, password: password, agentPort: agentPort, progress: progress)
        }
    }

    public func savedPassword(serverID: String) -> String? {
        try? secrets.get(SecretKey.sshPassword(serverID))
    }

    public func setSavedPassword(_ password: String?, serverID: String) throws {
        let key = SecretKey.sshPassword(serverID)
        if let password, !password.isEmpty { try secrets.set(password, for: key) } else { try secrets.remove(key) }
    }

    // MARK: VPN keys

    private func amnezia(_ server: ServerConfig, _ password: String?) -> AmneziaKeys {
        AmneziaKeys(server: server, password: password ?? savedPassword(serverID: server.id))
    }

    public func createVPNKey(server: ServerConfig, container: String, name: String,
                             password: String?) async throws -> AWGNewClient {
        let keys = amnezia(server, password)
        let ref = ObjectRef.vpnKey(publicKey: "", name: name, on: server)
        let new = try await audited(.manageVPNKeys, on: ref, detail: "создан ключ в \(container)") {
            try await keys.create(container: container, name: name)
        }
        await pollNow()
        return new
    }

    public func deleteVPNKey(server: ServerConfig, container: String, publicKey: String, name: String,
                             password: String?) async throws {
        let keys = amnezia(server, password)
        let ref = ObjectRef.vpnKey(publicKey: publicKey, name: name, on: server)
        try await audited(.manageVPNKeys, on: ref, detail: "удалён ключ из \(container)") {
            try await keys.delete(container: container, publicKey: publicKey)
        }
        await pollNow()
    }

    // MARK: Restarts

    public func restartContainer(server: ServerConfig, container: String, password: String?) async throws {
        let control = ServerControl(server: server, password: password ?? savedPassword(serverID: server.id))
        try await audited(.restart, on: .server(server), detail: "перезапуск контейнера \(container)") {
            try await control.restartContainer(container)
        }
        await pollNow()
    }

    public func rebootServer(server: ServerConfig, password: String?) async throws {
        let control = ServerControl(server: server, password: password ?? savedPassword(serverID: server.id))
        try await audited(.restart, on: .server(server), detail: "перезагрузка сервера") {
            try await control.reboot()
        }
        await poller?.markRebooting(server.id)
    }

    // MARK: Backups

    public func backupDatabase(server: ServerConfig, container: String, engine: String,
                               password: String?) async throws -> String {
        let control = ServerControl(server: server, password: password ?? savedPassword(serverID: server.id))
        let file = try await audited(.backup, on: .server(server), detail: "бэкап базы \(container)") {
            try await control.backup(container: container, engine: engine)
        }
        await pollNow()
        return file
    }

    public func setNightlyBackup(server: ServerConfig, container: String, engine: String, on: Bool,
                                 password: String?) async throws {
        let control = ServerControl(server: server, password: password ?? savedPassword(serverID: server.id))
        try await audited(.backup, on: .server(server),
                          detail: (on ? "включён" : "выключен") + " ночной бэкап базы \(container)") {
            try await control.setNightlyBackup(container: container, engine: engine, on: on)
        }
        await pollNow()
    }
}

#endif
