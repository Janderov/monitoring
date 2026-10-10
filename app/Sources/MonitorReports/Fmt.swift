import Foundation

/// Russian formatting for the report: «99,97 %», «14 мин», «23 сент., 03:12».
enum Fmt {
    static let monthsNominative = ["январь", "февраль", "март", "апрель", "май", "июнь",
                                   "июль", "август", "сентябрь", "октябрь", "ноябрь", "декабрь"]
    static let monthsGenitive = ["января", "февраля", "марта", "апреля", "мая", "июня",
                                 "июля", "августа", "сентября", "октября", "ноября", "декабря"]
    static let monthsShort = ["янв.", "февр.", "марта", "апр.", "мая", "июня",
                              "июля", "авг.", "сент.", "окт.", "нояб.", "дек."]

    /// 0.9997 → «99,97 %», 1 → «100 %», nil → «нет данных».
    static func percent(_ share: Double?) -> String {
        guard let share else { return "нет данных" }
        if share >= 1 { return "100 %" }
        // Never round a bad month up to 100 %.
        let v = (share * 10000).rounded(.down) / 100
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s.replacingOccurrences(of: ".", with: ",") + " %"
    }

    /// A load or fill level already in percent: 64.4 → «64 %».
    static func level(_ v: Double?) -> String {
        v.map { "\(Int($0.rounded())) %" } ?? "—"
    }

    static func duration(_ seconds: Int) -> String {
        let m = max(0, seconds) / 60
        if m < 1 { return "меньше минуты" }
        if m < 60 { return "\(m) мин" }
        let h = m / 60, rm = m % 60
        if h < 24 { return rm > 0 ? "\(h) ч \(rm) мин" : "\(h) ч" }
        let d = h / 24, rh = h % 24
        return rh > 0 ? "\(d) дн \(rh) ч" : "\(d) дн"
    }

    static func ms(_ v: Double?) -> String {
        guard let v else { return "—" }
        return v >= 1000 ? String(format: "%.1f с", v / 1000).replacingOccurrences(of: ".", with: ",") : "\(Int(v.rounded())) мс"
    }

    static func bytes(_ b: Int64?) -> String {
        guard let b else { return "—" }
        let units = ["Б", "КБ", "МБ", "ГБ", "ТБ"]
        var v = Double(b), i = 0
        while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
        let s = v >= 10 || i == 0 ? String(Int(v.rounded())) : String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",")
        return "\(s) \(units[i])"
    }

    static func parts(_ date: Date, _ tz: TimeZone) -> DateComponents {
        ReportPeriod.calendar(tz).dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    /// «23 сент.»
    static func dayShort(_ date: Date, _ tz: TimeZone) -> String {
        let c = parts(date, tz)
        return "\(c.day!) \(monthsShort[c.month! - 1])"
    }

    /// «23 сент., 03:12»
    static func dayTime(_ date: Date, _ tz: TimeZone) -> String {
        let c = parts(date, tz)
        return dayShort(date, tz) + String(format: ", %02d:%02d", c.hour!, c.minute!)
    }

    /// «16 ноября 2026»
    static func dayLong(_ date: Date, _ tz: TimeZone) -> String {
        let c = parts(date, tz)
        return "\(c.day!) \(monthsGenitive[c.month! - 1]) \(c.year!)"
    }

    /// "2026-09-06" → «06.09»
    static func dayNumeric(_ day: String) -> String {
        let p = day.split(separator: "-")
        return p.count == 3 ? "\(p[2]).\(p[1])" : day
    }

    /// "2026-09-14" → «14 сент.»
    static func dayShort(_ day: String) -> String {
        let p = day.split(separator: "-").compactMap { Int($0) }
        return p.count == 3 ? "\(p[2]) \(monthsShort[p[1] - 1])" : day
    }

    /// "2026-09-01" → «сентябрь 2026»
    static func month(_ day: String) -> String {
        let p = day.split(separator: "-").compactMap { Int($0) }
        return p.count == 3 ? "\(monthsNominative[p[1] - 1]) \(p[0])" : day
    }

    static func runway(_ days: Int?) -> String {
        guard let days else { return "не растёт" }
        if days > 365 { return "больше года" }
        if days < 45 { return "~\(days) дн" }
        return "~\(Int((Double(days) / 30).rounded())) мес."
    }
}
