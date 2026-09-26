#!/usr/bin/env bash
# Verify the committed release digest before extracting or executing its contents.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$REPO_ROOT/ios/ci_scripts/XCODEGEN_VERSION")"
SHA256="$(tr -d '[:space:]' < "$REPO_ROOT/ios/ci_scripts/XCODEGEN_SHA256")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ "$SHA256" =~ ^[0-9a-f]{64}$ ]]
[[ $# == 1 ]] || { echo 'usage: download_xcodegen.sh OUTPUT_DIRECTORY' >&2; exit 2; }
mkdir -p "$1"
ARCHIVE="$1/xcodegen.zip"
curl --fail --silent --show-error --location --retry 5 --retry-all-errors \
  --retry-delay 2 --connect-timeout 30 --output "$ARCHIVE" \
  "https://github.com/yonaskolb/XcodeGen/releases/download/$VERSION/xcodegen.zip"
printf '%s  %s\n' "$SHA256" "$ARCHIVE" | shasum --algorithm 256 --check --strict
unzip -q "$ARCHIVE" -d "$1"
test -x "$1/xcodegen/bin/xcodegen"
test -d "$1/xcodegen/share/xcodegen/SettingPresets"
