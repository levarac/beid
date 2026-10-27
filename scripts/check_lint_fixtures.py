#!/usr/bin/env python3
"""Prove custom SwiftLint rules fire only on the fail fixture's marked lines."""

from collections import Counter
import json
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]


def check_fixtures(root: Path) -> int:
    root = root.resolve()
    fail_source = root / "lint-fixtures/LintFixtures_fail.swift.txt"
    expected = Counter()
    for line, text in enumerate(fail_source.read_text().splitlines(), 1):
        marker = re.search(r"// FAIL (\w+)\b", text)
        if marker:
            expected[(line, marker[1])] += 1
    if not expected:
        raise ValueError("fail fixture must contain // FAIL <rule> markers")

    created = []
    try:
        for source, destination in (
            (root / "lint-fixtures/LintFixtures_pass.swift", root / "ios/Beid/LintFixtures_pass.swift"),
            (fail_source, root / "ios/Beid/LintFixtures_fail.swift"),
        ):
            # Exclusive creation preserves any pre-existing developer file.
            with destination.open("x") as output:
                created.append(destination)
                output.write(source.read_text())
        result = subprocess.run(
            [str(root / "scripts/lint.sh"), "--reporter", "json"],
            cwd=root, text=True, capture_output=True, timeout=120,
        )
        # Error-severity violations in the fail fixture MUST make lint exit 2.
        # Exit 0 is a dead-rule failure, not successful proof of a clean app.
        if result.returncode != 2:
            raise ValueError(f"SwiftLint must exit 2 for the fail fixture; got {result.returncode}: "
                             + result.stderr.strip())
        try:
            report = json.loads(result.stdout)
        except ValueError as error:
            raise ValueError("SwiftLint did not return a JSON violation report") from error
        if not isinstance(report, list):
            raise ValueError("SwiftLint violation report must be a list")
        actual = Counter()
        fail_file = root / "ios/Beid/LintFixtures_fail.swift"
        for violation in report:
            if (not isinstance(violation, dict)
                    or not isinstance(violation.get("file"), str)
                    or type(violation.get("line")) is not int
                    or not isinstance(violation.get("rule_id"), str)):
                raise ValueError("malformed SwiftLint violation")
            path = (root / violation["file"]).resolve()
            if path != fail_file:
                raise ValueError(f"violation outside the fail fixture: {path}")
            actual[(violation["line"], violation["rule_id"])] += 1
        if actual != expected:
            raise ValueError(f"fixture violations differ: missing {dict(expected - actual)}, "
                             f"unexpected {dict(actual - expected)}")
        return sum(expected.values())
    finally:
        for path in created:
            path.unlink()


def main() -> int:
    try:
        count = check_fixtures(ROOT)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(f"OK: {count} expected violations in fail fixture; 0 in pass fixture or other files; "
          "SwiftLint exit 2 (expected).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
