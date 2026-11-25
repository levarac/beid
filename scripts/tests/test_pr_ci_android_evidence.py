"""Exercise the actual workflow summary against complete and missing JUnit data."""

import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]


class AndroidCiEvidenceTests(unittest.TestCase):
    def test_robolectric_cache_tracks_versions_and_only_saves_sdk_jars(self):
        workflow = (ROOT / ".github/workflows/pr-ci.yml").read_text()
        android = workflow.split("\n  android:\n", 1)[1].split("\n  lint:\n", 1)[0]
        by_name = dict(re.findall(r"^      - name: ([^\n]+)\n(.*?)(?=^      - |\Z)", android, re.M | re.S))
        self.assertIn("Compute Robolectric SDK cache inputs", by_name)
        inputs = by_name["Compute Robolectric SDK cache inputs"]
        cache = by_name["Cache Robolectric SDK jars"]
        self.assertRegex(cache, r"(?m)^        uses: actions/cache@[0-9a-f]{40} # v4$")
        self.assertNotIn("        if:", cache)  # PRs must be able to restore AND save.
        self.assertNotIn("restore-keys:", cache)
        self.assertIn("          key: beid-robolectric-sdk-v1-${{ runner.os }}-${{ steps.robolectric-cache.outputs.versions }}\n", cache)
        self.assertIn("          path: ${{ steps.robolectric-cache.outputs.paths }}\n", cache)
        self.assertIn("        id: robolectric-cache\n", inputs)
        self.assertLess(android.index(by_name["Set up Gradle"]), android.index(cache))
        self.assertLess(android.index(inputs), android.index(cache))
        self.assertLess(android.index(cache), android.index(by_name["Build and test Android app"]))
        command = textwrap.dedent(inputs.split("        run: |\n", 1)[1].split("\n      #", 1)[0])
        original = (ROOT / "android/app/build.gradle.kts").read_text()
        for version34 in ("14-robolectric-10818077-i7", "14-robolectric-10818077-i8"):
            with self.subTest(version34=version34), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                build = root / "android/app/build.gradle.kts"
                build.parent.mkdir(parents=True)
                build.write_text(original.replace("14-robolectric-10818077-i7", version34))
                output = root / "outputs"
                result = subprocess.run(
                    ["bash", "-e", "-c", command], cwd=root, capture_output=True, text=True,
                    env={**os.environ, "GITHUB_OUTPUT": str(output)},
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                versions = [version34, "15-robolectric-12650502-i7"]
                self.assertEqual(output.read_text().splitlines(), [
                    "versions=" + "-".join(versions), "paths<<EOF",
                    *[f"~/.gradle/caches/modules-2/files-2.1/org.robolectric/android-all-instrumented/{v}/*/android-all-instrumented-{v}.jar" for v in versions],
                    "EOF",
                ])

    def test_robolectric_mirror_is_first_and_filters_only_sdk_module(self):
        settings = (ROOT / "android/settings.gradle.kts").read_text()
        repositories = settings.split("dependencyResolutionManagement {", 1)[1]
        self.assertIn('https://maven-central.storage-download.googleapis.com/maven2/', repositories)
        self.assertLess(repositories.index("storage-download.googleapis.com"), repositories.index("google {"))
        self.assertLess(repositories.index("storage-download.googleapis.com"), repositories.index("mavenCentral()"))
        self.assertIn('includeModule("org.robolectric", "android-all-instrumented")', repositories)
        self.assertIn('excludeModule("org.robolectric", "android-all-instrumented")', repositories)
        self.assertNotIn("exclusiveContent", repositories)  # Central remains a missing-module fallback.

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
