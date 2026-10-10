import Foundation
import HubAccounts
import HubCore
import Hummingbird

/// The cabinet's Telegram section: is the bot set up, is my Telegram linked,
/// the bot's token (owner, with a fresh code), «Подключить» / «Отключить».
public struct TelegramModule: WebModule {
    public init() {}

    struct StatusBody: Encodable {
        struct Bot: Encodable { var configured: Bool; var username: String? }
        struct Me: Encodable {
            var linked: Bool
            var username: String?
            var blocked: Bool
            var linked_at: Date?
        }
        var bot: Bot
        var me: Me
    }
    struct TokenBody: Decodable { var token: String }
    struct LinkBody: Encodable { var url: String; var expires_at: Date }
    struct BotBody: Encodable { var username: String }

    public func register(_ router: Router<WebContext>, deps d: WebDeps) {
        let audit = Audit(db: d.db)

        router.get("/api/telegram/status") { req, ctx in
            let a = try await d.auth.require(req, ctx)
            guard let id = a.account?.id else { throw AccountError.unauthorized("Войдите заново") }
            let s = try await TelegramSettings.status(d.db, account: id)
            return Web.encode(StatusBody(bot: .init(configured: s.configured, username: s.username),
                                         me: .init(linked: s.linked, username: s.chat, blocked: s.blocked, linked_at: s.linkedAt)))
        }

        router.put("/api/telegram/bot") { req, ctx in
            let a = try await d.auth.requireOwner(req, ctx, stepUp: true)
            guard let box = d.box else { throw AccountError.internal("На хабе нет ключа шифрования") }
            let b = try await Web.body(req, as: TokenBody.self)
            do {
                let name = try await TelegramSettings.setToken(d.db, box: box, token: b.token)
                await audit.write(.init("telegram.bot_token", objectType: "hub", objectName: "@" + name), by: a)
                return Web.encode(BotBody(username: name))
            } catch let e as TelegramSettings.Failure {
                await audit.write(.init("telegram.bot_token", objectType: "hub", result: .failed, error: e.description), by: a)
                throw AccountError.badRequest(e.description)
            }
        }

        router.post("/api/telegram/link") { req, ctx in
            let a = try await d.auth.require(req, ctx)
            guard let id = a.account?.id else { throw AccountError.unauthorized("Войдите заново") }
            do {
                let l = try await TelegramSettings.link(d.db, account: id)
                return Web.encode(LinkBody(url: l.url.absoluteString, expires_at: l.expires))
            } catch let e as TelegramSettings.Failure {
                throw AccountError.conflict(e.description)
            }
        }

        router.delete("/api/telegram/link") { req, ctx in
            let a = try await d.auth.require(req, ctx)
            guard let id = a.account?.id else { throw AccountError.unauthorized("Войдите заново") }
            try await TelegramSettings.unlink(d.db, account: id)
            await audit.write(.init("telegram.unlink", objectType: "account", objectID: id, objectName: a.account?.displayName ?? ""),
                              by: a)
            return Web.ok()
        }
    }
}
