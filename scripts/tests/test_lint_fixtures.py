"""The proof pair must detect dead rules, false positives and lint failures."""

import importlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

from scripts.tests.workflow_yaml import workflow_data


ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "scripts/check_lint_fixtures.py"


class LintFixtureTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(CHECKER.is_file(), "the fixture proof must be automated")
        self.checker = importlib.import_module("scripts.check_lint_fixtures")
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name in ("lint-fixtures", "ios/Beid", "scripts"):
            (self.root / name).mkdir(parents=True)
        (self.root / "lint-fixtures/LintFixtures_pass.swift").write_text("// clean\n")
        (self.root / "lint-fixtures/LintFixtures_fail.swift.txt").write_text(
            "bad() // FAIL first_rule\nwrong() // FAIL second_rule\n")
        self.fail = self.root / "ios/Beid/LintFixtures_fail.swift"
        self.passed = self.root / "ios/Beid/LintFixtures_pass.swift"
        self.report = [
            {"file": str(self.fail), "line": 1, "rule_id": "first_rule"},
            {"file": str(self.fail), "line": 2, "rule_id": "second_rule"},
        ]

    def fake_lint(self, report=None, exit_code=2, raw=None):
        payload = json.dumps(self.report if report is None else report) if raw is None else raw
        path = self.root / "scripts/lint.sh"
        path.write_text(
            f"#!{sys.executable}\n"
            "import pathlib, sys\n"
            "assert sys.argv[1:] == ['--reporter', 'json']\n"
            "assert pathlib.Path('ios/Beid/LintFixtures_pass.swift').is_file()\n"
            "assert pathlib.Path('ios/Beid/LintFixtures_fail.swift').is_file()\n"
            f"print({payload!r})\n"
            f"sys.exit({exit_code})\n")
        path.chmod(0o755)

    def test_exact_fail_report_and_clean_pass_succeed_and_clean_up(self):
        self.fake_lint()
        self.assertEqual(self.checker.check_fixtures(self.root), 2)
        self.assertFalse(self.fail.exists())
        self.assertFalse(self.passed.exists())

    def test_dead_rule_missing_duplicate_wrong_line_and_wrong_rule_fail(self):
        for report in ([], self.report[:1], self.report + self.report[:1],
                       [dict(row, line=10) for row in self.report],
                       [dict(row, rule_id="other_rule") for row in self.report]):
            with self.subTest(report=report):
                self.fake_lint(report)
                with self.assertRaises(ValueError):
                    self.checker.check_fixtures(self.root)
                self.assertFalse(self.fail.exists())
                self.assertFalse(self.passed.exists())

    def test_pass_fixture_or_other_file_violation_fails(self):
        for path in (self.passed, self.root / "ios/Beid/Unrelated.swift"):
            with self.subTest(path=path):
                self.fake_lint(self.report + [{"file": str(path), "line": 1, "rule_id": "first_rule"}])
                with self.assertRaises(ValueError):
                    self.checker.check_fixtures(self.root)

    def test_only_expected_nonzero_exit_is_success(self):
        for exit_code in (0, 1, 3):
            with self.subTest(exit_code=exit_code):
                self.fake_lint(exit_code=exit_code)
                with self.assertRaises(ValueError):
                    self.checker.check_fixtures(self.root)

    def test_malformed_report_fails_and_cleans_up(self):
        for raw in ("not JSON", "{}", '[{"file": "missing fields"}]'):
            with self.subTest(raw=raw):
                self.fake_lint(raw=raw)
                with self.assertRaises(ValueError):
                    self.checker.check_fixtures(self.root)
                self.assertFalse(self.fail.exists())
                self.assertFalse(self.passed.exists())

    def test_existing_fixture_is_never_overwritten_or_removed(self):
        for target in (self.passed, self.fail):
            with self.subTest(target=target):
                target.write_text("keep this\n")
                self.fake_lint()
                with self.assertRaises((OSError, ValueError)):
                    self.checker.check_fixtures(self.root)
                self.assertEqual(target.read_text(), "keep this\n")
                target.unlink()
                self.assertFalse(self.fail.exists())
                self.assertFalse(self.passed.exists())


class LintFixtureWiringTests(unittest.TestCase):
    def test_existing_swiftlint_job_runs_the_proof_pair(self):
        workflow = workflow_data((ROOT / ".github/workflows/pr-ci.yml").read_text())
        lint = workflow["jobs"]["lint"]
        self.assertEqual(lint["name"], "SwiftLint")
        self.assertEqual(lint["runs-on"], "macos-26")
        steps = [step for step in lint["steps"]
                 if step.get("run") == "python3 scripts/check_lint_fixtures.py"]
        self.assertEqual(len(steps), 1)
        self.assertNotIn("if", steps[0])
        self.assertNotIn("continue-on-error", steps[0])

    def test_expected_nonzero_exit_is_documented(self):
        text = (ROOT / "lint-fixtures/README.md").read_text()
        self.assertIn("exit 2", text)
        self.assertIn("python3 scripts/check_lint_fixtures.py", text)
