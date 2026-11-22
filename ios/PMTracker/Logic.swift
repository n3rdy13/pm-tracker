import Foundation

// Pure logic: dates, status, sorting, distance, route optimisation and Google Maps links.
// Ported from the web app's logic.js.

let cycleMonths = 6
let maxRouteStops = 9          // one Google Maps route
let roadFactor = 1.25          // straight-line miles -> rough road miles, estimates only

// MARK: - Dates (local YYYY-MM-DD strings)

enum Day {
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }

    static func string(_ d: Date = Date()) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 2000, c.month ?? 1, c.day ?? 1)
    }

    static var today: String { string() }

    static func parts(_ s: String) -> (Int, Int, Int)? {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return (p[0], p[1], p[2])
    }

    static func date(_ s: String) -> Date? {
        guard let p = parts(s) else { return nil }
        return calendar.date(from: DateComponents(year: p.0, month: p.1, day: p.2, hour: 12))
    }

    /// Adds calendar months, clamping to the end of the month (Aug 31 + 6 -> Feb 28/29).
    static func addMonths(_ s: String, _ n: Int) -> String {
        guard let d = date(s), let r = calendar.date(byAdding: .month, value: n, to: d) else { return s }
        return string(r)
    }

    static func addDays(_ s: String, _ n: Int) -> String {
        guard let d = date(s), let r = calendar.date(byAdding: .day, value: n, to: d) else { return s }
        return string(r)
    }

    /// b - a in whole days.
    static func between(_ a: String, _ b: String) -> Int {
        guard let pa = parts(a), let pb = parts(b) else { return 0 }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard let da = utc.date(from: DateComponents(year: pa.0, month: pa.1, day: pa.2)),
              let db = utc.date(from: DateComponents(year: pb.0, month: pb.1, day: pb.2)) else { return 0 }
        return Int((db.timeIntervalSince(da) / 86400).rounded())
    }

    static func pretty(_ s: String?) -> String {
        guard let s, let d = date(s) else { return "—" }
        return d.formatted(.dateTime.month(.abbreviated).day().year())
    }

    static func spoken(_ s: String?) -> String {
        guard let s, let d = date(s) else { return "unknown" }
        return d.formatted(.dateTime.month(.wide).day().year())
    }
}

// MARK: - Status

enum PMStatus: Int, CaseIterable, Identifiable {
    case overdue = 0, never, soon, current

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .overdue: return "Overdue"
        case .never: return "Never visited"
        case .soon: return "Due soon"
        case .current: return "Current"
        }
    }

    var needsVisit: Bool { self != .current }
}

struct StatusInfo {
    let status: PMStatus
    let last: String?
    let due: String?
    let daysToDue: Int?

    var text: String {
        switch status {
        case .never: return "Never visited"
        case .overdue: return "\(-(daysToDue ?? 0)) d overdue"
        case .soon: return daysToDue == 0 ? "Due today" : "Due in \(daysToDue ?? 0) d"
        case .current: return "Due \(Day.pretty(due))"
        }
    }

    var spoken: String {
        switch status {
        case .never: return "never visited"
        case .overdue:
            let d = -(daysToDue ?? 0)
            return "overdue by \(d) day\(d == 1 ? "" : "s")"
        case .soon:
            let d = daysToDue ?? 0
            return d == 0 ? "due today" : "due in \(d) day\(d == 1 ? "" : "s")"
        case .current: return "current, next due \(Day.spoken(due))"
        }
    }
}

func computeStatus(_ r: Retailer, today: String, soonDays: Int) -> StatusInfo {
    guard let last = r.lastVisit else { return StatusInfo(status: .never, last: nil, due: nil, daysToDue: nil) }
    let due = Day.addMonths(last, cycleMonths)
    let days = Day.between(today, due)
    let status: PMStatus = days < 0 ? .overdue : (days <= soonDays ? .soon : .current)
    return StatusInfo(status: status, last: last, due: due, daysToDue: days)
}

// MARK: - Distance

func haversineMi(_ a: Coord, _ b: Coord) -> Double {
    let r = 3958.8, rad = Double.pi / 180
    let dLat = (b.lat - a.lat) * rad, dLng = (b.lng - a.lng) * rad
    let x = pow(sin(dLat / 2), 2) + cos(a.lat * rad) * cos(b.lat * rad) * pow(sin(dLng / 2), 2)
    return 2 * r * asin(min(1, sqrt(x)))
}

