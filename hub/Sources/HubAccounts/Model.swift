import Foundation

/// What went wrong, in words the cabinet can show as is.
public enum AccountError: Error, CustomStringConvertible, Sendable, Equatable {
    case badRequest(String)
    /// Not logged in, or the login has ended.
    case unauthorized(String)
    case forbidden(String)
    case notFound(String)
    /// A dangerous action: ask for a fresh code from the phone and try again.
    case needTOTP
    case conflict(String)
    case tooMany(String)
    case `internal`(String)

    public var description: String {
        switch self {
        case .badRequest(let m), .unauthorized(let m), .forbidden(let m), .notFound(let m),
             .conflict(let m), .tooMany(let m), .internal(let m): return m
        case .needTOTP: return "Введите код из приложения на телефоне"
        }
    }
}

public enum AccountKind: String, Codable, Sendable { case owner, staff }
public enum AccountStatus: String, Codable, Sendable { case invited, active, disabled }

public struct Account: Codable, Equatable, Sendable {
    public var id: UUID
    public var login: String
    public var displayName: String
    public var kind: AccountKind
    public var status: AccountStatus
    public var accessExpiresAt: Date?

    public var isOwner: Bool { kind == .owner }

    public init(id: UUID, login: String, displayName: String, kind: AccountKind, status: AccountStatus,
                accessExpiresAt: Date? = nil) {
        self.id = id; self.login = login; self.displayName = displayName
        self.kind = kind; self.status = status; self.accessExpiresAt = accessExpiresAt
    }
}

/// Who is doing something right now, for permission checks and the audit log.
public struct Actor: Sendable {
    public var account: Account?
    public var sessionID: UUID?
    public var ip: String?
    public var device: String?

    public init(account: Account?, sessionID: UUID? = nil, ip: String? = nil, device: String? = nil) {
        self.account = account; self.sessionID = sessionID; self.ip = ip; self.device = device
    }

    /// The hub itself (expired invites, the command line).
    public static let system = Actor(account: nil, device: "хаб")

    var kind: String { account.map { $0.isOwner ? "owner" : "staff" } ?? "system" }
    var name: String { account?.displayName ?? "Хаб" }
}

/// One permission's setting in a grant or a template.
public enum PermissionMode: String, Codable, Sendable, CaseIterable {
    case allow, approval, deny
}

/// Danger level 2 (SSH, reboot, deleting VPN keys, staff…): a fresh code
/// from the phone before each such action.
public enum Danger {
    public static let stepUpLevel = 2
}

/// How long things live.
public enum Lifetimes {
    public static let invite: TimeInterval = 48 * 3600
    public static let loginTicket: TimeInterval = 5 * 60
    public static let sessionAbsolute: TimeInterval = 30 * 24 * 3600
    public static let approval: TimeInterval = 30 * 60
    /// Five wrong passwords or codes in a row lock the login for this long.
    public static let lockout: TimeInterval = 15 * 60
    public static let maxFailures = 5
}
