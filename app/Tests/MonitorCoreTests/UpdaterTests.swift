import Foundation
import XCTest
@testable import MonitorCore

final class FakeHTTP: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    var responses: [String: (Int, String)] = [:]
    private var _requests: [String] = []
    var requests: [String] { lock.withLock { _requests } }

    func get(_ url: URL, headers: [String: String]) async throws -> (Int, Data) {
        lock.withLock { _requests.append(url.absoluteString) }
        XCTAssertEqual(headers["Authorization"], "Bearer tok")
        let key = responses.keys.first { url.absoluteString.contains($0) }
        let (code, body) = key.flatMap { responses[$0] } ?? (404, "{}")
        return (code, Data(body.utf8))
    }

    func download(_ url: URL, headers: [String: String], to file: URL) async throws -> Int {
        lock.withLock { _requests.append(url.absoluteString) }
        try Data("zip".utf8).write(to: file)
        return 200
    }
}

final class UpdaterTests: XCTestCase {
    let runs = """
    {"total_count":2,"workflow_runs":[
      {"id":22,"head_sha":"cd6cb2f0123456789abcdef0123456789abcdef0","display_title":"Merge pull request #10",
       "updated_at":"2026-10-05T11:10:00Z"},
      {"id":21,"head_sha":"4ff6ded0123456789abcdef0123456789abcdef0","display_title":"Merge pull request #8",
       "updated_at":"2026-10-05T10:00:00Z"}]}
    """

    func fake() -> FakeHTTP {
        let h = FakeHTTP()
        h.responses = [
            "/workflows/app.yml/runs": (200, runs),
            "/runs/22/artifacts": (200, #"{"artifacts":[{"id":901,"name":"Monitor-app","expired":false,"size_in_bytes":4200000}]}"#),
        ]
        return h
    }

    func testCommitFromVersion() {
        XCTAssertEqual(AppUpdater.commit(fromVersion: "0.0.0-dev-4ff6ded"), "4ff6ded")
        XCTAssertNil(AppUpdater.commit(fromVersion: "0.0.0-dev"))
        XCTAssertNil(AppUpdater.commit(fromVersion: "1.2.0"))
    }

    func testFindsNewerBuild() async throws {
        let h = fake()
        let u = try await AppUpdater(token: "tok", http: h).check(current: "0.0.0-dev-4ff6ded")
        XCTAssertEqual(u?.artifactID, 901)
        XCTAssertEqual(u?.version, "0.0.0-dev-cd6cb2f")
        XCTAssertEqual(u?.title, "Merge pull request #10")
        XCTAssertTrue(h.requests.contains { $0.contains("branch=main&status=success") })
    }

    func testUpToDate() async throws {
        let u = try await AppUpdater(token: "tok", http: fake()).check(current: "0.0.0-dev-cd6cb2f")
        XCTAssertNil(u)
    }

    func testBadToken() async {
        let h = FakeHTTP()
        h.responses = ["/runs": (401, "{}")]
        do {
            _ = try await AppUpdater(token: "tok", http: h).check(current: "0.0.0-dev")
            XCTFail("expected error")
        } catch {
            XCTAssertTrue("\(error)".contains("токен"), "\(error)")
        }
    }

    func testDownload() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = fake()
        let updater = AppUpdater(token: "tok", http: h)
        let u = try await updater.check(current: "0.0.0-dev")!
        let file = try await updater.download(u, into: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(h.requests.last!.hasSuffix("/actions/artifacts/901/zip"))
    }

    func testSignerMustMatchOnceSigned() throws {
        // Ad hoc today: any build that passes codesign is accepted.
        XCTAssertNoThrow(try AppUpdater.checkSigner(current: nil, new: nil))
        XCTAssertNoThrow(try AppUpdater.checkSigner(current: nil, new: "TEAM123456"))
        // Signed: only the same team.
        XCTAssertNoThrow(try AppUpdater.checkSigner(current: "TEAM123456", new: "TEAM123456"))
        XCTAssertThrowsError(try AppUpdater.checkSigner(current: "TEAM123456", new: nil))
        XCTAssertThrowsError(try AppUpdater.checkSigner(current: "TEAM123456", new: "OTHER00000"))
    }
}
