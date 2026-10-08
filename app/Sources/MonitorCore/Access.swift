import Foundation

/// Groundwork for other admins and VPN client cabinets (docs/future-foundations.md):
/// every change goes through `Auditor.perform`, which asks `Access.can` and
/// writes the audit log. Today there is one person, the owner, who may do
/// everything; roles below are the draft for later and are not offered in the UI.

/// Things a person can do. Raw values are stored in the audit log.
public enum UserAction: String, CaseIterable, Sendable {
    case view
    case ssh
    case installAgent
    case editConfig
    case manageVPNKeys
    /// Restart a container or reboot a server.
    case restart
    /// Dump a database now, or switch its nightly dump on and off.
    case backup
    case updateApp
    /// Give or take away other people's access, set up the admin key.
    case manageAccess
    /// Unlocking the app with the admin key or recovery code.
    case adminLogin

    public var title: String {
        switch self {
        case .view: return "Просмотр"
        case .ssh: return "Вход по SSH"
        case .installAgent: return "Установка агента"
        case .editConfig: return "Изменение настроек"
        case .manageVPNKeys: return "Ключи VPN"
        case .restart: return "Перезапуск"
        case .backup: return "Бэкапы баз"
        case .updateApp: return "Обновление приложения"
        case .manageAccess: return "Управление доступом"
        case .adminLogin: return "Вход администратора"
        }
    }

    /// Needs the admin key once one is set up (see AdminLock): everything,
    /// even looking, except unlocking itself.
    public var needsAdminKey: Bool { self != .adminLogin }
}

public enum Role: String, CaseIterable, Sendable {
    case owner, admin, vpnOperator, viewer

    public var title: String {
        switch self {
        case .owner: return "Владелец"
        case .admin: return "Админ"
        case .vpnOperator: return "Оператор VPN"
        case .viewer: return "Наблюдатель"
        }
    }

    var allowed: Set<UserAction> {
        switch self {
        case .owner: return Set(UserAction.allCases)
        case .admin: return [.view, .ssh, .installAgent, .editConfig, .manageVPNKeys, .restart, .backup]
        case .vpnOperator: return [.view, .manageVPNKeys]
        case .viewer: return [.view]
        }
    }
}

/// A person using the app, or the app itself ("system") for alerts.
public struct AppUser: Equatable, Sendable {
    public var id: String
    public var name: String
    public var role: Role
    /// Projects (server groups) this person may touch; nil means all.
    public var projects: Set<String>?

    public init(id: String, name: String, role: Role = .owner, projects: Set<String>? = nil) {
        self.id = id; self.name = name; self.role = role; self.projects = projects
    }

    /// The person using this Mac.
    public static var owner: AppUser {
        let full = NSFullUserName()
        return AppUser(id: "owner", name: full.isEmpty ? "Владелец" : full, role: .owner)
    }

    public static let system = AppUser(id: "system", name: "Мониторинг", role: .owner)
}

/// What an action is about, by stable id.
public struct ObjectRef: Equatable, Sendable {
    public enum Kind: String, Sendable { case server, site, vpnKey, app }
    public var type: Kind
    public var id: String
    public var name: String
    /// Group of the object, for project-scoped access.
    public var project: String?

    public init(type: Kind, id: String, name: String, project: String? = nil) {
        self.type = type; self.id = id; self.name = name; self.project = project
    }

    public static func server(_ s: ServerConfig) -> ObjectRef {
        ObjectRef(type: .server, id: s.id, name: s.name, project: s.group)
    }

    public static func site(_ s: SiteConfig) -> ObjectRef {
        ObjectRef(type: .site, id: s.id, name: s.name, project: s.group)
    }

    /// A VPN key is identified by its public key and lives on a server.
    public static func vpnKey(publicKey: String, name: String, on server: ServerConfig) -> ObjectRef {
        ObjectRef(type: .vpnKey, id: publicKey, name: "\(name) (\(server.name))", project: server.group)
    }

    public static let app = ObjectRef(type: .app, id: "app", name: "Приложение")
}

public enum Access {
    /// The one place permissions are decided. Screens hide or disable buttons
    /// by asking this, not by their own conditions.
    public static func can(_ actor: AppUser, _ action: UserAction, _ object: ObjectRef? = nil) -> Bool {
        guard actor.role.allowed.contains(action) else { return false }
        if let projects = actor.projects, let object {
            guard let p = object.project, projects.contains(p) else { return false }
        }
        return true
    }
}

public struct AccessDenied: Error, CustomStringConvertible, Sendable {
    public var action: UserAction
    public var description: String { "нет прав: \(action.title.lowercased())" }
}

/// One line of the audit log.
public struct AuditRecord: Equatable, Identifiable, Sendable {
    public enum Result: String, Sendable { case done, failed, denied }

    public var id: String
    public var time: Date
    public var actor: AppUser
    public var action: UserAction
    public var object: ObjectRef
    /// Human-readable specifics, e.g. "ключ «iPhone Миши», 10.8.1.5".
    public var detail: String
    public var result: Result
    public var error: String?
}

/// Runs a change on behalf of a person: checks access, does it, and logs the
/// outcome whether it succeeded, failed or was refused.
public actor Auditor {
    private let store: Store
    private let lock: AdminLock?
    private let now: @Sendable () -> Date

    public init(store: Store, lock: AdminLock? = nil, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.lock = lock
        self.now = now
    }

    public func perform<T: Sendable>(_ action: UserAction, on object: ObjectRef, by actor: AppUser = .owner,
                                     detail: String = "",
                                     _ body: @Sendable () async throws -> T) async throws -> T {
        func log(_ result: AuditRecord.Result, _ error: String? = nil) async {
            let rec = AuditRecord(id: UUID().uuidString, time: now(), actor: actor, action: action, object: object,
                                  detail: detail, result: result, error: error)
            // The change itself matters more than its log line.
            try? await store.addAction(rec)
        }
        guard Access.can(actor, action, object) else {
            await log(.denied)
            throw AccessDenied(action: action)
        }
        if let lock {
            do {
                try await lock.authorize(action)
            } catch {
                await log(.denied, "\(error)")
                throw error
            }
        }
        do {
            let value = try await body()
            await log(.done)
            return value
        } catch {
            await log(.failed, "\(error)")
            throw error
        }
    }

    public func recent(limit: Int = 200, objectID: String? = nil) async throws -> [AuditRecord] {
        try await store.actions(limit: limit, objectID: objectID)
    }
}
