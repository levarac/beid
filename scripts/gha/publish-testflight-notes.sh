#!/bin/zsh

set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "usage: $0 <prepared-notes-dir> <upload-started-at-rfc3339>" >&2
  exit 64
fi

NOTES_DIR="$1"
UPLOAD_STARTED_AT="$2"
BEID_BUNDLE_ID="${BEID_BUNDLE_ID:-org.levarac.beid}"
RUN_TEMP_ROOT="${RUNNER_TEMP:-/tmp}"

: "${ASC_KEY_ID:?ASC_KEY_ID is required to publish TestFlight notes}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID is required to publish TestFlight notes}"
: "${ASC_KEY_PATH:?ASC_KEY_PATH is required to publish TestFlight notes}"

if [[ ! -r "$ASC_KEY_PATH" ]]; then
  echo "error: ASC authentication key is not readable at the configured path." >&2
  exit 1
fi
if ! command -v asc >/dev/null 2>&1; then
  echo "error: asc CLI is required to publish TestFlight notes." >&2
  exit 1
fi

NOTE_FILES=("$NOTES_DIR"/WhatToTest.*.txt(N))
if (( ${#NOTE_FILES[@]} == 0 )); then
  echo "error: no prepared TestFlight notes found in $NOTES_DIR" >&2
  exit 1
fi

# Reuse the same runner-local API key already loaded by
# build-and-upload-ios.sh. Bypass Keychain profiles so a runner default cannot
# silently select a different App Store Connect team.
export ASC_PRIVATE_KEY_PATH="$ASC_KEY_PATH"
export ASC_BYPASS_KEYCHAIN=1
export ASC_STRICT_AUTH=true

WAIT_RESULT="$(mktemp "$RUN_TEMP_ROOT/beid-asc-build-wait.XXXXXX")"
cleanup() {
  rm -f -- "$WAIT_RESULT"
}
trap cleanup EXIT

asc builds wait \
  --app "$BEID_BUNDLE_ID" \
  --latest \
  --platform IOS \
  --since "$UPLOAD_STARTED_AT" \
  --timeout "${ASC_BUILD_WAIT_TIMEOUT:-30m}" \
  --poll-interval "${ASC_BUILD_POLL_INTERVAL:-30s}" \
  --fail-on-invalid \
  --output json > "$WAIT_RESULT"

BUILD_ID="$(python3 - "$WAIT_RESULT" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
build_id = result.get("buildId")
state = result.get("processingState")
if not isinstance(build_id, str) or not build_id.strip():
    raise SystemExit("asc builds wait returned no buildId")
if state != "VALID":
    raise SystemExit(f"asc builds wait returned unexpected state: {state!r}")
print(build_id.strip())
PY
)"

for note_file in "${NOTE_FILES[@]}"; do
  file_name="${note_file:t}"
  locale="${file_name#WhatToTest.}"
  locale="${locale%.txt}"
  note_text="$(< "$note_file")"
  if [[ -z "${note_text//[[:space:]]/}" ]]; then
    echo "error: prepared TestFlight note is empty: $note_file" >&2
    exit 1
  fi

  asc builds test-notes create \
    --build-id "$BUILD_ID" \
    --locale "$locale" \
    --whats-new "$note_text" \
    --output json >/dev/null
  echo "Published TestFlight notes for locale $locale to build $BUILD_ID."
done
