import Foundation
#if canImport(Security)
import Security
#endif
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
    /// The CI artifact, for builds published before releases (0 for a release).
    public var artifactID: Int
    public var sizeBytes: Int
    /// The release's Monitor.zip; releases are public and never expire.
    public var downloadURL: URL? = nil
    /// The build number of a release ("build-123").
    public var build: Int? = nil
    /// Version string the new build reports, e.g. "0.0.0-dev-1a2b3c4".
    public var version: String {
        build.map { "1.\($0)-dev-" + commit.prefix(7) } ?? "0.0.0-dev-" + commit.prefix(7)
    }
}

public struct UpdateError: Error, CustomStringConvertible, Sendable {
    public var description: String
    public init(_ d: String) { description = d }
}

/// Updates the app from the newest build of main: a `build-N` release that CI
/// publishes for every green build (public, kept forever, no token needed),
/// or, before the first release, the `Monitor-app` artifact of the `app`
/// workflow, which needs a GitHub token with read access to Actions.
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

    /// Build number of a release build ("1.123-dev-…" → 123).
    public static func build(fromVersion v: String) -> Int? {
        guard v.hasPrefix("1.") else { return nil }
        return Int(v.dropFirst(2).prefix { $0.isNumber })
    }

    /// Commit the running build came from, when it is a CI build of a commit.
    public static func commit(fromVersion v: String) -> String? {
        guard let r = v.range(of: "dev-", options: .backwards) else { return nil }
        let c = String(v[r.upperBound...])
        return c.count >= 7 && c.allSatisfy(\.isHexDigit) ? c.lowercased() : nil
    }

    private var headers: [String: String] {
        var h = ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"]
        if !token.isEmpty { h["Authorization"] = "Bearer \(token)" }
        return h
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
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
        do { return try Self.decoder.decode(type, from: data) } catch { throw UpdateError("непонятный ответ GitHub: \(error)") }
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

    struct Release: Decodable {
        struct Asset: Decodable { var name: String; var size: Int; var browserDownloadUrl: URL }
        var tagName: String
        var name: String?
        var targetCommitish: String
        var draft: Bool
        var publishedAt: Date?
        var assets: [Asset]
    }

    /// The newest release build of main; nil when there are none yet.
    func newestRelease() async -> AppUpdate? {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=10")!
        guard let response = try? await http.get(url, headers: headers), response.0 == 200,
              let list = try? Self.decoder.decode([Release].self, from: response.1) else { return nil }
        for r in list where !r.draft && r.tagName.hasPrefix("build-") {
            guard let n = Int(r.tagName.dropFirst("build-".count)),
                  let zip = r.assets.first(where: { $0.name == "Monitor.zip" }) else { continue }
            let title = (r.name ?? "").replacingOccurrences(of: #"^Сборка \d+: "#, with: "", options: .regularExpression)
            return AppUpdate(commit: r.targetCommitish, title: title, date: r.publishedAt ?? Date(), artifactID: 0,
                             sizeBytes: zip.size, downloadURL: zip.browserDownloadUrl, build: n)
        }
        return nil
    }

    /// The newest build of main, or nil when the running build is it (or newer).
    public func check(current: String = AppUpdater.currentVersion) async throws -> AppUpdate? {
        if let release = await newestRelease() {
            let mine = Self.commit(fromVersion: current)
            if let mine, release.commit.lowercased().hasPrefix(mine) { return nil }
            if let n = Self.build(fromVersion: current), let m = release.build, m <= n { return nil }
            return release
        }
        // Before the first release only the CI artifacts exist, behind a token.
        guard !token.isEmpty else { throw UpdateError("на GitHub ещё нет выпусков приложения") }
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

    /// Downloads the release's Monitor.zip, or the artifact (a zip holding
    /// Monitor.zip), into `dir`.
    public func download(_ update: AppUpdate, into dir: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let url = update.downloadURL {
            let file = dir.appendingPathComponent("Monitor-\(update.build ?? 0).zip")
            // The asset is public: no token goes to the download host.
            let code = try await http.download(url, headers: [:], to: file)
            guard code == 200 else {
                try? FileManager.default.removeItem(at: file)
                throw UpdateError("не удалось скачать сборку: HTTP \(code)")
            }
            return file
        }
        let file = dir.appendingPathComponent("artifact-\(update.artifactID).zip")
        let url = URL(string: "https://api.github.com/repos/\(repo)/actions/artifacts/\(update.artifactID)/zip")!
        let code = try await http.download(url, headers: headers, to: file)
        guard code == 200 else {
            try? FileManager.default.removeItem(at: file)
            throw UpdateError(code == 410 ? "сборка уже удалена с GitHub" : "не удалось скачать сборку: HTTP \(code)")
        }
        return file
    }

    /// Once the running app is signed with a certificate (docs/signing.md),
    /// only builds signed by the same team are installed, so a build from
    /// anywhere else cannot take over the app and its Keychain secrets.
    public static func checkSigner(current: String?, new: String?) throws {
        guard let current else { return }
        guard new == current else {
            throw UpdateError("сборка подписана не вашим сертификатом (\(new ?? "без подписи")), обновление отменено")
        }
    }

    #if os(macOS)
    /// Unpacks the download, checks it is Monitor.app, swaps it in for the
    /// running bundle and opens it; the new copy quits this one on launch
    /// (SingleInstance). The download and the old bundle are deleted.
    /// `keepPrevious`: where the replaced bundle is kept for "Вернуть
    /// предыдущую"; nil deletes it as before.
    public func install(_ artifact: URL, replacing app: URL = Bundle.main.bundleURL,
                        keepPrevious: URL? = nil) throws {
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
        try Self.checkSigner(current: Self.teamID(of: app), new: Self.teamID(of: newApp))

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
        if let keepPrevious {
            try? fm.removeItem(at: keepPrevious)
            try? fm.createDirectory(at: keepPrevious.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.moveItem(at: old, to: keepPrevious)
        }
        try Self.run("/usr/bin/open", ["-n", app.path])
    }

    /// Version of a bundle on disk (the kept previous build).
    public static func version(of bundle: URL) -> String? {
        NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"]
            as? String
    }

    /// Puts the kept previous build back once this process quits: swaps the
    /// bundles (so the newer one becomes "previous" and can come back the
    /// same way), restores the database copy made before the update when
    /// `database` is given, and opens the app. The caller then quits.
    public static func scheduleRollback(app: URL = Bundle.main.bundleURL, previous: URL,
                                        database: (live: URL, copy: URL)?) throws {
        let script = """
            pid="$1"; app="$2"; prev="$3"; db="$4"; copy="$5"
            i=0; while kill -0 "$pid" 2>/dev/null && [ $i -lt 150 ]; do sleep 0.2; i=$((i+1)); done
            if [ -n "$copy" ] && [ -f "$copy" ]; then rm -f "$db-wal" "$db-shm"; cp "$copy" "$db"; fi
            tmp="$prev.swap"; rm -rf "$tmp"
            mv "$app" "$tmp" && mv "$prev" "$app" && mv "$tmp" "$prev"
            open "$app"
            """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "rollback", String(ProcessInfo.processInfo.processIdentifier),
                       app.path, previous.path, database?.live.path ?? "", database?.copy.path ?? ""]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }

    /// When the certificate this build is signed with runs out; nil for an
    /// ad hoc signature.
    public static func signingExpiry(of bundle: URL = Bundle.main.bundleURL) -> Date? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let certs = (info as NSDictionary?)?[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certs.first,
              let values = SecCertificateCopyValues(leaf, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil)
                as? [String: Any],
              let entry = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any],
              let seconds = entry[kSecPropertyKeyValue as String] as? NSNumber
        else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds.doubleValue)
    }

    /// Team ID in a bundle's signature; nil when signed ad hoc.
    static func teamID(of bundle: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as NSDictionary?)?[kSecCodeInfoTeamIdentifier as String] as? String
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
