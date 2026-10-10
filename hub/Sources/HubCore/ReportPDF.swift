import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import MonitorReports

/// The report as PDF: the same page in print mode, printed by Chromium in the
/// Gotenberg container next to the hub (deploy/docker-compose.yml, service
/// `pdf`; it has no internet and no other job). Made once per version of the
/// page and kept on the hub's disk (`sys.file`), so a client opening the PDF
/// again costs nothing.
public struct ReportPDF: Sendable {
    public typealias Render = @Sendable (String) async throws -> Data

    let store: PostgresReportStore
    let filesDir: URL
    let render: Render

    public init(store: PostgresReportStore, filesDir: URL, render: @escaping Render) {
        self.store = store
        self.filesDir = filesDir
        self.render = render
    }

    public static func html(_ s: PostgresReportStore.Stored) -> String {
        ReportPage.html(s.report, comment: s.comment, mode: .pdf, timeZone: s.timeZone, sections: s.sections)
    }

    /// Where this version of the page is kept: a new comment makes a new file.
    static func key(_ id: UUID, html: String) -> String {
        let digest = SHA256.hash(data: Data(html.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "reports/\(id.uuidString.lowercased())-\(digest).pdf"
    }

    public func pdf(_ s: PostgresReportStore.Stored) async throws -> Data {
        let html = Self.html(s)
        let key = Self.key(s.id, html: html)
        let file = filesDir.appendingPathComponent(key)
        if s.pdfKey == key, let data = try? Data(contentsOf: file), !data.isEmpty { return data }
        let data = try await render(html)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        try await store.setPDF(s.id, key: key, pdf: data)
        return data
    }

    /// A file name the browser offers: «report-2026-09.pdf».
    public static func fileName(_ r: ClientReport) -> String {
        "report-\(r.periodStart.prefix(7)).pdf"
    }

    /// Gotenberg's Chromium route: one HTML file in, PDF out. The page sets
    /// its own A4 size and margins (`@page`).
    public static func gotenberg(_ base: URL, timeout: TimeInterval = 60) -> Render {
        { html in
            let boundary = "monitor-\(UUID().uuidString)"
            var body = Data()
            func field(_ name: String, _ value: String) {
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
            }
            field("preferCssPageSize", "true")
            field("printBackground", "true")
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"index.html\"\r\nContent-Type: text/html; charset=utf-8\r\n\r\n".utf8))
            body.append(Data(html.utf8))
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))

            var req = URLRequest(url: base.appendingPathComponent("forms/chromium/convert/html"), timeoutInterval: timeout)
            req.httpMethod = "POST"
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, data.starts(with: Data("%PDF".utf8)) else {
                throw HubConfig.Error("PDF не получился: Gotenberg ответил \(code)")
            }
            return data
        }
    }
}
