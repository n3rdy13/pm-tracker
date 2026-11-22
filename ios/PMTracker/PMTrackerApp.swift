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
    }
}
