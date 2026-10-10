import Foundation
import HTTPTypes
import HubAccounts
import HubCore
import Hummingbird
import Logging
import NIOCore
import PostgresNIO

/// The hub's one web server: the cabinet for the owner and staff, and every
/// other part's routes (client report links, Telegram setup…). Each part is
/// a `WebModule` listed in monitor-hub's main.swift; the server, the session
/// cookie, error handling and the security headers live here once.
public struct WebConfig: Sendable {
    public var host: String
    public var port: Int
    /// https://hub.example.ru — for links in invites; nil = links relative to
    /// wherever the cabinet was opened.
    public var publicURL: URL?
    /// Folder with the cabinet's index.html, app.js, app.css.
    public var webDir: URL
    /// Behind Caddy (compose): the client's address comes from X-Forwarded-For.
    public var trustProxy: Bool

    public init(host: String = "127.0.0.1", port: Int = 8080, publicURL: URL? = nil, webDir: URL,
                trustProxy: Bool = false) {
        self.host = host; self.port = port; self.publicURL = publicURL; self.webDir = webDir
        self.trustProxy = trustProxy
    }

    /// HUB_HTTP=0.0.0.0:8080 (or "off"), HUB_PUBLIC_URL, HUB_WEB, HUB_TRUST_PROXY=1.
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) throws -> WebConfig? {
        let listen = env["HUB_HTTP"] ?? "off"
        guard listen != "off", !listen.isEmpty else { return nil }
        let parts = listen.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let port = Int(parts[1]) else {
            throw HubConfig.Error("HUB_HTTP должен быть вида 0.0.0.0:8080 или off")
        }
        var url: URL?
        if let u = env["HUB_PUBLIC_URL"], !u.isEmpty {
            guard let parsed = URL(string: u.hasSuffix("/") ? String(u.dropLast()) : u), parsed.scheme == "https"
                    || parsed.host == "localhost" || parsed.host == "127.0.0.1" else {
                throw HubConfig.Error("HUB_PUBLIC_URL должен начинаться с https://")
            }
            url = parsed
        }
        return WebConfig(host: String(parts[0]), port: port, publicURL: url,
                         webDir: URL(fileURLWithPath: env["HUB_WEB"] ?? "/opt/monitor-hub/web"),
                         trustProxy: env["HUB_TRUST_PROXY"] == "1")
    }

    /// Cookies only over HTTPS, unless the hub is opened on this very machine.
    var secureCookies: Bool { publicURL.map { $0.scheme == "https" } ?? false }

    public func link(_ path: String) -> String { (publicURL?.absoluteString ?? "") + path }
}

public struct WebContext: RequestContext {
    public var coreContext: CoreRequestContextStorage
    public let remoteAddress: SocketAddress?

    public init(source: ApplicationRequestContextSource) {
        self.coreContext = .init(source: source)
        self.remoteAddress = source.channel.remoteAddress
    }
}

/// What a module gets to work with.
public struct WebDeps: Sendable {
    public let config: HubConfig
    public let web: WebConfig
    public let db: Database
    public let box: SecretBox?
    public let logger: Logger
    public let accounts: Accounts
    public let access: Access
    public let staff: Staff
    public let preferences: Preferences
    public let overview: Overview
    public let auth: Auth

    public init(config: HubConfig, web: WebConfig, db: Database, logger: Logger,
                now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.config = config; self.web = web; self.db = db; self.logger = logger
        let box = try config.secretKey.map { try SecretBox(key: $0) }
        self.box = box
        let accounts = Accounts(db: db, box: box, now: now)
        self.accounts = accounts
        let access = Access(accounts: accounts)
        self.access = access
        self.staff = Staff(access: access)
        self.preferences = Preferences(accounts: accounts)
        self.overview = Overview(access: access)
        self.auth = Auth(accounts: accounts, web: web)
    }
}

/// A part of the hub with its own routes. Register under /api/<yours>/ for
/// the cabinet's JSON, or a short public path (like /r/<token>) for links.
public protocol WebModule: Sendable {
    func register(_ router: Router<WebContext>, deps: WebDeps)
}

