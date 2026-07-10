#!/bin/zsh
#
# Xcode Cloud: runs after xcodebuild.
#
# Purpose:
# - Generate TestFlight "What to Test" notes that Xcode Cloud picks up
#   automatically from ios/TestFlight/WhatToTest.<locale>.txt.
# - Source file depends on the branch: release/* branches ship the
#   marketing-style release_notes.json, everything else (PRs, main, feature
#   branches) ships the internal-tester what_to_test.json. See
#   docs/xcode-cloud.md for the full convention.
#

set -euo pipefail

cd "$CI_PRIMARY_REPOSITORY_PATH"

if [[ ! -d "${CI_APP_STORE_SIGNED_APP_PATH:-}" ]]; then
  echo "No signed app path; skipping TestFlight note generation."
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TESTFLIGHT_DIR="$IOS_DIR/TestFlight"
mkdir -p "$TESTFLIGHT_DIR"

if [[ "${CI_BRANCH:-}" == release/* ]]; then
  SOURCE_JSON="release_notes.json"
else
  SOURCE_JSON="what_to_test.json"
fi

if [[ ! -f "$SOURCE_JSON" ]]; then
  echo "warning: $SOURCE_JSON not found at repo root; skipping TestFlight note generation." >&2
  exit 0
fi

echo "Generating TestFlight notes from $SOURCE_JSON (branch: ${CI_BRANCH:-unknown})"
python3 scripts/prepare_testflight_notes.py \
  --source "$SOURCE_JSON" \
  --output-dir "$TESTFLIGHT_DIR"

echo "TestFlight dir:"
ls -la "$TESTFLIGHT_DIR"
