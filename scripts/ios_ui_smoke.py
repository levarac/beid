#!/usr/bin/env python3
"""Select UI smoke tests and require their executed xcresult evidence."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import re
import sys

from scripts.run_local_tests import parse_xcresult_tests


IDENTIFIER = re.compile(r"BeidUITests/[A-Za-z_]\w*/test\w+")
DEFAULT_LIST = Path("ios/ci/ui-smoke-tests.txt")


def compute_mode(event_name: str, payload: object) -> str:
    """Only a well-formed, unlabeled PR payload can reduce UI coverage."""
    if event_name != "pull_request" or not isinstance(payload, dict):
        return "full"
    pr = payload.get("pull_request")
    labels = pr.get("labels") if isinstance(pr, dict) else None
    if not isinstance(labels, list) or any(
        not isinstance(label, dict) or not isinstance(label.get("name"), str)
        for label in labels
    ):
        return "full"
    return "full" if any(label["name"] == "ci:full-ui" for label in labels) else "smoke"


def parse_smoke_list(text: str) -> list[str]:
    tests = []
    for number, line in enumerate(text.splitlines(), 1):
        identifier = line.partition("#")[0].strip()
        if not identifier:
            continue
        if not IDENTIFIER.fullmatch(identifier):
            raise ValueError(f"invalid smoke identifier on line {number}: {identifier!r}")
        if identifier in tests:
            raise ValueError(f"duplicate smoke identifier on line {number}: {identifier}")
        tests.append(identifier)
    if not tests:
        raise ValueError("smoke list is empty")
    return tests


def selection_arguments(mode: str, tests: list[str]) -> list[str]:
    if mode not in {"smoke", "full"}:
        raise ValueError(f"invalid test mode: {mode!r}")
    parse_smoke_list("\n".join(tests))
    return (["-only-testing:BeidTests"] + [f"-only-testing:{test}" for test in tests]
            if mode == "smoke" else [])


def validate_sources(tests: list[str], source_root: Path) -> None:
    """Bind each method to its Swift class, ignoring comments and string literals."""
    available = set()
    tokens = re.compile(r'//[^\n]*|/\*.*?\*/|""".*?"""|"(?:\\.|[^"\\])*"', re.S)
    for path in source_root.rglob("*.swift"):
        text = tokens.sub("", path.read_text(encoding="utf-8"))
        for match in re.finditer(r"\b(?:class|extension)\s+(\w+)[^{]*\{", text):
            start = match.end()
            depth, end = 1, start
            while depth and end < len(text):
                depth += (text[end] == "{") - (text[end] == "}")
                end += 1
            for method in re.findall(r"\bfunc\s+(test\w+)\s*\(", text[start:end - 1]):
                available.add(f"BeidUITests/{match[1]}/{method}")
    missing = set(tests) - available
    if missing:
        raise ValueError(f"smoke methods missing from UI sources: {sorted(missing)}")


def case_duration(node: dict) -> float:
    if "durationInSeconds" in node:
        value = node["durationInSeconds"]
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ValueError("xcresult case durationInSeconds must be numeric")
        if not math.isfinite(value) or value < 0:
            raise ValueError("xcresult case duration must be finite and nonnegative")
        return float(value)
    # Xcode's human-readable field also occurs on older result bundles.
    value = node.get("duration", "")
    if not isinstance(value, str) or not re.fullmatch(
        r"\s*(?:\d+(?:\.\d+)?\s*[dhms]\s*)+", value
    ):
        raise ValueError("xcresult case duration is missing or unrecognized")
    scale = {"d": 86400, "h": 3600, "m": 60, "s": 1}
    seconds = sum(float(amount) * scale[unit]
                  for amount, unit in re.findall(r"(\d+(?:\.\d+)?)\s*([dhms])", value))
    if not math.isfinite(seconds):
        raise ValueError("xcresult case duration must be finite")
    return seconds


def validate_results(mode: str, tests: list[str], payload: object):
    selection_arguments(mode, tests)
    counts = parse_xcresult_tests(payload)
    for bundle in ("BeidTests", "BeidUITests"):
        if bundle not in counts.bundles or counts.bundles[bundle].total <= 0:
            raise ValueError(f"xcresult contains no {bundle} cases")
    durations = {"BeidTests": 0.0, "BeidUITests": 0.0}
    ui = {}

    def walk(node, bundle=None, suite=None):
        if isinstance(node, list):
            for child in node:
                walk(child, bundle, suite)
            return
        if not isinstance(node, dict):
            return
        kind = str(node.get("nodeType", node.get("type", ""))).lower()
        if "bundle" in kind:
            bundle, suite = node.get("name"), None
        if kind == "test suite":
            suite = str(node.get("name", "")).removeprefix("BeidUITests.")
        if kind == "test case" and bundle in durations:
            durations[bundle] += case_duration(node)
            if bundle == "BeidUITests":
                identifier = node.get("nodeIdentifier") or f"{suite}/{node.get('name', '')}"
                identifier = str(identifier).removesuffix("()")
                if not identifier.startswith("BeidUITests/"):
                    identifier = f"BeidUITests/{identifier}"
                if not IDENTIFIER.fullmatch(identifier):
                    raise ValueError(f"unrecognized UI case identifier: {identifier!r}")
                if identifier in ui:
                    raise ValueError(f"duplicate xcresult UI case: {identifier}")
                ui[identifier] = node.get("result", node.get("testStatus"))
        for key in ("children", "testNodes", "subtests"):
            if key in node:
                walk(node[key], bundle, suite)

    walk(payload)
    missing = set(tests) - ui.keys()
    extra = ui.keys() - set(tests) if mode == "smoke" else set()
    if missing or extra:
        raise ValueError(f"UI execution mismatch: missing={sorted(missing)}, extra={sorted(extra)}")
    nonpassing = {test: ui[test] for test in tests if ui[test] != "Passed"}
    if nonpassing:
        raise ValueError(f"listed UI tests did not pass (skips fail): {nonpassing}")
    return counts, durations


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    mode = sub.add_parser("mode")
    mode.add_argument("--event-name", required=True)
    mode.add_argument("--event-path", type=Path, required=True)
    for command in ("arguments", "verify"):
        child = sub.add_parser(command)
        child.add_argument("--mode", required=True)
        child.add_argument("--list", type=Path, default=DEFAULT_LIST)
        if command == "verify":
            child.add_argument("--tests-json", type=Path, required=True)
            child.add_argument("--summary", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == "mode":
            # A corrupt/missing event is never evidence for reducing coverage.
            try:
                payload = json.loads(args.event_path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                payload = None
            print(f"mode={compute_mode(args.event_name, payload)}")
            return 0
        tests = parse_smoke_list(args.list.read_text(encoding="utf-8"))
        if args.command == "arguments":
            for argument in selection_arguments(args.mode, tests):
                print(argument)
            return 0
        with args.summary.open("a", encoding="utf-8") as output:
            output.write(f"\n### UI execution evidence\n\nMode: **{args.mode}**; listed UI cases: {len(tests)}.\n\n")
            try:
                counts, durations = validate_results(args.mode, tests, json.loads(
                    args.tests_json.read_text(encoding="utf-8")))
            except (OSError, ValueError) as error:
                output.write("UI execution or duration verification failed; this is not passing evidence.\n")
                raise ValueError(str(error)) from error
            output.write("Durations: sum of xcresult Test Case nodes, excluding suite totals; not wall time.\n\n")
            output.write("| Bundle | Cases | Passed | Failed | Skipped | Duration (s) |\n")
            output.write("| --- | ---: | ---: | ---: | ---: | ---: |\n")
            for bundle, seconds in durations.items():
                count = counts.bundles[bundle]
                line = f"| {bundle} | {count.total} | {count.passed} | {count.failed} | {count.skipped} | {seconds:.3f} |\n"
                output.write(line)
                print(line.strip())
        return 0
    except (OSError, ValueError) as error:
        print(f"iOS UI evidence failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
