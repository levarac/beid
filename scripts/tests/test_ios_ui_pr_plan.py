"""Release pull requests choose coverage from pinned paths before the build."""

import json
import unittest

from scripts.ios_ui_pr_plan import execution_plan
from scripts.ios_ui_smoke import DEFAULT_DURATIONS


class ExecutionPlanTest(unittest.TestCase):
    def plan(self, paths, *, weights=None, base="release/1.1.0", head="feat/ui", initial="smoke"):
        payload = {"pull_request": {"base": {"ref": base}, "head": {"ref": head}}}
        return execution_plan(initial, "pull_request", payload, {"files": paths}, 5, weights)

    def test_real_screen_weights_and_account_under_budget(self):
        for name, expected in (("AccountSheetView", "full"), ("OrganizerToolsView", "selected"),
                               ("ItemDetailView", "full"), ("CollectionHomeView", "full")):
            with self.subTest(name=name):
                plan = self.plan([f"ios/Beid/Views/{name}.swift"])
                self.assertEqual(plan["mode"], expected)
        weights = {test: 1 for test in json.loads(DEFAULT_DURATIONS.read_text())["seconds"]}
        plan = self.plan(["ios/Beid/Views/AccountSheetView.swift"], weights=weights)
        self.assertEqual(plan["mode"], "selected")
        self.assertEqual(plan["matrix"]["lane"], ["ui-1"])
        self.assertGreater(len(plan["proposal"]["candidates"]), 12)

    def test_unchanged_event_modes_and_conservative_fallback(self):
        screen = ["ios/Beid/Views/OrganizerToolsView.swift"]
        self.assertEqual(self.plan(screen, base="main")["mode"], "smoke")
        self.assertEqual(self.plan(screen, initial="full")["mode"], "full")
        self.assertEqual(self.plan(screen, head="ship/v1")["mode"], "full")
        for paths in ([], ["shared/src/file.kt"], ["ios/Beid/Views/Unknown.swift"]):
            self.assertEqual(self.plan(paths)["mode"], "full")
        self.assertEqual(self.plan(["android/app/src/Foo.kt"])["mode"], "smoke")

    def test_minimum_count_uses_the_same_weights_as_the_manifest(self):
        weights = dict.fromkeys(json.loads(DEFAULT_DURATIONS.read_text())["seconds"], 25)
        result = self.plan(["ios/Beid/Views/AccountSheetView.swift"], weights=weights)
        self.assertEqual(result["matrix"]["lane"], ["ui-1", "ui-2"])
        proposal = result["proposal"]
        self.assertGreater(sum(proposal["planned_seconds"]), 1200)
        self.assertLessEqual(max(proposal["planned_seconds"]), 1200)
        self.assertEqual(sorted(sum(proposal["shards"], [])), proposal["candidates"])
        self.assertEqual(set(proposal["matched_reasons"]), set(proposal["candidates"]))
