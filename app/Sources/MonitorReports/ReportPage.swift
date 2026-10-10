import Foundation

/// The report as one HTML page: what the client opens by the link, and what
/// the hub prints to PDF. Same look as the Mac app (docs/design-context.md):
/// system font, dense tables, colour only for status. Self-contained: no
/// scripts, no external files, so it renders the same in a browser and in a
/// headless Chromium printing to A4.
public enum ReportPage {
    public enum Mode: Sendable {
        /// Follows the viewer's light or dark theme; shows the PDF link.
        case web(pdfURL: String?)
        /// Always light, A4 margins.
        case pdf
    }

    /// Sections a client can turn off (`rep.client_report_settings.sections`).
    public enum Section: String, CaseIterable, Sendable {
        case summary, prevented, uptime, incidents, backups, work_done, forecasts
    }

    public static func html(_ r: ClientReport, comment: String = "", mode: Mode, timeZone: TimeZone,
                            sections: Set<Section> = Set(Section.allCases)) -> String {
        let tz = timeZone
        var b = ""
        b += "<!doctype html><html lang=\"ru\"><head><meta charset=\"utf-8\">"
        b += "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        b += "<meta name=\"robots\" content=\"noindex, nofollow\">"
        b += "<title>\(e("Отчёт за \(Fmt.month(r.periodStart)) · \(r.clientName)"))</title>"
        b += "<style>\(css(mode))</style></head><body><main class=\"sheet\">"

        // Header and the four numbers.
        b += "<header class=\"sec\"><div class=\"top\"><div>"
        b += "<div class=\"cap\">Отчёт о работе серверов и сайтов · \(e(Fmt.month(r.periodStart)))</div>"
        b += "<h1>\(e(r.clientName))</h1></div>"
        b += "<div class=\"meta\">\(e(r.signature))<br>сформирован \(e(Fmt.dayLong(r.generatedAt, tz)))"
        if case .web(let pdf?) = mode { b += "<br><a href=\"\(e(pdf))\">Скачать PDF</a>" }
        b += "</div></div>"
        let symbol = r.status == .ok ? "ok" : r.status == .issues ? "warn" : "bad"
        let label = r.status == .ok ? "Норма" : r.status == .issues ? "Были проблемы" : "Серьёзные проблемы"
        b += "<div class=\"status\">\(sym(symbol, label))<p><b>\(e(r.headline))</b>"
        if let d = r.detail { b += " \(e(d))" }
        b += "</p></div>"
        if sections.contains(.summary) {
            let t = r.totals
            var slaNote = "\(t.siteCount) \(plural(t.siteCount, "сайт", "сайта", "сайтов"))"
            var slaBad = false
            if let sla = t.slaTarget, let up = t.siteUptime {
                slaBad = up < sla
                slaNote = "цель \(Fmt.percent(sla)) " + (slaBad ? "не выполнена" : "выполнена")
            }
            b += "<div class=\"nums\">"
            b += num("Доступность сайтов", Fmt.percent(t.siteUptime), slaNote, bad: slaBad)
            b += num("Доступность серверов", Fmt.percent(t.serverUptime), "\(t.serverCount) \(plural(t.serverCount, "сервер", "сервера", "серверов"))")
            b += num("Сбоев", "\(t.incidents)", t.downtimeSeconds > 0 ? "простой \(Fmt.duration(t.downtimeSeconds))" : "простоя не было")
            b += num("Предотвращено", "\(t.prevented)", "исправлено до последствий")
            b += "</div>"
        }
        b += "</header>"

        if sections.contains(.prevented) && !r.prevented.isEmpty {
            b += head("Предотвращено", "что случилось бы, если бы никто не следил")
            b += "<div class=\"group\">"
            for p in r.prevented {
                var title = p.title
                if let w = p.wouldHappenAt, p.detail != nil { title += " около \(Fmt.dayShort(w, tz))" }
                b += "<div class=\"row\">\(sym("ok", "Предотвращено"))<div><div class=\"what\">\(e(title))</div>"
                if let d = p.detail, d != p.title { b += "<p>\(e(d))</p>" }
                b += "<div class=\"steps\"><span>замечено \(e(Fmt.dayShort(p.seenAt, tz)))</span>"
                if let w = p.wouldHappenAt { b += "<span>случилось бы ~\(e(Fmt.dayShort(w, tz)))</span>" }
                b += "<span class=\"done\">\(e(Fmt.dayShort(p.fixedAt, tz)))\(p.fix.map { ": " + e($0) } ?? ": исправлено")</span></div></div>"
                b += "<span class=\"side\">\(e(Fmt.dayShort(p.fixedAt, tz)))</span></div>"
            }
            b += "</div></section>"
        }

        if sections.contains(.uptime) && !r.sites.isEmpty {
            b += head("Сайты", "проверка каждую минуту из нескольких стран")
            b += "<div class=\"tbl\"><table><thead><tr><th>Сайт</th><th>\(e(dayRange(r)))</th><th class=\"r\">Доступность</th><th class=\"r\">Ответ</th><th class=\"r\">SSL</th><th class=\"r\">Домен</th></tr></thead><tbody>"
            for s in r.sites {
                b += "<tr><td>\(dot(s.uptime.map { $0 < 1 } ?? false))\(e(s.name))\(sub(s.note))</td><td>\(strip(s.days))</td>"
                b += "<td class=\"r\">\(e(Fmt.percent(s.uptime)))</td><td class=\"r\">\(e(Fmt.ms(s.latencyMs)))</td>"
                b += "<td class=\"r\(expiryClass(s.tlsDays, warn: 21))\">\(e(s.tlsDays.map { "\($0) дн" } ?? "—"))</td>"
                b += "<td class=\"r\(expiryClass(s.domainDays, warn: 60))\">\(e(s.domainDays.map { "\($0) дн" } ?? "—"))</td></tr>"
            }
            b += "</tbody></table></div><span class=\"cap\">Жёлтый день: были отдельные ошибки. Красный: сайт был недоступен. Серый: нет данных.</span></section>"
        }

        if sections.contains(.uptime) && !r.servers.isEmpty {
            b += head("Серверы", "максимум за месяц")
            b += "<div class=\"tbl\"><table><thead><tr><th>Сервер</th><th class=\"r\">Доступность</th><th class=\"r\">CPU</th><th class=\"r\">Память</th><th class=\"r\">Диск</th><th class=\"r\">Места хватит</th><th class=\"r\">Перезагрузки</th></tr></thead><tbody>"
            for s in r.servers {
                let diskWarn = (s.diskMax ?? 0) >= 75 || (s.diskRunwayDays ?? .max) < 90
                b += "<tr><td>\(dot(s.uptime.map { $0 < 1 } ?? false))\(e(s.name))\(sub(s.note))</td>"
                b += "<td class=\"r\">\(e(Fmt.percent(s.uptime)))</td><td class=\"r\">\(e(Fmt.level(s.cpuMax)))</td><td class=\"r\">\(e(Fmt.level(s.memMax)))</td>"
                b += "<td class=\"r\(diskWarn ? " t-warn" : "")\">\(e(Fmt.level(s.diskMax)))</td>"
                b += "<td class=\"r\((s.diskRunwayDays ?? .max) < 90 ? " t-warn" : "")\">\(e(Fmt.runway(s.diskRunwayDays)))</td>"
                b += "<td class=\"r\">\(s.reboots)</td></tr>"
            }
            b += "</tbody></table></div>"
            for c in r.diskCharts { b += chart(c) }
            b += "</section>"
        }

        if sections.contains(.incidents) {
            b += head("Сбои", "всё, что могли заметить ваши клиенты")
            if r.incidents.isEmpty {
                b += "<div class=\"group\"><div class=\"row\">\(sym("ok", "Норма"))<div class=\"what\">Сбоев не было</div><span></span></div></div>"
            } else {
                b += "<div class=\"group\">"
                for i in r.incidents {
                    let dur = i.ongoing ? "продолжается" : Fmt.duration(i.durationSeconds)
                    b += "<div class=\"row\">\(sym(i.critical ? "bad" : "warn", i.critical ? "Сбой" : "Предупреждение"))<div>"
                    b += "<div class=\"what\">\(e(i.object)): \(e(i.title.lowercasedFirst)), \(e(dur))</div>"
                    let text = [i.cause, i.resolution].compactMap { $0 }.joined(separator: " ")
                    if !text.isEmpty { b += "<p>\(e(text))</p>" }
                    b += "</div><span class=\"side\">\(e(Fmt.dayTime(i.startedAt, tz)))</span></div>"
                }
                b += "</div>"
            }
            b += "</section>"
        }

        if sections.contains(.backups) && !r.backups.isEmpty {
            b += head("Резервные копии", "копия за каждый день месяца")
            b += "<div class=\"tbl\"><table><thead><tr><th>База</th><th class=\"r\">Копий</th><th class=\"r\">Последняя</th><th class=\"r\">Размер</th><th>Состояние</th></tr></thead><tbody>"
            for k in r.backups {
                b += "<tr><td>\(e(k.target))\(sub(k.server))</td><td class=\"r\">\(k.good) из \(k.expected)</td>"
                b += "<td class=\"r\">\(e(k.last.map { Fmt.dayTime($0, tz) } ?? "нет"))</td><td class=\"r\">\(e(Fmt.bytes(k.lastBytes)))</td>"
                if k.missedDays.isEmpty {
                    b += "<td>\(dot(false))в порядке</td></tr>"
                } else {
                    let list = k.missedDays.prefix(3).map(Fmt.dayShort).joined(separator: ", ") + (k.missedDays.count > 3 ? "…" : "")
                    b += "<td class=\"t-warn\">\(k.missedDays.count) \(plural(k.missedDays.count, "пропуск", "пропуска", "пропусков")): \(e(list))</td></tr>"
                }
            }
            b += "</tbody></table></div></section>"
        }

        if sections.contains(.work_done) && !r.work.isEmpty {
            b += "<section class=\"sec\"><h2>Работы за месяц</h2><div class=\"group\"><ul class=\"works\">"
            for w in r.work { b += "<li><span>\(e(Fmt.dayNumeric(w.day)))</span>\(e(w.text))</li>" }
            b += "</ul></div></section>"
        }

        if sections.contains(.forecasts) && !r.attention.isEmpty {
            b += head("Скоро потребует внимания", "прогноз на 3 месяца")
            b += "<div class=\"group\">"
            for a in r.attention {
                b += "<div class=\"row\">\(sym("warn", "Внимание"))<div><div class=\"what\">\(e(a.title))</div>"
                if let d = a.detail { b += "<p>\(e(d))</p>" }
                b += "</div><div class=\"side\">\(e(a.due.map { Fmt.dayLong($0, tz) } ?? ""))"
                b += a.needsClient ? "<br><span class=\"badge\">нужно ваше решение</span>" : "<br>сделаю сам"
                b += "</div></div>"
            }
            b += "</div></section>"
        }

        let note = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty {
            b += "<section class=\"sec\"><h2>От администратора</h2><div class=\"note\">"
            b += e(note).replacingOccurrences(of: "\n", with: "<br>")
            b += "<div class=\"sig\">\(e(r.signature))</div></div></section>"
        }

        b += "<footer><span class=\"slogan\">Слежу за вашими серверами и сайтами, предупреждаю проблемы до того, как они случатся.</span>"
        b += "<span>\(e(r.footer).replacingOccurrences(of: "\n", with: "<br>"))</span></footer>"
        b += "</main></body></html>"
        return b
    }

