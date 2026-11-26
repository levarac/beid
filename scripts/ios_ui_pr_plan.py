"""Plan the macOS test jobs for one event before provisioning a runner."""

import json
import os
from pathlib import Path

from scripts.ios_ui_selection_shadow import propose
from scripts.ios_ui_smoke import (
    DEFAULT_DURATIONS, DEFAULT_LIST, IPHONE_SKIPS, UI_SHARD_COUNTS, classifier_skip,
    parse_smoke_list, shard_tests, source_tests,
)

TARGET_SECONDS = 20 * 60


def execution_plan(initial, event, payload, changes, max_count, weights=None):
    if initial not in ("smoke", "full") or max_count not in UI_SHARD_COUNTS:
        raise ValueError("invalid initial mode or full shard count")
    full = {"mode": "full", "matrix": {"lane": ["unit", *(f"ui-{i}" for i in range(1, max_count + 1))]}}
    smoke = {"mode": "smoke", "matrix": {"lane": []}}
    if initial == "full" or event != "pull_request":
        return full
    pr = payload.get("pull_request", {})
    base = pr.get("base", {}).get("ref")
    if not isinstance(base, str) or not base:
        return full
    if not base.startswith("release/"):
        return smoke
    head = pr.get("head", {}).get("ref")
    if not isinstance(head, str) or not head or head.startswith(("ship/", "release/")) or pr.get("title", "").lower().startswith("ship "):
        return full
    if weights is None:
        weights = json.loads(DEFAULT_DURATIONS.read_text())["seconds"]
    inventory = {
        "ui": source_tests(Path("ios/BeidUITests")),
        "smoke": parse_smoke_list(DEFAULT_LIST.read_text()),
        "iphone_skips": parse_smoke_list(IPHONE_SKIPS.read_text()),
    }
    proposal = propose(changes, inventory, weights)
    if proposal["mode"] == "full":
        return full
    tests = proposal["candidates"]
    if not set(tests).difference(inventory["smoke"], inventory["iphone_skips"]):
        return smoke
    for count in range(1, min(max_count, len(tests)) + 1):
        shards = shard_tests(tests, weights, count, selected=True)
        loads = [sum(weights.get(test, 20.0) for test in shard) for shard in shards]
        if max(loads) <= TARGET_SECONDS:
            proposal.update(shards=shards, planned_seconds=[round(load, 3) for load in loads],
                            changed_paths=changes["files"], sha=pr["head"].get("sha"), base_sha=pr["base"].get("sha"))
            return {"mode": "selected", "matrix": {"lane": [f"ui-{i}" for i in range(1, count + 1)]},
                    "proposal": proposal}
    return full


def main():
    event = os.environ["EVENT_NAME"]
    changes = json.loads(os.environ["CHANGES_JSON"])
    skip = classifier_skip(event, {"changes": changes})
    try:
        paths = json.loads(changes.get("outputs", {}).get("shadow_paths", ""))
    except ValueError:
        paths = {}
    # The previous step has already forced full on unreadable events.
    initial = os.environ["INITIAL_MODE"]
    payload = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text()) if initial == "smoke" else {}
    plan = execution_plan(initial, event, payload, paths, int(os.environ["IOS_UI_SHARDS"]))
    print(f"run={str(not skip).lower()}")
    print("mode=" + plan["mode"])
    print("matrix=" + json.dumps(plan["matrix"]))
    if plan["mode"] == "selected":
        text = json.dumps(plan["proposal"], separators=(",", ":"))
        print("proposal=" + text)
        Path(os.environ["RUNNER_TEMP"], "ui-selection.json").write_text(text + "\n")


if __name__ == "__main__":
    main()
