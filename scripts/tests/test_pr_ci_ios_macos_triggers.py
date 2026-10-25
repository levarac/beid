"""Keep the hosted iOS gate current on every PR head, including drafts."""

import re
import unittest
from pathlib import Path


from scripts.tests.workflow_yaml import workflow_data


WORKFLOW_PATH = Path(__file__).parents[2] / ".github/workflows/pr-ci-ios-macos.yml"

EXPECTED_PATHS = [
    '.github/workflows/pr-ci-ios-macos.yml',
    'ios/**',
    'shared/**',
    'android/build.gradle.kts',
    'android/settings.gradle.kts',
    'android/gradle.properties',
    'android/gradlew',
    'android/gradle/wrapper/**',
    'android/gradle/*.toml',
    'scripts/ci_change_filter.py',
    'scripts/xcodegen_generate_checked.sh',
    'scripts/resolve_kmp_java_home.sh',
    'scripts/download_xcodegen.sh',
    'scripts/ci_simulator.py',
    'scripts/ios_ui_smoke.py',
    'scripts/ios_test_shards.py',
    'scripts/run_local_tests.py',
]


def workflow_text() -> str:
    return WORKFLOW_PATH.read_text(encoding="utf-8")


def trigger_block(text: str) -> str:
    """Return the top-level `on:` block with comment lines removed.

    Comments are stripped because the block's own rationale comment names the
    events it deliberately excludes; asserting over the raw text would match
    the explanation instead of the configuration.
    """
    start = text.index("on:\n")
    end = text.index("\npermissions:\n", start)
    lines = text[start:end].splitlines()
    return "\n".join(line for line in lines if not line.lstrip().startswith("#"))


def event_section(block: str, event: str) -> str:
    marker = f"  {event}:\n"
    start = block.index(marker) + len(marker)
    rest = block[start:]
    match = re.search(r"^  \S", rest, re.MULTILINE)
    return rest if match is None else rest[: match.start()]


class PrCiIosMacosTriggerTest(unittest.TestCase):
    def test_pull_request_fires_on_every_head(self) -> None:
        section = workflow_data(workflow_text())["on"]["pull_request"]
        self.assertEqual(set(section), {"types"})
        self.assertEqual(set(section["types"]),
                         {"opened", "synchronize", "reopened", "ready_for_review", "labeled"})

    def test_drafts_also_get_exact_head_evidence(self) -> None:
        data = workflow_data(workflow_text())
        checkouts = []
        for job in data["jobs"].values():
            self.assertNotIn("pull_request.draft", job.get("if", ""))
            for step in job.get("steps", []):
                self.assertNotIn("pull_request.draft", step.get("if", ""))
                if step.get("uses", "").startswith("actions/checkout@"):
                    checkouts.append(step)
        self.assertTrue(checkouts)
        for step in checkouts:
            self.assertEqual(step["with"]["ref"],
                             "${{ github.event.pull_request.head.sha || github.sha }}")

    def test_push_is_limited_to_main(self) -> None:
        section = workflow_data(workflow_text())["on"]["push"]
        self.assertEqual(section["branches"], ["main"])
        self.assertNotIn("tags", section)
        self.assertNotIn("branches-ignore", section)

    def test_manual_dispatch_is_available(self) -> None:
        self.assertIn("workflow_dispatch", workflow_data(workflow_text())["on"])

    def test_main_push_keeps_the_paths_filter(self) -> None:
        paths = workflow_data(workflow_text())["on"]["push"]["paths"]
        self.assertEqual(set(paths), set(EXPECTED_PATHS))
        self.assertEqual(len(paths), len(EXPECTED_PATHS))

    def test_nightly_schedule_has_no_pr_filter(self) -> None:
        events = workflow_data(workflow_text())["on"]
        self.assertEqual(events["schedule"], [{"cron": "23 3 * * *"}])
        self.assertNotIn("unlabeled", events["pull_request"]["types"])

    def test_run_name_displays_payload_mode(self) -> None:
        name = workflow_data(workflow_text())["run-name"]
        self.assertIn("github.event_name == 'pull_request'", name)
        self.assertIn("github.event.pull_request.labels.*.name", name)
        self.assertIn("ci:full-ui", name)
        self.assertIn("'smoke' || 'full'", name)

    def test_concurrency_still_cancels_superseded_runs(self) -> None:
        concurrency = workflow_data(workflow_text())["concurrency"]
        self.assertEqual(concurrency["group"],
                         "pr-ios-macos-${{ github.event_name }}-${{ github.ref }}")
        self.assertEqual(concurrency["cancel-in-progress"], "true")


if __name__ == "__main__":
    unittest.main()
