#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUN_TEMP_ROOT="${RUNNER_TEMP:-/tmp}"
DELIVERY_TMP="$(mktemp -d "$RUN_TEMP_ROOT/beid-ios-delivery.XXXXXX")"

cleanup() {
  if [[ -n "${DELIVERY_TMP:-}" && -d "$DELIVERY_TMP" && "$DELIVERY_TMP" == "$RUN_TEMP_ROOT"/beid-ios-delivery.* ]]; then
    rm -rf -- "$DELIVERY_TMP"
  fi
}
trap cleanup EXIT

cd "$REPO_ROOT"

TESTFLIGHT_NOTES_SOURCE="${TESTFLIGHT_NOTES_SOURCE:?TESTFLIGHT_NOTES_SOURCE must identify the tester-note JSON}"
TESTFLIGHT_NOTES_DIR="$DELIVERY_TMP/testflight-notes"
NOTES_PREPARE_ARGS=(
  --source "$TESTFLIGHT_NOTES_SOURCE"
  --output-dir "$TESTFLIGHT_NOTES_DIR"
)
if [[ -n "${TESTFLIGHT_NOTES_FALLBACK_SOURCE:-}" ]]; then
  NOTES_PREPARE_ARGS+=(--fallback-source "$TESTFLIGHT_NOTES_FALLBACK_SOURCE")
fi
python3 scripts/prepare_testflight_notes.py "${NOTES_PREPARE_ARGS[@]}"

XCODEGEN_VERSION="$(< ios/ci_scripts/XCODEGEN_VERSION)"
INSTALLED_VERSION=""
if command -v xcodegen >/dev/null 2>&1; then
  INSTALLED_VERSION="$(xcodegen --version | awk '{print $2}')"
fi

if [[ "$INSTALLED_VERSION" != "$XCODEGEN_VERSION" ]]; then
  echo "Installing XcodeGen $XCODEGEN_VERSION (found: ${INSTALLED_VERSION:-none})..."
  curl -sSL --retry 5 --retry-all-errors --retry-delay 2 --connect-timeout 30 \
    -o "$DELIVERY_TMP/xcodegen.zip" \
    "https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"
  unzip -q "$DELIVERY_TMP/xcodegen.zip" -d "$DELIVERY_TMP/xcodegen-release"
  XCODEGEN_PREFIX="$HOME/.local/xcodegen-${XCODEGEN_VERSION}"
  rm -rf -- "$XCODEGEN_PREFIX"
  mkdir -p "$(dirname "$XCODEGEN_PREFIX")"
  mv "$DELIVERY_TMP/xcodegen-release/xcodegen" "$XCODEGEN_PREFIX"
  export PATH="$XCODEGEN_PREFIX/bin:$PATH"
fi

echo "Using XcodeGen: $(xcodegen --version)"

KMP_JAVA_HOME="$(scripts/resolve_kmp_java_home.sh)"
export KMP_JAVA_HOME
export JAVA_HOME="$KMP_JAVA_HOME"
export PATH="$JAVA_HOME/bin:$PATH"
echo "Using KMP JDK: $JAVA_HOME"
"$JAVA_HOME/bin/java" -version

echo "Regenerating Beid.xcodeproj from project.yml..."
scripts/xcodegen_generate_checked.sh

if [[ -n "$(git status --porcelain -- ios/Beid.xcodeproj)" ]]; then
  echo "error: ios/Beid.xcodeproj is out of sync with ios/project.yml." >&2
  echo "Run 'cd ios && xcodegen generate' locally and commit the result." >&2
  git status --porcelain -- ios/Beid.xcodeproj >&2
  exit 1
fi

ARCHIVE_PATH="$DELIVERY_TMP/Beid.xcarchive"
EXPORT_PATH="$DELIVERY_TMP/export"
EXPORT_OPTIONS="$DELIVERY_TMP/ExportOptions.plist"

: "${ASC_CRED_DIR:?ASC_CRED_DIR must point to the runner-local ASC credential directory}"
ASC_ENV_FILE="$ASC_CRED_DIR/env"
if [[ ! -r "$ASC_ENV_FILE" ]]; then
  echo "error: ASC credential environment file is not readable: $ASC_ENV_FILE" >&2
  exit 1
fi

set -a
# The source path is runner-local and supplied by ASC_CRED_DIR.
# shellcheck disable=SC1090
source "$ASC_ENV_FILE"
set +a

