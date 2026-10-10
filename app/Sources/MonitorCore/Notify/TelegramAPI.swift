import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One call to the Bot API; tests substitute a fake.
public protocol TelegramTransport: Sendable {
    /// POSTs `json` to the method and returns the HTTP status and body.
    func post(_ method: String, json: Data, timeout: TimeInterval) async throws -> (Int, Data)
}

/// The real Bot API over HTTPS. The token lives in the hub's secrets and only
/// in this value: it is part of the URL, so neither the URL nor the request is
/// ever logged or put into an error.
public struct URLSessionTelegram: TelegramTransport {
    private let token: String
    private let base: String

    public init(token: String, base: String = "https://api.telegram.org") {
        self.token = token; self.base = base
    }

    public func post(_ method: String, json: Data, timeout: TimeInterval) async throws -> (Int, Data) {
        guard let url = URL(string: "\(base)/bot\(token)/\(method)") else { throw TelegramError.badToken }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.httpBody = json
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch {
            // URLError descriptions can carry the URL, and with it the token.
            throw TelegramError.network((error as? URLError).map { "сеть: код \($0.code.rawValue)" } ?? "сеть недоступна")
        }
    }
}

public enum TelegramError: Error, Equatable, CustomStringConvertible {
    /// 403: the person blocked the bot or deleted the chat.
    case blocked
    /// 429: too many messages; wait this many seconds.
    case retryAfter(Int)
    /// 401/404: the token is wrong or revoked.
    case badToken
    case rejected(Int, String)
    case network(String)

    public var description: String {
        switch self {
        case .blocked: return "пользователь заблокировал бота"
        case .retryAfter(let s): return "Telegram просит подождать \(s) с"
        case .badToken: return "Telegram не принял токен бота: проверьте его в настройках хаба"
        case .rejected(let code, let text): return "Telegram ответил \(code): \(text)"
        case .network(let text): return text
        }
    }
}

// MARK: Updates

public struct TelegramUser: Decodable, Equatable, Sendable {
    public var id: Int64
    public var username: String?
    public var first_name: String?
    public init(id: Int64, username: String? = nil, first_name: String? = nil) {
        self.id = id; self.username = username; self.first_name = first_name
    }
}

public struct TelegramChat: Decodable, Equatable, Sendable {
    public var id: Int64
    public var type: String
    public init(id: Int64, type: String) { self.id = id; self.type = type }
}

public struct TelegramIncoming: Decodable, Equatable, Sendable {
    public var message_id: Int64
    public var chat: TelegramChat
    public var from: TelegramUser?
    public var text: String?
    public init(message_id: Int64, chat: TelegramChat, from: TelegramUser? = nil, text: String? = nil) {
        self.message_id = message_id; self.chat = chat; self.from = from; self.text = text
    }
}

public struct TelegramCallback: Decodable, Equatable, Sendable {
    public var id: String
    public var from: TelegramUser
    public var message: TelegramIncoming?
    public var data: String?
    public init(id: String, from: TelegramUser, message: TelegramIncoming? = nil, data: String? = nil) {
        self.id = id; self.from = from; self.message = message; self.data = data
    }
}

public struct TelegramUpdate: Decodable, Equatable, Sendable {
    public var update_id: Int64
    public var message: TelegramIncoming?
    public var callback_query: TelegramCallback?
    public init(update_id: Int64, message: TelegramIncoming? = nil, callback_query: TelegramCallback? = nil) {
        self.update_id = update_id; self.message = message; self.callback_query = callback_query
    }
}

// MARK: Calls

/// The few Bot API methods the hub uses. Long polling (getUpdates), so the hub
/// needs no public address and opens no ports.
public struct TelegramBotAPI: Sendable {
    let transport: TelegramTransport
    /// How long getUpdates waits for something to arrive.
    public var pollTimeout = 25

    public init(transport: TelegramTransport) { self.transport = transport }

    struct Reply<T: Decodable>: Decodable {
        var ok: Bool
        var result: T?
        var error_code: Int?
        var description: String?
        var parameters: Params?
        struct Params: Decodable { var retry_after: Int? }
    }

    struct Sent: Decodable { var message_id: Int64 }

    func call<T: Decodable>(_ method: String, _ body: [String: Any], timeout: TimeInterval = 15) async throws -> T {
        let json = try JSONSerialization.data(withJSONObject: body)
        let (code, data) = try await transport.post(method, json: json, timeout: timeout)
        let r = try? JSONDecoder().decode(Reply<T>.self, from: data)
        if let r, r.ok, let result = r.result { return result }
        let err = r?.error_code ?? code
        switch err {
        case 403: throw TelegramError.blocked
        case 429: throw TelegramError.retryAfter(r?.parameters?.retry_after ?? 5)
        case 401, 404: throw TelegramError.badToken
        default: throw TelegramError.rejected(err, r?.description ?? "HTTP \(code)")
        }
    }

    static func markup(_ m: TelegramMessage) -> [String: Any]? {
        guard !m.buttons.isEmpty else { return nil }
        return ["inline_keyboard": m.buttons.map { $0.map { ["text": $0.text, "callback_data": $0.data] } }]
    }

    public func updates(after offset: Int64?) async throws -> [TelegramUpdate] {
        var body: [String: Any] = ["timeout": pollTimeout, "allowed_updates": ["message", "callback_query"]]
        if let offset { body["offset"] = offset + 1 }
        return try await call("getUpdates", body, timeout: TimeInterval(pollTimeout + 10))
    }

    /// Returns the new message's id (ntf.delivery.external_id).
    @discardableResult
    public func send(_ chat: Int64, _ m: TelegramMessage, replyTo: Int64? = nil) async throws -> Int64 {
        var body: [String: Any] = ["chat_id": chat, "text": m.text, "parse_mode": "HTML",
                                   "link_preview_options": ["is_disabled": true]]
        if let k = Self.markup(m) { body["reply_markup"] = k }
        if let replyTo { body["reply_parameters"] = ["message_id": replyTo, "allow_sending_without_reply": true] }
        let sent: Sent = try await call("sendMessage", body)
        return sent.message_id
    }

    /// Edits a message sent before; "not modified" is not an error.
    public func edit(_ chat: Int64, message: Int64, _ m: TelegramMessage) async throws {
        var body: [String: Any] = ["chat_id": chat, "message_id": message, "text": m.text, "parse_mode": "HTML",
                                   "link_preview_options": ["is_disabled": true]]
        body["reply_markup"] = Self.markup(m) ?? ["inline_keyboard": [[String: Any]]()]
        do {
            let _: Sent = try await call("editMessageText", body)
        } catch TelegramError.rejected(400, let text) where text.contains("not modified") {
            return
        }
    }

    /// The bot's username, for the t.me link the cabinet shows.
    public func me() async throws -> String {
        struct Me: Decodable { var username: String? }
        let m: Me = try await call("getMe", [:])
        return m.username ?? ""
    }

    /// The small note over the chat after a button press.
    public func answer(_ callbackID: String, _ text: String? = nil) async throws {
        var body: [String: Any] = ["callback_query_id": callbackID]
        if let text { body["text"] = text }
        let _: Bool = try await call("answerCallbackQuery", body)
    }
}
