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
        let url = try await TelegramSettings.link(db, account: account, now: now).url
        return """
            Откройте на телефоне в течение 10 минут и нажмите «Старт»:
            \(url.absoluteString)
            """
    }
}
