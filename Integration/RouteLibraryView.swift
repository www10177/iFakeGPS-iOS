import MapKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let ifakeGPX = UTType(importedAs: "com.topografix.gpx", conformingTo: .xml)
}

struct GPXDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.ifakeGPX, .xml] }
    static var writableContentTypes: [UTType] { [.ifakeGPX] }
    var data: Data
    init(route: SavedRoute) { data = GPXCodec.encode(route) }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw RouteError.invalid("The selected file is not a regular GPX file.")
        }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

@MainActor @Observable
final class RouteLibraryModel {
    private(set) var routes: [SavedRoute] = []
    private(set) var loadError: String?
    private let url: URL?

    init() {
        url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("iFakeGPS/routes-v1.json")
        do {
            guard let url else { throw RouteError.invalid("Application storage is unavailable.") }
            routes = try RouteLibrary.load(from: url)
        } catch { loadError = error.localizedDescription }
    }
    func add(_ routes: [SavedRoute]) throws { try commit(self.routes + routes) }
    func remove(at offsets: IndexSet) throws {
        var copy = routes
        copy.remove(atOffsets: offsets)
        try commit(copy)
    }
    func rename(_ route: SavedRoute, to name: String) throws {
        var copy = routes
        guard let index = copy.firstIndex(where: { $0.id == route.id }) else { return }
        copy[index] = try route.renamed(name)
        try commit(copy)
    }
    func importGPX(from source: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile != false, (values.fileSize ?? 0) <= GPXCodec.maximumBytes else {
            throw RouteError.invalid("Choose a regular GPX file no larger than 5 MiB.")
        }
        try add(GPXCodec.decode(Data(contentsOf: source)))
    }
    private func commit(_ routes: [SavedRoute]) throws {
        guard loadError == nil, let url else {
            throw RouteError.invalid("The existing library could not be loaded; it will not be overwritten.")
        }
        try RouteLibrary.save(routes, to: url)
        self.routes = routes
    }
}

