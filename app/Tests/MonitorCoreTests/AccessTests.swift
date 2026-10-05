import Foundation
import XCTest
@testable import MonitorCore

final class AccessTests: XCTestCase {
    func testRoles() {
        let nl = ObjectRef.server(ServerConfig(id: "nl", name: "NL", host: "h", token: "t", fingerprint: "f",
                                               group: "VPN"))
        XCTAssertTrue(UserAction.allCases.allSatisfy { Access.can(.owner, $0, nl) })
        let op = AppUser(id: "anna", name: "Анна", role: .vpnOperator, projects: ["VPN"])
        XCTAssertTrue(Access.can(op, .manageVPNKeys, nl))
        XCTAssertFalse(Access.can(op, .ssh, nl))
        let other = ObjectRef(type: .server, id: "ru", name: "RU", project: "Сайты")
        XCTAssertFalse(Access.can(op, .manageVPNKeys, other))
        XCTAssertFalse(Access.can(AppUser(id: "v", name: "V", role: .viewer), .editConfig))
    }

    func testAuditorLogsEveryOutcome() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Store(path: dir.appendingPathComponent("m.sqlite").path)
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let auditor = Auditor(store: store, now: { t0 })
        let server = ServerConfig(id: "nl", name: "NL", host: "h", token: "t", fingerprint: "f")
        let key = ObjectRef.vpnKey(publicKey: "CPUB=", name: "iPhone", on: server)

        let v = try await auditor.perform(.manageVPNKeys, on: key, detail: "создан ключ") { 42 }
        XCTAssertEqual(v, 42)
        do {
            _ = try await auditor.perform(.manageVPNKeys, on: key, detail: "удалён ключ") { () -> Int in
                throw AWGError("такого ключа на сервере нет")
            }
            XCTFail()
        } catch {}
        let viewer = AppUser(id: "v", name: "Наблюдатель", role: .viewer)
        do {
            _ = try await auditor.perform(.editConfig, on: .server(server), by: viewer) { 1 }
            XCTFail()
        } catch let e as AccessDenied {
            XCTAssertEqual(e.action, .editConfig)
        }

        let log = try await auditor.recent()
        XCTAssertEqual(log.map(\.result), [.denied, .failed, .done])
        XCTAssertEqual(log[1].error, "такого ключа на сервере нет")
        XCTAssertEqual(log[2].object.name, "iPhone (NL)")
        XCTAssertEqual(log[0].actor.name, "Наблюдатель")
        let forKey = try await auditor.recent(objectID: "CPUB=")
        XCTAssertEqual(forKey.count, 2)
        XCTAssertEqual(Store.schemaVersion, 6)
    }
}
