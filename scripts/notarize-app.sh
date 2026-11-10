#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/CleanerMac.app"
FINAL_ZIP_PATH="$DIST_DIR/CleanerMac.zip"
DMG_PATH="$DIST_DIR/CleanerMac.dmg"

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-}"
NOTARY_KEYCHAIN="${NOTARY_KEYCHAIN:-}"
NOTARY_API_KEY_PATH="${NOTARY_API_KEY_PATH:-}"
NOTARY_API_KEY_ID="${NOTARY_API_KEY_ID:-}"
NOTARY_API_ISSUER_ID="${NOTARY_API_ISSUER_ID:-}"
NOTARY_TIMEOUT="${NOTARY_TIMEOUT:-30m}"
SKIP_BUILD="${SKIP_BUILD:-0}"
CREATE_DMG="${CREATE_DMG:-0}"

usage() {
  cat <<'EOF'
Usage: scripts/notarize-app.sh [--help]

Build (unless SKIP_BUILD=1), Developer ID sign, notarize with Apple Notary
service via `xcrun notarytool`, staple, and verify dist/CleanerMac.app.

Required environment variables:
  CODESIGN_IDENTITY        Developer ID Application signing identity
                           (required unless SKIP_BUILD=1 and CREATE_DMG=0).

Authentication (choose one; store secrets outside the repository):
  Option 1 (Keychain profile created via `xcrun notarytool store-credentials`):
    NOTARY_KEYCHAIN_PROFILE   Profile name stored in Keychain
    NOTARY_KEYCHAIN           Optional path to custom keychain file

  Option 2 (App Store Connect API key):
    NOTARY_API_KEY_PATH       Path to .p8 private key file
    NOTARY_API_KEY_ID         App Store Connect API Key ID
    NOTARY_API_ISSUER_ID      Issuer UUID (required for Team keys; omit for Individual keys)

Optional environment variables:
  SKIP_BUILD=1             Reuse and verify an existing Developer ID signed dist/CleanerMac.app
  CREATE_DMG=1             Also build, Developer ID sign, notarize, and staple dist/CleanerMac.dmg
  NOTARY_TIMEOUT=30m       Wait timeout passed to `xcrun notarytool submit --wait` (default: 30m)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
elif [[ $# -gt 0 ]]; then
  echo "Error: Unknown argument '$1'. Run with --help for usage." >&2
  exit 1
fi

for required_cmd in codesign xcrun ditto plutil spctl; do
  if ! command -v "$required_cmd" >/dev/null 2>&1; then
    echo "Error: Required tool '$required_cmd' not found." >&2
    exit 1
  fi
done

if ! xcrun --find notarytool >/dev/null 2>&1 || ! xcrun --find stapler >/dev/null 2>&1; then
  echo "Error: Xcode / Command Line Tools must provide 'notarytool' and 'stapler'." >&2
  exit 1
fi

if [[ "$CREATE_DMG" == "1" ]] && ! command -v hdiutil >/dev/null 2>&1; then
  echo "Error: CREATE_DMG=1 requires hdiutil." >&2
  exit 1
fi

if [[ "$SKIP_BUILD" != "1" ]]; then
  if [[ -z "$CODESIGN_IDENTITY" || "$CODESIGN_IDENTITY" == "-" ]]; then
    echo "Error: CODESIGN_IDENTITY must be set to a 'Developer ID Application' identity (unless SKIP_BUILD=1)." >&2
    exit 1
  fi
fi

if [[ "$CREATE_DMG" == "1" ]]; then
  if [[ -z "$CODESIGN_IDENTITY" || "$CODESIGN_IDENTITY" == "-" ]]; then
    echo "Error: CREATE_DMG=1 requires CODESIGN_IDENTITY to sign dist/CleanerMac.dmg." >&2
    exit 1
  fi
fi

NOTARY_AUTH_ARGS=()
if [[ -n "$NOTARY_KEYCHAIN_PROFILE" ]]; then
  NOTARY_AUTH_ARGS=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
  if [[ -n "$NOTARY_KEYCHAIN" ]]; then
    if [[ ! -f "$NOTARY_KEYCHAIN" ]]; then
      echo "Error: NOTARY_KEYCHAIN file not found at $NOTARY_KEYCHAIN" >&2
      exit 1
    fi
    NOTARY_AUTH_ARGS+=(--keychain "$NOTARY_KEYCHAIN")
  fi
elif [[ -n "$NOTARY_API_KEY_PATH" || -n "$NOTARY_API_KEY_ID" ]]; then
  if [[ -z "$NOTARY_API_KEY_PATH" || -z "$NOTARY_API_KEY_ID" ]]; then
    echo "Error: Both NOTARY_API_KEY_PATH and NOTARY_API_KEY_ID must be set for API key authentication." >&2
    exit 1
  fi
  if [[ ! -f "$NOTARY_API_KEY_PATH" ]]; then
    echo "Error: App Store Connect API key file not found at $NOTARY_API_KEY_PATH" >&2
    exit 1
  fi
  NOTARY_AUTH_ARGS=(--key "$NOTARY_API_KEY_PATH" --key-id "$NOTARY_API_KEY_ID")
  if [[ -n "$NOTARY_API_ISSUER_ID" ]]; then
    NOTARY_AUTH_ARGS+=(--issuer "$NOTARY_API_ISSUER_ID")
  fi
else
  echo "Error: Configure notarization auth via NOTARY_KEYCHAIN_PROFILE or NOTARY_API_KEY_PATH + NOTARY_API_KEY_ID." >&2
  exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cleanermac-notary.XXXXXX")"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

verify_developer_id_app() {
  local bundle_path="$1"

  if [[ ! -d "$bundle_path" ]]; then
    echo "Error: App bundle not found at $bundle_path" >&2
    exit 1
  fi

  codesign --verify --deep --strict --verbose=4 "$bundle_path" >/dev/null

  local sign_details
  sign_details="$(codesign -dvvv "$bundle_path" 2>&1)"

  if ! grep -q "Authority=Developer ID Application:" <<<"$sign_details"; then
    echo "Error: $bundle_path is not signed with a Developer ID Application certificate." >&2
    exit 1
  fi
  if ! grep -Eq "flags=.*\(.*runtime.*\)" <<<"$sign_details"; then
    echo "Error: Hardened Runtime flag missing on $bundle_path." >&2
    exit 1
  fi
  if grep -q "TeamIdentifier=not set" <<<"$sign_details"; then
    echo "Error: TeamIdentifier is missing on $bundle_path." >&2
    exit 1
  fi
  if ! grep -q "^Timestamp=" <<<"$sign_details"; then
    echo "Error: Secure timestamp missing on $bundle_path (sign with --timestamp)." >&2
    exit 1
  fi
}

submit_and_wait() {
  local artifact_path="$1"
  local label="$2"

  echo "Submitting $label to Apple Notary service (timeout: $NOTARY_TIMEOUT)..."
  local stdout_file="$WORK_DIR/notary-stdout.json"
  local stderr_file="$WORK_DIR/notary-stderr.log"
  local submit_exit
  set +e
  xcrun notarytool submit "$artifact_path" \
    "${NOTARY_AUTH_ARGS[@]}" \
    --wait \
    --timeout "$NOTARY_TIMEOUT" \
    --output-format json >"$stdout_file" 2>"$stderr_file"
  submit_exit=$?
  set -e

  local submission_status submission_id
  submission_status="$(plutil -extract status raw "$stdout_file" 2>/dev/null || true)"
  submission_id="$(plutil -extract id raw "$stdout_file" 2>/dev/null || true)"

  if [[ $submit_exit -ne 0 || "$submission_status" != "Accepted" ]]; then
    echo "Error: Notarization failed for $label (exit=$submit_exit, status=${submission_status:-unknown})." >&2
    [[ -s "$stdout_file" ]] && cat "$stdout_file" >&2
    [[ -s "$stderr_file" ]] && cat "$stderr_file" >&2
    if [[ -n "$submission_id" ]]; then
      echo "Fetching notarization log for submission $submission_id..." >&2
      xcrun notarytool log "$submission_id" "${NOTARY_AUTH_ARGS[@]}" >&2 || true
    fi
    exit 1
  fi

  echo "Notarization Accepted for $label (submission id: ${submission_id:-unknown})."
}

cd "$ROOT_DIR"

if [[ "$SKIP_BUILD" != "1" ]]; then
  REQUIRE_DEVELOPER_ID=1 CODESIGN_IDENTITY="$CODESIGN_IDENTITY" "$ROOT_DIR/scripts/package-app.sh"
fi

verify_developer_id_app "$APP_BUNDLE"

SUBMIT_ZIP="$WORK_DIR/CleanerMac-notary-upload.zip"
echo "Archiving signed app for notarization upload..."
ditto -c -k --keepParent "$APP_BUNDLE" "$SUBMIT_ZIP"

submit_and_wait "$SUBMIT_ZIP" "CleanerMac.app"

echo "Stapling notarization ticket to $APP_BUNDLE..."
xcrun stapler staple "$APP_BUNDLE"
xcrun stapler validate "$APP_BUNDLE"

echo "Verifying code signature and Gatekeeper assessment..."
codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE"
spctl_output="$(spctl --assess --type execute --ignore-cache --verbose "$APP_BUNDLE" 2>&1)"
echo "$spctl_output"
if ! grep -q "accepted" <<<"$spctl_output" || ! grep -q "source=Notarized Developer ID" <<<"$spctl_output"; then
  echo "Error: Gatekeeper did not report accepted / source=Notarized Developer ID for $APP_BUNDLE." >&2
  exit 1
fi

echo "Creating stapled distribution archive at $FINAL_ZIP_PATH..."
rm -f "$FINAL_ZIP_PATH"
ditto -c -k --keepParent "$APP_BUNDLE" "$FINAL_ZIP_PATH"

if [[ "$CREATE_DMG" == "1" ]]; then
  DMG_STAGE="$WORK_DIR/dmg-staging"
  mkdir -p "$DMG_STAGE"
  ditto "$APP_BUNDLE" "$DMG_STAGE/CleanerMac.app"
  ln -s /Applications "$DMG_STAGE/Applications"

  echo "Creating UDZO disk image at $DMG_PATH..."
  rm -f "$DMG_PATH"
  hdiutil create -volname "CleanerMac" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null

  echo "Signing $DMG_PATH with Developer ID..."
  codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$DMG_PATH"
  codesign --verify --strict --verbose=4 "$DMG_PATH" >/dev/null

  submit_and_wait "$DMG_PATH" "CleanerMac.dmg"

  echo "Stapling notarization ticket to $DMG_PATH..."
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"

  dmg_spctl_output="$(spctl --assess --type open --context context:primary-signature --ignore-cache --verbose "$DMG_PATH" 2>&1)"
  echo "$dmg_spctl_output"
  if ! grep -q "accepted" <<<"$dmg_spctl_output"; then
    echo "Error: Gatekeeper assessment did not accept $DMG_PATH." >&2
    exit 1
  fi
fi

echo "Notarization and verification complete."
echo "  App bundle: $APP_BUNDLE"
echo "  Zip archive: $FINAL_ZIP_PATH"
if [[ "$CREATE_DMG" == "1" ]]; then
  echo "  Disk image:  $DMG_PATH"
fi
