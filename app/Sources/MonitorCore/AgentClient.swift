import Foundation

/// Sends one HTTP request to an agent. The real implementation (macOS) pins
/// the agent certificate; tests substitute a fake.
public protocol AgentTransport: Sendable {
    func send(_ server: ServerConfig, method: String, path: String, body: Data?) async throws -> (Int, Data)
}

public enum AgentError: Error, Equatable, CustomStringConvertible, Sendable {
    case unauthorized
    case http(Int, String)
    case decoding(String)

    public var description: String {
        switch self {
        case .unauthorized: return "агент отклонил ключ (401)"
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        case .decoding(let msg): return "не удалось разобрать ответ агента: \(msg)"
        }
    }
}

public struct AgentClient: Sendable {
    public let transport: AgentTransport

    public init(transport: AgentTransport) { self.transport = transport }

    public struct Health: Decodable, Sendable {
        public var status: String
        public var version: String
    }

    public func health(_ server: ServerConfig) async throws -> Health {
        try decode(Health.self, try await get(server, "/v1/health"))
    }

    public func snapshot(_ server: ServerConfig) async throws -> Snapshot {
        try decode(Snapshot.self, try await get(server, "/v1/snapshot"))
    }

    /// All snapshots newer than `since`, following the agent's paging.
    public func history(_ server: ServerConfig, since: Date) async throws -> [Snapshot] {
        var out: [Snapshot] = []
        var cursor = since
        for _ in 0..<20 { // 20 pages x 500 = far more than the agent's 24h buffer
            let page = try decode(HistoryPage.self,
                                  try await get(server, "/v1/history?since=\(Int(cursor.timeIntervalSince1970))"))
            let items = page.snapshots ?? []
            out.append(contentsOf: items.filter { $0.time > since })
            guard page.more, let last = items.last else { break }
            cursor = last.time
        }
        return out
    }

    public func setChecks(_ server: ServerConfig, targets: [CheckTarget]) async throws {
        let body = try JSONEncoder().encode(["targets": targets])
        let (code, data) = try await transport.send(server, method: "PUT", path: "/v1/checks", body: body)
        try check(code, data)
    }

    private func get(_ server: ServerConfig, _ path: String) async throws -> Data {
        let (code, data) = try await transport.send(server, method: "GET", path: path, body: nil)
        try check(code, data)
        return data
    }

    private func check(_ code: Int, _ data: Data) throws {
        if code == 401 { throw AgentError.unauthorized }
        guard (200..<300).contains(code) else {
            throw AgentError.http(code, String(decoding: data, as: UTF8.self))
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try AgentJSON.decoder.decode(type, from: data) }
        catch { throw AgentError.decoding(String(describing: error)) }
    }
}

/// A site or server the agent should probe (agent/internal/probe.Target).
public struct CheckTarget: Codable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var url: String?
    public var host: String?
    public var port: Int?
    /// Login for a site behind HTTP basic auth. Agents before this field
    /// reject unknown keys, so it is sent only when set.
    public var basicAuth: BasicAuth? = nil

    public struct BasicAuth: Codable, Equatable, Sendable {
        public var user: String
        public var password: String
        public init(user: String, password: String) { self.user = user; self.password = password }
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, url, host, port
        case basicAuth = "basic_auth"
    }

    public static func http(_ id: String, url: String, auth: BasicAuth? = nil) -> CheckTarget {
        CheckTarget(id: id, kind: "http", url: url, host: nil, port: nil, basicAuth: auth)
    }
    public static func tcp(_ id: String, host: String, port: Int) -> CheckTarget {
        CheckTarget(id: id, kind: "tcp", url: nil, host: host, port: port)
    }
}
