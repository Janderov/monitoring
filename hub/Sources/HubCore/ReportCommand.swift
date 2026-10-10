import Foundation
import MonitorReports

/// `monitor-hub report …`: the owner's review of monthly reports from the
/// server's command line, until the web cabinet has its screen for it.
/// Nothing here sends anything to a client: `send` gives the owner a link to
/// hand over.
public enum ReportCommand {
    public static let help = """
        monitor-hub report drafts                 черновики, которые ждут проверки
        monitor-hub report make                   сделать черновики, срок которых подошёл (как по расписанию)
        monitor-hub report make КЛИЕНТ [ГГГГ-ММ]  пересобрать черновик клиента за месяц (по умолчанию прошлый)
        monitor-hub report preview ID > файл.html страница черновика, чтобы открыть в браузере
        monitor-hub report comment ID "текст"     ваш комментарий в начале отчёта
        monitor-hub report send ID                утвердить и получить ссылку для клиента
        monitor-hub report link КЛИЕНТ            постоянная ссылка «все мои отчёты»
        monitor-hub report revoke ССЫЛКА          закрыть ссылку
        monitor-hub report signature "Имя Фамилия" ["строка внизу"]   подпись отчётов
        """

    public static func run(_ args: [String], db: Database, config: HubConfig, now: Date = Date()) async throws -> String {
        let store = PostgresReportStore(db: db)
        func id(_ i: Int) throws -> UUID {
            guard args.count > i, let u = UUID(uuidString: args[i]) else { throw HubConfig.Error("укажите id отчёта (из report drafts)") }
            return u
        }
        func url(_ t: ReportToken) -> String { t.url(base: config.publicURL ?? "https://АДРЕС-ХАБА") }

        switch args.first ?? "help" {
        case "drafts":
            let list = try await store.drafts()
            if list.isEmpty { return "черновиков нет" }
            return list.map { "\($0.id.uuidString.lowercased())  \($0.periodStart.prefix(7))  \($0.status ?? "-")  \($0.client)" }
                .joined(separator: "\n")

        case "make":
            if args.count == 1 {
                try await DailyRollup.run(db)
                let made = try await ReportJob.run(store: store, now: now)
                return made.isEmpty ? "новых черновиков нет: срок ни у кого не подошёл или они уже есть"
                    : made.map { "\($0.reportID.uuidString.lowercased())  \($0.clientName)" }.joined(separator: "\n")
            }
            guard let client = try await store.client(named: args[1]) else { throw HubConfig.Error("нет клиента «\(args[1])»") }
            let zone = TimeZone(identifier: try await db.scalar("SELECT timezone FROM inv.client WHERE id = \(client)", as: String.self)
                                ?? "Europe/Moscow") ?? TimeZone(identifier: "Europe/Moscow")!
            let period = try month(args.count > 2 ? args[2] : nil, now: now, timeZone: zone)
            // A new version would hide the sent one: the client's link opens only approved and sent reports.
            if let sent = try await db.scalar("""
                SELECT status FROM rep.client_report
                WHERE client_id = \(client) AND period_start = \(SQLDay(period.start)) AND status IN ('approved','sent')
                """, as: String.self) {
                throw HubConfig.Error("отчёт за \(period.start.prefix(7)) уже \(sent == "sent" ? "отправлен" : "утверждён"): клиент видит его по ссылке")
            }
            try await DailyRollup.run(db)
            guard let input = try await store.input(clientID: client, period: period) else { throw HubConfig.Error("нет клиента") }
            let report = ReportBuilder.build(input, now: now)
            let rid = try await store.saveDraft(clientID: client, period: period, report: report, generatedBy: nil)
            return "\(rid.uuidString.lowercased())  \(period.start.prefix(7))  \(report.status.rawValue)  \(report.headline)"

        case "preview":
            guard let s = try await store.report(try id(1)) else { throw HubConfig.Error("нет такого отчёта") }
            return ReportPage.html(s.report, comment: s.comment, mode: .web(pdfURL: nil), timeZone: s.timeZone, sections: s.sections)

        case "comment":
            guard args.count > 2 else { throw HubConfig.Error("укажите текст комментария") }
            try await store.setComment(try id(1), args[2])
            return "комментарий сохранён"

        case "send":
            guard let token = try await store.send(try id(1), by: nil) else {
                throw HubConfig.Error("это не черновик: уже отправлен или заменён новой версией")
            }
            return "ссылка для клиента (покажется один раз):\n\(url(token))"

        case "link":
            guard args.count > 1, let client = try await store.client(named: args[1]) else { throw HubConfig.Error("укажите клиента") }
            return "постоянная ссылка клиента (покажется один раз):\n\(url(try await store.clientLink(client, by: nil)))"

        case "revoke":
            guard args.count > 1, let token = ReportToken.parse(String(args[1].split(separator: "/").last ?? "")) else {
                throw HubConfig.Error("укажите ссылку целиком")
            }
            return try await store.revoke(token, by: nil) ? "ссылка закрыта" : "такой открытой ссылки нет"

        case "signature":
            guard args.count > 1 else { return "подпись: «\(try await store.signature())»" }
            try await store.setSignature(args[1], footer: args.count > 2 ? args[2] : nil)
            return "подпись: «\(args[1])»"

        default:
            return help
        }
    }

    /// "2026-09" or the month before now.
    static func month(_ text: String?, now: Date, timeZone: TimeZone) throws -> ReportPeriod {
        guard let text else { return ReportPeriod.previousMonth(before: now, timeZone: timeZone) }
        let p = text.split(separator: "-").compactMap { Int($0) }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        guard p.count == 2, let d = cal.date(from: DateComponents(year: p[0], month: p[1], day: 15)) else {
            throw HubConfig.Error("месяц пишется так: 2026-09")
        }
        return ReportPeriod.month(containing: d, timeZone: timeZone)
    }
}
