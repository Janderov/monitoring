import Crypto
import Foundation
import NIOCore
import MonitorCore
import MonitorReports
import PostgresNIO

/// Monthly client reports on PostgreSQL: the rows `ReportJob` builds a draft
/// from, the drafts themselves, the admin's review (approve, link, sent) and
/// what a client's link opens. All SQL is MonitorReports' `ReportSQL`.
public struct PostgresReportStore: ReportStore {
    let db: Database

    public init(db: Database) { self.db = db }

    static let utc = TimeZone(identifier: "UTC")!

    @discardableResult
    func rows(_ text: String, _ binds: [(any PostgresEncodable)?]) async throws -> PostgresRowSequence {
        try await db.query(try .sql(text, binds))
    }

    // MARK: ReportStore

    public func dueClients(monthStart: String) async throws -> [DueClient] {
        var out: [DueClient] = []
        for try await (id, zone, day) in try await rows(ReportSQL.dueClients, [SQLDay(monthStart)]).decode((UUID, String, Int).self) {
            out.append(DueClient(id: id, timeZone: TimeZone(identifier: zone) ?? Self.moscow, dayOfMonth: day))
        }
        return out
    }

    static let moscow = TimeZone(identifier: "Europe/Moscow")!

    public func input(clientID: UUID, period p: ReportPeriod) async throws -> ReportInput? {
        let month: [(any PostgresEncodable)?] = [clientID, SQLDay(p.start), SQLDay(p.end), p.from, p.to]

        var head: (name: String, sla: Decimal?, signature: String, footer: String)?
        let clientRows = try await rows(ReportSQL.client, month)
            .decode((String, String, Bool, Int, String, String, Int, String, Decimal?, String, String?).self)
        for try await r in clientRows { head = (r.0, r.8, r.9, r.10 ?? "") }
        guard let head else { return nil }

        var input = ReportInput(clientName: head.name, signature: head.signature, footer: head.footer, period: p,
                                slaTarget: head.sla.map { NSDecimalNumber(decimal: $0 / 100).doubleValue })

        for try await (id, name, _, tls, domain, current) in try await rows(ReportSQL.sites, month)
            .decode((UUID, String, String, Date?, Date?, Bool).self) {
            input.sites.append(.init(id: id, name: name, tlsExpiry: tls, domainExpiry: domain, current: current))
        }
        for try await (id, day, total, ok, down, latency) in try await rows(ReportSQL.siteDays, month)
            .decode((UUID, SQLDay, Int, Int, Int, Float?).self) {
            input.siteDays.append(.init(siteID: id, day: day.value, checksTotal: total, checksOK: ok,
                                        downtimeSeconds: down, latencyAvgMs: latency.map(Double.init)))
        }
        for try await (id, name, _, current) in try await rows(ReportSQL.servers, month).decode((UUID, String, String?, Bool).self) {
            input.servers.append(.init(id: id, name: name, current: current))
        }
        for try await (id, day, cpu, mem, disk, reboots, total, ok) in try await rows(ReportSQL.serverDays, month)
            .decode((UUID, SQLDay, Float?, Float?, Float?, Int, Int, Int).self) {
            input.serverDays.append(.init(serverID: id, day: day.value, cpuMax: cpu.map(Double.init), memMax: mem.map(Double.init),
                                          diskMaxPct: disk.map(Double.init), reboots: reboots, checksTotal: total, checksOK: ok))
        }
        for try await (id, mount, day, used, total) in try await rows(ReportSQL.diskDays, month)
            .decode((UUID, String, SQLDay, Int64, Int64).self) {
            input.diskDays.append(.init(serverID: id, mount: mount, day: day.value, usedBytes: used, totalBytes: total))
        }
        for try await (name, kind, severity, message, started, ended, cause, resolution) in try await rows(ReportSQL.incidents, month)
            .decode((String, String, Int, String, Date, Date?, String?, String?).self) {
            input.incidents.append(.init(objectName: name, kind: kind, severity: severity, message: message, startedAt: started,
                                         endedAt: ended, cause: cause, resolution: resolution))
        }
        for try await (name, id, kind, line, due, first, status, closed, note) in try await rows(ReportSQL.forecasts, month)
            .decode((String, UUID?, String, String, Date?, Date, String, Date?, String?).self) {
            input.forecasts.append(.init(objectName: name, objectID: id, kind: kind, line: line, dueAt: due, firstSeenAt: first,
                                         status: status, closedAt: closed, note: note))
        }
        for try await (server, target, started, ok, size) in try await rows(ReportSQL.backups, month)
            .decode((String, String, Date, Bool, Int64?).self) {
            input.backups.append(.init(serverName: server, target: target, startedAt: started, ok: ok, sizeBytes: size))
        }
        for try await (done, text) in try await rows(ReportSQL.work, month).decode((Date, String).self) {
            input.work.append(.init(doneAt: done, text: text))
        }
        return input
    }

