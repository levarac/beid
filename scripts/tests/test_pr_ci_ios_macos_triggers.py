"""Pin the trigger contract of the self-hosted iOS lane (gh#479).

This lane occupies the single self-hosted macOS host for ~30 minutes and gates
nothing, so *when* it runs is the whole point of its configuration. Re-adding
`synchronize` would silently restore the per-push behavior #479 removed, and
nothing else in CI would notice: `scripts/check_pr_ci_doc_drift.py` covers only
`pr-ci.yml`, and the lane is informational so a regression never turns a check
red. These assertions are that missing guard rail.

Text/regex based rather than YAML based, matching the sibling workflow tests:
PyYAML is not a dependency of this repository, and `on:` would parse as the
boolean key `True` under it anyway.
"""

import re
import unittest
from pathlib import Path


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
    'scripts/resolve_kmp_java_home.sh',
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
    def test_pull_request_fires_only_on_ready_for_review(self) -> None:
        block = trigger_block(workflow_text())
        section = event_section(block, "pull_request")

        self.assertIn("    types: [ready_for_review]\n", section)
        for event in ("synchronize", "opened", "reopened", "edited"):
            with self.subTest(event=event):
                self.assertNotIn(event, section)

    def test_push_is_limited_to_main(self) -> None:
        block = trigger_block(workflow_text())
        section = event_section(block, "push")

        self.assertIn("    branches: [main]\n", section)
        self.assertNotIn("tags:", section)

    def test_manual_dispatch_is_available(self) -> None:
        block = trigger_block(workflow_text())

        self.assertIn("  workflow_dispatch:", block)

    def test_both_filtered_events_keep_the_same_paths_filter(self) -> None:
        block = trigger_block(workflow_text())

        for event in ("pull_request", "push"):
            with self.subTest(event=event):
                section = event_section(block, event)
                found = re.findall(r'^      - "(.+)"$', section, re.MULTILINE)
                self.assertEqual(found, EXPECTED_PATHS)

    def test_concurrency_still_cancels_superseded_runs(self) -> None:
        text = workflow_text()

        self.assertIn("  group: pr-ios-macos-${{ github.ref }}\n", text)
        self.assertIn("  cancel-in-progress: true\n", text)


if __name__ == "__main__":
    unittest.main()
