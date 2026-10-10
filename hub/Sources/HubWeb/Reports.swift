import Foundation
import HTTPTypes
import HubCore
import Hummingbird
import Logging
import NIOCore

/// Clients' monthly report links: GET /r/<token> (the page) and
/// /r/<token>/pdf. No login: the token is the key, and only its SHA-256 is
/// stored. What they answer is HubCore's `ReportWeb`; this only mounts it.
public struct ReportsWebModule: WebModule {
    public init() {}

    public func register(_ router: Router<WebContext>, deps: WebDeps) {
        let store = PostgresReportStore(db: deps.db)
        let pdf = deps.config.pdfURL.map {
            ReportPDF(store: store, filesDir: deps.config.filesDir, render: ReportPDF.gotenberg($0))
        }
        let web = ReportWeb(open: { try await store.open($0) },
                            pdf: pdf.map { p in { @Sendable s in try await p.pdf(s) } }, logger: deps.logger)
        let handler: @Sendable (Request, WebContext) async throws -> Response = { req, _ in
            Self.response(await web.respond(method: req.method == .head ? .HEAD : .GET, uri: req.uri.path))
        }
        router.get("/r/{token}", use: handler)
        router.get("/r/{token}/pdf", use: handler)
    }

    static func response(_ r: ReportWeb.Response) -> Response {
        var headers = HTTPFields()
        headers[.contentType] = r.contentType
        for (k, v) in ReportWeb.securityHeaders + r.headers {
            if let name = HTTPField.Name(k) { headers[name] = v }
        }
        return Response(status: HTTPResponse.Status(code: Int(r.status.code)), headers: headers,
                        body: .init(byteBuffer: ByteBuffer(bytes: r.body)))
    }
}
