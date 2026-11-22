import SwiftUI

@main
struct PMTrackerApp: App {
    @StateObject private var store = Store.shared
    @StateObject private var location = LocationProvider.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(location)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        store.scheduleReminders()
                        if store.settings.autoLocate && store.hasData {
                            Task { await store.locate(fresh: false, quiet: true) }
                        }
                    }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        ZStack {
        TabView {
            RetailerListView()
                .tabItem { Label("Retailers", systemImage: "list.bullet") }
            NearView()
                .tabItem { Label("Near Me", systemImage: "location") }
            RouteView()
                .tabItem { Label("Route", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                .badge(store.state.route.stops.count)
            MoreView()
                .tabItem { Label("More", systemImage: "ellipsis.circle") }
        }
        .overlay { ToastOverlay() }
        .alert("Import problem", isPresented: Binding(get: { store.alertMessage != nil }, set: { if !$0 { store.alertMessage = nil } })) {
            Button("OK", role: .cancel) { store.alertMessage = nil }
        } message: {
            Text(store.alertMessage ?? "")
        }
        }
        .alert("Replace everything?", isPresented: Binding(get: { store.pendingBackup != nil }, set: { if !$0 { store.pendingBackup = nil } })) {
            Button("Replace", role: .destructive) {
                if let b = store.pendingBackup { store.applyBackup(b) }
                store.pendingBackup = nil
            }
            Button("Cancel", role: .cancel) { store.pendingBackup = nil }
        } message: {
            Text(replaceMessage)
        }
    }

    private var replaceMessage: String {
        guard let b = store.pendingBackup else { return "" }
        let v = b.state.retailers.values.reduce(0) { $0 + $1.visits.count }
        return "This replaces all \(store.state.retailers.count) retailers on this phone with the backup (\(b.state.retailers.count) retailers, \(v) visits)."
    }
}
