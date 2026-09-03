from __future__ import annotations

import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"
PREPARE_NOTES = ROOT / "scripts" / "prepare_testflight_notes.py"
PUBLISH_NOTES = ROOT / "scripts" / "gha" / "publish-testflight-notes.sh"
TESTFLIGHT_SKILL = ROOT / ".claude" / "skills" / "beid-testflight" / "SKILL.md"


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


class NotePreparationTests(unittest.TestCase):
    def run_prepare(
        self,
        primary: Path,
        output_dir: Path,
        fallback: Path | None = None,
    ) -> subprocess.CompletedProcess[str]:
        command = [
            sys.executable,
            str(PREPARE_NOTES),
            "--source",
            str(primary),
            "--output-dir",
            str(output_dir),
        ]
        if fallback is not None:
            command.extend(["--fallback-source", str(fallback)])
        return subprocess.run(command, text=True, capture_output=True, check=False)

    def test_existing_primary_wins_over_fallback(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            primary = root / "what_to_test.json"
            fallback = root / "what_to_test.ios.json"
            primary.write_text(
                json.dumps([{"language": "en-US", "text": "Common notes."}]),
                encoding="utf-8",
            )
            fallback.write_text(
                json.dumps([{"language": "en-US", "text": "iOS notes."}]),
                encoding="utf-8",
            )

            result = self.run_prepare(primary, root / "notes", fallback)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                (root / "notes" / "WhatToTest.en-US.txt").read_text(
                    encoding="utf-8"
                ),
                "Common notes.\n",
            )

    def test_missing_primary_uses_valid_fallback_and_removes_stale_generated_notes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fallback = root / "what_to_test.ios.json"
            fallback.write_text(
                json.dumps([{"language": "en-US", "text": "Check the join flow."}]),
                encoding="utf-8",
            )
            output = root / "notes"
            output.mkdir()
            (output / "WhatToTest.ja.txt").write_text("stale\n", encoding="utf-8")
            (output / "keep.txt").write_text("keep\n", encoding="utf-8")

            result = self.run_prepare(root / "missing.json", output, fallback)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                (output / "WhatToTest.en-US.txt").read_text(encoding="utf-8"),
                "Check the join flow.\n",
            )
            self.assertFalse((output / "WhatToTest.ja.txt").exists())
            self.assertTrue((output / "keep.txt").exists())

    def test_empty_duplicate_and_unsafe_locale_sources_fail(self):
        invalid_sources = (
            [],
            [
                {"language": "en-US", "text": "First"},
                {"language": "en-US", "text": "Second"},
            ],
            [{"language": "../en-US", "text": "Unsafe"}],
            [{"language": "1", "text": "Numeric locales are not valid."}],
        )
        for index, payload in enumerate(invalid_sources):
            with self.subTest(payload=payload), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                source = root / f"invalid-{index}.json"
                source.write_text(json.dumps(payload), encoding="utf-8")
                result = self.run_prepare(source, root / "notes")
                self.assertNotEqual(result.returncode, 0)


