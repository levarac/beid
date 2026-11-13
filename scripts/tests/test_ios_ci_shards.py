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
EXPECTED_UNIT_SKIPS = [
    "BeidTests/OnboardingFlagTests/testWalletFirstOrderReachesBluetoothPermissionAfterConnect",
    "BeidTests/ReportSubmissionOperatorIntegrationTests/testRealSignedWindowGetsVerifiedReceiptFromReferenceOperator",
    "BeidTests/SensingCoordinatorTests/testReleaseConfigurationCannotEnableDemoEventMode",
]
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
        for count in (0, 1, 5, 6, True, False, "4", None):
            with self.assertRaises(ValueError):
                self.tool.shard_tests(tests, durations, count)
        with self.assertRaises(ValueError):
            self.tool.shard_tests([ONE, ONE], {}, 2)

    def test_four_shards_preserve_lpt_ties_and_twenty_second_default(self):
        tests = [f"BeidUITests/FlowTests/test{letter}" for letter in "ABCDEFGHI"]
        durations = dict(zip(tests, (40, 40, 30, 30, 20, 20, 10, 10)))
        try:
            shards = self.tool.shard_tests(list(reversed(tests)), durations, 4)
        except ValueError as error:
            self.fail(f"four-shard configuration rejected: {error}")
        self.assertEqual(shards, [[tests[0], tests[8]], [tests[1], tests[6], tests[7]],
                                  [tests[2], tests[4]], [tests[3], tests[5]]])
        self.assertEqual(sorted(sum(shards, [])), tests)

    def test_four_shards_reject_empty_duplicate_and_malformed_inventory(self):
        for tests in ([ONE, TWO], [ONE, TWO, ONE, TWO], [], None,
                      [ONE, TWO, "bad", "BeidUITests/FlowTests/testFour"]):
            with self.subTest(tests=tests), self.assertRaises(ValueError):
                self.tool.shard_tests(tests, {}, 4)

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
        unit_suites = payload["values"][0]["children"][0]["children"]
        for test in EXPECTED_UNIT_SKIPS:
            _, suite, method = test.split("/")
            unit_suites.append({"name": suite, "children": [{"name": method + "()"}]})
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            enum, manifest = root / "enumerated.json", root / "manifest.json"
            enum.write_text(json.dumps(payload))
            for count in (2, 3, 4):
                result = subprocess.run([sys.executable, "-m", "scripts.ios_ui_smoke", "shards",
                    "--enumeration", str(enum), "--output", str(manifest), "--count", str(count),
                    "--mode", "full", "--sha", "a" * 40], cwd=ROOT, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                data = json.loads(manifest.read_text())
                self.assertEqual(data["unit_skips"], EXPECTED_UNIT_SKIPS)
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
            unit_suites.pop()
            enum.write_text(json.dumps(payload))
            result = subprocess.run([sys.executable, "-m", "scripts.ios_ui_smoke", "shards",
                "--enumeration", str(enum), "--output", str(manifest), "--count", "3",
                "--mode", "full", "--sha", "a" * 40], cwd=ROOT, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0, "stale unit skip list accepted")

    def test_duration_weights_must_be_finite_positive_numbers(self):
        for value in (-1, 0, True, float("nan"), float("inf"), "20"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.tool.shard_tests([ONE, TWO], {ONE: value}, 2)


class AggregateContractTest(unittest.TestCase):
    def setUp(self):
        self.tool = importlib.import_module("scripts.ios_ui_smoke")
        self.manifest = {"sha": "a" * 40, "mode": "full", "unit": [UNIT], "ui": [ONE, TWO],
                         "shards": [[ONE], [TWO]], "iphone_skips": [], "unit_skips": []}
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

    def test_four_shard_aggregate_requires_complete_unique_coverage(self):
        ui = [f"BeidUITests/FlowTests/test{name}" for name in ("One", "Two", "Three", "Four")]
        self.manifest["ui"] = ui
        self.manifest["shards"] = [[test] for test in ui]
        self.evidence = {"unit": self.evidence["unit"]}
        for index, test in enumerate(ui, 1):
            self.evidence[f"ui-{index}"] = tree([{
                "nodeType": "Test Case", "nodeIdentifier": test,
                "result": "Passed", "durationInSeconds": 1.25,
            }], unit=False)
        try:
            message = self.verify()
        except ValueError as error:
            self.fail(f"four-shard execution ledger rejected: {error}")
        self.assertIn("all 5 cases accounted for", message)
        good_manifest, good_evidence = copy.deepcopy(self.manifest), copy.deepcopy(self.evidence)
        for problem in ("missing artifact", "duplicate assignment", "unassigned case", "empty shard", "fifth shard"):
            self.manifest, self.evidence = copy.deepcopy(good_manifest), copy.deepcopy(good_evidence)
            if problem == "missing artifact":
                del self.evidence["ui-4"]
            elif problem == "duplicate assignment":
                self.manifest["shards"][3] = [ui[0]]
            elif problem == "unassigned case":
                self.manifest["ui"].append("BeidUITests/FlowTests/testNew")
            elif problem == "empty shard":
                self.manifest["shards"][3] = []
            else:
                self.manifest["shards"].append(["BeidUITests/FlowTests/testFifth"])
                self.manifest["ui"].append("BeidUITests/FlowTests/testFifth")
            with self.subTest(problem=problem), self.assertRaises(ValueError):
                self.verify()

    def test_ui_four_selector_and_verification_cli(self):
        self.manifest["shards"] = [[ONE], [TWO], ["BeidUITests/FlowTests/testThree"],
                                   ["BeidUITests/FlowTests/testFour"]]
        self.manifest["ui"] = sum(self.manifest["shards"], [])
        selected = self.manifest["shards"][3][0]
        payload = tree([{"nodeType": "Test Case", "nodeIdentifier": selected,
                         "result": "Passed", "durationInSeconds": 1.25}], unit=False)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest, tests, summary = (root / name for name in ("manifest.json", "tests.json", "summary.json"))
            manifest.write_text(json.dumps(self.manifest))
            tests.write_text(json.dumps(payload))
            summary.write_text(json.dumps({"result": "Passed", "totalTestCount": 1,
                "passedTests": 1, "failedTests": 0, "skippedTests": 0}))
            command = [sys.executable, "-B", "-m", "scripts.ios_ui_smoke"]
            arguments = subprocess.run(command + ["lane-arguments", "--manifest", str(manifest),
                "--lane", "ui-4"], cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(arguments.returncode, 0, arguments.stderr)
            self.assertEqual(arguments.stdout.splitlines(), [f"-only-testing:{selected}"])
            verify = command + ["verify-lane", "--manifest", str(manifest), "--lane", "ui-4",
                "--tests-json", str(tests), "--summary-json", str(summary),
                "--summary", str(root / "summary.md")]
            result = subprocess.run(verify, cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("ui-4 execution evidence", (root / "summary.md").read_text())
            payload["testNodes"][0]["children"][0]["children"][0]["children"][0]["result"] = "Failed"
            tests.write_text(json.dumps(payload))
            self.assertNotEqual(subprocess.run(verify, cwd=ROOT, capture_output=True).returncode, 0)
            for lane in ("ui-0", "ui-5", "ui-6", "ui-04", "ui-true"):
                with self.subTest(lane=lane):
                    result = subprocess.run(command + ["lane-arguments", "--manifest", str(manifest),
                        "--lane", lane], cwd=ROOT, capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0)

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

    def unit_case(self, mode):
        self.needs["plan"]["outputs"]["mode"] = self.manifest["mode"] = mode
        if mode == "smoke":
            self.needs["tests"]["result"] = "skipped"
            self.manifest["smoke"] = [ONE, TWO]
            self.evidence = {"build": tree()}
        payload = self.evidence["build" if mode == "smoke" else "unit"]
        return payload["testNodes"][0]["children"][0]["children"][0]

    def test_allowlisted_unit_skip_passes_in_full_and_smoke(self):
        self.manifest["unit_skips"] = [UNIT]
        for mode in ("full", "smoke"):
            with self.subTest(mode=mode):
                case = self.unit_case(mode)
                case["result"] = "Skipped"
                del case["durationInSeconds"]
                message = self.verify()
                self.assertIn("BeidTests: 0 passed, 1 skipped", message)

    def test_unlisted_unit_skip_fails_in_full_and_smoke(self):
        for mode in ("full", "smoke"):
            self.unit_case(mode)["result"] = "Skipped"
            with self.subTest(mode=mode), self.assertRaisesRegex(ValueError, "test did not pass"):
                self.verify()

    def test_allowlisted_unit_that_passed_fails_in_full_and_smoke(self):
        self.manifest["unit_skips"] = [UNIT]
        for mode in ("full", "smoke"):
            self.unit_case(mode)
            with self.subTest(mode=mode), self.assertRaisesRegex(ValueError, "did not skip"):
                self.verify()

    def test_allowlisted_unit_missing_fails_in_full_and_smoke(self):
        self.manifest["unit_skips"] = [UNIT]
        for mode in ("full", "smoke"):
            self.unit_case(mode)
            payload = self.evidence["build" if mode == "smoke" else "unit"]
            payload["testNodes"][0]["children"][0]["children"].clear()
            with self.subTest(mode=mode), self.assertRaisesRegex(ValueError, "execution ledger mismatch"):
                self.verify()

    def test_missing_malformed_or_stale_unit_skip_list_fails(self):
        for skips in (None, "", [UNIT, UNIT], [ONE], [UNIT + "Missing"]):
            self.manifest["unit_skips"] = skips
            with self.subTest(skips=skips), self.assertRaises(ValueError):
                self.verify()

    def test_verify_lane_cli_enforces_unit_skips_in_full_and_smoke(self):
        self.manifest["unit_skips"] = [UNIT]
        for mode, lane in (("full", "unit"), ("smoke", "build")):
            case = self.unit_case(mode)
            case["result"] = "Skipped"
            payload = self.evidence[lane]
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                manifest, tests, summary = (root / name for name in ("manifest.json", "tests.json", "summary.json"))
                manifest.write_text(json.dumps(self.manifest))
                total = 1 if mode == "full" else 3
                summary.write_text(json.dumps({"result": "Passed", "totalTestCount": total,
                    "passedTests": total - 1, "failedTests": 0, "skippedTests": 1}))
                command = [sys.executable, "-m", "scripts.ios_ui_smoke", "verify-lane",
                    "--manifest", str(manifest), "--lane", lane, "--tests-json", str(tests),
                    "--summary-json", str(summary), "--summary", str(root / "summary.md")]
                tests.write_text(json.dumps(payload))
                result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                case["result"] = "Passed"
                tests.write_text(json.dumps(payload))
                summary.write_text(json.dumps({"result": "Passed", "totalTestCount": total,
                    "passedTests": total, "failedTests": 0, "skippedTests": 0}))
                result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("did not skip", result.stderr)

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
            self.assertIn("BeidTests: 1 passed, 0 skipped", (root / "summary.md").read_text())
            (artifacts / "ios-evidence-1-ui-2/test-tree.json").unlink()
            result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
