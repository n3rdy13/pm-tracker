import SwiftUI
import UniformTypeIdentifiers

enum ListFilter: String, CaseIterable, Identifiable {
    case all, overdue, never, soon, current, geo
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .overdue: return "Overdue"
        case .never: return "Never"
        case .soon: return "Due soon"
        case .current: return "Current"
        case .geo: return "Needs location"
        }
    }
}

struct RetailerListView: View {
    @EnvironmentObject var store: Store
    @State private var filter: ListFilter = .all
    @State private var tab = ""
    @State private var query = ""
    @State private var adding = false

    var body: some View {
        NavigationStack {
            Group {
                if store.hasData {
                    list
                } else {
                    welcome
                }
            }
            .navigationTitle("PM Tracker")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await store.locate() }
                    } label: {
                        if store.locating { ProgressView() } else { Image(systemName: store.here == nil ? "location" : "location.fill") }
                    }
                    .accessibilityLabel("Locate me")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add retailer")
                }
            }
            .sheet(isPresented: $adding) { AddRetailerSheet() }
            .navigationDestination(for: String.self) { id in RetailerDetailView(id: id) }
        }
    }

    private var welcome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Bring over your retailers").font(.title2.bold())
                Text("1. In the old PM Tracker web app, open **More › Back up now** and save the file to Files or iCloud Drive.")
                Text("2. Tap **Import backup** below and pick that file. Your retailers, visits, notes and fixed locations all come across.")
                Text("You can also import a retailer list file (retailers-881.json).").foregroundStyle(.secondary)
                Button {
                    store.startImport()
                } label: {
                    Label("Import backup", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding()
        }
    }

    private var allItems: [Item] { store.items(from: store.reference) }

    private var list: some View {
        let all = allItems
        var shown = all
        switch filter {
        case .all: break
        case .geo: shown = shown.filter { $0.r.geoKind == .approx || $0.r.geoKind == .none }
        case .overdue: shown = shown.filter { $0.s.status == .overdue }
        case .never: shown = shown.filter { $0.s.status == .never }
        case .soon: shown = shown.filter { $0.s.status == .soon }
        case .current: shown = shown.filter { $0.s.status == .current }
        }
        if !tab.isEmpty { shown = shown.filter { $0.r.tab == tab } }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty { shown = shown.filter { "\($0.r.id) \($0.r.name) \($0.r.city) \($0.r.address)".lowercased().contains(q) } }
        let sorted = sortByImportance(shown)
        let tabs = Array(Set(all.map(\.r.tab).filter { !$0.isEmpty })).sorted()

        return List {
            Section {
                SummaryGrid(items: all, filter: $filter)
                Banners(items: all, filter: $filter)
            }
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(ListFilter.allCases) { f in
                            Button(f.label) { filter = f }
                                .buttonStyle(.bordered)
                                .tint(filter == f ? .accentColor : .gray)
                                .controlSize(.small)
                        }
                        if !tabs.isEmpty {
                            Menu(tab.isEmpty ? "All tabs" : "Tab \(tab)") {
                                Button("All tabs") { tab = "" }
                                ForEach(tabs, id: \.self) { t in Button("Tab \(t)") { tab = t } }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            } footer: {
                Text("\(sorted.count) shown · Overdue → Never visited → Due soon → Current" + (store.reference == nil ? " · tap the location button to sort by distance" : " · nearest first within each group"))
            }
            Section {
                if sorted.isEmpty {
                    Text("No retailers match.").foregroundStyle(.secondary)
                }
                ForEach(sorted) { item in
                    NavigationLink(value: item.r.id) {
                        RetailerRow(item: item)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "Name, ID, city or address")
        .refreshable { await store.locate() }
    }
}

struct SummaryGrid: View {
    let items: [Item]
    @Binding var filter: ListFilter

    var body: some View {
        var c: [PMStatus: Int] = [:]
        for i in items { c[i.s.status, default: 0] += 1 }
        let total = items.count
        let visited = (c[.soon] ?? 0) + (c[.current] ?? 0)
        let pct = total > 0 ? Int((Double(visited) / Double(total) * 100).rounded()) : 0
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(PMStatus.allCases) { s in
                    Button {
                        filter = ListFilter(rawValue: ["overdue", "never", "soon", "current"][s.rawValue]) ?? .all
                    } label: {
                        VStack(spacing: 2) {
                            Text("\(c[s] ?? 0)").font(.title3.bold()).foregroundStyle(s.color)
                            Text(s.label).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(s.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Text("**\(visited)** of \(total) visited in the last 6 months").font(.caption)
                Spacer()
                Text("\(pct)%").font(.caption.bold())
            }
            ProgressView(value: Double(visited), total: Double(max(total, 1)))
        }
        .padding(.vertical, 4)
    }
}

struct Banners: View {
    @EnvironmentObject var store: Store
    let items: [Item]
    @Binding var filter: ListFilter

    var body: some View {
        let over = items.filter { $0.s.status == .overdue }.count
        let due7 = items.filter { $0.s.status == .soon && ($0.s.daysToDue ?? 99) <= 7 }.count
        let changes = store.state.meta.changesSinceBackup
        let last = ISO.date(store.state.meta.lastBackupAt)
        let stale = last == nil || Date().timeIntervalSince(last!) > 7 * 86400
        let alertParts: [String?] = [over > 0 ? "\(over) overdue" : nil, due7 > 0 ? "\(due7) due within 7 days" : nil]
        let alertText = alertParts.compactMap { $0 }.joined(separator: " · ")
        let lastText: String = last.map { "Last backup " + Day.pretty(Day.string($0)) + "." } ?? "No backup yet."
        let backupText = "\(lastText) \(changes) change\(changes == 1 ? "" : "s") not backed up. Back up from the More tab."
        VStack(alignment: .leading, spacing: 8) {
            if over > 0 || due7 > 0 {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(PMStatus.overdue.color)
                    Text(alertText)
                        .font(.subheadline)
                    Spacer()
                    Button("Show") { filter = over > 0 ? .overdue : .soon }.buttonStyle(.bordered).controlSize(.small)
                }
            }
            if changes > 0 && stale {
                HStack {
                    Image(systemName: "externaldrive.badge.exclamationmark").foregroundStyle(PMStatus.soon.color)
                    Text(backupText)
                        .font(.caption)
                }
            }
        }
    }
}
