import json
import os
import shlex
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest

from scripts.tests.workflow_yaml import named_step, workflow_data


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


def step_data(text: str, name: str, job: str = "build") -> dict:
    return named_step(workflow_data(text), job, name)


def run_commands(text: str) -> str:
    return "\n".join(without_comments(step.get("run", ""))
                     for job in workflow_data(text)["jobs"].values()
                     for step in job.get("steps", []))


class PrCiIosMacosWorkflowTest(unittest.TestCase):
    def test_lane_creates_its_device_instead_of_selecting_or_erasing_one(self) -> None:
        text = run_commands(workflow_text())
        self.assertIn("python3 scripts/ci_simulator.py", text)
        self.assertNotIn("simctl list devices", text)
        self.assertNotIn("simctl erase", text)

    def test_simulator_helper_changes_trigger_the_lane(self) -> None:
        self.assertEqual(workflow_data(workflow_text())["on"]["push"]["paths"].count(
            "scripts/ci_simulator.py"), 1)

    def test_every_device_operation_uses_only_the_create_steps_output(self) -> None:
        text = workflow_text()
        creation = step_data(text, "Create owned simulator")
        self.assertEqual(creation["id"], "simulator")
        self.assertIn('--name "ci-beid-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT-$GITHUB_JOB"', creation["run"])
        self.assertIn('printf \'udid=%s\\n\' "$simulator_udid" >> "$GITHUB_OUTPUT"', creation["run"])
        for name in ("Boot owned simulator", "Build for testing",
                     "Test without rebuilding", "Delete owned simulator"):
            with self.subTest(step=name):
                self.assertEqual(step_data(text, name)["env"]["SIMULATOR_UDID"],
                                 "${{ steps.simulator.outputs.udid }}")
        cleanup = step_data(text, "Delete owned simulator")
        self.assertEqual(cleanup["if"], "${{ always() && steps.simulator.outputs.udid != '' }}")

    def test_cleanup_deletes_only_owned_udid_even_when_shutdown_fails(self) -> None:
        block = step_data(workflow_text(), "Delete owned simulator")
        command = block["run"]
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
                block = step_data(text, name)["run"]
                # Shell tokenization respects quotes, array parentheses and comments;
                # prefix matches would accept -Onone, -Osize and other wrong values.
                lexer = shlex.shlex(block, posix=True, punctuation_chars="();|&")
                lexer.whitespace_split = True
                values = [token.split("=", 1)[1] for token in lexer
                          if token.startswith("SWIFT_OPTIMIZATION_LEVEL=")]
                self.assertEqual(values, ["-O"])

    def test_simulator_lane_no_longer_builds_release_for_device(self) -> None:
        """The Release-for-device build moved out (gh#479).

        It was about 11 of this lane's 33 minutes, inside a lane whose
        purpose is simulator tests, on the repository's only self-hosted
        runner — which TestFlight delivery also needs. This pins the removal so it cannot
        drift back in unnoticed; re-adding it here is a decision, not an edit.
        """
        directives = run_commands(workflow_text())

        self.assertNotIn("-configuration Release", directives)
        self.assertNotIn("Build Release for device", [
            step.get("name") for job in workflow_data(workflow_text())["jobs"].values()
            for step in job.get("steps", [])
        ])
        self.assertNotIn("generic/platform=iOS", directives)

    def test_mode_is_selected_once_and_cannot_skip_testing(self):
        text = workflow_text()
        data = workflow_data(text)
        mode = step_data(text, "Determine test mode", "plan")
        self.assertEqual(mode["id"], "test-mode")
        self.assertIn('python3 -m scripts.ios_ui_smoke mode', mode["run"])
        self.assertIn('"$GITHUB_EVENT_PATH"', mode["run"])
        self.assertEqual(data["jobs"]["changes"]["outputs"]["ios_full"],
                         "${{ steps.classify.outputs.ios_full }}")
        for requirement in ("needs.changes.result == 'success'",
                            "needs.changes.outputs.error == 'false'",
                            "needs.changes.outputs.ios_full == 'false'"):
            self.assertIn(requirement, mode["env"]["ALLOW_SMOKE"])
        self.assertIn("mode=full", mode["run"])
        self.assertNotIn("if", mode)
        self.assertEqual(run_commands(text).count("scripts.ios_ui_smoke mode"), 1)
        run = step_data(text, "Test without rebuilding")
        self.assertEqual(run["if"], "${{ needs.plan.outputs.mode == 'smoke' }}")
        self.assertEqual(run["env"]["TEST_MODE"], "${{ needs.plan.outputs.mode }}")
        self.assertIn('scripts.ios_ui_smoke arguments', run["run"])
        self.assertIn('"${test_args[@]}"', run["run"])
        check = step_data(text, "Verify UI execution and bundle durations")
        self.assertEqual(check["if"], "${{ always() && needs.plan.outputs.mode == 'smoke' }}")
        self.assertEqual(check["env"]["TEST_MODE"], "${{ needs.plan.outputs.mode }}")
        self.assertIn('xcresulttool get test-results tests', check["run"])
        self.assertIn('scripts.ios_ui_smoke verify-lane --lane build', check["run"])
        for job in data["jobs"].values():
            self.assertNotIn("continue-on-error", job)
            for step in job.get("steps", []):
                self.assertNotIn("continue-on-error", step)

    def test_plan_runs_full_when_changed_path_output_affects_deferred_coverage(self):
        block = step_data(workflow_text(), "Determine test mode", "plan")
        command = block["run"]
        root = WORKFLOW_PATH.parents[2]
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            event = folder / "event.json"
            output = folder / "output.txt"
            for allow_smoke, labels, expected in (
                ("true", [], "smoke"),
                ("false", [], "full"),
                ("", [], "full"),
                ("true", [{"name": "ci:full-ui"}], "full"),
            ):
                with self.subTest(allow_smoke=allow_smoke, labels=labels):
                    event.write_text(json.dumps({"pull_request": {"labels": labels}}))
                    output.write_text("")
                    subprocess.run(["bash", "-c", command], cwd=root, check=True,
                        env={**os.environ, "ALLOW_SMOKE": allow_smoke, "EVENT_NAME": "pull_request",
                             "GITHUB_EVENT_PATH": str(event), "GITHUB_OUTPUT": str(output)},
                        capture_output=True, text=True)
                    self.assertEqual(output.read_text(), f"mode={expected}\n")

    def test_selection_shell_passes_exact_arguments_in_both_modes(self):
        block = step_data(workflow_text(), "Test without rebuilding")
        self.assertIn("scripts.ios_ui_smoke arguments", block["run"])
        command = block["run"]
        root = WORKFLOW_PATH.parents[2]
        (root / "build").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=root / "build") as temporary:
            folder = Path(temporary)
            fake = folder / "xcodebuild"
            fake.write_text(f"#!{sys.executable}\nimport json, os, sys\n"
                            "print(json.dumps(sys.argv[1:]))\n"
                            "sys.exit(int(os.environ.get('XCODE_EXIT', '0')))\n")
            fake.chmod(0o755)
            for mode, child_exit in (("smoke", 0), ("full", 0), ("smoke", 65)):
                result = subprocess.run(["bash", "-c", command], cwd=root, text=True,
                    capture_output=True, env={**os.environ,
                        "PATH": str(folder) + os.pathsep + os.environ["PATH"],
                        "CI_OUTPUT_ROOT": str(folder), "SIMULATOR_UDID": "owned",
                        "XCTESTRUN": str(folder / "Beid.xctestrun"),
                        "TEST_MODE": mode, "XCODE_EXIT": str(child_exit)})
                self.assertEqual(result.returncode, child_exit, result.stderr)
                argv = json.loads(result.stdout)
                self.assertEqual([arg for arg in argv if arg.startswith("SWIFT_OPTIMIZATION_LEVEL=")],
                                 ["SWIFT_OPTIMIZATION_LEVEL=-O"])
                selections = [item for item in argv if item.startswith("-only-testing:")]
                from scripts.ios_ui_smoke import parse_smoke_list
                listed = parse_smoke_list((root / "ios/ci/ui-smoke-tests.txt").read_text())
                self.assertEqual(selections, (["-only-testing:BeidTests"] +
                    [f"-only-testing:{test}" for test in listed]) if mode == "smoke" else [])
                exclusions = [item for item in argv if item.startswith("-skip-testing:")]
                self.assertEqual(exclusions, [
                    "-skip-testing:BeidTests/ReportSubmissionOperatorIntegrationTests",
                    "-skip-testing:BeidTests/ProductionVenueBundleVerifierTests",
                    "-skip-testing:BeidTests/ReportProofLinkContainmentTests",
                ] if mode == "smoke" else [])


