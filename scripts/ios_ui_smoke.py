#!/usr/bin/env python3
"""Select UI smoke tests and require their executed xcresult evidence."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import re
import sys
from collections import Counter

from scripts.run_local_tests import parse_xcresult_tests, validate_xcresult_summary


IDENTIFIER = re.compile(r"BeidUITests/[A-Za-z_]\w*/test\w+")
DEFAULT_LIST = Path("ios/ci/ui-smoke-tests.txt")
DEFAULT_DURATIONS = Path("scripts/ios-ui-durations.json")
IPHONE_SKIPS = Path("scripts/ios-ui-iphone-skips.txt")


def unique_tests(tests, bundle):
    if not isinstance(tests, list) or not tests:
        raise ValueError(f"empty or malformed {bundle} enumeration")
    pattern = re.compile(rf"{bundle}/[A-Za-z_]\w*/test\w+")
    if any(not isinstance(test, str) or not pattern.fullmatch(test) for test in tests):
        raise ValueError(f"invalid {bundle} identifier")
    if len(set(tests)) != len(tests):
        raise ValueError(f"duplicate {bundle} identifier")
    return sorted(tests)


def parse_enumeration(payload):
    """Read xcodebuild -enumerate-tests' hierarchical JSON (not source counts)."""
    if not isinstance(payload, dict) or payload.get("errors") or not payload.get("values"):
        raise ValueError("invalid or failed Xcode test enumeration")
    tests = {"BeidTests": [], "BeidUITests": []}

    def walk(nodes, bundle=None, suite=None):
        if not isinstance(nodes, list):
            raise ValueError("malformed enumeration children")
        for node in nodes:
            if not isinstance(node, dict) or not isinstance(node.get("name"), str):
                raise ValueError("malformed enumeration node")
            name = node["name"]
            if name in tests:
                walk(node.get("children", []), name)
            elif bundle and suite is None:
                walk(node.get("children", []), bundle, name.removeprefix(bundle + "."))
            elif bundle:
                if node.get("children"):
                    raise ValueError("unexpected nested test enumeration")
                tests[bundle].append(f"{bundle}/{suite}/{name.removesuffix('()')}")
            else:
                walk(node.get("children", []))

    walk(payload["values"])
    return {bundle: unique_tests(items, bundle) for bundle, items in tests.items()}


def shard_tests(tests, durations, count):
    """Longest-first scheduling, with identifier and shard index as tie breakers."""
    tests = unique_tests(tests, "BeidUITests")
    if isinstance(count, bool) or count not in (2, 3):
        raise ValueError("UI shard count must be 2 or 3 (at most four test jobs)")
    weights = {}
    for test in tests:
        # New methods always get a positive weight and exactly one assignment.
        value = durations.get(test, 20.0)
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value <= 0:
            raise ValueError(f"invalid test duration: {test}")
        weights[test] = value
    shards, loads = [[] for _ in range(count)], [0.0] * count
    for test in sorted(tests, key=lambda test: (-weights[test], test)):
        index = min(range(count), key=lambda index: (loads[index], index))
        shards[index].append(test)
        loads[index] += weights[test]
    if any(not shard for shard in shards):
        raise ValueError("empty UI shard")
    return [sorted(shard) for shard in shards]


def result_cases(payload):
    """Normalize case identifiers; retain duplicates so the ledger can reject them."""
    cases = []

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
        if kind == "test suite" and bundle:
            suite = str(node.get("name", "")).removeprefix(bundle + ".")
        if kind == "test case":
            if bundle not in ("BeidTests", "BeidUITests"):
                raise ValueError(f"unexpected test bundle: {bundle}")
            identifier = str(node.get("nodeIdentifier") or f"{suite}/{node.get('name', '')}").removesuffix("()")
            if not identifier.startswith(bundle + "/"):
                identifier = f"{bundle}/{identifier}"
            unique_tests([identifier], bundle)
            cases.append((identifier, node.get("result", node.get("testStatus")), case_duration(node)))
        for key in ("children", "testNodes", "subtests"):
            if key in node:
                walk(node[key], bundle, suite)

    walk(payload)
    return cases