struct RouteLibraryView: View {
    let simulation: WalkingSimulationController
    let onSelect: (SavedRoute) throws -> Void
    @State private var model = RouteLibraryModel()
    @State private var isImporting = false
    @State private var isExporting = false
    @State private var document: GPXDocument?
    @State private var exportName = "route"
    @State private var errorMessage: String?
    @State private var isShowingError = false
    @State private var renameTarget: SavedRoute?
    @State private var renameText = ""
    @State private var isRenaming = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let error = model.loadError {
                    Section("Library unavailable") {
                        Text(error)
                        Text("The existing file is preserved. No import, rename, or delete will overwrite it.")
                    }
                }
                Section {
                    Button("Import GPX", systemImage: "square.and.arrow.down") { isImporting = true }
                    if let route = simulation.exportableRoute {
                        Button("Save current route", systemImage: "square.and.arrow.down.on.square") {
                            perform { try model.add([route]) }
                        }
                    }
                } footer: {
                    Text("GPX stays on this iPhone. Each track segment is imported separately; elevation and timestamps are not used for playback.")
                }
                .disabled(model.loadError != nil)
                Section("Saved routes") {
                    if model.routes.isEmpty { Text("Import a GPX route from desktop iFakeGPS to begin.") }
                    ForEach(model.routes) { route in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(route.name).font(.headline)
                            Text("\(route.points.count) points").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Use route") { perform { try onSelect(route) } }
                                    .disabled(simulation.locksDestination)
                                Spacer()
                                Menu {
                                    Button("Export GPX") {
                                        document = GPXDocument(route: route)
                                        exportName = "route-\(route.id.uuidString.prefix(8))"
                                        isExporting = true
                                    }
                                    Button("Rename") {
                                        renameTarget = route
                                        renameText = route.name
                                        isRenaming = true
                                    }
                                } label: { Image(systemName: "ellipsis.circle").padding(8) }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .onDelete { offsets in perform { try model.remove(at: offsets) } }
                }
                Section("Playback") { PlaybackOptionsView(simulation: simulation) }
            }
            .navigationTitle("iFakeGPS Routes")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.ifakeGPX, .xml]) { result in
                perform { try model.importGPX(from: result.get()) }
            }
            .fileExporter(isPresented: $isExporting, document: document,
                          contentType: .ifakeGPX, defaultFilename: exportName) { result in
                if case .failure(let error) = result { show(error) }
            }
            .alert("Route error", isPresented: $isShowingError) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "Unknown error") }
            .alert("Rename route", isPresented: $isRenaming) {
                TextField("Route name", text: $renameText)
                Button("Save") {
                    guard let route = renameTarget else { return }
                    perform { try model.rename(route, to: renameText) }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
    private func perform(_ work: () throws -> Void) {
        do { try work() } catch { show(error) }
    }
    private func show(_ error: Error) {
        errorMessage = error.localizedDescription
        isShowingError = true
    }
}

struct PlaybackOptionsView: View {
    @Bindable var simulation: WalkingSimulationController
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Speed: \(simulation.speedKMH, specifier: "%.1f") km/h")
                .font(.subheadline.monospacedDigit())
            Slider(value: $simulation.speedKMH, in: 0.1...50, step: 0.1)
                .accessibilityLabel("Speed in kilometres per hour")
            Text("Speed variation: \(simulation.speedVariationPercent, specifier: "%.0f")%")
                .font(.caption)
            Slider(value: $simulation.speedVariationPercent, in: 0...50, step: 1)
                .accessibilityLabel("Random speed variation percentage")
            Toggle("Loop by walking back and forth", isOn: $simulation.loopRoute)
                .font(.subheadline)
            if let notice = simulation.interruptionNotice {
                Text(notice).font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

struct IFakeRoutePlaybackCard: View {
    @Environment(AppModel.self) private var appModel
    let simulation: WalkingSimulationController
    let onStop: () -> Void
    let onClose: () -> Void
    @State private var isConfirmingStop = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(simulation.destination?.name ?? "GPX route").font(.headline)
                Text(status).font(.subheadline)
                ProgressView(value: simulation.progress)
                Text("\(simulation.distanceTravelled, specifier: "%.0f") / \(simulation.totalDistance, specifier: "%.0f") m")
                    .font(.caption.monospacedDigit())
                PlaybackOptionsView(simulation: simulation)
                HStack {
                    if simulation.phase == .idle {
                        Button("Start route") { Task { await simulation.start(using: appModel) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(!isPaired)
                        Button("Close", action: onClose)
                    } else if simulation.phase == .walking || simulation.phase == .paused {
                        Button(simulation.phase == .paused ? "Resume" : "Pause", action: simulation.togglePause)
                            .buttonStyle(.borderedProminent)
                    }
                    if simulation.phase != .idle {
                        Button("Stop & Restore", role: .destructive) { isConfirmingStop = true }
                            .disabled(simulation.phase == .stopping)
                    }
                }
                Text("A stopped or suspended app does not guarantee continued movement. After a process restart, restore location before restarting this GPX route.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(18)
        }
        .frame(maxHeight: 390)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .confirmationDialog("Stop the route and restore real location?", isPresented: $isConfirmingStop,
                            titleVisibility: .visible) {
            Button("Stop & Restore", role: .destructive, action: onStop)
            Button("Cancel", role: .cancel) {}
        }
    }
    private var isPaired: Bool { if case .paired = appModel.pairingStatus { return true }; return false }
    private var status: String {
        switch simulation.phase {
        case .idle: "Ready - starting sets this iPhone to the route's first point"
        case .preparing: "Connecting"
        case .walking: "Walking"
        case .paused: "Paused"
        case .arrived: "Arrived - simulated location is still active"
        case .stopping: "Restoring real location"
        case .failed(let message): message
        }
    }
}
