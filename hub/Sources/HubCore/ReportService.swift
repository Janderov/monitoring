import Foundation
import Logging
import MonitorCore
import MonitorReports
import PostgresNIO

/// Once an hour: day totals, then the drafts of every client whose report is
/// due (they wait for the owner; nothing goes to a client from here), and one
/// Telegram line to the owner when there are new ones. Each step is a row in
/// sys.job_run. A failed step is logged and tried again next hour: it never
/// stops the checks.
public struct ReportService: HubService {
    public var name: String { "reports" }
    public static let every: TimeInterval = 3600

    public init() {}

    public func run(_ db: Database, logger: Logger) async throws {
        while !Task.isCancelled {
            await Self.tick(db, logger: logger, now: Date())
            try await Task.sleep(nanoseconds: UInt64(Self.every * 1_000_000_000))
        }
    }

    static func tick(_ db: Database, logger: Logger, now: Date) async {
        await job(db, "rollup", logger: logger) {
            let rows = try await DailyRollup.run(db)
            return "{\"rows\":\(rows.values.reduce(0, +))}"
        }
        await job(db, "report", logger: logger) {
            let store = PostgresReportStore(db: db)
            let made = try await ReportJob.run(store: store, now: now)
            if !made.isEmpty {
                if try await store.signature().isEmpty {
                    logger.warning("в отчётах нет подписи: monitor-hub report signature \"Имя Фамилия\"")
                }
                let period = ReportPeriod.previousMonth(before: now, timeZone: TimeZone(identifier: "Europe/Moscow")!)
                if let line = ReportJob.notice(made, period: period) {
                    logger.notice("\(line)")
                    try await store.queueNotice(line, now: now)
                }
            }
            return "{\"made\":\(made.count)}"
        }
    }

    static func job(_ db: Database, _ name: String, logger: Logger, _ body: () async throws -> String) async {
        let started = Date()
        var detail = "{}", failure: String?
        do { detail = try await body() } catch {
            failure = HubError.describe(error)
            logger.error("\(name): \(failure ?? "")")
        }
        _ = try? await db.query("""
            INSERT INTO sys.job_run (job, started_at, finished_at, ok, detail, error)
            VALUES (\(name), \(started), \(Date()), \(failure == nil), \(detail)::jsonb, \(failure))
            """)
    }
}

/// The client link page (`ReportServer` on HUB_HTTP), with PDF when Gotenberg
/// is configured. Until the cabinet's web server takes the /r/ routes over.
/// It must never stop the checks: on an error it waits a minute and binds again.
public struct ReportWebService: HubService {
    public var name: String { "report-links" }
    let config: HubConfig

    public init(config: HubConfig) { self.config = config }

    public func run(_ db: Database, logger: Logger) async throws {
        guard let http = config.http else {
            // Nothing to serve; stay up like the other services.
            while !Task.isCancelled { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
            return
        }
        let web = Self.web(db, config: config, logger: logger)
        while !Task.isCancelled {
            do { try await ReportServer.run(host: http.host, port: http.port, web: web, logger: logger) } catch {
                logger.error("страница отчётов: \(HubError.describe(error))")
            }
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
    }

    public static func web(_ db: Database, config: HubConfig, logger: Logger) -> ReportWeb {
        let store = PostgresReportStore(db: db)
        let pdf = config.pdfURL.map { ReportPDF(store: store, filesDir: config.filesDir, render: ReportPDF.gotenberg($0)) }
        return ReportWeb(open: { try await store.open($0) }, pdf: pdf.map { p in { @Sendable s in try await p.pdf(s) } }, logger: logger)
    }
}
