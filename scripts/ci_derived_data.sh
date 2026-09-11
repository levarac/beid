#!/bin/bash
#
# Persistent DerivedData for the self-hosted iOS lanes (gh#479).
#
# Used by .github/workflows/pr-ci-ios-macos.yml and
# .github/workflows/main-ios-release-build.yml, which run on the single
# self-hosted runner `emi`. Contract tests: scripts/tests/test_ci_derived_data.py.
#
#   scripts/ci_derived_data.sh resolve
#       Derive ONE cache key from the four inputs that decide whether an old
#       DerivedData is still valid for this checkout, place the directory under
#       the runner user (never under RUNNER_TEMP, which is per job), report
#       whether it is cold or warm, prune to the three most recently used keys,
#       and export CI_DERIVED_DATA / CI_DERIVED_DATA_KEY / CI_DERIVED_DATA_STATE
#       to GITHUB_ENV for the steps that follow.
#
#   scripts/ci_derived_data.sh build <label> -- xcodebuild ...
#       Run the build. On failure, wipe the DerivedData so the next run starts
#       clean, and retry exactly once IF the failed attempt was warm: a
#       stale-module false red then heals itself, and the job summary says so.
#       A cold attempt that failed is not retried; a clean build that failed
#       has nothing stale to heal, and a second identical build would only add
#       minutes to a real red. The summary line always carries the word
#       "incremental" so this build's wall time is never quoted as a cold number.
#
# Key inputs (any change → new key → cold build):
#   - `xcodebuild -version` build line (the Xcode selected by DEVELOPER_DIR)
#   - ios/ci_scripts/XCODEGEN_VERSION
#   - sha256 of ios/Beid.xcodeproj/.../swiftpm/Package.resolved
#   - ios/ci_scripts/DERIVED_DATA_CACHE_BUMP — edit it to invalidate every key
#
# Path: $HOME/Library/Caches/ci-derived-data/<owner>-<repo>/<runner>/<key>
#   Per runner, so an ephemeral second runner on the same host never writes
#   into the directory the first one is using.
#
# Written for the runner's shell, macOS /bin/bash 3.2: no arrays beyond
# positional parameters, no mapfile, no ${x,,}; `shasum -a 256` rather than
# sha256sum; no sed -i; no stat -f/-c. The contract tests run this file under
# /bin/bash explicitly so the sanity job (Ubuntu, bash 5) checks the same code.

set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage:
  ci_derived_data.sh resolve
  ci_derived_data.sh build <label> -- <command> [args...]
USAGE
  exit 2
}

log() {
  printf 'ci_derived_data: %s\n' "$*" >&2
}

CACHE_ROOT="${HOME:?HOME is not set}/Library/Caches/ci-derived-data"
REPO_SLUG="${GITHUB_REPOSITORY:-thegreeting/beid}"
REPO_DIR="${REPO_SLUG//\//-}"
RUNNER="${RUNNER_NAME:-unknown-runner}"
WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"
KEEP_KEYS=3

XCODEGEN_VERSION_FILE="$WORKSPACE/ios/ci_scripts/XCODEGEN_VERSION"
BUMP_FILE="$WORKSPACE/ios/ci_scripts/DERIVED_DATA_CACHE_BUMP"
PACKAGE_RESOLVED="$WORKSPACE/ios/Beid.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