class NotePublicationTests(unittest.TestCase):
    def run_publisher(
        self,
        asc_body: str,
        notes: dict[str, str] | None = None,
        fail_create: bool = False,
        competing_body: str | None = None,
    ) -> tuple[subprocess.CompletedProcess[str], list[dict[str, object]]]:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            calls = root / "calls.jsonl"
            fake_asc = bin_dir / "asc"
            fake_asc.write_text(
                """#!/usr/bin/env python3
import json
import os
import sys
with open(os.environ["FAKE_ASC_CALLS"], "a", encoding="utf-8") as output:
    output.write(json.dumps({
        "argv": sys.argv[1:],
        "private_key_path": os.environ.get("ASC_PRIVATE_KEY_PATH"),
        "bypass_keychain": os.environ.get("ASC_BYPASS_KEYCHAIN"),
        "strict_auth": os.environ.get("ASC_STRICT_AUTH"),
    }) + "\\n")
if sys.argv[1:3] == ["builds", "wait"]:
    exact_selector = (
        "--version" in sys.argv
        and sys.argv[sys.argv.index("--version") + 1] == "1.0"
        and "--build-number" in sys.argv
        and sys.argv[sys.argv.index("--build-number") + 1] == "33724513679.1"
        and "--latest" not in sys.argv
    )
    if exact_selector or not os.environ.get("FAKE_ASC_COMPETING_BODY"):
        print(os.environ["FAKE_ASC_WAIT_BODY"])
    else:
        print(os.environ["FAKE_ASC_COMPETING_BODY"])
elif sys.argv[1:4] == ["builds", "test-notes", "create"]:
    if os.environ.get("FAKE_ASC_FAIL_CREATE") == "1":
        raise SystemExit(23)
    print('{"data":{"id":"localization-1"}}')
else:
    raise SystemExit(97)
""",
                encoding="utf-8",
            )
            fake_asc.chmod(0o755)
            key = root / "AuthKey.p8"
            key.write_text("test key", encoding="utf-8")
            note_dir = root / "notes"
            note_dir.mkdir()
            for locale, text in (notes or {"en-US": "Check the join flow."}).items():
                (note_dir / f"WhatToTest.{locale}.txt").write_text(
                    text + "\n", encoding="utf-8"
                )
            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{bin_dir}:{env['PATH']}",
                    "ASC_KEY_ID": "key-id",
                    "ASC_ISSUER_ID": "issuer-id",
                    "ASC_KEY_PATH": str(key),
                    "FAKE_ASC_CALLS": str(calls),
                    "FAKE_ASC_WAIT_BODY": asc_body,
                    "FAKE_ASC_COMPETING_BODY": competing_body or "",
                    "FAKE_ASC_FAIL_CREATE": "1" if fail_create else "0",
                }
            )
            result = subprocess.run(
                [
                    "zsh",
                    str(PUBLISH_NOTES),
                    str(note_dir),
                    "1.0",
                    "33724513679.1",
                ],
                cwd=ROOT,
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )
            recorded = []
            if calls.exists():
                recorded = [json.loads(line) for line in calls.read_text().splitlines()]
            return result, recorded

    def test_publishes_each_locale_to_exact_build_returned_by_wait(self):
        result, calls = self.run_publisher(
            '{"buildId":"build-123","processingState":"VALID"}',
            {"en-US": "Check joining.", "ja": "参加を確認してください。"},
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 3)
        wait = calls[0]
        self.assertEqual(wait["argv"][:2], ["builds", "wait"])
        self.assertNotIn("--latest", wait["argv"])
        self.assertIn("1.0", wait["argv"])
        self.assertIn("33724513679.1", wait["argv"])
        self.assertTrue(str(wait["private_key_path"]).endswith("/AuthKey.p8"))
        self.assertEqual(wait["bypass_keychain"], "1")
        self.assertEqual(wait["strict_auth"], "true")
        for call in calls[1:]:
            self.assertEqual(call["argv"][:3], ["builds", "test-notes", "create"])
            self.assertIn("build-123", call["argv"])

    def test_competing_newer_build_is_rejected_by_exact_upload_identifier(self):
        result, calls = self.run_publisher(
            '{"buildId":"this-run-build","processingState":"VALID"}',
            competing_body=(
                '{"buildId":"competing-newer-build","processingState":"VALID"}'
            ),
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[1]["argv"][:3], ["builds", "test-notes", "create"])
        self.assertIn("this-run-build", calls[1]["argv"])
        self.assertNotIn("competing-newer-build", calls[1]["argv"])

    def test_invalid_wait_output_and_note_upload_failure_are_terminal(self):
        invalid_result, invalid_calls = self.run_publisher("{}")
        self.assertNotEqual(invalid_result.returncode, 0)
        self.assertEqual(len(invalid_calls), 1)

        upload_result, upload_calls = self.run_publisher(
            '{"buildId":"build-123","processingState":"VALID"}', fail_create=True
        )
        self.assertEqual(upload_result.returncode, 23)
        self.assertEqual(len(upload_calls), 2)


class NoteWorkflowWiringTests(unittest.TestCase):
    def test_workflows_select_their_note_sources(self):
        internal = workflow_text("internal-testflight.yml")
        release = workflow_text("release-testflight.yml")
        self.assertIn("TESTFLIGHT_NOTES_SOURCE: what_to_test.json", internal)
        self.assertIn("TESTFLIGHT_NOTES_FALLBACK_SOURCE: what_to_test.ios.json", internal)
        self.assertIn("TESTFLIGHT_NOTES_SOURCE: release_notes.json", release)
        self.assertNotIn("TESTFLIGHT_NOTES_FALLBACK_SOURCE:", release)

    def test_delivery_script_prepares_before_upload_and_publishes_after_upload(self):
        script = (ROOT / "scripts" / "gha" / "build-and-upload-ios.sh").read_text(
            encoding="utf-8"
        )
        prepare = script.index("prepare_testflight_notes.py")
        upload = script.index("-exportArchive")
        publish = script.index("publish-testflight-notes.sh")
        self.assertLess(prepare, upload)
        self.assertLess(upload, publish)
        self.assertIn('GITHUB_RUN_ID', script)
        self.assertIn('GITHUB_RUN_ATTEMPT', script)
        self.assertIn('CURRENT_PROJECT_VERSION="$UPLOAD_BUILD_NUMBER"', script)
        self.assertIn('manageAppVersionAndBuildNumber -bool NO', script)
        self.assertIn('CFBundleShortVersionString', script)
        self.assertIn('CFBundleVersion', script)
        self.assertIn(
            '"$TESTFLIGHT_NOTES_DIR" "$ARCHIVED_MARKETING_VERSION" "$ARCHIVED_BUILD_NUMBER"',
            script,
        )

    def test_project_skill_covers_generic_note_requests_and_actual_locale_sets(self):
        skill = TESTFLIGHT_SKILL.read_text(encoding="utf-8")
        description = skill.split("---", 2)[1]
        self.assertIn("tester notes", description)
        self.assertIn("release notes", description)
        self.assertIn("Internal tester notes: `en-US`", skill)
        self.assertIn("Release notes: preserve `ja` and `en-US`", skill)


if __name__ == "__main__":
    unittest.main()
