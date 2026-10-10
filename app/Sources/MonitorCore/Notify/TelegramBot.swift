import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// MARK: Linking codes

/// The one-time code behind «Подключить Telegram»: the cabinet shows
/// t.me/<bot>?start=<code> as a QR, the bot gets "/start <code>".
/// Only the SHA-256 of the code is stored (ntf.link_code.code_hash).
public enum LinkCode {
    public static let lifetime: TimeInterval = 10 * 60
    static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")

    /// 20 random characters (about 115 bits).
    public static func generate() -> String {
        var rng = SystemRandomNumberGenerator()
        return String((0..<20).map { _ in alphabet.randomElement(using: &rng)! })
    }

    public static func hash(_ code: String) -> Data { Data(SHA256.hash(data: Data(code.utf8))) }

    /// What the cabinet shows; `bot` is the bot's username without "@".
    public static func link(bot: String, code: String) -> URL? {
        URL(string: "https://t.me/\(bot)?start=\(code)")
    }

    /// The shape of a code, checked before touching the database.
    public static func plausible(_ code: String) -> Bool {
        code.count == 20 && code.allSatisfy { alphabet.contains($0) }
    }
}

// MARK: What people send

/// An update from Telegram, read as one thing to do.
public enum BotInput: Equatable, Sendable {
    case start(code: String?)
    case stop
    case status
    case problems
    case settings
    case mute(TimeInterval)
    case help
    case button(BotButton, id: String, callbackID: String, messageID: Int64?)
    /// Anything else (groups, stickers, unknown commands): a short hint at most.
    case other

    /// The longest /mute: a day; longer is done in the cabinet.
    public static let maxMute: TimeInterval = 24 * 3600

    public static func parse(_ u: TelegramUpdate) -> (chat: Int64, user: TelegramUser?, input: BotInput)? {
        if let cb = u.callback_query {
            guard let msg = cb.message, msg.chat.type == "private" else { return nil }
            guard let data = cb.data, let (b, id) = BotButton.parse(data) else {
                return (msg.chat.id, cb.from, .other)
            }
            return (msg.chat.id, cb.from, .button(b, id: id, callbackID: cb.id, messageID: msg.message_id))
        }
        guard let m = u.message else { return nil }
        // Version 1 talks to people only, not to groups.
        guard m.chat.type == "private" else { return nil }
        let words = (m.text ?? "").split(separator: " ").map(String.init)
        // "/status@MyBot" in clients that append the bot's name.
        let cmd = words.first.map { String($0.split(separator: "@").first ?? "").lowercased() } ?? ""
        let input: BotInput
        switch cmd {
        case "/start": input = .start(code: words.count > 1 ? words[1] : nil)
        case "/stop": input = .stop
        case "/status": input = .status
        case "/problems": input = .problems
        case "/settings": input = .settings
        case "/mute": input = .mute(words.count > 1 ? (muteDuration(words[1]) ?? 3600) : 3600)
        case "/help": input = .help
        default: input = .other
        }
        return (m.chat.id, m.from, input)
    }

    /// "30m", "2h", "1d", "2" (hours); capped at a day.
    public static func muteDuration(_ s: String) -> TimeInterval? {
        let t = s.lowercased()
        let units: [(String, TimeInterval)] = [("m", 60), ("м", 60), ("h", 3600), ("ч", 3600), ("d", 86400), ("д", 86400)]
        for (u, k) in units where t.hasSuffix(u) {
            guard let n = Double(t.dropLast(u.count)), n > 0 else { return nil }
            return min(n * k, maxMute)
        }
        guard let n = Double(t), n > 0 else { return nil }
        return min(n * 3600, maxMute)
    }
}

// MARK: Storage

