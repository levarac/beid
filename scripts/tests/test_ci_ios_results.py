import json
import tempfile
import unittest
from pathlib import Path

from scripts.ci_ios_results import GROUPS, aggregate, arguments, counts, verify_scheme

ROOT = Path(__file__).resolve().parents[2]


def summary(**changes):
    value = dict(result="Passed", totalTestCount=4, passedTests=3,
                 failedTests=0, skippedTests=1, expectedFailures=0)
    value.update(changes)
    return value


class IosResultsTests(unittest.TestCase):
    def test_groups_partition_all_current_and_future_tests(self):
        for test in ("BeidTests/NewSuite/testNew", "BeidUITests/BeidIPadLayoutTests/testNew",
                     "BeidUITests/NewSuite/testNew"):
            owners = []
            for group in GROUPS:
                selectors = arguments(group)
                includes = [s.split(":", 1)[1] for s in selectors if s.startswith("-only-testing:")]
                excludes = [s.split(":", 1)[1] for s in selectors if s.startswith("-skip-testing:")]
                if any(test.startswith(p + "/") for p in includes) and not any(test.startswith(p + "/") for p in excludes):
                    owners.append(group)
            self.assertEqual(len(owners), 1, (test, owners))
        with self.assertRaises(ValueError):
            arguments("unknown")

    def test_current_scheme_is_fully_covered_and_new_targets_fail_closed(self):
        path = ROOT / "ios/Beid.xcodeproj/xcshareddata/xcschemes/Beid.xcscheme"
        verify_scheme(path)
        with tempfile.TemporaryDirectory() as directory:
            changed = Path(directory) / "scheme"
            changed.write_text(path.read_text().replace('BlueprintName = "BeidUITests"', 'BlueprintName = "NewTests"'))
            with self.assertRaises(ValueError):
                verify_scheme(changed)

    def test_summary_requires_nonzero_consistent_executed_passing_tests(self):
        self.assertEqual(counts(summary()), dict(total=4, passed=3, failed=0, skipped=1, expected_failures=0))
        invalid = [summary(result="Failed"), summary(totalTestCount=0),
                   summary(totalTestCount=True), summary(passedTests=3.0), summary(skippedTests=-1),
                   summary(passedTests=1), summary(passedTests=5), summary(passedTests=0, skippedTests=4),
                   summary(passedTests=2, failedTests=1), summary(result="Unknown"), {}]
        for value in invalid:
            with self.subTest(value=value), self.assertRaises(ValueError):
                counts(value)

    def test_aggregate_requires_each_group_from_the_current_commit(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            for group in GROUPS:
                (folder / (group + ".json")).write_text(json.dumps(dict(group=group, head="current", summary=summary())))
            self.assertEqual(aggregate(folder, "current")["total"], 12)
            with self.assertRaises(ValueError):
                aggregate(folder, "different")
            (folder / "unit.json").unlink()
            with self.assertRaises(ValueError):
                aggregate(folder, "current")
            (folder / "unit.json").write_text(json.dumps(dict(group="ipad", head="current", summary=summary())))
            with self.assertRaises(ValueError):
                aggregate(folder, "current")
