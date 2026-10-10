import Foundation
import PostgresNIO

public enum HubError {
    /// PostgresNIO hides the server's message from `description` (it may
    /// carry data); the hub's own log is the place to see it.
    public static func describe(_ error: Error) -> String {
        if let e = error as? PSQLError {
            let info = e.serverInfo
            let parts = [info?[.sqlState].map { "код \($0)" }, info?[.message], info?[.detail], info?[.hint]]
            let text = parts.compactMap { $0 }.joined(separator: "; ")
            return text.isEmpty ? String(reflecting: e) : "PostgreSQL: \(text)"
        }
        if error is PostgresDecodingError { return String(reflecting: error) }
        return String(describing: error)
    }
}
