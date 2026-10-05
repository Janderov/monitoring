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
        .init(code: "CA", name: "Канада", city: "Торонто", lat: 43.65, lon: -79.38),
        .init(code: "LT", name: "Литва", city: "Вильнюс", lat: 54.69, lon: 25.28),
        .init(code: "LV", name: "Латвия", city: "Рига", lat: 56.95, lon: 24.11),
        .init(code: "EE", name: "Эстония", city: "Таллин", lat: 59.44, lon: 24.75),
        .init(code: "CH", name: "Швейцария", city: "Цюрих", lat: 47.37, lon: 8.54),
        .init(code: "AT", name: "Австрия", city: "Вена", lat: 48.21, lon: 16.37),
        .init(code: "IT", name: "Италия", city: "Милан", lat: 45.46, lon: 9.19),
        .init(code: "ES", name: "Испания", city: "Мадрид", lat: 40.42, lon: -3.70),
        .init(code: "IE", name: "Ирландия", city: "Дублин", lat: 53.35, lon: -6.26),
        .init(code: "CZ", name: "Чехия", city: "Прага", lat: 50.08, lon: 14.44),
        .init(code: "BG", name: "Болгария", city: "София", lat: 42.70, lon: 23.32),
        .init(code: "RO", name: "Румыния", city: "Бухарест", lat: 44.43, lon: 26.10),
        .init(code: "HU", name: "Венгрия", city: "Будапешт", lat: 47.50, lon: 19.04),
        .init(code: "RS", name: "Сербия", city: "Белград", lat: 44.79, lon: 20.45),
        .init(code: "UA", name: "Украина", city: "Киев", lat: 50.45, lon: 30.52),
        .init(code: "GE", name: "Грузия", city: "Тбилиси", lat: 41.72, lon: 44.79),
        .init(code: "AM", name: "Армения", city: "Ереван", lat: 40.18, lon: 44.51),
        .init(code: "HK", name: "Гонконг", city: "Гонконг", lat: 22.32, lon: 114.17),
        .init(code: "IN", name: "Индия", city: "Мумбаи", lat: 19.08, lon: 72.88),
        .init(code: "BR", name: "Бразилия", city: "Сан-Паулу", lat: -23.55, lon: -46.63),
        .init(code: "AU", name: "Австралия", city: "Сидней", lat: -33.87, lon: 151.21),
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