    public func saveDraft(clientID: UUID, period: ReportPeriod, report: ClientReport, generatedBy: UUID?) async throws -> UUID {
        let binds: [(any PostgresEncodable)?] = [clientID, SQLDay(period.start), SQLDay(period.end),
                                              Int32(ClientReport.templateVersion), report.status.rawValue,
                                              JSONB(data: try ReportJob.encode(report)), generatedBy]
        for try await id in try await rows(ReportSQL.insertDraft, binds).decode(UUID.self) { return id }
        throw HubConfig.Error("черновик отчёта не сохранился")
    }

    // MARK: review

    public struct Draft: Sendable {
        public var id: UUID
        public var client: String
        public var periodStart: String
        public var status: String?
    }

    /// Drafts waiting for the admin.
    public func drafts() async throws -> [Draft] {
        var out: [Draft] = []
        for try await (id, client, start, status) in try await rows(ReportSQL.drafts, [])
            .decode((UUID, String, SQLDay, String?).self) {
            out.append(Draft(id: id, client: client, periodStart: start.value, status: status))
        }
        return out
    }

    /// One report as stored, for the admin's preview.
    public struct Stored: Sendable {
        public var id: UUID
        public var report: ClientReport
        public var comment: String
        public var timeZone: TimeZone
        public var sections: Set<ReportPage.Section>
        public var status: String
        public var pdfKey: String?
    }

    public func report(_ id: UUID) async throws -> Stored? {
        let q: PostgresQuery = """
            SELECT r.id, r.data::text, r.admin_comment, c.timezone, coalesce(s.sections, '{}'::jsonb)::text, r.status, f.storage_key
            FROM rep.client_report r JOIN inv.client c ON c.id = r.client_id
            LEFT JOIN rep.client_report_settings s ON s.client_id = r.client_id
            LEFT JOIN sys.file f ON f.id = r.pdf_file_id
            WHERE r.id = \(id)
            """
        for try await (id, data, comment, zone, sections, status, key) in try await db.query(q)
            .decode((UUID, String, String, String, String, String, String?).self) {
            return try Self.stored(id: id, data: data, comment: comment, zone: zone, sections: sections, status: status, pdfKey: key)
        }
        return nil
    }

    static func stored(id: UUID, data: String, comment: String, zone: String, sections: String, status: String,
                       pdfKey: String?) throws -> Stored {
        let flags = (try? JSONDecoder().decode([String: Bool].self, from: Data(sections.utf8))) ?? [:]
        return Stored(id: id, report: try ReportJob.decode(Data(data.utf8)), comment: comment,
                      timeZone: TimeZone(identifier: zone) ?? moscow, sections: ReportJob.sections(flags),
                      status: status, pdfKey: pdfKey)
    }

    public func setComment(_ id: UUID, _ comment: String) async throws {
        try await rows(ReportSQL.setComment, [id, comment])
    }

    /// The admin checked the draft: approve it, make a link for this report
    /// and mark it sent (the link is what the admin hands over until email
    /// exists). Returns the token, shown once; nil when it was not a draft.
    public func send(_ id: UUID, by account: UUID?, ttlDays: Int = 365) async throws -> ReportToken? {
        var approved = false
        for try await _ in try await rows(ReportSQL.approve, [id, account]).decode(UUID.self) { approved = true }
        guard approved else { return nil }
        let token = ReportToken.make()
        try await rows(ReportSQL.insertLink, ["report", id, nil, Data(token.hash), account, Int32(ttlDays)])
        try await rows(ReportSQL.markSent, [id])
        return token
    }

    /// A permanent «all my reports» link for a client: opens the newest sent one.
    public func clientLink(_ clientID: UUID, by account: UUID?, ttlDays: Int = 3650) async throws -> ReportToken {
        let token = ReportToken.make()
        try await rows(ReportSQL.insertLink, ["client", nil, clientID, Data(token.hash), account, Int32(ttlDays)])
        return token
    }

