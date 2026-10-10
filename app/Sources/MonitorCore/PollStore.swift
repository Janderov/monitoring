import Foundation

/// What the poller writes and reads back between rounds. `Store` (SQLite on
/// the Mac) is one implementation; the hub implements it on PostgreSQL, so
/// the same rounds, alert rules and backfill run in both places.
public protocol PollStore: Sendable {
    func addSamples(_ serverID: String, _ snaps: [Snapshot]) async throws
    func addSiteSamples(serverID: String, _ snaps: [Snapshot]) async throws
    func addLinkSamples(serverID: String, _ snaps: [Snapshot]) async throws
    func addVPNTraffic(_ serverID: String, _ snap: Snapshot, calendar: Calendar) async throws
    func addPoll(_ serverID: String, at time: Date, ok: Bool, error: String?) async throws
    func addEvent(_ e: AlertEvent, actor: String) async throws
    func eventCount(_ serverID: String, key: String, since: Date) async throws -> Int
    func setLatest(_ serverID: String, _ snap: Snapshot) async throws
    func latest(_ serverID: String) async throws -> Snapshot?
    func lastSampleTime(_ serverID: String) async throws -> Date?
    func rollup(since: Date, now: Date) async throws
    func setDomain(_ domain: String, _ e: DomainExpiry.Entry) async throws
    func domains() async throws -> [String: DomainExpiry.Entry]
    func setValue(_ value: String?, for key: String) async throws
    func value(_ key: String) async throws -> String?
}

extension Store: PollStore {}
