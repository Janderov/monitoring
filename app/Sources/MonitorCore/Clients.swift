import Foundation

/// A customer whose servers, sites and VPN keys are looked after, and who gets
/// the monthly report. The owner's own infrastructure is the internal client
/// «Своё», so every object always belongs to someone and filters work the
/// same way. Mirrors `inv.client` and friends in the hub's PostgreSQL schema
/// (architecture/db-schema.md); until the hub runs, the book lives in
/// clients.json next to servers.json.
public struct Client: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case company, person }
    /// Paused: no report and no night alerts, monitoring goes on.
    public enum State: String, Codable, CaseIterable, Sendable { case active, paused, ended }

    public var id: String
    public var name: String
    /// For the map and table cells, up to about 12 characters.
    public var shortName: String?
    public var kind: Kind
    public var state: State
    /// The one client «Своё».
    public var isInternal: Bool
    public var color: ClientColor
    public var legalName: String?
    public var inn: String?
    /// IANA name, e.g. "Europe/Moscow": report times and quiet hours.
    public var timezone: String?
    public var notes: String?
    public var contacts: [ClientContact]
    /// Tariff history, so last month's report keeps last month's price.
    public var contracts: [ClientContract]
    public var createdAt: Date
    /// Archived instead of deleted, so history stays readable.
    public var archivedAt: Date?

    public init(id: String = UUID().uuidString.lowercased(), name: String, shortName: String? = nil,
                kind: Kind = .company, state: State = .active, isInternal: Bool = false,
                color: ClientColor = .blue, legalName: String? = nil, inn: String? = nil,
                timezone: String? = nil, notes: String? = nil, contacts: [ClientContact] = [],
                contracts: [ClientContract] = [], createdAt: Date = Date(), archivedAt: Date? = nil) {
        self.id = id; self.name = name; self.shortName = shortName; self.kind = kind; self.state = state
        self.isInternal = isInternal; self.color = color; self.legalName = legalName; self.inn = inn
        self.timezone = timezone; self.notes = notes; self.contacts = contacts; self.contracts = contracts
        self.createdAt = createdAt; self.archivedAt = archivedAt
    }

    /// The short name when set, else the name.
    public var label: String {
        let s = shortName?.trimmingCharacters(in: .whitespaces) ?? ""
        return s.isEmpty ? name : s
    }

    /// The contract in force on `date`: the latest one started by then and
    /// not ended before it.
    public func contract(at date: Date = Date()) -> ClientContract? {
        contracts.filter { $0.startedOn <= date && ($0.endedOn.map { date < $0 } ?? true) }
            .max { $0.startedOn < $1.startedOn }
    }
}

/// Label colors from the system palette, one per client across the app.
public enum ClientColor: String, Codable, CaseIterable, Sendable {
    case gray, blue, orange, green, purple, pink, teal, red, yellow, brown

    public var title: String {
        switch self {
        case .gray: return "Серый"
        case .blue: return "Синий"
        case .orange: return "Оранжевый"
        case .green: return "Зелёный"
        case .purple: return "Фиолетовый"
        case .pink: return "Розовый"
        case .teal: return "Бирюзовый"
        case .red: return "Красный"
        case .yellow: return "Жёлтый"
        case .brown: return "Коричневый"
        }
    }
}

public struct ClientContact: Codable, Equatable, Identifiable, Sendable {
    public enum Role: String, Codable, CaseIterable, Sendable {
        case owner, tech, billing, other

        public var title: String {
            switch self {
            case .owner: return "руководитель"
            case .tech: return "технический"
            case .billing: return "оплата"
            case .other: return "другое"
            }
        }
    }

    public var id: String
    public var name: String
    public var role: Role
    public var phone: String?
    public var email: String?
    public var telegram: String?
    public var receivesReport: Bool
    public var receivesAlerts: Bool

    public init(id: String = UUID().uuidString.lowercased(), name: String, role: Role = .owner,
                phone: String? = nil, email: String? = nil, telegram: String? = nil,
                receivesReport: Bool = false, receivesAlerts: Bool = false) {
        self.id = id; self.name = name; self.role = role; self.phone = phone; self.email = email
        self.telegram = telegram; self.receivesReport = receivesReport; self.receivesAlerts = receivesAlerts
    }
}

public struct ClientContract: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var planName: String
    public var monthlyPrice: Double
    /// "₽", "€", "$".
    public var currency: String
    /// Day of the month the client pays, 1...31.
    public var billingDay: Int?
    public var startedOn: Date
    public var endedOn: Date?
    /// Promised availability in percent, e.g. 99.5.
    public var slaUptime: Double?
    /// Day of the month the report goes out.
    public var reportDay: Int?

    public init(id: String = UUID().uuidString.lowercased(), planName: String, monthlyPrice: Double,
                currency: String = "₽", billingDay: Int? = nil, startedOn: Date, endedOn: Date? = nil,
                slaUptime: Double? = nil, reportDay: Int? = 1) {
        self.id = id; self.planName = planName; self.monthlyPrice = monthlyPrice; self.currency = currency
        self.billingDay = billingDay; self.startedOn = startedOn; self.endedOn = endedOn
        self.slaUptime = slaUptime; self.reportDay = reportDay
    }
}

