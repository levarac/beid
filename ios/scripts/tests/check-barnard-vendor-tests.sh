#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
GUARD_SCRIPT="$IOS_DIR/scripts/check-barnard-vendor.sh"
VENDOR_DIR="$IOS_DIR/Vendor/Barnard"

if [[ ! -x "$GUARD_SCRIPT" ]]; then
  echo "FAIL: Barnard vendor guard script is missing or not executable: $GUARD_SCRIPT" >&2
  exit 1
fi

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/beid-barnard-guard-tests.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

UPSTREAM_REPO="$TEST_ROOT/upstream"
mkdir -p "$UPSTREAM_REPO/packages/swift"
cp -R "$VENDOR_DIR" "$UPSTREAM_REPO/packages/swift/barnard"
rm -f "$UPSTREAM_REPO/packages/swift/barnard/.pin"
rm -rf \
  "$UPSTREAM_REPO/packages/swift/barnard/.build" \
  "$UPSTREAM_REPO/packages/swift/barnard/.swiftpm"

git -C "$UPSTREAM_REPO" init --quiet
git -C "$UPSTREAM_REPO" add packages/swift/barnard
git -C "$UPSTREAM_REPO" \
  -c user.name='Barnard guard tests' \
  -c user.email='barnard-guard-tests@example.invalid' \
  commit --quiet -m 'Create upstream fixture'
FIXTURE_PIN="$(git -C "$UPSTREAM_REPO" rev-parse HEAD)"

CASE_DIR=""
make_case() {
  local name="$1"
  CASE_DIR="$TEST_ROOT/$name"
  mkdir -p "$CASE_DIR/ios/Vendor" "$CASE_DIR/ios/scripts"
  cp -R "$VENDOR_DIR" "$CASE_DIR/ios/Vendor/Barnard"
  rm -rf \
    "$CASE_DIR/ios/Vendor/Barnard/.build" \
    "$CASE_DIR/ios/Vendor/Barnard/.swiftpm"
  cp "$GUARD_SCRIPT" "$CASE_DIR/ios/scripts/check-barnard-vendor.sh"
  cp "$IOS_DIR/README.md" "$CASE_DIR/ios/README.md"
  cp "$IOS_DIR/project.yml" "$CASE_DIR/ios/project.yml"
  printf '%s\n' "$FIXTURE_PIN" > "$CASE_DIR/ios/Vendor/Barnard/.pin"
}

replace_text() {
  local file="$1"
  local old="$2"
  local new="$3"
  python3 - "$file" "$old" "$new" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = sys.argv[2]
new = sys.argv[3]
if old not in text:
    raise SystemExit(f"test fixture did not contain expected text: {old}")
path.write_text(text.replace(old, new))
PY
}

assert_passes() {
  local name="$1"
  local output

  if ! output="$(BARNARD_UPSTREAM_URL="$UPSTREAM_REPO" \
    "$CASE_DIR/ios/scripts/check-barnard-vendor.sh" 2>&1)"; then
    echo "FAIL: $name unexpectedly failed" >&2
    echo "$output" >&2
    exit 1
  fi

  echo "PASS: $name"
}

assert_fails_with() {
  local name="$1"
  local expected="$2"
  local output

  if output="$(BARNARD_UPSTREAM_URL="$UPSTREAM_REPO" \
    "$CASE_DIR/ios/scripts/check-barnard-vendor.sh" 2>&1)"; then
    echo "FAIL: $name unexpectedly passed" >&2
    exit 1
  fi

  if [[ "$output" != *"$expected"* ]]; then
    echo "FAIL: $name failed without the expected message: $expected" >&2
    echo "$output" >&2
    exit 1
  fi

  echo "PASS: $name"
}

make_case clean
assert_passes "matching vendored tree"

make_case ignored-build-artifacts
mkdir -p \
  "$CASE_DIR/ios/Vendor/Barnard/.build" \
  "$CASE_DIR/ios/Vendor/Barnard/.swiftpm" \
  "$CASE_DIR/ios/Vendor/Barnard/Barnard.xcodeproj"
printf 'generated\n' > "$CASE_DIR/ios/Vendor/Barnard/.build/artifact"
printf 'generated\n' > "$CASE_DIR/ios/Vendor/Barnard/.swiftpm/artifact"
printf 'generated\n' > "$CASE_DIR/ios/Vendor/Barnard/Barnard.xcodeproj/project.pbxproj"
assert_passes "ignored SwiftPM and Xcode build artifacts"

make_case source-drift
printf '\n// deliberate test drift\n' >> "$CASE_DIR/ios/Vendor/Barnard/Package.swift"
assert_fails_with "source drift" "vendor drift detected"

make_case readme-reference
replace_text "$CASE_DIR/ios/README.md" "Vendor/Barnard/.pin" "Vendor/Barnard/PIN"
assert_fails_with "README canonical pin reference" "canonical pin reference"

make_case project-reference
replace_text "$CASE_DIR/ios/project.yml" "Vendor/Barnard/.pin" "Vendor/Barnard/PIN"
assert_fails_with "project.yml canonical pin reference" "canonical pin reference"

make_case duplicate-doc-pin
printf '\nStale copy: levarac/barnard@%s.\n' "$FIXTURE_PIN" >> "$CASE_DIR/ios/README.md"
assert_fails_with "duplicated documentation pin" "must not duplicate a Barnard commit SHA"

make_case invalid-pin
printf '%s\n' 'not-a-commit' > "$CASE_DIR/ios/Vendor/Barnard/.pin"
assert_fails_with "invalid pin format" "exactly one 40-character lowercase hexadecimal SHA"

echo "All Barnard vendor guard tests passed."
