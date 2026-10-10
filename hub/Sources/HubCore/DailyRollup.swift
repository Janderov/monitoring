import Foundation
import PostgresNIO

/// Day totals (mon.server_daily, site_daily, disk_daily): what reports, year
/// charts and long forecasts read. Days are calendar days in the installation's
/// zone (sys.org_settings.default_timezone). Each run recomputes the last three
/// days, so late agent data and the day in progress are caught up; the first
/// run fills every day the hourly history has (a Mac import brings a year).
enum DailyRollup {
    static let redo = 2

    /// Returns the rows written per table.
    @discardableResult
    static func run(_ db: Database) async throws -> [String: Int] {
        let tz = try await db.scalar("""
            SELECT coalesce((SELECT default_timezone FROM sys.org_settings), 'Europe/Moscow')
            """, as: String.self) ?? "Europe/Moscow"
        var out: [String: Int] = [:]
        out["server_daily"] = try await count(db, try .sql(server, [tz, Int32(redo)]))
        out["site_daily"] = try await count(db, try .sql(site, [tz, Int32(redo)]))
        out["disk_daily"] = try await count(db, try .sql(disk, [tz, Int32(redo)]))
        return out
    }

    static func count(_ db: Database, _ q: PostgresQuery) async throws -> Int {
        var n = 0
        for try await _ in try await db.query(q) { n += 1 }
        return n
    }

    /// `$1` zone, `$2` days to redo. The first day to (re)compute, as a
    /// timestamptz at its midnight: two days before the last computed one, or
    /// the oldest hour there is.
    static func since(_ table: String, _ source: String, _ time: String) -> String {
        """
        f AS (
          SELECT coalesce((SELECT max(day) FROM \(table)) - $2::int,
                          (SELECT min(\(time) AT TIME ZONE $1)::date FROM \(source)),
                          (now() AT TIME ZONE $1)::date)::timestamp AT TIME ZONE $1 AS ts
        )
        """
    }

    /// Hourly server rows and the reboots from the journal.
    static let server = """
    WITH \(since("mon.server_daily", "mon.server_hourly", "hour")),
    r AS (
      SELECT e.object_id, (e.ts AT TIME ZONE $1)::date AS day, count(*) AS n
      FROM ops.event e, f WHERE e.key = 'reboot' AND e.object_type = 'server' AND e.ts >= f.ts
      GROUP BY 1, 2
    )
    INSERT INTO mon.server_daily (server_id, day, cpu_avg, cpu_max, mem_avg, mem_max, disk_max_pct,
                                  rx_bytes, tx_bytes, vpn_max, reboots, checks_total, checks_ok)
    SELECT h.server_id, (h.hour AT TIME ZONE $1)::date AS day, avg(h.cpu_avg), max(h.cpu_max), avg(h.mem_avg),
           max(h.mem_max), max(h.disk_max), (sum(h.rx_avg) * 3600)::bigint, (sum(h.tx_avg) * 3600)::bigint,
           max(h.vpn_max), coalesce(max(r.n), 0), sum(h.polls_total), sum(h.polls_ok)
    FROM mon.server_hourly h
    JOIN f ON h.hour >= f.ts
    JOIN inv.server s ON s.id = h.server_id
    LEFT JOIN r ON r.object_id = h.server_id AND r.day = (h.hour AT TIME ZONE $1)::date
    GROUP BY 1, 2
    ON CONFLICT (server_id, day) DO UPDATE SET cpu_avg = EXCLUDED.cpu_avg, cpu_max = EXCLUDED.cpu_max,
      mem_avg = EXCLUDED.mem_avg, mem_max = EXCLUDED.mem_max, disk_max_pct = EXCLUDED.disk_max_pct,
      rx_bytes = EXCLUDED.rx_bytes, tx_bytes = EXCLUDED.tx_bytes, vpn_max = EXCLUDED.vpn_max,
      reboots = EXCLUDED.reboots, checks_total = EXCLUDED.checks_total, checks_ok = EXCLUDED.checks_ok
    RETURNING 1
    """

    /// Checks from the hourly rows; downtime from the raw checks (30 days):
    /// a minute is down when every point that checked failed and at least two
    /// did, or the site has one point only. The same rule as the alert and the
    /// Mac's report («not from one country» is routing, not the site).
    static let site = """
    WITH \(since("mon.site_daily", "mon.site_hourly", "hour")),
    m AS (
      SELECT c.site_id, date_trunc('minute', c.ts) AS minute, count(*) AS n, count(*) FILTER (WHERE NOT c.ok) AS fails
      FROM mon.site_check c, f WHERE c.ts >= f.ts GROUP BY 1, 2
    ),
    p AS (
      SELECT c.site_id, (c.ts AT TIME ZONE $1)::date AS day, count(DISTINCT c.probe_id) AS probes
      FROM mon.site_check c, f WHERE c.ts >= f.ts GROUP BY 1, 2
    ),
    d AS (
      SELECT m.site_id, (m.minute AT TIME ZONE $1)::date AS day, count(*) * 60 AS s
      FROM m JOIN p ON p.site_id = m.site_id AND p.day = (m.minute AT TIME ZONE $1)::date
      WHERE m.fails = m.n AND (m.fails >= 2 OR p.probes = 1)
      GROUP BY 1, 2
    )
    INSERT INTO mon.site_daily (site_id, day, checks_total, checks_ok, downtime_s, latency_avg_ms, latency_p95_ms)
    SELECT h.site_id, (h.hour AT TIME ZONE $1)::date AS day, sum(h.total), sum(h.ok), coalesce(max(d.s), 0),
           sum(h.latency_avg * h.total) FILTER (WHERE h.latency_avg IS NOT NULL)
             / nullif(sum(h.total) FILTER (WHERE h.latency_avg IS NOT NULL), 0),
           max(h.latency_p95)
    FROM mon.site_hourly h
    JOIN f ON h.hour >= f.ts
    JOIN inv.site s ON s.id = h.site_id
    LEFT JOIN d ON d.site_id = h.site_id AND d.day = (h.hour AT TIME ZONE $1)::date
    GROUP BY 1, 2
    ON CONFLICT (site_id, day) DO UPDATE SET checks_total = EXCLUDED.checks_total, checks_ok = EXCLUDED.checks_ok,
      downtime_s = EXCLUDED.downtime_s, latency_avg_ms = EXCLUDED.latency_avg_ms, latency_p95_ms = EXCLUDED.latency_p95_ms
    RETURNING 1
    """

    /// The last reading of each disk each day.
    static let disk = """
    WITH \(since("mon.disk_daily", "mon.disk_sample", "ts"))
    INSERT INTO mon.disk_daily (server_id, mount, day, used_bytes, total_bytes)
    SELECT DISTINCT ON (d.server_id, d.mount, (d.ts AT TIME ZONE $1)::date)
           d.server_id, d.mount, (d.ts AT TIME ZONE $1)::date, d.used_bytes, d.total_bytes
    FROM mon.disk_sample d
    JOIN f ON d.ts >= f.ts
    JOIN inv.server s ON s.id = d.server_id
    ORDER BY d.server_id, d.mount, (d.ts AT TIME ZONE $1)::date, d.ts DESC
    ON CONFLICT (server_id, mount, day) DO UPDATE SET used_bytes = EXCLUDED.used_bytes,
      total_bytes = EXCLUDED.total_bytes
    RETURNING 1
    """
}