/// What can belong to a client. Raw values match `inv.client_asset.asset_type`.
public enum AssetType: String, Codable, CaseIterable, Sendable {
    case server, site, vpnKey = "vpn_key"
}

/// One object of one client over a period. A shared server has a row per
/// client; `until` keeps past months' reports right after an object moves.
public struct ClientAsset: Codable, Equatable, Hashable, Sendable {
    public var clientID: String
    public var type: AssetType
    /// Server or site id; the public key for a VPN key.
    public var assetID: String
    /// Share of a shared server's cost, in percent; nil splits the rest equally.
    public var sharePercent: Double?
    public var since: Date
    public var until: Date?

    public init(clientID: String, type: AssetType, assetID: String, sharePercent: Double? = nil,
                since: Date, until: Date? = nil) {
        self.clientID = clientID; self.type = type; self.assetID = assetID
        self.sharePercent = sharePercent; self.since = since; self.until = until
    }

    public func active(at date: Date) -> Bool {
        since <= date && (until.map { date < $0 } ?? true)
    }
}

/// All clients and who owns what.
public struct ClientBook: Codable, Equatable, Sendable {
    public var version: Int
    public var clients: [Client]
    public var assets: [ClientAsset]

    public static let internalName = "Своё"

    public init(clients: [Client] = [], assets: [ClientAsset] = []) {
        self.version = 1; self.clients = clients; self.assets = assets
    }

    public var internalClient: Client? { clients.first { $0.isInternal } }

    /// Adds «Своё» when there is none; true when the book changed.
    @discardableResult
    public mutating func ensureInternal(now: Date = Date()) -> Bool {
        guard internalClient == nil else { return false }
        clients.insert(Client(name: Self.internalName, kind: .person, isInternal: true, color: .gray,
                              createdAt: now), at: 0)
        return true
    }

    /// Clients not archived: «Своё» first, then by name.
    public var current: [Client] {
        clients.filter { $0.archivedAt == nil }.sorted {
            if $0.isInternal != $1.isInternal { return $0.isInternal }
            return $0.name.lowercased() < $1.name.lowercased()
        }
    }

    public func client(_ id: String) -> Client? { clients.first { $0.id == id } }

    /// Rows assigning this object on `date`, in book order.
    public func rows(_ type: AssetType, _ id: String, at date: Date = Date()) -> [ClientAsset] {
        assets.filter { $0.type == type && $0.assetID == id && $0.active(at: date) && isLive($0.clientID) }
    }

    /// Who a site belongs to; «Своё» when nobody was assigned.
    public func owners(site id: String, at date: Date = Date()) -> [String] {
        orInternal(unique(rows(.site, id, at: date).map(\.clientID)))
    }

    /// Who a server serves: its own rows plus the owners of the sites running
    /// on it (`hosting`: site id -> server id), so a client's site makes the
    /// server shared without assigning it by hand. «Своё» when nobody.
    public func owners(server id: String, hosting: [String: String] = [:], at date: Date = Date()) -> [String] {
        let own = rows(.server, id, at: date).map(\.clientID)
        let hosted = hosting.filter { $0.value == id }.keys.sorted()
            .flatMap { rows(.site, $0, at: date).map(\.clientID) }
        return orInternal(unique(own + hosted))
    }

    /// Who a VPN key belongs to; «Своё» when nobody. Keys are not inherited
    /// from their server: a VPN server usually carries everybody's keys.
    public func owners(vpnKey publicKey: String, at date: Date = Date()) -> [String] {
        orInternal(unique(rows(.vpnKey, publicKey, at: date).map(\.clientID)))
    }

    /// Each owner's percent of a server's cost. Given shares are kept (capped
    /// so they never pass 100), the rest is split equally among owners with
    /// no share; the result sums to 100.
    public func shares(server id: String, hosting: [String: String] = [:], at date: Date = Date()) -> [String: Double] {
        let owners = owners(server: id, hosting: hosting, at: date)
        let given = Dictionary(rows(.server, id, at: date).compactMap { r in r.sharePercent.map { (r.clientID, max(0, $0)) } },
                               uniquingKeysWith: { a, _ in a })
        var out: [String: Double] = [:]
        var used = 0.0
        for o in owners {
            if let g = given[o] {
                let v = min(g, 100 - used)
                out[o] = v
                used += v
            }
        }
        let rest = owners.filter { given[$0] == nil }
        if rest.isEmpty {
            // Shares that do not add up to 100 are scaled to fill it.
            if used > 0, used != 100 { for (k, v) in out { out[k] = v * 100 / used } }
        } else {
            for o in rest { out[o] = (100 - used) / Double(rest.count) }
        }
        return out
    }