/// Who is asking: the session cookie, the client's address, the fresh code
/// for dangerous actions.
public struct Auth: Sendable {
    public static let cookie = "hub_session"
    /// The code from the phone for one dangerous action.
    public static let codeHeader = HTTPField.Name("X-TOTP")!
    let accounts: Accounts
    let web: WebConfig

    public func ip(_ req: Request, _ ctx: WebContext) -> String? {
        if web.trustProxy, let f = req.headers[HTTPField.Name("X-Forwarded-For")!] {
            let first = f.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) }
            if let first, !first.isEmpty { return first }
        }
        return ctx.remoteAddress?.ipAddress
    }

    public func device(_ req: Request) -> String? { req.headers[.userAgent].map { String($0.prefix(300)) } }

    public func code(_ req: Request) -> String? { req.headers[Self.codeHeader] }

    /// The logged-in person, or nil.
    public func current(_ req: Request, _ ctx: WebContext) async throws -> Actor? {
        guard let token = req.cookies[Self.cookie]?.value, !token.isEmpty,
              let (account, sid) = try await accounts.session(token) else { return nil }
        return Actor(account: account, sessionID: sid, ip: ip(req, ctx), device: device(req))
    }

    /// The logged-in person, or 401 (the cabinet shows the login page).
    public func require(_ req: Request, _ ctx: WebContext) async throws -> Actor {
        guard let a = try await current(req, ctx) else { throw AccountError.unauthorized("Войдите заново") }
        return a
    }

    /// The owner only; with `stepUp` also a fresh code from the phone.
    public func requireOwner(_ req: Request, _ ctx: WebContext, stepUp: Bool = false) async throws -> Actor {
        let a = try await require(req, ctx)
        guard a.account?.isOwner == true else { throw AccountError.forbidden("Это может только владелец") }
        if stepUp { try await accounts.stepUp(a, code: code(req)) }
        return a
    }

    func sessionCookie(_ token: String) -> String {
        "\(Self.cookie)=\(token); Path=/; HttpOnly; SameSite=Strict; Max-Age=\(Int(Lifetimes.sessionAbsolute))"
            + (web.secureCookies ? "; Secure" : "")
    }

    func clearCookie() -> String {
        "\(Self.cookie)=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0" + (web.secureCookies ? "; Secure" : "")
    }
}

/// Responses and request bodies.
public enum Web {
    public static func json(_ text: String, status: HTTPResponse.Status = .ok,
                            cookie: String? = nil) -> Response {
        var headers: HTTPFields = [.contentType: "application/json; charset=utf-8", .cacheControl: "no-store"]
        if let cookie { headers[.setCookie] = cookie }
        return Response(status: status, headers: headers, body: .init(byteBuffer: ByteBuffer(string: text)))
    }

    public static func ok() -> Response { json("{\"ok\":true}") }

    public static func encode<T: Encodable>(_ value: T, cookie: String? = nil) -> Response {
        json(JSON.encode(value), cookie: cookie)
    }

    public static func body<T: Decodable>(_ req: Request, as: T.Type) async throws -> T {
        let buffer = try await req.body.collect(upTo: 256 * 1024)
        do {
            return try JSON.decoder.decode(T.self, from: Data(buffer.readableBytesView))
        } catch {
            throw AccountError.badRequest("Не понял запрос: \(Self.decodingProblem(error))")
        }
    }

    static func decodingProblem(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let k, _): return "нет поля \(k.stringValue)"
        case DecodingError.typeMismatch(_, let c), DecodingError.valueNotFound(_, let c):
            return "поле \(c.codingPath.map(\.stringValue).joined(separator: "."))"
        case DecodingError.dataCorrupted(let c): return c.debugDescription
        default: return "неверный JSON"
        }
    }

    public static func uuid(_ ctx: WebContext, _ name: String = "id") throws -> UUID {
        guard let s = ctx.parameters.get(name), let id = UUID(uuidString: s) else {
            throw AccountError.notFound("Не найдено")
        }
        return id
    }
}

/// Errors as JSON the cabinet shows: {"error": "…", "need_code": true}.
struct ErrorMiddleware: RouterMiddleware {
    typealias Context = WebContext
    let logger: Logger

