# iFakeGPS-iOS

An independent, noncommercial iPhone location-testing app based on a pinned
Roam Control Build 61 and iFakeGPS route functionality.

## Current work

The GPX/route-library baseline (PR #1) is merged into `main`.
The **0.2.0 / build 2 changes** add visible bookmarks,
multi-waypoint editing, dynamic tail append, road-provider selection and
English/Traditional Chinese feature interfaces.

**Local tests pass. Check the pull request checks for the current commit's
Xcode archive and simulator results; real-device acceptance is still pending.**
See `Documentation/PHASE2.md` for limitations and device acceptance steps.

## Features in the second-stage source

Bookmarks save and organize named coordinates using the existing favourites
storage. Choose a bookmark to preview it, or append it to a draft/active route.
The main map has labelled Bookmarks, Routes and Edit route entries.

The editor supports map taps, coordinate/name edits, bookmark insertion,
reordering, deletion, reversal, preview and saved routes. Dynamic append extends
only the existing route endpoint without resetting already-travelled distance.
GPX import/export, speed variation and ping-pong playback remain available.

Offline planning connects points directly. Online planning supports Apple Maps
walking, OSRM driving, and OpenRouteService walking/cycling/driving, with explicit
coordinate-sharing confirmation. ORS keys are stored in device-only Keychain.

## Requirements and building

The app requires iOS 27+, Developer Mode, LocalDevVPN and sideload signing.
The core Swift package can be tested on Linux; the iOS app requires Xcode 27.

```sh
git submodule update --init --recursive
swift test
swift test -c release
python3 -m unittest discover -s scripts -p 'test_*.py'
# macOS + Xcode 27:
bash scripts/build_ipa.sh
```

The build script creates `.generated/RoamControl` from the exact reviewed upstream
and applies the tracked overlays. Do not build `Upstream/RoamControl` directly:
that is the unmodified upstream project. Successful packaging outputs
`dist/iFakeGPS-iOS-unsigned.ipa`; signing occurs during sideloading.

This source retains the existing bundle ID for upgrades and introduces the
independent `ifakegps-ios` callback scheme. Callback routing is not yet verified
on a physical iPhone. The original icon and portions of the legacy help/interface
remain; new features have Traditional Chinese localization.

## Upstream and licence

Upstream is fixed at tag `v0.9.2-preview-build.61`, commit
`19b596e737639a7a7089b7d476eee848a3255559`, with its PolyForm Noncommercial 1.0.0
licence and required notices. Do not update to a later upstream commit without
reviewing its different licence. The build refuses changed pins or licence blobs.
See `LICENSE`, `NOTICE`, `upstream.lock.json`, and the pinned upstream notices.
The desktop `www10177/iFakeGPS` repository is unchanged.

Use only on a device you own/control. Restore real location before navigation,
emergency or safety-sensitive use. A successful compile is not proof that the
physical location service, background behavior or restoration works correctly.
