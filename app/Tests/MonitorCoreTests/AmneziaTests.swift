import Foundation
import XCTest
@testable import MonitorCore

let serverConf = """
[Interface]
PrivateKey = SERVERPRIV=
Address = 10.8.1.0/24
ListenPort = 41234
Jc = 4
Jmin = 10
Jmax = 50
S1 = 101
S2 = 57
H1 = 1111
H2 = 2222
H3 = 3333
H4 = 4444

[Peer]
PublicKey = PHONE=
PresharedKey = PSK=
AllowedIPs = 10.8.1.1/32

[Peer]
# laptop
PublicKey = LAPTOP=
PresharedKey = PSK=
AllowedIPs = 10.8.1.2/32

"""

final class WGConfigTests: XCTestCase {
    func testPeersAndFreeAddress() {
        let c = WGConfig(serverConf)
        XCTAssertEqual(c.peers.map(\.publicKey), ["PHONE=", "LAPTOP="])
        XCTAssertEqual(c.listenPort, "41234")
        XCTAssertEqual(c.freeAddress(), "10.8.1.3")
    }

    func testAddRemoveStrip() {
        var c = WGConfig(serverConf)
        c.addPeer(publicKey: "NEW=", presharedKey: "PSK=", allowedIPs: "10.8.1.3/32")
        XCTAssertEqual(c.peers.last, WGConfig.Peer(publicKey: "NEW=", allowedIPs: "10.8.1.3/32"))
        XCTAssertEqual(c.freeAddress(), "10.8.1.4")
        XCTAssertTrue(c.removePeer(publicKey: "LAPTOP="))
        XCTAssertFalse(c.text.contains("laptop"))
        XCTAssertEqual(c.peers.map(\.publicKey), ["PHONE=", "NEW="])
        XCTAssertFalse(c.removePeer(publicKey: "NOPE="))
        XCTAssertFalse(c.stripped().contains("Address"))
        XCTAssertTrue(c.stripped().contains("Jc = 4"))
        XCTAssertTrue(c.stripped().contains("ListenPort = 41234"))
    }

    func testClientConfigCarriesObfuscation() {
        let text = WGConfig(serverConf).clientConfig(privateKey: "CPRIV=", address: "10.8.1.3/32",
                                                    serverPublicKey: "SPUB=", presharedKey: "PSK=",
                                                    endpoint: "203.0.113.10:41234")
        for line in ["PrivateKey = CPRIV=", "Address = 10.8.1.3/32", "Jc = 4", "H4 = 4444", "PublicKey = SPUB=",
                     "Endpoint = 203.0.113.10:41234", "AllowedIPs = 0.0.0.0/0, ::/0"] {
            XCTAssertTrue(text.contains(line), line)
        }
        XCTAssertFalse(text.contains("SERVERPRIV"))
    }

    func testClientsTable() throws {
        let json = #"[{"clientId":"PHONE=","userData":{"clientName":"Телефон","creationDate":"x"},"extra":1}]"#
        let added = try ClientsTable.adding(json, publicKey: "NEW=", name: "Ноутбук", created: "y")
        XCTAssertEqual(ClientsTable.entries(added)["NEW="]?.name, "Ноутбук")
        XCTAssertTrue(added.contains("extra"))
        let removed = try ClientsTable.removing(added, publicKey: "PHONE=")
        XCTAssertNil(ClientsTable.entries(removed)["PHONE="])
        XCTAssertEqual(AmneziaKeys.fileName("iPhone Миши"), "iphone-миши.conf")
    }
}

final class FakeAmneziaSSH: SSHRunner, @unchecked Sendable {
    private let lock = NSLock()
    var conf = serverConf
    var table = #"[{"clientId":"PHONE=","userData":{"clientName":"Телефон"}}]"#
    private var _scripts: [String] = []
    var scripts: [String] { lock.withLock { _scripts } }

    func run(_ target: SSHTarget, password: String?, command: String, stdin: Data?) async throws -> SSHOutput {
        let script = String(decoding: stdin ?? Data(), as: UTF8.self)
        lock.withLock { _scripts.append(script) }
        XCTAssertTrue(command.contains("docker exec -i amnezia-awg2 sh -s"), command)
        if script.contains("syncconf") {
            // Pull the new files out of the heredocs, like the shell would.
            let blocks = script.components(separatedBy: "<<'B64'\n").dropFirst()
                .map { $0.components(separatedBy: "\nB64")[0].replacingOccurrences(of: "\n", with: "") }
            conf = String(decoding: Data(base64Encoded: blocks[0])!, as: UTF8.self)
            table = String(decoding: Data(base64Encoded: blocks[1])!, as: UTF8.self)
            return SSHOutput(status: 0, stdout: "ok\n", stderr: "")
        }
        // Like the real script: `sect` prints "\n@@name\n" and `cat` copies the
        // file as is, so a file without a final newline must still parse.
        func sect(_ name: String) -> String { "\n@@\(name)\n" }
        var out = "dir=/opt/amnezia/awg\nconf=/opt/amnezia/awg/awg0.conf\ntool=awg\n"
        out += sect("conf") + conf + sect("clients") + table + sect("serverpub") + "SPUB=" + sect("psk") + "PSK=\n"
        if script.contains("genkey") { out += sect("keys") + "CPRIV=\nCPUB=\nOTHERPSK=\n" }
        out += sect("end")
        return SSHOutput(status: 0, stdout: out, stderr: "")
    }

