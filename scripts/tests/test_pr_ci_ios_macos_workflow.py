from pathlib import Path
import unittest
import os
import subprocess
import tempfile
import textwrap
import json
import sys


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
        self.assertEqual(workflow_text().count('      - "scripts/ci_simulator.py"'), 1)

    def test_each_test_job_owns_one_clean_simulator_without_clones(self):
        text = workflow_text()
        self.assertIn("matrix:\n        group: [unit, ipad, interface]", text)
        for name in ("Wait for test simulator readiness", "Test without rebuilding"):
            self.assertIn("SIMULATOR_UDID: ${{ steps.simulator.outputs.udid }}", step_block(text, name))
        self.assertIn("-parallel-testing-enabled NO", step_block(text, "Test without rebuilding"))
        self.assertNotIn("simctl shutdown", text)
        self.assertNotIn("simctl delete", text)

    def test_build_uses_measured_optimization_and_products_are_shared(self):
        block = step_block(workflow_text(), "Build for testing")
        self.assertIn("-configuration Debug", block)
        self.assertIn("SWIFT_OPTIMIZATION_LEVEL=-O", block.split())
        self.assertIn("tar -C", step_block(workflow_text(), "Package test products"))
        self.assertNotIn("build-for-testing", step_block(workflow_text(), "Test without rebuilding"))

    def test_compiled_manifest_and_test_selection_reach_xcode_unchanged(self):
        block = step_block(workflow_text(), "Test without rebuilding")
        command = textwrap.dedent(block.split("        run: |\n", 1)[1])
        expected = {
            "unit": ["-only-testing:BeidTests"],
            "ipad": ["-only-testing:BeidUITests/BeidIPadLayoutTests"],
            "interface": ["-only-testing:BeidUITests", "-skip-testing:BeidUITests/BeidIPadLayoutTests"],
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            products = root / "DerivedData/Build/Products"
            products.mkdir(parents=True)
            manifest = products / "Beid.xctestrun"
            manifest.touch()
            capture = root / "arguments.json"
            fake = root / "xcodebuild"
            fake.write_text(f"#!{sys.executable}\nimport json, os, sys\nopen(os.environ['CAPTURE'], 'w').write(json.dumps(sys.argv[1:]))\nsys.exit(65 if os.environ.get('FAIL_TESTS') else 0)\n")
            fake.chmod(0o755)
            environment = {**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"],
                           "CI_OUTPUT_ROOT": str(root), "SIMULATOR_UDID": "owned", "CAPTURE": str(capture)}
            for group, selectors in expected.items():
                result = subprocess.run(["bash", "-c", command], cwd=WORKFLOW_PATH.parents[2],
                                        env={**environment, "TEST_GROUP": group}, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                argv = json.loads(capture.read_text())
                self.assertEqual(argv[argv.index("-xctestrun") + 1], str(manifest))
                self.assertEqual([a for a in argv if a.startswith(("-only-testing:", "-skip-testing:"))], selectors)
            result = subprocess.run(["bash", "-c", command], cwd=WORKFLOW_PATH.parents[2],
                                    env={**environment, "TEST_GROUP": "unit", "FAIL_TESTS": "1"}, capture_output=True)
            self.assertEqual(result.returncode, 65)
            manifest.unlink()
            result = subprocess.run(["bash", "-c", command], cwd=WORKFLOW_PATH.parents[2],
                                    env={**environment, "TEST_GROUP": "unit"}, capture_output=True)
            self.assertNotEqual(result.returncode, 0)

    def test_required_aggregate_rejects_failed_cancelled_or_skipped_children(self):
        text = workflow_text()
        self.assertIn("name: iOS simulator\n    if: always()\n    needs: [ios-simulator, ios-tests]", text)
        block = step_block(text, "Require every build and test job to pass")
        command = textwrap.dedent(block.split("        run: |\n", 1)[1])
        for build in ("success", "failure", "cancelled", "skipped"):
            for tests in ("success", "failure", "cancelled", "skipped"):
                result = subprocess.run(["bash", "-e", "-c", command],
                                        env={**os.environ, "BUILD_RESULT": build, "TEST_RESULT": tests})
                self.assertEqual(result.returncode == 0, build == tests == "success")
        self.assertIn("set -euo pipefail", step_block(text, "Verify complete current-head evidence"))

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
            release_workflow_text(), "Build Release for device"
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
