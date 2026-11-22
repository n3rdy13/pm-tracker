import AppIntents
import CoreLocation
import Foundation
import SwiftUI

// Siri commands. They run inside the app's process, so they share Store.shared with the app.

enum PMIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noData
    case message(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noData: return "PM Tracker doesn't have any retailers yet. Open the app and import your backup first."
        case .message(let m): return "\(m)"
        }
    }
}

@MainActor
enum IntentHelp {
    static func requireData() throws {
        if !Store.shared.hasData { throw PMIntentError.noData }
    }

    static func here() async throws -> Coord {
        do {
            let l = try await LocationProvider.shared.current(maxAge: 30, timeout: 10)
            Store.shared.setHere(l)
            return Coord(l)
        } catch LocationError.denied {
            throw PMIntentError.message("PM Tracker can't use your location. In Settings, open PM Tracker, tap Location, and choose Always.")
        } catch {
            throw PMIntentError.message("I couldn't get your location. Make sure PM Tracker's location permission is set to Always in Settings.")
        }
    }

    /// "Casey's General Store at 123 Main St, Ozark"
    static func place(_ r: Retailer) -> String {
        let city = r.city.capitalized
        return r.address.isEmpty ? "\(r.name) in \(city)" : "\(r.name) at \(r.address.capitalized), \(city)"
    }

    static func joined(_ parts: [String]) -> String {
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        case 2: return "\(parts[0]) and \(parts[1])"
        default: return parts.dropLast().joined(separator: ", ") + ", and " + parts.last!
        }
    }
}

// MARK: - Snippet shown under Siri's answer

struct SnippetRow: Identifiable {
    let id: String
    let name: String
    let detail: String
    let distance: String
    let color: Color
}

struct RetailerSnippet: View {
    let rows: [SnippetRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(rows) { row in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(row.color).frame(width: 10, height: 10).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name).font(.subheadline.bold()).lineLimit(1)
                        Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Text(row.distance).font(.caption.bold())
                }
            }
        }
        .padding()
    }
}

private func snippetRows(_ items: [Item]) -> [SnippetRow] {
    items.map { i in
        SnippetRow(id: i.r.id, name: i.r.name, detail: "#\(i.r.id) · \(i.s.text) · \(i.r.address), \(i.r.city)", distance: milesText(i.d), color: i.s.status.color)
    }
}

// MARK: - PMs near me

struct NearbyPMsIntent: AppIntent {
    static let title: LocalizedStringResource = "PMs Near Me"
    static let description = IntentDescription("Tells you the closest retailers that need preventative maintenance.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        try IntentHelp.requireData()
        let store = Store.shared
        let here = try await IntentHelp.here()
        let radius = store.settings.nearRadius
        let list = store.nearby(to: here, radius: radius, needOnly: true)
        guard !list.isEmpty else {
            let msg = "No stores need PM within \(Int(radius)) miles of you."
            return .result(dialog: "\(msg)", view: RetailerSnippet(rows: []))
        }
        let top = Array(list.prefix(3))
        let spoken = top.map { i in
            "\(IntentHelp.place(i.r)), \(milesSpoken(i.d ?? 0)), \(i.s.spoken), retailer number \(spacedDigits(i.r.id))"
        }
        var msg = list.count == 1
            ? "One store needs PM within \(Int(radius)) miles: "
            : "\(list.count) stores need PM within \(Int(radius)) miles. The closest \(top.count == 1 ? "is" : "are"): "
        msg += spoken.joined(separator: ". Then ") + "."
        return .result(dialog: "\(msg)", view: RetailerSnippet(rows: snippetRows(Array(list.prefix(5)))))
    }
}

// MARK: - Closest retailer number

struct ClosestRetailerIntent: AppIntent {
    static let title: LocalizedStringResource = "Closest Retailer Number"
    static let description = IntentDescription("Tells you the retailer number of the store closest to you.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        try IntentHelp.requireData()
        let store = Store.shared
        let here = try await IntentHelp.here()
        guard let near = store.nearest(to: here), let d = near.d else {
            throw PMIntentError.message("None of your stores have a location yet.")
        }
        let r = near.r
        var msg = d < 0.15 ? "You're at \(IntentHelp.place(r))." : "The closest store is \(IntentHelp.place(r)), \(milesSpoken(d))."
        msg += " Retailer number \(spacedDigits(r.id)). It's \(store.doneToday(r) ? "already done today" : near.s.spoken)."
        return .result(dialog: "\(msg)", view: RetailerSnippet(rows: snippetRows([near])))
    }
}

