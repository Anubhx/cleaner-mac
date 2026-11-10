#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/CleanerMac.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

ENTITLEMENTS_FILE="$ROOT_DIR/Resources/CleanerMac.entitlements"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
REQUIRE_DEVELOPER_ID="${REQUIRE_DEVELOPER_ID:-0}"

if [[ -z "$CODESIGN_IDENTITY" || "$CODESIGN_IDENTITY" == "-" ]]; then
  if [[ "$REQUIRE_DEVELOPER_ID" == "1" ]]; then
    echo "Error: REQUIRE_DEVELOPER_ID=1 requires CODESIGN_IDENTITY (e.g. 'Developer ID Application: Name (TEAMID)')." >&2
    exit 1
  fi
  SIGN_IDENTITY="-"
  IS_ADHOC=1
else
  SIGN_IDENTITY="$CODESIGN_IDENTITY"
  IS_ADHOC=0
fi

if ! command -v codesign >/dev/null 2>&1; then
  echo "Error: codesign tool not found." >&2
  exit 1
fi

cd "$ROOT_DIR"

echo "Building CleanerApp (arm64) in release configuration..."
swift build -c release --arch arm64 --product CleanerApp

BIN_PATH="$(swift build -c release --arch arm64 --show-bin-path)"
EXECUTABLE="$BIN_PATH/CleanerApp"

ICON_FILE="$ROOT_DIR/Resources/CleanerMac.icns"

if [[ ! -f "$EXECUTABLE" ]]; then
  echo "Error: CleanerApp binary not found at $EXECUTABLE" >&2
  exit 1
fi

if [[ ! -f "$ICON_FILE" ]]; then
  echo "Error: App icon not found at $ICON_FILE" >&2
  exit 1
fi

if [[ ! -f "$ENTITLEMENTS_FILE" ]]; then
  echo "Error: Entitlements file not found at $ENTITLEMENTS_FILE" >&2
  exit 1
fi

plutil -lint "$ENTITLEMENTS_FILE" >/dev/null

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR/Fonts"

cp "$EXECUTABLE" "$MACOS_DIR/CleanerApp"
chmod +x "$MACOS_DIR/CleanerApp"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ICON_FILE" "$RESOURCES_DIR/CleanerMac.icns"

plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null

cp "$ROOT_DIR"/Sources/CleanerUI/Resources/Fonts/*.ttf "$RESOURCES_DIR/Fonts/"
cp "$ROOT_DIR"/Sources/CleanerUI/Resources/Fonts/OFL.txt "$RESOURCES_DIR/Fonts/"

SIGN_COMMON_ARGS=(--force --sign "$SIGN_IDENTITY")
if [[ "$IS_ADHOC" -eq 0 ]]; then
  SIGN_COMMON_ARGS+=(--timestamp)
fi

# Inside-out signing: sign any nested Mach-O binaries or embedded bundles deepest-first,
# never using --deep, then sign the outer .app bundle last with Hardened Runtime + entitlements.
MAIN_EXECUTABLE="$MACOS_DIR/CleanerApp"

while IFS= read -r -d '' candidate; do
  if [[ "$candidate" == "$MAIN_EXECUTABLE" ]]; then
    continue
  fi
  if file -b "$candidate" | grep -q "Mach-O"; then
    if file -b "$candidate" | grep -q "Mach-O.*executable"; then
      codesign "${SIGN_COMMON_ARGS[@]}" --options runtime "$candidate"
    else
      codesign "${SIGN_COMMON_ARGS[@]}" "$candidate"
    fi
  fi
done < <(find "$CONTENTS_DIR" -type f ! -path "$CONTENTS_DIR/_CodeSignature/*" -print0 | LC_ALL=C sort -z)

while IFS= read -r -d '' bundle_item; do
  [[ -n "$bundle_item" ]] || continue
  codesign "${SIGN_COMMON_ARGS[@]}" --options runtime "$bundle_item"
done < <(
  find "$CONTENTS_DIR" -depth \
    \( -name "*.framework" -o -name "*.bundle" -o -name "*.xpc" -o -name "*.appex" -o -name "*.app" -o -name "*.plugin" \) \
    -print0
)

codesign "${SIGN_COMMON_ARGS[@]}" \
  --options runtime \
  --entitlements "$ENTITLEMENTS_FILE" \
  "$APP_BUNDLE"

codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE" >/dev/null

if [[ "$REQUIRE_DEVELOPER_ID" == "1" ]]; then
  SIGN_DETAILS="$(codesign -dvvv "$APP_BUNDLE" 2>&1)"
  if ! grep -q "Authority=Developer ID Application:" <<<"$SIGN_DETAILS"; then
    echo "Error: App is not signed with a Developer ID Application certificate." >&2
    exit 1
  fi
  if ! grep -Eq "flags=.*\(.*runtime.*\)" <<<"$SIGN_DETAILS"; then
    echo "Error: Hardened Runtime flag missing on signed bundle." >&2
    exit 1
  fi
  if grep -q "TeamIdentifier=not set" <<<"$SIGN_DETAILS"; then
    echo "Error: TeamIdentifier is missing on signed bundle." >&2
    exit 1
  fi
fi

echo "Created app bundle at: $APP_BUNDLE"