    func upload(_ target: SSHTarget, password: String?, files: [URL], to remoteDir: String) async throws {}
    func resolveHost(_ target: SSHTarget) async -> String { target.host }
    func close(_ target: SSHTarget) async {}
}

final class AmneziaKeysTests: XCTestCase {
    func testCreateListDelete() async throws {
        let ssh = FakeAmneziaSSH()
        let server = ServerConfig(id: "nl", name: "NL", host: "203.0.113.10", token: "t", fingerprint: "f")
        let keys = AmneziaKeys(server: server, ssh: ssh)

        let before = try await keys.list(container: "amnezia-awg2")
        XCTAssertEqual(before.map(\.name), ["Телефон", "без имени"])

        let new = try await keys.create(container: "amnezia-awg2", name: "iPhone Миши")
        XCTAssertEqual(new.client.address, "10.8.1.3/32")
        XCTAssertEqual(new.fileName, "iphone-миши.conf")
        XCTAssertTrue(new.config.contains("Endpoint = 203.0.113.10:41234"))
        XCTAssertTrue(new.config.contains("PresharedKey = PSK="), "uses the server-wide PSK")
        XCTAssertTrue(ssh.conf.contains("PublicKey = CPUB="))
        XCTAssertFalse(ssh.conf.contains("CPRIV"), "the client's private key never lands on the server")

        // The vpn:// link carries the same key for the AmneziaVPN app.
        let json = try XCTUnwrap(AmneziaLinkTests.decode(try XCTUnwrap(new.amneziaLink)))
        XCTAssertEqual(json["defaultContainer"] as? String, "amnezia-awg2")
        XCTAssertEqual(json["description"] as? String, "NL")
        let awg = try XCTUnwrap(((json["containers"] as? [[String: Any]])?.first)?["awg"] as? [String: Any])
        XCTAssertEqual(awg["port"] as? String, "41234")
        let last = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(try XCTUnwrap(awg["last_config"] as? String).utf8)) as? [String: Any])
        XCTAssertEqual(last["client_priv_key"] as? String, "CPRIV=")
        XCTAssertEqual(last["client_ip"] as? String, "10.8.1.3")
        XCTAssertEqual(last["config"] as? String, new.config)

        let after = try await keys.list(container: "amnezia-awg2")
        XCTAssertEqual(after.last?.name, "iPhone Миши")

        try await keys.delete(container: "amnezia-awg2", publicKey: "CPUB=")
        XCTAssertFalse(ssh.conf.contains("CPUB="))
        XCTAssertNil(ClientsTable.entries(ssh.table)["CPUB="])
        XCTAssertTrue(ssh.conf.hasSuffix("\n") && ssh.table.hasSuffix("\n"), "files end with a newline")
        let write = ssh.scripts.last!
        XCTAssertTrue(write.contains("cp -p \"$CONF\" \"$CONF.bak-$TS\""))
    }

    func testRejectsOddContainerName() async {
        let keys = AmneziaKeys(ssh: FakeAmneziaSSH(), target: SSHTarget(host: "h"), endpointHost: "h")
        do { _ = try await keys.list(container: "x; rm -rf /"); XCTFail() } catch {}
    }
}

final class AmneziaLinkTests: XCTestCase {
    /// Reverses the link: base64url, qCompress header, zlib stored blocks.
    static func decode(_ link: String) throws -> [String: Any]? {
        var b64 = String(link.dropFirst("vpn://".count))
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        let bytes = [UInt8](try XCTUnwrap(Data(base64Encoded: b64)))
        let size = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        XCTAssertEqual(Array(bytes[4..<6]), [0x78, 0x01])
        var i = 6, out: [UInt8] = []
        while true {
            let final = bytes[i] & 1
            let len = Int(bytes[i + 1]) | Int(bytes[i + 2]) << 8
            let nlen = Int(bytes[i + 3]) | Int(bytes[i + 4]) << 8
            XCTAssertEqual(len ^ 0xFFFF, nlen)
            out += bytes[(i + 5)..<(i + 5 + len)]
            i += 5 + len
            if final == 1 { break }
        }
        XCTAssertEqual(out.count, size)
        let a = AmneziaLink.adler32(out)
        XCTAssertEqual(Array(bytes[i..<(i + 4)]), [UInt8(a >> 24), UInt8(a >> 16 & 255), UInt8(a >> 8 & 255), UInt8(a & 255)])
        return try JSONSerialization.jsonObject(with: Data(out)) as? [String: Any]
    }

    func testAdlerAndLargeInput() throws {
        XCTAssertEqual(AmneziaLink.adler32(Array("Wikipedia".utf8)), 0x11E60398)
        // More than one stored block.
        let big = Data(repeating: 65, count: 70_000)
        let z = AmneziaLink.qCompress(big)
        XCTAssertEqual(z.count, 4 + 2 + (5 + 65535) + (5 + 4465) + 4)
    }
}