    /// Objects of a client on `date`, explicit rows only.
    public func assets(of clientID: String, at date: Date = Date()) -> [ClientAsset] {
        assets.filter { $0.clientID == clientID && $0.active(at: date) }
    }

    /// Makes `owners` (client id -> share or nil) the object's owners from
    /// `now` on. Rows that stay unchanged are kept; the others are closed at
    /// `now`, not deleted, so past reports stay right. An empty map leaves the
    /// object to «Своё».
    public mutating func setOwners(_ type: AssetType, _ id: String, _ owners: [String: Double?], now: Date = Date()) {
        var keep: Set<String> = []
        for i in assets.indices where assets[i].type == type && assets[i].assetID == id && assets[i].active(at: now) {
            let c = assets[i].clientID
            if let wanted = owners[c], wanted == assets[i].sharePercent, !keep.contains(c) {
                keep.insert(c)
            } else if assets[i].since >= now {
                assets[i].until = assets[i].since   // opened and closed at once: drop below
            } else {
                assets[i].until = now
            }
        }
        assets.removeAll { $0.until != nil && $0.until == $0.since }
        for (c, share) in owners.sorted(by: { $0.key < $1.key }) where !keep.contains(c) {
            assets.append(ClientAsset(clientID: c, type: type, assetID: id, sharePercent: share, since: now))
        }
    }

    /// Adds one owner to an object, keeping the others.
    public mutating func addOwner(_ clientID: String, _ type: AssetType, _ id: String, now: Date = Date()) {
        var map: [String: Double?] = [:]
        for r in rows(type, id, at: now) { map[r.clientID] = r.sharePercent }
        guard map[clientID] == nil else { return }
        map[clientID] = .some(nil)
        setOwners(type, id, map, now: now)
    }

    /// Removes one owner from an object, keeping the others.
    public mutating func removeOwner(_ clientID: String, _ type: AssetType, _ id: String, now: Date = Date()) {
        var map: [String: Double?] = [:]
        for r in rows(type, id, at: now) where r.clientID != clientID { map[r.clientID] = r.sharePercent }
        setOwners(type, id, map, now: now)
    }

    public mutating func upsert(_ client: Client) {
        if let i = clients.firstIndex(where: { $0.id == client.id }) { clients[i] = client } else { clients.append(client) }
    }

    /// Archives a client and ends its assignments; «Своё» stays.
    public mutating func archive(_ id: String, now: Date = Date()) {
        guard let i = clients.firstIndex(where: { $0.id == id }), !clients[i].isInternal else { return }
        clients[i].archivedAt = now
        for j in assets.indices where assets[j].clientID == id && assets[j].active(at: now) {
            assets[j].until = now
        }
    }

    /// A client's part of the servers' monthly cost, per currency.
    public func costShare(of clientID: String, servers: [ServerConfig], hosting: [String: String] = [:],
                          at date: Date = Date()) -> [String: Double] {
        var out: [String: Double] = [:]
        for s in servers {
            guard let cost = s.cost, let p = shares(server: s.id, hosting: hosting, at: date)[clientID] else { continue }
            out[cost.currency, default: 0] += cost.monthly * p / 100
        }
        return out
    }

    private func isLive(_ clientID: String) -> Bool { client(clientID)?.archivedAt == nil }

    private func orInternal(_ ids: [String]) -> [String] {
        if !ids.isEmpty { return ids }
        return internalClient.map { [$0.id] } ?? []
    }

    private func unique(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        return ids.filter { seen.insert($0).inserted }
    }
}

/// Reads and writes clients.json in the data folder (owner-only, like
/// servers.json). Contacts are personal data: the file never leaves the Mac
/// except in the encrypted transfer file.
public struct ClientsRepository: Sendable {
    public let url: URL

    public init(url: URL = DataFolder.clientsFile) { self.url = url }

    /// A missing file is a book with «Своё» only. When «Своё» has to be made,
    /// the book is saved at once, so its id stays the same between launches.
    public func load() throws -> ClientBook {
        var book: ClientBook
        if FileManager.default.fileExists(atPath: url.path) {
            book = try Self.decode(Data(contentsOf: url))
        } else {
            book = ClientBook()
        }
        if book.ensureInternal() { try save(book) }
        return book
    }

    public func save(_ book: ClientBook) throws {
        let data = try Self.encode(book)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func encode(_ book: ClientBook) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return try e.encode(book)
    }

    public static func decode(_ data: Data) throws -> ClientBook {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(ClientBook.self, from: data)
    }
}
