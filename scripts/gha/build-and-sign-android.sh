#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

fail() {
  echo "error: $*" >&2
  exit 1
}

"$SCRIPT_DIR/check-play-delivery.sh"

# Load the same runner-local values checked above. No credential value is
# printed or passed directly on a process command line.
set -a
# shellcheck disable=SC1091
source "$PLAY_CRED_DIR/env"
set +a

: "${ANDROID_HOME:?ANDROID_HOME must point to the runner-local Android SDK}"
if [[ ! -d "$ANDROID_HOME/platforms/android-36" ]]; then
  fail "Android platform 36 is missing under ANDROID_HOME."
fi
if [[ ! -d "$ANDROID_HOME/build-tools/36.0.0" ]]; then
  fail "Android build-tools 36.0.0 are missing under ANDROID_HOME."
fi

KMP_JAVA_HOME="$("$REPO_ROOT/scripts/resolve_kmp_java_home.sh")"
export KMP_JAVA_HOME
export JAVA_HOME="$KMP_JAVA_HOME"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$PATH"

run_number="${GITHUB_RUN_NUMBER:-}"
run_attempt="${GITHUB_RUN_ATTEMPT:-1}"
if [[ ! "$run_number" =~ ^[1-9][0-9]*$ || ! "$run_attempt" =~ ^[1-9][0-9]*$ ]]; then
  fail "GITHUB_RUN_NUMBER and GITHUB_RUN_ATTEMPT must be positive integers."
fi

version_code=$((1000000000 + run_number * 10 + run_attempt))
if (( version_code > 2100000000 )); then
  fail "Computed Android versionCode exceeds the Google Play limit."
fi
export BEID_ANDROID_VERSION_CODE="$version_code"

# The git height is computed by the workflow (which owns the checkout depth that
# makes it correct) and arrives here through the environment. Under CI its
# absence is a hard failure rather than a fallback to "local": a delivered build
# that calls itself local is worse than a red one, and it is exactly the silent
# degradation this key exists to make impossible. Outside CI the flag is omitted
# so a developer's local build gets Gradle's own "local" default (beid#491).
gradle_height_args=()
if [[ -n "${BEID_GIT_HEIGHT:-}" ]]; then
  gradle_height_args=("-PgitHeight=${BEID_GIT_HEIGHT}")
elif [[ -n "${CI:-}" ]]; then
  fail "BEID_GIT_HEIGHT is unset under CI; refusing to deliver a build whose version row would read 'local'."
fi

echo "Building Android release AAB with versionCode $version_code..."
(
  cd "$REPO_ROOT/android"
  ./gradlew \
    :app:bundleRelease \
    -I "$SCRIPT_DIR/android-version-code.init.gradle" \
    "${gradle_height_args[@]}" \
    --no-daemon
)

aab_path="$REPO_ROOT/android/app/build/outputs/bundle/release/app-release.aab"
manifest_path="$REPO_ROOT/android/app/build/intermediates/bundle_manifest/release/processApplicationManifestReleaseForBundle/AndroidManifest.xml"

if [[ ! -s "$aab_path" ]]; then
  fail "Gradle did not produce the expected release AAB."
fi

python3 - "$manifest_path" "$version_code" <<'PY'
import sys
import xml.etree.ElementTree as ET

manifest_path, expected = sys.argv[1:]
try:
    root = ET.parse(manifest_path).getroot()
except (OSError, ET.ParseError) as exc:
    raise SystemExit(f"error: generated Android manifest could not be inspected: {exc}")

actual = root.attrib.get("{http://schemas.android.com/apk/res/android}versionCode")
if actual != expected:
    raise SystemExit(
        f"error: generated AAB manifest has versionCode {actual!r}; expected {expected!r}"
    )
PY

echo "Signing the AAB with the runner-local upload key..."
jarsigner \
  -keystore "$PLAY_KEYSTORE_PATH" \
  -storepass:env PLAY_KEYSTORE_PASSWORD \
  -keypass:env PLAY_KEY_PASSWORD \
  "$aab_path" \
  "$PLAY_KEY_ALIAS"

verification_output="$(mktemp "${RUNNER_TEMP:-/tmp}/beid-aab-signature.XXXXXX")"
trap 'rm -f -- "$verification_output"' EXIT
jarsigner -verify -verbose -certs "$aab_path" > "$verification_output"
if ! grep -q '^jar verified' "$verification_output" || grep -q 'jar is unsigned' "$verification_output"; then
  fail "The release AAB does not contain a verifiable JAR signature."
fi

if [[ -n "${GITHUB_ENV:-}" ]]; then
  case "$aab_path" in
    *$'\n'*) fail "AAB path must not contain a newline." ;;
  esac
  {
    printf 'ANDROID_AAB_PATH=%s\n' "$aab_path"
    printf 'ANDROID_VERSION_CODE=%s\n' "$version_code"
  } >> "$GITHUB_ENV"
fi

echo "Signed Android release AAB is ready for Google Play upload."
