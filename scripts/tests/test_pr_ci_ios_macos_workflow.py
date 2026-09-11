import unittest
from pathlib import Path


WORKFLOW_PATH = Path(__file__).parents[2] / ".github/workflows/pr-ci-ios-macos.yml"
RELEASE_WORKFLOW_PATH = (
    Path(__file__).parents[2] / ".github/workflows/main-ios-release-build.yml"
)

# The exact invocation, kept as a literal so the Release build is checked
# byte-for-byte rather than by step name. A lookalike step with the same name
# and different flags is precisely what a name match hides. Since gh#479 the
# command goes through scripts/ci_derived_data.sh and passes -derivedDataPath;
# everything else is the invocation moved out of the PR lane in gh#510.
RELEASE_BUILD_COMMAND = """          scripts/ci_derived_data.sh build "Build Release for device" -- xcodebuild \\
            -project ios/Beid.xcodeproj \\
            -scheme Beid \\
            -configuration Release \\
            -destination "generic/platform=iOS" \\
            -sdk iphoneos \\
            -derivedDataPath "$CI_DERIVED_DATA" \\
            build \\
            CODE_SIGNING_ALLOWED=NO
"""

# Both lanes resolve the persistent DerivedData the same way, from the same
# script, before they build. The literal is the whole step so a lookalike
# (a different script, a different subcommand, an inline mkdir) cannot pass.
RESOLVE_DERIVED_DATA_STEP = """      - name: Resolve DerivedData cache
        shell: bash
        run: scripts/ci_derived_data.sh resolve
"""

BUILD_FOR_TESTING_COMMAND = """          scripts/ci_derived_data.sh build "Build for testing" -- xcodebuild \\
            -project ios/Beid.xcodeproj \\
            -scheme Beid \\
            -configuration Debug \\
            -sdk iphonesimulator \\
            -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \\
            -derivedDataPath "$CI_DERIVED_DATA" \\
            SWIFT_OPTIMIZATION_LEVEL=-O \\
            build-for-testing
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
    def test_debug_build_and_test_use_measured_optimization(self) -> None:
        text = workflow_text()

        for name in ("Build for testing", "Test without rebuilding"):
            with self.subTest(step=name):
                block = step_block(text, name)
                self.assertEqual(block.count("SWIFT_OPTIMIZATION_LEVEL=-O"), 1)

    def test_build_goes_through_the_derived_data_wrapper_and_tests_reuse_its_path(self) -> None:
        """Persistent DerivedData (gh#479, sis-ios-ci report section 12).

        The build step must be the wrapper call byte-for-byte: it is what
        provides wipe-on-failure and the single clean retry, and a second
        inline `xcodebuild` would double the SWIFT_OPTIMIZATION_LEVEL pin
        above. The test step reuses the same path and is NOT wrapped: a test
        failure is not a stale-module symptom, and wiping on it would throw
        away the state the next run needs.
        """
        text = workflow_text()

        self.assertIn(BUILD_FOR_TESTING_COMMAND, step_block(text, "Build for testing"))
        test_step = step_block(text, "Test without rebuilding")
        self.assertIn('-derivedDataPath "$CI_DERIVED_DATA"', test_step)
        self.assertNotIn("ci_derived_data.sh", test_step)
        self.assertNotIn("RUNNER_TEMP/DerivedData", without_comments(text))
        self.assertNotIn("CI_OUTPUT_ROOT/DerivedData", without_comments(text))

    def test_derived_data_is_resolved_after_xcode_and_before_the_build(self) -> None:
        """`resolve` reads `xcodebuild -version`, so DEVELOPER_DIR must already be
        exported; and the build needs CI_DERIVED_DATA, so the step must precede it.
        """
        text = workflow_text()

        self.assertEqual(text.count(RESOLVE_DERIVED_DATA_STEP), 1)
        resolve_at = text.index(RESOLVE_DERIVED_DATA_STEP)
        self.assertLess(text.index("      - name: Resolve Xcode, JDK, and iOS 26.5 simulator\n"), resolve_at)
        self.assertLess(resolve_at, text.index("      - name: Build for testing\n"))

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
    def test_release_build_command_is_pinned_to_the_wrapped_form(self) -> None:
        block = step_block(
            release_workflow_text(), "Build Release for device (informational)"
        )

        self.assertIn(RELEASE_BUILD_COMMAND, block)
        # Informational: it produces no artefact and gates nothing, so nothing
        # downstream can come to depend on it without that being a visible edit.
        self.assertNotIn("upload-artifact", release_workflow_text())
        self.assertNotIn("needs:", release_workflow_text())

    def test_release_workflow_resolves_derived_data_before_the_build(self) -> None:
        """Incremental by decision (sis-ios-ci report section 11/12).

        Run 1 of this workflow passed no -derivedDataPath and hit a warm
        default DerivedData by accident (76 s, one SwiftCompile line). The
        resolve step makes the reuse explicit and puts cold/warm in the job
        summary, so the step's wall time is never quoted as a cold number.
        """
        text = release_workflow_text()

        self.assertEqual(text.count(RESOLVE_DERIVED_DATA_STEP), 1)
        resolve_at = text.index(RESOLVE_DERIVED_DATA_STEP)
        self.assertLess(text.index("      - name: Resolve Xcode and JDK\n"), resolve_at)
        self.assertLess(resolve_at, text.index("      - name: Build Release for device (informational)\n"))

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

    def test_release_workflow_shares_the_runner_routing_variable(self) -> None:
        self.assertIn("fromJSON(vars.RUNS_ON_MACOS", release_workflow_text())


if __name__ == "__main__":
    unittest.main()
