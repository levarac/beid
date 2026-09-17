#!/usr/bin/env bash
# Use of this source code is governed by a BSD-style license.
#
# Build beid-lab-cli with SwiftPM and assemble it into BeidLabCli.app.
#
# The .app wrapper is not cosmetic. macOS keys the Bluetooth grant to a bundle
# identity plus a code signature, so a bare executable is treated as a
# different, unnamed thing on every run and is prompted for (or refused)
# differently each time. Info.plist is written here rather than checked in
# because it has to agree with the built binary's name.
#
# Nothing here needs Xcode's build system, XcodeGen, DerivedData or the
# repository's Xcode project: `swift build` and `codesign` are the whole
# toolchain, which is what makes the result copyable to another Mac.
#
# Environment (all optional):
#   CONFIGURATION       debug or release (default: release)
#   CODESIGN_IDENTITY   signing identity; ad-hoc "-" when unset. A stable
#                       identity is what makes the Bluetooth grant survive a
#                       rebuild, so a lab host should set it.
#   BUILD_DIR           SwiftPM scratch path (default: ./.build)
#   APP_DIR             where BeidLabCli.app is assembled (default: ./build)
#
# Prints the bundled binary's path on stdout. Everything else goes to stderr,
# so a caller can capture the path without capturing the build.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BINARY_NAME="beid-lab-cli"
# Must match `LabBundle.identifier` in Sources/beid-lab-cli/EngineLogging.swift.
# The two agreeing is what makes the Bluetooth grant survive a rebuild.
BUNDLE_ID="org.levarac.beid.LabCli"
CONFIGURATION="${CONFIGURATION:-release}"
BUILD_DIR="${BUILD_DIR:-$TOOL_DIR/.build}"
APP_DIR="${APP_DIR:-$TOOL_DIR/build}"
APP="$APP_DIR/BeidLabCli.app"

cd "$TOOL_DIR"

swift build -c "$CONFIGURATION" --scratch-path "$BUILD_DIR" >&2
BINARY="$(swift build -c "$CONFIGURATION" --scratch-path "$BUILD_DIR" --show-bin-path)/$BINARY_NAME"
if [ ! -x "$BINARY" ]; then
  echo "bundle.sh: built binary not found at $BINARY" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BINARY" "$APP/Contents/MacOS/$BINARY_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key>
  <string>$BINARY_NAME</string>
  <key>CFBundleName</key>
  <string>BeidLabCli</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <!-- Headless: no Dock icon and no menu bar. This is driven over ssh. -->
  <key>LSUIElement</key>
  <true/>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>beid-lab-cli uses Bluetooth to observe, serve and join beid events during a device-lab measurement.</string>
</dict>
</plist>
PLIST

# Ad-hoc by default so this builds on any Mac and in CI with no keychain. An
# ad-hoc signature changes on every rebuild, which drops the Bluetooth grant;
# CODESIGN_IDENTITY is how a lab host avoids that.
IDENTITY="${CODESIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP" >&2
echo "[bundle.sh] signed $APP as $BUNDLE_ID with identity: ${CODESIGN_IDENTITY:-ad-hoc}" >&2

echo "$APP/Contents/MacOS/$BINARY_NAME"
