"""Exercise the actual workflow summary against complete and missing JUnit data."""

import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]


class AndroidCiEvidenceTests(unittest.TestCase):
    def test_summary_requires_passing_results_from_both_suites(self):
        workflow = (ROOT / ".github/workflows/pr-ci.yml").read_text()
        step = workflow.split("      - name: Summarize Android test results\n", 1)[1]
        command = textwrap.dedent(step.split("        run: |\n", 1)[1].split("\n      - name:", 1)[0])
        passing = '<testsuite><testcase name="passes"/></testsuite>'
        cases = {
            "passing": (passing, 0),
            "missing": (None, 1),
            "empty": ("<testsuite/>", 1),
            "malformed": ("<broken", 1),
            "failed": ('<testsuite><testcase name="fails"><failure/></testcase></testsuite>', 1),
            "all skipped": ('<testsuite><testcase name="skips"><skipped/></testcase></testsuite>', 1),
        }
        for name, (shared_xml, expected) in cases.items():
            with self.subTest(case=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                for relative, content in (
                    ("shared/build/test-results/testAndroidHostTest", shared_xml),
                    ("android/app/build/test-results/testDebugUnitTest", passing),
                ):
                    destination = root / relative
                    destination.mkdir(parents=True)
                    if content is not None:
                        (destination / "TEST-sample.xml").write_text(content)
                result = subprocess.run(
                    ["bash", "-c", command], cwd=root, capture_output=True, text=True,
                    env={**os.environ, "PYTHONPATH": str(ROOT)},
                )
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                self.assertIn(":app:testDebugUnitTest: total=1 pass=1 fail=0 skip=0", result.stdout)
                if expected == 0:
                    self.assertIn(":shared:testAndroidHostTest: total=1 pass=1 fail=0 skip=0", result.stdout)
