"""Second-stage overlays. All edits fail closed if the pinned anchors change."""
from pathlib import Path
import shutil
import plistlib
from prepare_app import replace_once


def patch_home_v2(text: str) -> str:
    text = replace_once(text, "    @State private var isShowingRouteLibrary = false", """    @State private var isShowingRouteLibrary = false
    @State private var isShowingBookmarks = false
    @State private var isShowingWaypointEditor = false
    @State private var waypointEditor = WaypointEditorModel()
    @State private var waypointError: String?
""")
    text = replace_once(text, "                .disabled(walkingSimulation.locksDestination)", """                .disabled(walkingSimulation.locksDestination)

                HStack {
                    Button("Bookmarks", systemImage: "bookmark.fill") { isShowingBookmarks = true }
                    Spacer(minLength: 4)
                    Button("Routes", systemImage: "point.topleft.down.to.point.bottomright.curvepath") { isShowingRouteLibrary = true }
                    Spacer(minLength: 4)
                    Button(LocalizedStringKey(walkingSimulation.canAppendWaypoints ? "Append waypoints" : "Edit route"), systemImage: "point.3.connected.trianglepath.dotted") { isShowingWaypointEditor = true }
                        .disabled(walkingSimulation.locksDestination && !walkingSimulation.canAppendWaypoints)
                }
                .font(.subheadline)
                .buttonStyle(.bordered)
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))

                if mapModel.selectedLocation != nil && !walkingSimulation.locksDestination {
                    Button("Add selected point to draft", systemImage: "plus.circle") {
                        guard let target = mapModel.selectedLocation else { return }
                        do { try waypointEditor.add(target); isShowingWaypointEditor = true }
                        catch { waypointError = error.localizedDescription }
                    }
                    .buttonStyle(.borderedProminent)
                }
""")
    # A text-labelled Routes entry replaces the first-stage unlabelled shortcut.
    text = replace_once(text, """                        Button { isShowingRouteLibrary = true } label: {
                            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                                .frame(width: 44, height: 44)
                                .background(.regularMaterial, in: Circle())
                        }.accessibilityLabel("iFakeGPS route library")
""", "")
    text = replace_once(text, "        .sheet(isPresented: $isShowingRouteLibrary) {", """        .onChange(of: walkingSimulation.isCustomRoute) { _, custom in
            if custom { walkingRoutePlanner.clear() }
        }
        .alert("Route error", isPresented: Binding(get: { waypointError != nil }, set: { if !$0 { waypointError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(waypointError ?? "") }
        .sheet(isPresented: $isShowingBookmarks) {
            BookmarksView(selectedLocation: mapModel.selectedLocation,
                canSelect: !walkingSimulation.locksDestination,
                appendLabel: walkingSimulation.canAppendWaypoints ? "Append to active route" : "Add to draft",
                canAppend: !walkingSimulation.locksDestination || walkingSimulation.canAppendWaypoints,
                onSelect: { target in
                    guard !walkingSimulation.locksDestination else { return }
                    walkingSimulation.reset()
                    walkingRoutePlanner.clear()
                    mapModel.show(target)
                }, onAppend: { target in
                    if walkingSimulation.canAppendWaypoints {
                        try walkingSimulation.appendWaypoints([RouteCoordinate(target)], using: appModel)
                        walkingRoutePlanner.clear()
                    } else {
                        guard !walkingSimulation.locksDestination else { throw RouteError.invalid("Stop the current session first.") }
                        try waypointEditor.add(target)
                    }
                })
        }
        .sheet(isPresented: $isShowingWaypointEditor) {
            WaypointEditorView(model: waypointEditor, simulation: walkingSimulation, onUse: previewEditedRoute)
        }
        .sheet(isPresented: $isShowingRouteLibrary) {""")
    text = replace_once(text, """                guard !walkingSimulation.locksDestination else { return }
                try walkingSimulation.prepare(savedRoute: route)
                walkingRoutePlanner.clear()
                if let target = walkingSimulation.destination { mapModel.show(target) }
                isShowingRouteLibrary = false""", """                try previewEditedRoute(route)
                isShowingRouteLibrary = false""")
    text = replace_once(text, "    private var needsPairingPrompt: Bool {", """    private func previewEditedRoute(_ route: SavedRoute) throws {
        guard !walkingSimulation.locksDestination else { throw RouteError.invalid("Stop the current route before replacing it.") }
        try walkingSimulation.prepare(savedRoute: route)
        walkingRoutePlanner.clear()
        if let target = walkingSimulation.destination { mapModel.show(target) }
        if let polyline = walkingSimulation.customPolyline {
            mapModel.cameraPosition = .rect(polyline.boundingMapRect)
        }
    }

    private var needsPairingPrompt: Bool {""")
    # UI smoke launch hooks are compiled only in Debug, never in the IPA Release.
    text = replace_once(text, "        _isShowingSettings = State(initialValue: showSettingsInitially)", """        _isShowingSettings = State(initialValue: showSettingsInitially)
#if DEBUG
        _isShowingBookmarks = State(initialValue: ProcessInfo.processInfo.arguments.contains("--show-bookmarks"))
        _isShowingWaypointEditor = State(initialValue: ProcessInfo.processInfo.arguments.contains("--show-route-editor"))
#endif""")
    text = replace_once(text, "            await appModel.restorePairingStatus()", """#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-smoke") {
                let sample = LocationTarget(name: "Sample bookmark", subtitle: "UI test fixture",
                    latitude: 25.033, longitude: 121.565)
                if let point = try? NamedWaypoint(name: sample.name, coordinate: RouteCoordinate(sample)) {
                    appModel.saveBookmark(point)
                }
                try? waypointEditor.add(sample)
                try? waypointEditor.add(LocationTarget(name: "Waypoint 2", subtitle: "UI test fixture",
                    latitude: 25.035, longitude: 121.568))
                mapModel.show(sample)
                return
            }
#endif
            await appModel.restorePairingStatus()""")
    return text


