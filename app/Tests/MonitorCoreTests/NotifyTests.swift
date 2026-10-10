import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import MonitorCore

/// Telegram notifications from the hub: who gets what, quiet hours, bundles,
/// escalation, texts, the Bot API and the bot's answers.
final class NotifyTests: XCTestCase {
    let msk = TimeZone(identifier: "Europe/Moscow")!

    /// A moment in Moscow time.
    func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = msk
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    func incident(_ id: String = "i1", severity: Severity = .critical, client: String? = "c1",
                  started: Date, name: String = "Нидерланды VPN", message: String = "VPN amnezia-awg2 остановлен") -> NotifyIncident {
        NotifyIncident(id: id, objectID: "s-" + id, objectName: name, clientID: client,
                       clientName: client.map { "Клиент " + $0 }, key: "vpn:amnezia-awg2", severity: severity,
                       message: message, startedAt: started)
    }

    let night = NotifyPrefs(quietFrom: 23 * 60, quietTo: 8 * 60)

    // MARK: Quiet hours

    func testQuietHoursSpanMidnight() {
        // 2026-10-10 is a Saturday.
        XCTAssertTrue(Notify.isQuiet(night, now: at(2026, 10, 10, 23, 30)))
        XCTAssertTrue(Notify.isQuiet(night, now: at(2026, 10, 11, 3, 12)))
        XCTAssertFalse(Notify.isQuiet(night, now: at(2026, 10, 11, 8, 0)))
        XCTAssertFalse(Notify.isQuiet(night, now: at(2026, 10, 10, 14, 0)))
        XCTAssertFalse(Notify.isQuiet(NotifyPrefs(), now: at(2026, 10, 11, 3, 0)), "no quiet hours set")

        // Weekdays only: Friday night is quiet, Saturday night is not.
        var weekdays = night
        weekdays.quietDays = Set(1...5)
        XCTAssertTrue(Notify.isQuiet(weekdays, now: at(2026, 10, 10, 2, 0)), "night that began on Friday")
        XCTAssertFalse(Notify.isQuiet(weekdays, now: at(2026, 10, 11, 2, 0)), "night that began on Saturday")

        // A daytime range, in another time zone.
        let day = NotifyPrefs(timeZone: TimeZone(identifier: "UTC")!, quietFrom: 13 * 60, quietTo: 15 * 60)
        XCTAssertTrue(Notify.isQuiet(day, now: at(2026, 10, 10, 16, 30)), "16:30 Moscow is 13:30 UTC")
    }

    // MARK: Who gets what

    func testDecide() {
        let t = at(2026, 10, 11, 3, 12)
        let crit = incident(started: t)
        let warn = incident(severity: .warning, started: t)
        let ivan = NotifyRecipient(accountID: "ivan", name: "Иван", chatID: 1, prefs: night)

        XCTAssertEqual(Notify.decide(.fired, crit, for: NotifyRecipient(accountID: "x", name: "X", chatID: nil), now: t),
                       .skip("Telegram не привязан"))
        XCTAssertEqual(Notify.decide(.fired, crit, for: ivan, now: t), .send, "critical wakes up at night")
        XCTAssertEqual(Notify.decide(.fired, warn, for: ivan, now: t), .holdForMorning)
        XCTAssertEqual(Notify.decide(.fired, warn, for: ivan, now: at(2026, 10, 11, 12, 0)), .send)

        var sleeper = ivan
        sleeper.prefs.criticalInQuiet = false
        XCTAssertEqual(Notify.decide(.fired, crit, for: sleeper, now: t), .holdForMorning)

        var onlyCritical = ivan
        onlyCritical.prefs.minSeverity = .critical
        XCTAssertEqual(Notify.decide(.fired, warn, for: onlyCritical, now: at(2026, 10, 11, 12, 0)), .skip("ниже порога"))

        var muted = ivan
        muted.mutes = [NotifyMute(scope: .client, scopeID: "c1", until: t.addingTimeInterval(60))]
        XCTAssertEqual(Notify.decide(.fired, crit, for: muted, now: t), .skip("заглушено"))
        XCTAssertEqual(Notify.decide(.fired, crit, for: muted, now: t.addingTimeInterval(120)), .send, "mute ran out")

        let ack = NotifyAck(accountID: "m", name: "Михаил", at: t)
        XCTAssertEqual(Notify.decide(.reminder, crit, for: ivan, acks: [ack], now: t), .skip("уже взяли"))
        XCTAssertEqual(Notify.decide(.resolved, crit, for: ivan, acks: [ack], now: t), .send)
    }