// MARK: - Mark this store done

struct MarkThisStoreDoneIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark This Store Done"
    static let description = IntentDescription("Records today's PM visit for the store you're at.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try IntentHelp.requireData()
        let store = Store.shared
        let here = try await IntentHelp.here()
        guard let near = store.nearest(to: here), let d = near.d else {
            throw PMIntentError.message("None of your stores have a location yet, so I can't tell which one you're at. Say \"Mark a retailer done\" instead.")
        }
        let r = near.r
        if store.doneToday(r) {
            let msg = "\(r.name), retailer number \(spacedDigits(r.id)), is already marked done today."
            return .result(dialog: "\(msg)")
        }
        // Ask first unless you're clearly standing at a store with a reliable location.
        if d > 0.2 || r.hasWeakLocation {
            let ask = "The closest store is \(IntentHelp.place(r)), retailer number \(spacedDigits(r.id)), \(milesSpoken(d)). Mark it done?"
            try await requestConfirmation(result: .result(dialog: "\(ask)"))
        }
        let saveLocation = r.hasWeakLocation
        store.markDone(r.id, location: saveLocation ? here : nil)
        var msg = "Marked \(r.name) done. Next PM is due \(Day.spoken(store.nextDue(r.id)))."
        if saveLocation { msg += " I also saved where you are as its location." }
        return .result(dialog: "\(msg)")
    }
}

// MARK: - Mark a retailer done by number

struct MarkRetailerDoneIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark Retailer Done"
    static let description = IntentDescription("Records today's PM visit for a retailer number.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Retailer Number", requestValueDialog: IntentDialog("What's the retailer number?"))
    var retailerNumber: String

    static var parameterSummary: some ParameterSummary {
        Summary("Mark retailer \(\.$retailerNumber) done")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try IntentHelp.requireData()
        let store = Store.shared
        guard let r = store.find(number: retailerNumber) else {
            let heard = digitsFromSpeech(retailerNumber)
            let ask = heard.isEmpty
                ? "I didn't catch a number. What's the retailer number?"
                : "I couldn't find retailer \(spacedDigits(heard)). What's the retailer number?"
            throw $retailerNumber.needsValueError(IntentDialog("\(ask)"))
        }
        if store.doneToday(r) {
            let msg = "\(r.name), retailer number \(spacedDigits(r.id)), is already marked done today."
            return .result(dialog: "\(msg)")
        }
        let ask = "Mark \(IntentHelp.place(r)) done?"
        try await requestConfirmation(result: .result(dialog: "\(ask)"))
        store.markDone(r.id)
        var msg = "Marked \(r.name) done. Next PM is due \(Day.spoken(store.nextDue(r.id)))."
        if r.hasWeakLocation { msg += " Its map location is only approximate. If you're there, you can fix it in the app." }
        return .result(dialog: "\(msg)")
    }
}

// MARK: - Start a route

struct StartRouteIntent: AppIntent {
    static let title: LocalizedStringResource = "Start PM Route"
    static let description = IntentDescription("Builds a route to the closest stores that need PM and opens it in Google Maps.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Stops", requestValueDialog: IntentDialog("How many stops? You can pick 1 to 9."))
    var stops: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Start a PM route with \(\.$stops) stops")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & OpensIntent {
        guard (1...maxRouteStops).contains(stops) else {
            throw $stops.needsValueError(IntentDialog("Pick a number from 1 to 9. How many stops?"))
        }
        try IntentHelp.requireData()
        let store = Store.shared
        let here = try await IntentHelp.here()
        let list = store.buildRoute(count: stops, start: here)
        guard !list.isEmpty, let url = store.routeURL() else {
            throw PMIntentError.message("No stores need PM within 75 miles of you.")
        }
        var msg = list.count < stops
            ? "I only found \(list.count) store\(list.count == 1 ? "" : "s") that need PM nearby. "
            : ""
        msg += "Starting a \(list.count)-stop route: \(IntentHelp.joined(list.map(\.name)))."
        return .result(opensIntent: OpenURLIntent(url), dialog: "\(msg)")
    }
}

// MARK: - Resume the current route

