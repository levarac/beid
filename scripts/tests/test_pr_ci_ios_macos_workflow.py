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
                self.assertEqual(block.count("SWIFT_OPTIMIZATION_LEVEL=-O"), 1)

    def test_release_build_remains_sequential_and_informational(self) -> None:
        text = workflow_text()
        summary = text.index("      - name: Summarize structured test results\n")
        release = text.index("      - name: Build Release for device (informational)\n")
        shutdown = text.index("      - name: Shutdown simulator\n")
        block = step_block(text, "Build Release for device (informational)")

        self.assertLess(summary, release)
        self.assertLess(release, shutdown)
        self.assertIn("        if: ${{ !cancelled() }}\n", block)
        self.assertNotIn("        id:", block)
        self.assertNotIn("        background:", block)
        self.assertNotIn("wait: release-device-build", text)


if __name__ == "__main__":
    unittest.main()
