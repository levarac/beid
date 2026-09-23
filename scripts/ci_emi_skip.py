#!/usr/bin/env python3
"""Skip emi only for the repository-only CI contract change set.

The Linux change-detection job fails if its input is unavailable.  A failed
change-detection job must never schedule a macOS job to compensate for missing
evidence; the PR remains red until classification succeeds.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import sys


APPROVED_FILES = frozenset(
    {
        ".github/workflows/pr-ci.yml",
        "AGENTS.md",
        "docs/delivery-ci.md",
        "scripts/check_pr_ci_doc_drift.py",
        "scripts/ci_emi_skip.py",
        "scripts/tests/fixtures/pr_ci_doc_drift_agents.md",
        "scripts/tests/fixtures/pr_ci_doc_drift_workflow.yml",
        "scripts/tests/test_check_pr_ci_doc_drift.py",
        "scripts/tests/test_ci_emi_skip.py",
    }
)
APPROVED_WORKFLOW_SHA256 = "82d309dbb31e4abafcd6bbab1dde37ca47d2f1c728b1b5066d94dc3097ee8ad9"
WORKFLOW_PATH = pathlib.Path(__file__).resolve().parents[1] / ".github/workflows/pr-ci.yml"


def should_skip_emi(files: list[str], workflow_path: pathlib.Path = WORKFLOW_PATH) -> bool:
    paths = set(files)
    return (
        paths == APPROVED_FILES
        and len(files) == len(APPROVED_FILES)
        and hashlib.sha256(workflow_path.read_bytes()).hexdigest() == APPROVED_WORKFLOW_SHA256
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=pathlib.Path)
    args = parser.parse_args()

    try:
        payload = json.loads(args.input.read_text(encoding="utf-8"))
        files = payload["files"]
        if not isinstance(files, list) or not files or not all(
            isinstance(path, str) and path for path in files
        ):
            raise ValueError("files must be a non-empty list of paths")
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"error: cannot determine emi skip scope: {error}", file=sys.stderr)
        return 1

    try:
        skip = should_skip_emi(files)
    except OSError as error:
        print(f"error: cannot verify approved workflow content: {error}", file=sys.stderr)
        return 1

    print(f"emi_skip={str(skip).lower()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
