#!/usr/bin/env python3
"""Fail if `tools/beid-lab-cli` and the iOS app pin different Barnard versions.

The CLI is a measuring instrument for the app. Its whole value is that the
radio behaviour it records is the radio behaviour the app ships, so a run that
measured a different SDK produces numbers nobody can use -- and would produce
them silently, looking exactly like a good run.

The pin lives in two files that nothing else ties together: `ios/project.yml`
declares `exactVersion` for XcodeGen, and `tools/beid-lab-cli/Package.swift`
declares `exact:` for SwiftPM. Bumping one is a one-line change that leaves
the other untouched with no build error anywhere, which is exactly the shape
of drift a person does not notice.

This also checks the CLI's `Package.resolved`, so the assertion is about what
SwiftPM actually resolved rather than only about what was asked for.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

PROJECT_YML = "ios/project.yml"
CLI_PACKAGE = "tools/beid-lab-cli/Package.swift"
CLI_RESOLVED = "tools/beid-lab-cli/Package.resolved"

# `  Barnard:` ... `    exactVersion: 0.9.2` -- read as a pair so a version
# under some other package cannot be mistaken for Barnard's.
PROJECT_PIN = re.compile(
    r"^\s*Barnard:\s*$.*?^\s*exactVersion:\s*\"?([0-9][^\s\"]*)\"?\s*$",
    re.MULTILINE | re.DOTALL,
)
PACKAGE_PIN = re.compile(
    r"""\.package\(\s*url:\s*"[^"]*barnard[^"]*"\s*,\s*exact:\s*"([^"]+)"\s*\)""",
    re.IGNORECASE,
)


def project_pin(root: Path) -> str:
    text = (root / PROJECT_YML).read_text(encoding="utf-8")
    match = PROJECT_PIN.search(text)
    if not match:
        raise SystemExit(f"error: no Barnard exactVersion found in {PROJECT_YML}")
    return match.group(1)


def cli_pin(root: Path) -> str:
    text = (root / CLI_PACKAGE).read_text(encoding="utf-8")
    match = PACKAGE_PIN.search(text)
    if not match:
        raise SystemExit(
            f"error: no `.package(url: ..., exact: ...)` for barnard in {CLI_PACKAGE}. "
            "A range or a branch would let the tool drift from the app between builds."
        )
    return match.group(1)


def cli_resolved(root: Path) -> tuple[str, str]:
    path = root / CLI_RESOLVED
    if not path.exists():
        raise SystemExit(
            f"error: {CLI_RESOLVED} is missing. It is tracked on purpose: it is the "
            "evidence of which revision the tool actually resolved, not merely asked for."
        )
    document = json.loads(path.read_text(encoding="utf-8"))
    for pin in document.get("pins", []):
        if pin.get("identity") == "barnard":
            state = pin.get("state", {})
            return state.get("version", ""), state.get("revision", "")
    raise SystemExit(f"error: no barnard pin in {CLI_RESOLVED}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=str(REPO_ROOT))
    args = parser.parse_args()
    root = Path(args.root)

    app = project_pin(root)
    cli = cli_pin(root)
    resolved_version, resolved_revision = cli_resolved(root)

    failures = []
    if app != cli:
        failures.append(
            f"{PROJECT_YML} pins Barnard {app} but {CLI_PACKAGE} pins {cli}. "
            "Bump both, or the CLI measures an SDK the app does not ship."
        )
    if resolved_version != cli:
        failures.append(
            f"{CLI_PACKAGE} asks for {cli} but {CLI_RESOLVED} records {resolved_version}. "
            "Run `swift package resolve` in tools/beid-lab-cli and commit the result."
        )

    if failures:
        print("error: Barnard pin drift between the app and the lab CLI.", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        return 1

    print(f"ok: app and lab CLI both pin Barnard {app}, resolved at {resolved_revision}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
