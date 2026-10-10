import Foundation

extension Notify {
    /// A critical problem nobody took is repeated to the general admin after this long.
    public static let escalateAfter: TimeInterval = 15 * 60
    /// At least this many alerts for one client in one round become a single message.
    public static let bundleMin = 3

    // MARK: Quiet hours

    /// Whether `now` falls in the person's quiet hours. A range that spans
    /// midnight (23:00–08:00) belongs to the day it starts on.
    public static func isQuiet(_ p: NotifyPrefs, now: Date) -> Bool {
        guard let from = p.quietFrom, let to = p.quietTo, from != to else { return false }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = p.timeZone
        let c = cal.dateComponents([.hour, .minute, .weekday], from: now)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        // Calendar weekday: 1 = Sunday. ISO: 1 = Monday … 7 = Sunday.
        let today = ((c.weekday ?? 1) + 5) % 7 + 1
        let yesterday = (today + 5) % 7 + 1
        if from < to {
            return minute >= from && minute < to && p.quietDays.contains(today)
        }
        if minute >= from { return p.quietDays.contains(today) }
        if minute < to { return p.quietDays.contains(yesterday) }
        return false
    }

    // MARK: Who gets what

    /// What to do with a message of `kind` about `incident` for one person.
    public static func decide(_ kind: NotifyKind, _ incident: NotifyIncident, for r: NotifyRecipient,
                              acks: [NotifyAck] = [], now: Date) -> NotifyDecision {
        guard r.chatID != nil else { return .skip("Telegram не привязан") }
        if kind == .escalation {
            // Only the general admin; quiet hours and client mutes do not stop it,
            // a mute on this very problem does (he has seen it).
            guard r.isOwner else { return .skip("эскалация только генеральному админу") }
            if r.mutes.contains(where: { $0.scope == .incident && $0.covers(incident, now: now) }) {
                return .skip("заглушено")
            }
            return .send
        }
        if incident.severity < r.prefs.minSeverity { return .skip("ниже порога") }
        if r.mutes.contains(where: { $0.covers(incident, now: now) }) { return .skip("заглушено") }
        // Someone took it: no more reminders for anyone.
        if kind == .reminder && !acks.isEmpty { return .skip("уже взяли") }
        if isQuiet(r.prefs, now: now) {
            if incident.severity == .critical && r.prefs.criticalInQuiet { return .send }
            return .holdForMorning
        }
        return .send
    }

    /// One message for one person, ready for ntf.delivery.
    public struct Planned: Equatable, Sendable {
        public var accountID: String
        public var chatID: Int64
        public var kind: NotifyKind
        public var incidentIDs: [String]
        /// ntf.delivery.dedup_key: the same message is never queued twice.
        public var dedupKey: String
        public var decision: NotifyDecision
        public var message: TelegramMessage

        public init(accountID: String, chatID: Int64, kind: NotifyKind, incidentIDs: [String], dedupKey: String,
                    decision: NotifyDecision, message: TelegramMessage) {
            self.accountID = accountID; self.chatID = chatID; self.kind = kind; self.incidentIDs = incidentIDs
            self.dedupKey = dedupKey; self.decision = decision; self.message = message
        }
    }

    /// The messages one alert event turns into, one per person who should know.
    /// - Parameters:
    ///   - recipients: accounts with alerts_receive on the incident's client.
    ///   - reminder: how many reminders were sent before (ops.incident.reminders),
    ///     so each reminder has its own dedup key.
    public static func plan(_ kind: NotifyKind, _ incident: NotifyIncident, recipients: [NotifyRecipient],
                            acks: [NotifyAck] = [], reminder: Int = 0, notified: [String] = [],
                            now: Date) -> [Planned] {
        recipients.compactMap { r in
            let d = decide(kind, incident, for: r, acks: acks, now: now)
            guard let chat = r.chatID else { return nil }
            if case .skip = d { return nil }
            let n = kind == .reminder ? ":\(reminder + 1)" : ""
            return Planned(accountID: r.accountID, chatID: chat, kind: kind, incidentIDs: [incident.id],
                           dedupKey: "\(kind.rawValue):\(incident.id)\(n):\(r.accountID)", decision: d,
                           message: TelegramText.alert(kind, incident, acks: acks, notified: notified,
                                                       tz: r.prefs.timeZone, now: now))
        }
    }

    // MARK: Bundles

    /// Splits the new alerts of one round for one person into messages: three
    /// or more for the same client become one list, the rest go one by one.
    public static func bundle(_ incidents: [NotifyIncident]) -> [[NotifyIncident]] {
        var groups: [String: [NotifyIncident]] = [:]
        var order: [String] = []
        for i in incidents {
            let k = i.clientID ?? "object:\(i.objectID ?? i.objectName)"
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(i)
        }
        return order.flatMap { k -> [[NotifyIncident]] in
            let g = groups[k]!
            return g.count >= bundleMin ? [g.filter { $0.severity == .critical } + g.filter { $0.severity != .critical }] : g.map { [$0] }
        }
    }

    // MARK: Escalation

    /// An open problem as the escalation check sees it.
    public struct OpenIncident: Sendable {
        public var incident: NotifyIncident
        public var acks: [NotifyAck]
        /// An escalation delivery already exists for it.
        public var escalated: Bool
        /// The names of those who were told, for the message.
        public var notified: [String]
        public init(incident: NotifyIncident, acks: [NotifyAck], escalated: Bool, notified: [String]) {
            self.incident = incident; self.acks = acks; self.escalated = escalated; self.notified = notified
        }
    }

    /// Critical problems open for `escalateAfter` that nobody took and that were
    /// not escalated yet.
    public static func escalations(_ open: [OpenIncident], now: Date) -> [OpenIncident] {
        open.filter {
            $0.incident.severity == .critical && $0.incident.endedAt == nil && $0.acks.isEmpty
                && !$0.escalated && now.timeIntervalSince($0.incident.startedAt) >= escalateAfter
        }
    }

    // MARK: Mass outage

    /// More than half of the servers unreachable at once (with at least three
    /// watched) is almost always the hub's own network: one calm message
    /// instead of an alarm per server.
    public static func massOutage(down: Int, total: Int) -> Bool {
        total >= 3 && down * 2 > total
    }
}