    func testEscalationGoesToOwnerOnly() {
        let t = at(2026, 10, 11, 4, 7)
        let i = incident(started: t.addingTimeInterval(-17 * 60))
        var owner = NotifyRecipient(accountID: "m", name: "Михаил", chatID: 7, prefs: NotifyPrefs(quietFrom: 0, quietTo: 9 * 60,
                                    criticalInQuiet: false), isOwner: true)
        owner.mutes = [NotifyMute(scope: .client, scopeID: "c1")]
        let ivan = NotifyRecipient(accountID: "ivan", name: "Иван", chatID: 1)
        let plans = Notify.plan(.escalation, i, recipients: [owner, ivan], notified: ["Иван"], now: t)
        XCTAssertEqual(plans.map(\.accountID), ["m"], "quiet hours and a client mute do not stop it")
        XCTAssertTrue(plans[0].message.text.contains("Никто не взял за 15 минут"))
        XCTAssertTrue(plans[0].message.text.contains("Получили: Иван"))

        let open = [
            Notify.OpenIncident(incident: i, acks: [], escalated: false, notified: ["Иван"]),
            Notify.OpenIncident(incident: incident("i2", started: t.addingTimeInterval(-5 * 60)), acks: [], escalated: false, notified: []),
            Notify.OpenIncident(incident: incident("i3", started: t.addingTimeInterval(-20 * 60)),
                                acks: [NotifyAck(accountID: "ivan", name: "Иван", at: t)], escalated: false, notified: []),
            Notify.OpenIncident(incident: incident("i4", severity: .warning, started: t.addingTimeInterval(-60 * 60)),
                                acks: [], escalated: false, notified: []),
            Notify.OpenIncident(incident: incident("i5", started: t.addingTimeInterval(-60 * 60)), acks: [], escalated: true, notified: []),
        ]
        XCTAssertEqual(Notify.escalations(open, now: t).map(\.incident.id), ["i1"])
    }

    func testPlanDedupKeys() {
        let t = at(2026, 10, 10, 14, 0)
        let i = incident(started: t)
        let rs = [NotifyRecipient(accountID: "a", name: "A", chatID: 1), NotifyRecipient(accountID: "b", name: "B", chatID: nil)]
        XCTAssertEqual(Notify.plan(.fired, i, recipients: rs, now: t).map(\.dedupKey), ["fired:i1:a"])
        XCTAssertEqual(Notify.plan(.reminder, i, recipients: rs, reminder: 2, now: t).map(\.dedupKey), ["reminder:i1:3:a"])
    }

    func testBundleThreeOfOneClient() {
        let t = at(2026, 10, 10, 14, 40)
        let list = [
            incident("a", severity: .warning, client: "alfa", started: t, name: "wise1", message: "память занята на 94%"),
            incident("b", client: "alfa", started: t, name: "wise1", message: "сервис nginx не запущен"),
            incident("c", client: "beta", started: t, name: "beta-db"),
            incident("d", client: "alfa", started: t, name: "stalcad.ru", message: "недоступен из 3 стран"),
        ]
        let groups = Notify.bundle(list)
        XCTAssertEqual(groups.map { $0.map(\.id) }, [["b", "d", "a"], ["c"]], "criticals first inside a bundle")
        let m = TelegramText.bundle(groups[0])
        XCTAssertTrue(m.text.hasPrefix("🔴 <b>Клиент alfa: 3 проблемы</b>"))
        XCTAssertEqual(m.buttons[0][0].data, "akc:alfa")
        XCTAssertEqual(Notify.bundle(Array(list.prefix(2))).count, 2, "two are sent one by one")
    }

