import SwiftUI

struct RetailerDetailView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let id: String

    @State private var notes = ""
    @State private var loadedNotes = false
    @State private var markingDone = false
    @State private var fixingLocation = false
    @State private var editing = false
    @State private var confirmArchive = false
    @State private var visitToDelete: Visit?

    var body: some View {
        if let r = store.retailer(id) {
            content(r)
        } else {
            Text("This retailer no longer exists.").foregroundStyle(.secondary)
        }
    }

    private func content(_ r: Retailer) -> some View {
        let s = store.status(r)
        let distance: Double? = {
            guard let ref = store.reference, let c = r.coord else { return nil }
            return haversineMi(ref, c)
        }()
        let visits = r.visits.sorted { $0.date > $1.date }

        return List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(r.name).font(.title3.bold())
                    HStack {
                        if store.doneToday(r) { Pill(text: "Done today", color: PMStatus.current.color) }
                        Pill(text: s.text, color: s.status.color)
                        if r.archived { Pill(text: "Archived", color: .gray) }
                    }
                }
                LabeledContent("Retailer ID", value: r.id)
                LabeledContent("Address") {
                    Text("\(r.address)\n\(r.city), \(r.state.isEmpty ? "MO" : r.state)").multilineTextAlignment(.trailing)
                }
                LabeledContent("Tab", value: r.tab.isEmpty ? "—" : r.tab)
                LabeledContent("Last visit", value: Day.pretty(s.last))
                LabeledContent("Next due", value: s.due.map { Day.pretty($0) } ?? "Now (never visited)")
                LabeledContent("Location", value: r.geoKind.label + (distance.map { " · \(milesText($0)) away" } ?? ""))
            }

            Section {
                Button { markingDone = true } label: { Label("Mark done", systemImage: "checkmark.circle.fill") }
                Button { store.open(store.directionsURL(r)) } label: { Label("Navigate in Google Maps", systemImage: "car.fill") }
                Button { store.toggleRoute(r.id) } label: {
                    Label(store.inRoute(r.id) ? "Remove from route" : "Add to route", systemImage: store.inRoute(r.id) ? "minus.circle" : "plus.circle")
                }
                Button { fixingLocation = true } label: { Label("Fix location", systemImage: "mappin.and.ellipse") }
            }

            Section("Notes") {
                TextField("Gate code, contact, hours, terminal notes…", text: $notes, axis: .vertical)
                    .lineLimit(3...10)
                    .onSubmit { store.setNotes(id, notes) }
            }

            Section("Visit history") {
                if visits.isEmpty {
                    Text("No visits recorded yet.").foregroundStyle(.secondary)
                }
                ForEach(visits) { v in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Day.pretty(v.date)).font(.subheadline.bold())
                        if !v.note.isEmpty { Text(v.note).font(.caption).foregroundStyle(.secondary) }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { visitToDelete = v }
                    }
                }
            }

            Section {
                Button("Edit details") { editing = true }
                if r.archived {
                    Button("Restore from archive") { store.setArchived(id, false) }
                } else {
                    Button("Archive (store closed)", role: .destructive) { confirmArchive = true }
                }
            }
        }
        .navigationTitle("#\(r.id)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !loadedNotes { notes = r.notes; loadedNotes = true }
        }
        .onDisappear { store.setNotes(id, notes) }
        .sheet(isPresented: $markingDone) { MarkDoneSheet(id: id) }
        .sheet(isPresented: $fixingLocation) { FixLocationSheet(id: id) }
        .sheet(isPresented: $editing) { EditRetailerSheet(retailer: r) }
        .confirmationDialog("Archive \(r.name)? It will be hidden from lists and routes.", isPresented: $confirmArchive, titleVisibility: .visible) {
            Button("Archive", role: .destructive) { store.setArchived(id, true) }
        }
        .confirmationDialog("Delete this visit?", isPresented: Binding(get: { visitToDelete != nil }, set: { if !$0 { visitToDelete = nil } }), titleVisibility: .visible) {
            Button("Delete visit", role: .destructive) {
                if let v = visitToDelete { store.deleteVisit(id, v.id) }
                visitToDelete = nil
            }
        }
    }
}

// MARK: - Mark done

