import unittest
from pathlib import Path
from prepare_app import patch_home
from phase2 import patch_home_v2, patch_recovery, patch_callback

ROOT = Path(__file__).resolve().parents[1]
UPSTREAM = ROOT / 'Upstream/RoamControl/RoamControl'

@unittest.skipUnless(UPSTREAM.is_dir(), 'Full integration tests need the pinned submodule')
class Phase2Tests(unittest.TestCase):
    def home(self):
        return patch_home_v2(patch_home((UPSTREAM/'Features/Home/HomeView.swift').read_text()))

    def test_full_home_has_visible_feature_entries(self):
        text = self.home()
        for name in ['Button("Bookmarks"', 'Button("Routes"', 'WaypointEditorView(', 'BookmarksView(']:
            self.assertIn(name, text)
        self.assertNotIn('accessibilityLabel("iFakeGPS route library")', text)

    def test_preview_does_not_start_a_device_session(self):
        text = self.home().split('private func previewEditedRoute')[1].split('private var needsPairingPrompt')[0]
        self.assertIn('prepare(savedRoute:', text)
        self.assertNotIn('startLocationSession', text)
        self.assertIn('boundingMapRect', text)

    def test_home_fails_closed_on_repeated_patch(self):
        with self.assertRaises(RuntimeError):
            patch_home_v2(self.home())

    def test_recovery_preserves_legacy_bookmark_storage(self):
        original = (UPSTREAM/'App/AppModel.swift').read_text()
        text = patch_recovery(original)
        self.assertIn('private static let favouritesKey = "favouriteLocations"', text)
        self.assertIn('self.favouriteLocations = Self.locations(forKey: Self.favouritesKey', text)
        method = text.split('func preserveEditedRouteRecovery')[1].split('private func persistActiveSessionRecovery')[0]
        self.assertIn('activeSessionRecovery = .fixed(at: target)', method)
        self.assertNotIn('deviceSession.start', method)
        with self.assertRaises(RuntimeError):
            patch_recovery(text)

    def test_bookmark_save_is_not_a_removal_toggle(self):
        source = (ROOT/'Integration/BookmarksView.swift').read_text()
        self.assertIn('if isFavourite(target) { renameFavourite', source)
        self.assertIn('else { toggleFavourite(target) }', source)
        self.assertNotIn('UserDefaults', source)

    def test_planning_cancels_and_checks_snapshot(self):
        source = (ROOT/'Integration/WaypointEditorView.swift').read_text()
        for guard in ['planningID == requestID', 'simulation.editToken == token', 'model.draft.points == snapshot', 'Task.checkCancellation()']:
            self.assertIn(guard, source)
        self.assertIn('.onDisappear { task?.cancel()', source)

    def test_keychain_and_no_redirect_policy(self):
        source = (ROOT/'Integration/RoadPlanningService.swift').read_text()
        self.assertIn('kSecAttrAccessibleWhenUnlockedThisDeviceOnly', source)
        self.assertIn('completionHandler(nil)', source)
        self.assertNotIn('UserDefaults', source)

    def test_callback_scheme_is_independent_and_complete(self):
        original = (UPSTREAM/'Services/Tunnel/LocalDeviceSessionCoordinator.swift').read_text()
        text = patch_callback(original)
        self.assertIn('localdevvpn://enable?scheme=ifakegps-ios', text)
        self.assertIn('url.scheme?.lowercased() == "ifakegps-ios"', text)
        self.assertNotIn('scheme=roamcontrol', text)
        with self.assertRaises(RuntimeError):
            patch_callback(text)

    def test_smoke_hooks_are_debug_only(self):
        text = self.home()
        before, after = text.split('_isShowingBookmarks = State(initialValue: ProcessInfo')
        self.assertGreater(before.rfind('#if DEBUG'), before.rfind('#endif'))
        self.assertIn('#endif', after)

if __name__ == '__main__':
    unittest.main()
