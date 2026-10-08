import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension SecretKey {
    /// The ping address of the outside check (healthchecks.io or the like).
    /// Not sealed: the pulse has to go on while the app is locked.
    public static let heartbeat = "heartbeat-url"
}

/// The outside "pulse": after every round that worked the Mac pings a service
/// such as healthchecks.io. When the pings stop (the Mac is off, asleep, has
/// no network or the app hangs) that service sends an email or a Telegram
/// message, so silence itself becomes the alarm.
public enum Heartbeat {
    /// One ping a minute, like the rounds.
    public static let interval: TimeInterval = 60

    /// The address as typed: https only, no login in it.
    public static func parse(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: t), url.scheme?.lowercased() == "https",
              let host = url.host, host.contains("."), url.user == nil, url.password == nil else { return nil }
        return url
    }

    /// What to send after a round. Nil while the Mac has no network: the ping
    /// would not get out, and the silence is what raises the alarm. A
    /// database error or an empty server list is reported at once as a
    /// failure, since the Mac still has network.
    /// The body has counts only, no names or addresses.
    public static func request(_ base: URL, health: PollerHealth, servers: (ok: Int, total: Int),
                               sites: (ok: Int, total: Int)) -> URLRequest? {
        if health.macOffline && health.storeError == nil { return nil }
        var text = "серверы \(servers.ok) из \(servers.total) в норме"
        if sites.total > 0 { text += ", сайты \(sites.ok) из \(sites.total)" }
        var failed = true
        if let error = health.storeError {
            text = "мониторинг не работает: не удаётся записать данные: \(error)"
        } else if servers.total == 0 {
            // An empty list (servers.json unreadable) watches nothing.
            text = "мониторинг не работает: ни одного сервера под наблюдением"
        } else {
            failed = false
        }
        var r = URLRequest(url: failed ? base.appendingPathComponent("fail") : base)
        r.httpMethod = "POST"
        r.timeoutInterval = 15
        r.httpBody = Data(text.utf8)
        r.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        return r
    }
}

extension Heartbeat {
    /// A line in the service's log before the Mac goes to sleep, so the
    /// silence that follows is explained. It does not count as a ping.
    public static func sleepNote(_ base: URL) -> URLRequest {
        var r = URLRequest(url: base.appendingPathComponent("log"))
        r.httpMethod = "POST"
        r.timeoutInterval = 5
        r.httpBody = Data("Мак уходит в сон, проверки на паузе".utf8)
        r.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        return r
    }
}

/// Sends the pings, at most one a minute, and remembers how the last went.
public actor HeartbeatSender {
    public struct State: Equatable, Sendable {
        public var lastSent: Date?
        /// Why the last ping failed; nil when it worked.
        public var error: String?
        public init(lastSent: Date? = nil, error: String? = nil) { self.lastSent = lastSent; self.error = error }
    }

    public typealias Send = @Sendable (URLRequest) async throws -> Int
    private let send: Send
    private var attempted: Date?
    public private(set) var state = State()

    public init(send: @escaping Send = HeartbeatSender.urlSession) { self.send = send }

    public static let urlSession: Send = { request in
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    /// Pings when a minute has passed since the last try; `force` for the
    /// "Проверить" button. Returns the state after it.
    @discardableResult
    public func tick(_ request: URLRequest?, now: Date = Date(), force: Bool = false) async -> State {
        guard let request else { return state }
        if !force, let a = attempted, now.timeIntervalSince(a) < Heartbeat.interval - 5 { return state }
        attempted = now
        do {
            let code = try await send(request)
            if (200..<300).contains(code) {
                state = State(lastSent: now, error: nil)
            } else {
                state.error = code == 404 ? "адрес не найден (404): проверьте ссылку" : "сервис ответил \(code)"
            }
        } catch {
            state.error = "не удалось отправить: \(error.localizedDescription)"
        }
        return state
    }
}
