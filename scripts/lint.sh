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

# SwiftLint's SourceKit dependency needs a full Xcode.app toolchain; the
# Command Line Tools package lacks Toolchains/XcodeDefault.xctoolchain and
# loading its sourcekitdInProc crashes with a fatal error at lint time. Both
# installs otherwise look similar (both ship usr/bin/swiftc), so probe for
# the concrete file SourceKit actually loads rather than just any toolchain
# binary. Mirrors scripts/resolve_kmp_java_home.sh: explicit override first
# (validated, not trusted blindly), then well-known candidates in order
# (each validated before being accepted), then a clear error if nothing
# resolves.
developer_dir_has_sourcekitd() {
    [ -x "$1/Toolchains/XcodeDefault.xctoolchain/usr/lib/sourcekitdInProc.framework/Versions/A/sourcekitdInProc" ]
}

resolve_developer_dir() {
    if [ -n "${DEVELOPER_DIR:-}" ]; then
        if developer_dir_has_sourcekitd "$DEVELOPER_DIR"; then
            printf '%s\n' "$DEVELOPER_DIR"
            return 0
        fi
        echo "error: DEVELOPER_DIR is set to '$DEVELOPER_DIR' but it does not contain a full Xcode toolchain (missing sourcekitdInProc)." >&2
        echo "  SwiftLint's SourceKit dependency needs a full Xcode.app install, not the Command Line Tools. Point DEVELOPER_DIR at a full Xcode.app's Contents/Developer, or unset it to let this script resolve one." >&2
        return 1
    fi

    xcode_select_dir="$(xcode-select -p 2>/dev/null || true)"
    if [ -n "$xcode_select_dir" ] && developer_dir_has_sourcekitd "$xcode_select_dir"; then
        printf '%s\n' "$xcode_select_dir"
        return 0
    fi

    default_xcode_dir="/Applications/Xcode.app/Contents/Developer"
    if developer_dir_has_sourcekitd "$default_xcode_dir"; then
        printf '%s\n' "$default_xcode_dir"
        return 0
    fi

    echo "error: could not find a full Xcode toolchain for SwiftLint's SourceKit dependency (sourcekitdInProc)." >&2
    echo "  xcode-select currently points at '${xcode_select_dir:-<unset>}', which looks like the Command Line Tools; SwiftLint needs a full Xcode.app install instead, or lint fails with a 'Loading sourcekitdInProc.framework ... failed' fatal error." >&2
    echo "  Fix: install Xcode.app (or point xcode-select at an existing one with 'sudo xcode-select -s /Applications/Xcode.app/Contents/Developer'), or set DEVELOPER_DIR to a full Xcode.app's Contents/Developer before running this script." >&2
    return 1
}

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
# NOT `export DEVELOPER_DIR="$(resolve_developer_dir)"`: under set -e, a
# failing command substitution inside an `export` assignment is masked by
# export's own (successful) exit status, so a resolver failure would be
# silently swallowed and the script would fall through to the crash this
# resolver exists to prevent. Splitting the assignment from `export` lets
# set -e see the command substitution's real exit status.
DEVELOPER_DIR="$(resolve_developer_dir)"
export DEVELOPER_DIR
exec swiftlint lint --config .swiftlint.yml --no-cache "$@"
