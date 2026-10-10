import Foundation
import MonitorCore
import PostgresNIO

/// `monitor-hub telegram-link [LOGIN]`: the link the cabinet's «Подключить
/// Telegram» shows, from the command line. Without a login it
/// is the owner's account.
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
        } else if let a = try await db.scalar("SELECT id FROM acc.account WHERE kind = 'owner' AND status = 'active'",
                                              as: UUID.self) {
            account = a
        } else {
            throw Failure(description: "нет учётной записи владельца: сначала monitor-hub owner-invite и вход в кабинет")
        }
        let url = try await TelegramSettings.link(db, account: account, now: now).url
        return """
            Откройте на телефоне в течение 10 минут и нажмите «Старт»:
            \(url.absoluteString)
            """
    }
}