    // MARK: - Pieces

    static func head(_ title: String, _ caption: String) -> String {
        "<section class=\"sec\"><div class=\"sec-head\"><h2>\(e(title))</h2><span class=\"cap\">\(e(caption))</span></div>"
    }

    static func num(_ k: String, _ v: String, _ n: String, bad: Bool = false) -> String {
        "<div><span class=\"k\">\(e(k))</span><span class=\"v\">\(e(v))</span><span class=\"n\(bad ? " t-bad" : "")\">\(e(n))</span></div>"
    }

    /// A status mark with its shape, never colour alone.
    static func sym(_ kind: String, _ label: String) -> String {
        "<span class=\"sym \(kind)\" role=\"img\" aria-label=\"\(e(label))\"></span>"
    }

    static func dot(_ warn: Bool) -> String { "<span class=\"dot\(warn ? " w" : "")\"></span>" }

    static func sub(_ note: String?) -> String {
        guard let note, !note.isEmpty else { return "" }
        return "<span class=\"sub\">\(e(note))</span>"
    }

    static func expiryClass(_ days: Int?, warn: Int) -> String {
        guard let days else { return "" }
        return days < 7 ? " t-bad" : days < warn ? " t-warn" : ""
    }

    static func dayRange(_ r: ClientReport) -> String {
        let a = Int(r.periodStart.suffix(2)) ?? 1, z = Int(r.periodEnd.suffix(2)) ?? 30
        let p = r.periodStart.split(separator: "-").compactMap { Int($0) }
        return p.count == 3 ? "\(a)–\(z) \(Fmt.monthsGenitive[p[1] - 1])" : ""
    }

