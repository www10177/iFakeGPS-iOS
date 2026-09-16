import SwiftUI

extension RouteCoordinate {
    init(_ target: LocationTarget) throws {
        try self.init(latitude: target.latitude, longitude: target.longitude)
    }
}

extension NamedWaypoint {
    var locationTarget: LocationTarget {
        LocationTarget(name: name, subtitle: "iFakeGPS bookmark", latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}

/// Reuses AppModel.favouriteLocations, including the persisted v0.1 collection.
/// Saving an existing coordinate renames it; it never accidentally toggles it off.
extension AppModel {
    func saveBookmark(_ point: NamedWaypoint) {
        let target = point.locationTarget
        if isFavourite(target) { renameFavourite(target, to: point.name) }
        else { toggleFavourite(target) }
    }
}

struct CoordinateEntryView: View {
    let original: NamedWaypoint
    let onSave: (NamedWaypoint) throws -> Void
    @State private var name: String
    @State private var latitude: String
    @State private var longitude: String
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(point: NamedWaypoint, onSave: @escaping (NamedWaypoint) throws -> Void) {
        original = point
        self.onSave = onSave
        _name = State(initialValue: point.name)
        _latitude = State(initialValue: String(point.coordinate.latitude))
        _longitude = State(initialValue: String(point.coordinate.longitude))
    }
    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Latitude (-90 to 90)", text: $latitude)
                    .keyboardType(.numbersAndPunctuation)
                TextField("Longitude (-180 to 180)", text: $longitude)
                    .keyboardType(.numbersAndPunctuation)
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("Name and coordinates")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            guard let lat = Double(latitude.trimmingCharacters(in: .whitespaces)),
                                  let lon = Double(longitude.trimmingCharacters(in: .whitespaces)) else {
                                throw RouteError.invalid("Enter numeric coordinates using a decimal point.")
                            }
                            let point = try NamedWaypoint(id: original.id, name: name,
                                coordinate: RouteCoordinate(latitude: lat, longitude: lon))
                            try onSave(point)
                            dismiss()
                        } catch { errorMessage = error.localizedDescription }
                    }
                }
            }
        }
    }
}

struct BookmarksView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let selectedLocation: LocationTarget?
    let canSelect: Bool
    let appendLabel: String
    let canAppend: Bool
    let onSelect: (LocationTarget) -> Void
    let onAppend: (LocationTarget) throws -> Void
    @State private var query = ""
    @State private var entry: NamedWaypoint?
    @State private var renameTarget: LocationTarget?
    @State private var renameText = ""
    @State private var isRenaming = false
    @State private var errorMessage: String?
    @State private var notice: String?

    private var filtered: [LocationTarget] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? appModel.favouriteLocations : appModel.favouriteLocations.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.subtitle.localizedCaseInsensitiveContains(query)
        }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let selectedLocation {
                        Button("Bookmark selected location", systemImage: "bookmark.badge.plus") {
                            perform { entry = try NamedWaypoint(name: selectedLocation.name, coordinate: RouteCoordinate(selectedLocation)) }
                        }
                    }
                    Button("Add by coordinates", systemImage: "plus") {
                        perform {
                            entry = try NamedWaypoint(name: String(localized: "New bookmark"),
                                coordinate: RouteCoordinate(latitude: 0, longitude: 0))
                        }
                    }
                    if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                } footer: {
                    Text("Bookmarks are saved on this iPhone. Existing favourites are kept. Selecting a bookmark only previews it; starting location requires a separate action.")
                }
                Section("Saved bookmarks") {
                    if filtered.isEmpty { Text("No matching bookmarks") }
                    ForEach(filtered) { place in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(place.name).font(.headline)
                            Text(String(format: "%.6f, %.6f", place.latitude, place.longitude))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            HStack {
                                Button("Select location") { onSelect(place); dismiss() }.disabled(!canSelect)
                                Spacer()
                                Menu {
                                    Button(LocalizedStringKey(appendLabel)) {
                                        perform { try onAppend(place); notice = String(localized: "Waypoint added") }
                                    }.disabled(!canAppend)
                                    Button("Rename") { renameTarget = place; renameText = place.name; isRenaming = true }
                                } label: { Image(systemName: "ellipsis.circle").padding(8) }
                            }.buttonStyle(.borderless)
                        }
                    }
                    .onDelete { offsets in
                        let selected = offsets.map { filtered[$0] }
                        selected.forEach(appModel.removeFavourite)
                    }
                    .onMove { source, destination in
                        guard query.isEmpty else { return }
                        appModel.moveFavouriteLocations(from: source, to: destination)
                    }
                    .moveDisabled(!query.isEmpty)
                }
            }
            .searchable(text: $query, prompt: "Search bookmarks")
            .navigationTitle("Bookmarks")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { EditButton().disabled(!query.isEmpty) }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $entry) { point in
                CoordinateEntryView(point: point) { point in
                    appModel.saveBookmark(point)
                    notice = String(localized: "Bookmark saved")
                }
            }
            .alert("Rename bookmark", isPresented: $isRenaming) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    perform {
                        guard let place = renameTarget else { return }
                        let validated = try NamedWaypoint(name: renameText, coordinate: RouteCoordinate(place))
                        appModel.renameFavourite(place, to: validated.name)
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Bookmark error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }
    private func perform(_ work: () throws -> Void) {
        do { try work() } catch { errorMessage = error.localizedDescription }
    }
}
