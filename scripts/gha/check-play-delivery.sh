#!/bin/bash

set -euo pipefail

fail() {
  echo "error: $*" >&2
  exit 1
}

if [[ -z "${PLAY_CRED_DIR:-}" ]]; then
  fail "PLAY_CRED_DIR must point to the runner-local Play credential directory."
fi
PLAY_ENV_FILE="$PLAY_CRED_DIR/env"

if [[ ! -r "$PLAY_ENV_FILE" ]]; then
  fail "Play credential environment file is not readable: $PLAY_ENV_FILE. Ken must place the upload-keystore and service-account paths in this runner-local file."
fi

set -a
# The source path is runner-local and supplied by PLAY_CRED_DIR.
# shellcheck disable=SC1090
source "$PLAY_ENV_FILE"
set +a

required_variables=(
  PLAY_SERVICE_ACCOUNT_JSON
  PLAY_KEYSTORE_PATH
  PLAY_KEY_ALIAS
  PLAY_KEYSTORE_PASSWORD
  PLAY_KEY_PASSWORD
)

for variable_name in "${required_variables[@]}"; do
  if [[ -z "${!variable_name:-}" ]]; then
    fail "$variable_name is missing from the runner-local Play environment file."
  fi
done

if [[ ! -r "$PLAY_SERVICE_ACCOUNT_JSON" ]]; then
  fail "Play service-account JSON is not readable at the configured runner-local path."
fi

if [[ ! -r "$PLAY_KEYSTORE_PATH" ]]; then
  fail "Play upload keystore is not readable at the configured runner-local path."
fi

python3 - "$PLAY_SERVICE_ACCOUNT_JSON" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError) as exc:
    raise SystemExit(f"error: configured Play service-account file is not valid JSON: {exc}")

missing = [key for key in ("client_email", "private_key", "token_uri") if not data.get(key)]
if missing:
    raise SystemExit(
        "error: configured Play service-account JSON is missing required fields: "
        + ", ".join(missing)
    )
PY

if [[ -n "${KMP_JAVA_HOME:-}" && -x "$KMP_JAVA_HOME/bin/keytool" ]]; then
  keytool_bin="$KMP_JAVA_HOME/bin/keytool"
elif command -v keytool >/dev/null 2>&1; then
  keytool_bin="$(command -v keytool)"
else
  fail "keytool is unavailable; KMP_JAVA_HOME must point to the runner JDK 17."
fi

if ! "$keytool_bin" \
  -list \
  -keystore "$PLAY_KEYSTORE_PATH" \
  -storepass:env PLAY_KEYSTORE_PASSWORD \
  -alias "$PLAY_KEY_ALIAS" \
  >/dev/null; then
  fail "Play upload keystore could not be opened with the configured alias and password."
fi

if [[ -n "${GITHUB_ENV:-}" ]]; then
  case "$PLAY_SERVICE_ACCOUNT_JSON" in
    *$'\n'*) fail "PLAY_SERVICE_ACCOUNT_JSON path must not contain a newline." ;;
  esac
  printf 'PLAY_SERVICE_ACCOUNT_JSON=%s\n' "$PLAY_SERVICE_ACCOUNT_JSON" >> "$GITHUB_ENV"
fi

echo "Runner-local Play credentials are readable and internally consistent."
