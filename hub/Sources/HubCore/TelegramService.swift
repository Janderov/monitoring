import Foundation
import Logging
import MonitorCore
import PostgresNIO

/// The Telegram bot as a part of the hub: answers people (long polling, no
/// open ports), sends the queue every two seconds, and once a minute queues
/// escalations and the morning «Прогноз». The token comes from the hub's
/// credentials folder (secrets/telegram-bot-token) or, when that is empty,
/// from the cabinet (sys.secret, sealed); a new token is picked up within a
/// minute. Without a token the service waits.
public struct TelegramService: HubService {
    public let name = "telegram"
    let fileToken: String?
    let box: SecretBox?
    /// How often the token is looked up again.
    public static let recheck: TimeInterval = 60

    public init(config: HubConfig) {
        fileToken = config.telegramToken
        box = config.secretKey.flatMap { try? SecretBox(key: $0) }
    }

    public func run(_ db: Database, logger: Logger) async throws {
        var current: String?
        var bot: Task<Void, Never>?
        defer { bot?.cancel() }
        var said = false
        while !Task.isCancelled {
            let token: String?
            do {
                if let fileToken { token = fileToken } else { token = try await TelegramSettings.storedToken(db, box: box) }
            } catch {
                logger.error("telegram: \(HubError.describe(error))")
                token = current
            }
            if token != current {
                bot?.cancel()
                bot = nil
                current = token
                if let token {
                    bot = Task { await Self.bot(token, db: db, logger: logger) }
                } else if !said {
                    logger.notice("нет токена бота: Telegram выключен")
                }
                said = true
            }
            try? await Task.sleep(nanoseconds: UInt64(Self.recheck * 1_000_000_000))
        }
    }

    static func bot(_ token: String, db: Database, logger: Logger) async {
        let store = PostgresTelegramStore(db: db)
        let api = TelegramBotAPI(transport: URLSessionTelegram(token: token))
        let bot = TelegramBot(api: api, store: store)
        do {
            let name = try await api.me()
            try await store.setUsername(name)
            logger.info("telegram: бот @\(name)")
        } catch {
            logger.error("telegram: \(HubError.describe(error))")
        }
        @Sendable func pause(_ error: Error) async {
            logger.warning("telegram: \(HubError.describe(error))")
            let wait: UInt64 = (error as? TelegramError) == .badToken ? 300 : 5
            try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    do { try await bot.poll() } catch { await pause(error) }
                }
            }
            group.addTask {
                while !Task.isCancelled {
                    do { try await bot.flush() } catch { await pause(error) }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            group.addTask {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    do {
                        try await NotifyQueue.escalate(db, now: Date())
                        try await NotifyQueue.digests(db, now: Date())
                    } catch {
                        logger.error("telegram jobs: \(HubError.describe(error))")
                    }
                }
            }
        }
    }
}

/// What the cabinet's Telegram section calls (the web part owns HTTP, rights
/// and the step-up check before `setToken`).
public enum TelegramSettings {
    /// sys.secret label of the bot token set from the cabinet.
    public static let label = "telegram-bot"

    public struct Status: Codable, Equatable, Sendable {
        public var configured: Bool
        public var username: String?
        public var linked: Bool
        public var chat: String?
        /// The person blocked the bot: messages do not arrive.
        public var blocked: Bool
        public var linkedAt: Date?
    }

    public struct Failure: Error, CustomStringConvertible {
        public var description: String
    }

    public static func status(_ db: Database, account: UUID) async throws -> Status {
        let bot = try await db.scalar("SELECT value #>> '{}' FROM sys.kv WHERE key = \(PostgresTelegramStore.usernameKey)",
                                      as: String.self)
        let configured = try await db.scalar("SELECT count(*) FROM sys.secret WHERE kind = 'api_token' AND label = \(label)",
                                             as: Int64.self) ?? 0 > 0
        var s = Status(configured: configured || bot != nil, username: bot, linked: false, chat: nil, blocked: false, linkedAt: nil)
        for try await (user, blocked, at) in try await db.query("""
            SELECT tg_username, blocked_bot, linked_at FROM ntf.telegram_link WHERE account_id = \(account) AND unlinked_at IS NULL
            """).decode((String?, Bool, Date).self) {
            s.linked = true
            s.linkedAt = at
            s.chat = user.map { "@" + $0 }
            s.blocked = blocked
        }
        return s
    }

    /// The token as typed in the cabinet: checked with Telegram, then sealed
    /// into sys.secret (the old one goes). Returns the bot's username. The
    /// running hub switches to it within a minute.
    public static func setToken(_ db: Database, box: SecretBox, token raw: String,
                                transport: TelegramTransport? = nil) async throws -> String {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.range(of: #"^[0-9]{5,}:[A-Za-z0-9_-]{30,}$"#, options: .regularExpression) != nil else {
            throw Failure(description: "это не похоже на токен от @BotFather (вид 123456789:AA…)")
        }
        let api = TelegramBotAPI(transport: transport ?? URLSessionTelegram(token: token))
        let username: String
        do { username = try await api.me() } catch TelegramError.badToken {
            throw Failure(description: "Telegram не принял этот токен")
        }
        let id = UUID()
        let sealed = try box.seal(token, id: id, kind: "api_token")
        try await db.transaction { conn in
            try await conn.query("DELETE FROM sys.secret WHERE kind = 'api_token' AND label = \(label)", logger: db.logger)
            try await conn.query("""
                INSERT INTO sys.secret (id, kind, ciphertext, nonce, key_version, label)
                VALUES (\(id), 'api_token', \(ByteBuffer(bytes: sealed.ciphertext)), \(ByteBuffer(bytes: sealed.nonce)),
                        \(SecretBox.keyVersion), \(label))
                """, logger: db.logger)
            try await conn.query("""
                INSERT INTO sys.kv (key, value) VALUES (\(PostgresTelegramStore.usernameKey), to_jsonb(\(username)::text))
                ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now()
                """, logger: db.logger)
        }
        return username
    }

    /// The token set from the cabinet, or nil.
    static func storedToken(_ db: Database, box: SecretBox?) async throws -> String? {
        guard let box else { return nil }
        for try await (id, c, n) in try await db.query("""
            SELECT id, ciphertext, nonce FROM sys.secret WHERE kind = 'api_token' AND label = \(label)
            ORDER BY created_at DESC LIMIT 1
            """).decode((UUID, ByteBuffer, ByteBuffer).self) {
            return try box.open(.init(ciphertext: Array(buffer: c), nonce: Array(buffer: n)), id: id, kind: "api_token")
        }
        return nil
    }

    /// «Подключить Telegram»: the t.me link (show it as a QR too) and when it stops working.
    public static func link(_ db: Database, account: UUID, now: Date = Date()) async throws -> (url: URL, expires: Date) {
        guard let bot = try await db.scalar("SELECT value #>> '{}' FROM sys.kv WHERE key = \(PostgresTelegramStore.usernameKey)",
                                            as: String.self), !bot.isEmpty else {
            throw Failure(description: "бот ещё не настроен: сначала токен от @BotFather")
        }
        let code = try await PostgresTelegramStore.newCode(db, account: account, now: now)
        guard let url = LinkCode.link(bot: bot, code: code) else { throw Failure(description: "не получилось собрать ссылку") }
        return (url, now.addingTimeInterval(LinkCode.lifetime))
    }

    /// «Отключить Telegram».
    public static func unlink(_ db: Database, account: UUID, now: Date = Date()) async throws {
        try await db.query("UPDATE ntf.telegram_link SET unlinked_at = \(now) WHERE account_id = \(account) AND unlinked_at IS NULL")
    }
}
