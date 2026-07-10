#!/usr/bin/env bash
# Design-contract lint runner (DESIGN.md §16).
#
# SwiftLint 0.65 baselines store absolute file:// paths, so a checked-in
# baseline only works in the checkout that generated it. The portable
# source of truth is lint/baseline.template.json (paths rooted at the
# __REPO_ROOT__ placeholder); this script materializes the gitignored
# .swiftlint-baseline.json for THIS checkout, then runs swiftlint.
#
# The shrink-only policy governs the TEMPLATE: regenerating it to absorb
# new violations is FORBIDDEN; it may only shrink after a migration lands.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"

python3 - "$ROOT" <<'PYEOF'
import json, sys
root = sys.argv[1]
with open(f"{root}/lint/baseline.template.json") as f:
    entries = json.load(f)
for e in entries:
    loc = e["violation"]["location"]
    loc["file"] = loc["file"].replace("file://__REPO_ROOT__/", f"file://{root}/")
with open(f"{root}/.swiftlint-baseline.json", "w") as f:
    json.dump(entries, f)
PYEOF

cd "$ROOT"
exec swiftlint lint --config .swiftlint.yml --no-cache "$@"