struct MarkDoneSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let id: String

    @State private var date = Date()
    @State private var note = ""
    @State private var saveLocation = false
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                if let r = store.retailer(id) {
                    Section {
                        Text(r.name).font(.headline)
                        Text("#\(r.id) · \(r.address), \(r.city)").font(.caption).foregroundStyle(.secondary)
                    }
                    Section {
                        DatePicker("Visit date", selection: $date, in: ...Date(), displayedComponents: .date)
                        TextField("Note (optional), e.g. replaced printer head", text: $note)
                    }
                    Section {
                        Toggle("Save my current position as this store's location", isOn: $saveLocation)
                    } footer: {
                        Text(r.hasWeakLocation ? "Recommended: this store's location is only approximate. Only turn this on if you're at the store." : "Only turn this on if you're at the store.")
                    }
                }
            }
            .navigationTitle("Mark done")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(saving)
                }
            }
            .onAppear { saveLocation = store.retailer(id)?.hasWeakLocation ?? false }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() async {
        saving = true
        var loc: Coord?
        var locMsg = ""
        if saveLocation {
            loc = await store.locate(fresh: true, quiet: true)
            locMsg = loc == nil ? " · location not saved" : " · location saved"
        }
        guard let r = store.retailer(id) else { dismiss(); return }
        let before = store.markDone(id, date: Day.string(date), note: note.trimmingCharacters(in: .whitespaces), location: loc)
        dismiss()
        store.show("Done: \(r.name). Next due \(Day.pretty(store.nextDue(id)))\(locMsg)", undo: {
            if let before { store.put(before) }
        })
    }
}

// MARK: - Fix location

struct FixLocationSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var pasted = ""

    var body: some View {
        NavigationStack {
            Form {
                if let r = store.retailer(id) {
                    Section {
                        Text("Currently: **\(r.geoKind.label)**. Locations are used for distances, route order and Siri's \"this store\" lookups.")
                            .font(.callout)
                    }
                    Section {
                        Button {
                            Task {
                                if let c = await store.locate(fresh: true) {
                                    store.setLocation(id, c, geo: .manual)
                                    store.show("Location saved" + (store.hereAccuracy.map { " (±\(Int($0)) m)" } ?? ""))
                                    dismiss()
                                }
                            }
                        } label: {
                            Label("I'm at the store — use my position", systemImage: "location.fill")
                        }
                    }
                    Section {
                        TextField("37.2089, -93.2923 or a Google Maps link", text: $pasted)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Save pasted location") {
                            guard let c = parseCoords(pasted) else { store.show("Couldn't read coordinates from that"); return }
                            store.setLocation(id, c, geo: .manual)
                            store.show("Location saved")
                            dismiss()
                        }
                    } header: {
                        Text("Or paste coordinates")
                    } footer: {
                        Text("In Google Maps, long-press the store to drop a pin, then copy the coordinates shown.")
                    }
                    if let tc = store.townCenter(r.city) {
                        Section {
                            Button("Use town center") {
                                store.setLocation(id, tc, geo: .approx)
                                store.show("Set to town center")
                                dismiss()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Fix location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

// MARK: - Edit / add

struct EditRetailerSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let retailer: Retailer
    @State private var name = ""
    @State private var address = ""
    @State private var city = ""
    @State private var tab = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Street address", text: $address)
                TextField("City", text: $city).textInputAutocapitalization(.characters)
                TextField("Tab", text: $tab).keyboardType(.numberPad)
            }
            .navigationTitle("Edit details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.updateDetails(retailer.id, name: name.trimmingCharacters(in: .whitespaces), address: address.trimmingCharacters(in: .whitespaces), city: city.trimmingCharacters(in: .whitespaces), tab: tab.trimmingCharacters(in: .whitespaces))
                        store.show("Saved")
                        dismiss()
                    }
                }
            }
            .onAppear {
                name = retailer.name; address = retailer.address; city = retailer.city; tab = retailer.tab
            }
        }
    }
}

struct AddRetailerSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var id = ""
    @State private var name = ""
    @State private var address = ""
    @State private var city = ""
    @State private var tab = ""
    @State private var atStore = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Retailer ID", text: $id).keyboardType(.numberPad)
                TextField("Name", text: $name)
                TextField("Street address", text: $address)
                TextField("City", text: $city).textInputAutocapitalization(.characters)
                TextField("Tab (e.g. 600)", text: $tab).keyboardType(.numberPad)
                Toggle("I'm at the store — use my position as its location", isOn: $atStore)
            }
            .navigationTitle("Add retailer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await add() } }
                        .disabled(id.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func add() async {
        let rid = id.trimmingCharacters(in: .whitespaces)
        let r = Retailer(id: rid, name: name.isEmpty ? "Retailer \(rid)" : name.trimmingCharacters(in: .whitespaces), address: address.trimmingCharacters(in: .whitespaces), city: city.trimmingCharacters(in: .whitespaces).uppercased(), tab: tab.trimmingCharacters(in: .whitespaces))
        var loc: Coord?
        if atStore { loc = await store.locate(fresh: true) }
        if let err = store.add(r, location: loc) {
            store.show(err)
        } else {
            store.show("Added \(r.name)")
            dismiss()
        }
    }
}
