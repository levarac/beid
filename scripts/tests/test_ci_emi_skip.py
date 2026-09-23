"""Contract for routing repository-only PR CI changes away from emi."""

import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from scripts.ci_emi_skip import should_skip_emi


ROOT = Path(__file__).resolve().parents[2]
SELECTOR = ROOT / "scripts/ci_emi_skip.py"
WORKFLOW = ROOT / ".github/workflows/pr-ci.yml"

REPOSITORY_ONLY_FILES = [
    ".github/workflows/pr-ci.yml",
    "AGENTS.md",
    "docs/delivery-ci.md",
    "scripts/check_pr_ci_doc_drift.py",
    "scripts/ci_emi_skip.py",
    "scripts/tests/fixtures/pr_ci_doc_drift_agents.md",
    "scripts/tests/fixtures/pr_ci_doc_drift_workflow.yml",
    "scripts/tests/test_check_pr_ci_doc_drift.py",
    "scripts/tests/test_ci_emi_skip.py",
]


class CIEmiSkipTests(unittest.TestCase):
    def select(self, payload):
        with tempfile.TemporaryDirectory() as directory:
            input_path = Path(directory) / "changed-files.json"
            input_path.write_text(json.dumps(payload), encoding="utf-8")
            return subprocess.run(
                [sys.executable, str(SELECTOR), "--input", str(input_path)],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=False,
            )

    def test_repository_only_checker_change_skips_emi(self):
        result = self.select({"files": REPOSITORY_ONLY_FILES})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "emi_skip=true")

    def test_mixed_product_change_does_not_skip_emi(self):
        result = self.select({"files": REPOSITORY_ONLY_FILES + ["android/app/src/main/Foo.kt"]})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "emi_skip=false")

    def test_other_workflow_change_does_not_skip_emi(self):
        result = self.select({"files": [".github/workflows/pr-ci.yml"]})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "emi_skip=false")

    def test_only_the_exact_reviewed_file_set_can_skip_emi(self):
        self.assertFalse(should_skip_emi(REPOSITORY_ONLY_FILES[:-1]))

    def test_changed_workflow_content_cannot_reuse_the_exception(self):
        with tempfile.TemporaryDirectory() as directory:
            changed_workflow = Path(directory) / "pr-ci.yml"
            changed_workflow.write_text(
                WORKFLOW.read_text(encoding="utf-8") + "\n# unrelated workflow change\n",
                encoding="utf-8",
            )
            self.assertFalse(
                should_skip_emi(REPOSITORY_ONLY_FILES, workflow_path=changed_workflow)
            )

    def test_unknown_input_fails_instead_of_routing_to_emi(self):
        for payload in ({"error": "GitHub API unavailable"}, {"files": []}, {"files": [12]}):
            with self.subTest(payload=payload):
                result = self.select(payload)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("emi_skip=false", result.stdout)

    def test_workflow_guards_both_emi_jobs_and_keeps_linux_sanity(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        changes = workflow.split("\n  changes:\n", 1)[1].split("\n  android:\n", 1)[0]
        self.assertIn("runs-on: ubuntu-24.04-arm", changes)
        self.assertIn("emi_skip: ${{ steps.emi_scope.outputs.emi_skip }}", workflow)
        self.assertIn(
            'run: python3 scripts/ci_emi_skip.py --input "$RUNNER_TEMP/beid-changed-files.json" >> "$GITHUB_OUTPUT"',
            workflow,
        )
        for job_name in ("android", "lint"):
            with self.subTest(job=job_name):
                tail = workflow.split(f"\n  {job_name}:\n", 1)[1]
                job = re.split(r"\n  [A-Za-z_][A-Za-z0-9_-]*:\n", tail, maxsplit=1)[0]
                self.assertIn("needs.changes.result == 'success'", job)
                self.assertIn("needs.changes.outputs.emi_skip != 'true'", job)
                self.assertIn("runs-on: [self-hosted, macOS, ARM64, emi]", job)
        sanity = workflow.split("\n  sanity:\n", 1)[1]
        self.assertIn("runs-on: ubuntu-24.04-arm", sanity)
        self.assertIn("name: Require successful changed-path classification", sanity)
        self.assertIn("if: ${{ always() && needs.changes.result != 'success' }}", sanity)
        self.assertIn("exit 1", sanity)
        self.assertIn("python3 -m unittest discover -s scripts/tests -t .", sanity)


if __name__ == "__main__":
    unittest.main()
