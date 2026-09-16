import unittest
from prepare_app import replace_once, patch_home, patch_update_checker


class IntegrationTests(unittest.TestCase):
    def test_replace_exactly_once(self):
        self.assertEqual(replace_once("before A after", "A", "B"), "before B after")

    def test_missing_anchor_fails_closed(self):
        with self.assertRaises(RuntimeError):
            replace_once("unrelated upstream", "expected", "replacement")

    def test_duplicate_anchor_fails_closed(self):
        with self.assertRaises(RuntimeError):
            replace_once("A A", "A", "B")

    def test_release_checker_targets_this_repo_only(self):
        original = 'let url = "https://api.github.com/repos/seanhowarthdev/Roam-Control/releases/latest"'
        patched = patch_update_checker(original)
        self.assertIn("www10177/iFakeGPS-iOS/releases/latest", patched)
        self.assertNotIn("seanhowarthdev/Roam-Control", patched)
        with self.assertRaises(RuntimeError):
            patch_update_checker(patched)

    def test_home_patch_requires_exact_pinned_structure(self):
        text = "\n".join([
            "    @State private var isShowingSavedPlaces = false",
            "                    if let route = walkingRoutePlanner.route {\n                        MapPolyline(route)",
            "                    HStack(spacing: 10) {\n                        Button {\n                            isShowingSavedPlaces = true",
            "                    } else if let route = walkingRoutePlanner.route,",
            "        .sheet(isPresented: $isShowingSavedPlaces) {",
        ])
        patched = patch_home(text)
        self.assertIn("RouteLibraryView(simulation:", patched)
        self.assertIn("IFakeRoutePlaybackCard(simulation:", patched)
        self.assertIn("walkingSimulation.customPolyline", patched)
        with self.assertRaises(RuntimeError):
            patch_home(patched)


if __name__ == "__main__":
    unittest.main()