/// A message waiting in ntf.delivery (status queued, due now).
public struct TelegramOutgoing: Equatable, Sendable {
    public var deliveryID: String
    public var chatID: Int64
    public var message: TelegramMessage
    /// Send as a reply to this message (the «решено» under the first alert).
    public var replyTo: Int64?
    /// Edit this message instead of sending a new one.
    public var edit: Int64?
    public var attempts: Int
    /// A new alert that may join others of the same client into one message
    /// (`Notify.bundle`): the client's id, and the problem itself.
    public var bundle: String?
    public var incident: NotifyIncident?
    public init(deliveryID: String, chatID: Int64, message: TelegramMessage, replyTo: Int64? = nil,
                edit: Int64? = nil, attempts: Int = 0, bundle: String? = nil, incident: NotifyIncident? = nil) {
        self.deliveryID = deliveryID; self.chatID = chatID; self.message = message
        self.replyTo = replyTo; self.edit = edit; self.attempts = attempts
        self.bundle = bundle; self.incident = incident
    }
}

/// A message sent before about an incident, to edit when it changes.
public struct TelegramSent: Equatable, Sendable {
    public var chatID: Int64
    public var messageID: Int64
    public var accountID: String
    public init(chatID: Int64, messageID: Int64, accountID: String) {
        self.chatID = chatID; self.messageID = messageID; self.accountID = accountID
    }
}

/// What the hub implements over PostgreSQL. Every method is one short
/// transaction; rights are checked inside (alerts_receive, alerts_ack), so a
/// button pressed in a chat can never reach a client the person has no right to.
public protocol TelegramStore: Sendable {
    // Linking (ntf.telegram_link, ntf.link_code).
    /// Marks the code used and links the chat; nil for an unknown, used or expired code.
    func redeem(codeHash: Data, chatID: Int64, username: String?, now: Date) async throws
        -> (name: String, clients: [String], prefs: NotifyPrefs)?
    /// The account behind an active link.
    func account(chatID: Int64) async throws -> (accountID: String, name: String, prefs: NotifyPrefs)?
    func unlink(chatID: Int64, now: Date) async throws
    /// The bot got 403: stop sending, show «Telegram не доставляется» in the cabinet.
    func markBlocked(chatID: Int64) async throws

    // Problems (ops.incident, ops.incident_ack, ntf.mute).
    /// Records the ack if the account has alerts_ack on the incident's client.
    /// Returns the incident and every message sent about it, to edit; nil without the right.
    func ack(incidentID: String, accountID: String, now: Date) async throws
        -> (incident: NotifyIncident, ack: NotifyAck, sent: [TelegramSent])?
    /// Every open problem of a client (or object) the account may ack.
    func openIncidents(scope: String, accountID: String) async throws -> [String]
    func mute(accountID: String, scope: NotifyMute.Scope, scopeID: String, until: Date?) async throws
    /// A mute on every client the account gets alerts for.
    func muteAll(accountID: String, until: Date) async throws
    /// The latest numbers of the incident's server, if the account may see it.
    func details(incidentID: String, accountID: String) async throws -> TelegramMessage?
    func status(accountID: String) async throws -> [TelegramText.ClientState]
    func problems(accountID: String) async throws -> [NotifyIncident]

    // Outbox (ntf.delivery) and the getUpdates offset (sys.kv).
    /// Queued messages due now, taken with FOR UPDATE SKIP LOCKED.
    func due(now: Date, limit: Int) async throws -> [TelegramOutgoing]
    func sent(deliveryID: String, messageID: Int64?, now: Date) async throws
    /// `retryAt` nil: give up (status failed).
    func failed(deliveryID: String, error: String, retryAt: Date?) async throws
    func offset() async throws -> Int64?
    func setOffset(_ id: Int64) async throws
}

// MARK: The bot

