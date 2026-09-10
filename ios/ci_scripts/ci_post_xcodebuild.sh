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

# Test actions (e.g. the PR Build & Test workflow) run this hook without
# CI_PRIMARY_REPOSITORY_PATH and never need TestFlight notes.
if [[ -z "${CI_PRIMARY_REPOSITORY_PATH:-}" ]]; then
  echo "No CI_PRIMARY_REPOSITORY_PATH (test action); skipping TestFlight note generation."
  exit 0
fi

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
  # A release branch ships the marketing-style notes by name; there is no
  # per-platform variant of that file.
  SOURCE_ARGS=(--source release_notes.json)
  SOURCE_DESCRIPTION="release_notes.json"
else
  # --platform ios prefers what_to_test.ios.json and falls back to
  # what_to_test.json. That preference lives in prepare_testflight_notes.py so
  # this hook, the emi delivery lane and the Android lane all resolve it the
  # same way, and so --missing-ok can skip generation without this script
  # holding its own copy of the candidate list (beid#503).
  SOURCE_ARGS=(--platform ios)
  SOURCE_DESCRIPTION="what_to_test.ios.json, falling back to what_to_test.json"
fi

echo "Generating TestFlight notes from $SOURCE_DESCRIPTION (branch: ${CI_BRANCH:-unknown})"
python3 scripts/prepare_testflight_notes.py \
  "${SOURCE_ARGS[@]}" \
  --repo-root . \
  --skip-empty \
  --missing-ok \
  --output-dir "$TESTFLIGHT_DIR"

echo "TestFlight dir:"
ls -la "$TESTFLIGHT_DIR"
