import Foundation

/// What happened while the Mac was not polling (asleep, off, no network). The
/// agents keep a 24 h buffer, so the first round afterwards brings the missed
/// minutes back; this turns them into one journal entry, sent as a
/// notification when there is something to tell.
public enum AwaySummary {
    /// Shorter pauses (a slow round, a short Wi-Fi drop) are not worth a line.
    public static let minimumGap: TimeInterval = 10 * 60
    /// Event key and pseudo server of the entry.
    public static let key = "away"
    public static let sourceID = "mac"

    /// One server's samples received after the pause, oldest first.
    public struct Seen: Sendable {
        public var server: ServerConfig
        /// The last sample stored before the pause.
        public var before: Snapshot?
        public var samples: [Snapshot]

        public init(server: ServerConfig, before: Snapshot?, samples: [Snapshot]) {
            self.server = server; self.before = before; self.samples = samples
        }
    }

    /// Lines for each server or site that had trouble after `from`; empty when
    /// all was quiet.
    public static func lines(from: Date, seen: [Seen], sites: [SiteConfig],
                             timeZone: TimeZone = .current) -> [String] {
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "ru_RU")
        clock.timeZone = timeZone
        clock.dateFormat = "HH:mm"
        var out: [String] = []
        var siteMinutes: [String: Double] = [:]

        for s in seen {
            var notes: [String] = []
            if let before = s.before, let boot = s.samples.last?.bootTime, boot > from,
               boot > before.bootTime.addingTimeInterval(60) {
                notes.append("перезагрузился в \(clock.string(from: boot))")
            }
            // The agent samples every `intervalS`; a hole of several samples
            // means it (or the whole server) was not running.
            let chain = (s.before.map { [$0] } ?? []) + s.samples
            for (a, b) in zip(chain, chain.dropFirst()) where b.time > from {
                let step = TimeInterval(b.intervalS ?? a.intervalS ?? 60)
                if b.time.timeIntervalSince(a.time) > max(3 * step, 180) {
                    notes.append("не было данных \(clock.string(from: a.time))–\(clock.string(from: b.time))")
                }
            }
            if !notes.isEmpty { out.append("\(s.server.name): \(notes.joined(separator: ", "))") }

            // Sites: minutes in which this server could not open them.
            var failed: [String: Double] = [:]
            for snap in s.samples where snap.time > from {
                let step = Double(snap.intervalS ?? 60) / 60
                for c in snap.checks ?? [] where !c.ok && c.id.hasPrefix(SiteConfig.checkPrefix) {
                    failed[c.id, default: 0] += step
                }
            }
            for (id, minutes) in failed { siteMinutes[id] = max(siteMinutes[id] ?? 0, minutes) }
        }
        for site in sites {
            guard let minutes = siteMinutes[site.checkID] else { continue }
            out.append("\(site.name) не открывался ~\(max(Int(minutes.rounded()), 1)) мин")
        }
        return out
    }

    /// The journal entry for a pause from `from` to `to`.
    public static func event(from: Date, to: Date, lines: [String], timeZone: TimeZone = .current) -> AlertEvent {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.timeZone = timeZone
        f.dateFormat = Calendar.current.isDate(from, inSameDayAs: to) ? "HH:mm" : "d MMM HH:mm"
        let span = "с \(f.string(from: from)) до \(f.string(from: to))"
        let message = lines.isEmpty ? "Мак не проверял серверы \(span), за это время всё было в норме"
                                    : "Мак не проверял серверы \(span). " + lines.joined(separator: "; ")
        return AlertEvent(serverID: sourceID, serverName: "Пока Мак не проверял", key: key, kind: .info,
                          severity: .warning, message: message, time: to)
    }
}
