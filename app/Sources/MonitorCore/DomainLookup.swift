import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Network)
import Network
#endif

/// RDAP over HTTPS (rdap.org redirects to the registry's server) and WHOIS
/// over TCP 43 for zones without RDAP, such as .ru.
public struct NetworkDomainLookup: DomainLookupTransport {
    public init() {}

    public func rdap(_ domain: String) async throws -> Data {
        var req = URLRequest(url: URL(string: "https://rdap.org/domain/\(domain)")!)
        req.timeoutInterval = 20
        req.setValue("application/rdap+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw ConfigError("RDAP ответил HTTP \(code)") }
        return data
    }

    public func whois(server: String, query: String) async throws -> String {
        #if canImport(Network)
        return try await Whois.query(server: server, query: query)
        #else
        throw ConfigError("WHOIS доступен только на macOS")
        #endif
    }
}

#if canImport(Network)
enum Whois {
    static func query(server: String, query: String, timeout: TimeInterval = 15) async throws -> String {
        let conn = NWConnection(host: NWEndpoint.Host(server), port: 43, using: .tcp)
        let box = ResultBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                box.set(cont)
                @Sendable func read() {
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
                        let total = box.append(data)
                        if let error { box.finish(.failure(error)); conn.cancel(); return }
                        if done || total > 1 << 20 {
                            box.finish(.success(String(decoding: box.received, as: UTF8.self)))
                            conn.cancel()
                        } else {
                            read()
                        }
                    }
                }
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        conn.send(content: Data((query + "\r\n").utf8), completion: .contentProcessed { error in
                            if let error { box.finish(.failure(error)); conn.cancel() } else { read() }
                        })
                    case .failed(let error), .waiting(let error):
                        box.finish(.failure(error))
                        conn.cancel()
                    default: break
                    }
                }
                conn.start(queue: .global())
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    box.finish(.failure(ConfigError("WHOIS \(server): таймаут")))
                    conn.cancel()
                }
            }
        } onCancel: {
            conn.cancel()
        }
    }

    /// Resumes the continuation exactly once, whichever callback comes first.
    final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<String, Error>?
        private var pending: Result<String, Error>?
        private var data = Data()

        /// Adds received bytes and returns the total so far.
        func append(_ d: Data?) -> Int {
            lock.lock(); defer { lock.unlock() }
            if let d { data.append(d) }
            return data.count
        }

        var received: Data { lock.lock(); defer { lock.unlock() }; return data }

        func set(_ c: CheckedContinuation<String, Error>) {
            lock.lock()
            if let r = pending { pending = nil; lock.unlock(); c.resume(with: r); return }
            cont = c
            lock.unlock()
        }

        func finish(_ r: Result<String, Error>) {
            lock.lock()
            guard let c = cont else { if pending == nil { pending = r }; lock.unlock(); return }
            cont = nil
            lock.unlock()
            c.resume(with: r)
        }
    }
}
#endif
