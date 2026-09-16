#!/usr/bin/env python3
"""Materialize a build-only copy of the pinned upstream, then apply reviewed overlays.

Only tracked files from the exact upstream commit are copied. Local signing
configuration, later upstream revisions, and untracked files are never imported.
"""
from pathlib import Path
import json
import plistlib
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def replace_once(text: str, old: str, new: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"Expected one integration anchor, found {count}: {old[:90]!r}")
    return text.replace(old, new, 1)


def patch_home(text: str) -> str:
    text = replace_once(text, "    @State private var isShowingSavedPlaces = false",
                        "    @State private var isShowingSavedPlaces = false\n"
                        "    @State private var isShowingRouteLibrary = false")
    text = replace_once(text,
        "                    if let route = walkingRoutePlanner.route {\n                        MapPolyline(route)",
        "                    if let polyline = walkingSimulation.customPolyline {\n"
        "                        MapPolyline(polyline).stroke(.orange, lineWidth: 6)\n"
        "                    }\n"
        "                    if let route = walkingRoutePlanner.route {\n                        MapPolyline(route)")
    text = replace_once(text,
        "                    HStack(spacing: 10) {\n                        Button {\n                            isShowingSavedPlaces = true",
        "                    HStack(spacing: 10) {\n"
        "                        Button { isShowingRouteLibrary = true } label: {\n"
        "                            Image(systemName: \"point.topleft.down.to.point.bottomright.curvepath\")\n"
        "                                .frame(width: 44, height: 44)\n"
        "                                .background(.regularMaterial, in: Circle())\n"
        "                        }.accessibilityLabel(\"iFakeGPS route library\")\n"
        "                        Button {\n                            isShowingSavedPlaces = true")
    text = replace_once(text,
        "                    } else if let route = walkingRoutePlanner.route,",
        "                    } else if walkingSimulation.isCustomRoute {\n"
        "                        IFakeRoutePlaybackCard(simulation: walkingSimulation, onStop: {\n"
        "                            shouldClearLocationAfterRestoration = true\n"
        "                            walkingSimulation.stop(using: appModel.deviceSession)\n"
        "                        }, onClose: {\n"
        "                            walkingSimulation.reset()\n"
        "                            walkingRoutePlanner.clear()\n"
        "                        })\n"
        "                    } else if let route = walkingRoutePlanner.route,")
    return replace_once(text, "        .sheet(isPresented: $isShowingSavedPlaces) {",
        "        .sheet(isPresented: $isShowingRouteLibrary) {\n"
        "            RouteLibraryView(simulation: walkingSimulation) { route in\n"
        "                guard !walkingSimulation.locksDestination else { return }\n"
        "                try walkingSimulation.prepare(savedRoute: route)\n"
        "                walkingRoutePlanner.clear()\n"
        "                if let target = walkingSimulation.destination { mapModel.show(target) }\n"
        "                isShowingRouteLibrary = false\n"
        "            }\n"
        "        }\n"
        "        .sheet(isPresented: $isShowingSavedPlaces) {")