    func testMassOutage() {
        XCTAssertTrue(Notify.massOutage(down: 5, total: 7))
        XCTAssertFalse(Notify.massOutage(down: 3, total: 7))
        XCTAssertFalse(Notify.massOutage(down: 2, total: 2), "too few servers to tell")
    }

    // MARK: Texts

    func testAlertTexts() {
        let t = at(2026, 10, 11, 3, 12)
        var i = incident(started: t.addingTimeInterval(-120), name: "<NL>")
        let fired = TelegramText.alert(.fired, i, now: t)
        XCTAssertEqual(fired.text, "🔴 <b>&lt;NL&gt;</b>\nКлиент: Клиент c1\nVPN amnezia-awg2 остановлен\nДлится 2 мин")
        XCTAssertEqual(fired.buttons[0].map(\.data), ["ack:i1", "snz:i1", "det:i1"])

        let ack = NotifyAck(accountID: "m", name: "Михаил", at: at(2026, 10, 11, 3, 14))
        let taken = TelegramText.taken(i, by: ack, tz: msk, now: t)
        XCTAssertTrue(taken.text.hasSuffix("<b>👀 Взял Михаил, 03:14</b>"))
        XCTAssertEqual(taken.buttons[0].map(\.data), ["snz:i1", "det:i1"], "no second «Беру»")

        i.endedAt = t.addingTimeInterval(7 * 60)
        XCTAssertTrue(TelegramText.alert(.resolved, i, now: t).text.hasSuffix("Простой 9 мин"))
        XCTAssertTrue(TelegramText.closed(i).text.contains("Решено за 9 мин"))
        XCTAssertEqual(TelegramText.alert(.resolved, i, now: t).buttons, [])
    }

    func testDurationsAndPlurals() {
        XCTAssertEqual(TelegramText.duration(20), "1 мин")
        XCTAssertEqual(TelegramText.duration(65 * 60), "1 ч 5 мин")
        XCTAssertEqual(TelegramText.duration(3 * 3600), "3 ч")
        XCTAssertEqual(TelegramText.duration(51 * 3600), "2 дн 3 ч")
        XCTAssertEqual([1, 2, 5, 11, 21, 22, 25].map(TelegramText.problems),
                       ["проблема", "проблемы", "проблем", "проблем", "проблема", "проблемы", "проблем"])
    }

    func testDigestWithNight() {
        let started = at(2026, 10, 11, 2, 10)
        var i = incident(severity: .warning, started: started, name: "wise1", message: "CPU 93% дольше 5 мин")
        i.endedAt = started.addingTimeInterval(8 * 60)
        let m = TelegramText.digest(forecast: ["Диск wise1 заполнится через 12 дн"], night: [i], tz: msk)!
        XCTAssertEqual(m.text, """
        ☀️ <b>Прогноз на сегодня</b>
        🟡 Диск wise1 заполнится через 12 дн

        <b>За ночь (тихие часы)</b>
        🟡 02:10 wise1 · CPU 93% дольше 5 мин, прошло за 8 мин
        """)
        XCTAssertNil(TelegramText.digest(forecast: [], night: []))
    }

    // MARK: Parsing

    func update(_ text: String, chatType: String = "private") -> TelegramUpdate {
        TelegramUpdate(update_id: 1, message: TelegramIncoming(message_id: 5, chat: TelegramChat(id: 42, type: chatType),
                                                              from: TelegramUser(id: 42, username: "ivan"), text: text),
                       callback_query: nil)
    }

