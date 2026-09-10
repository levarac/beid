"""Tests for the pinned-Parallax-ref single-source check (beid#478).

The check exists because the property everyone states ("the ref lives in exactly
one place") was never the property enforced ("this one file has one
assignment"). These tests are written so that a check which only re-implemented
the narrow property would fail them: the strays they plant are in *other* files,
and none of them is an `EXPECTED_PARALLAX_REF` assignment.
"""

import shutil
import subprocess
import textwrap
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory


REPO_ROOT = Path(__file__).resolve().parents[2]
CHECK = REPO_ROOT / "scripts" / "check_parallax_ref_single_source.py"
PIN_SCRIPT = REPO_ROOT / "scripts" / "clone_parallax_pinned.sh"
CANONICAL_REL = Path(
    "shared/src/androidHostTest/kotlin/org/levarac/parallax/registry"
    "/ParallaxEventDefinitionSourceChecksumTest.kt"
)
REF = "a" * 40
OTHER_REF = "b" * 40


class SingleSourceCheckTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.repo = Path(self._tmp.name)

        (self.repo / "scripts" / "tests").mkdir(parents=True)
        shutil.copy2(CHECK, self.repo / "scripts" / CHECK.name)
        shutil.copy2(PIN_SCRIPT, self.repo / "scripts" / PIN_SCRIPT.name)

        canonical = self.repo / CANONICAL_REL
        canonical.parent.mkdir(parents=True)
        canonical.write_text(
            f'private const val EXPECTED_PARALLAX_REF = "{REF}"\n', encoding="utf-8"
        )

        subprocess.run(["git", "init", "-q"], cwd=self.repo, check=True)
        self._track()

    def _track(self) -> None:
        subprocess.run(["git", "add", "-A"], cwd=self.repo, check=True)

    def _write(self, relative: str, body: str) -> None:
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(textwrap.dedent(body), encoding="utf-8")
        self._track()

    def _run(self) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["python3", str(self.repo / "scripts" / CHECK.name)],
            capture_output=True,
            text=True,
            cwd=self.repo,
        )

    def test_a_lone_canonical_copy_passes(self) -> None:
        result = self._run()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_second_copy_in_a_workflow_is_caught(self) -> None:
        """The case the script's own comment names: a ref restated in YAML."""
        self._write(".github/workflows/example.yml", f'        ref: "{REF}"\n')
        result = self._run()
        self.assertEqual(result.returncode, 1)
        self.assertIn(".github/workflows/example.yml:1", result.stderr)

    def test_a_second_copy_in_prose_is_caught(self) -> None:
        self._write("docs/note.md", f"verified against `{REF}` on some date\n")
        result = self._run()
        self.assertEqual(result.returncode, 1)
        self.assertIn("docs/note.md:1", result.stderr)

    def test_a_second_copy_under_a_different_constant_name_is_caught(self) -> None:
        """The narrow check greps for the constant name; this has a different one."""
        self._write("shared/src/Other.kt", f'const val SOME_OTHER_PIN = "{REF}"\n')
        result = self._run()
        self.assertEqual(result.returncode, 1)
        self.assertIn("shared/src/Other.kt:1", result.stderr)

    def test_an_unrelated_40_hex_string_is_not_caught(self) -> None:
        """Only the pinned value matters; other digests are none of this check's business."""
        self._write("docs/other.md", f"baseline source SHA-256 `{OTHER_REF}`\n")
        result = self._run()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_an_abbreviated_prefix_is_deliberately_not_caught(self) -> None:
        """Documents the trade in the check's docstring, so a future change is a choice.

        `test_parallax_ci_wiring.py` keeps a 7-hex prefix of a superseded ref as a
        negative-test fixture. Scanning prefixes would fail on it forever, and
        exempting it would need an allowlist that goes stale silently.
        """
        self._write("scripts/tests/short.py", f'REJECTED = "{REF[:7]}"\n')
        result = self._run()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_canonical_file_without_the_ref_fails_rather_than_reporting_zero(
        self,
    ) -> None:
        """A scan that cannot find the pin where it lives cannot certify absence elsewhere."""
        (self.repo / CANONICAL_REL).write_text(
            'private const val EXPECTED_PARALLAX_REF = "main"\n', encoding="utf-8"
        )
        self._track()
        result = self._run()
        self.assertNotEqual(result.returncode, 0)

    def test_untracked_files_are_out_of_scope(self) -> None:
        """Scope is `git ls-files`; build output is excluded without listing it."""
        stray = self.repo / "build" / "generated.txt"
        stray.parent.mkdir(parents=True, exist_ok=True)
        stray.write_text(f"{REF}\n", encoding="utf-8")
        result = self._run()
        self.assertEqual(result.returncode, 0, result.stderr)


class ThisRepositoryHoldsTheInvariantTest(unittest.TestCase):
    """Run the check against the real repository, not just fixtures.

    This is the wiring. Without it the suite would only prove the check *can*
    detect a planted copy, while a real second copy sat in the tree unnoticed --
    and one did: `docs/plans/2026-09-10-venue-bundle-import.md` carried the full
    pin from the moment it landed, after the issue that asked for this check had
    already measured the tree as clean. Fixture tests would all have stayed
    green through that.

    It runs in the Repository sanity job via `unittest discover`, so no workflow
    change is needed to make it a gate.
    """

    def test_the_pinned_ref_appears_only_in_its_canonical_source(self) -> None:
        result = subprocess.run(
            ["python3", str(CHECK)], capture_output=True, text=True, cwd=REPO_ROOT
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


class CanonicalPathIsNotRestatedTest(unittest.TestCase):
    def test_the_checker_reads_the_path_from_the_pin_script(self) -> None:
        """The checker must not name the canonical file itself (beid#478).

        If it did, bumping the pin's home would need two edits and the checker
        would be the second source of truth it forbids.
        """
        body = CHECK.read_text(encoding="utf-8")
        code = body.split('"""', 2)[-1]
        self.assertNotIn("ParallaxEventDefinitionSourceChecksumTest", code)
        self.assertIn("--print-source", body)


if __name__ == "__main__":
    unittest.main()
