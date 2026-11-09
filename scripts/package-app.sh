#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/CleanerMac.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$ROOT_DIR"

echo "Building CleanerApp in release configuration..."
swift build -c release --product CleanerApp

BIN_PATH="$(swift build -c release --show-bin-path)"
EXECUTABLE="$BIN_PATH/CleanerApp"
RESOURCE_BUNDLE="$BIN_PATH/CleanerMac_CleanerUI.bundle"

if [[ ! -f "$EXECUTABLE" ]]; then
  echo "Error: CleanerApp binary not found at $EXECUTABLE" >&2
  exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR/Fonts"

cp "$EXECUTABLE" "$MACOS_DIR/CleanerApp"
chmod +x "$MACOS_DIR/CleanerApp"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"

cp "$ROOT_DIR"/Sources/CleanerUI/Resources/Fonts/*.ttf "$RESOURCES_DIR/Fonts/"
cp "$ROOT_DIR"/Sources/CleanerUI/Resources/Fonts/OFL.txt "$RESOURCES_DIR/Fonts/"

if [[ -d "$RESOURCE_BUNDLE" ]]; then
  cp -R "$RESOURCE_BUNDLE" "$RESOURCES_DIR/"
fi

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null
fi

echo "Created app bundle at: $APP_BUNDLE"
