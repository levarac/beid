#!/bin/zsh
#
# Xcode Cloud: runs after cloning the repository.
#
# Purpose:
# - Regenerate Beid.xcodeproj from project.yml with XcodeGen, and fail loudly
#   if the committed .xcodeproj had drifted (AGENTS.md: project.yml is the
#   source of truth, the .xcodeproj is generated from it, never hand-edited).
#
# XcodeGen is pinned to the version in XCODEGEN_VERSION (next to this
# script) rather than `brew install xcodegen`'s always-latest: an
# unannounced XcodeGen release could otherwise reformat/reorder the
# generated project and false-positive the drift guard below with zero
# repo-side change. If this guard fails right after bumping XCODEGEN_VERSION
# on purpose, that's expected — regenerate and commit locally with the new
# version first (see docs/xcode-cloud.md).
#

set -euo pipefail

cd "$CI_PRIMARY_REPOSITORY_PATH/ios"

echo "=== ci_post_clone ==="
echo "CI_BRANCH: ${CI_BRANCH:-}"
echo "CI_PULL_REQUEST_NUMBER: ${CI_PULL_REQUEST_NUMBER:-}"

# --- beid#491 git-height plist injection: begin ---
# Ship the git height INSIDE the bundle so the in-app version row can render
# "{MARKETING_VERSION} ({git height}+{CFBundleVersion})". The height is a
# function of the built commit's ancestry, so an iOS build and an Android build
# showing the same height were built from the same commit -- which is the whole
# reason this key exists. CFBundleVersion is untouched: it is the only number
# App Store Connect, TestFlight and crash logs ever show.
#
# THE GUARD IS "IS THIS REPOSITORY STILL SHALLOW", NOT "IS THE HEIGHT EMPTY".
# Xcode Cloud clones shallow. On a shallow clone `git rev-list --count HEAD`
# does not fail and does not return empty -- it returns a PLAUSIBLE SMALLER
# NUMBER. That is the worst failure mode available here: a bundle that ships a
# wrong build position with nothing to distinguish it from a right one. An
# emptiness check cannot see it. (The model this was taken from, umidori
# v0.12.10 ci_post_clone.sh:19-24, deepens with a trailing `|| true` and then
# only checks for empty, so it does not actually refuse a truncated height.
# Deliberate divergence, not an oversight.)
#
# stderr is NOT suppressed here: `--unshallow` legitimately errors on a complete
# repository, and hiding that stream would also hide a network failure. The
# is-shallow check below is what decides, so the noise is safe to show.
echo "Calculating git height for build identification..."
git -C "$CI_PRIMARY_REPOSITORY_PATH" fetch --unshallow --quiet \
  || git -C "$CI_PRIMARY_REPOSITORY_PATH" fetch --deepen 100000 --quiet \
  || true
if [[ "$(git -C "$CI_PRIMARY_REPOSITORY_PATH" rev-parse --is-shallow-repository)" != "false" ]]; then
  echo "error: repository is still shallow after --unshallow/--deepen." >&2
  echo "git rev-list --count HEAD would return a plausible but TRUNCATED height," >&2
  echo "so this build is refused rather than shipping a wrong build position." >&2
  exit 1