def patch_recovery(text: str) -> str:
    if "func preserveEditedRouteRecovery" in text:
        raise RuntimeError("Recovery overlay is already present.")
    return replace_once(text, "    private func persistActiveSessionRecovery(at target: LocationTarget) {", """    func preserveEditedRouteRecovery(at target: LocationTarget) {
        activeSessionRecovery = .fixed(at: target)
        lastRecoverySaveDate = nil
        persistActiveSessionRecovery(at: target)
    }

    private func persistActiveSessionRecovery(at target: LocationTarget) {""")


def patch_callback(text: str) -> str:
    text = replace_once(text, 'localdevvpn://enable?scheme=roamcontrol',
                        'localdevvpn://enable?scheme=ifakegps-ios')
    return replace_once(text, 'url.scheme?.lowercased() == "roamcontrol"',
                        'url.scheme?.lowercased() == "ifakegps-ios"')


def apply_phase2(target: Path, root: Path) -> None:
    app = target / "RoamControl"
    home = app / "Features/Home/HomeView.swift"
    home.write_text(patch_home_v2(home.read_text()))
    model = app / "App/AppModel.swift"
    model.write_text(patch_recovery(model.read_text()))
    for name in ["BookmarksView.swift", "RoadPlanningService.swift", "WaypointEditorView.swift"]:
        shutil.copy2(root / "Integration" / name, app / "IFakeGPS" / name)
    for locale in (root / "Integration/Localizations").glob("*.lproj"):
        shutil.copytree(locale, app / "Resources" / locale.name, dirs_exist_ok=True)
    project = target / "RoamControl.xcodeproj/project.pbxproj"
    text = project.read_text()
    for old, new in [("MARKETING_VERSION = 0.1.0;", "MARKETING_VERSION = 0.2.0;"),
                     ("CURRENT_PROJECT_VERSION = 1;", "CURRENT_PROJECT_VERSION = 2;")]:
        if text.count(old) != 2: raise RuntimeError(f"Unexpected version settings: {old}")
        text = text.replace(old, new)
    project.write_text(text)
    coordinator = app / "Services/Tunnel/LocalDeviceSessionCoordinator.swift"
    coordinator.write_text(patch_callback(coordinator.read_text()))
    info = target / "Configuration/RoamControl-Info.plist"
    values = plistlib.loads(info.read_bytes())
    callbacks = values.get("CFBundleURLTypes", [])
    if len(callbacks) != 1 or callbacks[0].get("CFBundleURLSchemes") != ["roamcontrol"]:
        raise RuntimeError("Unexpected upstream callback registration.")
    callbacks[0]["CFBundleURLSchemes"] = ["ifakegps-ios"]
    callbacks[0]["CFBundleURLName"] = "com.www10177.ifakegps.callback"
    values["CFBundleLocalizations"] = ["en", "zh-Hant"]
    info.write_bytes(plistlib.dumps(values, sort_keys=False))
    # Keep authorship, legal notices and pairing wire/protocol names intact.
    for relative in ["Features/Onboarding/OnboardingView.swift", "Features/Settings/SettingsView.swift"]:
        path = app / relative
        path.write_text(path.read_text().replace('"Roam Control"', '"iFakeGPS"'))
