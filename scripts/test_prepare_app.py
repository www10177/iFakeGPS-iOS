import unittest
from prepare_app import replace_once, patch_home


class IntegrationTests(unittest.TestCase):
    def test_replace_exactly_once(self):
        self.assertEqual(replace_once("before A after", "A", "B"), "before B after")

    def test_missing_anchor_fails_closed(self):
        with self.assertRaises(RuntimeError):
            replace_once("unrelated upstream", "expected", "replacement")

    def test_duplicate_anchor_fails_closed(self):
        with self.assertRaises(RuntimeError):
            replace_once("A A", "A", "B")

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