: "${ASC_KEY_ID:?ASC_KEY_ID is missing from the runner-local ASC environment file}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID is missing from the runner-local ASC environment file}"
: "${ASC_KEY_PATH:?ASC_KEY_PATH is missing from the runner-local ASC environment file}"
: "${BEID_TEAM_ID:?BEID_TEAM_ID is missing from the runner-local ASC environment file}"
BEID_BUNDLE_ID='org.levarac.beid'
BEID_PROVISIONING_PROFILE="${BEID_PROVISIONING_PROFILE:-Beid GitHub Actions App Store}"
GITHUB_RUN_ID="${GITHUB_RUN_ID:?GITHUB_RUN_ID is required for a unique iOS build number}"
GITHUB_RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT:-1}"
if [[ ! "$GITHUB_RUN_ID" =~ ^[1-9][0-9]*$ || ! "$GITHUB_RUN_ATTEMPT" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: GITHUB_RUN_ID and GITHUB_RUN_ATTEMPT must be positive integers." >&2
  exit 1
fi
UPLOAD_BUILD_NUMBER="${GITHUB_RUN_ID}.${GITHUB_RUN_ATTEMPT}"
if (( ${#UPLOAD_BUILD_NUMBER} > 18 )); then
  echo "error: computed iOS build number exceeds Apple's 18-character limit." >&2
  exit 1
fi

if [[ ! -r "$ASC_KEY_PATH" ]]; then
  echo "error: ASC authentication key is not readable at the configured path." >&2
  exit 1
fi

CI_KEYCHAIN_PATH="${BEID_CI_KEYCHAIN_PATH:-$HOME/Library/Keychains/beid-ci.keychain-db}"
: "${BEID_CI_KEYCHAIN_PASSWORD:?BEID_CI_KEYCHAIN_PASSWORD is missing from the runner environment}"

if [[ ! -r "$CI_KEYCHAIN_PATH" ]]; then
  echo "error: dedicated iOS signing keychain is not readable at the configured path." >&2
  exit 1
fi

echo "Unlocking the dedicated iOS signing keychain..."
security unlock-keychain -p "$BEID_CI_KEYCHAIN_PASSWORD" "$CI_KEYCHAIN_PATH"

SIGNING_IDENTITIES="$(security find-identity -v -p codesigning "$CI_KEYCHAIN_PATH")"
if ! grep -Fq "($BEID_TEAM_ID)" <<< "$SIGNING_IDENTITIES"; then
  echo "error: dedicated iOS signing keychain has no valid identity for the configured team." >&2
  exit 1
fi
echo "Dedicated iOS signing identity is available."

echo "Archiving Beid for a generic iOS device..."
# -quiet prevents xcodebuild's command-invocation banner from logging the
# runner-local authentication identifiers. Warnings and errors remain visible.
xcodebuild \
  -quiet \
  -project ios/Beid.xcodeproj \
  -scheme Beid \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY='Apple Distribution' \
  DEVELOPMENT_TEAM="$BEID_TEAM_ID" \
  BEID_PROVISIONING_PROFILE="$BEID_PROVISIONING_PROFILE" \
  CURRENT_PROJECT_VERSION="$UPLOAD_BUILD_NUMBER" \
  archive

ARCHIVED_APP_INFO="$ARCHIVE_PATH/Products/Applications/Beid.app/Info.plist"
if [[ ! -r "$ARCHIVED_APP_INFO" ]]; then
  echo "error: archived app Info.plist is missing." >&2
  exit 1
fi
ARCHIVED_MARKETING_VERSION="$(plutil -extract CFBundleShortVersionString raw "$ARCHIVED_APP_INFO")"
ARCHIVED_BUILD_NUMBER="$(plutil -extract CFBundleVersion raw "$ARCHIVED_APP_INFO")"
if [[ "$ARCHIVED_BUILD_NUMBER" != "$UPLOAD_BUILD_NUMBER" ]]; then
  echo "error: archived build number does not match this workflow run." >&2
  exit 1
fi

plutil -create xml1 "$EXPORT_OPTIONS"
plutil -insert method -string app-store-connect "$EXPORT_OPTIONS"
plutil -insert destination -string upload "$EXPORT_OPTIONS"
plutil -insert signingStyle -string manual "$EXPORT_OPTIONS"
plutil -insert signingCertificate -string 'Apple Distribution' "$EXPORT_OPTIONS"
plutil -insert provisioningProfiles -dictionary "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy \
  -c "Add :provisioningProfiles:$BEID_BUNDLE_ID string $BEID_PROVISIONING_PROFILE" \
  "$EXPORT_OPTIONS"
plutil -insert teamID -string "$BEID_TEAM_ID" "$EXPORT_OPTIONS"
plutil -insert manageAppVersionAndBuildNumber -bool NO "$EXPORT_OPTIONS"

echo "Uploading archive to App Store Connect..."
xcodebuild \
  -quiet \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"

scripts/gha/publish-testflight-notes.sh \
  "$TESTFLIGHT_NOTES_DIR" "$ARCHIVED_MARKETING_VERSION" "$ARCHIVED_BUILD_NUMBER"

echo "TestFlight upload and tester-note publication completed."
