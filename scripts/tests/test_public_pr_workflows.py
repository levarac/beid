"""Public PRs must never route repository code to persistent runners."""

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github/workflows"
TRUSTED_EVENT = (
    "github.event_name != 'pull_request' || "
    "github.event.pull_request.head.repo.full_name == github.repository"
)
FORK_EVENT = (
    "github.event_name == 'pull_request' && "
    "github.event.pull_request.head.repo.full_name != github.repository"
)


def step(text, name):
    start = text.index(f"      - name: {name}\n")
    end = text.find("\n      - ", start + 1)
    return text[start:] if end < 0 else text[start:end]


class PublicPrWorkflowTests(unittest.TestCase):
    def test_every_pr_job_uses_a_literal_hosted_runner(self):
        checked = 0
        for path in WORKFLOWS.glob("*.yml"):
            text = path.read_text()
            if not re.search(r"^  pull_request(?:_target)?:", text, re.M):
                continue
            runners = re.findall(r"^    runs-on: (.+)$", text, re.M)
            self.assertTrue(runners, path.name)
            for runner in runners:
                with self.subTest(workflow=path.name, runner=runner):
                    self.assertIn(
                        runner,
                        {"ubuntu-24.04", "ubuntu-24.04-arm", "ubuntu-latest", "macos-26"},
                    )
                checked += 1
        self.assertGreaterEqual(checked, 7)

    def test_fork_comparison_has_no_secret_or_false_pass(self):
        text = (WORKFLOWS / "pr-ci.yml").read_text()
        clone = step(text, "Clone Parallax at the pinned commit")
        self.assertIn(TRUSTED_EVENT, clone)
        self.assertIn("secrets.PARALLAX_READ_TOKEN", clone)
        skipped = step(text, "Report skipped Parallax comparison for fork PRs")
        self.assertIn(FORK_EVENT, skipped)
        self.assertNotIn("secrets.", skipped)
        self.assertIn("SKIPPED", skipped)
        self.assertIn("not a passing comparison", skipped)
        self.assertIn("GITHUB_STEP_SUMMARY", skipped)
        verify = step(text, "Verify the Parallax comparison actually ran")
        self.assertIn(TRUSTED_EVENT, verify)
        self.assertIn("env.PARALLAX_REPO != ''", verify)

    def test_delivery_has_no_pull_request_trigger(self):
        for name in ("internal-google-play.yml", "internal-testflight.yml", "release-testflight.yml"):
            text = (WORKFLOWS / name).read_text()
            with self.subTest(workflow=name):
                self.assertNotRegex(text, r"(?m)^  (pull_request|pull_request_target|workflow_run):")
                self.assertIn("  push:", text)
                self.assertIn("  workflow_dispatch:", text)

    def test_privileged_pr_metadata_workflow_never_checks_out_code(self):
        for path in WORKFLOWS.glob("*.yml"):
            text = path.read_text()
            if re.search(r"^  pull_request_target:", text, re.M):
                self.assertNotIn("actions/checkout", text, path.name)
                self.assertNotIn("pull_request.head.sha", text, path.name)


if __name__ == "__main__":
    unittest.main()
