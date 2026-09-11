import unittest
from pathlib import Path


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

    def test_simulator_lane_no_longer_builds_release_for_device(self) -> None:
        """The Release-for-device build moved out (gh#479).

        It was 11 of this lane's 33 minutes in a lane whose purpose is
        simulator tests, on the repository's only self-hosted runner — which
        TestFlight delivery also needs. This pins the removal so it cannot
        drift back in unnoticed; re-adding it here is a decision, not an edit.
        """
        text = workflow_text()

        self.assertNotIn("-configuration Release", text)
        self.assertNotIn("Build Release for device", text)
        self.assertNotIn("generic/platform=iOS", text)


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

        self.assertIn("  push:\n    branches: [main]\n", text)
        self.assertIn("  workflow_dispatch:\n", text)
        self.assertNotIn("pull_request", text)

    def test_release_workflow_shares_the_runner_routing_variable(self) -> None:
        self.assertIn("fromJSON(vars.RUNS_ON_MACOS", release_workflow_text())


if __name__ == "__main__":
    unittest.main()
