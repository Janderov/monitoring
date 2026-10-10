import Foundation
import Logging
import MonitorReports
import NIOHTTP1

/// What a client's link answers (mounted on the hub's web server by
/// HubWeb's `ReportsWebModule`):
///   GET /r/<token>      the report page
///   GET /r/<token>/pdf  the same as PDF
/// Anything else under /r/, and any link that is unknown, expired, revoked or points
/// at a draft, gets the same «not found» page: a link can't be probed.
public struct ReportWeb: Sendable {
    public struct Response: Sendable {
        public var status: HTTPResponseStatus
        public var contentType: String
        public var body: Data
        public var headers: [(String, String)] = []
    }

    public typealias Open = @Sendable (ReportToken) async throws -> PostgresReportStore.Stored?
    public typealias PDF = @Sendable (PostgresReportStore.Stored) async throws -> Data

    let open: Open
    let pdf: PDF?
    let logger: Logger

    public init(open: @escaping Open, pdf: PDF?, logger: Logger) {
        self.open = open
        self.pdf = pdf
        self.logger = logger
    }

    /// No scripts, no outside files, no framing, no referrer: the page is
    /// self-contained and the token in the address goes nowhere else.
    public static let securityHeaders: [(String, String)] = [
        ("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"),
        ("X-Content-Type-Options", "nosniff"),
        ("Referrer-Policy", "no-referrer"),
        ("X-Robots-Tag", "noindex, nofollow"),
        ("Cache-Control", "private, no-store"),
    ]

    public func respond(method: HTTPMethod, uri: String) async -> Response {
        guard method == .GET || method == .HEAD else {
            return message(.methodNotAllowed, "Так нельзя", "Эта страница только для чтения.")
        }
        let path = String(uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // "", "r", token[, "pdf"]
        guard parts.count == 3 || (parts.count == 4 && parts[3] == "pdf"), parts[0].isEmpty, parts[1] == "r",
              let token = ReportToken.parse(parts[2]) else { return notFound }
        do {
            guard let stored = try await open(token) else { return notFound }
            if parts.count == 4 {
                guard let pdf else { return notFound }
                return Response(status: .ok, contentType: "application/pdf", body: try await pdf(stored),
                                headers: [("Content-Disposition", "inline; filename=\"\(ReportPDF.fileName(stored.report))\"")])
            }
            let html = ReportPage.html(stored.report, comment: stored.comment,
                                       mode: .web(pdfURL: pdf == nil ? nil : "/r/\(token.value)/pdf"),
                                       timeZone: stored.timeZone, sections: stored.sections)
            return Response(status: .ok, contentType: "text/html; charset=utf-8", body: Data(html.utf8))
        } catch {
            logger.error("отчёт по ссылке: \(HubError.describe(error))")
            return message(.internalServerError, "Не получилось открыть отчёт",
                           "Попробуйте ещё раз через несколько минут. Если не откроется, напишите нам.")
        }
    }

    var notFound: Response {
        message(.notFound, "Ссылка не действует",
                "Отчёта по этой ссылке нет: возможно, срок ссылки истёк. Попросите прислать новую.")
    }

    func message(_ status: HTTPResponseStatus, _ title: String, _ text: String) -> Response {
        let page = """
            <!doctype html><html lang="ru"><head><meta charset="utf-8">\
            <meta name="viewport" content="width=device-width, initial-scale=1"><meta name="robots" content="noindex">\
            <title>\(title)</title><style>body{margin:0;padding:48px 16px;font:14px/1.5 -apple-system,BlinkMacSystemFont,\
            "Segoe UI",Roboto,Arial,sans-serif;color:#1d1d1f;background:#ececec}main{max-width:480px;margin:0 auto;\
            background:#fff;border:1px solid #e0e0e3;border-radius:10px;padding:24px}h1{font-size:17px;font-weight:600;margin:0 0 8px}\
            p{margin:0;color:#6e6e73}@media (prefers-color-scheme: dark){body{background:#161617;color:#f2f2f7}\
            main{background:#1e1e1f;border-color:#38383a}p{color:#98989d}}</style></head>\
            <body><main><h1>\(title)</h1><p>\(text)</p></main></body></html>
            """
        return Response(status: status, contentType: "text/html; charset=utf-8", body: Data(page.utf8))
    }
}