    static func strip(_ days: [ClientReport.DayMark]) -> String {
        var s = "<span class=\"days\" style=\"grid-template-columns:repeat(\(max(1, days.count)),4px)\" role=\"img\" aria-label=\"По дням\">"
        for d in days {
            switch d {
            case .ok: s += "<i></i>"
            case .errors: s += "<i class=\"w\"></i>"
            case .down: s += "<i class=\"b\"></i>"
            case .none: s += "<i class=\"n\"></i>"
            }
        }
        return s + "</span>"
    }

    /// Fill line with a 10 % area, dashed «full» rule, dotted forecast to the
    /// day it would have filled, a green point at the fix.
    static func chart(_ c: ClientReport.DiskChart) -> String {
        let n = c.percent.count
        guard n > 1, c.percent.contains(where: { $0 != nil }) else { return "" }
        let W = 640.0, H = 170.0, L = 34.0, R = 12.0, T = 10.0, B = 22.0
        let lo = max(0, ((c.percent.compactMap { $0 }.min() ?? 0) / 20).rounded(.down) * 20 - 20)
        func x(_ d: Double) -> Double { L + d / Double(n - 1) * (W - L - R) }
        func y(_ p: Double) -> Double { T + (100 - min(100, max(lo, p))) / (100 - lo) * (H - T - B) }
        func f(_ v: Double) -> String { String(format: "%.1f", v) }
        var s = "<div class=\"chart\"><span class=\"cap\">Диск \(e(c.server)) (\(e(c.mount))), % заполнения за месяц</span>"
        s += "<svg viewBox=\"0 0 640 170\" role=\"img\" aria-label=\"Заполнение диска \(e(c.server)) по дням\">"
        var tick = lo
        while tick <= 100 {
            s += "<line x1=\"\(f(L))\" x2=\"\(f(W - R))\" y1=\"\(f(y(tick)))\" y2=\"\(f(y(tick)))\" class=\"\(tick == 100 ? "lim" : "grid")\"/>"
            s += "<text x=\"\(f(L - 6))\" y=\"\(f(y(tick) + 3))\" text-anchor=\"end\">\(Int(tick))%</text>"
            tick += 20
        }
        for d in Set([0, n / 4, n / 2, 3 * n / 4, n - 1]).sorted() {
            s += "<text x=\"\(f(x(Double(d))))\" y=\"\(f(H - 6))\" text-anchor=\"middle\">\(d + 1)</text>"
        }
        // Line with gaps where there is no data: a missing day is not a value.
        var segments: [[(Int, Double)]] = [[]]
        for (i, v) in c.percent.enumerated() {
            if let v { segments[segments.count - 1].append((i, v)) } else if !segments.last!.isEmpty { segments.append([]) }
        }
        for seg in segments where !seg.isEmpty {
            let line = seg.enumerated().map { ($0.offset == 0 ? "M" : "L") + f(x(Double($0.element.0))) + " " + f(y($0.element.1)) }.joined(separator: " ")
            s += "<path class=\"area\" d=\"\(line) L\(f(x(Double(seg.last!.0)))) \(f(y(lo))) L\(f(x(Double(seg[0].0)))) \(f(y(lo))) Z\"/>"
            s += "<path class=\"ln\" d=\"\(line)\"/>"
        }
        if let fix = c.fixDay, fix > 0, let before = c.percent[..<fix].lastIndex(where: { $0 != nil }), let wf = c.wouldFillDay {
            let hit = min(wf, Double(n - 1))
            let reach = hit < wf ? c.percent[before]! + (100 - c.percent[before]!) * (hit - Double(before)) / (wf - Double(before)) : 100
            s += "<path class=\"fc\" d=\"M\(f(x(Double(before)))) \(f(y(c.percent[before]!))) L\(f(x(hit))) \(f(y(reach)))\"/>"
            s += "<text x=\"\(f(min(x(hit) + 6, W - R - 130)))\" y=\"\(f(y(reach) + 12))\">без исправления</text>"
        }
        if let fix = c.fixDay, fix < n, let v = c.percent[fix] ?? c.percent[min(n - 1, fix + 1)] {
            s += "<circle cx=\"\(f(x(Double(fix))))\" cy=\"\(f(y(v)))\" r=\"3.5\" class=\"fix\"/>"
            if let label = c.fixLabel {
                s += "<text x=\"\(f(min(x(Double(fix)) + 8, W - R - 200)))\" y=\"\(f(y(v) + 14))\">\(e(String(label.prefix(40))))</text>"
            }
        }
        return s + "</svg></div>"
    }

    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let n10 = n % 10, n100 = n % 100
        if n10 == 1 && n100 != 11 { return one }
        if (2...4).contains(n10) && !(12...14).contains(n100) { return few }
        return many
    }

    /// HTML escaping: every text in the report comes from people or servers.
    static func e(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    // MARK: - Style

    static let light = """
    --bg:#ececec;--window:#ffffff;--group:#f5f5f7;--ink:#1d1d1f;--secondary:#6e6e73;--tertiary:#a1a1a6;\
    --sep:#e0e0e3;--accent:#007aff;--green:#34c759;--yellow:#ffcc00;--orange-text:#c26a00;--red:#ff3b30;\
    --fill-10:rgba(0,122,255,.10);
    """
    static let dark = """
    --bg:#161617;--window:#1e1e1f;--group:#2a2a2c;--ink:#f2f2f7;--secondary:#98989d;--tertiary:#636366;\
    --sep:#38383a;--accent:#0a84ff;--green:#30d158;--yellow:#ffd60a;--orange-text:#ff9f0a;--red:#ff453a;\
    --fill-10:rgba(10,132,255,.14);color-scheme:dark;
    """

    static func css(_ mode: Mode) -> String {
        var s = ":root{\(light)--f:-apple-system,BlinkMacSystemFont,\"SF Pro Text\",\"Helvetica Neue\",\"Segoe UI\",Roboto,Arial,sans-serif;}"
        switch mode {
        case .web:
            s += "@media (prefers-color-scheme: dark){:root{\(dark)}}"
            s += "body{padding:20px 16px}.sheet{border:1px solid var(--sep);border-radius:10px;padding:28px clamp(16px,4vw,36px)}"
        case .pdf:
            s += "@page{size:A4;margin:14mm 12mm}body{background:#fff;padding:0}.sheet{padding:0;max-width:none}"
            s += "section,.row,tr{break-inside:avoid}"
        }
        s += common
        return s
    }

    static let common = """
    *{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font-family:var(--f);font-size:13px;line-height:1.45;-webkit-font-smoothing:antialiased}\
    a{color:var(--accent)}.sheet{max-width:860px;margin:0 auto;background:var(--window);display:grid;gap:26px}\
    h1,h2{margin:0;text-wrap:balance}h2{font-size:13px;font-weight:600}.sec{display:grid;gap:8px}\
    .sec-head{display:flex;justify-content:space-between;align-items:baseline;gap:12px;flex-wrap:wrap}\
    .cap{font-size:11px;color:var(--secondary)}.group{background:var(--group);border-radius:8px;padding:2px 12px}\
    .top{display:flex;justify-content:space-between;gap:16px;flex-wrap:wrap;align-items:flex-start}\
    .top h1{font-size:22px;font-weight:600;line-height:1.25}.top .meta{text-align:right;font-size:11px;color:var(--secondary)}\
    .status{display:flex;gap:10px;align-items:flex-start;padding:10px 0}.status p{margin:0;max-width:72ch}.status b{font-weight:600}\
    .sym{flex:none;display:inline-grid;place-items:center;width:14px;height:14px;border-radius:50%;color:#fff;font-size:9px;font-weight:700;line-height:1;vertical-align:-2px}\
    .sym.ok{background:var(--green)}.sym.ok::before{content:"✓"}\
    .sym.warn{background:none;width:15px;border-radius:0}\
    .sym.warn::before{content:"";width:0;height:0;border-left:7.5px solid transparent;border-right:7.5px solid transparent;border-bottom:13px solid var(--yellow);grid-area:1/1}\
    .sym.warn::after{content:"!";grid-area:1/1;font-size:9px;margin-top:4px;color:#1d1d1f}\
    .sym.bad{background:var(--red);border-radius:3px}.sym.bad::before{content:"✕"}\
    .dot{display:inline-block;width:7px;height:7px;border-radius:50%;background:var(--green);vertical-align:1px;margin-right:6px}.dot.w{background:var(--yellow)}\
    .t-warn{color:var(--orange-text)}.t-bad{color:var(--red)}\
    .nums{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));border-top:1px solid var(--sep);border-bottom:1px solid var(--sep)}\
    .nums div{padding:10px 14px 10px 0;display:grid;gap:1px}.nums div+div{padding-left:14px;border-left:1px solid var(--sep)}\
    .nums .k,.nums .n{font-size:11px;color:var(--secondary)}.nums .n.t-bad{color:var(--red)}\
    .nums .v{font-size:20px;font-weight:600;font-variant-numeric:tabular-nums}\
    @media (max-width:620px){.nums{grid-template-columns:repeat(2,minmax(0,1fr))}.nums div:nth-child(3){padding-left:0;border-left:0}.nums div:nth-child(n+3){border-top:1px solid var(--sep)}}\
    .row{display:grid;grid-template-columns:22px minmax(0,1fr) auto;gap:8px;padding:9px 0;border-bottom:1px solid var(--sep);align-items:start}\
    .row:last-child{border-bottom:0}.row .what{font-weight:500}.row p{margin:2px 0 0;color:var(--secondary);max-width:70ch}\
    .row .side{font-size:11px;color:var(--secondary);text-align:right;white-space:nowrap;font-variant-numeric:tabular-nums}\
    .steps{display:flex;flex-wrap:wrap;gap:2px 14px;margin-top:4px;font-size:11px;color:var(--secondary)}.steps .done{color:var(--ink)}\
    @media (max-width:520px){.row{grid-template-columns:22px minmax(0,1fr)}.row .side{grid-column:2;text-align:left}}\
    .tbl{overflow-x:auto}table{width:100%;border-collapse:collapse;min-width:600px;font-size:13px}\
    th{text-align:left;font-weight:400;font-size:11px;color:var(--secondary);padding:6px 12px 5px 0;border-bottom:1px solid var(--sep);white-space:nowrap}\
    td{padding:5px 12px 5px 0;border-bottom:1px solid var(--sep);height:22px;white-space:nowrap;font-variant-numeric:tabular-nums}\
    tr:last-child td{border-bottom:0}td.r,th.r{text-align:right}td .sub{color:var(--secondary);margin-left:6px}\
    .days{display:inline-grid;gap:1px;vertical-align:middle}.days i{display:block;height:12px;border-radius:1px;background:var(--green);opacity:.55}\
    .days i.w{background:var(--yellow);opacity:1}.days i.b{background:var(--red);opacity:1}.days i.n{background:var(--sep);opacity:1}\
    .chart{padding:10px 0 4px}.chart svg{width:100%;height:auto;display:block}\
    .chart text{fill:var(--secondary);font-family:var(--f);font-size:10px}.chart .grid{stroke:var(--sep);stroke-width:1}\
    .chart .lim{stroke:var(--red);stroke-width:1;stroke-dasharray:4 3}.chart .ln{stroke:var(--accent);stroke-width:1.5;fill:none}\
    .chart .fc{stroke:var(--secondary);stroke-width:1.2;fill:none;stroke-dasharray:3 3}.chart .area{fill:var(--fill-10)}.chart .fix{fill:var(--green)}\
    .works{margin:0;padding:4px 0;list-style:none;display:grid}\
    .works li{display:grid;grid-template-columns:52px minmax(0,1fr);gap:8px;padding:5px 0;border-bottom:1px solid var(--sep)}\
    .works li:last-child{border-bottom:0}.works span{color:var(--secondary);font-variant-numeric:tabular-nums}\
    .badge{font-size:11px;color:var(--accent);white-space:nowrap}.note{padding:10px 0;max-width:72ch}.note .sig{color:var(--secondary);margin-top:6px;font-size:12px}\
    footer{border-top:1px solid var(--sep);padding-top:12px;display:flex;justify-content:space-between;flex-wrap:wrap;gap:10px;font-size:11px;color:var(--secondary)}\
    footer .slogan{color:var(--ink);font-size:12px;max-width:48ch}
    """
}
