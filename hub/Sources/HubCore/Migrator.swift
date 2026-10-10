import Crypto
import Foundation
import Logging
import PostgresNIO

/// Applies the numbered SQL files (0001_init.sql, 0002_….sql) in order, each
/// in its own transaction, and remembers them in `public.schema_migrations`.
/// Same rule as Store.swift on the Mac: a released migration is never edited,
/// a new one is added; an edited file stops the hub instead of guessing.
public enum Migrator {
    public struct Error: Swift.Error, CustomStringConvertible {
        public var description: String
    }

    public struct File: Sendable {
        public var version: String
        public var sql: String
        public var checksum: String
    }

    public static func files(in dir: URL) throws -> [File] {
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".sql") && $0.first?.isNumber == true }
            .sorted()
        return try names.map { name in
            let sql = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            let sum = SHA256.hash(data: Data(sql.utf8)).map { String(format: "%02x", $0) }.joined()
            return File(version: String(name.dropLast(4)), sql: sql, checksum: sum)
        }
    }

    /// Returns the versions applied by this call.
    @discardableResult
    public static func migrate(_ db: Database, dir: URL) async throws -> [String] {
        let all = try files(in: dir)
        let logger = db.logger
        return try await db.client.withConnection { conn in
            // Two hubs starting at once must not apply the same file twice.
            try await conn.query("SELECT pg_advisory_lock(727001)", logger: logger)
            do {
                let applied = try await apply(all, conn: conn, logger: logger)
                try await conn.query("SELECT pg_advisory_unlock(727001)", logger: logger)
                return applied
            } catch {
                _ = try? await conn.query("SELECT pg_advisory_unlock(727001)", logger: logger)
                throw error
            }
        }
    }

    static func apply(_ all: [File], conn: PostgresConnection, logger: Logger) async throws -> [String] {
        try await conn.query("""
            CREATE TABLE IF NOT EXISTS public.schema_migrations (
              version text PRIMARY KEY, checksum text NOT NULL,
              applied_at timestamptz NOT NULL DEFAULT now())
            """, logger: logger)
        var done: [String: String] = [:]
        for try await (v, c) in try await conn.query("SELECT version, checksum FROM public.schema_migrations",
                                                     logger: logger).decode((String, String).self) {
            done[v] = c
        }
        var applied: [String] = []
        for f in all {
            if let sum = done[f.version] {
                guard sum == f.checksum else {
                    throw Error(description: "миграция \(f.version) изменена после применения; добавьте новую вместо правки")
                }
                continue
            }
            try await conn.query("BEGIN", logger: logger)
            do {
                for statement in SQLScript.statements(f.sql) {
                    try await conn.query(PostgresQuery(unsafeSQL: statement), logger: logger)
                }
                try await conn.query(
                    "INSERT INTO public.schema_migrations (version, checksum) VALUES (\(f.version), \(f.checksum))",
                    logger: logger)
                try await conn.query("COMMIT", logger: logger)
            } catch {
                _ = try? await conn.query("ROLLBACK", logger: logger)
                throw Error(description: "миграция \(f.version): \(HubError.describe(error))")
            }
            logger.info("applied migration \(f.version)")
            applied.append(f.version)
        }
        return applied
    }
}
