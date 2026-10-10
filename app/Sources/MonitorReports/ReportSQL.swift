import Foundation

/// The queries the hub runs for reports, against the approved schema
/// (architecture/db-schema.sql, schemas inv, mon, ops, rep).
///
/// Every query that reads a client's month takes the same five parameters:
/// `$1` client id (uuid), `$2` first day and `$3` last day of the period
/// (date, client's zone), `$4` and `$5` the period as instants [from, to)
/// (timestamptz). An object belongs to the report when it was the client's at
/// any time in the period (`inv.client_asset.since/until`), so a site moved to
/// another client mid-month still shows in both reports.
/// Tested on PostgreSQL 18 with the schema and sample rows: Tests/sql/reports-check.sh.
public enum ReportSQL {
    static let assets = """
    WITH a AS (
      SELECT asset_type, asset_id FROM inv.client_asset
      WHERE client_id = $1 AND since <= $3 AND (until IS NULL OR until >= $2)
    )
    """

    /// name, timezone, enabled, day_of_month, mode, sections (jsonb), link_ttl_days,
    /// sla_uptime (percent, numeric), signature, footer.
    public static let client = """
    SELECT c.name, c.timezone,
           coalesce(s.enabled, true) AS enabled, coalesce(s.day_of_month, 1) AS day_of_month,
           coalesce(s.mode, 'review') AS mode, coalesce(s.sections, '{}'::jsonb) AS sections,
           coalesce(s.link_ttl_days, 365) AS link_ttl_days, coalesce(s.extra_note, '') AS extra_note,
           (SELECT k.sla_uptime FROM inv.client_contract k
             WHERE k.client_id = c.id AND k.started_on <= $3 AND (k.ended_on IS NULL OR k.ended_on >= $2)
             ORDER BY k.started_on DESC LIMIT 1) AS sla_uptime,
           coalesce(o.company_name, '') AS signature,
           concat_ws(E'\\n', nullif(o.report_footer, ''),
                     nullif(concat_ws(' · ', o.contact_phone, o.contact_email), '')) AS footer
    FROM inv.client c
    LEFT JOIN rep.client_report_settings s ON s.client_id = c.id
    LEFT JOIN sys.org_settings o ON true
    WHERE c.id = $1
    """

    /// id, name, url, tls_expires_at, domain_expires_at.
    public static let sites = assets + """
    , s AS (
      SELECT s.id, s.name, s.url, lower(substring(s.url FROM '^[a-zA-Z]+://([^/:?#]+)')) AS host
      FROM inv.site s JOIN a ON a.asset_type = 'site' AND a.asset_id = s.id
    )
    SELECT s.id, s.name, s.url,
           (SELECT min(c.expires_at) FROM inv.certificate c WHERE c.host = s.host) AS tls_expires_at,
           (SELECT d.expires_at FROM inv.domain d
             WHERE s.host = d.name OR s.host LIKE '%.' || d.name
             ORDER BY length(d.name) DESC LIMIT 1) AS domain_expires_at
    FROM s ORDER BY s.name
    """

    /// site_id, day (date), checks_total, checks_ok, downtime_s, latency_avg_ms.
    public static let siteDays = assets + """
    SELECT d.site_id, d.day, d.checks_total, d.checks_ok, d.downtime_s, d.latency_avg_ms
    FROM mon.site_daily d JOIN a ON a.asset_type = 'site' AND a.asset_id = d.site_id
    WHERE d.day BETWEEN $2 AND $3
    """

    /// id, name, role.
    public static let servers = assets + """
    SELECT s.id, s.name, s.role
    FROM inv.server s JOIN a ON a.asset_type = 'server' AND a.asset_id = s.id
    ORDER BY s.name
    """

    /// server_id, day, cpu_max, mem_max, disk_max_pct, reboots, checks_total, checks_ok.
    public static let serverDays = assets + """
    SELECT d.server_id, d.day, d.cpu_max, d.mem_max, d.disk_max_pct, d.reboots, d.checks_total, d.checks_ok
    FROM mon.server_daily d JOIN a ON a.asset_type = 'server' AND a.asset_id = d.server_id
    WHERE d.day BETWEEN $2 AND $3
    """

