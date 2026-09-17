#!/usr/bin/env bash
# Use of this source code is governed by a BSD-style license.
#
# Bundle beid-lab-cli and launch it, passing every remaining argument through.
#
# stdout belongs to the CLI alone: it is JSON lines and a caller greps or pipes
# it, so build output goes to stderr instead.
#
#   ./scripts/run.sh --codesign-identity "Apple Development: ..." \
#       observe --timeout 60 --log ~/observe.jsonl
#   ./scripts/run.sh --build-only
#   ./scripts/run.sh --skip-build participate --event-code BND --timeout 120
#
# --codesign-identity and --log are the two arguments a remote operator needs,
# so both are accepted here: the identity is consumed by this script, and --log
# is forwarded to the binary, which writes the file itself.
#
# CONFIGURATION, CODESIGN_IDENTITY, BUILD_DIR and APP_DIR are passed through to
# bundle.sh. CODESIGN_IDENTITY remains honoured as a fallback so an existing
# device-lab orchestrator keeps working unchanged.
#
# Exits with the CLI's own exit code: 0 ran the window, 1 usage or harness, 2
# expectation not met, 3 Bluetooth unavailable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BINARY_NAME="beid-lab-cli"
APP_DIR="${APP_DIR:-$TOOL_DIR/build}"
APP_BINARY="$APP_DIR/BeidLabCli.app/Contents/MacOS/$BINARY_NAME"

BUILD_ONLY=0
SKIP_BUILD="${SKIP_BUILD:-0}"
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --codesign-identity)
      if [ $# -lt 2 ]; then
        echo "run.sh: --codesign-identity needs a value" >&2
        exit 1
      fi
      CODESIGN_IDENTITY="$2"
      export CODESIGN_IDENTITY
      shift 2
      ;;
    --build-only)
      BUILD_ONLY=1
      shift
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --)
      shift
      args+=("$@")
      break
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done

if [ "$SKIP_BUILD" != "1" ]; then
  # bundle.sh prints the built binary path on stdout and everything else on
  # stderr, so capturing it here keeps the build off our stdout.
  if ! APP_BINARY="$("$SCRIPT_DIR/bundle.sh")"; then
    echo "run.sh: build failed" >&2
    exit 1
  fi
fi

if [ "$BUILD_ONLY" = "1" ]; then
  echo "[run.sh] built $APP_BINARY" >&2
  exit 0
fi

if [ ! -x "$APP_BINARY" ]; then
  echo "run.sh: bundled binary not found at $APP_BINARY" >&2
  exit 1
fi

# exec so a backgrounded PID is the CLI itself and a SIGTERM reaches its own
# signal handler rather than this wrapper. That matters over ssh: the handler
# is what stops the radio and writes the closing result line.
echo "[run.sh] launching $APP_BINARY" >&2
exec "$APP_BINARY" ${args[@]+"${args[@]}"}
