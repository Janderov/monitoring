import Foundation

/// The AmneziaVPN app's share link: "vpn://" + base64url of Qt's qCompress
/// of a JSON server description with one AmneziaWG container. Pasting it in
/// the app ("Добавить сервер" → "Вставить ключ") or scanning it as a QR code
/// adds the server with this client's key.
public enum AmneziaLink {
    public struct Input: Sendable {
        public var description: String
        public var hostName: String
        public var port: String
        /// Container name on the server, e.g. "amnezia-awg2".
        public var container: String
        public var clientIP: String
        public var clientPrivateKey: String
        public var clientPublicKey: String
        public var presharedKey: String
        public var serverPublicKey: String
        /// Obfuscation values (Jc, S1, H1, ...) exactly as in the client config.
        public var obfuscation: [String: String]
        /// The full client config text the app falls back on.
        public var config: String
    }

    public static func make(_ i: Input) throws -> String {
        var last: [String: Any] = [
            "config": i.config,
            "hostName": i.hostName,
            "port": Int(i.port) ?? 51820,
            "client_ip": i.clientIP,
            "client_priv_key": i.clientPrivateKey,
            "client_pub_key": i.clientPublicKey,
            "psk_key": i.presharedKey,
            "server_pub_key": i.serverPublicKey,
            "mtu": "1280",
            "allowed_ips": ["0.0.0.0/0", "::/0"],
            "persistent_keep_alive": "25",
        ]
        var proto: [String: Any] = ["port": i.port, "transport_proto": "udp"]
        for (k, v) in i.obfuscation {
            last[k] = v
            proto[k] = v
        }
        let lastJSON = try JSONSerialization.data(withJSONObject: last, options: [.sortedKeys])
        proto["last_config"] = String(decoding: lastJSON, as: UTF8.self)
        let server: [String: Any] = [
            "containers": [["container": i.container, "awg": proto]],
            "defaultContainer": i.container,
            "description": i.description,
            "dns1": "1.1.1.1",
            "dns2": "1.0.0.1",
            "hostName": i.hostName,
        ]
        let json = try JSONSerialization.data(withJSONObject: server, options: [.sortedKeys])
        return "vpn://" + base64url(qCompress(json))
    }

    /// Qt's qCompress layout: the uncompressed length as 4 big-endian bytes,
    /// then a zlib stream. Stored (uncompressed) deflate blocks keep this free
    /// of a zlib dependency; a config is a couple of kilobytes either way.
    static func qCompress(_ data: Data) -> Data {
        var out = Data()
        let n = UInt32(data.count)
        out.append(contentsOf: [UInt8(n >> 24), UInt8(n >> 16 & 255), UInt8(n >> 8 & 255), UInt8(n & 255)])
        out.append(contentsOf: [0x78, 0x01]) // zlib header: deflate, 32K window, no preset dictionary
        let bytes = [UInt8](data)
        var offset = 0
        repeat {
            let len = min(65535, bytes.count - offset)
            let final: UInt8 = offset + len >= bytes.count ? 1 : 0
            out.append(final) // BFINAL, BTYPE=00 (stored), padded to the byte
            out.append(contentsOf: [UInt8(len & 255), UInt8(len >> 8)])
            out.append(contentsOf: [UInt8(~len & 255), UInt8((~len >> 8) & 255)])
            out.append(contentsOf: bytes[offset..<offset + len])
            offset += len
        } while offset < bytes.count
        let a = adler32(bytes)
        out.append(contentsOf: [UInt8(a >> 24), UInt8(a >> 16 & 255), UInt8(a >> 8 & 255), UInt8(a & 255)])
        return out
    }

    static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for x in bytes {
            a = (a + UInt32(x)) % 65521
            b = (b + a) % 65521
        }
        return b << 16 | a
    }

    static func base64url(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
