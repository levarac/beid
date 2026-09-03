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
