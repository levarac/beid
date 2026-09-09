"""Contract tests for the beid#415 PR CI wiring of the Parallax comparison.

Two scripts keep the cross-repo byte comparison running on every PR instead of only
when someone points PARALLAX_REPO at a checkout by hand:

- ``scripts/clone_parallax_pinned.sh`` resolves the pinned commit and clones it,
- ``scripts/check_parallax_comparison_ran.py`` refuses to call a skipped comparison a
  passing one.

Both directions matter here. A guard that cannot fail is the defect this issue exists to
remove, so every case below has a partner that must NOT pass: a ref source that is
ambiguous or not a commit must be rejected, and a JUnit file where the comparison skipped
must be rejected even though the surrounding suite is green.

The two JUnit fixtures are real Gradle output captured from ``:shared:testAndroidHostTest``
on 2026-09-09 -- one run with PARALLAX_REPO pointed at a pinned checkout and one with it
unset -- not hand-written XML, so they carry the shape the real task actually produces.
"""
import subprocess
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURES = Path(__file__).resolve().parent / "fixtures"
CLONE_SCRIPT = REPO_ROOT / "scripts" / "clone_parallax_pinned.sh"
GUARD_SCRIPT = REPO_ROOT / "scripts" / "check_parallax_comparison_ran.py"
REAL_REF_SOURCE = (
    REPO_ROOT
    / "shared/src/androidHostTest/kotlin/org/levarac/parallax/registry"
    / "ParallaxEventDefinitionSourceChecksumTest.kt"
)


def run_guard(results_dir):
    return subprocess.run(
        [sys.executable, str(GUARD_SCRIPT), "--results-dir", str(results_dir)],
        capture_output=True,
        text=True,
        cwd=REPO_ROOT,
    )


def print_ref(source):
    return subprocess.run(
        [str(CLONE_SCRIPT), "--print-ref", "--source", str(source)],
        capture_output=True,
        text=True,
        cwd=REPO_ROOT,
    )


class ComparisonEvidenceGuardTests(unittest.TestCase):
    def test_a_comparison_that_ran_is_accepted(self):
        result = run_guard(FIXTURES / "parallax_results_ran")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("ran and was not skipped", result.stdout)

    def test_a_skipped_comparison_is_rejected(self):
        """The partner case. This suite is green overall; only the comparison skipped."""
        result = run_guard(FIXTURES / "parallax_results_skipped")
        self.assertEqual(1, result.returncode)
        self.assertIn("was SKIPPED", result.stderr)
        self.assertIn("not a passing comparison", result.stderr)
        self.assertIn("Parallax checkout is not available", result.stderr)

    def test_a_missing_results_directory_is_rejected(self):
        result = run_guard(FIXTURES / "parallax_results_absent")
        self.assertEqual(1, result.returncode)
        self.assertIn("No JUnit result file", result.stderr)

    def test_a_suite_without_the_comparison_testcase_is_rejected(self):
        result = run_guard(FIXTURES / "parallax_results_without_comparison")
        self.assertEqual(1, result.returncode)
        self.assertIn("has no testcase named", result.stderr)
        self.assertIn("The comparison did not run", result.stderr)

    def test_unparseable_xml_is_rejected_rather_than_read_as_evidence(self):
        result = run_guard(FIXTURES / "parallax_results_malformed")
        self.assertEqual(1, result.returncode)
        self.assertIn("not parseable XML", result.stderr)


class PinnedRefResolutionTests(unittest.TestCase):
    def test_the_pinned_ref_is_read_from_the_test_that_owns_it(self):
        """The workflow must never restate the ref; this is the single source of truth."""
        result = print_ref(REAL_REF_SOURCE)
        self.assertEqual(0, result.returncode, result.stderr)
        ref = result.stdout.strip()
        self.assertRegex(ref, r"^[0-9a-f]{40}$")
        self.assertIn(f'EXPECTED_PARALLAX_REF = "{ref}"', REAL_REF_SOURCE.read_text(encoding="utf-8"))

    def _reject(self, name, body):
        source = Path(self.tmp) / name
        source.write_text(body, encoding="utf-8")
        result = print_ref(source)
        self.assertEqual(1, result.returncode, f"expected refusal, got: {result.stdout}")
        self.assertIn("EXPECTED_PARALLAX_REF", result.stderr)
        return result

    def setUp(self):
        import tempfile

        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = self._tmp.name
        self.addCleanup(self._tmp.cleanup)

    def test_a_source_without_the_constant_is_refused(self):
        self._reject("absent.kt", "private const val SOMETHING_ELSE = \"nope\"\n")

    def test_a_branch_name_is_refused_because_it_is_not_a_pinned_commit(self):
        """A moving ref is the failure the pin exists to prevent, so it must not resolve."""
        self._reject("branch.kt", 'private const val EXPECTED_PARALLAX_REF = "main"\n')

    def test_a_short_sha_is_refused(self):
        self._reject("short.kt", 'private const val EXPECTED_PARALLAX_REF = "5215991"\n')

    def test_two_candidate_refs_are_refused_rather_than_guessed(self):
        self._reject(
            "ambiguous.kt",
            'private const val EXPECTED_PARALLAX_REF = "{}"\n'
            'private const val EXPECTED_PARALLAX_REF = "{}"\n'.format("a" * 40, "b" * 40),
        )

    def test_a_missing_source_file_is_refused(self):
        result = print_ref(Path(self.tmp) / "no-such-file.kt")
        self.assertEqual(1, result.returncode)
        self.assertIn("no such ref source", result.stderr)


class SkipPathTests(unittest.TestCase):
    """Without the secret the clone must skip loudly and leave PARALLAX_REPO UNSET.

    Exporting an empty PARALLAX_REPO would read back in the Kotlin test as a configured
    checkout that is missing, which fails loudly by design (beid#403 / PR #412). Only an
    unset variable may skip, so this asserts the variable is absent, not merely empty.
    """

    def test_no_token_skips_loudly_without_setting_parallax_repo(self):
        import os
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            github_env = Path(tmp) / "github_env"
            github_env.touch()
            summary = Path(tmp) / "summary.md"
            environment = dict(os.environ)
            environment.pop("PARALLAX_READ_TOKEN", None)
            environment["GITHUB_ENV"] = str(github_env)
            environment["GITHUB_STEP_SUMMARY"] = str(summary)

            result = subprocess.run(
                [str(CLONE_SCRIPT)],
                capture_output=True,
                text=True,
                cwd=REPO_ROOT,
                env=environment,
            )

            self.assertEqual(0, result.returncode, result.stderr)
            self.assertIn("::warning", result.stdout)
            self.assertIn("PARALLAX COMPARISON SKIPPED", result.stderr)
            self.assertNotIn("PARALLAX_REPO", github_env.read_text(encoding="utf-8"))
            self.assertIn("Parallax comparison skipped", summary.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
