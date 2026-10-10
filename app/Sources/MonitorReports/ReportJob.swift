import Foundation

/// What the hub's database layer provides to the report job (it runs
/// `ReportSQL` and decodes the rows). Kept as a protocol so the job is tested
/// without PostgreSQL and the hub can pick its own driver.
public protocol ReportStore: Sendable {
    /// Clients without a report for the month before `monthStart` (`ReportSQL.dueClients`).
    func dueClients(monthStart: String) async throws -> [DueClient]
    /// All rows for one client and period (`ReportSQL.client` … `ReportSQL.work`); nil when the client is gone.
    func input(clientID: UUID, period: ReportPeriod) async throws -> ReportInput?
    /// `ReportSQL.insertDraft`; returns the new report id.
    func saveDraft(clientID: UUID, period: ReportPeriod, report: ClientReport, generatedBy: UUID?) async throws -> UUID
}

public struct DueClient: Equatable, Sendable {
    public var id: UUID
    public var timeZone: TimeZone
    public var dayOfMonth: Int
    public init(id: UUID, timeZone: TimeZone, dayOfMonth: Int) {
        self.id = id; self.timeZone = timeZone; self.dayOfMonth = dayOfMonth
    }
}

/// Makes the monthly drafts. The hub calls `run` every hour; a client's draft
/// is made once its day has come in the client's own time zone. Drafts always
/// wait for the admin (Mihail's decision 2026-10-10): nothing is sent to a
/// client from here.
public enum ReportJob {
    public struct Made: Equatable, Sendable {
        public var reportID: UUID
        public var clientName: String
        public var status: ClientReport.Status
    }

    public static func run(store: ReportStore, now: Date) async throws -> [Made] {
        // The widest zone decides which month is asked about; each client is then checked in its own zone.
        let utcMonth = ReportPeriod.month(containing: now, timeZone: TimeZone(identifier: "UTC")!)
        var made: [Made] = []
        for c in try await store.dueClients(monthStart: utcMonth.start) {
            let period = ReportPeriod.previousMonth(before: now, timeZone: c.timeZone)
            guard now >= period.dueAt(dayOfMonth: c.dayOfMonth),
                  let input = try await store.input(clientID: c.id, period: period) else { continue }
            let report = ReportBuilder.build(input, now: now)
            let id = try await store.saveDraft(clientID: c.id, period: period, report: report, generatedBy: nil)
            made.append(Made(reportID: id, clientName: report.clientName, status: report.status))
        }
        return made
    }

    /// One line for the admin's Telegram and the app: «Отчёты за сентябрь готовы: 12, у 2 были сбои».
    public static func notice(_ made: [Made], period: ReportPeriod) -> String? {
        guard !made.isEmpty else { return nil }
        let month = Fmt.monthsNominative[(Int(period.start.split(separator: "-")[1]) ?? 1) - 1]
        let troubled = made.filter { $0.status != .ok }.count
        var line = "Отчёты за \(month) готовы: \(made.count). Проверьте и отправьте"
        if troubled > 0 { line += "; сбои были у \(troubled)" }
        return line + "."
    }

    /// `rep.client_report_settings.sections` as page sections. Missing keys mean «on».
    public static func sections(_ json: [String: Bool]) -> Set<ReportPage.Section> {
        var out = Set(ReportPage.Section.allCases)
        let map: [String: ReportPage.Section] = ["summary": .summary, "prevented": .prevented, "uptime": .uptime,
                                                 "incidents": .incidents, "backups": .backups, "work_done": .work_done,
                                                 "forecasts": .forecasts, "recommendations": .forecasts]
        for (k, on) in json where !on { if let s = map[k] { out.remove(s) } }
        return out
    }

    /// The snapshot as stored in `rep.client_report.data`.
    public static func encode(_ r: ClientReport) throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return try e.encode(r)
    }

    public static func decode(_ data: Data) throws -> ClientReport {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(ClientReport.self, from: data)
    }
}