struct ResumeRouteIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume PM Route"
    static let description = IntentDescription("Opens the remaining stops of your current route in Google Maps.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & OpensIntent {
        let store = Store.shared
        let stops = store.routeStops
        guard !stops.isEmpty else {
            throw PMIntentError.message("You don't have a route right now. Say \"Start a PM route in PM Tracker\" to make one.")
        }
        let left = stops.filter { !store.doneToday($0) }
        guard !left.isEmpty, let url = store.routeURL() else {
            throw PMIntentError.message("Every stop on your route is done for today.")
        }
        let msg = "\(left.count) stop\(left.count == 1 ? "" : "s") left. Next up: \(left[0].name)."
        return .result(opensIntent: OpenURLIntent(url), dialog: "\(msg)")
    }
}

// MARK: - Status summary

struct PMStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "PM Status"
    static let description = IntentDescription("Tells you how many stores are overdue, never visited, and due soon.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try IntentHelp.requireData()
        let store = Store.shared
        let c = store.counts
        let today = store.active.filter { store.doneToday($0) }.count
        let week = store.active.filter { r in
            let s = store.status(r)
            return s.status == .soon && (s.daysToDue ?? 99) <= 7
        }.count
        var msg = "\(c[.overdue] ?? 0) overdue, \(c[.never] ?? 0) never visited, \(c[.soon] ?? 0) due in the next \(store.settings.soonDays) days, and \(c[.current] ?? 0) current."
        if week > 0 { msg += " \(week) come due within a week." }
        msg += today > 0 ? " You've done \(today) today." : ""
        return .result(dialog: "\(msg)")
    }
}

// MARK: - Siri phrases

struct PMTrackerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NearbyPMsIntent(),
            phrases: [
                "PMs near me in \(.applicationName)",
                "What needs PM near me in \(.applicationName)",
                "Which stores need PM near me in \(.applicationName)",
                "Find PMs near me with \(.applicationName)",
                "\(.applicationName) near me",
            ],
            shortTitle: "PMs Near Me",
            systemImageName: "location.magnifyingglass"
        )
        AppShortcut(
            intent: ClosestRetailerIntent(),
            phrases: [
                "Closest retailer number in \(.applicationName)",
                "What's the closest retailer number in \(.applicationName)",
                "What store am I at in \(.applicationName)",
                "Retailer number for this store in \(.applicationName)",
                "\(.applicationName) retailer number",
            ],
            shortTitle: "Closest Retailer #",
            systemImageName: "number.circle"
        )
        AppShortcut(
            intent: MarkThisStoreDoneIntent(),
            phrases: [
                "Mark this store done in \(.applicationName)",
                "Mark this store complete in \(.applicationName)",
                "Mark this one done in \(.applicationName)",
                "I finished this PM in \(.applicationName)",
                "\(.applicationName) mark done",
            ],
            shortTitle: "Mark This Store Done",
            systemImageName: "checkmark.circle.fill"
        )
        AppShortcut(
            intent: MarkRetailerDoneIntent(),
            phrases: [
                "Mark a retailer done in \(.applicationName)",
                "Mark retailer done in \(.applicationName)",
                "Mark a store done by number in \(.applicationName)",
                "\(.applicationName) mark retailer done",
            ],
            shortTitle: "Mark Retailer # Done",
            systemImageName: "checkmark.seal"
        )
        AppShortcut(
            intent: StartRouteIntent(),
            phrases: [
                "Start a PM route in \(.applicationName)",
                "Start a route in \(.applicationName)",
                "Plan a PM route in \(.applicationName)",
                "Route me to PMs with \(.applicationName)",
                "\(.applicationName) start route",
            ],
            shortTitle: "Start PM Route",
            systemImageName: "car.fill"
        )
        AppShortcut(
            intent: ResumeRouteIntent(),
            phrases: [
                "Resume my route in \(.applicationName)",
                "Continue my route in \(.applicationName)",
                "Next stop in \(.applicationName)",
                "\(.applicationName) resume route",
            ],
            shortTitle: "Resume Route",
            systemImageName: "arrow.triangle.turn.up.right.circle"
        )
        AppShortcut(
            intent: PMStatusIntent(),
            phrases: [
                "PM status in \(.applicationName)",
                "How many PMs are overdue in \(.applicationName)",
                "\(.applicationName) status",
            ],
            shortTitle: "PM Status",
            systemImageName: "chart.bar.fill"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .teal
}