class MainIosReleaseBuildWorkflowTest(unittest.TestCase):
    def test_release_build_command_moved_unchanged(self) -> None:
        data = workflow_data(release_workflow_text())
        step = named_step(data, "ios-release-build", "Build Release for device")
        self.assertIn(textwrap.dedent(RELEASE_BUILD_COMMAND), step["run"])
        # The informational lane must not produce artifacts or gain dependencies.
        for job in data["jobs"].values():
            self.assertNotIn("needs", job)
            for step in job.get("steps", []):
                self.assertFalse(step.get("uses", "").startswith("actions/upload-artifact@"))

    def test_release_workflow_runs_only_on_main_and_on_demand(self) -> None:
        """Push-to-main is the only trigger it gains.

        A `pull_request` trigger here would re-create the cost the move
        removed, on the same single runner, while looking like a separate
        lane.
        """
        events = workflow_data(release_workflow_text())["on"]
        self.assertEqual(set(events), {"push", "workflow_dispatch"})
        self.assertEqual(events["push"]["branches"], ["main"])
        self.assertNotIn("tags", events["push"])
        self.assertNotIn("branches-ignore", events["push"])

    def test_release_workflow_uses_a_hosted_runner(self) -> None:
        self.assertEqual(workflow_data(release_workflow_text())["jobs"]["ios-release-build"]["runs-on"],
                         "macos-26")


if __name__ == "__main__":
    unittest.main()
