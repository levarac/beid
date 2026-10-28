"""Fail closed on UI selection drift and incomplete xcresult evidence."""

import importlib
import json
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).parents[2]
LIST = ROOT / "ios/ci/ui-smoke-tests.txt"
ONE = "BeidUITests/FlowTests/testOne"
TWO = "BeidUITests/FlowTests/testTwo"


def tree(ui=None, unit=True):
    def case(name, status="Passed", duration=1.25):
        return {"nodeType": "Test Case", "name": name + "()", "result": status,
                "durationInSeconds": duration, "nodeIdentifier": "FlowTests/" + name + "()"}
    bundles = []
    if unit:
        bundles.append({"nodeType": "Unit test bundle", "name": "BeidTests",
                        "children": [case("testUnit")]})
    bundles.append({"nodeType": "UI test bundle", "name": "BeidUITests", "children": [
        {"nodeType": "Test Suite", "name": "FlowTests", "children":
         ui if ui is not None else [case("testOne"), case("testTwo")]}]})
    return {"testNodes": [{"nodeType": "Test Plan", "name": "Beid", "children": bundles}]}


class SmokeContractTest(unittest.TestCase):
    def setUp(self):
        (ROOT / "build").mkdir(exist_ok=True)
        self.assertTrue((ROOT / "scripts/ios_ui_smoke.py").is_file(),
                        "missing smoke mode/selection/evidence implementation")
        self.tool = importlib.import_module("scripts.ios_ui_smoke")

    def test_mode_uses_only_payload_labels_and_defaults_to_full(self):
        for event, payload, expected in [
            ("pull_request", {"pull_request": {"labels": []}}, "smoke"),
            ("pull_request", {"pull_request": {"labels": [{"name": "other"}]}}, "smoke"),
            ("pull_request", {"pull_request": {"labels": [{"name": "ci:full-ui"}]}}, "full"),
            ("pull_request", {"action": "labeled", "label": {"name": "ci:full-ui"},
                              "pull_request": {"labels": [{"name": "ci:full-ui"}]}}, "full"),
            ("pull_request", {"action": "labeled", "pull_request": {"labels": []}}, "smoke"),
            *[(event, {"pull_request": {"labels": []}}, "full")
              for event in ("push", "schedule", "workflow_dispatch", "merge_group", "unknown")],
            *[("pull_request", payload, "full") for payload in (
                {}, None, [], {"pull_request": {}}, {"pull_request": {"labels": None}},
                {"pull_request": {"labels": ["ci:full-ui"]}},
                {"pull_request": {"labels": [{}]}})],
        ]:
            with self.subTest(event=event, payload=payload):
                self.assertEqual(self.tool.compute_mode(event, payload), expected)

    def test_merge_group_checks_requested_always_selects_full(self):
        payload = {"action": "checks_requested", "merge_group": {
            "base_sha": "b" * 40, "head_sha": "a" * 40,
            "head_ref": "refs/heads/gh-readonly-queue/main/pr-42-aaaa",
        }}
        self.assertEqual(self.tool.compute_mode("merge_group", payload), "full")
        with tempfile.TemporaryDirectory(dir=ROOT / "build") as folder:
            event = Path(folder) / "event.json"
            event.write_text(json.dumps(payload))
            result = subprocess.run([
                sys.executable, "-m", "scripts.ios_ui_smoke", "mode",
                "--event-name", "merge_group", "--event-path", str(event),
            ], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "mode=full")

    def test_list_parser_accepts_crlf_blank_comments_and_trailing_space(self):
        self.assertEqual(self.tool.parse_smoke_list(
            f"# reason\r\n \r\n {ONE}  \r\n{TWO}\t # reason\r\n"), [ONE, TWO])

    def test_list_parser_rejects_empty_duplicate_and_invalid_identifiers(self):
        for value in ("", "# nothing\n  ", f"{ONE}\r\n{ONE}  # repeated",
                      "BeidTests/FlowTests/testOne", "BeidUITests/FlowTests",
                      ONE + "()", ONE + " extra", "-skip-testing:BeidUITests"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.tool.parse_smoke_list(value)

    def test_arguments_select_all_units_and_exact_ui_only_in_smoke(self):
        self.assertEqual(self.tool.selection_arguments("smoke", [ONE, TWO]),
                         ["-only-testing:BeidTests", f"-only-testing:{ONE}", f"-only-testing:{TWO}"])
        self.assertEqual(self.tool.selection_arguments("full", [ONE, TWO]), [])
        for mode, tests in (("", [ONE]), ("short", [ONE]), ("smoke", []), ("full", [ONE, ONE])):
            with self.subTest(mode=mode, tests=tests), self.assertRaises(ValueError):
                self.tool.selection_arguments(mode, tests)

    def test_exact_match_and_parenthesized_xcresult_names_pass(self):
        counts, durations = self.tool.validate_results("smoke", [ONE, TWO], tree())
        self.assertEqual(counts.bundles["BeidUITests"].passed, 2)
        self.assertEqual(durations, {"BeidTests": 1.25, "BeidUITests": 2.5})

    def test_context_names_without_identifiers_are_normalized(self):
        payload = tree()
        cases = payload["testNodes"][0]["children"][1]["children"][0]["children"]
        for case in cases:
            del case["nodeIdentifier"]
        self.tool.validate_results("smoke", [ONE, TWO], payload)

    def test_full_bundle_identifiers_are_normalized(self):
        payload = tree()
        cases = payload["testNodes"][0]["children"][1]["children"][0]["children"]
        for case in cases:
            case["nodeIdentifier"] = "BeidUITests/" + case["nodeIdentifier"]
        self.tool.validate_results("smoke", [ONE, TWO], payload)

    def test_missing_extra_skipped_failed_duplicate_and_unit_only_fail_smoke(self):
        case = {"nodeType": "Test Case", "name": "testOne()", "result": "Passed", "duration": "1s"}
        for cases in ([], [case], [case, case],
                      [case, dict(case, name="testTwo()", result="Skipped")],
                      [case, dict(case, name="testTwo()", result="Failed")],
                      [case, dict(case, name="testTwo()"), dict(case, name="testExtra()")]):
            with self.subTest(cases=cases), self.assertRaises(ValueError):
                self.tool.validate_results("smoke", [ONE, TWO], tree(cases))

    def test_missing_unit_bundle_is_not_a_smoke_pass(self):
        with self.assertRaises(ValueError):
            self.tool.validate_results("smoke", [ONE, TWO], tree(unit=False))

    def test_full_requires_all_listed_cases_and_all_listed_passed(self):
        self.tool.validate_results("full", [ONE], tree())
        for expected in ([ONE, "BeidUITests/FlowTests/testRenamed"],):
            with self.assertRaises(ValueError):
                self.tool.validate_results("full", expected, tree())
        case = {"nodeType": "Test Case", "name": "testOne()", "result": "Skipped", "duration": "0s"}
        with self.assertRaises(ValueError):
            self.tool.validate_results("full", [ONE], tree([case]))

    def test_human_duration_is_summed_only_at_case_level(self):
        payload = tree()
        cases = payload["testNodes"][0]["children"][1]["children"][0]["children"]
        for case in cases:
            del case["durationInSeconds"]
            case["duration"] = "1m 2.5s"
        payload["testNodes"][0]["duration"] = "9h"
        counts, durations = self.tool.validate_results("smoke", [ONE, TWO], payload)
        self.assertEqual(durations["BeidUITests"], 125)

    def test_absent_or_invalid_duration_cannot_look_measured(self):
        for value in (None, -1, float("nan"), True, "bogus"):
            payload = tree()
            case = payload["testNodes"][0]["children"][1]["children"][0]["children"][0]
            case["durationInSeconds"] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.tool.validate_results("smoke", [ONE, TWO], payload)

    def test_checked_in_list_is_six_to_ten_real_methods_outside_xcodegen_sources(self):
        selected = self.tool.parse_smoke_list(LIST.read_text())
        self.assertTrue(6 <= len(selected) <= 10)
        self.tool.validate_sources(selected, ROOT / "ios/BeidUITests")
        # The sanity suite is stdlib-only; accept the source entry forms used
        # by project.yml and fail if a new form needs an explicit parser update.
        project = (ROOT / "ios/project.yml").read_text()
        blocks = re.findall(r"^    sources:\n((?:(?: {6,}.*|)\n)*)", project, re.M)
        self.assertTrue(blocks)
        for block in blocks:
            entries = re.findall(r"^      - (.+)$", block, re.M)
            self.assertTrue(entries)
            for entry in entries:
                source = entry.removeprefix("path: ")
                self.assertRegex(source, r"^[./A-Za-z0-9_-]+$")
                directory = (ROOT / "ios" / source).resolve()
                self.assertFalse(LIST.resolve().is_relative_to(directory), source)
        self.assertNotIn("ui-smoke-tests.txt", (ROOT / "ios/Beid.xcodeproj/project.pbxproj").read_text())

    def test_static_source_check_binds_method_to_correct_class(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build") as folder:
            root = Path(folder)
            (root / "Flow.swift").write_text("// func testGhost() {}\n"
                "final class Other: XCTestCase { func testOne() {} }\n"
                "final class FlowTests: XCTestCase { func testTwo() {} }\n")
            self.tool.validate_sources([TWO], root)
            for selected in ([ONE], ["BeidUITests/FlowTests/testGhost"]):
                with self.assertRaises(ValueError):
                    self.tool.validate_sources(selected, root)

    def test_verify_cli_fails_for_missing_case_and_reports_mode_counts_durations(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build") as folder:
            root = Path(folder)
            listing = root / "list.txt"
            listing.write_text(ONE + "\n" + TWO + "\n")
            payload = root / "tests.json"
            summary = root / "summary.md"
            payload.write_text(json.dumps(tree()))
            argv = [sys.executable, "-m", "scripts.ios_ui_smoke", "verify", "--mode", "smoke",
                    "--list", str(listing), "--tests-json", str(payload), "--summary", str(summary)]
            result = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            report = summary.read_text()
            for value in ("smoke", "BeidTests", "BeidUITests", "2.500", "xcresult"):
                self.assertIn(value, report)
            payload.write_text(json.dumps(tree([])))
            result = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)

    def test_mode_cli_reads_event_file(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build") as folder:
            event = Path(folder) / "event.json"
            event.write_text(json.dumps({"pull_request": {"labels": []}}))
            result = subprocess.run([sys.executable, "-m", "scripts.ios_ui_smoke", "mode",
                "--event-name", "pull_request", "--event-path", str(event)],
                cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "mode=smoke")