    func testParseCommands() {
        XCTAssertEqual(BotInput.parse(update("/start ABC"))?.input, .start(code: "ABC"))
        XCTAssertEqual(BotInput.parse(update("/start"))?.input, .start(code: nil))
        XCTAssertEqual(BotInput.parse(update("/status@MonitorBot"))?.input, .status)
        XCTAssertEqual(BotInput.parse(update("/mute 2h"))?.input, .mute(7200))
        XCTAssertEqual(BotInput.parse(update("/mute"))?.input, .mute(3600))
        XCTAssertEqual(BotInput.parse(update("/mute 5d"))?.input, .mute(86400), "capped at a day")
        XCTAssertEqual(BotInput.parse(update("привет"))?.input, .other)
        XCTAssertNil(BotInput.parse(update("/status", chatType: "group")), "groups are ignored")
        XCTAssertEqual(BotInput.muteDuration("30м"), 1800)
        XCTAssertNil(BotInput.muteDuration("abc"))

        let cb = TelegramUpdate(update_id: 2, message: nil, callback_query: TelegramCallback(
            id: "cb1", from: TelegramUser(id: 42), message: TelegramIncoming(message_id: 9, chat: TelegramChat(id: 42, type: "private")),
            data: "ack:i1"))
        XCTAssertEqual(BotInput.parse(cb)?.input, .button(.ack, id: "i1", callbackID: "cb1", messageID: 9))
        XCTAssertNil(BotButton.parse("ack:"))
        XCTAssertNil(BotButton.parse("zzz:i1"))
    }

    func testLinkCodes() {
        let c = LinkCode.generate()
        XCTAssertTrue(LinkCode.plausible(c))
        XCTAssertNotEqual(c, LinkCode.generate())
        XCTAssertEqual(LinkCode.hash(c).count, 32)
        XCTAssertFalse(LinkCode.plausible("short"))
        XCTAssertFalse(LinkCode.plausible("0OIl0OIl0OIl0OIl0OIl"), "look-alike characters are not used")
        XCTAssertEqual(LinkCode.link(bot: "MonitorBot", code: c)?.absoluteString, "https://t.me/MonitorBot?start=\(c)")
    }

    // MARK: Bot API

