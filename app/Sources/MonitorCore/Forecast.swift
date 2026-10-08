import Foundation

/// What is about to go wrong, sent by itself once a day: disks filling up,
/// certificates and domains running out, old or missing database backups,
/// security updates and pending reboots. What is two days away or closer is
/// sent at once, without waiting for the morning.
public struct ForecastItem: Equatable, Identifiable, Sendable {
    /// Stable across days, to send an urgent one only once.
    public var id: String
    public var line: String
    /// Days left for something that runs out, nil for upkeep notes.
    public var days: Int?

    /// Two days or less: worth a notification right away.
    public var urgent: Bool { days.map { $0 <= Forecast.urgentDays } ?? false }
}

public enum Forecast {
    public static let urgentDays = 2
    /// An urgent item is repeated at most this often.
    public static let repeatUrgent: TimeInterval = 24 * 3600

    /// Everything worth the daily notice, soonest first, upkeep after.
    /// - Parameters:
    ///   - soon: what runs out, with the server's name (from `Soon.items`).
    ///   - care: upkeep notes with the server's name (from `Care.notes`).
    public static func items(soon: [(server: String, item: SoonItem)], care: [(server: String, note: CareNote)],
                             now: Date) -> [ForecastItem] {
        var out: [ForecastItem] = []
        for s in soon.filter({ Soon.urgent($0.item, now: now) }).sorted(by: { $0.item.date < $1.item.date }) {
            let days = max(0, Int(s.item.date.timeIntervalSince(now) / 86400))
            let when = days == 0 ? "сегодня" : days == 1 ? "завтра" : "через \(days) дн"
            let line: String
            switch s.item.kind {
            case .disk: line = "Диск \(s.server) заполнится \(when)"
            case .tls: line = "SSL \(s.item.name) истекает \(when)"
            case .domain: line = "Домен \(s.item.name) истекает \(when)"
            case .payment: line = "Оплата \(s.server) \(when)"
            }
            // A site's certificate is the same whichever server it is found on.
            let site = s.item.kind == .tls || s.item.kind == .domain
            out.append(ForecastItem(id: site ? s.item.id : s.server + "|" + s.item.id, line: line,
                                    days: s.item.kind == .payment ? nil : days))
        }
        for c in care where c.note.warn {
            out.append(ForecastItem(id: c.server + "|" + c.note.id, line: "\(c.server): \(c.note.text.lowercasedFirst)", days: nil))
        }
        return out
    }

    /// The daily notification; nil when nothing needs a look.
    public static func notice(_ items: [ForecastItem]) -> MorningSummary? {
        guard !items.isEmpty else { return nil }
        return MorningSummary(title: "Прогноз: требует внимания \(items.count)",
                              body: items.map(\.line).joined(separator: "\n"))
    }

    /// Urgent items not sent in the last day, and the record with them added
    /// (entries older than a day dropped).
    public static func dueNow(_ items: [ForecastItem], sent: [String: Date], now: Date) -> (due: [ForecastItem], sent: [String: Date]) {
        var record = sent.filter { now.timeIntervalSince($0.value) < repeatUrgent }
        let due = items.filter { $0.urgent && record[$0.id] == nil }
        for i in due { record[i.id] = now }
        return (due, record)
    }
}
