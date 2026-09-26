"""Contract tests for publishing what_to_test text to testers (beid#503).

**These assert that removing a wiring turns something red, not that the wiring
is written down.** A test that greps for the string it expects passes against a
lane that reads the file and then throws the text away, which is the failure
mode this repository keeps finding. So each of the three publication paths is
*executed* here against a synthetic checkout, and the assertion is on the bytes
that reach the store's own input:

* Xcode Cloud — run `ci_post_xcodebuild.sh` and read `WhatToTest.<locale>.txt`.
* Google Play — run the workflow step's own shell and read `whatsnew-<locale>`,
  then check the upload action is pointed at exactly that directory.
* the emi TestFlight lane — the only path that cannot be run from a pull
  request, since it needs a real upload and a runner-local signing key. Its
  request shapes are covered by `test_set_testflight_whats_new.py`; what is
  asserted here is the call site, including that it runs *after* the export.

The fixtures deliberately give each source file a distinct text. Asserting on
the text rather than on the filename is what makes the platform preference
falsifiable: a lane that fell back to the shared file would still produce a
correctly named output.
"""

import json
import re
import shutil
import subprocess
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

REPO_ROOT = Path(__file__).resolve().parents[2]
POST_XCODEBUILD = REPO_ROOT / "ios/ci_scripts/ci_post_xcodebuild.sh"
PLAY_WORKFLOW = REPO_ROOT / ".github/workflows/internal-google-play.yml"
IOS_WORKFLOW = REPO_ROOT / ".github/workflows/internal-testflight.yml"
IOS_DELIVERY = REPO_ROOT / "scripts/gha/build-and-upload-ios.sh"
FORMATTER = REPO_ROOT / "scripts/prepare_testflight_notes.py"

SHARED_TEXT = "shared what to test"
IOS_TEXT = "ios only what to test"
ANDROID_TEXT = "android only what to test"
RELEASE_TEXT = "marketing release note"


def shell_for(script: Path) -> str:
    """The script's own interpreter when present, else bash.

    `ci_post_xcodebuild.sh` is `#!/bin/zsh`, and the Linux runner that executes
    these tests may not have zsh. Falling back keeps the contract executed
    everywhere rather than skipped where it would matter most; the shebang
    itself is asserted separately.
    """
    interpreter = script.read_text(encoding="utf-8").splitlines()[0].removeprefix("#!").strip()
    name = Path(interpreter).name
    return name if shutil.which(name) else "bash"


def write_notes(path: Path, text: str) -> None:
    path.write_text(json.dumps([{"language": "en-US", "text": text}]), encoding="utf-8")


def make_checkout(root: Path, *, ios: bool = False, android: bool = False,
                  release: bool = False, shared: bool = True) -> Path:
    """A minimal tree with the real scripts in their real relative places."""
    (root / "scripts").mkdir(parents=True, exist_ok=True)
    shutil.copy2(FORMATTER, root / "scripts/prepare_testflight_notes.py")
    (root / "ios/ci_scripts").mkdir(parents=True, exist_ok=True)
    shutil.copy2(POST_XCODEBUILD, root / "ios/ci_scripts/ci_post_xcodebuild.sh")

    if shared:
        write_notes(root / "what_to_test.json", SHARED_TEXT)
    if ios:
        write_notes(root / "what_to_test.ios.json", IOS_TEXT)
    if android:
        write_notes(root / "what_to_test.android.json", ANDROID_TEXT)
    if release:
        write_notes(root / "release_notes.json", RELEASE_TEXT)
    return root


def run_post_xcodebuild(checkout: Path, branch: str) -> subprocess.CompletedProcess:
    script = checkout / "ios/ci_scripts/ci_post_xcodebuild.sh"
    signed = checkout / "signed.app"
    signed.mkdir(exist_ok=True)
    return subprocess.run(
        [shell_for(POST_XCODEBUILD), str(script)],
        cwd=checkout,
        env={
            "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
            "HOME": str(checkout),
            "CI_PRIMARY_REPOSITORY_PATH": str(checkout),
            "CI_APP_STORE_SIGNED_APP_PATH": str(signed),
            "CI_BRANCH": branch,
        },
        capture_output=True, text=True, check=False,
    )