func milesText(_ d: Double?) -> String {
    guard let d, d.isFinite else { return "" }
    return d < 10 ? String(format: "%.1f mi", d) : "\(Int(d.rounded())) mi"
}

func milesSpoken(_ d: Double) -> String {
    if d < 0.1 { return "right here" }
    if d < 10 { return String(format: "%.1f miles away", d) }
    return "\(Int(d.rounded())) miles away"
}

/// A retailer together with its status and distance, used for lists.
struct Item: Identifiable {
    let r: Retailer
    let s: StatusInfo
    var d: Double?
    var id: String { r.id }
}

/// Overdue (most overdue first) -> Never visited -> Due soon -> Current; ties by distance, then city/name.
func sortByImportance(_ items: [Item]) -> [Item] {
    items.sorted { a, b in
        if a.s.status != b.s.status { return a.s.status.rawValue < b.s.status.rawValue }
        if a.s.status != .never, let x = a.s.daysToDue, let y = b.s.daysToDue, x != y { return x < y }
        let da = a.d ?? .infinity, db = b.d ?? .infinity
        if da != db { return da < db }
        return (a.r.city + a.r.name) < (b.r.city + b.r.name)
    }
}

// MARK: - Route optimisation

private func pathLength(_ order: [Int], _ pts: [Coord], _ start: Coord, _ end: Coord?) -> Double {
    var d = 0.0, prev = start
    for i in order { d += haversineMi(prev, pts[i]); prev = pts[i] }
    if let end { d += haversineMi(prev, end) }
    return d
}

private func heldKarp(_ pts: [Coord], _ start: Coord, _ end: Coord?) -> [Int] {
    let n = pts.count, full = (1 << n) - 1
    var dp = [Double](repeating: .infinity, count: (1 << n) * n)
    var parent = [Int](repeating: -1, count: (1 << n) * n)
    var dist = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
    for i in 0..<n { for j in 0..<n { dist[i][j] = haversineMi(pts[i], pts[j]) } }
    for i in 0..<n { dp[(1 << i) * n + i] = haversineMi(start, pts[i]) }
    for mask in 1...full {
        for i in 0..<n where mask & (1 << i) != 0 {
            let cur = dp[mask * n + i]
            if cur == .infinity { continue }
            for j in 0..<n where mask & (1 << j) == 0 {
                let next = mask | (1 << j), v = cur + dist[i][j]
                if v < dp[next * n + j] { dp[next * n + j] = v; parent[next * n + j] = i }
            }
        }
    }
    var best = Double.infinity, last = 0
    for i in 0..<n {
        let v = dp[full * n + i] + (end.map { haversineMi(pts[i], $0) } ?? 0)
        if v < best { best = v; last = i }
    }
    var order: [Int] = [], mask = full, i = last
    while i != -1 {
        order.append(i)
        let p = parent[mask * n + i]
        mask &= ~(1 << i)
        i = p
    }
    return order.reversed()
}

private func twoOpt(_ seed: [Int], _ pts: [Coord], _ start: Coord, _ end: Coord?) -> [Int] {
    var best = seed, bestLen = pathLength(best, pts, start, end), improved = true, guardCount = 0
    while improved && guardCount < 200 {
        guardCount += 1
        improved = false
        for i in 0..<max(0, best.count - 1) {
            for k in (i + 1)..<best.count {
                var cand = best
                cand.replaceSubrange(i...k, with: best[i...k].reversed())
                let len = pathLength(cand, pts, start, end)
                if len + 1e-9 < bestLen { best = cand; bestLen = len; improved = true }
            }
        }
    }
    return best
}

/// Returns the visiting order (indices into pts) with the shortest straight-line distance.
func optimizeOrder(_ pts: [Coord], start: Coord, end: Coord? = nil) -> [Int] {
    let n = pts.count
    if n <= 1 { return Array(0..<n) }
    if n <= 12 { return heldKarp(pts, start, end) }
    var left = Set(0..<n), order: [Int] = [], cur = start
    while !left.isEmpty {
        let next = left.min { haversineMi(cur, pts[$0]) < haversineMi(cur, pts[$1]) }!
        order.append(next)
        left.remove(next)
        cur = pts[next]
    }
    return twoOpt(order, pts, start, end)
}

