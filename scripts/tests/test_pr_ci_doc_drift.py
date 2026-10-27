"""The default documentation gate must include the separate hosted lanes."""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from scripts.check_pr_ci_doc_drift import workflow_command_tokens


ROOT = Path(__file__).resolve().parents[2]


class PrCiDocDriftTests(unittest.TestCase):
    def run_checker(self, workflows, document):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            arguments = []
            for index, workflow in enumerate(workflows):
                path = folder / f"workflow-{index}.yml"
                path.write_text(workflow)
                arguments.extend(["--workflow-path", str(path)])
            path = folder / "AGENTS.md"
            path.write_text(document)
            return subprocess.run(
                [sys.executable, "scripts/check_pr_ci_doc_drift.py", *arguments,
                 "--agents-md-path", str(path)],
                cwd=ROOT, capture_output=True, text=True,
            )

    def test_discovery_command_is_recognized_in_shell_forms(self):
        command = "python3 -m unittest discover -s scripts/tests -t ."
        for block in (command, "  python3   -m unittest discover -s scripts/tests -t .  ",
                      "set -eu\n" + command,
                      "python3 -m unittest discover \\\n  -s scripts/tests \\\n  -t .",
                      "python3 -m unittest discover\n  -s scripts/tests -t ."):
            with self.subTest(block=block):
                self.assertEqual(workflow_command_tokens([block]), {command})

    def test_discovery_mentions_and_changed_arguments_are_not_commands(self):
        command = "python3 -m unittest discover -s scripts/tests -t ."
        for block in (f'echo "{command}"', f"# {command}",
                      command.replace("scripts/tests", "other/tests"),
                      command + " --failfast"):
            with self.subTest(block=block):
                self.assertEqual(workflow_command_tokens([block]), set())

    def test_discovery_deletion_is_detected_in_both_directions_on_hosted_workflows(self):
        command = "python3 -m unittest discover -s scripts/tests -t ."
        workflows = [(ROOT / ".github/workflows" / name).read_text() for name in
                     ("pr-ci.yml", "pr-ci-ios-macos.yml", "pr-ci-lab-cli.yml")]
        document = (ROOT / "AGENTS.md").read_text()
        for side in ("workflow", "documentation"):
            with self.subTest(side=side):
                changed = [text.replace(command, f'echo "{command}"') for text in workflows]
                result = self.run_checker(
                    changed if side == "workflow" else workflows,
                    document.replace(command, "removed discovery") if side == "documentation" else document,
                )
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn(command, result.stderr)

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
