import Foundation
import NIOCore
import PostgresNIO

/// A calendar day ("yyyy-MM-dd") bound as a PostgreSQL `date`, for queries
/// written with plain `$n` parameters (MonitorReports' `ReportSQL`), where a
/// text parameter would not compare with a date column.
struct SQLDay: PostgresEncodable, PostgresDecodable, Equatable {
    var value: String

    init(_ value: String) { self.value = value }

    static var psqlType: PostgresDataType { .date }
    static var psqlFormat: PostgresFormat { .binary }

    static let utc = TimeZone(identifier: "UTC")!
    /// 2000-01-01, PostgreSQL's day zero.
    static let epoch = Date(timeIntervalSince1970: 946_684_800)

    func encode<E: PostgresJSONEncoder>(into buffer: inout ByteBuffer, context: PostgresEncodingContext<E>) throws {
        let p = value.split(separator: "-").compactMap { Int($0) }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.utc
        guard p.count == 3, let d = cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2])) else {
            throw PostgresDecodingError.Code.failure
        }
        buffer.writeInteger(Int32((d.timeIntervalSince(Self.epoch) / 86_400).rounded()))
    }

    init<D: PostgresJSONDecoder>(from buffer: inout ByteBuffer, type: PostgresDataType, format: PostgresFormat,
                                 context: PostgresDecodingContext<D>) throws {
        let date = try Date(from: &buffer, type: type, format: format, context: context)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.utc
        let c = cal.dateComponents([.year, .month, .day], from: date)
        value = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}

/// Text that is already JSON, bound as `jsonb` (the report snapshot).
struct JSONB: PostgresEncodable {
    var data: Data

    static var psqlType: PostgresDataType { .jsonb }
    static var psqlFormat: PostgresFormat { .binary }

    func encode<E: PostgresJSONEncoder>(into buffer: inout ByteBuffer, context: PostgresEncodingContext<E>) throws {
        buffer.writeInteger(UInt8(1))
        buffer.writeBytes(data)
    }
}

extension PostgresQuery {
    /// A query with numbered parameters, as MonitorReports writes them.
    /// A nil is sent untyped: the column or a cast in the SQL gives its type.
    static func sql(_ text: String, _ binds: [(any PostgresEncodable)?]) throws -> PostgresQuery {
        var b = PostgresBindings(capacity: binds.count)
        for v in binds {
            if let v { try b.append(v, context: .default) } else { b.appendNull() }
        }
        return PostgresQuery(unsafeSQL: text, binds: b)
    }
}