def validate_lane(expected, payload, allowed_skips=()):
    cases = result_cases(payload)
    identifiers = [case[0] for case in cases]
    if Counter(identifiers) != Counter(expected):
        raise ValueError(f"execution ledger mismatch: missing={sorted((Counter(expected) - Counter(identifiers)).elements())}, "
                         f"extra/duplicate={sorted((Counter(identifiers) - Counter(expected)).elements())}")
    for identifier, result, _ in cases:
        if result != "Passed" and not (result == "Skipped" and identifier in allowed_skips):
            raise ValueError(f"test did not pass: {identifier}: {result}")
    return cases


def classifier_skip(event, needs):
    changes = needs.get("changes", {})
    outputs = changes.get("outputs", {})
    return (event == "pull_request" and changes.get("result") == "success"
            and outputs.get("ios") == "false" and outputs.get("error") == "false")


def validate_aggregate(event, needs, manifest, evidence, sha):
    if needs.get("plan", {}).get("result") != "success":
        raise ValueError("test plan did not succeed")
    plan = needs["plan"].get("outputs", {})
    if classifier_skip(event, needs):
        if plan.get("run") != "false" or any(needs.get(job, {}).get("result") != "skipped"
                                               for job in ("build", "tests")):
            raise ValueError("classifier skip has inconsistent job results")
        return "Classifier skip: no iOS-affecting changes."
    mode = plan.get("mode")
    if plan.get("run") != "true" or mode not in ("full", "smoke"):
        raise ValueError("missing or invalid test plan")
    for job in ("build", "tests") if mode == "full" else ("build",):
        if needs.get(job, {}).get("result") != "success":
            raise ValueError(f"needed job did not succeed: {job}")
    if mode == "smoke" and needs.get("tests", {}).get("result") != "skipped":
        raise ValueError("smoke must execute in one macOS job")
    if not isinstance(manifest, dict) or manifest.get("sha") != sha or manifest.get("mode") != mode:
        raise ValueError("manifest head or mode mismatch")
    unit = unique_tests(manifest.get("unit"), "BeidTests")
    ui = unique_tests(manifest.get("ui"), "BeidUITests")
    skips = manifest.get("iphone_skips", [])
    if not isinstance(skips, list) or len(set(skips)) != len(skips) or not set(skips) <= set(ui):
        raise ValueError("invalid explicit iPhone skip list")
    if mode == "smoke":
        lanes = {"build": unit + manifest["smoke"]}
    else:
        shards = manifest.get("shards", [])
        if not isinstance(shards, list) or len(shards) not in (2, 3) or any(not shard for shard in shards):
            raise ValueError("missing UI shards")
        if Counter(test for shard in shards for test in shard) != Counter(ui):
            raise ValueError("UI shard union has a gap or duplicate")
        lanes = {"unit": unit, **{f"ui-{index + 1}": shard for index, shard in enumerate(shards)}}
    if evidence.keys() != lanes.keys():
        raise ValueError(f"missing or extra lane artifacts: expected={sorted(lanes)}, actual={sorted(evidence)}")
    all_cases = []
    for lane, expected in lanes.items():
        all_cases.extend(validate_lane(expected, evidence[lane], skips))
    executed = [identifier for identifier, result, _ in all_cases if result == "Passed"]
    if mode == "full" and set(executed) - set(unit) != set(ui) - {
        identifier for identifier, result, _ in all_cases if result == "Skipped" and identifier in skips
    }:
        raise ValueError("executed iPhone UI union mismatch")
    return f"{mode}: all {len(all_cases)} cases accounted for; all {len(unit)} BeidTests passed."


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


def source_tests(source_root: Path, bundle="BeidUITests") -> list[str]:
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
                available.add(f"{bundle}/{match[1]}/{method}")
    return sorted(available)


