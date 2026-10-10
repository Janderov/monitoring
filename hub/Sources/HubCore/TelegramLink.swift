import Foundation
import MonitorCore
import PostgresNIO

/// `monitor-hub telegram-link [LOGIN]`: the link the cabinet's «Подключить
/// Telegram» will show, for use before the cabinet exists. Without a login it
/// is the owner's account, made on first use if there is none yet.
public enum TelegramLink {
    public struct Failure: Error, CustomStringConvertible {
        public var description: String
    }

    public static func make(_ db: Database, login: String?, now: Date = Date()) async throws -> String {
        guard let bot = try await db.scalar("SELECT value #>> '{}' FROM sys.kv WHERE key = \(PostgresTelegramStore.usernameKey)",
                                            as: String.self), !bot.isEmpty else {
            throw Failure(description: "хаб ещё не знает имя бота: положите токен в secrets/telegram-bot-token и перезапустите хаб")
        }
        let account: UUID
        if let login {
            guard let a = try await db.scalar("SELECT id FROM acc.account WHERE login = \(login) AND status = 'active'",
                                              as: UUID.self) else {
                throw Failure(description: "нет активной учётной записи \(login)")
            }
            account = a
        } else if let a = try await db.scalar("SELECT id FROM acc.account WHERE kind = 'owner'", as: UUID.self) {
            account = a
        } else {
            let name = ProcessInfo.processInfo.environment["HUB_OWNER_NAME"] ?? "Владелец"
            account = try await db.scalar("""
                INSERT INTO acc.account (login, display_name, kind, status) VALUES ('owner', \(name), 'owner', 'active')
                RETURNING id
                """, as: UUID.self)!
        }
        let code = try await PostgresTelegramStore.newCode(db, account: account, now: now)
        guard let url = LinkCode.link(bot: bot, code: code) else { throw Failure(description: "не получилось собрать ссылку") }
        return """
            Откройте на телефоне в течение 10 минут и нажмите «Старт»:
            \(url.absoluteString)
            """
    }
}