/// Picks stores by chaining nearest-next from the start. Overdue stores count as 30% closer.
func autoPick(_ candidates: [Item], start: Coord, count: Int, maxMiles: Double = 75) -> [Item] {
    var pool = candidates.filter { $0.r.coord.map { haversineMi(start, $0) <= maxMiles } ?? false }
    var chosen: [Item] = [], cur = start
    while chosen.count < count && !pool.isEmpty {
        var bestIndex = 0, bestScore = Double.infinity
        for (i, c) in pool.enumerated() {
            guard let p = c.r.coord else { continue }
            let w = c.s.status == .overdue ? 0.7 : (c.s.status == .soon ? 1.3 : 1.0)
            let score = haversineMi(cur, p) * w
            if score < bestScore { bestScore = score; bestIndex = i }
        }
        let c = pool.remove(at: bestIndex)
        chosen.append(c)
        cur = c.r.coord ?? cur
    }
    return chosen
}

// MARK: - Google Maps

enum RouteStop {
    case retailer(Retailer)
    case point(Coord, String)

    var mapsQuery: String {
        switch self {
        case .retailer(let r):
            // A pin the user set by hand is more reliable than the street address.
            if r.geoKind == .manual, let c = r.coord { return "\(c.lat),\(c.lng)" }
            return r.fullAddress
        case .point(let c, _):
            return "\(c.lat),\(c.lng)"
        }
    }

    var name: String {
        switch self {
        case .retailer(let r): return r.name
        case .point(_, let label): return label
        }
    }
}

enum GoogleMaps {
    private static let allowed: CharacterSet = {
        var s = CharacterSet.alphanumerics
        s.insert(charactersIn: "-._~,")
        return s
    }()

    private static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// Google Maps app link. Starts from wherever you are.
    static func appURL(_ stops: [RouteStop]) -> URL? {
        guard !stops.isEmpty else { return nil }
        let daddr = stops.map { enc($0.mapsQuery) }.joined(separator: "+to:")
        return URL(string: "comgooglemaps://?daddr=\(daddr)&directionsmode=driving")
    }

    /// google.com/maps link (opens the Google Maps app when it's installed).
    static func webURL(_ stops: [RouteStop], navigate: Bool) -> URL? {
        guard let dest = stops.last else { return nil }
        var q = "api=1&travelmode=driving&destination=\(enc(dest.mapsQuery))"
        let way = stops.dropLast()
        if !way.isEmpty { q += "&waypoints=" + way.map { enc($0.mapsQuery) }.joined(separator: "%7C") }
        if navigate { q += "&dir_action=navigate" }
        return URL(string: "https://www.google.com/maps/dir/?" + q)
    }

    static func url(_ stops: [RouteStop], mode: String, navigate: Bool) -> URL? {
        mode == "web" ? webURL(stops, navigate: navigate) : appURL(stops)
    }
}

// MARK: - Coordinates from pasted text

func parseCoords(_ text: String) -> Coord? {
    let patterns = [#"@(-?\d+\.\d+),\s*(-?\d+\.\d+)"#, #"(-?\d{1,2}\.\d+)\s*,\s*(-?\d{1,3}\.\d+)"#]
    for p in patterns {
        guard let re = try? NSRegularExpression(pattern: p) else { continue }
        let ns = text as NSString
        if let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges >= 3,
           let lat = Double(ns.substring(with: m.range(at: 1))), let lng = Double(ns.substring(with: m.range(at: 2))),
           abs(lat) <= 90, abs(lng) <= 180 {
            return Coord(lat: lat, lng: lng)
        }
    }
    return nil
}

// MARK: - Spoken retailer numbers

/// Turns what Siri heard ("one two three 45", "12,345") into digits.
func digitsFromSpeech(_ text: String) -> String {
    let words: [String: String] = [
        "zero": "0", "oh": "0", "o": "0", "one": "1", "won": "1", "two": "2", "to": "2", "too": "2",
        "three": "3", "four": "4", "for": "4", "five": "5", "six": "6", "seven": "7", "eight": "8",
        "ate": "8", "nine": "9",
    ]
    var out = ""
    for token in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
        let t = String(token)
        if let d = words[t] { out += d } else { out += t.filter(\.isNumber) }
    }
    return out
}

func spacedDigits(_ s: String) -> String {
    s.map(String.init).joined(separator: " ")
}
