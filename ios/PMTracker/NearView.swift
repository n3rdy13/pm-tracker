import MapKit
import SwiftUI

struct NearView: View {
    @EnvironmentObject var store: Store
    @State private var needOnly = true
    @State private var radius: Double = 25
    @State private var position: MapCameraPosition = .userLocation(fallback: .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 37.2, longitude: -93.3), span: MKCoordinateSpan(latitudeDelta: 2, longitudeDelta: 2))))
    @State private var selected: String?
    @State private var loaded = false

    private var items: [Item] {
        guard let origin = store.reference else { return [] }
        return store.nearby(to: origin, radius: radius, needOnly: needOnly)
    }

    var body: some View {
        NavigationStack {
            let list = items
            VStack(spacing: 0) {
                Map(position: $position, selection: $selected) {
                    UserAnnotation()
                    ForEach(MapPin.from(Array(list.prefix(300)))) { pin in
                        Marker(pin.name, coordinate: pin.coordinate)
                            .tint(pin.color)
                            .tag(pin.id)
                    }
                }
                .frame(height: 280)
                .overlay(alignment: .bottom) {
                    if let id = selected, let r = store.retailer(id) {
                        NavigationLink(value: id) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(r.name).font(.subheadline.bold())
                                    Text("#\(r.id) · \(store.status(r).text)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                            }
                            .padding(10)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                            .padding(8)
                        }
                        .buttonStyle(.plain)
                    }
                }

                List {
                    Section {
                        Picker("Show", selection: $needOnly) {
                            Text("Needs a visit").tag(true)
                            Text("All").tag(false)
                        }
                        .pickerStyle(.segmented)
                        Picker("Within", selection: $radius) {
                            ForEach([5.0, 10, 25, 50, 100], id: \.self) { Text("\(Int($0)) miles").tag($0) }
                        }
                    } footer: {
                        Text(locationNote)
                    }
                    Section {
                        if store.reference == nil {
                            Text("Tap the location button to find stores near you.").foregroundStyle(.secondary)
                        } else if list.isEmpty {
                            Text("Nothing \(needOnly ? "needing a visit " : "")within \(Int(radius)) miles.").foregroundStyle(.secondary)
                        }
                        ForEach(list.prefix(200)) { item in
                            NavigationLink(value: item.r.id) { RetailerRow(item: item) }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("Near Me")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            await store.locate()
                            position = .userLocation(fallback: .automatic)
                        }
                    } label: {
                        if store.locating { ProgressView() } else { Label("Refresh", systemImage: "location.fill") }
                    }
                }
            }
            .navigationDestination(for: String.self) { id in RetailerDetailView(id: id) }
            .onAppear {
                if !loaded { radius = store.settings.nearRadius; loaded = true }
                if store.here == nil { Task { await store.locate(fresh: false, quiet: true) } }
            }
            .onChange(of: radius) { _, v in store.updateSettings { $0.nearRadius = v } }
        }
    }

    private var locationNote: String {
        if let t = store.hereTime {
            let mins = Int(Date().timeIntervalSince(t) / 60)
            let acc = store.hereAccuracy.map { " (±\(Int($0)) m)" } ?? ""
            return "Your location \(mins < 1 ? "just now" : "\(mins) min ago")\(acc). Straight-line miles."
        }
        return store.settings.home != nil ? "Using your home base until your location is found." : "Your location hasn't been found yet."
    }
}

struct MapPin: Identifiable {
    let id: String
    let name: String
    let coordinate: CLLocationCoordinate2D
    let color: Color

    static func from(_ items: [Item]) -> [MapPin] {
        items.compactMap { item in
            guard let c = item.r.coord else { return nil }
            return MapPin(id: item.r.id, name: item.r.name, coordinate: c.cl, color: item.s.status.color)
        }
    }
}
