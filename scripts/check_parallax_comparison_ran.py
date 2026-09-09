#!/usr/bin/env python3
"""Fail unless the Parallax cross-repo comparison actually executed.

beid#415 wires levarac/parallax into PR CI so the vendored-resource byte comparison in
ParallaxEventDefinitionSourceChecksumTest stops depending on someone remembering to set
PARALLAX_REPO at their desk. Wiring it is not the same as running it: the comparison
skips itself (JUnit reports an AssumptionViolatedException as a skipped testcase) when it
cannot find a checkout, and a skipped test is indistinguishable from a passing one in the
job's exit code. That is the exact failure this issue exists to remove, so a run that
believes it cloned Parallax must prove the comparison ran rather than assume it.

Run this only on jobs where the checkout was actually produced. With no checkout the
comparison is *expected* to skip and the clone step says so loudly instead.
"""
import argparse
import sys
import xml.etree.ElementTree as ElementTree
from pathlib import Path

DEFAULT_RESULTS_DIR = Path("shared/build/test-results/testAndroidHostTest")
TEST_CLASS = "org.levarac.parallax.registry.ParallaxEventDefinitionSourceChecksumTest"
TEST_NAME = "copiedVectorsAndCddlMatchTheParallaxCheckoutWhenAvailable"


def result_file(results_dir):
    return results_dir / f"TEST-{TEST_CLASS}.xml"


def check(results_dir):
    """Return a list of failure messages; empty means the comparison ran and was not skipped."""
    path = result_file(results_dir)
    if not path.is_file():
        return [
            f"No JUnit result file at {path}. The Parallax comparison cannot have run. "
            f"Either {TEST_CLASS} did not execute at all, or the results directory is wrong."
        ]

    try:
        root = ElementTree.parse(path).getroot()
    except ElementTree.ParseError as error:
        return [f"{path} is not parseable XML ({error}); refusing to read it as evidence."]

    cases = [case for case in root.iter("testcase") if case.get("name") == TEST_NAME]
    if not cases:
        names = sorted(case.get("name") or "<unnamed>" for case in root.iter("testcase"))
        return [
            f"{path} has no testcase named '{TEST_NAME}'. Present: {', '.join(names) or '(none)'}. "
            "The comparison did not run."
        ]

    failures = []
    for case in cases:
        skipped = case.find("skipped")
        if skipped is not None:
            reason = (skipped.get("message") or skipped.text or "").strip() or "(no reason given)"
            failures.append(
                f"'{TEST_NAME}' was SKIPPED even though a Parallax checkout was supposed to be "
                f"present. Reason: {reason}. A skipped comparison is not a passing comparison."
            )
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--results-dir",
        type=Path,
        default=DEFAULT_RESULTS_DIR,
        help=f"JUnit XML directory (default: {DEFAULT_RESULTS_DIR})",
    )
    args = parser.parse_args()

    failures = check(args.results_dir)
    if failures:
        print("Parallax comparison evidence check failed:\n", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1

    print(f"OK: '{TEST_NAME}' ran and was not skipped ({result_file(args.results_dir)}).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