def validate_sources(tests: list[str], source_root: Path) -> None:
    available = set(source_tests(source_root))
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
    shards = sub.add_parser("shards", help="enumerate and balance the complete UI suite")
    shards.add_argument("--enumeration", type=Path, required=True)
    shards.add_argument("--output", type=Path, required=True)
    shards.add_argument("--count", type=int, required=True)
    shards.add_argument("--mode", choices=("full", "smoke"), required=True)
    shards.add_argument("--sha", required=True)
    shards.add_argument("--durations", type=Path, default=DEFAULT_DURATIONS)
    for command in ("lane-arguments", "verify-lane"):
        child = sub.add_parser(command)
        child.add_argument("--manifest", type=Path, required=True)
        child.add_argument("--lane", required=True)
        if command == "verify-lane":
            child.add_argument("--tests-json", type=Path, required=True)
            child.add_argument("--summary-json", type=Path, required=True)
            child.add_argument("--summary", type=Path, required=True)
    aggregate = sub.add_parser("aggregate")
    aggregate.add_argument("--event-name", required=True)
    aggregate.add_argument("--needs-json", type=Path, required=True)
    aggregate.add_argument("--evidence-root", type=Path, required=True)
    aggregate.add_argument("--attempt", required=True)
    aggregate.add_argument("--sha", required=True)
    aggregate.add_argument("--summary", type=Path, required=True)
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
        if args.command == "shards":
            enumerated = parse_enumeration(json.loads(args.enumeration.read_text()))
            if set(enumerated["BeidUITests"]) != set(source_tests(Path("ios/BeidUITests"))):
                raise ValueError("runtime UI enumeration differs from Swift source inventory")
            skips = parse_smoke_list(IPHONE_SKIPS.read_text())
            if not set(skips) <= set(enumerated["BeidUITests"]):
                raise ValueError("stale iPhone skip list")
            smoke = parse_smoke_list(DEFAULT_LIST.read_text())
            validate_sources(smoke, Path("ios/BeidUITests"))
            duration_data = json.loads(args.durations.read_text())
            manifest = {"sha": args.sha, "mode": args.mode,
                        "unit": enumerated["BeidTests"], "ui": enumerated["BeidUITests"],
                        "iphone_skips": skips, "smoke": smoke,
                        "shards": shard_tests(enumerated["BeidUITests"], duration_data["seconds"], args.count)}
            args.output.write_text(json.dumps(manifest, indent=2) + "\n")
            return 0
        if args.command in ("lane-arguments", "verify-lane"):
            manifest = json.loads(args.manifest.read_text())
            if args.lane == "build" and manifest["mode"] == "smoke":
                selected = manifest["unit"] + manifest["smoke"]
                arguments = selection_arguments("smoke", manifest["smoke"])
            elif args.lane == "unit" and manifest["mode"] == "full":
                selected, arguments = manifest["unit"], ["-only-testing:BeidTests"]
            elif re.fullmatch(r"ui-[1-3]", args.lane) and manifest["mode"] == "full":
                selected = manifest["shards"][int(args.lane[-1]) - 1]
                arguments = [f"-only-testing:{test}" for test in selected]
            else:
                raise ValueError(f"invalid lane: {args.lane}")
            if args.command == "lane-arguments":
                print("\n".join(arguments))
                return 0
            payload = json.loads(args.tests_json.read_text())
            cases = validate_lane(selected, payload, manifest["iphone_skips"])
            summary = json.loads(args.summary_json.read_text())
            warnings = validate_xcresult_summary(summary, parse_xcresult_tests(payload))
            if warnings or summary.get("result") != "Passed":
                raise ValueError(f"invalid or failing result summary: {warnings}")
            with args.summary.open("a", encoding="utf-8") as output:
                output.write(f"\n### {args.lane} execution evidence\n\n")
                output.write("Durations sum Test Case nodes, excluding suite totals; not wall time.\n\n")
                for bundle in ("BeidTests", "BeidUITests"):
                    items = [item for item in cases if item[0].startswith(bundle + "/")]
                    if items:
                        output.write(f"{bundle}: {len(items)} cases; {sum(item[2] for item in items):.3f} s.\n\n")
            return 0
        if args.command == "aggregate":
            needs = json.loads(args.needs_json.read_text())
            evidence, manifest = {}, None
            prefix = f"ios-evidence-{args.attempt}-"
            for folder in args.evidence_root.iterdir():
                if not folder.is_dir() or not folder.name.startswith(prefix):
                    raise ValueError(f"unexpected evidence entry: {folder.name}")
                lane = folder.name.removeprefix(prefix)
                if lane == "build":
                    manifest = json.loads((folder / "manifest.json").read_text())
                if (folder / "test-tree.json").exists():
                    evidence[lane] = json.loads((folder / "test-tree.json").read_text())
            message = validate_aggregate(args.event_name, needs, manifest, evidence, args.sha)
            print(message)
            with args.summary.open("a", encoding="utf-8") as output:
                output.write(f"\n### iOS simulator aggregate\n\n{message}\n")
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
    except (OSError, ValueError, KeyError, IndexError, TypeError) as error:
        print(f"iOS UI evidence failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