def prepare(root: Path = ROOT) -> Path:
    lock = json.loads((root / "upstream.lock.json").read_text())
    upstream = root / "Upstream/RoamControl"
    def git(*args: str) -> str:
        return subprocess.check_output(["git", "-C", str(upstream), *args], text=True).strip()
    if not (upstream / "RoamControl.xcodeproj").is_dir():
        raise RuntimeError("Initialize the pinned dependency: git submodule update --init --recursive")
    if git("rev-parse", "HEAD") != lock["commit"]:
        raise RuntimeError("Upstream commit differs from the reviewed Build 61 pin. Refusing to import it.")
    if git("status", "--porcelain", "--untracked-files=no"):
        raise RuntimeError("The upstream submodule has tracked changes. Keep modifications in Integration/.")
    if git("hash-object", "LICENSE") != lock["license_blob"]:
        raise RuntimeError("Upstream license does not match the reviewed PolyForm Noncommercial license.")

    generated = root / ".generated"
    target = generated / "RoamControl"
    if generated.is_symlink() or target.is_symlink():
        raise RuntimeError("Generated build directories must not be symlinks.")
    if target.exists():
        shutil.rmtree(target)
    target.mkdir(parents=True)
    files = subprocess.check_output(["git", "-C", str(upstream), "ls-files", "-z"]).decode().split("\0")
    for relative in filter(None, files):
        source = upstream / relative
        if source.is_symlink() or not source.is_file() or ".." in Path(relative).parts or Path(relative).is_absolute():
            raise RuntimeError(f"Unexpected tracked file: {relative}")
        destination = target / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)

    home = target / "RoamControl/Features/Home/HomeView.swift"
    home.write_text(patch_home(home.read_text()))
    preview = target / "RoamControl/Features/Map/WalkingRoutePreviewCard.swift"
    preview.write_text(replace_once(preview.read_text(),
        "            if canChoosePace {\n                pacePicker\n            }",
        "            if canChoosePace {\n                PlaybackOptionsView(simulation: simulation)\n            }"))
    shutil.copy2(root / "Integration/WalkingSimulationController.swift",
                 target / "RoamControl/Features/Map/WalkingSimulationController.swift")
    feature = target / "RoamControl/IFakeGPS"
    feature.mkdir()
    shutil.copy2(root / "Integration/RouteLibraryView.swift", feature / "RouteLibraryView.swift")
    for source in (root / "Sources/RouteCore").glob("*.swift"):
        shutil.copy2(source, feature / source.name)

    project = target / "RoamControl.xcodeproj/project.pbxproj"
    settings = project.read_text()
    for old, new in [("com.sean.roamcontrol", "com.www10177.ifakegps.ios"),
                     ("MARKETING_VERSION = 0.9.2;", "MARKETING_VERSION = 0.1.0;"),
                     ("CURRENT_PROJECT_VERSION = 61;", "CURRENT_PROJECT_VERSION = 1;")]:
        if settings.count(old) != 2:
            raise RuntimeError(f"Unexpected Xcode setting count: {old}")
        settings = settings.replace(old, new)
    project.write_text(settings)

    info = target / "Configuration/RoamControl-Info.plist"
    values = plistlib.loads(info.read_bytes())
    values["CFBundleDisplayName"] = "iFakeGPS"
    # No upstream analytics destination or credential is retained, even if consent is enabled.
    for key in ["RoamControlTelemetryAppID", "RoamControlTelemetryNamespace",
                "RoamControlSelfHostedTelemetryEndpoint", "RoamControlSelfHostedTelemetryToken"]:
        values[key] = ""
    values["UTImportedTypeDeclarations"] = [{
        "UTTypeIdentifier": "com.topografix.gpx",
        "UTTypeDescription": "GPS Exchange Format",
        "UTTypeConformsTo": ["public.xml"],
        "UTTypeTagSpecification": {"public.filename-extension": ["gpx"],
                                   "public.mime-type": ["application/gpx+xml"]}}]
    info.write_bytes(plistlib.dumps(values, sort_keys=False))
    # Existing callback scheme and pairing internals remain unchanged intentionally.
    # Do not install upstream Roam Control alongside this first-stage build.
    notices = [(target / name).read_text() for name in
               ["LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md"]]
    sources = list((target / "ThirdParty").rglob("*"))
    sources += list((target / "Documentation/Licensing").rglob("*"))
    for source in sorted(sources):
        if source.is_file():
            notices.append(f"\n--- {source.relative_to(target)} ---\n{source.read_text()}")
    (feature / "UpstreamLicenses.txt").write_text("\n".join(notices))
    (generated / "provenance.json").write_text(json.dumps(lock, indent=2) + "\n")
    return target


if __name__ == "__main__":
    try:
        print(prepare())
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"prepare_app: {error}", file=sys.stderr)
        sys.exit(1)