    /// server_id, mount, day, used_bytes, total_bytes. From 30 days before the
    /// period: the disk runway is fitted on the last two weeks.
    public static let diskDays = assets + """
    SELECT d.server_id, d.mount, d.day, d.used_bytes, d.total_bytes
    FROM mon.disk_daily d JOIN a ON a.asset_type = 'server' AND a.asset_id = d.server_id
    WHERE d.day BETWEEN $2 - 30 AND $3
    """

    /// object_name, kind, severity, message, started_at, ended_at, cause, resolution.
    /// Problems of the client's objects that overlap the period and are not hidden from the client.
    public static let incidents = assets + """
    SELECT i.object_name, i.kind, i.severity, i.message, i.started_at, i.ended_at, i.cause, i.resolution
    FROM ops.incident i JOIN a ON a.asset_type = i.object_type AND a.asset_id = i.object_id
    WHERE i.client_visible AND i.started_at < $5 AND (i.ended_at IS NULL OR i.ended_at > $4)
    ORDER BY i.started_at
    """

    /// object_name, object_id, kind, line, due_at, first_seen_at, status, closed_at, note.
    /// Prevented in the period, and still open now.
    public static let forecasts = assets + """
    SELECT coalesce(sv.name, st.name, f.detail->>'object_name', '') AS object_name,
           f.object_id, f.kind, f.line, f.due_at, f.first_seen_at, f.status, f.closed_at, f.note
    FROM ops.forecast f
    JOIN a ON a.asset_type = f.object_type AND a.asset_id = f.object_id
    LEFT JOIN inv.server sv ON f.object_type = 'server' AND sv.id = f.object_id
    LEFT JOIN inv.site st ON f.object_type = 'site' AND st.id = f.object_id
    WHERE f.client_visible
      AND ((f.status = 'prevented' AND f.closed_at >= $4 AND f.closed_at < $5) OR f.status = 'open')
    ORDER BY f.first_seen_at
    """

    /// server_name, target, started_at, ok, size_bytes.
    public static let backups = assets + """
    SELECT s.name AS server_name, b.target, b.started_at, coalesce(b.ok, false) AS ok, b.size_bytes
    FROM mon.backup_run b
    JOIN a ON a.asset_type = 'server' AND a.asset_id = b.server_id
    JOIN inv.server s ON s.id = b.server_id
    WHERE b.started_at >= $4 AND b.started_at < $5
    """

    /// done_at, client_text.
    public static let work = """
    SELECT w.done_at, w.client_text
    FROM rep.work_item w
    WHERE w.client_id = $1 AND w.client_visible AND w.done_at >= $4 AND w.done_at < $5
    ORDER BY w.done_at
    """

    // MARK: - Writing

    /// A new draft replaces the earlier version of the same month (kept as
    /// `superseded`, with its links still pointing at it). One statement, so
    /// two hub jobs cannot both leave a live draft.
    /// $1 client_id, $2 period_start, $3 period_end, $4 template_version,
    /// $5 summary_status, $6 data (jsonb), $7 generated_by (uuid or null).
    /// Returns id.
    public static let insertDraft = """
    WITH old AS (
      UPDATE rep.client_report SET status = 'superseded'
      WHERE client_id = $1 AND period_start = $2 AND status <> 'superseded'
      RETURNING id, admin_comment
    )
    INSERT INTO rep.client_report (client_id, period_start, period_end, template_version, status,
                                   summary_status, data, admin_comment, generated_by, supersedes_id)
    SELECT $1, $2, $3, $4, 'draft', $5, $6, coalesce((SELECT admin_comment FROM old LIMIT 1), ''), $7,
           (SELECT id FROM old LIMIT 1)
    RETURNING id
    """

    /// The admin's comment on a draft. $1 report id, $2 comment.
    public static let setComment = """
    UPDATE rep.client_report SET admin_comment = $2 WHERE id = $1 AND status IN ('draft','approved')
    """

    /// The admin checked the draft and pressed «Отправить». $1 report id, $2 account id.
    /// Returns id; no row when it was not a draft any more.
    public static let approve = """
    UPDATE rep.client_report SET status = 'approved', approved_at = now(), approved_by = $2
    WHERE id = $1 AND status = 'draft'
    RETURNING id
    """

