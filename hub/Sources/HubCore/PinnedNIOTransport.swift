import Crypto
import Foundation
import MonitorCore
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL

/// HTTPS to agents from Linux, with the same rule as the Mac's
/// PinnedTransport: the agent's self-signed certificate is accepted only if
/// its SHA-256 matches the fingerprint saved for that server, and no CA is
/// trusted. One connection per request, as agents are polled once a minute.
public final class PinnedNIOTransport: AgentTransport, @unchecked Sendable {
    let group: EventLoopGroup
    let timeout: TimeAmount

    public init(group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton, timeout: TimeAmount = .seconds(15)) {
        self.group = group
        self.timeout = timeout
    }

    public struct PinError: Error, CustomStringConvertible {
        public var description: String
    }

    public func send(_ server: ServerConfig, method: String, path: String, body: Data?) async throws -> (Int, Data) {
        guard let want = Fingerprint.bytes(server.fingerprint) else {
            throw PinError(description: "у сервера неверный отпечаток сертификата")
        }
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification = .noHostnameVerification
        tls.minimumTLSVersion = .tlsv12
        let context = try NIOSSLContext(configuration: tls)
        let host = server.host
        let isIP = (try? SocketAddress(ipAddress: host, port: 0)) != nil
        let promise = group.next().makePromise(of: (Int, Data).self)
        let timeout = self.timeout

        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(.seconds(10))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssl = try NIOSSLClientHandler(context: context, serverHostname: isIP ? nil : host,
                                                      customVerificationCallback: { chain, verify in
                        guard let leaf = chain.first, let der = try? leaf.toDERBytes() else {
                            verify.succeed(.failed)
                            return
                        }
                        let digest = Array(SHA256.hash(data: der))
                        verify.succeed(digest == want ? .certificateVerified : .failed)
                    })
                    try channel.pipeline.syncOperations.addHandler(ssl)
                    try channel.pipeline.syncOperations.addHTTPClientHandlers()
                    try channel.pipeline.syncOperations.addHandler(ResponseCollector(promise: promise))
                }
            }

        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: host, port: server.port).get()
        } catch {
            promise.fail(error)
            throw error
        }
        let deadline = channel.eventLoop.scheduleTask(in: timeout) {
            promise.fail(PinError(description: "агент не ответил за \(timeout.nanoseconds / 1_000_000_000) с"))
            channel.close(promise: nil)
        }
        promise.futureResult.whenComplete { _ in
            deadline.cancel()
            channel.close(promise: nil)
        }

        var head = HTTPRequestHead(version: .http1_1, method: HTTPMethod(rawValue: method), uri: path)
        head.headers.add(name: "Host", value: isIP ? host : "\(host):\(server.port)")
        head.headers.add(name: "Authorization", value: "Bearer \(server.token)")
        head.headers.add(name: "Connection", value: "close")
        head.headers.add(name: "Accept", value: "application/json")
        if let body {
            head.headers.add(name: "Content-Type", value: "application/json")
            head.headers.add(name: "Content-Length", value: String(body.count))
        }
        channel.write(HTTPClientRequestPart.head(head), promise: nil)
        if let body {
            channel.write(HTTPClientRequestPart.body(.byteBuffer(ByteBuffer(bytes: body))), promise: nil)
        }
        channel.writeAndFlush(HTTPClientRequestPart.end(nil)).whenFailure { promise.fail($0) }
        return try await promise.futureResult.get()
    }
}

/// Gathers one HTTP response and completes the promise with status and body.
final class ResponseCollector: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPClientResponsePart
    let promise: EventLoopPromise<(Int, Data)>
    var status = 0
    var body = Data()
    static let maxBody = 32 * 1024 * 1024

    init(promise: EventLoopPromise<(Int, Data)>) { self.promise = promise }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h):
            status = Int(h.status.code)
        case .body(var buf):
            if body.count + buf.readableBytes > Self.maxBody {
                promise.fail(PinnedNIOTransport.PinError(description: "слишком большой ответ агента"))
                context.close(promise: nil)
                return
            }
            if let bytes = buf.readBytes(length: buf.readableBytes) { body.append(contentsOf: bytes) }
        case .end:
            promise.succeed((status, body))
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        promise.fail(PinnedNIOTransport.PinError(description: "соединение с агентом закрыто"))
    }
}