# Every rm -rf in this file goes through here. `set -u` alone does not stop
# `rm -rf "$HOME/Library/Caches"` when a key comes out empty.
guard_cache_path() {
  local path="$1"
  case "$path" in
    "$CACHE_ROOT/$REPO_DIR/"*/*) ;;
    *)
      log "refusing to delete outside the cache root: '$path' (root: $CACHE_ROOT/$REPO_DIR/<runner>/<key>)"
      return 1
      ;;
  esac
  case "$path" in
    */.. | */../* | *//*)
      log "refusing to delete a path with '..' or '//': '$path'"
      return 1
      ;;
  esac
  return 0
}

wipe() {
  local path="$1"
  # Checked explicitly: inside a function invoked in a conditional context
  # (`wipe x || true`, `if wipe x`) bash suppresses `set -e`, and the guard's
  # failure would otherwise fall straight through to rm -rf.
  guard_cache_path "$path" || return 1
  log "wiping $path"
  rm -rf "$path"
}

summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"
  fi
  printf '%s\n' "$*"
}

sha256_of_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

read_trimmed() {
  tr -d '[:space:]' < "$1"
}

require_file() {
  if [[ ! -f "$1" ]]; then
    log "required input is missing: $1"
    exit 1
  fi
}

cmd_resolve() {
  require_file "$XCODEGEN_VERSION_FILE"
  require_file "$BUMP_FILE"
  require_file "$PACKAGE_RESOLVED"

  local xcode_build xcodegen_version resolved_sha bump key runner_root path state
  xcode_build="$(xcodebuild -version | awk '/^Build version/ {print $3}')"
  if [[ -z "$xcode_build" ]]; then
    log "could not read a build version from 'xcodebuild -version'"
    exit 1
  fi
  xcodegen_version="$(read_trimmed "$XCODEGEN_VERSION_FILE")"
  resolved_sha="$(sha256_of_file "$PACKAGE_RESOLVED")"
  bump="$(read_trimmed "$BUMP_FILE")"

  key="$(printf 'xcode=%s\nxcodegen=%s\npackage_resolved=%s\nbump=%s\n' \
    "$xcode_build" "$xcodegen_version" "$resolved_sha" "$bump" | shasum -a 256 | cut -c1-16)"

  runner_root="$CACHE_ROOT/$REPO_DIR/$RUNNER"
  path="$runner_root/$key"

  state=cold
  if [[ -f "$path/.last-used" ]]; then
    state=warm
  fi
  mkdir -p "$path"
  touch "$path/.last-used"

  # Prune: keep the KEEP_KEYS most recently used keys under this runner, judged
  # by the .last-used marker (directory mtimes move for unrelated reasons).
  # Directories without a marker are not ours and are left alone.
  local marker dir
  # shellcheck disable=SC2012  # ls -t is the bash-3.2-portable mtime sort; names are our own hex keys
  for marker in $(ls -t "$runner_root"/*/.last-used 2>/dev/null | tail -n +$((KEEP_KEYS + 1))); do
    dir="${marker%/.last-used}"
    wipe "$dir"
  done

  if [[ -n "${GITHUB_ENV:-}" ]]; then
    {
      printf 'CI_DERIVED_DATA=%s\n' "$path"
      printf 'CI_DERIVED_DATA_KEY=%s\n' "$key"
      printf 'CI_DERIVED_DATA_STATE=%s\n' "$state"
    } >> "$GITHUB_ENV"
  fi

  summary "### DerivedData"
  summary ""
  summary "- state: **$state** (key \`$key\`)"
  summary "- path: \`$path\`"
  summary "- key inputs: Xcode build \`$xcode_build\`, XcodeGen \`$xcodegen_version\`, Package.resolved sha256 \`${resolved_sha:0:12}…\`, bump \`$bump\`"
  summary ""
  log "state=$state key=$key path=$path"
}

cmd_build() {
  local label="$1"
  shift
  if [[ "${1:-}" != "--" ]]; then
    usage
  fi
  shift
  if [[ $# -eq 0 ]]; then
    usage
  fi

  local path="${CI_DERIVED_DATA:-}" state="${CI_DERIVED_DATA_STATE:-}" key="${CI_DERIVED_DATA_KEY:-}"
  if [[ -z "$path" || -z "$state" || -z "$key" ]]; then
    log "CI_DERIVED_DATA / CI_DERIVED_DATA_STATE / CI_DERIVED_DATA_KEY are not set; run 'ci_derived_data.sh resolve' first"
    exit 1
  fi
  guard_cache_path "$path"

  local status
  set +e
  "$@"
  status=$?
  set -e

  if [[ $status -eq 0 ]]; then
    summary "- **$label**: passed on attempt 1; DerivedData incremental (**$state**, key \`$key\`)"
    return 0
  fi

  log "$label failed on attempt 1 (exit $status) with DerivedData $state"
  wipe "$path"

  if [[ "$state" != "warm" ]]; then
    summary "- **$label**: **failed** on a cold DerivedData (exit $status); no retry, nothing stale to heal; DerivedData wiped (incremental cache: cold, key \`$key\`)"
    return "$status"
  fi

  log "$label: clean retry (attempt 2) after wiping $path"
  mkdir -p "$path"
  set +e
  "$@"
  status=$?
  set -e

  if [[ $status -eq 0 ]]; then
    touch "$path/.last-used"
    summary "- **$label**: passed on attempt 2 after one clean retry (attempt 1 failed on a warm DerivedData; incremental cache wiped and rebuilt, key \`$key\`)"
    return 0
  fi

  wipe "$path"
  summary "- **$label**: **failed** twice (warm attempt 1, clean attempt 2, exit $status); DerivedData wiped (incremental cache, key \`$key\`)"
  return "$status"
}

main() {
  if [[ $# -lt 1 ]]; then
    usage
  fi
  local command="$1"
  shift
  case "$command" in
    resolve)
      if [[ $# -ne 0 ]]; then
        usage
      fi
      cmd_resolve
      ;;
    build)
      if [[ $# -lt 1 ]]; then
        usage
      fi
      cmd_build "$@"
      ;;
    *)
      usage
      ;;
  esac
}

# Run only when executed, not when sourced: the contract tests source this file
# to call wipe directly (see test_ci_derived_data.py).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
