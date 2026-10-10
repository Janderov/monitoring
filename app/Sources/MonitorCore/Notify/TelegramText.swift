import Foundation

/// A button under a message. `data` comes back in the callback (64 bytes at most).
public struct TelegramButton: Equatable, Codable, Sendable {
    public var text: String
    public var data: String
    public init(_ text: String, _ data: String) { self.text = text; self.data = data }
}

/// A message as the Bot API takes it: HTML text and rows of buttons.
public struct TelegramMessage: Equatable, Codable, Sendable {
    public var text: String
    public var buttons: [[TelegramButton]]
    public init(_ text: String, buttons: [[TelegramButton]] = []) { self.text = text; self.buttons = buttons }
}

/// What a button does; the callback data is "<action>:<id>".
public enum BotButton: String, Sendable {
    case ack = "ack"          // Беру
    case snooze = "snz"       // 🔕 1 час, for me
    case details = "det"      // 📊 Подробнее
    case ackClient = "akc"    // Беру все (a bundle): every open problem of this client

    public func data(_ id: String) -> String { "\(rawValue):\(id)" }

    public static func parse(_ data: String) -> (BotButton, String)? {
        let parts = data.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let b = BotButton(rawValue: parts[0]), !parts[1].isEmpty else { return nil }
        return (b, parts[1])
    }
}

/// The texts of every message the bot sends, in Russian, Telegram HTML.
/// No passwords, tokens or keys ever go into them; names of servers and clients do.
public enum TelegramText {
    /// Snooze from the button.
    public static let snoozeFor: TimeInterval = 3600

    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// "9 мин", "1 ч 5 мин", "2 дн 3 ч".
    public static func duration(_ seconds: TimeInterval) -> String {
        let m = max(0, Int(seconds / 60))
        if m < 60 { return "\(max(m, 1)) мин" }
        let h = m / 60
        if h < 24 { return m % 60 == 0 ? "\(h) ч" : "\(h) ч \(m % 60) мин" }
        return h % 24 == 0 ? "\(h / 24) дн" : "\(h / 24) дн \(h % 24) ч"
    }

