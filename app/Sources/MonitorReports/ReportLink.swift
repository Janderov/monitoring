import Foundation
import MonitorCore

/// The secret part of a client's link, `https://<hub>/r/<token>`. 128 random
/// bits; the database keeps only its SHA-256 (`rep.report_link.token_hash`),
/// so a copy of the database does not open anyone's reports.
public struct ReportToken: Equatable, Sendable {
    public let value: String

    public init(value: String) { self.value = value }

    /// A new token from the system's secure random source.
    public static func make() -> ReportToken {
        var g = SystemRandomNumberGenerator()
        return ReportToken(value: base64url((0..<16).map { _ in UInt8.random(in: 0...255, using: &g) }))
    }

    /// What is stored and looked up.
    public var hash: [UInt8] { Digest.sha256(Array(value.utf8)) }

    /// Tokens we issued are 22 base64url characters; anything else is rejected
    /// before touching the database.
    public static func parse(_ s: String) -> ReportToken? {
        guard s.count == 22, s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return ReportToken(value: s)
    }

    public func url(base: String) -> String {
        (base.hasSuffix("/") ? String(base.dropLast()) : base) + "/r/" + value
    }

    static func base64url(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
