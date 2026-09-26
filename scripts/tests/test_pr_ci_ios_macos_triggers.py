"""Keep the hosted iOS gate current on every PR head, including drafts."""

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
    'scripts/download_xcodegen.sh',
    'scripts/ci_simulator.py',
    'scripts/ci_ios_results.py',
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
        section = event_section(trigger_block(workflow_text()), "pull_request")
        self.assertIn("    types: [opened, synchronize, reopened, ready_for_review]\n", section)
        self.assertNotIn("paths:", section)

    def test_drafts_also_get_exact_head_evidence(self) -> None:
        text = workflow_text()
        self.assertNotIn("pull_request.draft", text)
        self.assertIn("ref: ${{ github.event.pull_request.head.sha || github.sha }}", text)

    def test_push_is_limited_to_main(self) -> None:
        block = trigger_block(workflow_text())
        section = event_section(block, "push")

        self.assertIn("    branches: [main]\n", section)
        self.assertNotIn("tags:", section)

    def test_manual_dispatch_is_available(self) -> None:
        block = trigger_block(workflow_text())

        self.assertIn("  workflow_dispatch:", block)

    def test_main_push_keeps_the_paths_filter(self) -> None:
        block = trigger_block(workflow_text())

        for event in ("push",):
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
