"""Public PRs must never route repository code to persistent runners."""

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github/workflows"


class PublicPrWorkflowTests(unittest.TestCase):
    def test_every_pr_job_uses_a_literal_hosted_runner(self):
        checked = 0
        for path in sorted(p for p in WORKFLOWS.iterdir() if p.suffix in {".yml", ".yaml"}):
            text = path.read_text()
            if not re.search(r"^  pull_request(?:_target)?:", text, re.M):
                continue
            runners = re.findall(r"^    runs-on: (.+)$", text, re.M)
            self.assertTrue(runners, path.name)
            for runner in runners:
                with self.subTest(workflow=path.name, runner=runner):
                    self.assertIn(
                        runner,
                        {"ubuntu-24.04", "ubuntu-24.04-arm", "macos-26"},
                    )
                checked += 1
        self.assertGreaterEqual(checked, 7)

    def test_pr_build_lanes_report_every_head_without_workflow_path_filters(self):
        for name in ("pr-ci-ios-macos.yml", "pr-ci-lab-cli.yml"):
            text = (WORKFLOWS / name).read_text()
            pr = text.split("  pull_request:\n", 1)[1].split("  push:\n", 1)[0]
            self.assertIn("types: [opened, synchronize, reopened, ready_for_review]", pr)
            self.assertNotIn("paths:", pr)
            self.assertNotIn("informational", text)
        for name in ("pr-ci.yml", "pr-ci-ios-macos.yml", "pr-ci-lab-cli.yml"):
            text = (WORKFLOWS / name).read_text()
            for checkout in text.split("- uses: actions/checkout@")[1:]:
                block = checkout.split("\n      - ", 1)[0]
                self.assertIn("ref: ${{ github.event.pull_request.head.sha || github.sha }}", block)
                self.assertIn("persist-credentials: false", block)

    def test_every_checkout_discards_credentials(self):
        checked = 0
        for path in sorted(p for p in WORKFLOWS.iterdir() if p.suffix in {".yml", ".yaml"}):
            if path.suffix not in {".yml", ".yaml"}:
                continue
            for step in re.split(r"(?m)^      - ", path.read_text())[1:]:
                if re.search(r"(?:^|\n        )uses: actions/checkout@", step):
                    with self.subTest(workflow=path.name, checkout=checked):
                        self.assertIn("          persist-credentials: false\n", step)
                    checked += 1
        self.assertGreaterEqual(checked, 10)

    def test_macos_builds_pin_the_available_xcode(self):
        for name in ("pr-ci-ios-macos.yml", "main-ios-release-build.yml", "pr-ci-lab-cli.yml"):
            text = (WORKFLOWS / name).read_text()
            self.assertIn("DEVELOPER_DIR: /Applications/Xcode_26.5.app/Contents/Developer", text)
            self.assertNotIn("for app in /Applications/Xcode*.app", text)

    def test_public_pr_workflows_have_no_secrets(self):
        for path in sorted(p for p in WORKFLOWS.iterdir() if p.suffix in {".yml", ".yaml"}):
            text = path.read_text()
            if re.search(r"^  pull_request(?:_target)?:", text, re.M):
                self.assertNotRegex(text, r"\$\{\{[^}]*secrets[.\[]", path.name)
        text = (WORKFLOWS / "pr-ci.yml").read_text()
        self.assertIn("SKIPPED", text)
        self.assertIn("not a passing comparison", text)

    def test_all_actions_are_pinned_and_annotated(self):
        for path in sorted(p for p in WORKFLOWS.iterdir() if p.suffix in {".yml", ".yaml"}):
            for action in re.findall(r"(?m)^\s+(?:- )?uses: (.+)$", path.read_text()):
                self.assertRegex(action, r"^[\w/-]+@[0-9a-f]{40} # v[\w.]+$", path.name)

    def test_every_runner_is_hosted(self):
        for path in sorted(p for p in WORKFLOWS.iterdir() if p.suffix in {".yml", ".yaml"}):
            for runner in re.findall(r"(?m)^    runs-on: (.+)$", path.read_text()):
                self.assertIn(runner, {"ubuntu-24.04", "ubuntu-24.04-arm", "macos-26"})

    def test_secret_lanes_are_main_only_and_environment_protected(self):
        for name, environment in (("internal-google-play.yml", "google-play-internal"),
                                  ("trusted-parallax-comparison.yml", "parallax-comparison")):
            text = (WORKFLOWS / name).read_text()
            self.assertNotRegex(text, r"(?m)^  (pull_request|pull_request_target|workflow_run):")
            self.assertIn("github.ref == 'refs/heads/main'", text)
            self.assertIn("    environment: " + environment, text)
            self.assertIn("  workflow_dispatch:", text)

    def test_every_secret_reference_belongs_to_an_approved_main_only_job(self):
        approved = {
            ("internal-google-play.yml", "deliver"): "google-play-internal",
            ("trusted-parallax-comparison.yml", "compare"): "parallax-comparison",
        }
        found = set()
        secret = re.compile(r"\$\{\{[^}]*secrets[.\[]")
        for path in sorted(p for p in WORKFLOWS.iterdir() if p.suffix in {".yml", ".yaml"}):
            text = path.read_text()
            preamble, jobs = text.split("\njobs:\n", 1)
            self.assertNotRegex(preamble, secret, path.name)
            blocks = re.split(r"(?m)^  ([\w-]+):\n", jobs)
            for job, block in zip(blocks[1::2], blocks[2::2]):
                if not secret.search(block):
                    continue
                key = (path.name, job)
                with self.subTest(workflow=path.name, job=job):
                    self.assertIn(key, approved)
                    self.assertIn("    environment: " + approved[key] + "\n", block)
                    self.assertIn("github.ref == 'refs/heads/main'", block)
                    self.assertNotRegex(preamble, r"(?m)^  (pull_request|pull_request_target|workflow_run):")
                found.add(key)
        self.assertEqual(found, set(approved))

    def test_ios_delivery_is_not_reachable_from_actions(self):
        for name in ("internal-testflight.yml", "release-testflight.yml"):
            self.assertFalse((WORKFLOWS / name).exists())
        for path in sorted(p for p in WORKFLOWS.iterdir() if p.suffix in {".yml", ".yaml"}):
            self.assertNotIn("build-and-upload-ios.sh", path.read_text())

    def test_default_permissions_are_read_only(self):
        for path in sorted(p for p in WORKFLOWS.iterdir() if p.suffix in {".yml", ".yaml"}):
            text = path.read_text()
            baseline = text.split("permissions:\n", 1)[1].split("\n\n", 1)[0]
            self.assertEqual(baseline.strip(), "contents: read", path.name)
            writes = re.findall(r"(?m)^\s+([\w-]+): write$", text)
            expected = ["pull-requests"] if path.name == "release-notes-warning.yml" else []
            self.assertEqual(writes, expected, path.name)

    def test_privileged_pr_metadata_workflow_never_checks_out_code(self):
        for path in sorted(p for p in WORKFLOWS.iterdir() if p.suffix in {".yml", ".yaml"}):
            text = path.read_text()
            if re.search(r"^  pull_request_target:", text, re.M):
                self.assertNotIn("actions/checkout", text, path.name)
                self.assertNotIn("pull_request.head.sha", text, path.name)


if __name__ == "__main__":
    unittest.main()
