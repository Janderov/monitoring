#if canImport(Security) && canImport(CryptoKit)
import CryptoKit
import Foundation
import Security

/// HTTPS to agents with certificate pinning: the agent's self-signed
/// certificate is accepted only if its SHA-256 matches the fingerprint saved
/// for that server. No CA is trusted for agent connections.
public final class PinnedTransport: AgentTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: URLSession] = [:]

    public init() {}

    public func send(_ server: ServerConfig, method: String, path: String, body: Data?) async throws -> (Int, Data) {
        var req = URLRequest(url: URL(string: path, relativeTo: server.baseURL)!)
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await session(for: server).data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    private func session(for server: ServerConfig) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(server.id)|\(server.host)|\(server.port)|\(server.fingerprint)"
        if let s = sessions[key] { return s }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        cfg.connectionProxyDictionary = [:] // agents are reached directly
        let s = URLSession(configuration: cfg, delegate: PinningDelegate(fingerprint: server.fingerprint),
                           delegateQueue: nil)
        sessions[key] = s
        return s
    }
}

private final class PinningDelegate: NSObject, URLSessionDelegate {
    let fingerprint: String

    init(fingerprint: String) { self.fingerprint = fingerprint }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let der = SecCertificateCopyData(leaf) as Data
        if Fingerprint.matches(fingerprint, sha256: Array(SHA256.hash(data: der))) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
#endif
