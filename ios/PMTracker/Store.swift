import CoreLocation
import Foundation
import SwiftUI
import UIKit
import UserNotifications

struct Toast: Identifiable {
    let id = UUID()
    let message: String
    let undo: (() -> Void)?
}

enum ImportedFile {
    case backup(Backup)
    case list([Retailer])
}

enum ImportError: LocalizedError {
    case unrecognized, empty
    var errorDescription: String? {
        switch self {
        case .unrecognized: return "That file isn't a PM Tracker backup or retailer list."
        case .empty: return "The file is empty."
        }
    }
}

/// All app data, saved as one JSON file on the phone. Shared by the app and the Siri commands.
@MainActor
final class Store: ObservableObject {
    static let shared = Store()
    static let appVersion = "2.0.1"

    @Published private(set) var state = AppState()
    @Published private(set) var here: Coord?
    @Published private(set) var hereAccuracy: Double?
    @Published private(set) var hereTime: Date?
    @Published private(set) var locating = false
    @Published var toast: Toast?
    @Published var pendingBackup: Backup?
    @Published var alertMessage: String?

    private let fileURL: URL
    private var reminderTask: Task<Void, Never>?

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("pm-tracker-state.json")
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(AppState.self, from: data) {
            state = saved
        }
    }

    // MARK: Saving

    private func commit(changed: Bool = true) {
        if changed { state.meta.changesSinceBackup += 1 }
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            show("Couldn't save: \(error.localizedDescription)")
        }
        scheduleReminders()
    }

    func show(_ message: String, undo: (() -> Void)? = nil) {
        toast = Toast(message: message, undo: undo)
    }

    // MARK: Reading

    var today: String { Day.today }
    var hasData: Bool { !state.retailers.isEmpty }
    var settings: AppSettings { state.settings }
    var active: [Retailer] { state.retailers.values.filter { !$0.archived } }
    var archived: [Retailer] { state.retailers.values.filter(\.archived).sorted { $0.name < $1.name } }
    var reference: Coord? { here ?? state.settings.home }

    func retailer(_ id: String) -> Retailer? { state.retailers[id] }
    func status(_ r: Retailer) -> StatusInfo { computeStatus(r, today: today, soonDays: state.settings.soonDays) }
    func doneToday(_ r: Retailer) -> Bool { r.lastVisit == today }

    func items(from origin: Coord?) -> [Item] {
        active.map { r in
            var d: Double?
            if let o = origin, let c = r.coord { d = haversineMi(o, c) }
            return Item(r: r, s: status(r), d: d)
        }
    }

    /// Stores sorted by distance from `point`, within `radius` miles.
    func nearby(to point: Coord, radius: Double, needOnly: Bool) -> [Item] {
        items(from: point)
            .filter { $0.d != nil && $0.d! <= radius }
            .filter { !needOnly || ($0.s.status.needsVisit && !doneToday($0.r)) }
            .sorted { ($0.d ?? .infinity) < ($1.d ?? .infinity) }
    }

    func nearest(to point: Coord) -> Item? {
        items(from: point).filter { $0.d != nil }.min { $0.d! < $1.d! }
    }

    func find(number: String) -> Retailer? {
        let digits = digitsFromSpeech(number)
        guard !digits.isEmpty else { return nil }
        if let r = state.retailers[digits] { return r }
        let trimmed = String(digits.drop { $0 == "0" })
        return state.retailers.values.first { String($0.id.drop { $0 == "0" }) == trimmed }
    }

    var counts: [PMStatus: Int] {
        var c: [PMStatus: Int] = [:]
        for r in active { c[status(r).status, default: 0] += 1 }
        return c
    }

    var badgeCount: Int {
        active.filter { r in
            let s = status(r)
            return s.status == .overdue || (s.status == .soon && (s.daysToDue ?? 99) <= 7)
        }.count
    }

    /// Median position of address-matched stores in the same town.
    func townCenter(_ city: String) -> Coord? {
        let c = city.uppercased()
        let pts = state.retailers.values.filter {
            $0.city.uppercased() == c && ($0.geoKind == .exact || $0.geoKind == .manual)
        }.compactMap(\.coord)
        guard !pts.isEmpty else { return nil }
        let lats = pts.map(\.lat).sorted(), lngs = pts.map(\.lng).sorted()
        return Coord(lat: lats[lats.count / 2], lng: lngs[lngs.count / 2])
    }

    // MARK: Location

    @discardableResult
    func locate(fresh: Bool = true, quiet: Bool = false) async -> Coord? {
        locating = true
        defer { locating = false }
        do {
            let l = try await LocationProvider.shared.current(maxAge: fresh ? 15 : 120)
            setHere(l)
            return Coord(l)
        } catch {
            if !quiet { show(error.localizedDescription) }
            return nil
        }
    }

    func setHere(_ l: CLLocation) {
        here = Coord(l)
        hereAccuracy = l.horizontalAccuracy
        hereTime = Date()
    }

    // MARK: Retailer changes

    /// Records a visit. Returns the retailer as it was before, for undo.
    @discardableResult
    func markDone(_ id: String, date: String? = nil, note: String = "", location: Coord? = nil) -> Retailer? {
        guard var r = state.retailers[id] else { return nil }
        let before = r
        r.visits.append(Visit(date: date ?? today, note: note))
        if let location {
            r.lat = location.lat
            r.lng = location.lng
            r.geo = Geo.manual.rawValue
        }
        state.retailers[id] = r
        commit()
        return before
    }

    func nextDue(_ id: String) -> String? {
        guard let last = state.retailers[id]?.lastVisit else { return nil }
        return Day.addMonths(last, cycleMonths)
    }

    /// Replaces a retailer (used by undo and edits).
    func put(_ r: Retailer) {
        state.retailers[r.id] = r
        commit()
    }

    func deleteVisit(_ rid: String, _ vid: String) {
        state.retailers[rid]?.visits.removeAll { $0.id == vid }
        commit()
    }

    func setNotes(_ id: String, _ notes: String) {
        guard state.retailers[id]?.notes != notes else { return }
        state.retailers[id]?.notes = notes
        commit()
    }

    func setLocation(_ id: String, _ c: Coord, geo: Geo) {
        guard var r = state.retailers[id] else { return }
        r.lat = c.lat
        r.lng = c.lng
        r.geo = geo.rawValue
        put(r)
    }

    func updateDetails(_ id: String, name: String, address: String, city: String, tab: String) {
        guard var r = state.retailers[id] else { return }
        let city = city.uppercased()
        let moved = address != r.address || city != r.city
        r.name = name.isEmpty ? r.name : name
        r.address = address
        r.city = city
        r.tab = tab
        if moved && r.geoKind != .manual {
            if let tc = townCenter(city) {
                r.lat = tc.lat; r.lng = tc.lng; r.geo = Geo.approx.rawValue
            } else {
                r.lat = nil; r.lng = nil; r.geo = Geo.none.rawValue
            }
        }
        put(r)
    }

    /// Returns an error message, or nil when added.
    func add(_ new: Retailer, location: Coord?) -> String? {
        if let existing = state.retailers[new.id] { return "ID \(new.id) already exists (\(existing.name))" }
        var r = new
        if let location {
            r.lat = location.lat; r.lng = location.lng; r.geo = Geo.manual.rawValue
        } else if let tc = townCenter(r.city) {
            r.lat = tc.lat; r.lng = tc.lng; r.geo = Geo.approx.rawValue
        }
        put(r)
        return nil
    }

    func setArchived(_ id: String, _ value: Bool) {
        state.retailers[id]?.archived = value
        if value { state.route.stops.removeAll { $0 == id } }
        commit()
    }

    // MARK: Route (at most 9 stops — one Google Maps route)

    var routeStops: [Retailer] { state.route.stops.compactMap { state.retailers[$0] } }
    func inRoute(_ id: String) -> Bool { state.route.stops.contains(id) }

    func toggleRoute(_ id: String) {
        if let i = state.route.stops.firstIndex(of: id) {
            state.route.stops.remove(at: i)
        } else if state.route.stops.count >= maxRouteStops {
            show("Route is full. Google Maps takes up to \(maxRouteStops) stops.")
            return
        } else {
            state.route.stops.append(id)
            show("Added to route (\(state.route.stops.count) of \(maxRouteStops))")
        }
        commit(changed: false)
    }

    func removeFromRoute(at offsets: IndexSet) {
        state.route.stops.remove(atOffsets: offsets)
        commit(changed: false)
    }

    func moveRoute(from: IndexSet, to: Int) {
        state.route.stops.move(fromOffsets: from, toOffset: to)
        commit(changed: false)
    }

    func clearRoute() {
        state.route.stops = []
        commit(changed: false)
    }

    func setRouteEnd(_ end: String) {
        state.route.end = end
        if let s = state.route.start { optimizeRoute(start: s) } else { commit(changed: false) }
    }

    var endPoint: Coord? {
        switch state.route.end {
        case "start": return state.route.start
        case "home": return state.settings.home
        default: return nil
        }
    }

    func optimizeRoute(start: Coord) {
        state.route.start = start
        let stops = routeStops
        let withCoords = stops.filter { $0.coord != nil }
        let without = stops.filter { $0.coord == nil }
        let order = optimizeOrder(withCoords.compactMap(\.coord), start: start, end: endPoint)
        state.route.stops = order.map { withCoords[$0].id } + without.map(\.id)
        state.route.builtAt = ISO.now()
        commit(changed: false)
    }

    /// Picks the closest stores that need a visit and orders them. Returns the stops (empty if none found).
    @discardableResult
    func buildRoute(count: Int, start: Coord) -> [Retailer] {
        let n = min(maxRouteStops, max(1, count))
        let candidates = items(from: start).filter { $0.s.status.needsVisit && !doneToday($0.r) }
        let picked = autoPick(candidates, start: start, count: n)
        guard !picked.isEmpty else { return [] }
        state.route.stops = picked.map(\.r.id)
        state.settings.routeStops = n
        optimizeRoute(start: start)
        return routeStops
    }

    func routeSequence(remainingOnly: Bool) -> [RouteStop] {
        var list = routeStops.filter { !remainingOnly || !doneToday($0) }.map { RouteStop.retailer($0) }
        if !list.isEmpty, let e = endPoint {
            list.append(.point(e, state.route.end == "home" ? "Home" : "Back to start"))
        }
        return list
    }

    var routeMiles: Double? {
        guard let start = state.route.start else { return nil }
        var d = 0.0, prev = start
        for r in routeStops { if let c = r.coord { d += haversineMi(prev, c); prev = c } }
        if let e = endPoint { d += haversineMi(prev, e) }
        return d * roadFactor
    }

    /// "app" only works when Google Maps is installed; otherwise use the web link.
    var mapsMode: String {
        if state.settings.mapsMode == "app", let probe = URL(string: "comgooglemaps://"), UIApplication.shared.canOpenURL(probe) {
            return "app"
        }
        return "web"
    }

    /// Google Maps link for the stops not yet done today.
    func routeURL() -> URL? {
        let seq = routeSequence(remainingOnly: true)
        guard !seq.isEmpty else { return nil }
        return GoogleMaps.url(seq, mode: mapsMode, navigate: true)
    }

    func directionsURL(_ r: Retailer) -> URL? {
        GoogleMaps.url([.retailer(r)], mode: mapsMode, navigate: false)
    }

    func open(_ url: URL?) {
        guard let url else { return }
        UIApplication.shared.open(url)
    }

    // MARK: Settings

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        change(&state.settings)
        if state.route.end == "home" && state.settings.home == nil { state.route.end = "last" }
        commit(changed: false)
    }

    // MARK: Backup / import

    func backupData() throws -> Data {
        let b = Backup(appVersion: Store.appVersion, exportedAt: ISO.now(), state: state)
        return try JSONEncoder().encode(b)
    }

    func markBackedUp() {
        state.meta.lastBackupAt = ISO.now()
        state.meta.changesSinceBackup = 0
        commit(changed: false)
    }

    func readImport(_ raw: Data) throws -> ImportedFile {
        var data = raw
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = Data(data.dropFirst(3)) }   // UTF-8 byte-order mark
        guard !data.isEmpty else { throw ImportError.empty }
        struct AnyDecodable: Decodable { init(from decoder: Decoder) throws {} }
        struct Header: Decodable {
            var type: String?
            var state: [String: AnyDecodable]?
            var retailers: [AnyDecodable]?
        }
        let header = try JSONDecoder().decode(Header.self, from: data)
        if header.type == "pm-tracker-backup" || (header.type == nil && header.state != nil) {
            return .backup(try JSONDecoder().decode(Backup.self, from: data))
        }
        if header.type == "pm-tracker-retailers" || (header.type == nil && header.retailers != nil) {
            return .list(try JSONDecoder().decode(RetailerList.self, from: data).retailers)
        }
        throw ImportError.unrecognized
    }

    /// Opens the file picker and imports a backup or retailer list.
    func startImport() {
        FilePicker.shared.pickFile { [weak self] url in
            self?.importFile(at: url)
        }
    }

    func importFile(at url: URL) {
        do {
            let data = try readPickedFile(url)
            switch try readImport(data) {
            case .backup(let b):
                if hasData { pendingBackup = b } else { applyBackup(b) }
            case .list(let list):
                let r = merge(list)
                show("Imported: \(r.added) new, \(r.updated) updated")
            }
        } catch {
            alertMessage = "Couldn't import \"\(url.lastPathComponent)\".\n\n\(describe(error))"
        }
    }

    func applyBackup(_ b: Backup) {
        restore(b)
        let v = b.state.retailers.values.reduce(0) { $0 + $1.visits.count }
        show("Restored \(b.state.retailers.count) retailers and \(v) visits")
        Task {
            _ = await requestReminders()
            LocationProvider.shared.requestWhenInUse()
        }
    }

    /// Opens "Save to Files" with a backup.
    func startBackup() {
        do {
            let data = try backupData()
            try FilePicker.shared.export(data, filename: "pm-tracker-backup-\(today).json") { [weak self] saved in
                guard saved else { return }
                self?.markBackedUp()
                self?.show("Backup saved")
            }
        } catch {
            alertMessage = "Couldn't make a backup.\n\n\(describe(error))"
        }
    }

    private func describe(_ error: Error) -> String {
        func path(_ c: DecodingError.Context) -> String {
            let p = c.codingPath.map(\.stringValue).joined(separator: " › ")
            return p.isEmpty ? "the top of the file" : p
        }
        if let e = error as? DecodingError {
            switch e {
            case .dataCorrupted(let c): return "The file isn't readable JSON. (\(c.debugDescription))"
            case .keyNotFound(let k, let c): return "Missing \"\(k.stringValue)\" at \(path(c))."
            case .typeMismatch(_, let c): return "Unexpected value at \(path(c)). \(c.debugDescription)"
            case .valueNotFound(_, let c): return "Missing value at \(path(c)). \(c.debugDescription)"
            @unknown default: return String(describing: e)
            }
        }
        return error.localizedDescription
    }

    func restore(_ b: Backup) {
        var s = b.state
        s.meta.lastBackupAt = b.exportedAt ?? ISO.now()
        s.meta.changesSinceBackup = 0
        s.route.stops = Array(s.route.stops.prefix(maxRouteStops))
        state = s
        commit(changed: false)
    }

    /// Adds new retailers and updates names/addresses. Keeps visits and notes; never removes anyone.
    func merge(_ list: [Retailer]) -> (added: Int, updated: Int) {
        var added = 0, updated = 0
        for inc in list where !inc.id.isEmpty {
            if var cur = state.retailers[inc.id] {
                let moved = inc.address != cur.address || inc.city.uppercased() != cur.city
                let better = inc.coord != nil && inc.geoKind == .exact && cur.hasWeakLocation && cur.geoKind != .manual
                guard inc.name != cur.name || moved || better else { continue }
                cur.name = inc.name.isEmpty ? cur.name : inc.name
                cur.address = inc.address.isEmpty ? cur.address : inc.address
                cur.city = inc.city.isEmpty ? cur.city : inc.city.uppercased()
                if !inc.tab.isEmpty { cur.tab = inc.tab }
                if better {
                    cur.lat = inc.lat; cur.lng = inc.lng; cur.geo = Geo.exact.rawValue
                } else if moved && cur.geoKind != .manual {
                    if let tc = townCenter(cur.city) { cur.lat = tc.lat; cur.lng = tc.lng; cur.geo = Geo.approx.rawValue }
                    else { cur.lat = nil; cur.lng = nil; cur.geo = Geo.none.rawValue }
                }
                state.retailers[cur.id] = cur
                updated += 1
            } else {
                var r = inc
                r.city = r.city.uppercased()
                r.visits = []
                r.archived = false
                if r.coord == nil { r.geo = Geo.none.rawValue }
                state.retailers[r.id] = r
                added += 1
            }
        }
        for (id, r) in state.retailers where r.geoKind == .none {
            if let tc = townCenter(r.city) {
                state.retailers[id]?.lat = tc.lat
                state.retailers[id]?.lng = tc.lng
                state.retailers[id]?.geo = Geo.approx.rawValue
            }
        }
        commit()
        return (added, updated)
    }

    func eraseAll() {
        state = AppState()
        commit(changed: false)
    }

    // MARK: Reminders (local notifications + icon badge)

    func requestReminders() async -> Bool {
        let ok = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        await applyReminders()
        return ok
    }

    func scheduleReminders() {
        reminderTask?.cancel()
        reminderTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            if Task.isCancelled { return }
            await self.applyReminders()
        }
    }

    /// Badge = overdue + due within 7 days. One notification at 9 AM on each upcoming due date.
    func applyReminders() async {
        let center = UNUserNotificationCenter.current()
        let ns = await center.notificationSettings()
        guard ns.authorizationStatus == .authorized || ns.authorizationStatus == .provisional else { return }
        try? await center.setBadgeCount(badgeCount)
        center.removeAllPendingNotificationRequests()

        let t = today
        var byDue: [String: [Retailer]] = [:]
        var allDues: [String] = []
        for r in active {
            guard let due = status(r).due else { continue }
            allDues.append(due)
            if due > t { byDue[due, default: []].append(r) }
        }
        for due in byDue.keys.sorted().prefix(60) {
            guard let list = byDue[due], let first = list.first, let day = Day.date(due) else { continue }
            let content = UNMutableNotificationContent()
            content.title = "PM due today"
            content.body = list.count == 1
                ? "\(first.name) (#\(first.id)) is due for preventative maintenance."
                : "\(list.count) retailers are due for PM, including \(first.name)."
            content.sound = .default
            let horizon = Day.addDays(due, 7)
            content.badge = NSNumber(value: allDues.filter { $0 <= horizon }.count)
            var comps = Day.calendar.dateComponents([.year, .month, .day], from: day)
            comps.hour = 9
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: "due-\(due)", content: content, trigger: trigger))
        }
    }
}
