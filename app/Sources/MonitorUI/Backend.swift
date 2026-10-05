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

    /// Checks the permission, runs `body` and writes the outcome to the
    /// audit log ("Журнал действий").
    func audited<T: Sendable>(_ action: UserAction, on object: ObjectRef, detail: String,
                              _ body: @Sendable () async throws -> T) async throws -> T
    func auditLog(limit: Int, objectID: String?) async throws -> [AuditRecord]
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
    private let secrets: SecretStore
    private let config: ConfigRepository

    public init(notify: @escaping @Sendable ([AlertEvent]) -> Void, secrets: SecretStore = KeychainSecrets()) {
        self.notify = notify
        self.secrets = secrets
        self.config = ConfigRepository(secrets: secrets)
    }

    public func start(onUpdate: @escaping @Sendable ([ServerStatus]) -> Void,
                      onSites: @escaping @Sendable ([SiteStatus]) -> Void) async throws {
        try DataFolder.prepare()
        let store = try Store(path: DataFolder.database.path)
        let poller = Poller(client: AgentClient(transport: PinnedTransport()), store: store,
                            onUpdate: onUpdate, onEvents: notify)
        self.store = store
        self.poller = poller
        self.auditor = Auditor(store: store)
        await poller.setSitesHandler(onSites)
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
            guard Access.can(.owner, action, object) else { throw AccessDenied(action: action) }
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
}

#endif