    func handle(_ req: Request, context: WebContext, next: (Request, WebContext) async throws -> Response) async throws -> Response {
        do {
            return try await next(req, context)
        } catch let e as AccountError {
            let status: HTTPResponse.Status
            switch e {
            case .badRequest: status = .badRequest
            case .unauthorized: status = .unauthorized
            case .forbidden: status = .forbidden
            case .notFound: status = .notFound
            case .needTOTP: status = .preconditionRequired
            case .conflict: status = .conflict
            case .tooMany: status = .tooManyRequests
            case .internal:
                logger.error("\(req.method) \(req.uri.path): \(e)")
                status = .internalServerError
            }
            let needCode = e == .needTOTP ? ",\"need_code\":true" : ""
            return Web.json("{\"error\":\(JSON.string(e.description))\(needCode)}", status: status)
        } catch let e as HTTPError {
            return Web.json("{\"error\":\(JSON.string(e.body ?? e.status.reasonPhrase))}", status: e.status)
        } catch {
            logger.error("\(req.method) \(req.uri.path): \(HubError.describe(error))")
            return Web.json("{\"error\":\"Ошибка на хабе. Подробности в журнале хаба.\"}", status: .internalServerError)
        }
    }
}

/// A page that changes things can only be driven by the cabinet itself:
/// non-GET calls to /api/ need the X-Requested-With header, which another
/// site's form cannot send. Plus headers that keep the cabinet out of frames.
struct SecurityMiddleware: RouterMiddleware {
    typealias Context = WebContext

    func handle(_ req: Request, context: WebContext, next: (Request, WebContext) async throws -> Response) async throws -> Response {
        if req.uri.path.hasPrefix("/api/"), req.method != .get, req.method != .head,
           req.headers[HTTPField.Name("X-Requested-With")!] != "cabinet" {
            return Web.json("{\"error\":\"Запрос отклонён\"}", status: .forbidden)
        }
        var res = try await next(req, context)
        res.headers[HTTPField.Name("X-Content-Type-Options")!] = "nosniff"
        res.headers[HTTPField.Name("X-Frame-Options")!] = "DENY"
        res.headers[HTTPField.Name("Referrer-Policy")!] = "no-referrer"
        if res.headers[HTTPField.Name("Content-Security-Policy")!] == nil {
            res.headers[HTTPField.Name("Content-Security-Policy")!] =
                "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
        }
        return res
    }
}

public struct WebServer: Sendable {
    let config: HubConfig
    let web: WebConfig
    let modules: [any WebModule]
    let logger: Logger

    public init(config: HubConfig, web: WebConfig, modules: [any WebModule], logger: Logger) {
        self.config = config; self.web = web; self.modules = modules; self.logger = logger
    }

    public func router(deps: WebDeps) -> Router<WebContext> {
        let router = Router(context: WebContext.self)
        router.add(middleware: SecurityMiddleware())
        router.add(middleware: ErrorMiddleware(logger: logger))
        router.add(middleware: FileMiddleware(web.webDir.path,
                                              searchForIndexHtml: true, logger: logger))
        router.get("/api/health") { _, _ in Web.json("{\"ok\":true,\"version\":\(JSON.string(HubVersion.current))}") }
        for m in modules { m.register(router, deps: deps) }
        return router
    }

    /// Runs until the process is told to stop (SIGTERM, SIGINT).
    public func run() async throws {
        let db = Database(config, logger: logger)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await db.run() }
            group.addTask {
                // The hub's main loop migrates too; the advisory lock makes the second a no-op.
                try await Migrator.migrate(db, dir: config.migrationsDir)
                try await Partitions.ensure(db, now: Date())
                let deps = try WebDeps(config: config, web: web, db: db, logger: logger)
                let app = Application(router: router(deps: deps),
                                      configuration: .init(address: .hostname(web.host, port: web.port),
                                                           serverName: "monitor-hub"),
                                      logger: logger)
                logger.info("web cabinet on \(web.host):\(web.port)")
                try await app.runService()
            }
            try await group.next()
            group.cancelAll()
        }
    }
}
