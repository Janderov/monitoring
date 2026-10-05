import Foundation
import XCTest
@testable import MonitorCore

final class IPLookupTests: XCTestCase {
    func testRIPE() {
        let json = #"{"objectClassName":"ip network","handle":"192.0.2.0 - 192.0.2.255","name":"NL-NET","country":"nl"}"#
        XCTAssertEqual(IPRDAP.parse(Data(json.utf8), ip: "192.0.2.110"),
                       IPOwner(ip: "192.0.2.110", country: "NL", network: "NL-NET"))
    }

    func testARINCountryFromAddress() {
        let json = #"""
        {"objectClassName":"ip network","name":"VULTR-NET","entities":[
          {"objectClassName":"entity","vcardArray":["vcard",[["version",{},"text","4.0"],
            ["adr",{"label":"319 Clematis Street\nWest Palm Beach\nFL\n33401\nUnited States"},"text",["","","","","","",""]]]]}]}
        """#
        XCTAssertEqual(IPRDAP.parse(Data(json.utf8), ip: "192.0.2.130")?.country, "US")
        XCTAssertNil(IPRDAP.parse(Data(#"{"objectClassName":"domain"}"#.utf8), ip: "1.2.3.4"))
    }

    func testCachesAnswers() async {
        let calls = Counter()
        let lookup = IPLookup(fetch: { _ in
            calls.inc()
            return Data(#"{"objectClassName":"ip network","country":"DE"}"#.utf8)
        })
        let first = await lookup.owner(of: "5.6.7.8")
        let second = await lookup.owner(of: "5.6.7.8")
        XCTAssertEqual(first?.country, "DE")
        XCTAssertEqual(second?.country, "DE")
        XCTAssertEqual(calls.value, 1)
        let cached = await lookup.cached("5.6.7.8")
        XCTAssertEqual(cached?.country, "DE")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func inc() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}
