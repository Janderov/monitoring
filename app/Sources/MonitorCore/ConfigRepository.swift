import Foundation

/// Reads and changes `servers.json` for the add/edit/delete screens. Agent
/// tokens go to the secret store (Keychain) and never into the file; every
/// change is validated and written atomically, keeping the previous version
/// as servers.json.bak.
public actor ConfigRepository {
    public let url: URL
    private let secrets: SecretStore

    public init(url: URL = DataFolder.serversFile, secrets: SecretStore) {
        self.url = url
        self.secrets = secrets
    }

    /// The file with tokens filled in from the secret store. Tokens still
    /// written in the file (hand-edited or from older versions) are moved to
    /// the secret store and removed from the file.
    public func load() throws -> ServersFile {
        let file = try read()
        try file.validate()
        return file
    }

    /// Like `load` without validation, so a broken entry can still be
    /// replaced or deleted.
    private func read() throws -> ServersFile {
        var file = try ServersFile.decode(Data(contentsOf: url))
        var moved = false
        for i in file.servers.indices {
            let key = SecretKey.agentToken(file.servers[i].id)
            if file.servers[i].token.isEmpty {
                file.servers[i].token = try secrets.get(key) ?? ""
            } else if !file.servers[i].token.hasPrefix("PASTE") {
                try secrets.set(file.servers[i].token, for: key)
                moved = true
            }
        }
        if moved { try write(file) }
        if var sites = file.sites {
            for i in sites.indices where sites[i].authUser != nil {
                sites[i].authPassword = try secrets.get(SecretKey.siteAuth(sites[i].id))
            }
            file.sites = sites
        }
        return file
    }

    /// Adds the server or replaces the one with the same id.
    @discardableResult
    public func upsertServer(_ server: ServerConfig) throws -> ServersFile {
        var file = try read()
        if let i = file.servers.firstIndex(where: { $0.id == server.id }) {
            file.servers[i] = server
        } else {
            file.servers.append(server)
        }
        try file.validate()
        try secrets.set(server.token, for: SecretKey.agentToken(server.id))
        try write(file)
        return file
    }

    /// Removes the server, its secrets and its mention in sites' `from`. A
    /// site left with an empty `from` is checked from all servers again.
    @discardableResult
    public func removeServer(id: String) throws -> ServersFile {
        var file = try read()
        file.servers.removeAll { $0.id == id }
        if var sites = file.sites {
            for i in sites.indices {
                guard let from = sites[i].from else { continue }
                let rest = from.filter { $0 != id }
                sites[i].from = rest.isEmpty ? nil : rest
            }
            file.sites = sites
        }
        try write(file)
        try secrets.remove(SecretKey.agentToken(id))
        try secrets.remove(SecretKey.sshPassword(id))
        return file
    }

    @discardableResult
    public func upsertSite(_ site: SiteConfig) throws -> ServersFile {
        var file = try read()
        var sites = file.sites ?? []
        if let i = sites.firstIndex(where: { $0.id == site.id }) { sites[i] = site } else { sites.append(site) }
        file.sites = sites
        try file.validate()
        if site.authUser?.isEmpty == false, let password = site.authPassword, !password.isEmpty {
            try secrets.set(password, for: SecretKey.siteAuth(site.id))
        } else if site.authUser?.isEmpty ?? true {
            try secrets.remove(SecretKey.siteAuth(site.id))
        }
        try write(file)
        return file
    }

    @discardableResult
    public func removeSite(id: String) throws -> ServersFile {
        var file = try read()
        file.sites?.removeAll { $0.id == id }
        try write(file)
        try secrets.remove(SecretKey.siteAuth(id))
        return file
    }

    /// Writes the file without tokens: temp file (owner-only) then rename, so
    /// a crash never leaves half a file.
    private func write(_ file: ServersFile) throws {
        var stripped = file
        for i in stripped.servers.indices { stripped.servers[i].token = "" }
        let data = try stripped.encoded()

        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = dir.appendingPathComponent(".servers.json.\(UUID().uuidString)")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw ConfigError("не удалось записать \(tmp.path)")
        }
        let backup = url.appendingPathExtension("bak")
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: url, to: backup)
            // The old file may still contain plaintext tokens.
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        guard rename(tmp.path, url.path) == 0 else {
            try? fm.removeItem(at: tmp)
            throw ConfigError("не удалось сохранить \(url.path): \(String(cString: strerror(errno)))")
        }
    }
}

extension ServersFile {
    /// A short unused id for a new server or site, from its name or address:
    /// "Нидерланды" -> "srv", "192.0.2.121" -> "192-0-2-121".
    public func newID(from text: String, existing: [String], fallback: String) -> String {
        var base = ""
        for ch in text.lowercased() {
            if ch.isASCII, ch.isLetter || ch.isNumber { base.append(ch) } else if !base.hasSuffix("-") { base.append("-") }
        }
        base = String(base.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(24))
        if base.isEmpty { base = fallback }
        let taken = Set(existing)
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    public func newServerID(from text: String) -> String {
        newID(from: text, existing: servers.map(\.id), fallback: "srv")
    }

    public func newSiteID(from text: String) -> String {
        newID(from: text, existing: (sites ?? []).map(\.id), fallback: "site")
    }
}
