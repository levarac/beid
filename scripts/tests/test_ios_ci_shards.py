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
        for count in (4, 5):
            shards = self.tool.shard_tests(tests, durations, count)
            self.assertEqual(len(shards), count)
            self.assertEqual(shards, self.tool.shard_tests(list(reversed(tests)), durations, count))
            self.assertEqual(sorted(sum(shards, [])), sorted(tests))
            if count == 4:
                self.assertLessEqual(max(map(len, shards)) - min(map(len, shards)), 1)
        for count in (0, 1, 6):
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
        unit_suites = payload["values"][0]["children"][0]["children"]
        for test in EXPECTED_UNIT_SKIPS:
            _, suite, method = test.split("/")
            unit_suites.append({"name": suite, "children": [{"name": method + "()"}]})
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            enum, manifest = root / "enumerated.json", root / "manifest.json"
            enum.write_text(json.dumps(payload))
            for count in (2, 3, 4, 5):
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
            invalid_lane = subprocess.run([sys.executable, "-m", "scripts.ios_ui_smoke", "lane-arguments",
                "--manifest", str(manifest), "--lane", "ui-6"], cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(invalid_lane.returncode, 1, invalid_lane.stderr)
            self.assertIn("invalid lane: ui-6", invalid_lane.stderr)
            smoke_command = [sys.executable, "-m", "scripts.ios_ui_smoke", "shards",
                             "--enumeration", str(enum), "--output", str(manifest), "--count", "5",
                             "--mode", "smoke", "--sha", "a" * 40]
            result = subprocess.run(smoke_command, cwd=ROOT, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("stale smoke unit suite exclusions", result.stderr)
            for suite in ("ReportSubmissionOperatorIntegrationTests",
                          "ProductionVenueBundleVerifierTests", "ReportProofLinkContainmentTests"):
                unit_suites.append({"name": suite, "children": [{"name": "testDeferred()"}]})
            enum.write_text(json.dumps(payload))
            result = subprocess.run(smoke_command, cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            # Plan from Swift on Linux, then bind that plan to Xcode's enumeration.
            from scripts.ios_ui_pr_plan import execution_plan
            plan = execution_plan("smoke", "pull_request", {"pull_request": {
                "base": {"ref": "release/1.1.0"}, "head": {"ref": "feat/ui", "sha": "a" * 40}}},
                {"files": ["ios/Beid/Views/OrganizerToolsView.swift"]}, 5)
            plan_path = root / "proposal.json"
            plan_path.write_text(json.dumps(plan["proposal"]))
            selected_command = smoke_command.copy()
            selected_command[selected_command.index("smoke")] = "selected"
            selected_command.extend(["--proposal", str(plan_path)])
            result = subprocess.run(selected_command, cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            data = json.loads(manifest.read_text())
            self.assertEqual(data["shards"], plan["proposal"]["shards"])
            args = subprocess.check_output([sys.executable, "-m", "scripts.ios_ui_smoke", "lane-arguments",
                "--manifest", str(manifest), "--lane", "ui-1"], cwd=ROOT, text=True).splitlines()
            self.assertEqual(args, self.tool.selection_arguments("smoke", plan["proposal"]["candidates"]))
            plan["proposal"]["shards"][0].pop()
            plan_path.write_text(json.dumps(plan["proposal"]))
            result = subprocess.run(selected_command, cwd=ROOT, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("selected assignments differ", result.stderr)
            del unit_suites[-3:]
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

    def test_selected_union_matches_independent_plan_and_skips(self):
        self.needs["plan"]["outputs"].update(mode="selected")
        planned = [[ONE, TWO]]
        self.manifest.update(mode="selected", smoke=[ONE], shards=planned)
        self.manifest["ui"].append("BeidUITests/OtherTests/testOutside")
        proposal = {"mode": "selected", "sha": self.manifest["sha"], "candidates": [ONE, TWO], "shards": planned}
        self.needs["plan"]["outputs"]["proposal"] = json.dumps(proposal)
        self.evidence = {"ui-1": tree()}
        self.verify()
        for shards in ([[ONE]], [[ONE, TWO, TWO]], [[ONE, TWO, self.manifest["ui"][-1]]]):
            self.manifest["shards"] = shards
            with self.subTest(shards=shards), self.assertRaises(ValueError):
                self.verify()
        self.manifest["shards"] = planned
        for payload in (tree(unit=False), tree([])):
            self.evidence["ui-1"] = payload
            with self.assertRaises(ValueError):
                self.verify()
        self.evidence["ui-1"] = tree()
        self.manifest["iphone_skips"] = [self.manifest["ui"][-1]]
        with self.assertRaises(ValueError):
            self.verify()
        self.manifest["iphone_skips"] = [ONE]
        with self.assertRaisesRegex(ValueError, "did not skip"):
            self.verify()
        self.evidence["ui-1"]["testNodes"][0]["children"][1]["children"][0]["children"][0]["result"] = "Skipped"
        self.verify()

    def add_ui_shards(self, total_count):
        for index in range(3, total_count + 1):
            case_identifier = f"FlowTests/testShard{index}"
            test = f"BeidUITests/{case_identifier}"
            self.manifest["ui"].append(test)
            self.manifest["shards"].append([test])
            self.evidence[f"ui-{index}"] = tree([{
                "nodeType": "Test Case",
                "nodeIdentifier": f"{case_identifier}()",
                "result": "Passed",
                "durationInSeconds": 1.25,
            }], unit=False)

    def test_full_aggregate_accepts_four_ui_shards(self):
        self.add_ui_shards(4)
        self.assertIn("all 5 cases accounted for", self.verify())

    def test_full_aggregate_accepts_five_ui_shards(self):
        self.add_ui_shards(5)
        self.assertIn("all 6 cases accounted for", self.verify())

    def test_full_aggregate_rejects_missing_fourth_ui_shard(self):
        self.add_ui_shards(4)
        del self.evidence["ui-4"]
        with self.assertRaisesRegex(ValueError, "missing or extra lane artifacts"):
            self.verify()

    def test_full_aggregate_rejects_missing_fifth_ui_shard(self):
        self.add_ui_shards(5)
        del self.evidence["ui-5"]
        with self.assertRaisesRegex(ValueError, "missing or extra lane artifacts"):
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
            if mode == "smoke":
                self.manifest["unit"].append("BeidTests/ReportProofLinkContainmentTests/testDeferred")
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

    def test_smoke_checks_only_selected_units_and_exact_ui_in_one_lane(self):
        deferred = "BeidTests/ReportSubmissionOperatorIntegrationTests/testDeferred"
        self.manifest["unit"].append(deferred)
        self.manifest["unit_skips"].append(deferred)
        self.needs["plan"]["outputs"]["mode"] = self.manifest["mode"] = "smoke"
        self.needs["tests"]["result"] = "skipped"
        self.manifest["smoke"] = [ONE, TWO]
        self.evidence = {"build": tree()}
        self.assertIn("BeidTests: 1 passed, 0 skipped", self.verify())
        unit_cases = self.evidence["build"]["testNodes"][0]["children"][0]["children"]
        deferred_case = dict(unit_cases[0],
                             nodeIdentifier=deferred.removeprefix("BeidTests/") + "()",
                             result="Skipped")
        unit_cases.append(deferred_case)
        with self.assertRaisesRegex(ValueError, "extra/duplicate"):
            self.verify()
        unit_cases.clear()
        with self.assertRaisesRegex(ValueError, "missing="):
            self.verify()
        self.evidence["build"] = tree([])
        with self.assertRaises(ValueError):
            self.verify()
        self.manifest["unit"] = [deferred]
        with self.assertRaisesRegex(ValueError, "smoke must select unit tests"):
            self.verify()

    def run_aggregate_cli(self, attempts, current_attempt, build_attempt=1):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            needs = root / "needs.json"
            needs.write_text(json.dumps({
                **self.needs,
                "build": {**self.needs["build"], "outputs": {"evidence_attempt": str(build_attempt)}},
            }))
            artifacts = root / "artifacts"
            for attempt, lanes in attempts.items():
                for lane, payload in lanes.items():
                    folder = artifacts / f"ios-evidence-{attempt}-{lane}"
                    folder.mkdir(parents=True)
                    if payload is not None:
                        filename = "manifest.json" if lane == "build" else "test-tree.json"
                        (folder / filename).write_text(json.dumps(payload))
            summary = root / "summary.md"
            command = [sys.executable, "-m", "scripts.ios_ui_smoke", "aggregate", "--event-name", "merge_group",
                       "--needs-json", str(needs), "--evidence-root", str(artifacts),
                       "--attempt", str(current_attempt), "--sha", self.manifest["sha"], "--summary", str(summary)]
            result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
            return result, summary.read_text() if summary.exists() else ""

    def test_aggregate_cli_combines_retried_shard_with_previous_lanes(self):
        self.add_ui_shards(4)
        first = {"build": self.manifest, **self.evidence}
        retry = {"ui-4": first.pop("ui-4")}
        result, summary = self.run_aggregate_cli({1: first, 2: retry}, current_attempt=2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("all 5 cases accounted for; BeidTests: 1 passed, 0 skipped", summary)

    def test_aggregate_cli_rejects_lane_missing_from_all_attempts(self):
        self.add_ui_shards(4)
        first = {"build": self.manifest, **self.evidence}
        retry = {"ui-4": first.pop("ui-4")}
        del first["ui-3"]
        result, _ = self.run_aggregate_cli({1: first, 2: retry}, current_attempt=2)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("missing or extra lane artifacts", result.stderr)

    def test_aggregate_cli_rejects_latest_failure_or_missing_tree_after_pass(self):
        self.add_ui_shards(4)
        first = {"build": self.manifest, **self.evidence}
        failed = tree([{
            "nodeType": "Test Case",
            "nodeIdentifier": "FlowTests/testShard4()",
            "result": "Failed",
            "durationInSeconds": 1.25,
        }], unit=False)
        for payload, error in ((failed, "test did not pass: BeidUITests/FlowTests/testShard4: Failed"),
                               (None, "missing or extra lane artifacts")):
            with self.subTest(error=error):
                result, _ = self.run_aggregate_cli({1: first, 2: {"ui-4": payload}}, current_attempt=2)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(error, result.stderr)

    def test_aggregate_cli_uses_latest_build_and_lanes_on_full_rerun(self):
        latest = {"build": self.manifest, **self.evidence}
        older = {**latest, "build": {**self.manifest, "sha": "b" * 40}, "ui-2": None}
        result, summary = self.run_aggregate_cli({2: older, 10: latest}, current_attempt=10, build_attempt=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("all 3 cases accounted for", summary)

    def test_aggregate_cli_rejects_stale_evidence_after_build_rerun(self):
        first = {"build": self.manifest, **self.evidence}
        for missing, error in (("build", "missing evidence for build attempt 2"),
                               ("ui-2", "evidence for ui-2 predates build attempt 2")):
            with self.subTest(missing=missing):
                latest = {lane: payload for lane, payload in first.items() if lane != missing}
                result, _ = self.run_aggregate_cli({1: first, 2: latest}, current_attempt=2, build_attempt=2)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(error, result.stderr)
