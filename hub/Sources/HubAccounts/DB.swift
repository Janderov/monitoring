import HubCore
import Logging
import PostgresNIO

extension PostgresConnection {
    /// The first column of the first row, or nil (HubCore's helper is internal).
    func one<T: PostgresDecodable>(_ q: PostgresQuery, as: T.Type) async throws -> T? {
        for try await v in try await query(q, logger: Logger(label: "hub.accounts")).decode(T.self) { return v }
        return nil
    }
}
