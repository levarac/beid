import unittest
from pathlib import Path


WORKFLOW_PATH = Path(__file__).parents[2] / ".github/workflows/pr-ci-ios-macos.yml"


def workflow_text() -> str:
    return WORKFLOW_PATH.read_text(encoding="utf-8")


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
                self.assertIn("SWIFT_OPTIMIZATION_LEVEL=-O", block)

    def test_release_build_runs_in_the_background_with_a_stable_id(self) -> None:
        block = step_block(workflow_text(), "Build Release for device (informational)")

        self.assertIn("        id: release-device-build\n", block)
        self.assertIn("        background: true\n", block)

    def test_release_build_overlaps_tests_and_is_waited_for_before_summary(self) -> None:
        text = workflow_text()
        release = text.index("      - name: Build Release for device (informational)\n")
        tests = text.index("      - name: Test without rebuilding\n")
        wait = text.index("      - name: Wait for informational Release device build\n")
        summary = text.index("      - name: Summarize structured test results\n")

        self.assertLess(release, tests)
        self.assertLess(tests, wait)
        self.assertLess(wait, summary)
        self.assertIn(
            "        wait: release-device-build\n",
            step_block(text, "Wait for informational Release device build"),
        )

    def test_wait_step_has_no_condition_that_can_hide_release_failure(self) -> None:
        block = step_block(workflow_text(), "Wait for informational Release device build")

        self.assertNotIn("        if:", block)


if __name__ == "__main__":
    unittest.main()
