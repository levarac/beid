"""Tests for scripts/check_observe_never_connects.py.

The checker's own failure mode is passing when it should not -- a guard that
quietly checks nothing looks exactly like a guard that passes. So these cover
both directions: the real source is clean today, and a planted call is caught.
"""
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
CHECKER = REPO_ROOT / "scripts" / "check_observe_never_connects.py"

spec = importlib.util.spec_from_file_location("check_observe_never_connects", CHECKER)
checker = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = checker
spec.loader.exec_module(checker)


class OffendingLinesTest(unittest.TestCase):
    def test_a_planted_connect_is_found(self):
        found = checker.offending_lines("    central.connect(peripheral, options: nil)\n")
        self.assertEqual([(1, "connect(", "connects to a peripheral")], found)

    def test_the_engine_is_forbidden_too(self):
        # The engine is the subtle one: it looks passive from the call site
        # and enqueues a connect on every discovery that clears its guard.
        found = checker.offending_lines("  private let engine = BarnardEngine()\n")
        self.assertEqual(1, len(found))
        self.assertEqual("BarnardEngine(", found[0][1])

    def test_comments_describing_the_rule_do_not_trip_it(self):
        # The source explains itself by naming these calls. A checker that
        # could not tell prose from code would make the explanation
        # unwritable.
        found = checker.offending_lines("  // No connect(, no discoverServices(, ever.\n")
        self.assertEqual([], found)

    def test_a_call_after_a_comment_on_the_same_line_is_still_found(self):
        found = checker.offending_lines("  central.connect(p) // safe, honest\n")
        self.assertEqual(1, len(found))

    def test_every_line_of_a_multiline_offence_is_reported(self):
        found = checker.offending_lines(
            "central.connect(p)\nlet x = 1\nperipheral.discoverServices(nil)\n"
        )
        self.assertEqual([1, 3], [number for number, _, _ in found])


class MainTest(unittest.TestCase):
    def test_the_real_observe_source_is_clean(self):
        self.assertEqual(0, self._run(REPO_ROOT))

    def test_a_missing_source_fails_rather_than_passing_vacuously(self):
        with tempfile.TemporaryDirectory() as empty:
            self.assertEqual(1, self._run(Path(empty)))

    def test_a_planted_call_in_a_copy_of_the_tree_fails(self):
        with tempfile.TemporaryDirectory() as sandbox:
            for relative in checker.OBSERVE_SOURCES:
                source = REPO_ROOT / relative
                target = Path(sandbox) / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(
                    source.read_text(encoding="utf-8") + "\n// planted\nx.connect(p)\n",
                    encoding="utf-8",
                )
            self.assertEqual(1, self._run(Path(sandbox)))

    def _run(self, root):
        argv = sys.argv
        sys.argv = ["check_observe_never_connects.py", "--root", str(root)]
        try:
            return checker.main()
        finally:
            sys.argv = argv


if __name__ == "__main__":
    unittest.main()
