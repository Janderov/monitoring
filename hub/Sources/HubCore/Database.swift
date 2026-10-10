import Foundation
import Logging
import NIOSSL
import PostgresNIO

/// The connection pool. `run()` must be running (in a task) while the hub
/// uses the database; it reconnects by itself after a restart of PostgreSQL.
public final class Database: Sendable {
    public let client: PostgresClient
    public let logger: Logger

    public init(_ config: HubConfig, logger: Logger) {
        var c = PostgresClient.Configuration(
            host: config.dbHost, port: config.dbPort, username: config.dbUser,
            password: config.dbPassword, database: config.dbName,
            tls: config.dbTLS ? .require(.makeClientConfiguration()) : .disable)
        c.options.minimumConnections = 1
        c.options.maximumConnections = 8
        self.client = PostgresClient(configuration: c, backgroundLogger: logger)
        self.logger = logger
    }

    public func run() async { await client.run() }

    @discardableResult
    public func query(_ q: PostgresQuery) async throws -> PostgresRowSequence {
        try await client.query(q, logger: logger)
    }

    public func transaction<T: Sendable>(_ body: (PostgresConnection) async throws -> T) async throws -> T {
        try await client.withConnection { conn in
            try await conn.query("BEGIN", logger: logger)
            do {
                let value = try await body(conn)
                try await conn.query("COMMIT", logger: logger)
                return value
            } catch {
                _ = try? await conn.query("ROLLBACK", logger: logger)
                throw error
            }
        }
    }

    /// The first column of the first row, or nil.
    public func scalar<T: PostgresDecodable>(_ q: PostgresQuery, as: T.Type) async throws -> T? {
        for try await v in try await query(q).decode(T.self) { return v }
        return nil
    }
}

extension PostgresConnection {
    func scalar<T: PostgresDecodable>(_ q: PostgresQuery, as: T.Type, logger: Logger) async throws -> T? {
        for try await v in try await query(q, logger: logger).decode(T.self) { return v }
        return nil
    }
}
