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
                      "python3 -m unittest discover \\\n  -s scripts/tests \\\n  -t ."):
            with self.subTest(block=block):
                self.assertEqual(workflow_command_tokens([block]), {command})

    def check_discovery_scalar(self, scalar, expected, documented=None):
        command = "python3 -m unittest discover -s scripts/tests -t ."
        workflow = "jobs:\n  sanity:\n    name: Repository sanity\n    steps:\n      - name: Script tests\n        run: " + scalar
        document = f"### PR CI\nRepository sanity runs `{documented or command}`.\n"
        result = self.run_checker([workflow], document)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)

    def test_heredoc_text_is_not_execution(self):
        command = "python3 -m unittest discover -s scripts/tests -t ."
        for opener, end in (("cat <<'EOF'", "EOF"), ("cat <<EOF", "EOF"),
                            ('cat <<"EOF"', "EOF"), ("cat <<-EOF", "\tEOF")):
            with self.subTest(opener=opener):
                self.check_discovery_scalar(f"|\n          {opener}\n          {command}\n          {end}\n", 1)

    def test_literal_lines_do_not_form_one_command(self):
        self.check_discovery_scalar("|\n          python3 -m unittest discover\n          -s scripts/tests -t .\n", 1)

    def test_quoted_heredoc_operator_does_not_hide_execution(self):
        self.check_discovery_scalar("|\n          echo '<<' EOF\n          python3 -m unittest discover -s scripts/tests -t .\n", 0)

    def test_heredoc_terminator_is_not_execution(self):
        command = "python3 -m unittest discover -s scripts/tests -t ."
        self.check_discovery_scalar(f"|\n          cat <<'{command}'\n          text\n          {command}\n", 1)

    def test_execution_after_multiple_heredocs_counts(self):
        self.check_discovery_scalar("|\n          cat <<ONE <<'TWO'\n          first\n          ONE\n          second\n          TWO\n          python3 -m unittest discover -s scripts/tests -t .\n", 0)

    def test_multiline_quoted_string_is_not_execution(self):
        self.check_discovery_scalar('|\n          echo "text\n          python3 -m unittest discover -s scripts/tests -t .\n          "\n', 1)

    def test_continued_command_after_setup_executes(self):
        self.check_discovery_scalar("|\n          set -eu\n          python3 -m unittest discover \\\n            -s scripts/tests \\\n            -t .\n", 0)

    def test_folded_scalar_forms_one_command(self):
        self.check_discovery_scalar(">-\n          python3 -m unittest discover\n          -s scripts/tests -t .\n", 0)

    def test_yaml_quoted_scalar_executes(self):
        self.check_discovery_scalar('"python3 -m unittest discover -s scripts/tests -t ."\n', 0)

    def test_documented_discovery_normalizes_spaces_and_quotes(self):
        for command in ("python3  -m unittest discover -s scripts/tests -t .",
                        "python3 -m unittest discover -s 'scripts/tests' -t ."):
            with self.subTest(command=command):
                self.check_discovery_scalar("python3 -m unittest discover -s scripts/tests -t .\n", 0, command)

    def test_extra_documented_flag_is_a_mismatch(self):
        command = "python3 -m unittest discover -s scripts/tests -t ."
        self.check_discovery_scalar(command + "\n", 1, command + " --failfast")

    def test_extra_workflow_flag_is_a_mismatch(self):
        command = "python3 -m unittest discover -s scripts/tests -t ."
        self.check_discovery_scalar(command + " --failfast\n", 1)

    def test_matching_extra_flags_are_documented(self):
        command = "python3 -m unittest discover -s scripts/tests -t . --failfast"
        self.check_discovery_scalar(command + "\n", 0, command)

    def test_discovery_mentions_are_not_commands(self):
        command = "python3 -m unittest discover -s scripts/tests -t ."
        for block in (f'echo "{command}"', f"# {command}"):
            with self.subTest(block=block):
                self.assertEqual(workflow_command_tokens([block]), set())

    def test_changed_arguments_remain_distinct_commands(self):
        command = "python3 -m unittest discover -s scripts/tests -t ."
        for changed in (command.replace("scripts/tests", "other/tests"), command + " --failfast"):
            with self.subTest(changed=changed):
                self.assertEqual(workflow_command_tokens([changed]), {changed})

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
