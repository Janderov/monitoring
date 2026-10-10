import Foundation

/// What the hub reads from the database for one client and one period
/// (`ReportSQL`), already limited to the client's objects and to what the
/// client may see (`client_visible`).
public struct ReportInput: Sendable {
    public var clientName: String
    public var signature: String
    public var footer: String
    public var period: ReportPeriod
    public var slaTarget: Double?
    public var sites: [SiteInfo]
    public var siteDays: [SiteDay]
    public var servers: [ServerInfo]
    public var serverDays: [ServerDay]
    public var diskDays: [DiskDay]
    public var incidents: [IncidentRow]
    public var forecasts: [ForecastRow]
    public var backups: [BackupRun]
    public var work: [WorkRow]

    public init(clientName: String, signature: String, footer: String = "", period: ReportPeriod, slaTarget: Double? = nil,
                sites: [SiteInfo] = [], siteDays: [SiteDay] = [], servers: [ServerInfo] = [], serverDays: [ServerDay] = [],
                diskDays: [DiskDay] = [], incidents: [IncidentRow] = [], forecasts: [ForecastRow] = [],
                backups: [BackupRun] = [], work: [WorkRow] = []) {
        self.clientName = clientName; self.signature = signature; self.footer = footer
        self.period = period; self.slaTarget = slaTarget
        self.sites = sites; self.siteDays = siteDays; self.servers = servers; self.serverDays = serverDays
        self.diskDays = diskDays; self.incidents = incidents; self.forecasts = forecasts
        self.backups = backups; self.work = work
    }

    public struct SiteInfo: Sendable {
        public var id: UUID
        public var name: String
        public var note: String?
        public var tlsExpiry: Date?
        public var domainExpiry: Date?
        /// Still the client's at the end of the period; a site that moved to
        /// someone else shows its days but gets no «Скоро потребует внимания».
        public var current: Bool
        public init(id: UUID, name: String, note: String? = nil, tlsExpiry: Date? = nil, domainExpiry: Date? = nil,
                    current: Bool = true) {
            self.id = id; self.name = name; self.note = note; self.tlsExpiry = tlsExpiry; self.domainExpiry = domainExpiry
            self.current = current
        }
    }

    /// `mon.site_daily`.
    public struct SiteDay: Sendable {
        public var siteID: UUID
        public var day: String
        public var checksTotal: Int
        public var checksOK: Int
        public var downtimeSeconds: Int
        public var latencyAvgMs: Double?
        public init(siteID: UUID, day: String, checksTotal: Int, checksOK: Int, downtimeSeconds: Int = 0, latencyAvgMs: Double? = nil) {
            self.siteID = siteID; self.day = day; self.checksTotal = checksTotal; self.checksOK = checksOK
            self.downtimeSeconds = downtimeSeconds; self.latencyAvgMs = latencyAvgMs
        }
    }

    public struct ServerInfo: Sendable {
        public var id: UUID
        public var name: String
        public var note: String?
        public var current: Bool
        public init(id: UUID, name: String, note: String? = nil, current: Bool = true) {
            self.id = id; self.name = name; self.note = note; self.current = current
        }
    }

    /// `mon.server_daily`.
    public struct ServerDay: Sendable {
        public var serverID: UUID
        public var day: String
        public var cpuMax: Double?
        public var memMax: Double?
        public var diskMaxPct: Double?
        public var reboots: Int
        public var checksTotal: Int
        public var checksOK: Int
        public init(serverID: UUID, day: String, cpuMax: Double? = nil, memMax: Double? = nil, diskMaxPct: Double? = nil,
                    reboots: Int = 0, checksTotal: Int, checksOK: Int) {
            self.serverID = serverID; self.day = day; self.cpuMax = cpuMax; self.memMax = memMax
            self.diskMaxPct = diskMaxPct; self.reboots = reboots; self.checksTotal = checksTotal; self.checksOK = checksOK
        }
    }

    /// `mon.disk_daily`, including the 30 days before the period for the runway.
    public struct DiskDay: Sendable {
        public var serverID: UUID
        public var mount: String
        public var day: String
        public var usedBytes: Int64
        public var totalBytes: Int64
        public init(serverID: UUID, mount: String, day: String, usedBytes: Int64, totalBytes: Int64) {
            self.serverID = serverID; self.mount = mount; self.day = day; self.usedBytes = usedBytes; self.totalBytes = totalBytes
        }
        var percent: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) * 100 : 0 }
    }

    /// `ops.incident` that overlaps the period.
    public struct IncidentRow: Sendable {
        public var objectName: String
        public var kind: String
        public var severity: Int
        public var message: String
        public var startedAt: Date
        public var endedAt: Date?
        public var cause: String?
        public var resolution: String?
        public init(objectName: String, kind: String, severity: Int, message: String, startedAt: Date, endedAt: Date?,
                    cause: String? = nil, resolution: String? = nil) {
            self.objectName = objectName; self.kind = kind; self.severity = severity; self.message = message
            self.startedAt = startedAt; self.endedAt = endedAt; self.cause = cause; self.resolution = resolution
        }
    }

    /// `ops.forecast`: prevented ones closed in the period, and the ones still open.
    public struct ForecastRow: Sendable {
        public var objectName: String
        public var objectID: UUID?
        public var kind: String
        public var line: String
        public var dueAt: Date?
        public var firstSeenAt: Date
        public var status: String
        public var closedAt: Date?
        public var note: String?
        public init(objectName: String, objectID: UUID? = nil, kind: String, line: String, dueAt: Date?, firstSeenAt: Date,
                    status: String, closedAt: Date? = nil, note: String? = nil) {
            self.objectName = objectName; self.objectID = objectID; self.kind = kind; self.line = line; self.dueAt = dueAt
            self.firstSeenAt = firstSeenAt; self.status = status; self.closedAt = closedAt; self.note = note
        }
    }

    /// `mon.backup_run` in the period.
    public struct BackupRun: Sendable {
        public var serverName: String
        public var target: String
        public var startedAt: Date
        public var ok: Bool
        public var sizeBytes: Int64?
        public init(serverName: String, target: String, startedAt: Date, ok: Bool, sizeBytes: Int64? = nil) {
            self.serverName = serverName; self.target = target; self.startedAt = startedAt; self.ok = ok; self.sizeBytes = sizeBytes
        }
    }

    /// `rep.work_item`.
    public struct WorkRow: Sendable {
        public var doneAt: Date
        public var text: String
        public init(doneAt: Date, text: String) { self.doneAt = doneAt; self.text = text }
    }
}
