"""Compare a proposed screen-based selection with full hosted iOS UI results."""

import argparse
from collections import Counter
import json
from pathlib import Path

from scripts.ci_change_filter import classify
from scripts.ios_ui_smoke import (
    DEFAULT_DURATIONS, latest_evidence, result_case_nodes, source_tests, ui_shard_lanes, unique_tests,
)


VIEWS = {
    "AccountSheetView": ("FlatScreenshotTourD", "EventMembershipUITests", "SingleAppearanceUITests"),
    "OrganizerToolsView": ("FlatScreenshotTourD",),
    "ItemDetailView": ("FlatScreenshotTourC", "NearbyJoinUITests", "BeidIPadLayoutTests", "AdaptiveContinuityUITests"),
    "CollectionHomeView": ("FlatScreenshotTourB", "NearbyJoinUITests", "BeidIPadLayoutTests", "AdaptiveContinuityUITests"),
}
# These files contain reviewed test classes. Files with shared helpers, such as
# RecordingBindingSheetUITests.swift (SensingVisualOracle), stay full.
TEST_FILES = {name for files in VIEWS.values() for name in files} | {
    "FlatScreenshotTourA", "JoinRefusalUITests", "ClockPreflightUITests", "EventIdentityVerificationUITests",
}
MAX_EXTRA_SECONDS = 25 * 60


def propose(changes, manifest, weights):
    ui = set(unique_tests(manifest["ui"], "BeidUITests"))
    smoke = set(unique_tests(manifest["smoke"], "BeidUITests"))
    skips = set(manifest["iphone_skips"])
    if not (smoke | skips) <= ui:
        raise ValueError("stale smoke or skip identifiers")
    matched = smoke | skips
    paths = changes.get("files") if isinstance(changes, dict) else None
    reasons = []
    full = False
    files = set()
    if (not isinstance(paths, list) or not paths or not all(isinstance(path, str) for path in paths)
            or changes.get("ios_force_run", False) is not False or "error" in changes):
        reasons.append("missing or unsafe changed paths")
        full = True
    else:
        for path in sorted(set(paths)):
            item = Path(path)
            if not classify([path])["ios"]:
                continue
            if path == f"ios/Beid/Views/{item.stem}.swift" and item.stem in VIEWS:
                files.update(VIEWS[item.stem])
            elif path == f"ios/BeidUITests/{item.stem}.swift" and item.stem in TEST_FILES:
                files.add(item.stem)
            else:
                reasons.append(f"unmapped or shared input: {path}")
                full = True
    for file in sorted(files):
        suites = {test.split("/")[1] for test in source_tests(Path("ios/BeidUITests") / (file + ".swift"))}
        matches = {test for test in ui if test.split("/")[1] in suites}
        if not matches:
            reasons.append(f"no runtime test matches {file}")
            full = True
        else:
            reasons.append(f"{file}.swift: {', '.join(sorted(suites))}")
            matched.update(matches)
    if full:
        matched = ui
    extra = round(sum(weights.get(test, 20.0) for test in sorted(matched - smoke - skips)), 3)
    if extra > MAX_EXTRA_SECONDS:
        reasons.append("additional test time exceeds 25 minutes")
        full = True
    return {
        "mode": "full" if full else "selected",
        "reasons": reasons or ["smoke and environment skips"],
        "matched": sorted(matched),
        "extra_seconds": extra,
        "candidates": sorted(ui if full else matched),
    }


def observe(root, manifest, current_attempt, build_attempt, selection):
    latest = latest_evidence(root, current_attempt)
    failed = set()
    unexpected = {}
    skips = set(manifest["iphone_skips"])
    unavailable = set()
    shards = ui_shard_lanes(manifest["shards"])
    if Counter(test for tests in shards.values() for test in tests) != Counter(manifest["ui"]):
        raise ValueError("UI shard union has a gap or duplicate")
    for shard, expected in shards.items():
        entry = latest.get(shard)
        if not entry or entry[0] < build_attempt:
            unavailable.add(shard)
            continue
        folder = entry[1]
        try:
            local = json.loads((folder / "manifest.json").read_text())
            if local["sha"] != manifest["sha"] or local["shards"] != manifest["shards"]:
                raise ValueError("shard belongs to another build")
            cases = result_case_nodes(json.loads((folder / "test-tree.json").read_text()))
            if Counter(test for test, _, _ in cases) != Counter(expected):
                unavailable.add(shard)
            for test, result, _ in cases:
                if test not in expected:
                    continue
                if result == "Failed":
                    failed.add(test)
                if result != ("Skipped" if test in skips else "Passed"):
                    unexpected[test] = result
                if result not in ("Passed", "Failed", "Skipped"):
                    unavailable.add(shard)
        except (OSError, KeyError, ValueError, TypeError):
            unavailable.add(shard)
    return {
        **selection,
        "sha": manifest["sha"],
        "attempt": current_attempt,
        "build_attempt": build_attempt,
        "unexpected_results": unexpected,
        "observed_failed": sorted(failed),
        "failed_outside_matched": sorted(failed - set(selection["matched"])),
        "failed_outside_candidates": sorted(failed - set(selection["candidates"])),
        "unavailable_shards": sorted(unavailable),
        "complete_ui_evidence": not unavailable,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("--changes", required=True, type=Path)
    parser.add_argument("--attempt", required=True, type=int)
    parser.add_argument("--build-attempt", required=True, type=int)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--base-sha", required=True)
    args = parser.parse_args()
    if not 1 <= args.build_attempt <= args.attempt:
        raise ValueError("invalid build attempt")
    folder = args.evidence / f"ios-evidence-{args.build_attempt}-build"
    manifest = json.loads((folder / "manifest.json").read_text())
    if manifest["sha"] != args.sha or manifest["mode"] != "full":
        raise ValueError("expected a full build on the requested head")
    try:
        changes = json.loads(args.changes.read_text())
    except (ValueError, OSError):
        changes = {}
    selection = propose(changes, manifest, json.loads(DEFAULT_DURATIONS.read_text())["seconds"])
    report = observe(args.evidence, manifest, args.attempt, args.build_attempt, selection)
    report["base_sha"] = args.base_sha or None
    report["changed_paths"] = changes.get("files") if isinstance(changes, dict) else None
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
