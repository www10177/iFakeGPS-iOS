# Bookmarks and waypoint editing (0.2.0 / build 2)

## Delivery status

PR #1 was merged into main at `03dec957f8e31fcdef628902d6b3889069ca0717`.
This change set is based on feature-branch commit `e12ba8add4f02fa1bf7b1571e7cf05d7a446a667`.

These changes are submitted on `feat/bookmarks-waypoint-editor` for review.
The initial delivery was a local patch; the pull request contains the feature
implementation, not only the earlier source-snapshot preparation workflow.
See the checks on the current PR commit for Xcode archive and simulator status.

Local results: 36 Swift tests in Debug and Release, 14 Python integration tests,
Swift syntax parsing, shell syntax checks and patch-application validation.
The CI checks perform full iOS type-check/archive and simulator screen launches.
Those checks do not establish real-device installation, Keychain behavior,
provider availability, background continuity or actual GPS delivery.

## User-visible features

- Labelled Bookmarks / Routes / Edit route buttons on the main map.
- Bookmarks: save a selected location or enter coordinates; name, search, rename,
  reorder, delete, preview, add to a draft or append to the current route.
- Bookmarks reuse the existing `favouriteLocations` store; saving the exact same
  coordinates renames the existing bookmark instead of removing it.
- Draft editor: tap the map, add bookmarked locations, edit coordinates and names,
  reorder/delete/reverse points, preview and save. Up to 200 draft waypoints.
- Active append: extends only the route tail. Current distance, position and
  ping-pong direction are preserved. After arrival, appending pauses until Resume.
- Offline direct geometry, Apple walking, OSRM driving, and ORS walking/cycling/
  driving. Online requests require confirmation; ORS requires the user's API key.
- ORS credentials use device-only Keychain storage; HTTP redirects are rejected.
- 95 English/Traditional Chinese string entries for the added interfaces and
  selected existing controls. This is not a complete legacy-interface translation.
- Independent `ifakegps-ios` callback scheme, keeping the existing bundle ID.
  The original pairing wire protocol and native framework remain unchanged.

## Limitations and acceptance checks

The source still targets iOS 27+, Developer Mode and LocalDevVPN. Use a signing
and sideloading workflow appropriate for your own device. The original icon and
some upstream onboarding/help text remain. Existing required notices are retained.

Drafts live in memory while the app runs; save a route before terminating the app.
An app restart does not automatically replay or recover the full edited geometry.
After a dynamic edit, recovery uses a fixed position, never an unrelated replanned
Apple Maps route. The route's first point is applied only after explicit Start.

Online planning accepts up to 50 input waypoints. GPX/generated geometry retains
the 50,000-point cap. Road snapping can create short straight endpoint connectors;
review the preview before starting. The default OSRM service is driving only.
No live ORS request was made with a user credential, and provider availability,
quota and network behavior still require testing. API keys and coordinates must
not be included in issue reports or CI fixtures.

Device acceptance should cover: upgrade preservation of bookmarks; duplicate save;
filtered delete and reorder; draft edit/reverse; offline and online planning;
cancellation during requests; append while walking, paused, arrived and returning;
Stop & Restore; lock screen/background interruptions; independent VPN callback;
side-by-side callback routing with the original app; and application restart.

## Build and verify

Run `swift test`, `swift test -c release`, and
`python3 -m unittest discover -s scripts -p 'test_*.py'`.

On macOS with Xcode 27, run `bash scripts/build_ipa.sh` for an unsigned IPA.
`bash scripts/ui_smoke.sh` builds and launches Debug simulator screens; the UI
fixtures and startup hooks are behind `#if DEBUG` and do not enter Release builds.
The updated CI includes this smoke job; review its result for the exact commit
you intend to install. Do not substitute an earlier build's green checks.