    func testAPISendAndErrors() async throws {
        let fake = FakeTelegram()
        let api = TelegramBotAPI(transport: fake)
        await fake.reply(200, #"{"ok":true,"result":{"message_id":77}}"#)
        let id = try await api.send(42, TelegramMessage("hi", buttons: [[TelegramButton("👀 Беру", "ack:i1")]]), replyTo: 5)
        XCTAssertEqual(id, 77)
        let method = await fake.method(0), body = await fake.body(0)
        XCTAssertEqual(method, "sendMessage")
        XCTAssertEqual(body["parse_mode"] as? String, "HTML")
        XCTAssertEqual((body["reply_parameters"] as? [String: Any])?["message_id"] as? Int, 5)
        let kb = (body["reply_markup"] as? [String: Any])?["inline_keyboard"] as? [[[String: Any]]]
        XCTAssertEqual(kb?[0][0]["callback_data"] as? String, "ack:i1")

        await fake.reply(403, #"{"ok":false,"error_code":403,"description":"Forbidden: bot was blocked by the user"}"#)
        do { try await api.send(42, TelegramMessage("x")); XCTFail() } catch { XCTAssertEqual(error as? TelegramError, .blocked) }
        await fake.reply(429, #"{"ok":false,"error_code":429,"description":"Too Many","parameters":{"retry_after":7}}"#)
        do { try await api.send(42, TelegramMessage("x")); XCTFail() } catch { XCTAssertEqual(error as? TelegramError, .retryAfter(7)) }
        await fake.reply(400, #"{"ok":false,"error_code":400,"description":"Bad Request: message is not modified"}"#)
        try await api.edit(42, message: 77, TelegramMessage("x"))
    }

    func testTokenNeverInErrors() {
        for e: TelegramError in [.blocked, .retryAfter(3), .badToken, .rejected(400, "x"), .network("сеть недоступна")] {
            XCTAssertFalse(e.description.contains("bot"), "no URL with the token")
        }
    }

    // MARK: Bot

    func testStartLinksWithValidCode() async throws {
        let fake = FakeTelegram(), store = MemoryTelegramStore()
        let code = LinkCode.generate()
        await store.addCode(LinkCode.hash(code), account: "ivan", name: "Иван", clients: ["Студия Альфа"])
        let bot = TelegramBot(api: TelegramBotAPI(transport: fake), store: store)
        await fake.reply(200, #"{"ok":true,"result":{"message_id":1}}"#)
        try await bot.handle(update("/start \(code)"))
        let linked = await store.links[42]
        XCTAssertEqual(linked, "ivan")
        let text = await fake.body(0)["text"] as? String
        XCTAssertTrue(text?.contains("Готово, Иван") == true)

        // The code works once.
        await fake.reply(200, #"{"ok":true,"result":{"message_id":2}}"#)
        let other = TelegramUpdate(update_id: 3, message: TelegramIncoming(message_id: 6, chat: TelegramChat(id: 43, type: "private"),
                                                                             text: "/start \(code)"), callback_query: nil)
        try await bot.handle(other)
        let second = await fake.body(1)["text"] as? String
        XCTAssertEqual(second, TelegramText.codeExpired.text)
    }

    func testStrangerGetsClosedBot() async throws {
        let fake = FakeTelegram()
        let bot = TelegramBot(api: TelegramBotAPI(transport: fake), store: MemoryTelegramStore())
        await fake.reply(200, #"{"ok":true,"result":{"message_id":1}}"#)
        try await bot.handle(update("/status"))
        let text = await fake.body(0)["text"] as? String
        XCTAssertEqual(text, TelegramText.closedBot.text)
    }

    func testAckEditsEveryCopy() async throws {
        let fake = FakeTelegram(), store = MemoryTelegramStore()
        let t = at(2026, 10, 11, 3, 14)
        await store.link(chat: 42, account: "m", name: "Михаил")
        await store.addIncident(incident(started: t.addingTimeInterval(-120)), allowed: ["m"],
                                sent: [TelegramSent(chatID: 42, messageID: 9, accountID: "m"),
                                       TelegramSent(chatID: 43, messageID: 11, accountID: "ivan")])
        let bot = TelegramBot(api: TelegramBotAPI(transport: fake), store: store, clock: { t })
        // editMessageText answers with the message.
        await fake.set([200, 200, 200], [#"{"ok":true,"result":true}"#, #"{"ok":true,"result":{"message_id":9}}"#,
                                         #"{"ok":true,"result":{"message_id":11}}"#])
        let cb = TelegramUpdate(update_id: 2, message: nil, callback_query: TelegramCallback(
            id: "cb1", from: TelegramUser(id: 42), message: TelegramIncoming(message_id: 9, chat: TelegramChat(id: 42, type: "private")),
            data: "ack:i1"))
        try await bot.handle(cb)
        let methods = await fake.methods()
        XCTAssertEqual(methods, ["answerCallbackQuery", "editMessageText", "editMessageText"])
        let edited = await fake.body(1)["text"] as? String
        XCTAssertTrue(edited?.contains("👀 Взял Михаил, 03:14") == true)
        let acks = await store.acks
        XCTAssertEqual(acks, ["i1:m"])

        // Someone without the right gets a refusal and changes nothing.
        await store.link(chat: 50, account: "x", name: "Чужой")
        await fake.set([200], [#"{"ok":true,"result":true}"#])
        let foreign = TelegramUpdate(update_id: 3, message: nil, callback_query: TelegramCallback(
            id: "cb2", from: TelegramUser(id: 50), message: TelegramIncoming(message_id: 1, chat: TelegramChat(id: 50, type: "private")),
            data: "ack:i1"))
        try await bot.handle(foreign)
        let note = await fake.body(0)["text"] as? String
        XCTAssertEqual(note, TelegramText.noRights)
        let after = await store.acks
        XCTAssertEqual(after, ["i1:m"])
    }

    func testFlushHandlesBlockedAndRateLimits() async throws {
        let fake = FakeTelegram(), store = MemoryTelegramStore()
        let t = at(2026, 10, 10, 14, 0)
        await store.queue([
            TelegramOutgoing(deliveryID: "d1", chatID: 1, message: TelegramMessage("a")),
            TelegramOutgoing(deliveryID: "d2", chatID: 1, message: TelegramMessage("b")),   // same chat: waits
            TelegramOutgoing(deliveryID: "d3", chatID: 2, message: TelegramMessage("c")),
            TelegramOutgoing(deliveryID: "d4", chatID: 3, message: TelegramMessage("d"), replyTo: 9),
        ])
        await fake.set([200, 403, 429], [#"{"ok":true,"result":{"message_id":100}}"#,
                                         #"{"ok":false,"error_code":403,"description":"blocked"}"#,
                                         #"{"ok":false,"error_code":429,"description":"slow","parameters":{"retry_after":30}}"#])
        let bot = TelegramBot(api: TelegramBotAPI(transport: fake), store: store, clock: { t })
        let n = try await bot.flush()
        XCTAssertEqual(n, 1)
        let sent = await store.sentIDs, failed = await store.failures, blocked = await store.blocked
        XCTAssertEqual(sent, ["d1": 100])
        XCTAssertEqual(blocked, [2])
        XCTAssertEqual(failed["d3"]?.retryAt, nil, "blocked: given up")
        XCTAssertEqual(failed["d4"]?.retryAt, t.addingTimeInterval(30))
        XCTAssertNil(failed["d2"], "left queued for the next flush")
    }

    func testFlushBundlesOneClient() async throws {
        let fake = FakeTelegram(), store = MemoryTelegramStore()
        let t = at(2026, 10, 10, 14, 40)
        func fired(_ id: String, _ client: String, chat: Int64 = 1) -> TelegramOutgoing {
            let i = incident(id, client: client, started: t)
            return TelegramOutgoing(deliveryID: "d-\(id)-\(chat)", chatID: chat, message: TelegramText.alert(.fired, i, now: t),
                                    bundle: client, incident: i)
        }
        await store.queue([fired("a", "alfa"), fired("b", "alfa"), fired("c", "beta", chat: 2), fired("d", "alfa"),
                           fired("e", "alfa", chat: 3)])
        await fake.set([200, 200, 200], [#"{"ok":true,"result":{"message_id":10}}"#, #"{"ok":true,"result":{"message_id":11}}"#,
                                         #"{"ok":true,"result":{"message_id":12}}"#])
        let bot = TelegramBot(api: TelegramBotAPI(transport: fake), store: store, clock: { t })
        let n = try await bot.flush()
        XCTAssertEqual(n, 3, "one list for chat 1, single messages for chats 2 and 3")
        let first = await fake.body(0)["text"] as? String
        XCTAssertTrue(first?.hasPrefix("🔴 <b>Клиент alfa: 3 проблемы</b>") == true)
        let sent = await store.sentIDs
        XCTAssertEqual(sent["d-a-1"], 10)
        XCTAssertEqual(sent["d-d-1"], 10, "every row of the list points at the one message")
        XCTAssertEqual(sent["d-c-2"], 11)
    }

    func testRetrySchedule() {
        let t = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(TelegramBot.retry(attempts: 1, now: t), t.addingTimeInterval(10))
        XCTAssertEqual(TelegramBot.retry(attempts: 3, now: t), t.addingTimeInterval(40))
        XCTAssertEqual(TelegramBot.retry(attempts: 7, now: t), t.addingTimeInterval(600))
        XCTAssertNil(TelegramBot.retry(attempts: 8, now: t))
    }
}

// MARK: Fakes

actor FakeTelegram: TelegramTransport {
    var replies: [(Int, String)] = []
    var calls: [(String, [String: Any])] = []

    func reply(_ code: Int, _ body: String) { replies.append((code, body)) }
    func method(_ i: Int) -> String { calls[i].0 }
    func body(_ i: Int) -> [String: Any] { calls[i].1 }
    func methods() -> [String] { calls.map(\.0) }
    func set(_ codes: [Int], _ bodies: [String]) {
        calls = []
        replies = zip(codes, bodies).map { ($0, $1) }
    }

    func post(_ method: String, json: Data, timeout: TimeInterval) async throws -> (Int, Data) {
        calls.append((method, (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] ?? [:]))
        guard !replies.isEmpty else { return (200, Data(#"{"ok":true,"result":true}"#.utf8)) }
        let (c, b) = replies.removeFirst()
        return (c, Data(b.utf8))
    }
}

actor MemoryTelegramStore: TelegramStore {
    struct Code { var account: String; var name: String; var clients: [String]; var used = false }
    var codes: [Data: Code] = [:]
    var links: [Int64: String] = [:]
    var names: [String: String] = [:]
    var incidents: [String: (NotifyIncident, Set<String>, [TelegramSent])] = [:]
    var acks: [String] = []
    var outbox: [TelegramOutgoing] = []
    var sentIDs: [String: Int64] = [:]
    var failures: [String: (error: String, retryAt: Date?)] = [:]
    var blocked: [Int64] = []
    var off: Int64?

    func addCode(_ h: Data, account: String, name: String, clients: [String]) {
        codes[h] = Code(account: account, name: name, clients: clients)
    }
    func link(chat: Int64, account: String, name: String) { links[chat] = account; names[account] = name }
    func addIncident(_ i: NotifyIncident, allowed: Set<String>, sent: [TelegramSent]) { incidents[i.id] = (i, allowed, sent) }
    func queue(_ o: [TelegramOutgoing]) { outbox = o }

    func redeem(codeHash: Data, chatID: Int64, username: String?, now: Date) async throws
        -> (name: String, clients: [String], prefs: NotifyPrefs)? {
        guard var c = codes[codeHash], !c.used else { return nil }
        c.used = true
        codes[codeHash] = c
        link(chat: chatID, account: c.account, name: c.name)
        return (c.name, c.clients, NotifyPrefs())
    }
    func account(chatID: Int64) async throws -> (accountID: String, name: String, prefs: NotifyPrefs)? {
        links[chatID].map { ($0, names[$0] ?? "", NotifyPrefs()) }
    }
    func unlink(chatID: Int64, now: Date) async throws { links[chatID] = nil }
    func markBlocked(chatID: Int64) async throws { blocked.append(chatID) }
    func ack(incidentID: String, accountID: String, now: Date) async throws
        -> (incident: NotifyIncident, ack: NotifyAck, sent: [TelegramSent])? {
        guard let (i, allowed, sent) = incidents[incidentID], allowed.contains(accountID) else { return nil }
        acks.append("\(incidentID):\(accountID)")
        return (i, NotifyAck(accountID: accountID, name: names[accountID] ?? "", at: now), sent)
    }
    func openIncidents(scope: String, accountID: String) async throws -> [String] {
        incidents.values.filter { $0.0.clientID == scope && $0.1.contains(accountID) }.map(\.0.id)
    }
    func mute(accountID: String, scope: NotifyMute.Scope, scopeID: String, until: Date?) async throws {}
    func muteAll(accountID: String, until: Date) async throws {}
    func details(incidentID: String, accountID: String) async throws -> TelegramMessage? { nil }
    func status(accountID: String) async throws -> [TelegramText.ClientState] { [] }
    func problems(accountID: String) async throws -> [NotifyIncident] { [] }
    func due(now: Date, limit: Int) async throws -> [TelegramOutgoing] { Array(outbox.prefix(limit)) }
    func sent(deliveryID: String, messageID: Int64?, now: Date) async throws { sentIDs[deliveryID] = messageID }
    func failed(deliveryID: String, error: String, retryAt: Date?) async throws { failures[deliveryID] = (error, retryAt) }
    func offset() async throws -> Int64? { off }
    func setOffset(_ id: Int64) async throws { off = id }
}
