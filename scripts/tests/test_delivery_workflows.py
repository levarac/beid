from __future__ import annotations

import re
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"


def workflow_text(name: str) -> str:
    return (WORKFLOWS / name).read_text(encoding="utf-8")


def push_block(text: str) -> str:
    match = re.search(r"(?ms)^  push:\n(?P<body>.*?)(?=^  [a-zA-Z_]+:|\Z)", text)
    if match is None:
        raise AssertionError("workflow has no configured push event")
    return match.group("body")


def push_list(text: str, key: str) -> list[str]:
    block = push_block(text)
    match = re.search(
        rf"(?m)^    {re.escape(key)}:\n(?P<items>(?:      - .+\n)+)", block
    )
    if match is None:
        return []
    return [
        line.removeprefix("      - ").strip().strip("'\"")
        for line in match.group("items").splitlines()
    ]


class DeliveryTriggerTests(unittest.TestCase):
    def test_internal_testflight_runs_on_note_changes_on_any_branch(self):
        text = workflow_text("internal-testflight.yml")
        self.assertEqual(push_list(text, "branches"), ["**"])
        self.assertEqual(
            push_list(text, "paths"),
            ["what_to_test.json", "what_to_test.ios.json"],
        )
        self.assertIn("  workflow_dispatch:", text)

    def test_internal_google_play_runs_on_note_changes_on_any_branch(self):
        text = workflow_text("internal-google-play.yml")
        self.assertEqual(push_list(text, "branches"), ["**"])
        self.assertEqual(
            push_list(text, "paths"),
            ["what_to_test.json", "what_to_test.android.json"],
        )
        self.assertIn("  workflow_dispatch:", text)

    def test_release_testflight_requires_release_branch_and_release_notes_change(self):
        text = workflow_text("release-testflight.yml")
        self.assertEqual(push_list(text, "branches"), ["release/**"])
        self.assertEqual(push_list(text, "paths"), ["release_notes.json"])
        self.assertNotIn("paths-ignore:", push_block(text))
        self.assertIn("  workflow_dispatch:", text)


if __name__ == "__main__":
    unittest.main()