/// Reads what people send and sends what is queued. The hub runs `poll()` in a
/// loop and `flush(now:)` every few seconds; both only talk to Telegram and to
/// the store, so a restart loses nothing.
public actor TelegramBot {
    let api: TelegramBotAPI
    let store: TelegramStore
    let clock: @Sendable () -> Date
    /// Telegram allows about one message a second into one chat.
    public static let perChatGap: TimeInterval = 1
    /// Attempts before a message is given up.
    public static let maxAttempts = 8
    private var lastToChat: [Int64: Date] = [:]

    public init(api: TelegramBotAPI, store: TelegramStore, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.api = api; self.store = store; self.clock = clock
    }

    /// One long poll: waits for updates and handles them.
    public func poll() async throws {
        let offset = try await store.offset()
        for u in try await api.updates(after: offset) {
            try? await handle(u)
            try await store.setOffset(u.update_id)
        }
    }

    public func handle(_ u: TelegramUpdate) async throws {
        guard let (chat, user, input) = BotInput.parse(u) else { return }
        let now = clock()
        if case .start(let code) = input {
            if let code, LinkCode.plausible(code),
               let r = try await store.redeem(codeHash: LinkCode.hash(code), chatID: chat, username: user?.username, now: now) {
                try await reply(chat, TelegramText.linked(name: r.name, clients: r.clients, prefs: r.prefs))
            } else if try await store.account(chatID: chat) != nil {
                try await reply(chat, TelegramText.status(try await statusOf(chat)))
            } else {
                try await reply(chat, code == nil ? TelegramText.closedBot : TelegramText.codeExpired)
            }
            return
        }
        guard let acc = try await store.account(chatID: chat) else {
            if case .button(_, _, let cb, _) = input { try? await api.answer(cb, "Telegram не привязан к кабинету") }
            try await reply(chat, TelegramText.closedBot)
            return
        }
        switch input {
        case .start: break
        case .stop:
            try await store.unlink(chatID: chat, now: now)
            try await reply(chat, TelegramText.unlinked)
        case .status:
            try await reply(chat, TelegramText.status(try await store.status(accountID: acc.accountID)))
        case .problems:
            try await reply(chat, TelegramText.problemsList(try await store.problems(accountID: acc.accountID), now: now))
        case .settings:
            try await reply(chat, TelegramText.settings(acc.prefs))
        case .mute(let d):
            let until = now.addingTimeInterval(d)
            try await store.muteAll(accountID: acc.accountID, until: until)
            try await reply(chat, TelegramText.muted(until: until, tz: acc.prefs.timeZone))
        case .help, .other:
            try await reply(chat, TelegramMessage("/status — мои клиенты\n/problems — что сейчас не так\n/mute 2h — тишина\n/settings — настройки\n/stop — отключить"))
        case .button(let b, let id, let cb, _):
            try await press(b, id: id, callbackID: cb, chat: chat, account: acc, now: now)
        }
    }

    func press(_ b: BotButton, id: String, callbackID: String, chat: Int64,
               account acc: (accountID: String, name: String, prefs: NotifyPrefs), now: Date) async throws {
        switch b {
        case .ack:
            guard let r = try await store.ack(incidentID: id, accountID: acc.accountID, now: now) else {
                try await api.answer(callbackID, TelegramText.noRights); return
            }
            try await api.answer(callbackID, "Взято. Напоминаний больше не будет")
            try await editAll(r.sent, TelegramText.taken(r.incident, by: r.ack, tz: acc.prefs.timeZone, now: now))
        case .ackClient:
            let ids = try await store.openIncidents(scope: id, accountID: acc.accountID)
            guard !ids.isEmpty else { try await api.answer(callbackID, "Открытых проблем нет"); return }
            for i in ids {
                if let r = try await store.ack(incidentID: i, accountID: acc.accountID, now: now) {
                    try await editAll(r.sent, TelegramText.taken(r.incident, by: r.ack, tz: acc.prefs.timeZone, now: now))
                }
            }
            try await api.answer(callbackID, "Взято проблем: \(ids.count)")
        case .snooze:
            try await store.mute(accountID: acc.accountID, scope: .incident, scopeID: id,
                                 until: now.addingTimeInterval(TelegramText.snoozeFor))
            try await api.answer(callbackID, "Эта проблема не будет беспокоить вас час")
        case .details:
            guard let m = try await store.details(incidentID: id, accountID: acc.accountID) else {
                try await api.answer(callbackID, "Нет свежих данных"); return
            }
            try await api.answer(callbackID)
            try await reply(chat, m)
        }
    }

    func editAll(_ sent: [TelegramSent], _ m: TelegramMessage) async throws {
        for s in sent { try? await api.edit(s.chatID, message: s.messageID, m) }
    }

    func statusOf(_ chat: Int64) async throws -> [TelegramText.ClientState] {
        guard let acc = try await store.account(chatID: chat) else { return [] }
        return try await store.status(accountID: acc.accountID)
    }

    func reply(_ chat: Int64, _ m: TelegramMessage) async throws {
        try await api.send(chat, m)
    }

    /// Sends what is due in ntf.delivery, one message a second per chat at most.
    /// Three or more new alerts of one client for one chat go as one list.
    /// Returns how many messages went out.
    @discardableResult
    public func flush(limit: Int = 50) async throws -> Int {
        let now = clock()
        var count = 0
        for group in Self.groups(try await store.due(now: now, limit: limit)) {
            let o = group[0]
            if let last = lastToChat[o.chatID], now.timeIntervalSince(last) < Self.perChatGap {
                continue  // still queued: the next flush takes it
            }
            lastToChat[o.chatID] = now
            let message = group.count > 1 ? TelegramText.bundle(group.compactMap(\.incident)) : o.message
            do {
                var id: Int64? = o.edit
                if let e = o.edit {
                    try await api.edit(o.chatID, message: e, message)
                } else {
                    id = try await api.send(o.chatID, message, replyTo: o.replyTo)
                }
                for m in group { try await store.sent(deliveryID: m.deliveryID, messageID: id, now: now) }
                count += 1
            } catch let e as TelegramError {
                for m in group { try await failed(m, e, now: now) }
                if e == .badToken { throw e }
            }
        }
        return count
    }

    func failed(_ o: TelegramOutgoing, _ e: TelegramError, now: Date) async throws {
        switch e {
        case .blocked:
            try await store.markBlocked(chatID: o.chatID)
            try await store.failed(deliveryID: o.deliveryID, error: e.description, retryAt: nil)
        case .retryAfter(let s):
            try await store.failed(deliveryID: o.deliveryID, error: e.description,
                                   retryAt: now.addingTimeInterval(TimeInterval(s)))
        case .badToken:
            // Every message would fail the same way: keep them queued.
            try await store.failed(deliveryID: o.deliveryID, error: e.description, retryAt: now.addingTimeInterval(300))
        default:
            try await store.failed(deliveryID: o.deliveryID, error: e.description,
                                   retryAt: Self.retry(attempts: o.attempts + 1, now: now))
        }
    }

    /// Due messages in order, with bundles of one client for one chat put together.
    static func groups(_ due: [TelegramOutgoing]) -> [[TelegramOutgoing]] {
        var bundles: [String: [TelegramOutgoing]] = [:]
        for o in due where o.bundle != nil && o.incident != nil { bundles["\(o.chatID)|\(o.bundle!)", default: []].append(o) }
        var taken = Set<String>()
        var out: [[TelegramOutgoing]] = []
        for o in due {
            guard let b = o.bundle, o.incident != nil else { out.append([o]); continue }
            let k = "\(o.chatID)|\(b)"
            let g = bundles[k] ?? [o]
            if g.count < Notify.bundleMin { out.append([o]); continue }
            if taken.insert(k).inserted {
                let incidents = Notify.bundle(g.compactMap(\.incident))[0].map(\.id)
                out.append(incidents.compactMap { id in g.first { $0.incident?.id == id } })
            }
        }
        return out
    }

    /// 10 s, 20 s, 40 s … up to 10 min; nil after `maxAttempts`.
    public static func retry(attempts: Int, now: Date) -> Date? {
        guard attempts < maxAttempts else { return nil }
        return now.addingTimeInterval(min(600, 10 * pow(2, Double(attempts - 1))))
    }
}
