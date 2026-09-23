import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from scripts.check_pr_ci_doc_drift import workflow_command_tokens


ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "scripts/check_pr_ci_doc_drift.py"
FIXTURES = Path(__file__).with_name("fixtures")
COMMAND = "python3 -m unittest discover -s scripts/tests -t ."


class PrCiDocDriftTests(unittest.TestCase):
    def run_checker(self, workflow_text, agents_text):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            workflow = directory / "workflow.yml"
            agents = directory / "AGENTS.md"
            workflow.write_text(workflow_text, encoding="utf-8")
            agents.write_text(agents_text, encoding="utf-8")
            return subprocess.run(
                [
                    sys.executable,
                    str(CHECKER),
                    "--workflow-path",
                    str(workflow),
                    "--agents-md-path",
                    str(agents),
                ],
                check=False,
                capture_output=True,
                text=True,
            )

    def setUp(self):
        self.workflow = (FIXTURES / "pr_ci_doc_drift_workflow.yml").read_text(
            encoding="utf-8"
        )
        self.agents = (FIXTURES / "pr_ci_doc_drift_agents.md").read_text(
            encoding="utf-8"
        )

    def test_matching_fixture_passes(self):
        result = self.run_checker(self.workflow, self.agents)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1 command token(s) checked", result.stdout)

    def test_removing_documented_token_fails_forward_check(self):
        result = self.run_checker(self.workflow, self.agents.replace(f"`{COMMAND}`", "tests"))
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"missing command token '{COMMAND}'", result.stderr)

    def test_removing_workflow_token_fails_reverse_check(self):
        result = self.run_checker(self.workflow.replace(COMMAND, "python3 --version"), self.agents)
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"quotes command token '{COMMAND}'", result.stderr)

    def test_literal_multiline_run_recognizes_split_command(self):
        block = "python3 -m unittest discover \\\n  -s scripts/tests \\\n  -t ."
        self.assertEqual(workflow_command_tokens([block]), {COMMAND})

        multiline_workflow = self.workflow.replace(
            f"run: {COMMAND}",
            "run: |\n"
            "          python3 -m unittest discover \\\n"
            "            -s scripts/tests \\\n"
            "            -t .",
        )
        result = self.run_checker(multiline_workflow, self.agents)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1 command token(s) checked", result.stdout)

    def test_harmless_whitespace_formatting_uses_canonical_token(self):
        block = "  python3   -m unittest discover -s scripts/tests   -t .  "
        self.assertEqual(workflow_command_tokens([block]), {COMMAND})

    def test_command_text_inside_another_command_is_not_a_token(self):
        block = f'echo "{COMMAND}"'
        self.assertEqual(workflow_command_tokens([block]), set())


if __name__ == "__main__":
    unittest.main()
