import Foundation
import HubCore
import Logging
import PostgresNIO

/// ops.audit_log: who did what, to what, from where, and how it ended.
/// The hub only ever adds lines; nothing here updates or deletes them.
public struct Audit: Sendable {
    let db: Database

    public init(db: Database) { self.db = db }

    public enum Result: String, Sendable { case done, failed, denied, pending_approval }

    public struct Entry: Sendable {
        public var action: String
        public var objectType: String
        public var objectID: UUID?
        public var objectName: String
        public var detail: [String: String]
        public var result: Result
        public var error: String?
        public var approvalID: UUID?

        public init(_ action: String, objectType: String, objectID: UUID? = nil, objectName: String = "",
                    detail: [String: String] = [:], result: Result = .done, error: String? = nil,
                    approvalID: UUID? = nil) {
            self.action = action; self.objectType = objectType; self.objectID = objectID
            self.objectName = objectName; self.detail = detail; self.result = result
            self.error = error; self.approvalID = approvalID
        }
    }

    /// Writes one line. A failed write is logged, never thrown: the action
    /// itself matters more than its log line (same rule as Auditor on the Mac).
    public func write(_ e: Entry, by actor: Actor) async {
        do { try await db.query(Self.insert(e, by: actor)) } catch {
            db.logger.error("audit: \(HubError.describe(error))")
        }
    }

    /// Inside a transaction, so the change and its line land together.
    public func write(_ e: Entry, by actor: Actor, on conn: PostgresConnection) async throws {
        try await conn.query(Self.insert(e, by: actor), logger: db.logger)
    }

    static func insert(_ e: Entry, by actor: Actor) -> PostgresQuery {
        let detail = JSON.object(e.detail)
        let accountID = actor.account?.id
        return """
            INSERT INTO ops.audit_log (actor_id, actor_kind, actor_name, session_id, ip, device, action,
                                       object_type, object_id, object_name, client_ids, detail, result, error,
                                       approval_id)
            VALUES (\(accountID), \(actor.kind), \(actor.name), \(actor.sessionID), \(actor.ip)::inet,
                    \(actor.device), \(e.action), \(e.objectType), \(e.objectID), \(e.objectName),
                    coalesce((SELECT array_agg(DISTINCT client_id) FROM inv.client_asset
                              WHERE asset_id = \(e.objectID) AND until IS NULL), '{}'),
                    \(detail)::jsonb, \(e.result.rawValue), \(e.error), \(e.approvalID))
            """
    }
}

/// Small JSON helpers: the cabinet's read endpoints let PostgreSQL build the
/// JSON (json_agg), so Swift only escapes what it writes itself.
public enum JSON {
    public static func string(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])
        let text = String(decoding: data, as: UTF8.self)
        return String(text.dropFirst().dropLast())
    }

    public static func object(_ d: [String: String]) -> String {
        "{" + d.sorted { $0.key < $1.key }.map { "\(string($0.key)):\(string($0.value))" }.joined(separator: ",") + "}"
    }

    public static func encode<T: Encodable>(_ value: T) -> String {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? enc.encode(value)) ?? Data("null".utf8), as: UTF8.self)
    }

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = parseDate(s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "дата \(s)"))
        }
        return d
    }()

    /// ISO 8601 with or without fractions, or a plain date (end of that day, UTC).
    public static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withFullDate]
        if let d = f.date(from: s) { return d.addingTimeInterval(86399) }
        return nil
    }
}
