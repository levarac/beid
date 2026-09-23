#!/usr/bin/env python3
"""Classify changed paths for the PR CI job gates.

Input is a JSON object with a ``files`` array.  The classifier is deliberately
conservative: unknown non-documentation paths enable every expensive check.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys
from typing import Iterable


def _is_documentation(path: str) -> bool:
    normalized = path[2:] if path.startswith("./") else path
    return (
        normalized.startswith("docs/")
        or normalized.endswith(".md")
        or normalized.endswith(".mdx")
    )


# The macOS lab CLI (beid#588). It is a standalone SwiftPM package that no
# app target links, so a change inside it cannot affect the Android build or
# the iOS lint lane -- but it does need its own macOS build-and-test job,
# which `pr-ci-lab-cli.yml` provides.
LAB_CLI_PREFIX = "tools/beid-lab-cli/"


def _is_lab_cli(path: str) -> bool:
    normalized = path[2:] if path.startswith("./") else path
    return normalized.startswith(LAB_CLI_PREFIX)


def _is_force_all(path: str) -> bool:
    normalized = path[2:] if path.startswith("./") else path
    # Exempted ahead of the basename rules below, which would otherwise catch
    # this package's own `Package.resolved` and run every expensive lane for a
    # pin that only this tool consumes. The pin is still checked on every PR --
    # `scripts/check_lab_cli_barnard_pin.py` runs in the always-on sanity job,
    # which is the check that actually matters for it.
    if _is_lab_cli(normalized):
        return False
    basename = pathlib.PurePosixPath(normalized).name
    return (
        normalized.startswith(".github/workflows/")
        or normalized.startswith("scripts/")
        or normalized.startswith("gradle/")
        or basename in {
            "build.gradle",
            "build.gradle.kts",
            "settings.gradle",
            "settings.gradle.kts",
            "gradle.properties",
            "gradle.lockfile",
            "libs.versions.toml",
            "Package.resolved",
            "project.yml",
            ".swiftlint.yml",
        }
    )


def classify(files: Iterable[str]) -> dict[str, bool]:
    paths = sorted({path[2:] if path.startswith("./") else path for path in files if path})
    if not paths:
        return {"android": True, "lint": True, "labcli": True, "sanity": True, "error": True}

    if any(_is_force_all(path) for path in paths):
        return {"android": True, "lint": True, "labcli": True, "sanity": True, "error": False}

    non_docs = [path for path in paths if not _is_documentation(path)]
    if not non_docs:
        # Repository sanity remains required because it validates repository
        # control documents; the expensive build/lint lanes can be skipped.
        return {"android": False, "lint": False, "labcli": False, "sanity": True, "error": False}

    android = False
    lint = False
    labcli = False
    for path in non_docs:
        if _is_lab_cli(path):
            labcli = True
        elif path.startswith("android/"):
            android = True
        elif path.startswith("ios/"):
            lint = True
        elif path.startswith("shared/"):
            android = True
            lint = True
        else:
            # Unknown product/source paths fail closed.
            return {"android": True, "lint": True, "labcli": True, "sanity": True, "error": True}

    return {"android": android, "lint": lint, "labcli": labcli, "sanity": True, "error": False}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=pathlib.Path)
    args = parser.parse_args()

    try:
        payload = json.loads(args.input.read_text(encoding="utf-8"))
        files = payload["files"]
        if not isinstance(files, list) or not all(isinstance(path, str) for path in files):
            raise ValueError("files must be a list of strings")
        result = classify(files)
    except Exception as error:  # fail closed if the detector input is unavailable/corrupt
        print(f"warning: CI change classification failed: {error}", file=sys.stderr)
        result = {"android": True, "lint": True, "sanity": True, "error": True}

    for key, value in result.items():
        print(f"{key}={str(value).lower()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
