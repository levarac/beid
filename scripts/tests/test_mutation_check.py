"""Tests for scripts/mutation_check.py.

Written against the specification for beid#662, deliberately NOT by reading
the implementation: this tool exists because a hand-built list of "behaviors
covered by tests" looked complete three times and was short three times, and
a test derived from the implementation only proves the implementation equals
itself -- the exact failure mode mutation_check.py was built to prevent.

The bug being pinned here: on 2026-09-23 the tool reported "99 sites, 99
killed, 0 survived" for beid#633's sigil geometry, where every constant
deciding the drawing is a `Double`. It had mutated none of them. The float
operator is what closes that hole, and `test_nine_float_constants_all_become_
sites` is the test that makes reintroducing the hole impossible to do
quietly.

No test here invokes Gradle. One full suite run per mutation site is what
makes the tool expensive, and a test that needed it would never be run.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import math
import os
import re
import shutil
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "mutation_check.py"


def load_module():
    if not SCRIPT.exists():
        raise AssertionError(f"production CLI is missing: {SCRIPT}")
    spec = importlib.util.spec_from_file_location("mutation_check", SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def looks_like_float_literal(text: str) -> bool:
    """A Kotlin token that the compiler will read as a Double/Float literal.

    Either it carries an `f`/`F` suffix, or its body has a decimal point or
    an exponent. A bare integer token is a type error where a Double is
    expected, and the resulting compile failure would be misreported as
    "killed (build failed)" -- a mutant credited to a test that never ran.
    """
    if text[-1:] in ("f", "F"):
        return True
    return "." in text or "e" in text or "E" in text


class ModuleTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tool = load_module()

    def sites_for(self, source: str):
        """find_sites() over a throwaway Kotlin file holding `source`."""
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "Sample.kt"
            path.write_bytes(source.encode("utf-8"))
            sites = self.tool.find_sites(path)
            # Offsets are absolute character offsets into the decoded text;
            # a site whose slice does not equal its own `original` would
            # splice the mutation into the wrong place.
            text = self.tool.read_source_text(path)
            for site in sites:
                self.assertEqual(text[site.start : site.end], site.original)
            return sites

    def pairs_for(self, source: str, kind=None):
        return [
            (s.original, s.mutated)
            for s in self.sites_for(source)
            if kind is None or s.kind == kind
        ]


# --------------------------------------------------------------------------
# 1. Float sites are found. This is the beid#662 regression test.
# --------------------------------------------------------------------------

SIGIL_SAMPLE = """package org.levarac.beid.sample

