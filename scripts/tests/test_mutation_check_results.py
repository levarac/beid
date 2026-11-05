"""Mutation outcomes must use only the current Gradle run's JUnit results."""

import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts.tests.test_mutation_check import load_module


TASK = ":shared:testAndroidHostTest"
TEST_ID = "HttpDateTest#acceptsValidHeader"
SOURCE = (
    "fun parseHttpDateEpochSeconds(value: String?): Long? {\n"
    "    if (value == null || value.length != 29) return null\n"
    "    return value.length.toLong()\n"
    "}\n"
)


class CurrentRunResultsTests(unittest.TestCase):
    def setUp(self):
        self.tool = load_module()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.xml = self.root / "shared/build/test-results/testAndroidHostTest/TEST-HttpDateTest.xml"
        self.xml.parent.mkdir(parents=True)
        self.target = self.root / "HttpDate.kt"
        self.target.write_text(SOURCE, encoding="utf-8")
        self.wrapper = self.root / "android/gradlew"
        self.wrapper.parent.mkdir()
        self.wrapper.touch()
        self.backups = self.root / "backups"
        self.backups.mkdir()
        self.argv = [
            "mutation_check.py", "--target", str(self.target),
            "--test-task", TASK, "--json-out", str(self.root / "report.json"),
        ]
        patches = [
            mock.patch.object(self.tool, "REPO_ROOT", self.root),
            mock.patch.object(self.tool, "ANDROID_DIR", self.wrapper.parent),
            mock.patch.object(self.tool, "GRADLEW", self.wrapper),
            mock.patch("time.time", return_value=1000.0),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def write_xml(self, failed=False, mtime=999.0, name="acceptsValidHeader"):
        failure = "<failure message='wrong date'/>" if failed else ""
        self.xml.write_text(
            f'<testsuite><testcase classname="HttpDateTest" name="{name}">'
            f"{failure}</testcase></testsuite>", encoding="utf-8",
        )
        os.utime(self.xml, (mtime, mtime))

    def test_compile_failure_rejects_previous_green_xml_within_two_seconds(self):
        self.write_xml(mtime=999.0)
        with mock.patch.object(self.tool, "run", return_value=subprocess.CompletedProcess(
            [], 1, "compileAndroidMain FAILED\nOnly safe calls are allowed"
        )):
            rc, results, tail = self.tool.run_tests([TASK], {})
        self.assertEqual(rc, 1)
        self.assertIsNone(results, "previous green XML was reused after compilation failed")
        self.assertIn("Only safe calls are allowed", tail)

    def test_compile_failure_rejects_previous_failed_xml(self):
        self.write_xml(failed=True, mtime=999.0)
        with mock.patch.object(self.tool, "run", return_value=subprocess.CompletedProcess(
            [], 1, "compileAndroidMain FAILED"
        )):
            _, results, _ = self.tool.run_tests([TASK], {})
        self.assertIsNone(results, "a previous failure must not kill the next mutation")

    def test_current_results_replace_old_results_even_with_coarse_mtimes(self):
        stale = self.xml.with_name("TEST-RemovedTest.xml")
        stale.write_text(
            '<testsuite><testcase classname="RemovedTest" name="old"/></testsuite>',
            encoding="utf-8",
        )
        os.utime(stale, (999.0, 999.0))

        def run_current(*args, **kwargs):
            self.write_xml(failed=True, mtime=999.0)
            return subprocess.CompletedProcess([], 1, "tests failed")

        with mock.patch.object(self.tool, "run", side_effect=run_current):
            rc, results, _ = self.tool.run_tests([TASK], {})
        self.assertEqual(rc, 1)
        self.assertEqual(results, {TEST_ID: True})

    def test_back_to_back_runs_do_not_reuse_the_first_runs_xml(self):
        def run_first(*args, **kwargs):
            self.write_xml(mtime=999.0)
            return subprocess.CompletedProcess([], 0, "BUILD SUCCESSFUL")

        with mock.patch.object(self.tool, "run", side_effect=run_first):
            self.assertEqual(self.tool.run_tests([TASK], {})[1], {TEST_ID: False})
        with mock.patch.object(self.tool, "run", return_value=subprocess.CompletedProcess(
            [], 1, "compileAndroidMain FAILED"
        )):
            self.assertIsNone(self.tool.run_tests([TASK], {})[1])

    def run_main(self, outcomes, first_site_only=False):
        """Replace only the subprocess boundary; exercise real XML and CLI logic."""
        mutations = []
        calls = iter(outcomes)

        def fake_runner(*args, **kwargs):
            outcome = next(calls)
            mutations.append(self.target.read_text(encoding="utf-8"))
            if outcome not in ("compile-failed", "no-tests"):
                self.write_xml(failed=outcome == "killed", mtime=999.0)
            return subprocess.CompletedProcess(
                [], 0 if outcome in ("green", "no-tests") else 1,
                "compileAndroidMain FAILED" if outcome == "compile-failed" else "tests finished",
            )

        stdout = io.StringIO()
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(self.tool, "run", side_effect=fake_runner))
            stack.enter_context(mock.patch.object(self.tool, "resolve_java_home", return_value="/fake/jdk"))
            stack.enter_context(mock.patch.object(self.tool, "note_if_dirty"))
            stack.enter_context(mock.patch.object(self.tool.tempfile, "mkdtemp", return_value=str(self.backups)))
            stack.enter_context(mock.patch.object(sys, "argv", self.argv))
            stack.enter_context(contextlib.redirect_stdout(stdout))
            if first_site_only:
                first = self.tool.find_sites(self.target)[0]
                stack.enter_context(mock.patch.object(self.tool, "find_sites", return_value=[first]))
            with self.assertRaises(SystemExit) as caught:
                self.tool.main()
        report = json.loads((self.root / "report.json").read_text(encoding="utf-8"))
        self.assertEqual(self.target.read_bytes(), SOURCE.encode("utf-8"))
        return caught.exception.code, stdout.getvalue(), report, mutations

    def test_http_date_null_guard_compile_failure_is_reported_separately(self):
        code, out, report, mutations = self.run_main(["green", "compile-failed"], first_site_only=True)
        self.assertIn("value != null || value.length != 29", mutations[1])
        self.assertEqual(report["results"][0]["verdict"], "compile-failed")
        self.assertEqual(report["results"][0]["killed_by"], [])
        self.assertEqual(report["compile_failed"], 1)
        self.assertEqual((report["killed"], report["survived"]), (0, 0))
        self.assertIn("Sites mutated: 1   Killed: 0   Survived: 0   Compile-failed: 1", out)
        self.assertEqual(code, 1, "a compile failure must not pass as test protection")

    def test_killed_survived_and_compile_failed_counts_are_disjoint(self):
        _, out, report, _ = self.run_main(["green", "compile-failed", "killed", "green"])
        self.assertEqual([r["verdict"] for r in report["results"]], ["compile-failed", "killed", "survived"])
        self.assertEqual(report["results"][1]["killed_by"], [TEST_ID])
        self.assertEqual((report["killed"], report["survived"], report["compile_failed"]), (1, 1, 1))
        self.assertIn("Sites mutated: 3   Killed: 1   Survived: 1   Compile-failed: 1", out)

    def test_failed_build_with_fresh_green_xml_is_not_a_survivor(self):
        code, _, report, _ = self.run_main(["green", "build-failed"], first_site_only=True)
        self.assertEqual(report["results"][0]["verdict"], "compile-failed")
        self.assertEqual(report["survived"], 0)
        self.assertEqual(code, 1)

    def test_success_without_xml_is_not_credited_as_test_protection(self):
        code, _, report, _ = self.run_main(["green", "no-tests"], first_site_only=True)
        self.assertEqual(report["results"][0]["verdict"], "compile-failed")
        self.assertEqual(report["killed"], 0)
        self.assertEqual(code, 1)


if __name__ == "__main__":
    unittest.main()
