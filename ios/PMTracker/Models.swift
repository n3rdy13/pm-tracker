import Foundation
import CoreLocation

// The data format matches the web app's backup file, so a backup from either app restores in the other.

struct Coord: Codable, Equatable, Hashable {
    var lat: Double
    var lng: Double

    var cl: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lng) }

    init(lat: Double, lng: Double) {
        self.lat = lat
        self.lng = lng
    }

    init(_ location: CLLocation) {
        self.lat = location.coordinate.latitude
        self.lng = location.coordinate.longitude
    }
}

/// Decodes a value that may have been saved as either a string or a number.
private func flexibleString<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> String? {
    if let s = try? c.decodeIfPresent(String.self, forKey: key) { return s }
    if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return String(i) }
    if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return String(Int(d)) }
    return nil
}

extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        let found: T? = try? decodeIfPresent(T.self, forKey: key)
        return found ?? fallback
    }

    func optional<T: Decodable>(_ key: Key, _ type: T.Type) -> T? {
        let found: T? = try? decodeIfPresent(T.self, forKey: key)
        return found
    }
}

struct Visit: Codable, Identifiable, Hashable {
    var id: String
    var date: String      // local YYYY-MM-DD
    var note: String
    var at: String?

    enum CodingKeys: String, CodingKey { case id, date, note, at }

    init(id: String = Visit.newID(), date: String, note: String, at: String? = ISO.now()) {
        self.id = id
        self.date = date
        self.note = note
        self.at = at
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = flexibleString(c, .id) ?? Visit.newID()
        date = c.value(.date, "")
        note = c.value(.note, "")
        at = c.optional(.at, String.self)
    }

    static func newID() -> String {
        String(Int(Date().timeIntervalSince1970 * 1000), radix: 36) + String(Int.random(in: 0..<1_679_616), radix: 36)
    }
}

enum Geo: String {
    case exact, approx, manual, none

    var label: String {
        switch self {
        case .exact: return "Address match"
        case .approx: return "Approximate (town center)"
        case .manual: return "Set by you"
        case .none: return "Missing"
        }
    }
}

struct Retailer: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var address: String
    var city: String
    var state: String
    var tab: String
    var visits: [Visit]
    var notes: String
    var lat: Double?
    var lng: Double?
    var geo: String
    var archived: Bool
    var addedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, address, city, state, tab, visits, notes, lat, lng, geo, archived, addedAt
    }

    init(id: String, name: String, address: String, city: String, tab: String) {
        self.id = id
        self.name = name
        self.address = address
        self.city = city
        self.state = "MO"
        self.tab = tab
        self.visits = []
        self.notes = ""
        self.lat = nil
        self.lng = nil
        self.geo = Geo.none.rawValue
        self.archived = false
        self.addedAt = ISO.now()
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = flexibleString(c, .id) ?? ""
        name = c.value(.name, "")
        address = c.value(.address, "")
        city = c.value(.city, "")
        state = c.value(.state, "MO")
        tab = flexibleString(c, .tab) ?? ""
        visits = c.value(.visits, [Visit]())
        notes = c.value(.notes, "")
        lat = c.optional(.lat, Double.self)
        lng = c.optional(.lng, Double.self)
        geo = c.value(.geo, lat != nil && lng != nil ? "approx" : "none")
        archived = c.value(.archived, false)
        addedAt = c.optional(.addedAt, String.self)
    }

    var coord: Coord? {
        guard let lat, let lng else { return nil }
        return Coord(lat: lat, lng: lng)
    }

    var geoKind: Geo { Geo(rawValue: geo) ?? .none }
    var hasWeakLocation: Bool { geoKind != .exact && geoKind != .manual }

    var lastVisit: String? { visits.map(\.date).max() }

    var fullAddress: String {
        [address, city, state.isEmpty ? "MO" : state].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

struct RouteState: Codable {
    var stops: [String] = []
    var end: String = "last"          // last | start | home
    var builtAt: String?
    var start: Coord?

    enum CodingKeys: String, CodingKey { case stops, end, builtAt, start }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stops = c.value(.stops, [String]())
        end = c.value(.end, "last")
        builtAt = c.optional(.builtAt, String.self)
        start = c.optional(.start, Coord.self)
    }
}

struct AppSettings: Codable {
    var soonDays: Int = 30
    var autoLocate: Bool = true
    var home: Coord?
    var leadDays: Int = 14
    var mapsMode: String = "app"      // app = Google Maps app, web = google.com link
    var nearRadius: Double = 25
    var routeStops: Int = 5

    enum CodingKeys: String, CodingKey { case soonDays, autoLocate, home, leadDays, mapsMode, nearRadius, routeStops }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        soonDays = c.value(.soonDays, 30)
        autoLocate = c.value(.autoLocate, true)
        home = c.optional(.home, Coord.self)
        leadDays = c.value(.leadDays, 14)
        mapsMode = c.value(.mapsMode, "app")
        nearRadius = c.value(.nearRadius, 25.0)
        routeStops = min(9, max(1, c.value(.routeStops, 5)))
    }
}

struct Meta: Codable {
    var createdAt: String? = ISO.now()
    var lastBackupAt: String?
    var changesSinceBackup: Int = 0

    enum CodingKeys: String, CodingKey { case createdAt, lastBackupAt, changesSinceBackup }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        createdAt = c.optional(.createdAt, String.self)
        lastBackupAt = c.optional(.lastBackupAt, String.self)
        changesSinceBackup = c.value(.changesSinceBackup, 0)
    }
}

struct AppState: Codable {
    var schema: Int = 1
    var retailers: [String: Retailer] = [:]
    var route = RouteState()
    var settings = AppSettings()
    var meta = Meta()

    enum CodingKeys: String, CodingKey { case schema, retailers, route, settings, meta }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = c.value(.schema, 1)
        let raw = try c.decode([String: Retailer].self, forKey: .retailers)
        var fixed: [String: Retailer] = [:]
        for (key, var r) in raw {
            if r.id.isEmpty { r.id = key }
            fixed[r.id] = r
        }
        retailers = fixed
        route = c.value(.route, RouteState())
        settings = c.value(.settings, AppSettings())
        meta = c.value(.meta, Meta())
    }
}

struct Backup: Codable {
    var type: String = "pm-tracker-backup"
    var version: Int = 1
    var appVersion: String?
    var exportedAt: String?
    var state: AppState
}

struct RetailerList: Decodable {
    var type: String
    var retailers: [Retailer]
}

enum ISO {
    static func now() -> String { ISO8601DateFormatter().string(from: Date()) }
    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s)
    }
}
