import MapKit
import SwiftUI

struct IDBox: Identifiable { let id: String }

struct RoutePin: Identifiable {
    let id: String
    let number: Int
    let coordinate: CLLocationCoordinate2D
    let done: Bool
}

struct RouteView: View {
    @EnvironmentObject var store: Store
    @State private var stopCount = 5
    @State private var loaded = false
    @State private var building = false
    @State private var confirmReplace = false
    @State private var confirmClear = false
    @State private var markDone: IDBox?
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        NavigationStack {
            List {
                buildSection
                if !store.routeStops.isEmpty {
                    routeSections
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !store.routeStops.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) { EditButton() }
                }
            }
            .navigationDestination(for: String.self) { id in RetailerDetailView(id: id) }
            .sheet(item: $markDone) { box in MarkDoneSheet(id: box.id) }
            .confirmationDialog("Replace the current route (\(store.routeStops.count) stops) with \(stopCount) new stops?", isPresented: $confirmReplace, titleVisibility: .visible) {
                Button("Replace route") { Task { await build() } }
            }
            .confirmationDialog("Clear all stops from the route?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear route", role: .destructive) { store.clearRoute() }
            }
            .onAppear {
                if !loaded { stopCount = store.settings.routeStops; loaded = true }
            }
        }
    }

    // MARK: Build

    private var buildSection: some View {
        Section {
            Stepper(value: $stopCount, in: 1...maxRouteStops) {
                Text("Stops: **\(stopCount)**")
            }
            Button {
                if store.routeStops.isEmpty { Task { await build() } } else { confirmReplace = true }
            } label: {
                HStack {
                    Label("Build route from my location", systemImage: "wand.and.stars")
                    if building { Spacer(); ProgressView() }
                }
            }
            .disabled(building || !store.hasData)
        } header: {
            Text("Build a route")
        } footer: {
            Text("Picks the \(stopCount) closest store\(stopCount == 1 ? "" : "s") that need a visit (overdue first) and puts them in the best order. You can also add stores with the + button in any list, up to \(maxRouteStops).")
        }
    }

    private func build() async {
        building = true
        defer { building = false }
        guard let here = await store.locate(fresh: true) else { return }
        let stops = store.buildRoute(count: stopCount, start: here)
        store.show(stops.isEmpty ? "No stores needing a visit within 75 miles" : "Built a \(stops.count)-stop route")
    }

    // MARK: Route

    @ViewBuilder
    private var routeSections: some View {
        let stops = store.routeStops
        let doneCount = stops.filter { store.doneToday($0) }.count

        Section {
            routeMap(stops)
                .frame(height: 240)
                .listRowInsets(EdgeInsets())
            VStack(alignment: .leading, spacing: 4) {
                (Text("\(stops.count) stop\(stops.count == 1 ? "" : "s")").bold()
                    + Text(verbatim: (store.routeMiles.map { " · about \(Int($0.rounded())) road miles (estimate)" } ?? "") + (doneCount > 0 ? " · \(doneCount) done today" : "")))
                    .font(.subheadline)
            }
            Button {
                if let url = store.routeURL() { store.open(url) } else { store.show("Every stop is done for today") }
            } label: {
                Label("Start in Google Maps", systemImage: "car.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .listRowBackground(Color.clear)
            Picker("Finish", selection: Binding(get: { store.state.route.end }, set: { store.setRouteEnd($0) })) {
                Text("At last stop").tag("last")
                Text("Back to start").tag("start")
                if store.settings.home != nil { Text("Home").tag("home") }
            }
            Button {
                Task {
                    if let here = await store.locate(fresh: true) {
                        store.optimizeRoute(start: here)
                        store.show("Route optimized from your location")
                    }
                }
            } label: {
                Label("Re-optimize from my location", systemImage: "arrow.triangle.swap")
            }
        } footer: {
            Text("Google Maps starts from wherever you are and skips stops already marked done today.")
        }

        Section("Stops") {
            ForEach(Array(stops.enumerated()), id: \.element.id) { index, r in
                HStack {
                    NavigationLink(value: r.id) {
                        RetailerRow(item: Item(r: r, s: store.status(r), d: nil), number: index + 1, showRouteButton: false)
                    }
                    if !store.doneToday(r) {
                        Button { markDone = IDBox(id: r.id) } label: {
                            Image(systemName: "checkmark.circle").font(.title2)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Mark done")
                    }
                }
            }
            .onMove { store.moveRoute(from: $0, to: $1) }
            .onDelete { store.removeFromRoute(at: $0) }
            Button("Clear route", role: .destructive) { confirmClear = true }
        }
    }

    private func routeMap(_ stops: [Retailer]) -> some View {
        var pins: [RoutePin] = []
        var line: [CLLocationCoordinate2D] = []
        if let s = store.state.route.start { line.append(s.cl) }
        for (i, r) in stops.enumerated() {
            guard let c = r.coord else { continue }
            pins.append(RoutePin(id: r.id, number: i + 1, coordinate: c.cl, done: store.doneToday(r)))
            line.append(c.cl)
        }
        if let e = store.endPoint { line.append(e.cl) }
        return Map(position: $position) {
            UserAnnotation()
            MapPolyline(coordinates: line)
                .stroke(Color.accentColor, lineWidth: 3)
            ForEach(pins) { pin in
                Annotation("", coordinate: pin.coordinate) {
                    Text("\(pin.number)")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(pin.done ? PMStatus.current.color : Color.accentColor, in: Circle())
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
        }
    }
}
