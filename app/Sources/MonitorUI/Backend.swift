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

    /// False until the core can install the agent over SSH; the form then
    /// offers only "the agent is already installed".
    var canInstallAgent: Bool { get }
    func installAgent(_ request: InstallRequest) -> AsyncThrowingStream<InstallUpdate, Error>
}

/// Where and how to reach a new server over SSH. The password lives only in
/// memory for the duration of the install.
public struct InstallRequest: Sendable {
    public var host: String
    public var sshPort: Int
    public var user: String
    public var keyPath: String?
    public var password: String?
    public var agentPort: Int

    public init(host: String, sshPort: Int = 22, user: String = "root", keyPath: String? = nil,
                password: String? = nil, agentPort: Int = 9443) {
        self.host = host; self.sshPort = sshPort; self.user = user
        self.keyPath = keyPath; self.password = password; self.agentPort = agentPort
    }
}

public enum InstallStep: String, CaseIterable, Identifiable, Sendable {
    case connect = "Подключение по SSH"
    case upload = "Загрузка агента"
    case install = "Установка"
    case start = "Запуск службы"
    case firewall = "Открытие порта агента"
    case identity = "Токен и отпечаток сертификата"
    case verify = "Проверка связи с Mac"
    public var id: String { rawValue }
}

public enum InstallUpdate: Sendable {
    case running(InstallStep, detail: String?)
    case done(InstallStep, detail: String?)
    /// The agent is up; these go into the new server's config.
    case finished(token: String, fingerprint: String)
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

    // MARK: Editing servers.json

    public func upsertServer(_ server: ServerConfig) async throws {
        try await edit { file in
            if let i = file.servers.firstIndex(where: { $0.id == server.id }) { file.servers[i] = server }
            else { file.servers.append(server) }
        }
    }

    public func removeServer(id: String) async throws {
        try await edit { file in
            file.servers.removeAll { $0.id == id }
            // A site limited to this server would fail validation otherwise.
            file.sites = file.sites?.map { site in
                var s = site
                s.from = s.from?.filter { $0 != id }
                if s.from?.isEmpty == true { s.from = nil }
                return s
            }
        }
    }

    public func upsertSite(_ site: SiteConfig) async throws {
        try await edit { file in
            var sites = file.sites ?? []
            if let i = sites.firstIndex(where: { $0.id == site.id }) { sites[i] = site } else { sites.append(site) }
            file.sites = sites
        }
    }

    public func removeSite(id: String) async throws {
        try await edit { file in
            file.sites?.removeAll { $0.id == id }
        }
    }

    /// Read, change, validate, write atomically (owner-only), then apply.
    private func edit(_ change: (inout ServersFile) -> Void) async throws {
        var file: ServersFile
        do {
            file = try ServersFile.decode(Data(contentsOf: DataFolder.serversFile))
        } catch CocoaError.fileReadNoSuchFile {
            file = ServersFile(servers: [])
        } catch {
            throw BackendError("servers.json не читается, сначала исправьте его: \(error.localizedDescription)")
        }
        // The example written on first launch is not a real server.
        file.servers.removeAll { $0.token.hasPrefix("PASTE") || $0.fingerprint.hasPrefix("PASTE") }
        change(&file)
        try file.validate()
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try e.encode(file)
        let url = DataFolder.serversFile
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("bak")
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: url, to: backup)
        }
        try data.write(to: url, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try await reload()
    }

    // MARK: Agent install

    public var canInstallAgent: Bool { false }

    public func installAgent(_ request: InstallRequest) -> AsyncThrowingStream<InstallUpdate, Error> {
        AsyncThrowingStream { $0.finish(throwing: BackendError("Установка из приложения пока не готова")) }
    }
}

/// Things a person can do. Every button that changes something or reaches a
/// server asks `AppModel.can` first, so roles can be added in one place later.
public enum UserAction: Sendable {
    case view, ssh, manageVPNKeys, installAgent, editConfig
}
#endif
