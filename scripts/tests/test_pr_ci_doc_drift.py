"""The default documentation gate must include the separate hosted lanes."""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from scripts.check_pr_ci_doc_drift import workflow_command_tokens


ROOT = Path(__file__).resolve().parents[2]


class PrCiDocDriftTests(unittest.TestCase):
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
