"""The full-mode ledger must fail closed on incomplete distributed execution."""

import copy
import importlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from scripts.tests.test_ios_ui_smoke import ONE, TWO, tree

UNIT = "BeidTests/FlowTests/testUnit"
ROOT = Path(__file__).resolve().parents[2]


class ShardContractTest(unittest.TestCase):
    def setUp(self):
        self.tool = importlib.import_module("scripts.ios_ui_smoke")

    def test_new_test_has_one_shard_with_deterministic_balancing(self):
        self.assertTrue(hasattr(self.tool, "shard_tests"), "duration-based sharding is missing")
        tests = [f"BeidUITests/FlowTests/test{i}" for i in range(12)]
        durations = {test: 10.0 for test in tests[:-1]}
        shards = self.tool.shard_tests(tests, durations, 3)
        self.assertEqual(shards, self.tool.shard_tests(list(reversed(tests)), durations, 3))
        self.assertEqual(sorted(sum(shards, [])), sorted(tests))
        self.assertLessEqual(max(map(len, shards)) - min(map(len, shards)), 1)
        for count in (0, 1, 4):
            with self.assertRaises(ValueError):
                self.tool.shard_tests(tests, durations, count)
        with self.assertRaises(ValueError):
            self.tool.shard_tests([ONE, ONE], {}, 2)

    def test_runtime_enumeration_requires_both_bundles_and_no_duplicates(self):
        self.assertTrue(hasattr(self.tool, "parse_enumeration"), "runtime enumeration is missing")
        payload = {"values": [{"name": "Beid", "children": [
            {"name": bundle, "children": [{"name": "FlowTests", "children": [
                {"name": name, "children": []} for name in methods]}]}
            for bundle, methods in (("BeidTests", ["testUnit()"]),
                                    ("BeidUITests", ["testOne()", "testTwo()"]))]}], "errors": []}
        self.assertEqual(self.tool.parse_enumeration(payload),
                         {"BeidTests": [UNIT], "BeidUITests": [ONE, TWO]})
        for bad in ({}, {**payload, "errors": ["unable to enumerate"]}):
            with self.assertRaises(ValueError):
                self.tool.parse_enumeration(bad)
        duplicate = copy.deepcopy(payload)
        duplicate["values"][0]["children"][1]["children"][0]["children"].append({"name": "testOne()"})
        with self.assertRaises(ValueError):
            self.tool.parse_enumeration(duplicate)

    def test_shards_cli_covers_current_ui_sources_and_lane_arguments(self):
        inventory = self.tool.source_tests(ROOT / "ios/BeidUITests")
        classes = {}
        for test in inventory:
            _, suite, method = test.split("/")
            classes.setdefault(suite, []).append({"name": method + "()"})
        payload = {"values": [{"name": "Beid", "children": [
            {"name": "BeidTests", "children": [{"name": "FlowTests", "children": [{"name": "testUnit()"}]}]},
            {"name": "BeidUITests", "children": [
                {"name": suite, "children": methods} for suite, methods in classes.items()]}]}]}
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            enum, manifest = root / "enumerated.json", root / "manifest.json"
            enum.write_text(json.dumps(payload))
            for count in (2, 3):
                result = subprocess.run([sys.executable, "-m", "scripts.ios_ui_smoke", "shards",
                    "--enumeration", str(enum), "--output", str(manifest), "--count", str(count),
                    "--mode", "full", "--sha", "a" * 40], cwd=ROOT, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                data = json.loads(manifest.read_text())
                self.assertEqual(len(data["shards"]), count)
                self.assertEqual(sorted(sum(data["shards"], [])), inventory)
                selected = []
                for index in range(count):
                    result = subprocess.run([sys.executable, "-m", "scripts.ios_ui_smoke", "lane-arguments",
                        "--manifest", str(manifest), "--lane", f"ui-{index + 1}"],
                        cwd=ROOT, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    selected.extend(line.removeprefix("-only-testing:") for line in result.stdout.splitlines())
                self.assertEqual(sorted(selected), inventory)

    def test_duration_weights_must_be_finite_positive_numbers(self):
        for value in (-1, 0, True, float("nan"), float("inf"), "20"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.tool.shard_tests([ONE, TWO], {ONE: value}, 2)


class AggregateContractTest(unittest.TestCase):
    def setUp(self):
        self.tool = importlib.import_module("scripts.ios_ui_smoke")
        self.manifest = {"sha": "a" * 40, "mode": "full", "unit": [UNIT], "ui": [ONE, TWO],
                         "shards": [[ONE], [TWO]], "iphone_skips": []}
        self.needs = {"changes": {"result": "skipped", "outputs": {}},
                      "plan": {"result": "success", "outputs": {"run": "true", "mode": "full"}},
                      "build": {"result": "success"}, "tests": {"result": "success"}}
        unit = tree([])
        unit["testNodes"][0]["children"].pop()
        ui1, ui2 = tree(unit=False), tree(unit=False)
        cases1 = ui1["testNodes"][0]["children"][0]["children"][0]["children"]
        cases2 = ui2["testNodes"][0]["children"][0]["children"][0]["children"]
        del cases1[1]
        del cases2[0]
        self.evidence = {"unit": unit, "ui-1": ui1, "ui-2": ui2}

    def verify(self):
        self.assertTrue(hasattr(self.tool, "validate_aggregate"), "aggregate verifier is missing")
        return self.tool.validate_aggregate("merge_group", self.needs, self.manifest,
                                            self.evidence, "a" * 40)

    def test_happy_path(self):
        self.verify()

    def test_cancelled_failed_or_skipped_shard_job_fails(self):
        for result in ("cancelled", "failure", "skipped", ""):
            self.needs["tests"]["result"] = result
            with self.subTest(result=result), self.assertRaises(ValueError):
                self.verify()

    def test_missing_shard_fails_even_if_matrix_reports_success(self):
        del self.evidence["ui-2"]
        with self.assertRaises(ValueError):
            self.verify()

    def test_case_in_two_shards_fails(self):
        self.evidence["ui-2"] = copy.deepcopy(self.evidence["ui-1"])
        with self.assertRaises(ValueError):
            self.verify()

    def test_case_in_no_shard_fails(self):
        self.manifest["ui"].append("BeidUITests/FlowTests/testNew")
        with self.assertRaises(ValueError):
            self.verify()

    def test_unexpected_skip_fails(self):
        self.evidence["ui-1"]["testNodes"][0]["children"][0]["children"][0]["children"][0]["result"] = "Skipped"
        with self.assertRaises(ValueError):
            self.verify()

    def test_unit_failure_skip_and_missing_case_fail(self):
        for result in ("Failed", "Skipped"):
            self.evidence["unit"]["testNodes"][0]["children"][0]["children"][0]["result"] = result
            with self.subTest(result=result), self.assertRaises(ValueError):
                self.verify()
        self.evidence["unit"] = tree([])
        self.manifest["unit"].append("BeidTests/FlowTests/testNew")
        with self.assertRaises(ValueError):
            self.verify()

    def test_explicit_iphone_skip_is_allowed_and_must_be_observed(self):
        self.manifest["iphone_skips"] = [ONE]
        self.evidence["ui-1"]["testNodes"][0]["children"][0]["children"][0]["children"][0]["result"] = "Skipped"
        self.verify()
        del self.evidence["ui-1"]["testNodes"][0]["children"][0]["children"][0]["children"][:]
        with self.assertRaises(ValueError):
            self.verify()

    def test_iphone_exclusion_must_skip_and_needs_no_execution_duration(self):
        self.manifest["iphone_skips"] = [ONE]
        with self.assertRaises(ValueError):
            self.verify()
        case = self.evidence["ui-1"]["testNodes"][0]["children"][0]["children"][0]["children"][0]
        case["result"] = "Skipped"
        del case["durationInSeconds"]
        self.verify()

    def test_missing_or_failed_plan_cannot_pass(self):
        for result in ("failure", "skipped", "cancelled", ""):
            self.needs["plan"]["result"] = result
            with self.subTest(result=result), self.assertRaises(ValueError):
                self.verify()

    def test_only_successful_explicit_classifier_skip_can_pass(self):
        self.needs["changes"] = {"result": "success", "outputs": {"ios": "false", "error": "false"}}
        self.needs["plan"]["outputs"]["run"] = "false"
        self.needs["build"]["result"] = self.needs["tests"]["result"] = "skipped"
        self.assertTrue(hasattr(self.tool, "validate_aggregate"), "aggregate verifier is missing")
        self.tool.validate_aggregate("pull_request", self.needs, None, {}, "a" * 40)
        for result in ("failure", "cancelled"):
            self.needs["changes"]["result"] = result
            with self.assertRaises(ValueError):
                self.tool.validate_aggregate("pull_request", self.needs, None, {}, "a" * 40)

    def test_wrong_head_build_failure_or_corrupt_manifest_fails(self):
        for field, value in (("sha", "b" * 40), ("shards", [[ONE], [ONE, TWO]])):
            original = self.manifest[field]
            self.manifest[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.verify()
            self.manifest[field] = original
        self.needs["build"]["result"] = "failure"
        with self.assertRaises(ValueError):
            self.verify()

    def test_smoke_keeps_full_units_and_exact_smoke_ui_in_one_lane(self):
        self.needs["plan"]["outputs"]["mode"] = self.manifest["mode"] = "smoke"
        self.needs["tests"]["result"] = "skipped"
        self.manifest["smoke"] = [ONE, TWO]
        self.evidence = {"build": tree()}
        self.verify()
        self.evidence["build"] = tree([])
        with self.assertRaises(ValueError):
            self.verify()

    def test_aggregate_cli_rejects_missing_artifact_and_writes_summary(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            needs = root / "needs.json"
            needs.write_text(json.dumps(self.needs))
            artifacts = root / "artifacts"
            artifacts.mkdir()
            build = artifacts / "ios-evidence-1-build"
            build.mkdir()
            (build / "manifest.json").write_text(json.dumps(self.manifest))
            for lane, payload in self.evidence.items():
                folder = artifacts / f"ios-evidence-1-{lane}"
                folder.mkdir()
                (folder / "test-tree.json").write_text(json.dumps(payload))
            command = [sys.executable, "-m", "scripts.ios_ui_smoke", "aggregate", "--event-name", "merge_group",
                       "--needs-json", str(needs), "--evidence-root", str(artifacts), "--attempt", "1",
                       "--sha", "a" * 40, "--summary", str(root / "summary.md")]
            result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("all 1 BeidTests passed", (root / "summary.md").read_text())
            (artifacts / "ios-evidence-1-ui-2/test-tree.json").unlink()
            result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
