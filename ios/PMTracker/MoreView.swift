import AppIntents
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct MoreView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var location: LocationProvider
    @Environment(\.openURL) private var openURL

    @State private var showArchived = false
    @State private var confirmErase = false
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        NavigationStack {
            Form {
                siriSection
                dataSection
                remindersSection
                settingsSection
                aboutSection
            }
            .navigationTitle("More")
            .sheet(isPresented: $showArchived) { ArchivedSheet() }
            .task { await refreshNotificationStatus() }
        }
    }

    // MARK: Siri

    private var siriSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Say \"Hey Siri,\" then:").font(.subheadline.bold())
                Group {
                    Text("• \"PMs near me in PM Tracker\"")
                    Text("• \"Closest retailer number in PM Tracker\"")
                    Text("• \"Mark this store done in PM Tracker\"")
                    Text("• \"Mark a retailer done in PM Tracker\"")
                    Text("• \"Start a PM route in PM Tracker\"")
                    Text("• \"Resume my route in PM Tracker\"")
                    Text("• \"PM status in PM Tracker\"")
                }
                .font(.callout)
            }
            ShortcutsLink()
            if !location.isAlways {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Siri needs location set to Always", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(PMStatus.soon.color)
                        .font(.subheadline.bold())
                    Text("Right now it's \"\(location.statusText)\". Without Always, Siri can't tell which stores are near you unless the app is open.")
                        .font(.caption)
                    Button(location.authorization == .authorizedWhenInUse ? "Change to Always" : "Allow location") {
                        if location.authorization == .notDetermined {
                            location.requestWhenInUse()
                        } else if location.authorization == .authorizedWhenInUse {
                            location.requestAlways()
                        } else if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    }
                    Text("If no prompt appears, open Settings › PM Tracker › Location › Always.").font(.caption2).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Siri")
        }
    }

    // MARK: Data

    private var dataSection: some View {
        let all = store.state.retailers.values
        let act = all.filter { !$0.archived }
        let visits = all.reduce(0) { $0 + $1.visits.count }
        let weak = act.filter { $0.hasWeakLocation && $0.geoKind != .manual }.count
        let last = ISO.date(store.state.meta.lastBackupAt)
        let lastText: String = last.map { "Last backup " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "No backup yet"
        let summary = "\(lastText) · \(store.state.meta.changesSinceBackup) changes since. \(act.count) active retailers, \(visits) visits, \(weak) with approximate or missing locations. Data stays on this phone, so back up to iCloud Drive now and then."
        return Section {
            Button {
                store.startBackup()
            } label: {
                Label("Back up now", systemImage: "square.and.arrow.up")
            }
            Button { store.startImport() } label: { Label("Restore backup or import retailer list", systemImage: "square.and.arrow.down") }
            Button { showArchived = true } label: { Label("Archived retailers (\(all.count - act.count))", systemImage: "archivebox") }
        } header: {
            Text("Data")
        } footer: {
            Text(summary)
        }
    }

    // MARK: Reminders

    private var remindersSection: some View {
        Section {
            if notificationStatus == .authorized || notificationStatus == .provisional {
                Label("On — badge shows \(store.badgeCount) (overdue + due within 7 days)", systemImage: "bell.badge.fill")
            } else if notificationStatus == .denied {
                Button("Turn on in Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            } else {
                Button("Turn on reminders and icon badge") {
                    Task {
                        _ = await store.requestReminders()
                        await refreshNotificationStatus()
                    }
                }
            }
            Picker("\"Due soon\" means within", selection: Binding(get: { store.settings.soonDays }, set: { v in store.updateSettings { $0.soonDays = v } })) {
                ForEach([14, 30, 45, 60], id: \.self) { Text("\($0) days").tag($0) }
            }
        } header: {
            Text("Reminders")
        } footer: {
            Text("You get a notification at 9 AM on each day a store comes due. The app icon badge counts overdue stores plus stores due within 7 days.")
        }
    }

    private func refreshNotificationStatus() async {
        notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // MARK: Settings

    private var settingsSection: some View {
        Section {
            Picker("Open routes in", selection: Binding(get: { store.settings.mapsMode }, set: { v in store.updateSettings { $0.mapsMode = v } })) {
                Text("Google Maps app").tag("app")
                Text("Google Maps link").tag("web")
            }
            Toggle("Find my location when the app opens", isOn: Binding(get: { store.settings.autoLocate }, set: { v in store.updateSettings { $0.autoLocate = v } }))
            HStack {
                Text("Home base")
                Spacer()
                Text(store.settings.home.map { String(format: "%.4f, %.4f", $0.lat, $0.lng) } ?? "Not set").foregroundStyle(.secondary)
            }
            Button("Set home base to my location") {
                Task {
                    if let c = await store.locate(fresh: true) {
                        store.updateSettings { $0.home = c }
                        store.show("Home base saved")
                    }
                }
            }
            if store.settings.home != nil {
                Button("Clear home base", role: .destructive) { store.updateSettings { $0.home = nil } }
            }
        } header: {
            Text("Settings")
        } footer: {
            Text("If \"Google Maps app\" doesn't open the app with all stops, switch to \"Google Maps link\". The home base is used for distances when your location isn't known, and as a route finish point.")
        }
    }

    private var aboutSection: some View {
        Section {
            Text("PM Tracker \(Store.appVersion) · data stays on this device").font(.caption).foregroundStyle(.secondary)
            Button("Erase all data", role: .destructive) { confirmErase = true }
                .confirmationDialog("Erase ALL retailers, visits and notes from this phone? This can't be undone.", isPresented: $confirmErase, titleVisibility: .visible) {
                    Button("Erase everything", role: .destructive) {
                        store.eraseAll()
                        store.show("All data erased")
                    }
                }
        }
    }
}

struct ArchivedSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if store.archived.isEmpty { Text("None.").foregroundStyle(.secondary) }
                ForEach(store.archived) { r in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(r.name).font(.subheadline.bold())
                            Text("#\(r.id) · \(r.city)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore") { store.setArchived(r.id, false) }.buttonStyle(.bordered)
                    }
                }
            }
            .navigationTitle("Archived")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
