#!/usr/bin/env bash
#
# Runs `xcodegen generate` for ios/Beid.xcodeproj and fails if XcodeGen
# could not find its own setting presets.
#
# Why this exists (beid#320, 2026-09-03):
#
# XcodeGen reads its build-setting presets from a `SettingPresets/`
# directory shipped alongside the binary (Homebrew and Mint both place it
# at `../share/xcodegen/SettingPresets`). An installation that has the
# binary but not that directory — extracting only `bin/xcodegen` from a
# release archive does exactly this — still generates a project, still
# exits 0, and silently omits every preset-derived setting.
#
# For this project that silently drops 161 lines, including
# `BUNDLE_LOADER`, `SDKROOT`, `LD_RUNPATH_SEARCH_PATHS` and
# `TARGETED_DEVICE_FAMILY`. The resulting project does not build:
#
#   xcodebuild: error: Could not find test host for BeidTests
#   error: Multiple commands produce '.../Debug-iphonesimulator/.app'
#
# The only signal XcodeGen gives is warnings on stdout — `No "base"
# settings found`, `No "iOS" settings found`, and friends — next to a
# success message and a zero exit code. This was originally diagnosed as a
# version difference between the pinned 2.45.3 and 2.46.0; it is not. The
# same 161 lines disappear from 2.46.0 run without its presets, and the
# pinned 2.45.3 on CI generates them correctly. The variable is the
# installation, not the version. See DECISIONS 2026-09-03.
#
# This guard turns that silent, correct-looking failure into a loud one.
# It is not a substitute for the drift check each caller runs afterwards:
# drift catches a wrong committed project, this catches a wrong generator.
#
# The version check below closes the other half of "a wrong generator"
# (beid#597, 2026-09-17). A DIFFERENT VERSION of XcodeGen, correctly
# installed with its presets, writes a project that builds, passes this
# script's preset check, and still differs from the pinned generator's
# output. Observed: 2.46.0 orders the `targets` list as Beid,
# BeidMetaMaskSupport, BeidLab where the pinned 2.45.3 writes Beid, BeidLab,
# BeidMetaMaskSupport. Nothing local says anything is wrong; the first signal
# is CI's drift check failing on a one-line reordering, after the run has
# already taken the single macOS runner the TestFlight lane shares.
#
# The version lives in ios/ci_scripts/XCODEGEN_VERSION, which is the same
# file CI reads, so the two cannot drift apart. As with the presets: do not
# "fix" a mismatch by editing that file.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios_dir="$(cd "$script_dir/../ios" && pwd)"

expected_version="$(tr -d '[:space:]' < "$ios_dir/ci_scripts/XCODEGEN_VERSION")"
installed_version=""
if command -v xcodegen >/dev/null 2>&1; then
  installed_version="$(xcodegen --version | awk '{print $2}')"
fi
if [[ "$installed_version" != "$expected_version" ]]; then
  {
    echo "error: XcodeGen $expected_version is required; found ${installed_version:-none}."
    echo
    echo "A different version generates a project that builds and still does not"
    echo "match the committed one, so the mismatch would first appear as a CI"
    echo "drift failure rather than here."
    echo
    echo "To run the pinned version without disturbing an installed one:"
    echo
    echo "  curl -sL -o /tmp/xcodegen.zip \\"
    echo "    https://github.com/yonaskolb/XcodeGen/releases/download/$expected_version/xcodegen.zip"
    echo "  unzip -q -o /tmp/xcodegen.zip -d /tmp/xcodegen-$expected_version"
    echo "  chmod +x /tmp/xcodegen-$expected_version/xcodegen/bin/xcodegen"
    echo "  PATH=/tmp/xcodegen-$expected_version/xcodegen/bin:\$PATH scripts/xcodegen_generate_checked.sh"
    echo
    echo "That archive carries share/xcodegen/SettingPresets beside the binary,"
    echo "so it does not hit the preset trap described above."
    echo
    echo "Do not 'fix' this by changing ios/ci_scripts/XCODEGEN_VERSION."
  } >&2
  exit 1
fi

cd "$ios_dir"

generate_log="$(mktemp -t xcodegen-generate)"
trap 'rm -f "$generate_log"' EXIT

# Keep XcodeGen's own exit code; capture stdout and stderr for inspection
# while still showing everything to the caller.
set +e
xcodegen generate >"$generate_log" 2>&1
generate_status=$?
set -e

cat "$generate_log"

if [[ $generate_status -ne 0 ]]; then
  exit $generate_status
fi

if grep -qE '^No ".*" settings found' "$generate_log"; then
  {
    echo
    echo "error: XcodeGen generated a project without its setting presets."
    echo
    echo "The warnings above mean XcodeGen could not find its SettingPresets"
    echo "directory. It wrote a project anyway and exited 0, but that project"
    echo "is missing BUNDLE_LOADER, SDKROOT, LD_RUNPATH_SEARCH_PATHS and"
    echo "TARGETED_DEVICE_FAMILY, and will not build."
    echo
    echo "This is an installation problem, not a version problem. Install"
    echo "XcodeGen so that share/xcodegen/SettingPresets sits next to the"
    echo "binary — Homebrew ('brew install xcodegen') and Mint both do."
    echo "Extracting only bin/xcodegen from a release archive does not."
    echo
    echo "Do not 'fix' this by changing ios/ci_scripts/XCODEGEN_VERSION or by"
    echo "removing settings from ios/project.yml. See beid#320."
  } >&2
  exit 1
fi