class XcodeCloudPathTest(unittest.TestCase):
    """The hook that already shipped, plus the preference #503 adds to it."""

    def test_the_ios_file_wins_over_the_shared_one(self) -> None:
        with TemporaryDirectory() as tmp:
            checkout = make_checkout(Path(tmp), ios=True)

            result = run_post_xcodebuild(checkout, "main")

            self.assertEqual(result.returncode, 0, result.stderr)
            written = checkout / "ios/TestFlight/WhatToTest.en-US.txt"
            self.assertEqual(written.read_text(encoding="utf-8").strip(), IOS_TEXT)

    def test_the_shared_file_is_used_when_there_is_no_ios_file(self) -> None:
        with TemporaryDirectory() as tmp:
            checkout = make_checkout(Path(tmp))

            result = run_post_xcodebuild(checkout, "main")

            self.assertEqual(result.returncode, 0, result.stderr)
            written = checkout / "ios/TestFlight/WhatToTest.en-US.txt"
            self.assertEqual(written.read_text(encoding="utf-8").strip(), SHARED_TEXT)

    def test_a_release_branch_still_ships_the_marketing_notes(self) -> None:
        """The release/* arm is untouched by the platform preference."""
        with TemporaryDirectory() as tmp:
            checkout = make_checkout(Path(tmp), ios=True, release=True)

            result = run_post_xcodebuild(checkout, "release/1.0.0")

            self.assertEqual(result.returncode, 0, result.stderr)
            written = checkout / "ios/TestFlight/WhatToTest.en-US.txt"
            self.assertEqual(written.read_text(encoding="utf-8").strip(), RELEASE_TEXT)

    def test_a_checkout_with_no_note_file_still_builds(self) -> None:
        with TemporaryDirectory() as tmp:
            checkout = make_checkout(Path(tmp), shared=False)

            result = run_post_xcodebuild(checkout, "main")

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((checkout / "ios/TestFlight/WhatToTest.en-US.txt").exists())

    def test_the_hook_keeps_its_own_interpreter(self) -> None:
        self.assertTrue(
            POST_XCODEBUILD.read_text(encoding="utf-8").startswith("#!/bin/zsh")
        )


def workflow_step_body(workflow: Path, step_name: str) -> str:
    """The `run:` block of a named workflow step, dedented."""
    text = workflow.read_text(encoding="utf-8")
    marker = f"      - name: {step_name}\n"
    start = text.index(marker)
    body = text[text.index("run: |\n", start) + len("run: |\n") :]
    lines = []
    for line in body.split("\n"):
        if line.strip() and not line.startswith("          "):
            break
        lines.append(line[10:] if line.startswith("          ") else line)
    return "\n".join(lines)


def upload_step_input(workflow: Path, name: str) -> str:
    match = re.search(rf"^          {name}: (.+)$", workflow.read_text(encoding="utf-8"),
                      re.MULTILINE)
    if match is None:
        raise AssertionError(f"the upload step has no {name} input")
    return match.group(1).strip()


class GooglePlayPathTest(unittest.TestCase):
    def _run_notes_step(self, checkout: Path, runner_temp: Path) -> subprocess.CompletedProcess:
        runner_temp.mkdir(parents=True, exist_ok=True)
        return subprocess.run(
            ["bash", "-c", workflow_step_body(PLAY_WORKFLOW, "Prepare Google Play release notes")],
            cwd=checkout,
            env={"PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
                 "HOME": str(checkout), "RUNNER_TEMP": str(runner_temp)},
            capture_output=True, text=True, check=False,
        )

    def test_the_android_file_wins_and_reaches_the_play_layout(self) -> None:
        with TemporaryDirectory() as tmp:
            checkout = make_checkout(Path(tmp) / "repo", android=True)
            runner_temp = Path(tmp) / "runner-temp"

            result = self._run_notes_step(checkout, runner_temp)

            self.assertEqual(result.returncode, 0, result.stderr)
            written = runner_temp / "whatsnew/whatsnew-en-US"
            self.assertEqual(written.read_text(encoding="utf-8"), ANDROID_TEXT)

    def test_the_upload_action_is_pointed_at_the_directory_that_was_written(self) -> None:
        """The two halves of the Android wiring, checked against each other.

        Changing where the step writes, or where the action reads, without
        changing the other turns this red — which is the whole point of
        asserting it here rather than asserting each half in isolation.
        """
        with TemporaryDirectory() as tmp:
            checkout = make_checkout(Path(tmp) / "repo", android=True)
            runner_temp = Path(tmp) / "runner-temp"
            self._run_notes_step(checkout, runner_temp)

            configured = upload_step_input(PLAY_WORKFLOW, "whatsNewDirectory")
            resolved = Path(configured.replace("${{ runner.temp }}", str(runner_temp)))

            self.assertEqual(resolved, runner_temp / "whatsnew")
            self.assertEqual(
                sorted(entry.name for entry in resolved.iterdir()), ["whatsnew-en-US"]
            )

    def test_the_notes_step_runs_before_the_upload_step(self) -> None:
        text = PLAY_WORKFLOW.read_text(encoding="utf-8")

        self.assertLess(
            text.index("- name: Prepare Google Play release notes"),
            text.index("- name: Upload AAB to Google Play internal testing"),
        )

    def test_a_note_over_plays_limit_is_clipped_before_it_reaches_the_action(self) -> None:
        with TemporaryDirectory() as tmp:
            checkout = make_checkout(Path(tmp) / "repo", shared=False)
            write_notes(checkout / "what_to_test.json", "q" * 900)
            runner_temp = Path(tmp) / "runner-temp"

            result = self._run_notes_step(checkout, runner_temp)

            self.assertEqual(result.returncode, 0, result.stderr)
            written = (runner_temp / "whatsnew/whatsnew-en-US").read_text(encoding="utf-8")
            self.assertEqual(len(written), 500)
            self.assertIn("truncating", result.stdout)