fi
GIT_HEIGHT="$(git -C "$CI_PRIMARY_REPOSITORY_PATH" rev-list --count HEAD)"
if [[ ! "$GIT_HEIGHT" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: computed git height is not a positive integer: '$GIT_HEIGHT'" >&2
  exit 1
fi
echo "Git height: $GIT_HEIGHT"

# Presence of this key is what marks a bundle as CI-produced; this script is its
# only writer, and the app renders "local" when it is absent. A missing plist is
# therefore a HARD FAILURE: skipping silently would ship an Xcode Cloud build
# that calls itself local, which is worse than a red build.
INFO_PLIST_PATH="${INFO_PLIST_PATH:-$CI_PRIMARY_REPOSITORY_PATH/ios/Beid/App/Info.plist}"
if [[ ! -f "$INFO_PLIST_PATH" ]]; then
  echo "error: Info.plist not found at $INFO_PLIST_PATH; refusing to build a bundle" >&2
  echo "whose version row cannot show the git height." >&2
  exit 1
fi
# Idempotent: Set updates an existing key, Add creates it on the first run.
# The type is `string` on purpose -- an <integer> comes back as an NSNumber and
# the app's `as? String` read would fall through to the "local" branch.
if ! /usr/libexec/PlistBuddy -c "Set :BeidGitHeight $GIT_HEIGHT" "$INFO_PLIST_PATH" 2>/dev/null; then
  /usr/libexec/PlistBuddy -c "Add :BeidGitHeight string $GIT_HEIGHT" "$INFO_PLIST_PATH"
fi
echo "Info.plist $INFO_PLIST_PATH BeidGitHeight: $(/usr/libexec/PlistBuddy -c "Print :BeidGitHeight" "$INFO_PLIST_PATH")"
# --- beid#491 git-height plist injection: end ---

XCODEGEN_VERSION="$(cat ci_scripts/XCODEGEN_VERSION)"
INSTALLED_VERSION=""
if command -v xcodegen >/dev/null 2>&1; then
  INSTALLED_VERSION="$(xcodegen --version | awk '{print $2}')"
fi

if [[ "$INSTALLED_VERSION" != "$XCODEGEN_VERSION" ]]; then
  echo "Installing XcodeGen $XCODEGEN_VERSION (found: ${INSTALLED_VERSION:-none})..."
  XCODEGEN_TMP="$(mktemp -d)"
  # Retry the download. Every Xcode Cloud runner is clean, so this fetch runs
  # on every single build and its success depends on the runner reaching
  # github.com at that moment — an unretried failure takes the whole build
  # down with correct code. Observed 2026-08-05: build 93c57d8e failed with
  # curl exit 35 (SSL connect error) here, nothing else wrong with the commit.
  # --retry-all-errors is what makes --retry cover connection/TLS failures;
  # --retry alone only covers transient HTTP responses and timeouts.
  curl -sSL --retry 5 --retry-all-errors --retry-delay 2 --connect-timeout 30 \
    -o "$XCODEGEN_TMP/xcodegen.zip" \
    "https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"
  unzip -q "$XCODEGEN_TMP/xcodegen.zip" -d "$XCODEGEN_TMP"
  XCODEGEN_PREFIX="$HOME/.local/xcodegen-${XCODEGEN_VERSION}"
  # Use the unzipped release directly. The release's install.sh does a bare
  # `cp` into $PREFIX and fails when the directory doesn't exist (observed
  # on Xcode Cloud runners, build 2).
  rm -rf "$XCODEGEN_PREFIX"
  mkdir -p "$(dirname "$XCODEGEN_PREFIX")"
  mv "$XCODEGEN_TMP/xcodegen" "$XCODEGEN_PREFIX"
  export PATH="$XCODEGEN_PREFIX/bin:$PATH"
  rm -rf "$XCODEGEN_TMP"
fi

echo "Using XcodeGen: $(xcodegen --version)"

if ! "$CI_PRIMARY_REPOSITORY_PATH/scripts/resolve_kmp_java_home.sh" >/dev/null 2>&1; then
  echo "Installing pinned OpenJDK 17 for Kotlin Multiplatform..."
  brew install openjdk@17
fi

KMP_JAVA_HOME="$("$CI_PRIMARY_REPOSITORY_PATH/scripts/resolve_kmp_java_home.sh")"
echo "Using KMP JDK: $KMP_JAVA_HOME"
"$KMP_JAVA_HOME/bin/java" -version

echo "Regenerating Beid.xcodeproj from project.yml..."
"$CI_PRIMARY_REPOSITORY_PATH/scripts/xcodegen_generate_checked.sh"

if [[ -n "$(git status --porcelain -- Beid.xcodeproj)" ]]; then
  echo "error: Beid.xcodeproj is out of sync with project.yml." >&2
  echo "Run 'cd ios && xcodegen generate' locally and commit the result." >&2
  git status --porcelain -- Beid.xcodeproj >&2
  exit 1
fi

echo "Beid.xcodeproj is in sync with project.yml."
exit 0
