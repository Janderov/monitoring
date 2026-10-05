import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Who holds an address on the internet, from the regional registry over RDAP:
/// enough to put an unknown hop of a chain in the right country on the map,
/// without a third-party geo service.
public struct IPOwner: Equatable, Sendable {
    public var ip: String
    /// ISO country code of the network's holder, e.g. "NL"; nil when the registry does not say.
    public var country: String?
    /// The registry's network name, e.g. "VULTR-NET" or "AEZA-NET".
    public var network: String?
}

public enum IPRDAP {
    /// Parses an RDAP "ip network" response. RIPE, APNIC, LACNIC and AFRINIC
    /// put the country at the top level; ARIN only has it in the holder's address.
    public static func parse(_ data: Data, ip: String) -> IPOwner? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["objectClassName"] as? String == "ip network" else { return nil }
        var country = (obj["country"] as? String)?.uppercased()
        if country == nil, let entities = obj["entities"] as? [[String: Any]] {
            country = entities.lazy.compactMap(addressCountry).first
        }
        return IPOwner(ip: ip, country: country, network: obj["name"] as? String)
    }

    /// The last line of a vCard address label, as ARIN writes it ("...\nUnited States").
    static func addressCountry(_ entity: [String: Any]) -> String? {
        guard let vcard = entity["vcardArray"] as? [Any], vcard.count > 1,
              let props = vcard[1] as? [[Any]] else { return nil }
        for p in props where p.first as? String == "adr" {
            guard p.count > 1, let params = p[1] as? [String: Any],
                  let label = params["label"] as? String,
                  let last = label.split(separator: "\n").last?.trimmingCharacters(in: .whitespaces)
            else { continue }
            if let code = countryCodes[last.lowercased()] { return code }
            if last.count == 2, last.allSatisfy(\.isLetter) { return last.uppercased() }
        }
        return nil
    }

    /// ARIN serves North America and part of the Caribbean.
    static let countryCodes = ["united states": "US", "canada": "CA", "puerto rico": "PR", "jamaica": "JM",
                               "bahamas": "BS", "barbados": "BB", "bermuda": "BM"]
}

/// Looks addresses up once and remembers the answer: registries rate-limit,
/// and a network's holder rarely changes.
public actor IPLookup {
    public typealias Fetch = @Sendable (String) async throws -> Data

    private let fetch: Fetch
    private let now: @Sendable () -> Date
    private var cache: [String: (owner: IPOwner?, until: Date)] = [:]
    private var inFlight: [String: Task<IPOwner?, Never>] = [:]

    /// Known answers are kept for a week; failures are retried after an hour.
    static let keep: TimeInterval = 7 * 86400
    static let retry: TimeInterval = 3600

    public init(fetch: @escaping Fetch = IPLookup.rdap, now: @escaping @Sendable () -> Date = Date.init) {
        self.fetch = fetch
        self.now = now
    }

    public func owner(of ip: String) async -> IPOwner? {
        if let c = cache[ip], c.until > now() { return c.owner }
        if let t = inFlight[ip] { return await t.value }
        let t = Task { [fetch] () -> IPOwner? in
            guard let data = try? await fetch(ip) else { return nil }
            return IPRDAP.parse(data, ip: ip)
        }
        inFlight[ip] = t
        let owner = await t.value
        inFlight[ip] = nil
        cache[ip] = (owner, now().addingTimeInterval(owner == nil ? Self.retry : Self.keep))
        return owner
    }

    /// The answer already known, without asking the registry.
    public func cached(_ ip: String) -> IPOwner? {
        guard let c = cache[ip], c.until > now() else { return nil }
        return c.owner
    }

    /// rdap.org redirects to the regional registry that holds the address.
    public static let rdap: Fetch = { ip in
        guard let url = URL(string: "https://rdap.org/ip/\(ip)") else { throw ConfigError("неверный адрес \(ip)") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("application/rdap+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw ConfigError("RDAP ответил HTTP \(code)") }
        return data
    }
}