    /// After the deliveries are queued (or the link is handed over). $1 report id.
    public static let markSent = """
    UPDATE rep.client_report SET status = 'sent' WHERE id = $1 AND status = 'approved'
    """

    /// $1 scope ('report' | 'client'), $2 report id or null, $3 client id or null,
    /// $4 token hash (bytea), $5 created_by, $6 ttl days. Returns id, expires_at.
    public static let insertLink = """
    INSERT INTO rep.report_link (scope, report_id, client_id, token_hash, created_by, expires_at)
    VALUES ($1, $2, $3, $4, $5, now() + make_interval(days => $6))
    RETURNING id, expires_at
    """

    /// $1 link id, $2 account id.
    public static let revokeLink = """
    UPDATE rep.report_link SET revoked_at = now(), revoked_by = $2 WHERE id = $1 AND revoked_at IS NULL
    """

    /// Opening a link: counts the visit and returns what to show. Only reports
    /// that were approved or sent are visible; drafts never leak by a link.
    /// For a client link, the newest sent report. $1 token hash.
    /// Returns report_id, client_id, data, admin_comment, timezone, sections, pdf_file_id.
    public static let openLink = """
    WITH l AS (
      UPDATE rep.report_link SET open_count = open_count + 1, last_opened_at = now()
      WHERE token_hash = $1 AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > now())
      RETURNING scope, report_id, client_id
    )
    SELECT r.id AS report_id, r.client_id, r.data, r.admin_comment, c.timezone,
           coalesce(s.sections, '{}'::jsonb) AS sections, r.pdf_file_id
    FROM l
    JOIN rep.client_report r ON (l.scope = 'report' AND r.id = l.report_id)
                             OR (l.scope = 'client' AND r.client_id = l.client_id)
    JOIN inv.client c ON c.id = r.client_id
    LEFT JOIN rep.client_report_settings s ON s.client_id = r.client_id
    WHERE r.status IN ('approved','sent')
    ORDER BY r.period_start DESC, r.generated_at DESC
    LIMIT 1
    """

    /// Every sent report of the client behind a client link, for the archive list.
    /// $1 token hash. Returns report_id, period_start.
    public static let linkArchive = """
    SELECT r.id AS report_id, r.period_start
    FROM rep.report_link l JOIN rep.client_report r ON r.client_id = l.client_id
    WHERE l.token_hash = $1 AND l.scope = 'client' AND l.revoked_at IS NULL
      AND (l.expires_at IS NULL OR l.expires_at > now()) AND r.status IN ('approved','sent')
    ORDER BY r.period_start DESC
    """

    /// Contacts who get the report. $1 client id.
    /// Returns contact id, name, email, telegram_chat_id.
    public static let recipients = """
    SELECT id, name, email::text AS email, telegram_chat_id
    FROM inv.client_contact WHERE client_id = $1 AND receives_report
    ORDER BY sort, name
    """

    /// Clients whose report for the month that ended before `$1` (a date: the
    /// first day of the current month) is due and not made yet. Your own
    /// infrastructure (`is_internal`) gets no report.
    /// Returns client id, timezone, day_of_month.
    public static let dueClients = """
    SELECT c.id, c.timezone, coalesce(s.day_of_month, 1) AS day_of_month
    FROM inv.client c
    LEFT JOIN rep.client_report_settings s ON s.client_id = c.id
    WHERE c.status = 'active' AND NOT c.is_internal AND c.archived_at IS NULL
      AND coalesce(s.enabled, true)
      AND NOT EXISTS (SELECT 1 FROM rep.client_report r
                      WHERE r.client_id = c.id AND r.period_start = ($1::date - interval '1 month')::date
                        AND r.status <> 'superseded')
    """

    /// Drafts waiting for the admin, for the «Отчёты готовы» notice and the review list.
    /// Returns id, client name, period_start, summary_status.
    public static let drafts = """
    SELECT r.id, c.name, r.period_start, r.summary_status
    FROM rep.client_report r JOIN inv.client c ON c.id = r.client_id
    WHERE r.status = 'draft'
    ORDER BY r.period_start DESC, c.name
    """
}
