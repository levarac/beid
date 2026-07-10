#!/bin/zsh
#
# Xcode Cloud: runs after cloning the repository.
#
# Purpose:
# - Regenerate Beid.xcodeproj from project.yml with XcodeGen, and fail loudly
#   if the committed .xcodeproj had drifted (AGENTS.md: project.yml is the
#   source of truth, the .xcodeproj is generated from it, never hand-edited).
#

set -euo pipefail

cd "$CI_PRIMARY_REPOSITORY_PATH/ios"

echo "=== ci_post_clone ==="
echo "CI_BRANCH: ${CI_BRANCH:-}"
echo "CI_PULL_REQUEST_NUMBER: ${CI_PULL_REQUEST_NUMBER:-}"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "Installing XcodeGen..."
  brew install xcodegen
fi

echo "Regenerating Beid.xcodeproj from project.yml..."
xcodegen generate

if ! git diff --quiet -- Beid.xcodeproj; then
  echo "error: Beid.xcodeproj is out of sync with project.yml." >&2
  echo "Run 'cd ios && xcodegen generate' locally and commit the result." >&2
  git diff --stat -- Beid.xcodeproj >&2
  exit 1
fi

echo "Beid.xcodeproj is in sync with project.yml."
exit 0
