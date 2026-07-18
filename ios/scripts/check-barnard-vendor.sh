#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR_DIR="$IOS_DIR/Vendor/Barnard"
PIN_FILE="$VENDOR_DIR/.pin"
UPSTREAM_URL="${BARNARD_UPSTREAM_URL:-https://github.com/levarac/barnard.git}"
UPSTREAM_PACKAGE_PATH="packages/swift/barnard"
CANONICAL_PIN_REFERENCE="Vendor/Barnard/.pin"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ -f "$PIN_FILE" ]] || fail "canonical Barnard pin is missing: $PIN_FILE"

PIN_LINE_COUNT="$(awk 'END { print NR }' "$PIN_FILE")"
PIN="$(sed -n '1p' "$PIN_FILE")"
if [[ "$PIN_LINE_COUNT" != "1" || ! "$PIN" =~ ^[0-9a-f]{40}$ ]]; then
  fail "$PIN_FILE must contain exactly one 40-character lowercase hexadecimal SHA"
fi

check_documentation_contract() {
  local document="$1"

  if ! grep -Fq "$CANONICAL_PIN_REFERENCE" "$document"; then
    fail "$document is missing the canonical pin reference $CANONICAL_PIN_REFERENCE"
  fi

  if grep -Eq 'levarac/barnard@[0-9a-fA-F]{7,40}' "$document"; then
    fail "$document must not duplicate a Barnard commit SHA; refer to $CANONICAL_PIN_REFERENCE instead"
  fi
}

check_documentation_contract "$IOS_DIR/README.md"
check_documentation_contract "$IOS_DIR/project.yml"

CHECKOUT_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/beid-barnard-vendor.XXXXXX")"
trap 'rm -rf "$CHECKOUT_ROOT"' EXIT
UPSTREAM_CHECKOUT="$CHECKOUT_ROOT/barnard"

git init --quiet "$UPSTREAM_CHECKOUT"
if ! git -C "$UPSTREAM_CHECKOUT" fetch --quiet --depth 1 "$UPSTREAM_URL" "$PIN"; then
  fail "could not fetch Barnard pin $PIN from $UPSTREAM_URL"
fi

FETCHED_PIN="$(git -C "$UPSTREAM_CHECKOUT" rev-parse 'FETCH_HEAD^{commit}')"
if [[ "$FETCHED_PIN" != "$PIN" ]]; then
  fail "fetched commit $FETCHED_PIN does not match canonical pin $PIN"
fi

git -C "$UPSTREAM_CHECKOUT" checkout --quiet --detach FETCH_HEAD
UPSTREAM_DIR="$UPSTREAM_CHECKOUT/$UPSTREAM_PACKAGE_PATH"
[[ -d "$UPSTREAM_DIR" ]] || fail "pinned Barnard commit does not contain $UPSTREAM_PACKAGE_PATH"

echo "Comparing ios/Vendor/Barnard with levarac/barnard@$PIN..."
# .pin is beid-only metadata. The other exclusions match Barnard's checked-in
# .gitignore so local SwiftPM/Xcode build products are not mistaken for source.
if diff -rq \
  -x .pin \
  -x .build \
  -x .swiftpm \
  -x '*.xcodeproj' \
  "$UPSTREAM_DIR" "$VENDOR_DIR"; then
  echo "Barnard vendor drift check passed: the vendored tree matches $PIN."
  exit 0
else
  DIFF_STATUS=$?
fi

if [[ "$DIFF_STATUS" == "1" ]]; then
  fail "Barnard vendor drift detected; re-vendor from $PIN or update $PIN_FILE intentionally"
fi

echo "ERROR: diff could not compare the Barnard trees (exit $DIFF_STATUS)" >&2
exit "$DIFF_STATUS"
