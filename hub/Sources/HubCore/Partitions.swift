import Foundation
import Logging
import PostgresNIO

/// Raw rows live in one partition per UTC day, summaries and journals in one
/// per month (sys.partition_policy). The database's own
/// sys.maintain_partitions() makes the current and coming partitions and
/// drops expired ones; the hub runs it every hour. What it does not make is
/// the past: on the first start the agents send up to 24 hours back, and an
/// import from the Mac up to two years, so `ensure(back:)` adds those, never
/// further back than the table keeps.
public enum Partitions {
    public enum Step: String, Sendable { case day, month }

    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// Start of the partition holding `date`.
    public static func start(of date: Date, step: Step) -> Date {
        let c = utc
        switch step {
        case .day: return c.startOfDay(for: date)
        case .month: return c.date(from: c.dateComponents([.year, .month], from: date))!
        }
    }

    public static func next(_ start: Date, step: Step) -> Date {
        utc.date(byAdding: step == .day ? .day : .month, value: 1, to: start)!
    }

    /// mon.server_sample_20261010 / mon.server_hourly_202610, as
    /// sys.maintain_partitions() names them.
    public static func partitionName(_ table: String, start: Date, step: Step) -> String {
        let c = utc.dateComponents([.year, .month, .day], from: start)
        let suffix = step == .day
            ? String(format: "%04d%02d%02d", c.year!, c.month!, c.day!)
            : String(format: "%04d%02d", c.year!, c.month!)
        return "\(table)_\(suffix)"
    }

    /// The partition starts covering [from, to].
    public static func starts(from: Date, to: Date, step: Step) -> [Date] {
        var out: [Date] = []
        var s = start(of: from, step: step)
        while s <= to {
            out.append(s)
            s = next(s, step: step)
        }
        return out
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }

    struct Policy: Sendable {
        var parent: String
        var step: Step
        var keep: TimeInterval
    }

    static func policies(_ db: Database) async throws -> [Policy] {
        var out: [Policy] = []
        let rows = try await db.query("""
            SELECT parent, step, extract(epoch FROM keep)::float8 FROM sys.partition_policy ORDER BY parent
            """)
        for try await (parent, step, keep) in rows.decode((String, String, Double).self) {
            out.append(Policy(parent: parent, step: Step(rawValue: step) ?? .day, keep: keep))
        }
        return out
    }

    /// The database's hourly upkeep plus the past partitions `back` needs.
    /// Returns what was created or dropped.
    @discardableResult
    public static func ensure(_ db: Database, now: Date, back: TimeInterval = 2 * 86_400) async throws -> [String] {
        var changed: [String] = []
        for p in try await policies(db) {
            let from = now.addingTimeInterval(-min(back, p.keep))
            for s in starts(from: from, to: now, step: p.step) where next(s, step: p.step) > now.addingTimeInterval(-p.keep) {
                let name = partitionName(p.parent, start: s, step: p.step)
                let exists = try await db.scalar("SELECT to_regclass(\(name)) IS NOT NULL", as: Bool.self) ?? false
                guard !exists else { continue }
                try await db.query(PostgresQuery(unsafeSQL: """
                    CREATE TABLE IF NOT EXISTS \(name) PARTITION OF \(p.parent)
                    FOR VALUES FROM ('\(iso(s))') TO ('\(iso(next(s, step: p.step)))')
                    """))
                changed.append("created \(name)")
            }
        }
        let rows = try await db.query("SELECT action, partition_name FROM sys.maintain_partitions(\(now))")
        for try await (action, name) in rows.decode((String, String).self) { changed.append("\(action) \(name)") }
        return changed
    }
}
