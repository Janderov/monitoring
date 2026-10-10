import Foundation

/// A calendar month in the client's time zone, and when its report is due.
public struct ReportPeriod: Equatable, Sendable {
    public var timeZone: TimeZone
    /// "yyyy-MM-dd", first and last day inclusive.
    public var start: String
    public var end: String
    /// The same period as instants: [from, to).
    public var from: Date
    public var to: Date

    /// Every day of the period, in order.
    public var days: [String] {
        var out: [String] = []
        var d = from
        let cal = Self.calendar(timeZone)
        while d < to {
            out.append(Self.day(d, timeZone))
            d = cal.date(byAdding: .day, value: 1, to: d)!
        }
        return out
    }

    /// The month that contains `date` in `timeZone`.
    public static func month(containing date: Date, timeZone: TimeZone) -> ReportPeriod {
        let cal = calendar(timeZone)
        let from = cal.dateInterval(of: .month, for: date)!.start
        let to = cal.date(byAdding: .month, value: 1, to: from)!
        let last = cal.date(byAdding: .day, value: -1, to: to)!
        return ReportPeriod(timeZone: timeZone, start: day(from, timeZone), end: day(last, timeZone), from: from, to: to)
    }

    /// The month before the one that contains `date`: what a report made on the 1st covers.
    public static func previousMonth(before date: Date, timeZone: TimeZone) -> ReportPeriod {
        let cal = calendar(timeZone)
        let thisMonth = cal.dateInterval(of: .month, for: date)!.start
        return month(containing: cal.date(byAdding: .day, value: -1, to: thisMonth)!, timeZone: timeZone)
    }

    /// When the report for this period is made: `dayOfMonth` of the next month
    /// at 06:00 in the client's zone, so the draft waits for the admin in the morning.
    public func dueAt(dayOfMonth: Int) -> Date {
        let cal = Self.calendar(timeZone)
        return cal.date(byAdding: DateComponents(day: max(1, min(28, dayOfMonth)) - 1, hour: 6), to: to)!
    }

    /// Index of `date`'s day within the period, nil outside it.
    public func dayIndex(_ date: Date) -> Int? {
        guard date >= from, date < to else { return nil }
        return days.firstIndex(of: Self.day(date, timeZone))
    }

    public static func day(_ date: Date, _ timeZone: TimeZone) -> String {
        let c = calendar(timeZone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }
}
