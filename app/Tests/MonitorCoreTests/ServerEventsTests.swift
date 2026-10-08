import XCTest
@testable import MonitorCore

final class ServerEventsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func snap(_ minutes: Double, boot: Date? = nil, uptime: Double = 3600,
                      containers: [Snapshot.Container]?) -> Snapshot {
        var s = Fixtures.snapshot(time: t0.addingTimeInterval(minutes * 60))
        s.bootTime = boot ?? t0.addingTimeInterval(-86400)
        s.uptimeSeconds = uptime
        s.containers = containers
        return s
    }

    private func ctr(_ name: String, _ state: String, _ status: String = "") -> Snapshot.Container {
        Snapshot.Container(id: name, name: name, image: "img", state: state, status: status)
    }

    private func changes(_ prev: Snapshot?, _ snaps: [Snapshot]) -> [AlertEvent] {
        ServerEvents.changes(serverID: "nl", serverName: "Нидерланды", previous: prev, snapshots: snaps)
    }

    func testRebootFoundInBackfilledHistory() {
        let a = snap(0, uptime: 3 * 86400 + 4 * 3600, containers: nil)
        let b = snap(1, containers: nil)
        let rebootAt = t0.addingTimeInterval(90)
        let c = snap(2, boot: rebootAt, uptime: 30, containers: nil)
        let ev = changes(a, [b, c])
        XCTAssertEqual(ev.count, 1)
        XCTAssertEqual(ev[0].kind, .info)
        XCTAssertEqual(ev[0].key, "reboot")
        XCTAssertEqual(ev[0].time, rebootAt)
        XCTAssertEqual(ev[0].message, "сервер перезагрузился, работал до этого 1 ч")
    }

    func testSmallBootTimeDriftIsNotAReboot() {
        let a = snap(0, containers: nil)
        let b = snap(1, boot: a.bootTime.addingTimeInterval(2), containers: nil)
        XCTAssertTrue(changes(a, [b]).isEmpty)
    }

    func testContainerChanges() {
        let a = snap(0, containers: [ctr("web", "running"), ctr("db", "exited"), ctr("old", "running")])
        let b = snap(1, containers: [ctr("web", "exited", "Exited (137) 5 seconds ago"), ctr("db", "running"),
                                     ctr("new", "running")])
        let msgs = changes(a, [b]).map(\.message)
        XCTAssertEqual(msgs, ["контейнер web остановился, код выхода 137", "контейнер db запущен",
                              "появился контейнер new", "контейнер old удалён"])
    }

    func testUnknownContainerListSaysNothing() {
        let a = snap(0, containers: [ctr("web", "running")])
        let b = snap(1, containers: nil)
        XCTAssertTrue(changes(a, [b]).isEmpty)
    }

    func testOlderAndRepeatedSnapshotsAreSkipped() {
        let a = snap(5, containers: [ctr("web", "running")])
        let older = snap(1, containers: [ctr("web", "exited")])
        let same = snap(5, containers: [ctr("web", "exited")])
        XCTAssertTrue(changes(a, [older, same]).isEmpty)
        // No previous snapshot (a new server): nothing to compare the first with.
        XCTAssertTrue(changes(nil, [a]).isEmpty)
    }

    func testPollerLogsEvents() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try Store(path: dir.appendingPathComponent("m.sqlite").path)
        try await store.setLatest("nl", snap(0, containers: [ctr("web", "running")]))
        for e in ServerEvents.changes(serverID: "nl", serverName: "Нидерланды",
                                      previous: try await store.latest("nl"),
                                      snapshots: [snap(1, containers: [ctr("web", "exited")])]) {
            try await store.addEvent(e)
        }
        let logged = try await store.events(serverID: "nl")
        XCTAssertEqual(logged.map(\.kind), [.info])
        XCTAssertEqual(logged.first?.message, "контейнер web остановился (exited)")
    }
}

extension ServerEventsTests {
    func testEventCountForFloodCap() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try Store(path: dir.appendingPathComponent("m.sqlite").path)
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        for i in 0..<3 {
            try await store.addEvent(AlertEvent(serverID: "nl", serverName: "NL", key: "ctr:web", kind: .info,
                                                severity: .warning, message: "x", time: t.addingTimeInterval(Double(i) * 600)))
        }
        let inHour = try await store.eventCount("nl", key: "ctr:web", since: t.addingTimeInterval(600))
        XCTAssertEqual(inHour, 2)
        let other = try await store.eventCount("nl", key: "reboot", since: t)
        XCTAssertEqual(other, 0)
    }
}