    /// Stops a link from opening. Returns whether there was one.
    public func revoke(_ token: ReportToken, by account: UUID?) async throws -> Bool {
        let q: PostgresQuery = """
            UPDATE rep.report_link SET revoked_at = now(), revoked_by = \(account)
            WHERE token_hash = \(ByteBuffer(bytes: token.hash)) AND revoked_at IS NULL RETURNING id
            """
        for try await _ in try await db.query(q) { return true }
        return false
    }

    /// What a client's link shows (`ReportSQL.openLink`, which counts the
    /// visit); nil for an unknown, expired or revoked link and for drafts.
    public func open(_ token: ReportToken) async throws -> Stored? {
        var found: (UUID, String, String, String, String, UUID?)?
        for try await (id, _, data, comment, zone, sections, file) in try await rows(ReportSQL.openLink, [Data(token.hash)])
            .decode((UUID, UUID, String, String, String, String, UUID?).self) {
            found = (id, data, comment, zone, sections, file)
        }
        guard let f = found else { return nil }
        var key: String?
        if let file = f.5 {
            key = try await db.scalar("SELECT storage_key FROM sys.file WHERE id = \(file)", as: String.self)
        }
        return try Self.stored(id: f.0, data: f.1, comment: f.2, zone: f.3, sections: f.4, status: "sent", pdfKey: key)
    }

    /// Remembers the PDF made for a report (`sys.file`, content on the hub's disk).
    public func setPDF(_ reportID: UUID, key: String, pdf: Data) async throws {
        let sha = ByteBuffer(bytes: Array(SHA256.hash(data: pdf)))
        try await db.transaction { conn in
            let id = try await conn.scalar("""
                INSERT INTO sys.file (kind, storage_key, mime, size_bytes, sha256)
                VALUES ('report_pdf', \(key), 'application/pdf', \(Int64(pdf.count)), \(sha))
                ON CONFLICT (storage_key) DO UPDATE SET size_bytes = EXCLUDED.size_bytes, sha256 = EXCLUDED.sha256
                RETURNING id
                """, as: UUID.self, logger: db.logger)
            try await conn.query("UPDATE rep.client_report SET pdf_file_id = \(id) WHERE id = \(reportID)", logger: db.logger)
        }
    }

    /// «Отчёты за сентябрь готовы…» to the owner's Telegram, through the
    /// common delivery queue that TelegramService sends.
    /// One per owner per hour at most. Returns how many were queued.
    @discardableResult
    public func queueNotice(_ text: String, now: Date) async throws -> Int {
        let hour = Int(now.timeIntervalSince1970 / 3600)
        let q: PostgresQuery = """
            INSERT INTO ntf.delivery (kind, account_id, channel, target, dedup_key, payload, next_attempt_at)
            SELECT 'report', a.id, 'telegram', t.chat_id::text, 'reports-ready:' || \(String(hour)) || ':' || a.id,
                   \(DeliveryPayload(message: TelegramMessage(text)).json)::jsonb, now()
            FROM acc.account a
            JOIN ntf.telegram_link t ON t.account_id = a.id AND t.unlinked_at IS NULL AND NOT t.blocked_bot
            WHERE a.kind = 'owner' AND a.status = 'active'
            ON CONFLICT (dedup_key) DO NOTHING
            RETURNING id
            """
        var n = 0
        for try await _ in try await db.query(q) { n += 1 }
        return n
    }

    /// Who signs the reports (sys.org_settings.company_name) and their footer line.
    public func setSignature(_ name: String, footer: String?) async throws {
        try await db.query("""
            INSERT INTO sys.org_settings (id, company_name, report_footer) VALUES (true, \(name), coalesce(\(footer), ''))
            ON CONFLICT (id) DO UPDATE SET company_name = EXCLUDED.company_name,
              report_footer = coalesce(\(footer), sys.org_settings.report_footer), updated_at = now()
            """)
    }

    public func signature() async throws -> String {
        try await db.scalar("SELECT company_name FROM sys.org_settings", as: String.self) ?? ""
    }

    /// A client by name (for the command line).
    public func client(named name: String) async throws -> UUID? {
        try await db.scalar("SELECT id FROM inv.client WHERE name = \(name) OR short_name = \(name) LIMIT 1", as: UUID.self)
    }
}
