import MapKit
import Observation
import SwiftUI

@MainActor @Observable
final class WaypointEditorModel {
    var draft = WaypointDraft()
    var name = String(localized: "New route")
    func add(_ target: LocationTarget) throws {
        try draft.add(NamedWaypoint(name: target.name, coordinate: RouteCoordinate(target)))
    }
}

struct WaypointEditorView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: WaypointEditorModel
    let simulation: WalkingSimulationController
    let onUse: (SavedRoute) throws -> Void
    @State private var camera: MapCameraPosition = .automatic
    @State private var editing: NamedWaypoint?
    @State private var isNewEntry = false
    @State private var mode: RoadPlanningService.Mode = .direct
    @State private var key = ""
    @State private var task: Task<Void, Never>?
    @State private var isPlanning = false
    @State private var planningID = UUID()
    @State private var showConsent = false
    @State private var saveOnly = false
    @State private var errorMessage: String?
    @State private var notice: String?
    @State private var clearConfirmed = false

    private var isAppending: Bool { simulation.canAppendWaypoints }
    private var anchor: RouteCoordinate? { isAppending ? simulation.routeEnd : nil }
    private var coordinates: [CLLocationCoordinate2D] {
        ((anchor.map { [$0] } ?? []) + model.draft.points.map(\.coordinate)).map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
    }
    private var canUse: Bool {
        !isPlanning && (!simulation.locksDestination || isAppending)
            && model.draft.points.count >= (isAppending ? 1 : 2)
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                editorMap
                List {
                    Section {
                        TextField("Route name", text: $model.name)
                        Text(LocalizedStringKey(isAppending ? "New points extend the active route endpoint, not your current position." : "Tap the map to add waypoints in order. Creating a route does not start location simulation."))
                            .font(.caption)
                        HStack {
                            Button("Coordinates", systemImage: "plus") {
                                perform {
                                    isNewEntry = true
                                    editing = try NamedWaypoint(name: String(localized: "Waypoint"),
                                        coordinate: anchor ?? RouteCoordinate(latitude: 0, longitude: 0))
                                }
                            }
                            Spacer()
                            Menu("Add bookmark", systemImage: "bookmark") {
                                ForEach(appModel.favouriteLocations) { point in
                                    Button(point.name) { perform { try model.add(point) } }
                                }
                            }.disabled(appModel.favouriteLocations.isEmpty)
                        }.buttonStyle(.borderless)
                    }
                    Section("Waypoints (drag to reorder)") {
                        if model.draft.points.isEmpty { Text("Tap the map or add a bookmark to begin.") }
                        ForEach(Array(model.draft.points.enumerated()), id: \.element.id) { index, point in
                            Button {
                                isNewEntry = false
                                editing = point
                            } label: {
                                HStack {
                                    Text("\(index + 1)").monospacedDigit().frame(width: 30)
                                    VStack(alignment: .leading) {
                                        Text(point.name)
                                        Text(String(format: "%.6f, %.6f", point.coordinate.latitude, point.coordinate.longitude))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .onDelete { offsets in
                            model.draft.remove(ids: Set(offsets.map { model.draft.points[$0].id }))
                        }
                        .onMove { source, destination in perform { try model.draft.move(from: source, to: destination) } }
                        HStack {
                            Button("Reverse order") { model.draft.reverse() }
                            Spacer()
                            Button("Clear draft", role: .destructive) { clearConfirmed = true }
                        }.buttonStyle(.borderless).disabled(model.draft.points.isEmpty)
                    }
                    Section("Route planning") {
                        Picker("Provider", selection: $mode) {
                            ForEach(RoadPlanningService.Mode.allCases) { mode in
                                Text(LocalizedStringKey(mode.title)).tag(mode)
                            }
                        }
                        if mode.needsKey {
                            SecureField("OpenRouteService API key", text: $key)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button("Save key in Keychain") {
                                perform { try RoutingKeyStore.save(key); notice = String(localized: "API key saved (empty removes it)") }
                            }
                        }
                        Text("Offline mode connects points directly. Online planning sends the waypoint coordinates to the selected provider after confirmation. OSRM here is driving only. Road snapping may add short straight connectors at endpoints.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section {
                        Button(LocalizedStringKey(isAppending ? "Append to active route" : "Preview this route")) { requestPlan(saveOnly: false) }
                            .disabled(!canUse)
                        Button("Save draft as route") { requestPlan(saveOnly: true) }
                            .disabled(isPlanning || model.draft.points.count < 2 || isAppending)
                        if isPlanning {
                            HStack {
                                ProgressView()
                                Text("Planning route")
                                Spacer()
                                Button("Cancel") { task?.cancel(); task = nil; planningID = UUID(); isPlanning = false }
                            }
                        }
                        if let notice { Text(notice).font(.caption) }
                    }
                }
            }
            .navigationTitle(Text(LocalizedStringKey(isAppending ? "Append waypoints" : "Edit route")))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { EditButton().disabled(isPlanning) }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $editing) { point in
                CoordinateEntryView(point: point) { updated in
                    if isNewEntry { try model.draft.add(updated) }
                    else { try model.draft.replace(updated) }
                }
            }
            .confirmationDialog("Send waypoints to the selected routing provider?", isPresented: $showConsent,
                                titleVisibility: .visible) {
                Button("Send and plan") { plan(saveOnly: saveOnly) }
                Button("Cancel", role: .cancel) {}
            } message: { Text(LocalizedStringKey(mode.title)) }
            .confirmationDialog("Discard all draft waypoints?", isPresented: $clearConfirmed,
                                titleVisibility: .visible) {
                Button("Clear draft", role: .destructive) { model.draft.clear() }
            }
            .alert("Route error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
            .onAppear { perform { key = try RoutingKeyStore.load() } }
            .onDisappear { task?.cancel(); task = nil; planningID = UUID() }
        }
    }
    private var editorMap: some View {
        MapReader { proxy in
            Map(position: $camera) {
                if let existing = simulation.customPolyline, isAppending {
                    MapPolyline(existing).stroke(.gray, lineWidth: 3)
                }
                if coordinates.count >= 2 { MapPolyline(coordinates: coordinates).stroke(.orange, lineWidth: 5) }
                if let anchor {
                    Marker("Current route endpoint", coordinate: CLLocationCoordinate2D(latitude: anchor.latitude, longitude: anchor.longitude))
                        .tint(.gray)
                }
                ForEach(Array(model.draft.points.enumerated()), id: \.element.id) { index, point in
                    Marker("\(index + 1). \(point.name)", coordinate: CLLocationCoordinate2D(
                        latitude: point.coordinate.latitude, longitude: point.coordinate.longitude))
                }
            }
            .onTapGesture { position in
                guard !isPlanning, let coordinate = proxy.convert(position, from: .local) else { return }
                perform {
                    try model.draft.add(NamedWaypoint(name: String(localized: "Waypoint") + " \(model.draft.points.count + 1)",
                        coordinate: RouteCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)))
                }
            }
        }
        .frame(height: 230)
        .accessibilityHint("Tap to append a draft waypoint")
    }
    private func requestPlan(saveOnly: Bool) {
        self.saveOnly = saveOnly
        if mode == .direct { plan(saveOnly: saveOnly) } else { showConsent = true }
    }
    private func plan(saveOnly: Bool) {
        task?.cancel()
        let snapshot = model.draft.points
        let token = simulation.editToken
        let append = isAppending && !saveOnly
        let points = (append ? anchor.map { [$0] } ?? [] : []) + snapshot.map(\.coordinate)
        let mode = self.mode
        let name = model.name
        let requestID = UUID()
        planningID = requestID
        isPlanning = true
        task = Task { @MainActor in
            defer { if planningID == requestID { isPlanning = false } }
            do {
                let geometry = try await RoadPlanningService().plan(points, mode: mode)
                try Task.checkCancellation()
                guard planningID == requestID, simulation.editToken == token, model.draft.points == snapshot, model.name == name, self.mode == mode else {
                    throw RouteError.invalid("The route changed while planning. Review it and try again.")
                }
                if append {
                    try simulation.appendWaypoints(geometry.points, using: appModel)
                    model.draft.clear()
                    dismiss()
                } else {
                    let route = try SavedRoute(name: name, points: geometry.points)
                    if saveOnly {
                        try RouteLibraryModel().add([route])
                        notice = String(localized: "Route saved")
                    } else {
                        try onUse(route)
                        model.draft.clear()
                        dismiss()
                    }
                }
            } catch is CancellationError { }
            catch { if planningID == requestID && !Task.isCancelled { errorMessage = error.localizedDescription } }
        }
    }
    private func perform(_ work: () throws -> Void) {
        do { try work() } catch { errorMessage = error.localizedDescription }
    }
}
