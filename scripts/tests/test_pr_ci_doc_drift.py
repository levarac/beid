"""The default documentation gate must include the separate hosted lanes."""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from scripts.check_pr_ci_doc_drift import workflow_command_tokens, collect_run_blocks, reverse_check


ROOT = Path(__file__).resolve().parents[2]


class PrCiDocDriftTests(unittest.TestCase):
    def test_build_and_test_invocations_are_distinguishing_tokens(self):
        self.assertEqual(workflow_command_tokens([
            "xcodebuild -quiet \\\n -scheme Beid \\\n build-for-testing",
            "xcodebuild -quiet test-without-building",
            "swift build -c release > build.log",
            "swift test > test.log",
        ]), {"xcodebuild build-for-testing", "xcodebuild test-without-building",
             "swift build -c release", "swift test"})

    def test_removing_each_native_command_from_docs_is_detected(self):
        original = (ROOT / "AGENTS.md").read_text()
        for token in ("xcodebuild build-for-testing", "xcodebuild test-without-building",
                      "swift build -c release", "swift test"):
            with self.subTest(token=token), tempfile.TemporaryDirectory() as directory:
                document = Path(directory) / "AGENTS.md"
                document.write_text(original.replace(token, "removed command"))
                result = subprocess.run(
                    [sys.executable, "scripts/check_pr_ci_doc_drift.py", "--agents-md-path", str(document)],
                    cwd=ROOT, capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn(token, result.stderr)

    def test_removing_each_native_command_from_workflows_is_detected(self):
        original = "\n".join((ROOT / ".github/workflows" / name).read_text() for name in
                              ("pr-ci-ios-macos.yml", "pr-ci-lab-cli.yml"))
        for token in ("xcodebuild build-for-testing", "xcodebuild test-without-building",
                      "swift build -c release", "swift test"):
            command = token.removeprefix("xcodebuild ")
            with self.subTest(token=token):
                modified = original.replace(command, "removed-command")
                self.assertNotIn(token, workflow_command_tokens(collect_run_blocks(modified)))
                self.assertTrue(reverse_check(set(), "`" + token + "`", modified))

    def test_shell_character_classes_are_not_gradle_tasks(self):
        self.assertEqual(workflow_command_tokens([
            "tr -d '[:space:]' < pin\n./gradlew :shared:testAndroidHostTest"
        ]), {":shared:testAndroidHostTest"})

    def test_missing_secondary_job_is_detected(self):
        original = (ROOT / "AGENTS.md").read_text()
        for job in ("iOS simulator", "beid-lab-cli build and test"):
            with self.subTest(job=job), tempfile.TemporaryDirectory() as directory:
                document = Path(directory) / "AGENTS.md"
                document.write_text(original.replace(job, "removed job"))
                result = subprocess.run(
                    [sys.executable, "scripts/check_pr_ci_doc_drift.py",
                     "--agents-md-path", str(document)],
                    cwd=ROOT, capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn(job, result.stderr)

    def test_repository_docs_match_all_pr_build_workflows(self):
        result = subprocess.run(
            [sys.executable, "scripts/check_pr_ci_doc_drift.py"],
            cwd=ROOT, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("3 workflow(s)", result.stdout)
