import Foundation

/// A server's history beyond alerts: reboots and containers starting,
/// stopping, appearing and disappearing, found by comparing consecutive
/// snapshots. The agent keeps a day of minute snapshots, so changes that
/// happened while the Mac slept are found too, with the time they happened.
public enum ServerEvents {
    /// Clocks and /proc/stat rounding move the boot time by a second or two;
    /// a real reboot moves it by at least the time the server was up.
    static let bootJitter: TimeInterval = 60
    /// Entries per hour logged for one key (one container) at most.
    public static let maxPerHour = 6

    /// Events between `previous` and each of `snapshots` in turn, oldest first.
    /// Snapshots not newer than the one before them are skipped.
    public static func changes(serverID: String, serverName: String,
                               previous: Snapshot?, snapshots: [Snapshot]) -> [AlertEvent] {
        var out: [AlertEvent] = []
        var prev = previous
        for s in snapshots {
            if let p = prev, s.time <= p.time { continue }
            if let p = prev {
                out += between(p, s).map {
                    AlertEvent(serverID: serverID, serverName: serverName, key: $0.key, kind: .info,
                               severity: $0.severity, message: $0.message, time: $0.time)
                }
            }
            prev = s
        }
        return out
    }

    private struct Change {
        var key: String
        var severity: Severity
        var message: String
        var time: Date
    }

    private static func between(_ a: Snapshot, _ b: Snapshot) -> [Change] {
        var out: [Change] = []
        if a.bootTime.timeIntervalSince1970 > 0, b.bootTime.timeIntervalSince1970 > 0,
           b.bootTime.timeIntervalSince(a.bootTime) > bootJitter {
            // The boot time is when it came back; keep it between the samples.
            let at = min(max(b.bootTime, a.time), b.time)
            out.append(Change(key: "reboot", severity: .warning,
                              message: "сервер перезагрузился, работал до этого \(uptime(a.uptimeSeconds))",
                              time: at))
        }
        // No list means Docker was not read (no socket, an error, or none
        // left): nothing can be said about containers then.
        guard let before = a.containers, let after = b.containers else { return out }
        let old = Dictionary(before.map { ($0.name, $0) }, uniquingKeysWith: { x, _ in x })
        let new = Dictionary(after.map { ($0.name, $0) }, uniquingKeysWith: { x, _ in x })
        for c in after {
            let running = c.state == "running"
            if let o = old[c.name] {
                let was = o.state == "running"
                if was && !running {
                    out.append(Change(key: "ctr:\(c.name)", severity: .warning,
                                      message: "контейнер \(c.name) остановился\(exitNote(c))", time: b.time))
                } else if !was && running {
                    out.append(Change(key: "ctr:\(c.name)", severity: .warning,
                                      message: "контейнер \(c.name) запущен", time: b.time))
                }
            } else {
                out.append(Change(key: "ctr:\(c.name)", severity: .warning,
                                  message: "появился контейнер \(c.name)\(running ? "" : " (не запущен)")",
                                  time: b.time))
            }
        }
        for c in before where new[c.name] == nil {
            out.append(Change(key: "ctr:\(c.name)", severity: .warning,
                              message: "контейнер \(c.name) удалён", time: b.time))
        }
        return out
    }

    /// ": код выхода 137" from Docker's "Exited (137) 2 minutes ago".
    static func exitNote(_ c: Snapshot.Container) -> String {
        guard c.status.hasPrefix("Exited ("), let close = c.status.firstIndex(of: ")") else {
            return c.state.isEmpty ? "" : " (\(c.state))"
        }
        let start = c.status.index(c.status.startIndex, offsetBy: "Exited (".count)
        return ", код выхода \(c.status[start..<close])"
    }

    /// "12 д 4 ч", "3 ч 10 мин", "4 мин", as the app shows durations.
    static func uptime(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return h > 0 ? "\(d) д \(h) ч" : "\(d) д" }
        if h > 0 { return m > 0 ? "\(h) ч \(m) мин" : "\(h) ч" }
        if m > 0 { return "\(m) мин" }
        return "\(s) с"
    }
}