object SigilGeometry {
    const val RADIUS = 12.5
    const val STROKE = 1.5f
    const val ORIGIN = 0.0
    const val EPSILON = 0.0001
    const val FAR = 1e3
    const val UNIT = 1f
    const val WIDTH = 200.0
    const val SPAN = 1_000.5
    const val TINY = 2E-5F
}
"""

EXPECTED_SIGIL_FLOAT_SITES = [
    ("12.5", "11.25"),
    ("1.5f", "1.35f"),
    ("0.0", "1.0"),
    ("0.0001", "9e-05"),
    ("1e3", "900.0"),
    ("1f", "0.9f"),
    ("200.0", "180.0"),
    ("1_000.5", "900.45"),
    ("2E-5F", "1.8e-05F"),
]


class FloatSiteDiscoveryTests(ModuleTest):
    def test_nine_float_constants_all_become_sites(self):
        """The whole point of beid#662: a file of Doubles must not scan empty.

        Before the float operator, this exact sample produced zero sites and
        the tool still printed a confident "0 survived".
        """
        sites = self.sites_for(SIGIL_SAMPLE)
        self.assertNotEqual(len(sites), 0, "a file of Double constants scanned to zero sites")
        self.assertEqual(len(sites), len(EXPECTED_SIGIL_FLOAT_SITES))
        self.assertEqual(
            [(s.original, s.mutated) for s in sites], EXPECTED_SIGIL_FLOAT_SITES
        )

    def test_every_site_in_the_sample_is_kind_float(self):
        for site in self.sites_for(SIGIL_SAMPLE):
            with self.subTest(literal=site.original):
                self.assertEqual(site.kind, "float")

    def test_each_named_literal_is_found_individually(self):
        for original, mutated in EXPECTED_SIGIL_FLOAT_SITES:
            with self.subTest(literal=original):
                self.assertEqual(
                    self.pairs_for(f"val x = {original}\n"), [(original, mutated)]
                )

    def test_a_literal_the_perturbation_refuses_is_skipped_entirely(self):
        """perturb returning None must drop the site, not register a no-op.

        `1e999` overflows to inf, so there is no mutant to write. A site with
        nothing to change would be reported "survived" having tested nothing,
        and would burn a full Gradle run doing it.
        """
        self.assertIsNotNone(self.tool.FLOAT_RE.search("1e999"))
        self.assertIsNone(self.tool.perturb_float_literal("1e999"))
        self.assertEqual(self.sites_for("val huge = 1e999\n"), [])

    def test_no_site_in_the_sample_is_a_no_op(self):
        """A mutation that changes nothing reports "survived" having tested
        nothing, and burns a full Gradle run to do it."""
        for site in self.sites_for(SIGIL_SAMPLE):
            with self.subTest(literal=site.original):
                self.assertNotEqual(site.mutated, site.original)

    def test_every_mutant_is_a_valid_looking_float_literal(self):
        for site in self.sites_for(SIGIL_SAMPLE):
            with self.subTest(literal=site.original):
                self.assertTrue(
                    looks_like_float_literal(site.mutated),
                    f"{site.mutated!r} would not compile as a Double/Float",
                )

    def test_line_numbers_track_the_literal(self):
        sites = self.sites_for(SIGIL_SAMPLE)
        by_original = {s.original: s.line for s in sites}
        self.assertEqual(by_original["12.5"], 4)
        self.assertEqual(by_original["2E-5F"], 12)


class FloatRegexTests(ModuleTest):
    MATCHING = [
        ("12.5", "12.5", ""),
        ("1.5f", "1.5", "f"),
        ("0.0", "0.0", ""),
        ("0.0001", "0.0001", ""),
        ("1e3", "1e3", ""),
        ("2E-5F", "2E-5", "F"),
        ("1f", "1", "f"),
        ("200.0", "200.0", ""),
        ("1_000.5", "1_000.5", ""),
        ("3.0e-8", "3.0e-8", ""),
    ]

    def test_group_one_is_the_body_and_group_two_the_suffix(self):
        for text, body, suffix in self.MATCHING:
            with self.subTest(text=text):
                match = self.tool.FLOAT_RE.search(text)
                self.assertIsNotNone(match, f"FLOAT_RE did not match {text!r}")
                self.assertEqual(match.group(0), text)
                self.assertEqual(match.group(1), body)
                self.assertEqual(match.group(2), suffix)

    def test_integer_literals_belong_to_the_other_operator(self):
        for text in ("6", "7L"):
            with self.subTest(text=text):
                self.assertIsNone(self.tool.FLOAT_RE.search(text))


# --------------------------------------------------------------------------
# 2. The integer operator is undisturbed.
# --------------------------------------------------------------------------


class IntegerOperatorTests(ModuleTest):
    def test_plain_and_long_integers_still_increment(self):
        self.assertEqual(self.pairs_for("val a = 6\n"), [("6", "7")])
        self.assertEqual(self.pairs_for("val b = 7L\n"), [("7L", "8L")])

    def test_integer_sites_are_still_kind_integer(self):
        for source in ("val a = 6\n", "val b = 7L\n"):
            with self.subTest(source=source):
                self.assertEqual([s.kind for s in self.sites_for(source)], ["integer"])

    def test_integer_range_matches_only_its_lower_bound(self):
        """A documented, verified miss: the lookbehind rejects a digit
        preceded by `.`, so `10` in `1..10` is never seen."""
        self.assertEqual(self.pairs_for("val r = 1..10\n"), [("1", "2")])

    def test_float_range_matches_only_its_lower_bound(self):
        self.assertEqual(self.pairs_for("val r = 0.0..1.0\n"), [("0.0", "1.0")])

    def test_decimal_literal_is_not_split_into_integer_sites(self):
        """`12.5` must be one float site, never an integer site for `12`."""
        self.assertEqual([s.kind for s in self.sites_for("val a = 12.5\n")], ["float"])

    def test_float_receiver_call_is_matched(self):
        self.assertEqual(
            self.pairs_for("val n = 1.0.toInt()\n"), [("1.0", "0.9")]
        )


class ExponentLiteralOwnershipTests(ModuleTest):
    """An exponent literal must produce exactly one site, and it must be the
    float one.

    The integer lookbehind `(?<![\\w.])` admits the trailing `8` of `3.0e-8`,
    because the character before it is `-` -- neither a word character nor a
    `.`. Measured: NUMERIC_RE offers candidates at both `3` and `8` for
    `val x = 3.0e-8`, while FLOAT_RE offers one at `3.0e-8`. The `3` is
    dropped by the decimal-float skip and the `8` by the overlap dedup, since
    the float candidate starts earlier and is kept first.

    So the behavior is correct, but correct by candidate ordering rather than
    by construction. Restructure the dedup or the append order and the
    integer operator starts mutating the exponent of a float literal --
    turning `3.0e-8` into `3.0e-9`, a 10x error dressed up as a mutant --
    with nothing to say so. Asserting only "the float site exists" would
    still pass with the stray integer site back alongside it, so these assert
    the count.
    """

    EXPONENT_LITERALS = [
        ("3.0e-8", "2.7e-08"),
        ("1.5e+10", "13500000000.0"),
        ("2e-3f", "0.0018f"),
    ]

    def test_exactly_one_float_site_and_no_integer_site(self):
        for original, mutated in self.EXPONENT_LITERALS:
            with self.subTest(literal=original):
                sites = self.sites_for(f"val x = {original}\n")
                self.assertEqual(
                    len(sites), 1, f"{original!r} produced {len(sites)} sites, expected 1"
                )
                self.assertEqual(sites[0].kind, "float")
                self.assertEqual((sites[0].original, sites[0].mutated), (original, mutated))

    def test_no_integer_kind_site_survives_for_an_exponent_literal(self):
        for original, _ in self.EXPONENT_LITERALS:
            with self.subTest(literal=original):
                kinds = [s.kind for s in self.sites_for(f"val x = {original}\n")]
                self.assertNotIn("integer", kinds)

    def test_exponent_literals_together_in_one_file(self):
        source = "".join(f"val v{i} = {lit}\n" for i, (lit, _) in enumerate(self.EXPONENT_LITERALS))
        sites = self.sites_for(source)
        self.assertEqual(len(sites), len(self.EXPONENT_LITERALS))
        self.assertEqual(
            [(s.original, s.mutated) for s in sites], self.EXPONENT_LITERALS
        )
        self.assertEqual({s.kind for s in sites}, {"float"})


# --------------------------------------------------------------------------
# 3. Strings and comments are never mutated.
# --------------------------------------------------------------------------

MASKED_ONLY_SAMPLE = '''package org.levarac.beid.sample

object Text {
    const val A = "radius 12.5 units"
    const val B = """
        block 3.5 text
    """
    // comment 7.25 here
    /* block comment 8.5 here */
}
'''

MIXED_SAMPLE = '''object Text {
    const val A = "radius 12.5 units"
    // comment 7.25 here
    const val C = 1.25
}
'''


class MaskingTests(ModuleTest):
    def test_floats_only_inside_strings_and_comments_yield_no_sites(self):
        self.assertEqual(self.sites_for(MASKED_ONLY_SAMPLE), [])

    def test_real_code_float_is_still_found_beside_masked_ones(self):
        self.assertEqual(self.pairs_for(MIXED_SAMPLE), [("1.25", "1.125")])

    def test_each_masking_context_individually(self):
        for label, source in [
            ("single-quoted string", 'val a = "12.5"\n'),
            ("raw string", 'val a = """12.5"""\n'),
            ("line comment", "// 12.5\n"),
            ("block comment", "/* 12.5 */\n"),
        ]:
            with self.subTest(context=label):
                self.assertEqual(self.sites_for(source), [])


# --------------------------------------------------------------------------
# 4. Perturbation semantics, directly against perturb_float_literal.
# --------------------------------------------------------------------------

SWEEP_BODIES = [
    "12.5", "1.5", "0.0", "0.0001", "1e3", "1", "200.0", "1_000.5", "2E-5",
    "3.0e-8", "0.95", "1.0", "0.5", "99.99", "123.456", "1e-300", "1e308",
    "0.000000001", "7.0", "0.1", "1_000_000.0", "2.5E10", "9.99999e-7",
]


class PerturbFloatLiteralTests(ModuleTest):
    def test_zero_gets_the_one_absolute_special_case(self):
        """Relative scaling cannot move 0.0, so it becomes 1.0 -- the top of
        the canonical 0.0..1.0 ratio range."""
        self.assertEqual(self.tool.perturb_float_literal("0.0"), "1.0")
        self.assertEqual(self.tool.perturb_float_literal("0.000"), "1.0")

    def test_a_ratio_stays_inside_its_range(self):
        self.assertEqual(self.tool.perturb_float_literal("0.95"), "0.855")

    def test_underscores_are_stripped_before_conversion(self):
        self.assertEqual(self.tool.perturb_float_literal("1_000.5"), "900.45")

    def test_mutant_stays_within_zero_and_the_original(self):
        """Invariant from the rationale, asserted as an invariant.

        Scaling toward zero keeps the mutant inside [0, original], so every
        upper-bound validation the original satisfied the mutant satisfies
        too. If a mutation tripped a `require(x in 0.0..1.0)`, the run would
        report "killed" because a range check threw rather than because a
        test checks the behavior -- a false sense of protection.

        0.0 is the single documented exception: it is the one value relative
        scaling cannot move, so it is special-cased upward to 1.0.
        """
        for body in SWEEP_BODIES:
            with self.subTest(body=body):
                original = float(body.replace("_", ""))
                mutated_text = self.tool.perturb_float_literal(body)
                self.assertIsNotNone(mutated_text, f"finite {body!r} produced no mutant")
                mutated = float(mutated_text)
                if original == 0.0:
                    self.assertEqual(mutated, 1.0)
                    continue
                self.assertGreaterEqual(mutated, 0.0)
                self.assertLessEqual(mutated, original)

    def test_mutant_is_a_meaningful_change_not_a_rounding_artifact(self):
        """The mutant must actually differ; a value that scaled back onto
        itself would be reported "survived" having tested nothing."""
        for body in SWEEP_BODIES:
            with self.subTest(body=body):
                mutated_text = self.tool.perturb_float_literal(body)
                self.assertIsNotNone(mutated_text)
                self.assertNotEqual(float(mutated_text), float(body.replace("_", "")))

    def test_result_always_reads_as_a_float_literal(self):
        for body in SWEEP_BODIES:
            with self.subTest(body=body):
                mutated_text = self.tool.perturb_float_literal(body)
                self.assertIsNotNone(mutated_text)
                self.assertTrue(
                    "." in mutated_text or "e" in mutated_text or "E" in mutated_text,
                    f"{mutated_text!r} is a bare integer token, not a float literal",
                )
                float(mutated_text)  # must parse

    def test_non_finite_values_are_refused(self):
        for body in ("1e999", "2E400"):
            with self.subTest(body=body):
                self.assertFalse(math.isfinite(float(body)))
                self.assertIsNone(self.tool.perturb_float_literal(body))


class SuffixPreservationTests(ModuleTest):
    def test_lowercase_and_uppercase_suffixes_survive_the_mutation(self):
        for source, expected in [
            ("val a = 1.5f\n", ("1.5f", "1.35f")),
            ("val a = 2E-5F\n", ("2E-5F", "1.8e-05F")),
            ("val a = 1f\n", ("1f", "0.9f")),
            ("val a = 0.0F\n", ("0.0F", "1.0F")),
        ]:
            with self.subTest(source=source.strip()):
                self.assertEqual(self.pairs_for(source), [expected])

    def test_suffix_case_is_not_normalised(self):
        (original, mutated), = self.pairs_for("val a = 2E-5F\n")
        self.assertTrue(original.endswith("F"))
        self.assertTrue(mutated.endswith("F"))
        self.assertFalse(mutated.endswith("f"))


class SweepSiteInvariantTests(ModuleTest):
    """The same invariants, but through find_sites() over real file text."""

    @staticmethod
    def as_literal(body: str) -> str:
        """A bare-integer body such as `1` is only ever a float *body* when an
        `f`/`F` suffix follows it, so write it back as one."""
        if "." in body or "e" in body or "E" in body:
            return body
        return body + "f"

    def test_no_site_is_ever_a_no_op_and_every_mutant_compiles_as_a_float(self):
        literals = [self.as_literal(body) for body in SWEEP_BODIES]
        source = "".join(f"val v{i} = {lit}\n" for i, lit in enumerate(literals))
        sites = self.sites_for(source)
        self.assertEqual([s.original for s in sites], literals)
        for site in sites:
            with self.subTest(literal=site.original):
                self.assertEqual(site.kind, "float")
                self.assertNotEqual(site.mutated, site.original)
                self.assertTrue(looks_like_float_literal(site.mutated))


# --------------------------------------------------------------------------
# 5/6. Snapshot restore: byte-exact, and loud when it fails.
# --------------------------------------------------------------------------

# CRLF and Japanese are in the fixture on purpose. `write_text` applies
# newline translation, so restoring with it would silently rewrite every line
# ending in a CRLF file as a side effect of restoring one literal.
CRLF_JA_SOURCE_BYTES = (
    "package org.levarac.beid.sample\r\n"
    "\r\n"
    "object 紋様 {\r\n"
    "    // 半径はここで決まる\r\n"
    "    const val RADIUS = 12.5\r\n"
    "    const val ALPHA = 0.95\r\n"
    "}\r\n"
).encode("utf-8")


class SnapshotRestoreTests(ModuleTest):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        # Deliberately outside any git worktree: a file git does not track is
        # exactly the case the old `git checkout --` restore could not handle,
        # and the case you are in when writing tests for brand-new code.
        self.target = self.tmp / "Untracked.kt"
        self.target.write_bytes(CRLF_JA_SOURCE_BYTES)
        self.backup_dir = self.tmp / "backups"
        self.backup_dir.mkdir()

    def tearDown(self):
        with contextlib.suppress(OSError):
            self.target.chmod(stat.S_IRUSR | stat.S_IWUSR)
        self._tmp.cleanup()

    def snapshot(self):
        snapshots = self.tool.snapshot_files([self.target], self.backup_dir)
        return snapshots[self.target]

    def test_read_source_text_preserves_crlf(self):
        """Offsets are measured against the bytes on disk, so the decode must
        not translate newlines or every offset past line 1 is wrong."""
        text = self.tool.read_source_text(self.target)
        self.assertIn("\r\n", text)
        self.assertEqual(text.encode("utf-8"), CRLF_JA_SOURCE_BYTES)

    def test_snapshot_captures_bytes_and_writes_a_backup(self):
        snapshot = self.snapshot()
        self.assertEqual(snapshot.path, self.target)
        self.assertEqual(snapshot.original_bytes, CRLF_JA_SOURCE_BYTES)
        self.assertTrue(snapshot.backup_path.exists())
        self.assertEqual(snapshot.backup_path.read_bytes(), CRLF_JA_SOURCE_BYTES)

    def test_mutate_then_restore_is_byte_identical_on_an_untracked_file(self):
        snapshot = self.snapshot()
        sites = self.tool.find_sites(self.target)
        self.assertEqual(
            [(s.original, s.mutated) for s in sites],
            [("12.5", "11.25"), ("0.95", "0.855")],
        )
        for site in sites:
            with self.subTest(literal=site.original):
                original_text = snapshot.original_bytes.decode("utf-8")
                mutated_text = (
                    original_text[: site.start] + site.mutated + original_text[site.end :]
                )
                self.target.write_bytes(mutated_text.encode("utf-8"))
                self.assertNotEqual(self.target.read_bytes(), CRLF_JA_SOURCE_BYTES)
                self.assertIn(site.mutated, self.tool.read_source_text(self.target))

                self.tool.restore(snapshot)
                self.assertEqual(self.target.read_bytes(), CRLF_JA_SOURCE_BYTES)

    def test_restore_raises_when_the_write_does_not_land(self):
        """The read-back is the point. A restore that silently did not land
        leaves a mutated constant in a source file and nothing turns red."""
        snapshot = self.snapshot()
        self.target.write_bytes(b"mutated, and nothing like the original\r\n")

        def swallow(self, data):  # a write that reports success and does nothing
            return len(data)

        with mock.patch.object(Path, "write_bytes", swallow):
            with self.assertRaises(Exception) as caught:
                self.tool.restore(snapshot)
        self.assertNotIsInstance(caught.exception, AssertionError)
        self.assertIn(self.target.name, str(caught.exception))

    @unittest.skipIf(
        hasattr(os, "geteuid") and os.geteuid() == 0, "root ignores file permissions"
    )
    def test_restore_raises_when_the_target_is_unwritable(self):
        snapshot = self.snapshot()
        self.target.chmod(stat.S_IRUSR)
        with self.assertRaises(OSError):
            self.tool.restore(snapshot)

    def test_restore_or_die_is_loud_and_exits_non_zero(self):
        """A failed restore must stop the run with the file, the backup and
        the exact recovery command on stderr -- not a quiet return."""
        snapshot = self.snapshot()
        self.target.write_bytes(b"still mutated\r\n")
        stderr = io.StringIO()

        def swallow(self, data):
            return len(data)

        with mock.patch.object(Path, "write_bytes", swallow):
            with contextlib.redirect_stderr(stderr):
                with self.assertRaises(SystemExit) as caught:
                    self.tool.restore_or_die(snapshot, self.backup_dir)

        self.assertNotEqual(caught.exception.code, 0)
        self.assertEqual(caught.exception.code, 2)
        banner = stderr.getvalue()
        self.assertIn(str(self.target), banner)
        self.assertIn(str(snapshot.backup_path), banner)
        self.assertIn(str(self.backup_dir), banner)
        self.assertIn("cp ", banner)
        self.assertIn("RESTORE FAILED", banner)

    def test_restore_or_die_is_silent_and_returns_on_success(self):
        snapshot = self.snapshot()
        self.target.write_bytes(b"mutated\r\n")
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            self.tool.restore_or_die(snapshot, self.backup_dir)
        self.assertEqual(stderr.getvalue(), "")
        self.assertEqual(self.target.read_bytes(), CRLF_JA_SOURCE_BYTES)


class DirtyTargetTests(ModuleTest):
    def test_a_dirty_or_untracked_target_is_noted_and_proceeds(self):
        """It no longer refuses. Running against a never-committed file is
        the entire point of the snapshot restore."""
        target = ROOT / "scripts" / "mutation_check.py"
        stdout = io.StringIO()
        with mock.patch.object(self.tool, "git_status_porcelain", return_value="?? x.kt"):
            with contextlib.redirect_stdout(stdout):
                result = self.tool.note_if_dirty(target)
        self.assertIsNone(result)
        printed = stdout.getvalue()
        self.assertIn("scripts/mutation_check.py", printed)
        self.assertIn("snapshot", printed.lower())

    def test_a_clean_target_prints_nothing(self):
        target = ROOT / "scripts" / "mutation_check.py"
        stdout = io.StringIO()
        with mock.patch.object(self.tool, "git_status_porcelain", return_value=""):
            with contextlib.redirect_stdout(stdout):
                self.tool.note_if_dirty(target)
        self.assertEqual(stdout.getvalue(), "")

    def test_the_git_clean_refusal_and_git_restore_are_gone(self):
        for name in ("ensure_clean", "restore_file"):
            with self.subTest(removed=name):
                self.assertFalse(
                    hasattr(self.tool, name),
                    f"{name}() is back; the tool refuses new code again",
                )

    def test_a_target_outside_the_repository_does_not_consult_git(self):
        with tempfile.TemporaryDirectory() as tmp:
            outside = Path(tmp) / "Outside.kt"
            outside.write_text("val a = 1.5\n", encoding="utf-8")
            with mock.patch.object(
                self.tool, "git_status_porcelain", side_effect=AssertionError("called git")
            ):
                self.assertIsNone(self.tool.note_if_dirty(outside))


# --------------------------------------------------------------------------
# 7. display_path.
# --------------------------------------------------------------------------


class DisplayPathTests(ModuleTest):
    def test_path_inside_the_repository_is_relative(self):
        self.assertEqual(
            self.tool.display_path(ROOT / "scripts" / "mutation_check.py"),
            "scripts/mutation_check.py",
        )

    def test_path_outside_the_repository_is_absolute_and_does_not_raise(self):
        with tempfile.TemporaryDirectory() as tmp:
            outside = Path(tmp).resolve() / "Outside.kt"
            self.assertEqual(self.tool.display_path(outside), str(outside))


# --------------------------------------------------------------------------
# 8. Documentation consistency -- keyword level only.
# --------------------------------------------------------------------------


class DocstringConsistencyTests(ModuleTest):
    def test_docstring_names_the_integer_limit_and_the_float_operator(self):
        """Keyword level on purpose. beid#662 was caused by AGENTS.md
        summarising this operator as "numeric-literal", which does not read
        as integer-only; a test that pinned exact sentences instead would be
        deleted the first time someone edited a paragraph."""
        doc = (self.tool.__doc__ or "").lower()
        self.assertTrue(doc, "mutation_check.py has no module docstring")
        self.assertIn("integer", doc)
        self.assertTrue(
            any(
                phrase in doc
                for phrase in ("integer literals only", "integer-only", "integer only")
            ),
            "the docstring does not say the integer operator is integer-only",
        )
        self.assertIn("float", doc)
        self.assertIn("double", doc)
        self.assertIn("snapshot", doc)


# --------------------------------------------------------------------------
# 9. main(): the whole loop, without Gradle.
# --------------------------------------------------------------------------

# Two sites of two different kinds, so one run exercises both operators and
# the JSON report has both `kind` values in it. CRLF and Japanese again,
# because the end-to-end claim that matters is that the file this tool
# mutated a dozen times comes back byte-identical.
INTEGRATION_SOURCE_BYTES = (
    "package org.levarac.beid.sample\r\n"
    "\r\n"
    "object \u7d0b\u69d8 {\r\n"
    "    // \u534a\u5f84\u306f\u3053\u3053\u3067\u6c7a\u307e\u308b\r\n"
    "    const val RADIUS = 12.5\r\n"
    "    const val COUNT = 6\r\n"
    "}\r\n"
).encode("utf-8")

GREEN = {"org.levarac.beid.SigilTest#radiusIsStable": False}
RED = {
    "org.levarac.beid.SigilTest#radiusIsStable": True,
    "org.levarac.beid.SigilTest#countIsStable": False,
}


class FakeGradle:
    """Stands in for run_tests(tasks, env, verbose=False).

    The first call is main()'s unmutated baseline pass; each later call is one
    mutated site, in site order. `verdicts` gives the per-site result: RED
    makes that mutant "killed", GREEN makes it "survive".
    """

    def __init__(self, verdicts):
        self.verdicts = list(verdicts)
        self.calls = []

    def __call__(self, tasks, env, verbose=False):
        self.calls.append(tasks)
        if len(self.calls) == 1:
            return 0, dict(GREEN), []
        results = self.verdicts[len(self.calls) - 2]
        return (1 if any(results.values()) else 0), dict(results), ["tail"]


class MainIntegrationTests(ModuleTest):
    """main() end to end with Gradle replaced, so the parts of the contract
    that only exist inside main() are checked rather than read.

    The backup directory's lifecycle (announced at startup, removed on
    success, KEPT on a failed restore) lived only here until this class
    existed, which meant the documentation described behavior nothing
    verified -- the same shape as the beid#662 bug itself.
    """

    def setUp(self):
        # Deliberately inside the repository and genuinely untracked: a path
        # outside REPO_ROOT never reaches git, so it could not show that an
        # untracked target is accepted rather than refused.
        self.dir = Path(tempfile.mkdtemp(dir=ROOT, prefix="mutation-check-it-")).resolve()
        self.target = self.dir / "Sigil.kt"
        self.target.write_bytes(INTEGRATION_SOURCE_BYTES)
        self.json_out = Path(tempfile.mkdtemp(prefix="mutation-check-json-")) / "report.json"
        self._leaked_backups = []

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)
        shutil.rmtree(self.json_out.parent, ignore_errors=True)
        for path in self._leaked_backups:
            shutil.rmtree(path, ignore_errors=True)
        self.assertFalse(self.dir.exists(), "integration fixture left inside the repo")

    def run_main(self, verdicts, restore_raises=False):
        """Run main() with Gradle and the JDK lookup replaced. Returns
        (exit_code, stdout, stderr, fake)."""
        fake = FakeGradle(verdicts)
        argv = [
            "mutation_check.py",
            "--target", str(self.target),
            "--test-task", ":shared:testAndroidHostTest",
            "--json-out", str(self.json_out),
        ]
        stdout, stderr = io.StringIO(), io.StringIO()
        patches = [
            mock.patch.object(self.tool, "run_tests", fake),
            mock.patch.object(self.tool, "resolve_java_home", lambda: "/fake/jdk"),
            mock.patch.object(sys, "argv", argv),
        ]
        if restore_raises:
            def boom(snapshot):
                raise RuntimeError("simulated restore failure")
            patches.append(mock.patch.object(self.tool, "restore", boom))

        with contextlib.ExitStack() as stack:
            for patch in patches:
                stack.enter_context(patch)
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                with self.assertRaises(SystemExit) as caught:
                    self.tool.main()
        out = stdout.getvalue()
        backup_dir = self.backup_dir_from(out)
        if backup_dir is not None:
            self._leaked_backups.append(backup_dir)
        return caught.exception.code, out, stderr.getvalue(), fake

    @staticmethod
    def backup_dir_from(stdout: str):
        match = re.search(r"backups in: (.+)", stdout)
        return Path(match.group(1).strip()) if match else None

    # -- the loop ---------------------------------------------------------

    def test_one_baseline_pass_plus_one_gradle_run_per_site(self):
        code, out, _, fake = self.run_main([RED, GREEN])
        self.assertEqual(len(fake.calls), 3, "expected 1 baseline + 2 sites")
        self.assertEqual(fake.calls[0], [":shared:testAndroidHostTest"])
        self.assertIn("Found 2 mutable site(s)", out)
        self.assertEqual(code, 1)

    def test_target_is_byte_identical_after_the_whole_run(self):
        self.run_main([RED, GREEN])
        self.assertEqual(self.target.read_bytes(), INTEGRATION_SOURCE_BYTES)

    # -- C7: an untracked target is accepted, not refused ------------------

    def test_an_untracked_target_is_noted_and_the_run_proceeds(self):
        """This is the case the old `git checkout --` restore refused
        outright, and it is the state of every file you are writing tests
        for. git is consulted for real here -- nothing is stubbed."""
        self.assertTrue(self.tool.git_status_porcelain(
            str(self.target.relative_to(ROOT))).startswith("??"))
        code, out, _, fake = self.run_main([RED, RED])
        self.assertIn("dirty or untracked", out)
        self.assertIn("Proceeding", out)
        self.assertEqual(len(fake.calls), 3, "the run did not proceed past the note")
        self.assertEqual(code, 0)

    # -- C3 / C8: the backup directory's lifecycle -------------------------

    def test_backup_directory_is_announced_at_startup(self):
        _, out, _, _ = self.run_main([RED, GREEN])
        self.assertIn("backups in:", out)
        backup_dir = self.backup_dir_from(out)
        self.assertIsNotNone(backup_dir)
        self.assertIn("mutation_check-backup-", backup_dir.name)

    def test_backup_directory_is_removed_on_a_successful_run(self):
        _, out, _, _ = self.run_main([RED, RED])
        backup_dir = self.backup_dir_from(out)
        self.assertFalse(
            backup_dir.exists(), f"backup directory {backup_dir} outlived a clean run"
        )

    def test_backup_directory_is_kept_when_a_restore_fails(self):
        """C8's other half, and the branch that matters most: the kept backup
        is the operator's only recovery path once a mutated literal has been
        left in a source file."""
        code, out, err, fake = self.run_main([RED, GREEN], restore_raises=True)

        self.assertEqual(code, 2)
        self.assertEqual(len(fake.calls), 2, "the run continued past a failed restore")

        backup_dir = self.backup_dir_from(out)
        self.assertTrue(
            backup_dir.exists(),
            f"backup directory {backup_dir} was removed after a failed restore",
        )
        backups = sorted(backup_dir.iterdir())
        self.assertEqual(len(backups), 1)
        self.assertEqual(
            backups[0].read_bytes(),
            INTEGRATION_SOURCE_BYTES,
            "the kept backup does not hold the original bytes",
        )

        self.assertIn("RESTORE FAILED", err)
        self.assertIn(str(backups[0]), err)
        self.assertIn(str(backup_dir), err)
        self.assertIn("cp ", err)

    # -- exit status -------------------------------------------------------

    def test_exit_status_is_one_when_a_mutant_survives(self):
        code, out, _, _ = self.run_main([RED, GREEN])
        self.assertEqual(code, 1)
        self.assertIn("SURVIVED", out)

    def test_exit_status_is_zero_when_every_mutant_is_killed(self):
        code, out, _, _ = self.run_main([RED, RED])
        self.assertEqual(code, 0)
        self.assertNotIn("SURVIVED", out)

    # -- the JSON report ---------------------------------------------------

    def test_json_report_records_both_kinds_counts_and_verdicts(self):
        self.run_main([RED, GREEN])
        report = json.loads(self.json_out.read_text(encoding="utf-8"))

        self.assertEqual(report["sites_mutated"], 2)
        self.assertEqual(report["killed"], 1)
        self.assertEqual(report["survived"], 1)
        self.assertEqual(report["test_tasks"], [":shared:testAndroidHostTest"])
        self.assertEqual(report["baseline_pre_existing_failures"], [])

        results = report["results"]
        self.assertEqual([r["kind"] for r in results], ["float", "integer"])
        self.assertEqual(
            [(r["original"], r["mutated"]) for r in results],
            [("12.5", "11.25"), ("6", "7")],
        )
        self.assertEqual([r["verdict"] for r in results], ["killed", "survived"])
        self.assertEqual(
            results[0]["killed_by"], ["org.levarac.beid.SigilTest#radiusIsStable"]
        )
        self.assertEqual(results[1]["killed_by"], [])

    def test_json_report_paths_are_repo_relative(self):
        """C9 through main(): an absolute path here leaks the checkout
        location into a report meant to be pasted into a PR."""
        self.run_main([RED, GREEN])
        report = json.loads(self.json_out.read_text(encoding="utf-8"))
        for path in [report["target"]] + [r["file"] for r in report["results"]]:
            with self.subTest(path=path):
                self.assertFalse(Path(path).is_absolute())
                self.assertTrue(path.startswith("mutation-check-it-"))

    def test_a_pre_existing_failure_is_never_counted_as_a_kill(self):
        """The baseline pass exists so a suite that is already red cannot
        make every mutant look caught."""
        fake = FakeGradle([RED, RED])
        original_call = fake.__call__

        def already_failing(tasks, env, verbose=False):
            if not fake.calls:
                fake.calls.append(tasks)
                return 1, dict(RED), []
            return original_call(tasks, env, verbose)

        argv = [
            "mutation_check.py",
            "--target", str(self.target),
            "--test-task", ":shared:testAndroidHostTest",
            "--json-out", str(self.json_out),
        ]
        stdout = io.StringIO()
        with mock.patch.object(self.tool, "run_tests", already_failing), \
             mock.patch.object(self.tool, "resolve_java_home", lambda: "/fake/jdk"), \
             mock.patch.object(sys, "argv", argv), \
             contextlib.redirect_stdout(stdout):
            with self.assertRaises(SystemExit) as caught:
                self.tool.main()
        out = stdout.getvalue()
        backup_dir = self.backup_dir_from(out)
        if backup_dir is not None:
            self._leaked_backups.append(backup_dir)

        self.assertIn("already fail before any mutation", out)
        report = json.loads(self.json_out.read_text(encoding="utf-8"))
        self.assertEqual(
            report["baseline_pre_existing_failures"],
            ["org.levarac.beid.SigilTest#radiusIsStable"],
        )
        # Both mutants returned the same already-red test and nothing new, so
        # neither is killed by it.
        self.assertEqual(report["survived"], 2)
        self.assertEqual(caught.exception.code, 1)


if __name__ == "__main__":
    unittest.main()
