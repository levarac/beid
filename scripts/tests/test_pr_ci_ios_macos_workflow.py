import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest


WORKFLOW_PATH = Path(__file__).parents[2] / ".github/workflows/pr-ci-ios-macos.yml"
RELEASE_WORKFLOW_PATH = (
    Path(__file__).parents[2] / ".github/workflows/main-ios-release-build.yml"
)

# The exact invocation, kept as a literal so the move is checked byte-for-byte
# rather than by step name. A lookalike step with the same name and different
# flags is precisely what a name match hides.
RELEASE_BUILD_COMMAND = """          xcodebuild \\
            -project ios/Beid.xcodeproj \\
            -scheme Beid \\
            -configuration Release \\
            -destination "generic/platform=iOS" \\
            -sdk iphoneos \\
            build \\
            CODE_SIGNING_ALLOWED=NO
"""


def workflow_text() -> str:
    return WORKFLOW_PATH.read_text(encoding="utf-8")


def release_workflow_text() -> str:
    return RELEASE_WORKFLOW_PATH.read_text(encoding="utf-8")


def without_comments(text: str) -> str:
    """Drop comment-only lines.

    The absence assertions below must pin what the workflow DOES, not what it
    says about itself. Checked against the whole file they also forbid the
    words in prose, so the sentence explaining why the Release build moved out
    cannot be written in its natural phrasing. The predictable failure is not
    that someone is blocked — it is that they hit an unexpected red and WEAKEN
    THE ASSERTION to fit, which is how a pin degrades into decoration.
    """
    return "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith("#")
    )


def step_block(text: str, name: str) -> str:
    marker = f"      - name: {name}\n"
    start = text.index(marker)
    next_step = text.find("\n      - ", start + len(marker))
    return text[start:] if next_step == -1 else text[start:next_step]


class PrCiIosMacosWorkflowTest(unittest.TestCase):
    def test_lane_creates_its_device_instead_of_selecting_or_erasing_one(self) -> None:
        text = without_comments(workflow_text())
        self.assertIn("python3 scripts/ci_simulator.py", text)
        self.assertNotIn("simctl list devices", text)
        self.assertNotIn("simctl erase", text)

    def test_simulator_helper_changes_trigger_the_lane(self) -> None:
        self.assertEqual(workflow_text().count('      - "scripts/ci_simulator.py"'), 2)

    def test_every_device_operation_uses_only_the_create_steps_output(self) -> None:
        text = workflow_text()
        creation = step_block(text, "Create owned simulator")
        self.assertIn("        id: simulator\n", creation)
        self.assertIn('--name "ci-beid-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT-$GITHUB_JOB"', creation)
        self.assertIn('printf \'udid=%s\\n\' "$simulator_udid" >> "$GITHUB_OUTPUT"', creation)
        for name in ("Boot owned simulator", "Build for testing",
                     "Test without rebuilding", "Delete owned simulator"):
            with self.subTest(step=name):
                self.assertIn("SIMULATOR_UDID: ${{ steps.simulator.outputs.udid }}", step_block(text, name))
        cleanup = step_block(text, "Delete owned simulator")
        self.assertIn("if: ${{ always() && steps.simulator.outputs.udid != '' }}", cleanup)

    def test_cleanup_deletes_only_owned_udid_even_when_shutdown_fails(self) -> None:
        block = step_block(workflow_text(), "Delete owned simulator")
        command = textwrap.dedent(block.split("        run: |\n", 1)[1])
        owned = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            calls = folder / "calls.jsonl"
            fake = folder / "xcrun"
            fake.write_text(
                f"#!{sys.executable}\n"
                "import json, os, sys\n"
                "with open(os.environ['CALLS'], 'a') as calls:\n"
                "    calls.write(json.dumps(sys.argv[1:]) + '\\n')\n"
                "sys.exit(1 if sys.argv[2] == 'shutdown' else int(os.environ['DELETE_EXIT']))\n"
            )
            fake.chmod(0o755)
            for delete_exit in (0, 1):
                with self.subTest(delete_exit=delete_exit):
                    calls.write_text("")
                    result = subprocess.run(
                        ["bash", "-c", command], capture_output=True, text=True,
                        env={**os.environ, "PATH": str(folder) + os.pathsep + os.environ["PATH"],
                             "SIMULATOR_UDID": owned, "CALLS": str(calls),
                             "DELETE_EXIT": str(delete_exit)},
                    )
                    self.assertEqual(result.returncode, delete_exit, result.stderr)
                    self.assertEqual([json.loads(line) for line in calls.read_text().splitlines()], [
                        ["simctl", "shutdown", owned], ["simctl", "delete", owned],
                    ])

    def test_debug_build_and_test_use_measured_optimization(self) -> None:
        text = workflow_text()

        for name in ("Build for testing", "Test without rebuilding"):
            with self.subTest(step=name):
                block = step_block(text, name)
                self.assertEqual(block.count("SWIFT_OPTIMIZATION_LEVEL=-O"), 1)

    def test_simulator_lane_no_longer_builds_release_for_device(self) -> None:
        """The Release-for-device build moved out (gh#479).

        It was about 11 of this lane's 33 minutes, inside a lane whose
        purpose is simulator tests, on the repository's only self-hosted
        runner — which TestFlight delivery also needs. This pins the removal so it cannot
        drift back in unnoticed; re-adding it here is a decision, not an edit.
        """
        directives = without_comments(workflow_text())

        self.assertNotIn("-configuration Release", directives)
        self.assertNotIn("Build Release for device", directives)
        self.assertNotIn("generic/platform=iOS", directives)


class MainIosReleaseBuildWorkflowTest(unittest.TestCase):
    def test_release_build_command_moved_unchanged(self) -> None:
        block = step_block(
            release_workflow_text(), "Build Release for device (informational)"
        )

        self.assertIn(RELEASE_BUILD_COMMAND, block)
        # Informational: it produces no artefact and gates nothing, so nothing
        # downstream can come to depend on it without that being a visible edit.
        self.assertNotIn("upload-artifact", release_workflow_text())
        self.assertNotIn("needs:", release_workflow_text())

    def test_release_workflow_runs_only_on_main_and_on_demand(self) -> None:
        """Push-to-main is the only trigger it gains.

        A `pull_request` trigger here would re-create the cost the move
        removed, on the same single runner, while looking like a separate
        lane.
        """
        text = release_workflow_text()

        directives = without_comments(text)

        self.assertIn("  push:\n    branches: [main]\n", directives)
        self.assertIn("  workflow_dispatch:\n", directives)
        self.assertNotIn("pull_request", directives)

    def test_release_workflow_uses_a_hosted_runner(self) -> None:
        self.assertIn("runs-on: macos-26", release_workflow_text())


if __name__ == "__main__":
    unittest.main()
