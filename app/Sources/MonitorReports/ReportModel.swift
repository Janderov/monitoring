import Foundation

/// A client's monthly report as it was on the day it was made: every number
/// and line the page shows. Stored as `rep.client_report.data`, so deleting a
/// site or pruning history later never changes a report already sent.
/// Days are "yyyy-MM-dd" in the client's time zone.
public struct ClientReport: Codable, Equatable, Sendable {
    /// Bumped when the page or the meaning of a field changes.
    public static let templateVersion = 1

    public var clientName: String
    public var periodStart: String
    public var periodEnd: String
    public var generatedAt: Date
    /// Who signs the report («Михаил Дмитраков»).
    public var signature: String
    public var footer: String
    public var status: Status
    public var headline: String
    public var detail: String?
    public var totals: Totals
    public var prevented: [Prevented]
    public var sites: [Site]
    public var servers: [Server]
    public var diskCharts: [DiskChart]
    public var incidents: [Incident]
    public var backups: [Backup]
    public var work: [Work]
    public var attention: [Attention]

    public enum Status: String, Codable, Sendable {
        case ok, issues, critical
    }

    public struct Totals: Codable, Equatable, Sendable {
        /// Share of good checks, 0...1; nil when there were none.
        public var siteUptime: Double?
        public var serverUptime: Double?
        public var siteCount: Int
        public var serverCount: Int
        public var incidents: Int
        public var downtimeSeconds: Int
        public var prevented: Int
        /// The client's target, 0...1, when one is agreed.
        public var slaTarget: Double?
    }

    /// Seen early, fixed before it happened: the point of the service.
    public struct Prevented: Codable, Equatable, Sendable {
        public var title: String
        public var detail: String?
        public var seenAt: Date
        public var wouldHappenAt: Date?
        public var fixedAt: Date
        public var fix: String?
    }

    public struct Site: Codable, Equatable, Sendable {
        public var name: String
        public var note: String?
        public var uptime: Double?
        public var latencyMs: Double?
        /// One mark per day of the period.
        public var days: [DayMark]
        public var tlsDays: Int?
        public var domainDays: Int?
    }

    public enum DayMark: String, Codable, Sendable {
        /// No data that day (site added later, hub was down).
        case none
        case ok
        /// Some checks failed, but it never went down.
        case errors
        case down
    }

    public struct Server: Codable, Equatable, Sendable {
        public var name: String
        public var note: String?
        public var uptime: Double?
        public var cpuMax: Double?
        public var memMax: Double?
        public var diskMax: Double?
        /// Days until the fullest disk is full at the recent pace; nil when not growing.
        public var diskRunwayDays: Int?
        public var reboots: Int
    }

    /// The fullest disk of a server over the period, drawn when a forecast
    /// about it was prevented: the picture of «would have filled up».
    public struct DiskChart: Codable, Equatable, Sendable {
        public var server: String
        public var mount: String
        /// Percent full per day of the period, nil for days without data.
        public var percent: [Double?]
        /// Day index (0-based) the disk would have been full without the fix.
        public var wouldFillDay: Double?
        /// Day index of the fix.
        public var fixDay: Int?
        public var fixLabel: String?
    }

    public struct Incident: Codable, Equatable, Sendable {
        public var object: String
        public var title: String
        public var startedAt: Date
        /// Within the period; an ongoing one counts to the end of the period.
        public var durationSeconds: Int
        public var ongoing: Bool
        public var cause: String?
        public var resolution: String?
        public var critical: Bool
    }

    public struct Backup: Codable, Equatable, Sendable {
        public var target: String
        public var server: String
        public var good: Int
        public var expected: Int
        public var last: Date?
        public var lastBytes: Int64?
        /// Days of the period without a good copy.
        public var missedDays: [String]
    }

    public struct Work: Codable, Equatable, Sendable {
        public var day: String
        public var text: String
    }

    public struct Attention: Codable, Equatable, Sendable {
        public var title: String
        public var detail: String?
        public var due: Date?
        /// The client decides or pays (a domain, a bigger disk); otherwise the admin does it.
        public var needsClient: Bool
    }
}
