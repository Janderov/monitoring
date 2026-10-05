#if canImport(SwiftUI) && canImport(AppKit)
import CoreLocation
import Foundation
import MonitorCore

/// Country of a server, guessed from its group or tags ("NL", "Нидерланды",
/// "nl-ams"...). Used for grouping and as the default place on the map.
public struct Country: Hashable, Sendable {
    public var code: String
    public var name: String
    /// A reasonable default pin: the usual data-center city.
    public var city: String
    public var lat: Double
    public var lon: Double

    public var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }

    static let known: [Country] = [
        .init(code: "RU", name: "Россия", city: "Москва", lat: 55.75, lon: 37.62),
        .init(code: "NL", name: "Нидерланды", city: "Амстердам", lat: 52.37, lon: 4.90),
        .init(code: "US", name: "США", city: "Нью-Джерси", lat: 40.73, lon: -74.17),
        .init(code: "DE", name: "Германия", city: "Франкфурт", lat: 50.11, lon: 8.68),
        .init(code: "FI", name: "Финляндия", city: "Хельсинки", lat: 60.17, lon: 24.94),
        .init(code: "GB", name: "Великобритания", city: "Лондон", lat: 51.51, lon: -0.13),
        .init(code: "FR", name: "Франция", city: "Париж", lat: 48.86, lon: 2.35),
        .init(code: "PL", name: "Польша", city: "Варшава", lat: 52.23, lon: 21.01),
        .init(code: "SE", name: "Швеция", city: "Стокгольм", lat: 59.33, lon: 18.07),
        .init(code: "TR", name: "Турция", city: "Стамбул", lat: 41.01, lon: 28.98),
        .init(code: "KZ", name: "Казахстан", city: "Алматы", lat: 43.24, lon: 76.89),
        .init(code: "AE", name: "ОАЭ", city: "Дубай", lat: 25.20, lon: 55.27),
        .init(code: "SG", name: "Сингапур", city: "Сингапур", lat: 1.35, lon: 103.82),
        .init(code: "JP", name: "Япония", city: "Токио", lat: 35.68, lon: 139.69),
    ]

    private static let aliases: [String: String] = [
        "russia": "RU", "россия": "RU", "рф": "RU", "moscow": "RU", "москва": "RU",
        "netherlands": "NL", "нидерланды": "NL", "голландия": "NL", "amsterdam": "NL", "амстердам": "NL",
        "usa": "US", "сша": "US", "america": "US", "германия": "DE", "germany": "DE",
        "финляндия": "FI", "finland": "FI",
    ]

    static func detect(_ server: ServerConfig) -> Country? {
        let words = ([server.group] + (server.tags ?? []).map { Optional($0) })
            .compactMap { $0 }
            .flatMap { $0.lowercased().split(whereSeparator: { !$0.isLetter }) }
            .map(String.init)
        for w in words {
            let code = aliases[w] ?? w.uppercased()
            if let c = known.first(where: { $0.code == code }) { return c }
        }
        return nil
    }
}

/// Where each server sits on the map. Defaults to its country's city; the
/// user can move a pin, and the choice is kept in UserDefaults by server id.
@MainActor
public final class ServerLocations: ObservableObject {
    @Published private var overrides: [String: [Double]]
    private let key = "serverLocations"

    init() {
        overrides = UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] ?? [:]
    }

    public func coordinate(for server: ServerConfig) -> CLLocationCoordinate2D? {
        if let p = overrides[server.id], p.count == 2 { return .init(latitude: p[0], longitude: p[1]) }
        return Country.detect(server)?.coordinate
    }

    /// A place the user chose by hand, for pins that are not servers.
    public func manual(_ id: String) -> CLLocationCoordinate2D? {
        guard let p = overrides[id], p.count == 2 else { return nil }
        return .init(latitude: p[0], longitude: p[1])
    }

    /// Nil goes back to the country's default place.
    public func set(_ c: CLLocationCoordinate2D?, for serverID: String) {
        overrides[serverID] = c.map { [$0.latitude, $0.longitude] }
        UserDefaults.standard.set(overrides, forKey: key)
    }
}
#endif
