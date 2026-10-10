import Foundation
import Logging
import MonitorCore
import PostgresNIO
import XCTest
@testable import HubCore

/// Telegram on a real PostgreSQL (HUB_TEST_PG=1, as PostgresTests; the
/// database is wiped): alerts become queued messages for the people with the
/// right, the bot sends them, «Беру» stops reminders, «решено» answers under
/// the first message, escalation reaches the owner, quiet hours wait for the
/// morning.
final class TelegramPostgresTests: XCTestCase {
    var env: [String: String] { ProcessInfo.processInfo.environment }

    func testTelegramOnARealDatabase() async throws {
        guard env["HUB_TEST_PG"] == "1" else { throw XCTSkip("HUB_TEST_PG=1 not set") }
        do { try await everything() } catch { XCTFail(HubError.describe(error)) }
    }

    func everything() async throws {
        var logger = Logger(label: "test")
        logger.logLevel = .warning
        let config = try HubConfig.fromEnvironment(env)
        let db = Database(config, logger: logger)
        let runner = Task { await db.run() }
        defer { runner.cancel() }
        for s in ["sys", "acc", "inv", "mon", "ops", "ntf", "rep"] {
            try await db.query(PostgresQuery(unsafeSQL: "DROP SCHEMA IF EXISTS \(s) CASCADE"))
        }
        try await db.query("DROP TABLE IF EXISTS public.schema_migrations")
        try await db.query("DROP FUNCTION IF EXISTS public.uuidv7()")
        if let version = try await db.scalar("SELECT current_setting('server_version_num')::int", as: Int32.self), version < 180000 {
            try await db.query("CREATE FUNCTION public.uuidv7() RETURNS uuid LANGUAGE sql AS 'SELECT gen_random_uuid()'")
        }
        _ = try await Migrator.migrate(db, dir: config.migrationsDir)

        // People: the owner, Ivan with alerts on client Альфа, Пётр with nothing.
        let owner = try await db.scalar("""
            INSERT INTO acc.account (login, display_name, kind, status) VALUES ('mihail', 'Михаил', 'owner', 'active') RETURNING id
            """, as: UUID.self)!
        let ivan = try await db.scalar("""
            INSERT INTO acc.account (login, display_name, kind, status) VALUES ('ivan', 'Иван', 'staff', 'active') RETURNING id
            """, as: UUID.self)!
        let petr = try await db.scalar("""
            INSERT INTO acc.account (login, display_name, kind, status) VALUES ('petr', 'Пётр', 'staff', 'active') RETURNING id
            """, as: UUID.self)!
        let alfa = try await db.scalar("INSERT INTO inv.client (name) VALUES ('Студия Альфа') RETURNING id", as: UUID.self)!
        let grant = try await db.scalar("""
            INSERT INTO acc.access_grant (account_id, scope_type, scope_id, created_by) VALUES (\(ivan), 'client', \(alfa), \(owner))
            RETURNING id
            """, as: UUID.self)!
        try await db.query("""
            INSERT INTO acc.grant_permission (grant_id, permission_code, mode)
            VALUES (\(grant), 'alerts_receive', 'allow'), (\(grant), 'alerts_ack', 'allow')
            """)
        let secret = try await db.scalar("""
            INSERT INTO sys.secret (kind, ciphertext, nonce, key_version) VALUES ('agent_token', '\\x00', '\\x00', 1) RETURNING id
            """, as: UUID.self)!
        let server = try await db.scalar("""
            INSERT INTO inv.server (name, host, agent_fingerprint, agent_token_id)
            VALUES ('wise1', '203.0.113.10', decode(repeat('ab', 32), 'hex'), \(secret)) RETURNING id
            """, as: UUID.self)!
        try await db.query("INSERT INTO inv.client_asset (client_id, asset_type, asset_id) VALUES (\(alfa), 'server', \(server))")

        // Linking: the owner by a code, Ivan too; a used code does not work twice.
        let tg = PostgresTelegramStore(db: db)
        let now = Date()
        let code = try await PostgresTelegramStore.newCode(db, account: owner, now: now)
        let linked = try await tg.redeem(codeHash: LinkCode.hash(code), chatID: 100, username: "mihail", now: now)
        XCTAssertEqual(linked?.name, "Михаил")
        XCTAssertEqual(linked?.clients, ["Студия Альфа"])
        let again = try await tg.redeem(codeHash: LinkCode.hash(code), chatID: 999, username: nil, now: now)
        XCTAssertNil(again)
        let ivanCode = try await PostgresTelegramStore.newCode(db, account: ivan, now: now)
        _ = try await tg.redeem(codeHash: LinkCode.hash(ivanCode), chatID: 200, username: "ivan", now: now)
        let petrCode = try await PostgresTelegramStore.newCode(db, account: petr, now: now)
        _ = try await tg.redeem(codeHash: LinkCode.hash(petrCode), chatID: 300, username: nil, now: now)
        let who = try await tg.account(chatID: 200)
        XCTAssertEqual(who?.name, "Иван")

        // A critical problem: queued for Михаил and Иван, not for Пётр.
        let store = PostgresPollStore(db: db)
        await store.setIDs(servers: ["s1": server], sites: [:])
        let t0 = now.addingTimeInterval(-60)
        let fired = AlertEvent(serverID: "s1", serverName: "wise1", key: "svc:nginx", kind: .fired, severity: .critical,
                               message: "сервис nginx не запущен", time: t0)
        try await store.addEvent(fired, actor: "system")
        try await store.addEvent(fired, actor: "system") // a repeat queues nothing more
        let queued = try await db.scalar("""
            SELECT string_agg(target, ',' ORDER BY target) FROM ntf.delivery WHERE kind = 'fired' AND status = 'queued'
            """, as: String.self)
        XCTAssertEqual(queued, "100,200")
        let early = try await tg.due(now: t0, limit: 10)
        XCTAssertEqual(early.count, 0, "new alerts wait for the rest of the round")

        let fake = HubFakeTelegram()
        let clock = Clock(now)
        let bot = TelegramBot(api: TelegramBotAPI(transport: fake), store: tg, clock: { clock.now })
        await fake.answer(#"{"ok":true,"result":{"message_id":11}}"#)
        await fake.answer(#"{"ok":true,"result":{"message_id":21}}"#)
        let sentCount = try await bot.flush()
        XCTAssertEqual(sentCount, 2)
        let firstText = await fake.texts().first ?? ""
        XCTAssertTrue(firstText.contains("сервис nginx не запущен"), firstText)
        XCTAssertTrue(firstText.contains("Клиент: Студия Альфа"), firstText)
        let ext = try await db.scalar("SELECT string_agg(external_id, ',' ORDER BY external_id) FROM ntf.delivery WHERE kind = 'fired'", as: String.self)
        XCTAssertEqual(ext, "11,21")

        // Пётр presses «Беру» on someone else's problem: refused.
        let incident = try await db.scalar("SELECT id FROM ops.incident WHERE key = 'svc:nginx'", as: UUID.self)!
        func press(_ chat: Int64, _ data: String) -> TelegramUpdate {
            TelegramUpdate(update_id: 1, message: nil, callback_query: TelegramCallback(
                id: "cb", from: TelegramUser(id: chat), message: TelegramIncoming(message_id: 1, chat: TelegramChat(id: chat, type: "private")),
                data: data))
        }
        await fake.reset()
        try await bot.handle(press(300, "ack:\(incident.uuidString.lowercased())"))
        let refusal = await fake.bodies().first?["text"] as? String
        XCTAssertEqual(refusal, TelegramText.noRights)

        // Иван takes it: both copies say so, reminders stop.
        await fake.reset()
        try await bot.handle(press(200, "ack:\(incident.uuidString.lowercased())"))
        let methods = await fake.methods()
        XCTAssertEqual(methods, ["answerCallbackQuery", "editMessageText", "editMessageText"])
        let edited = await fake.bodies()[1]["text"] as? String
        XCTAssertTrue(edited?.contains("👀 Взял Иван") == true)
        var reminder = fired
        reminder.kind = .reminder
        reminder.time = now
        try await store.addEvent(reminder, actor: "system")
        let reminders = try await db.scalar("SELECT count(*) FROM ntf.delivery WHERE kind = 'reminder'", as: Int64.self)
        XCTAssertEqual(reminders, 0)

        // Resolved: a reply under the first message, and the first message edited.
        var resolved = fired
        resolved.kind = .resolved
        resolved.time = now
        try await store.addEvent(resolved, actor: "system")
        let due = try await tg.due(now: now, limit: 10)
        XCTAssertEqual(Set(due.compactMap(\.replyTo)), [11, 21])
        XCTAssertEqual(Set(due.compactMap(\.edit)), [11, 21])
        XCTAssertTrue(due.contains { $0.message.text.contains("снова в норме") })

        // Escalation: a critical problem nobody took for 20 minutes reaches the owner once.
        let down = AlertEvent(serverID: "s1", serverName: "wise1", key: "down", kind: .fired, severity: .critical,
                              message: "агент не отвечает", time: now.addingTimeInterval(-20 * 60))
        try await store.addEvent(down, actor: "system")
        try await NotifyQueue.escalate(db, now: now)
        try await NotifyQueue.escalate(db, now: now)
        let esc = try await db.scalar("SELECT string_agg(target, ',') FROM ntf.delivery WHERE kind = 'escalation'", as: String.self)
        XCTAssertEqual(esc, "100")

        // Quiet hours: Иван's warnings wait for the morning «Прогноз».
        try await db.query("""
            INSERT INTO ntf.prefs (account_id, quiet_from, quiet_to, critical_in_quiet, timezone, digest_time)
            VALUES (\(ivan), '00:00', '23:59', false, 'UTC', '00:00')
            """)
        let disk = AlertEvent(serverID: "s1", serverName: "wise1", key: "disk:/", kind: .fired, severity: .warning,
                              message: "диск / заполнен на 93%", time: now)
        try await store.addEvent(disk, actor: "system")
        let held = try await db.scalar("SELECT status FROM ntf.delivery WHERE kind = 'fired' AND target = '200' AND incident_id = (SELECT id FROM ops.incident WHERE key = 'disk:/')", as: String.self)
        XCTAssertEqual(held, "dropped_quiet")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let midnight = cal.startOfDay(for: now).addingTimeInterval(60)
        try await NotifyQueue.digests(db, now: midnight)
        let digest = try await db.scalar("SELECT payload->'message'->>'text' FROM ntf.delivery WHERE kind = 'digest' AND target = '200'", as: String.self)
        XCTAssertTrue(digest?.contains("диск / заполнен на 93%") == true, digest ?? "no digest")

        // Commands answer from the database.
        let status = try await tg.status(accountID: ivan.uuidString.lowercased())
        XCTAssertEqual(status.map(\.name), ["Студия Альфа"])
        XCTAssertEqual(status.first?.criticals, 1)
        let problems = try await tg.problems(accountID: petr.uuidString.lowercased())
        XCTAssertEqual(problems, [], "no right, no problems shown")
        try await tg.setOffset(42)
        let offset = try await tg.offset()
        XCTAssertEqual(offset, 42)

        // /stop unlinks.
        try await tg.unlink(chatID: 300, now: now)
        let gone = try await tg.account(chatID: 300)
        XCTAssertNil(gone)
    }
}

final class Clock: @unchecked Sendable {
    var now: Date
    init(_ d: Date) { now = d.addingTimeInterval(30) }
}

actor HubFakeTelegram: TelegramTransport {
    var replies: [String] = []
    var calls: [(String, [String: Any])] = []
    func answer(_ body: String) { replies.append(body) }
    func reset() { calls = []; replies = [] }
    func methods() -> [String] { calls.map(\.0) }
    func bodies() -> [[String: Any]] { calls.map(\.1) }
    func texts() -> [String] { calls.compactMap { $0.1["text"] as? String } }
    func post(_ method: String, json: Data, timeout: TimeInterval) async throws -> (Int, Data) {
        calls.append((method, (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] ?? [:]))
        let body = replies.isEmpty
            ? (method == "editMessageText" ? #"{"ok":true,"result":{"message_id":1}}"# : #"{"ok":true,"result":true}"#)
            : replies.removeFirst()
        return (200, Data(body.utf8))
    }
}