    static func time(_ d: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.timeZone = tz
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    static func icon(_ s: Severity) -> String { s == .critical ? "🔴" : "🟡" }

    static func head(_ i: NotifyIncident) -> String {
        "\(icon(i.severity)) <b>\(escape(i.objectName))</b>"
    }

    static func client(_ i: NotifyIncident) -> String? {
        i.clientName.map { "Клиент: \(escape($0))" }
    }

    static func buttons(_ i: NotifyIncident, ack: Bool = true) -> [[TelegramButton]] {
        var row = [TelegramButton]()
        if ack { row.append(TelegramButton("👀 Беру", BotButton.ack.data(i.id))) }
        row.append(TelegramButton("🔕 1 час", BotButton.snooze.data(i.id)))
        row.append(TelegramButton("📊 Подробнее", BotButton.details.data(i.id)))
        return [row]
    }

    /// The message for one alert event.
    /// - Parameters:
    ///   - notified: for an escalation, who was told and did not answer.
    public static func alert(_ kind: NotifyKind, _ i: NotifyIncident, acks: [NotifyAck] = [],
                             notified: [String] = [], tz: TimeZone = NotifyPrefs.defaults.timeZone,
                             now: Date) -> TelegramMessage {
        let lasted = duration(now.timeIntervalSince(i.startedAt))
        switch kind {
        case .resolved:
            let took = duration((i.endedAt ?? now).timeIntervalSince(i.startedAt))
            return TelegramMessage("✅ <b>\(escape(i.objectName))</b>: снова в норме\n\(escape(i.message))\nПростой \(took)")
        case .escalation:
            var lines = ["⚠️ <b>Никто не взял за \(Int(Notify.escalateAfter / 60)) минут</b>",
                         "\(icon(i.severity)) \(i.clientName.map { escape($0) + " · " } ?? "")\(escape(i.objectName))",
                         escape(i.message), "Длится \(lasted)"]
            if !notified.isEmpty { lines.append("Получили: \(notified.map(escape).joined(separator: ", ")). Ответа нет.") }
            return TelegramMessage(lines.joined(separator: "\n"), buttons: buttons(i))
        case .reminder:
            var lines = [head(i) + " · всё ещё"]
            if let c = client(i) { lines.append(c) }
            lines += [escape(i.message), "Длится \(lasted)"]
            return TelegramMessage(lines.joined(separator: "\n"), buttons: buttons(i))
        default:
            var lines = [head(i)]
            if let c = client(i) { lines.append(c) }
            lines.append(escape(i.message))
            if now.timeIntervalSince(i.startedAt) >= 60 { lines.append("Длится \(lasted)") }
            if let a = acks.first { lines.append("<b>👀 Взял \(escape(a.name)), \(time(a.at, tz))</b>") }
            return TelegramMessage(lines.joined(separator: "\n"), buttons: buttons(i, ack: acks.isEmpty))
        }
    }

    /// The first message, edited once someone took the problem: everyone sees who.
    public static func taken(_ i: NotifyIncident, by a: NotifyAck, tz: TimeZone = NotifyPrefs.defaults.timeZone,
                             now: Date) -> TelegramMessage {
        alert(.fired, i, acks: [a], tz: tz, now: now)
    }

    /// The first message, edited when the problem is over (the "back to normal"
    /// itself goes as a reply to it, so it rings).
    public static func closed(_ i: NotifyIncident) -> TelegramMessage {
        let took = duration((i.endedAt ?? i.startedAt).timeIntervalSince(i.startedAt))
        return TelegramMessage("<s>\(icon(i.severity))</s> ✅ <b>\(escape(i.objectName))</b>\n\(escape(i.message))\nРешено за \(took)")
    }

    /// Three or more problems of one client in one round.
    public static func bundle(_ list: [NotifyIncident]) -> TelegramMessage {
        let worst = list.map(\.severity).max() ?? .warning
        let title = list.first?.clientName ?? list.first?.objectName ?? ""
        var lines = ["\(icon(worst)) <b>\(escape(title)): \(list.count) \(problems(list.count))</b>"]
        for i in list {
            lines.append("\(i.severity == .critical ? "🔴" : "🟡") \(escape(i.objectName)) · \(escape(i.message))")
        }
        let scope = list.first.map { $0.clientID ?? $0.objectID ?? $0.id } ?? ""
        return TelegramMessage(lines.joined(separator: "\n"), buttons: [[
            TelegramButton("👀 Беру все", BotButton.ackClient.data(scope)),
        ]])
    }

    static func problems(_ n: Int) -> String {
        let d = n % 10, h = n % 100
        if d == 1 && h != 11 { return "проблема" }
        if (2...4).contains(d) && !(12...14).contains(h) { return "проблемы" }
        return "проблем"
    }

    /// One calm message instead of an alarm for each unreachable server.
    public static func massOutage(down: Int, total: Int) -> TelegramMessage {
        TelegramMessage("""
        🟠 <b>Хаб не видит \(down) из \(total) серверов</b>
        Похоже, проблема у самого хаба или его сети, а не у серверов.
        По отдельным серверам не пишу, пока это не прояснится.
        """)
    }

    public static func massOutageOver(total: Int) -> TelegramMessage {
        TelegramMessage("✅ <b>Хаб снова видит серверы</b>\nНа связи все \(total)")
    }

    /// The morning «Прогноз», with what was kept from the quiet hours.
    /// - Parameters:
    ///   - forecast: lines from `Forecast.items`.
    ///   - night: problems held during quiet hours.
    public static func digest(forecast: [String], night: [NotifyIncident],
                              tz: TimeZone = NotifyPrefs.defaults.timeZone) -> TelegramMessage? {
        guard !forecast.isEmpty || !night.isEmpty else { return nil }
        var lines = ["☀️ <b>Прогноз на сегодня</b>"]
        lines += forecast.isEmpty ? ["Ничего не заканчивается в ближайшие дни"] : forecast.map { "🟡 " + escape($0) }
        if !night.isEmpty {
            lines += ["", "<b>За ночь (тихие часы)</b>"]
            for i in night.sorted(by: { $0.startedAt < $1.startedAt }) {
                var l = "\(icon(i.severity)) \(time(i.startedAt, tz)) \(escape(i.objectName)) · \(escape(i.message))"
                if let end = i.endedAt { l += ", прошло за \(duration(end.timeIntervalSince(i.startedAt)))" }
                lines.append(l)
            }
        }
        return TelegramMessage(lines.joined(separator: "\n"))
    }

    /// 📊 Подробнее: the latest numbers of a server.
    public static func details(_ name: String, _ s: Snapshot, tz: TimeZone = NotifyPrefs.defaults.timeZone) -> TelegramMessage {
        func pct(_ v: Double) -> String { String(format: "%.0f%%", v) }
        var rows = ["CPU     \(pct(s.cpu.usagePercent))", "Память  \(pct(s.memory.usedPercent))"]
        for d in (s.disks ?? []).prefix(4) { rows.append("Диск \(d.mount)".padding(toLength: 8, withPad: " ", startingAt: 0) + " \(pct(d.usedPercent))") }
        rows.append("Включён \(duration(s.uptimeSeconds))")
        var lines = ["<b>\(escape(name))</b> · \(time(s.time, tz))", "<pre>\(escape(rows.joined(separator: "\n")))</pre>"]
        let ctrs = s.containers ?? []
        if !ctrs.isEmpty {
            let bad = ctrs.filter { $0.state != "running" || $0.health == "unhealthy" }
            if bad.isEmpty {
                lines.append("Контейнеры: все \(ctrs.count) работают")
            } else {
                let names = bad.map { "\(escape($0.name)) (\($0.state == "running" ? "нездоров" : "остановлен"))" }
                lines.append("Контейнеры: \(names.joined(separator: ", ")), остальные \(ctrs.count - bad.count) работают")
            }
        }
        return TelegramMessage(lines.joined(separator: "\n"))
    }

    /// One client in /status.
    public struct ClientState: Equatable, Sendable {
        public var name: String
        public var servers: Int
        public var sites: Int
        public var warnings: Int
        public var criticals: Int
        public init(name: String, servers: Int, sites: Int, warnings: Int, criticals: Int) {
            self.name = name; self.servers = servers; self.sites = sites; self.warnings = warnings; self.criticals = criticals
        }
    }

    public static func status(_ clients: [ClientState]) -> TelegramMessage {
        guard !clients.isEmpty else { return TelegramMessage("У вас пока нет клиентов с оповещениями") }
        var lines = ["<b>Ваши клиенты</b>"]
        for c in clients {
            if c.criticals > 0 {
                lines.append("🔴 \(escape(c.name)): критичных \(c.criticals)\(c.warnings > 0 ? ", предупреждений \(c.warnings)" : "")")
            } else if c.warnings > 0 {
                lines.append("🟡 \(escape(c.name)): предупреждений \(c.warnings)")
            } else {
                lines.append("🟢 \(escape(c.name)): серверов \(c.servers), сайтов \(c.sites), всё в норме")
            }
        }
        lines += ["", "/problems — что сейчас не так", "/mute 2h — тишина на 2 часа"]
        return TelegramMessage(lines.joined(separator: "\n"))
    }

    public static func problemsList(_ open: [NotifyIncident], now: Date) -> TelegramMessage {
        guard !open.isEmpty else { return TelegramMessage("🟢 Сейчас всё в норме") }
        let lines = open.sorted { ($0.severity, $1.startedAt) > ($1.severity, $0.startedAt) }.map {
            "\(icon($0.severity)) \(escape($0.objectName)) · \(escape($0.message)) · \(duration(now.timeIntervalSince($0.startedAt)))"
        }
        return TelegramMessage((["<b>Сейчас не так: \(open.count)</b>"] + lines).joined(separator: "\n"))
    }

    public static func linked(name: String, clients: [String], prefs: NotifyPrefs) -> TelegramMessage {
        var lines = ["Готово, \(escape(name)). Telegram привязан к вашему кабинету."]
        if clients.isEmpty {
            lines.append("Пока нет клиентов, по которым вам положены оповещения.")
        } else {
            lines += ["", "Буду писать о проблемах у клиентов:"] + clients.map { "• " + escape($0) }
        }
        if let f = prefs.quietFrom, let t = prefs.quietTo {
            func hm(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }
            lines += ["", "Тихие часы: \(hm(f))–\(hm(t))\(prefs.criticalInQuiet ? ", критичные приходят всегда" : "")."]
        }
        lines.append("Настройки: /settings")
        return TelegramMessage(lines.joined(separator: "\n"))
    }

    public static let closedBot = TelegramMessage("Этот бот закрытый. Подключить его можно в своём кабинете: «Подключить Telegram».")
    public static let codeExpired = TelegramMessage("Код устарел или уже использован. Получите новый в кабинете: «Подключить Telegram».")
    public static let unlinked = TelegramMessage("Telegram отключён от кабинета. Уведомления больше не придут.")
    public static let noRights = "Нет прав на этого клиента"

    public static func muted(until: Date, tz: TimeZone) -> TelegramMessage {
        TelegramMessage("🔕 Тишина до \(time(until, tz)). Критичные тоже не придут, кроме эскалации генеральному админу.")
    }

    public static func settings(_ p: NotifyPrefs) -> TelegramMessage {
        func hm(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }
        let quiet = p.quietFrom.flatMap { f in p.quietTo.map { "\(hm(f))–\(hm($0))" } } ?? "нет"
        return TelegramMessage("""
        <b>Ваши настройки</b>
        Присылать: \(p.minSeverity == .critical ? "только критичные" : "критичные и предупреждения")
        Тихие часы: \(quiet)\(p.quietFrom != nil ? (p.criticalInQuiet ? ", критичные приходят" : ", критичные тоже ждут утра") : "")
        Утренний прогноз: \(p.digestEnabled ? hm(p.digestTime) : "выключен")
        Изменить можно в кабинете, раздел «Уведомления».
        """)
    }
}
