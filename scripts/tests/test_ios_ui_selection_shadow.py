import json
import tempfile
import unittest
from pathlib import Path

from scripts import ios_ui_selection_shadow as shadow
from scripts.ios_ui_smoke import source_tests
from scripts.tests.workflow_yaml import workflow_data


UI = "BeidUITests/"
SMOKE = UI + "FlatScreenshotTourB/testShot_04b_Empty"
CAMERA = UI + "FlatScreenshotTourD/testShot_14f3_CameraCouldNotStart"
SKIP = UI + "BeidIPadLayoutTests/testPrimaryFlowInLandscape"
ROOT = Path("ios/BeidUITests")
HISTORIES = json.loads((Path(__file__).parent / "fixtures/ios-ui-selection-pr-paths.json").read_text())


class ShadowSelectionTests(unittest.TestCase):
    def setUp(self):
        self.ui = source_tests(ROOT)
        self.manifest = {"mode": "full", "sha": "abc", "ui": self.ui, "smoke": [SMOKE],
                         "iphone_skips": [SKIP], "shards": [self.ui[::2], self.ui[1::2]]}
        self.weights = {test: 1 for test in self.ui}

    def select(self, paths, **extra):
        return shadow.propose({"files": paths, **extra}, self.manifest, self.weights)

    def test_known_screen_and_test_only_histories(self):
        account = self.select(HISTORIES["873"]["files"])
        self.assertEqual(account["mode"], "selected")
        self.assertIn(SMOKE, account["candidates"])
        self.assertIn(CAMERA, account["candidates"])
        self.assertIn(SKIP, account["candidates"])
        small = self.select(HISTORIES["891"]["files"])
        self.assertNotIn(CAMERA, small["candidates"])
        self.assertEqual(small["extra_seconds"], len(set(small["candidates"]) - {SMOKE, SKIP}))
        self.weights = dict.fromkeys(self.ui, 100)
        large = self.select(HISTORIES["891"]["files"])
        self.assertEqual(large["mode"], "full")
        self.assertNotIn(CAMERA, large["matched"])
        self.assertIn(CAMERA, large["candidates"])

    def test_account_change_selects_every_class_using_account_identifiers(self):
        result = self.select(["ios/Beid/Views/AccountSheetView.swift"])
        self.assertEqual(result["mode"], "selected")
        suites = {test.split("/")[1] for test in result["matched"]}
        for suite in ("SupportBundleUITests", "AdaptiveContinuityUITests", "FlatScreenshotTourA",
                      "FlatScreenshotTourD", "EventMembershipUITests"):
            self.assertIn(suite, suites)

    def test_uncertain_or_shared_changes_cover_runtime_inventory(self):
        # #907 touched both screen code and shared navigation.
        for payload in ({"files": HISTORIES["907"]["files"]},
                        {"files": HISTORIES["871"]["files"]}, {"files": HISTORIES["873"]["files"], "ios_force_run": True},
                        {"files": []}, {}, {"error": "compare failed"},
                        {"files": ["ios/BeidUITests/UITestWait.swift"]}):
            with self.subTest(payload=payload):
                result = shadow.propose(payload, self.manifest, self.weights)
                self.assertEqual(result["candidates"], self.ui)
                self.assertEqual(result["mode"], "full")
                self.assertTrue(result["reasons"])

    def test_shared_changes_preserve_screen_matches_before_full_fallback(self):
        result = self.select(HISTORIES["907"]["files"])
        self.assertEqual(result["mode"], "full")
        self.assertIn(CAMERA, result["candidates"])
        self.assertNotIn(CAMERA, result["matched"])
        self.assertIn(SMOKE, result["matched"])

    def test_changed_file_includes_both_test_classes(self):
        result = self.select(["ios/BeidUITests/NearbyJoinUITests.swift"])
        for suite in ("NearbyJoinUITests", "NowNavigationUITests"):
            cases = {test for test in self.ui if test.split("/")[1] == suite}
            self.assertTrue(cases)
            self.assertLessEqual(cases, set(result["candidates"]))

    def test_optional_report_runs_after_full_tests_including_failures(self):
        jobs = workflow_data(Path(".github/workflows/pr-ci-ios-macos.yml").read_text())["jobs"]
        advisory = jobs["selection-shadow"]
        self.assertIn("always()", advisory["if"])
        self.assertIn("needs.plan.outputs.mode == 'full'", advisory["if"])
        self.assertIn("tests", advisory["needs"])
        for name, job in jobs.items():
            if name != "selection-shadow":
                self.assertNotIn("selection-shadow", job.get("needs", []))
        self.assertEqual(jobs["changes"]["outputs"]["shadow_paths"], "${{ steps.shadow_paths.outputs.json }}")
        self.assertEqual(advisory["steps"][-1]["with"]["name"], "ios-ui-selection-${{ github.run_attempt }}")

    def test_failed_ids_survive_partial_results_and_reruns(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            selection = self.select(HISTORIES["891"]["files"])
            self.manifest.update(ui=[CAMERA, SMOKE], shards=[[CAMERA], [SMOKE]])
            def artifact(attempt, shard, test, outcome):
                folder = root / f"ios-evidence-{attempt}-{shard}"
                folder.mkdir()
                (folder / "manifest.json").write_text(json.dumps(self.manifest))
                tree = {"testNodes": [{"nodeType": "Test Plan", "children": [
                    {"nodeType": "Unit test bundle", "name": "BeidUITests", "children": [
                        {"nodeType": "Test Case", "nodeIdentifier": test.removeprefix(UI) + "()",
                         "result": outcome}]}]}]}
                (folder / "test-tree.json").write_text(json.dumps(tree))
            artifact(1, "ui-1", CAMERA, "Passed")
            artifact(2, "ui-1", CAMERA, "Failed")
            artifact(1, "ui-2", SMOKE, "Passed")
            result = shadow.observe(root, self.manifest, 2, 2, selection)
            self.assertEqual(result["failed_outside_candidates"], [CAMERA])
            self.assertEqual(result["unavailable_shards"], ["ui-2"])
            self.assertFalse(result["complete_ui_evidence"])

            self.manifest["shards"] = [[CAMERA], [CAMERA]]
            with self.assertRaisesRegex(ValueError, "shard union"):
                shadow.observe(root, self.manifest, 2, 2, selection)