class EmiTestFlightPathTest(unittest.TestCase):
    """The lane's call site. Its request shapes live in the sibling test file."""

    def test_the_delivery_script_publishes_the_notes_after_the_upload(self) -> None:
        text = IOS_DELIVERY.read_text(encoding="utf-8")

        self.assertIn("scripts/gha/set_testflight_whats_new.py", text)
        self.assertLess(
            text.index("-exportArchive"),
            text.index("scripts/gha/set_testflight_whats_new.py"),
            "notes can only be attached to a build that has been uploaded",
        )

    def test_the_notes_step_can_fail_the_delivery(self) -> None:
        """A green delivery with no tester notes is the failure being prevented.

        The script runs under `set -euo pipefail` with no `|| true` and no `if`
        guard, so a failure to write the notes fails the job.
        """
        text = IOS_DELIVERY.read_text(encoding="utf-8")
        call_index = text.index("scripts/gha/set_testflight_whats_new.py")
        invocation = text[text.rindex("\n", 0, call_index) : ]

        self.assertIn("set -euo pipefail", text)
        self.assertNotIn("|| true", invocation)

    def test_legacy_ios_delivery_has_no_actions_entrypoint(self) -> None:
        self.assertFalse(IOS_WORKFLOW.exists())
        for workflow in PLAY_WORKFLOW.parent.glob("*.yml"):
            self.assertNotIn("build-and-upload-ios.sh", workflow.read_text())

    def test_it_is_told_which_export_to_read_the_build_number_from(self) -> None:
        text = IOS_DELIVERY.read_text(encoding="utf-8")
        invocation = text[text.index("scripts/gha/set_testflight_whats_new.py") :]

        self.assertIn('--export-path "$EXPORT_PATH"', invocation)
        self.assertIn('--bundle-id "$BEID_BUNDLE_ID"', invocation)


class TriggerContractTest(unittest.TestCase):
    """Acceptance criterion 3: publishing notes did not widen either trigger.

    Text based rather than YAML based, matching the sibling workflow tests:
    PyYAML is not a dependency of this repository, and `on:` would parse as the
    boolean key `True` under it anyway.
    """

    def _paths(self, workflow: Path) -> list:
        text = workflow.read_text(encoding="utf-8")
        block = text[text.index("on:\n") : text.index("\npermissions:\n")]
        section = block[block.index("    paths:\n") + len("    paths:\n") :]
        found = []
        for line in section.split("\n"):
            if not line.startswith("      - "):
                break
            found.append(line[len("      - ") :].strip())
        return found

    def test_the_android_lane_still_fires_on_exactly_two_files(self) -> None:
        self.assertEqual(
            self._paths(PLAY_WORKFLOW), ["what_to_test.json", "what_to_test.android.json"]
        )

    def test_neither_lane_fires_on_a_script_or_workflow_change(self) -> None:
        """The paths list is a whitelist, so a push touching only these is inert."""
        for workflow in (PLAY_WORKFLOW,):
            with self.subTest(workflow=workflow.name):
                paths = self._paths(workflow)
                for unrelated in ("scripts/prepare_testflight_notes.py",
                                  "ios/ci_scripts/ci_post_xcodebuild.sh",
                                  ".github/workflows/internal-google-play.yml"):
                    self.assertNotIn(unrelated, paths)


if __name__ == "__main__":
    unittest.main()
