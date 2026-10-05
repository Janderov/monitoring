import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Plain HTTPS for the GitHub API; tests substitute a fake.
public protocol HTTPClient: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> (Int, Data)
    /// Saves the body to a file, following redirects.
    func download(_ url: URL, headers: [String: String], to file: URL) async throws -> Int
}

public struct URLSessionHTTP: HTTPClient {
    public init() {}

    public func get(_ url: URL, headers: [String: String]) async throws -> (Int, Data) {
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    public func download(_ url: URL, headers: [String: String], to file: URL) async throws -> Int {
        var req = URLRequest(url: url)
        req.timeoutInterval = 300
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: tmp, to: file)
        return (resp as? HTTPURLResponse)?.statusCode ?? 0
    }
}

extension SecretKey {
    /// Read-only GitHub token for downloading builds of the private repo.
    public static let githubToken = "github-token"
}

/// A build of Monitor.app newer than the running one.
public struct AppUpdate: Equatable, Sendable {
    public var commit: String
    public var title: String
    public var date: Date
    public var artifactID: Int
    public var sizeBytes: Int
    /// Version string the new build reports, e.g. "0.0.0-dev-1a2b3c4".
    public var version: String { "0.0.0-dev-" + commit.prefix(7) }
}

public struct UpdateError: Error, CustomStringConvertible, Sendable {
    public var description: String
    public init(_ d: String) { description = d }
}

/// Updates the app from the newest green CI build of main: the `Monitor-app`
/// artifact of the `app` workflow. The repository is private, so it needs a
/// GitHub token with read access to Actions (stored in Keychain).
public struct AppUpdater: Sendable {
    public var repo = "Janderov/monitoring"
    public var workflow = "app.yml"
    public var artifactName = "Monitor-app"
    private let http: HTTPClient
    private let token: String

    public init(token: String, http: HTTPClient = URLSessionHTTP()) {
        self.token = token
        self.http = http
    }

    /// The running build: CFBundleShortVersionString, set by build-app.sh.
    public static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0-dev"
    }

    /// Commit the running build came from, when it is a CI build of a commit.
    public static func commit(fromVersion v: String) -> String? {
        guard let r = v.range(of: "dev-", options: .backwards) else { return nil }
        let c = String(v[r.upperBound...])
        return c.count >= 7 && c.allSatisfy(\.isHexDigit) ? c.lowercased() : nil
    }

    private var headers: [String: String] {
        ["Authorization": "Bearer \(token)", "Accept": "application/vnd.github+json",
         "X-GitHub-Api-Version": "2022-11-28"]
    }

    private func api<T: Decodable>(_ path: String, _ type: T.Type) async throws -> T {
        let (code, data) = try await http.get(URL(string: "https://api.github.com/repos/\(repo)/\(path)")!,
                                              headers: headers)
        switch code {
        case 200: break
        case 401: throw UpdateError("GitHub не принял токен: проверьте его в настройках")
        case 403, 404: throw UpdateError("у токена нет доступа к репозиторию \(repo) (нужно чтение Actions)")
        default: throw UpdateError("GitHub ответил HTTP \(code)")
        }
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        do { return try d.decode(type, from: data) } catch { throw UpdateError("непонятный ответ GitHub: \(error)") }
    }

    struct Runs: Decodable {
        struct Run: Decodable {
            var id: Int
            var headSha: String
            var displayTitle: String?
            var updatedAt: Date
        }
        var workflowRuns: [Run]
    }

    struct Artifacts: Decodable {
        struct Artifact: Decodable { var id: Int; var name: String; var expired: Bool; var sizeInBytes: Int }
        var artifacts: [Artifact]
    }

    /// The newest green build of main, or nil when the running build is it.
    public func check(current: String = AppUpdater.currentVersion) async throws -> AppUpdate? {
        let runs = try await api("actions/workflows/\(workflow)/runs?branch=main&status=success&event=push&per_page=5",
                                 Runs.self)
        let mine = Self.commit(fromVersion: current)
        for run in runs.workflowRuns {
            if let mine, run.headSha.lowercased().hasPrefix(mine) { return nil }
            let list = try await api("actions/runs/\(run.id)/artifacts", Artifacts.self)
            guard let a = list.artifacts.first(where: { $0.name == artifactName && !$0.expired }) else { continue }
            return AppUpdate(commit: run.headSha, title: run.displayTitle ?? "", date: run.updatedAt,
                             artifactID: a.id, sizeBytes: a.sizeInBytes)
        }
        return nil
    }

    /// Downloads the artifact (a zip holding Monitor.zip) into `dir`.
    public func download(_ update: AppUpdate, into dir: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("artifact-\(update.artifactID).zip")
        let url = URL(string: "https://api.github.com/repos/\(repo)/actions/artifacts/\(update.artifactID)/zip")!
        let code = try await http.download(url, headers: headers, to: file)
        guard code == 200 else {
            try? FileManager.default.removeItem(at: file)
            throw UpdateError(code == 410 ? "сборка уже удалена с GitHub" : "не удалось скачать сборку: HTTP \(code)")
        }
        return file
    }

    #if os(macOS)
    /// Unpacks the download, checks it is Monitor.app, swaps it in for the
    /// running bundle and opens it; the new copy quits this one on launch
    /// (SingleInstance). The download and the old bundle are deleted.
    public func install(_ artifact: URL, replacing app: URL = Bundle.main.bundleURL) throws {
        let fm = FileManager.default
        let work = artifact.deletingLastPathComponent().appendingPathComponent("unpacked-\(UUID().uuidString)")
        defer {
            try? fm.removeItem(at: work)
            try? fm.removeItem(at: artifact)
        }
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try Self.run("/usr/bin/ditto", ["-x", "-k", artifact.path, work.path])
        let inner = work.appendingPathComponent("Monitor.zip")
        if fm.fileExists(atPath: inner.path) {
            try Self.run("/usr/bin/ditto", ["-x", "-k", inner.path, work.path])
        }
        let newApp = work.appendingPathComponent("Monitor.app")
        guard let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier ?? "com.janderov.monitor"
        else { throw UpdateError("в скачанной сборке нет Monitor.app") }
        try? Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
        try Self.run("/usr/bin/codesign", ["--verify", newApp.path])

        // Swap: old bundle aside, new one in place; the running process keeps
        // its already-open files.
        let old = work.appendingPathComponent("old-Monitor.app")
        try fm.moveItem(at: app, to: old)
        do {
            try fm.moveItem(at: newApp, to: app)
        } catch {
            try? fm.moveItem(at: old, to: app)
            throw UpdateError("не удалось заменить \(app.path): \(error.localizedDescription)")
        }
        try Self.run("/usr/bin/open", ["-n", app.path])
    }

    static func run(_ path: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw UpdateError("\(URL(fileURLWithPath: path).lastPathComponent): \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
    #endif
}
