import Foundation

/// Telegram notifications from the 24/7 hub (design: architecture/telegram/design.md).
///
/// Everything here is plain logic with no database: the hub reads rows from
/// PostgreSQL (ntf.*, ops.incident, ops.incident_ack), hands them in as these
/// values and writes back what comes out (rows of ntf.delivery). That keeps the
/// rules testable on Linux in CI, like the alert engine.
public enum Notify {}

/// An open or just-closed problem: a row of ops.incident.
public struct NotifyIncident: Equatable, Codable, Sendable {
    public var id: String
    public var objectType: String        // server, site, vpn_key, domain, hub
    public var objectID: String?
    public var objectName: String
    public var clientID: String?
    public var clientName: String?
    public var key: String
    public var severity: Severity
    public var message: String
    public var startedAt: Date
    public var endedAt: Date?

    public init(id: String, objectType: String = "server", objectID: String? = nil, objectName: String,
                clientID: String? = nil, clientName: String? = nil, key: String, severity: Severity,
                message: String, startedAt: Date, endedAt: Date? = nil) {
        self.id = id; self.objectType = objectType; self.objectID = objectID; self.objectName = objectName
        self.clientID = clientID; self.clientName = clientName; self.key = key; self.severity = severity
        self.message = message; self.startedAt = startedAt; self.endedAt = endedAt
    }
}

/// Personal settings: a row of ntf.prefs.
public struct NotifyPrefs: Equatable, Sendable {
    public var minSeverity: Severity
    public var timeZone: TimeZone
    /// Minutes after midnight; nil for no quiet hours. `from` > `to` spans midnight.
    public var quietFrom: Int?
    public var quietTo: Int?
    /// ISO weekdays (1 = Monday … 7 = Sunday) the quiet hours apply on, by the day they start.
    public var quietDays: Set<Int>
    public var criticalInQuiet: Bool
    public var digestEnabled: Bool
    /// Minutes after midnight for the morning «Прогноз».
    public var digestTime: Int
    /// Three or more alerts for one client within this window become one message.
    public var groupWindow: TimeInterval

    public init(minSeverity: Severity = .warning, timeZone: TimeZone = TimeZone(identifier: "Europe/Moscow")!,
                quietFrom: Int? = nil, quietTo: Int? = nil, quietDays: Set<Int> = Set(1...7),
                criticalInQuiet: Bool = true, digestEnabled: Bool = true, digestTime: Int = 9 * 60,
                groupWindow: TimeInterval = 60) {
        self.minSeverity = minSeverity; self.timeZone = timeZone; self.quietFrom = quietFrom; self.quietTo = quietTo
        self.quietDays = quietDays; self.criticalInQuiet = criticalInQuiet; self.digestEnabled = digestEnabled
        self.digestTime = digestTime; self.groupWindow = groupWindow
    }

    public static let defaults = NotifyPrefs()
}

/// «Не беспокоить»: a row of ntf.mute.
public struct NotifyMute: Equatable, Sendable {
    public enum Scope: String, Sendable { case client, server, site, incident }
    public var scope: Scope
    public var scopeID: String
    /// Nil: until switched off.
    public var until: Date?

    public init(scope: Scope, scopeID: String, until: Date? = nil) {
        self.scope = scope; self.scopeID = scopeID; self.until = until
    }

    func covers(_ i: NotifyIncident, now: Date) -> Bool {
        if let until, until <= now { return false }
        switch scope {
        case .incident: return scopeID == i.id
        case .client: return scopeID == i.clientID
        case .server: return i.objectType == "server" && scopeID == i.objectID
        case .site: return i.objectType == "site" && scopeID == i.objectID
        }
    }
}

/// Someone who may get a message about an incident: an account with the
/// alerts_receive right on the incident's client, as the hub found it.
public struct NotifyRecipient: Equatable, Sendable {
    public var accountID: String
    public var name: String
    /// Active ntf.telegram_link; nil when Telegram is not linked or the bot is blocked.
    public var chatID: Int64?
    public var prefs: NotifyPrefs
    public var mutes: [NotifyMute]
    /// The general admin: gets escalations, even in quiet hours.
    public var isOwner: Bool

    public init(accountID: String, name: String, chatID: Int64?, prefs: NotifyPrefs = .defaults,
                mutes: [NotifyMute] = [], isOwner: Bool = false) {
        self.accountID = accountID; self.name = name; self.chatID = chatID; self.prefs = prefs
        self.mutes = mutes; self.isOwner = isOwner
    }
}

/// Who took the problem: a row of ops.incident_ack.
public struct NotifyAck: Equatable, Sendable {
    public var accountID: String
    public var name: String
    public var at: Date
    public init(accountID: String, name: String, at: Date) { self.accountID = accountID; self.name = name; self.at = at }
}

/// The kinds of ntf.delivery rows this module writes.
public enum NotifyKind: String, Sendable { case fired, reminder, resolved, digest, escalation, bundle, service }

/// What happens to a message for one person.
public enum NotifyDecision: Equatable, Sendable {
    /// Queue it now.
    case send
    /// Quiet hours: keep it for the morning message (ntf.delivery status dropped_quiet).
    case holdForMorning
    /// Muted, below the person's threshold, or no Telegram: nothing to send.
    case skip(String)
}
