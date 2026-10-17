#!/usr/bin/env bash
# Production-style Release build: sync App Icon PNGs, xcodebuild archive, copy .app, zip for distribution.
# Usage: from repo root, `bash scripts/build-release.sh`
#
# Signing (default): Developer ID Application + Manual via scripts/lib/signing.sh
#   Copy .pingstat-signing.env.example → .pingstat-signing.env and set DEVELOPMENT_TEAM (or rely on keychain auto-detect).
#   PINGSTAT_ADHOC_SIGN=1 — ad-hoc only (unsigned distribution); skips Developer ID verification.
#
# Notarization (optional): PINGSTAT_NOTARIZE=1 plus NOTARY_KEYCHAIN_PROFILE or API key / Apple ID vars (see script tail).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PINGSTAT_ROOT="$ROOT"
cd "$ROOT"

# shellcheck source=lib/signing.sh
source "$ROOT/scripts/lib/signing.sh"
pingstat_source_signing_env

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild not found. Install full Xcode and run xcode-select." >&2
  exit 1
fi
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not found. Install with: brew install xcodegen" >&2
  exit 1
fi

echo "==> xcodegen generate"
xcodegen generate >/dev/null

echo "==> Syncing App Icon sizes from Design/PingStat-app-icon-master.png"
bash "$ROOT/scripts/sync-app-icons.sh"

DERIVED="$ROOT/.build/ReleaseDerivedData"
ARCHIVE="$ROOT/.build/PingStat.xcarchive"
DIST="$ROOT/dist"
rm -rf "$DERIVED" "$ARCHIVE" "$DIST/PingStat.app"
mkdir -p "$DIST" "$ROOT/.build"

if ! pingstat_build_xcode_sign_args; then
  exit 1
fi
SIGN_ARGS=("${PINGSTAT_XCODE_SIGN_ARGS[@]}")

echo "==> xcodebuild archive (Release, generic macOS)"
xcodebuild \
  -project "$ROOT/PingStat.xcodeproj" \
  -scheme PingStat \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED" \
  -archivePath "$ARCHIVE" \
  "${SIGN_ARGS[@]}" \
  archive

APP_IN_ARCHIVE="$ARCHIVE/Products/Applications/PingStat.app"
if [[ ! -d "$APP_IN_ARCHIVE" ]]; then
  echo "error: expected app at $APP_IN_ARCHIVE" >&2
  exit 1
fi

cp -R "$APP_IN_ARCHIVE" "$DIST/PingStat.app"

if [[ "${PINGSTAT_ADHOC_SIGN:-}" == "1" ]]; then
  pingstat_verify_app_signature "$DIST/PingStat.app" adhoc
else
  pingstat_verify_app_signature "$DIST/PingStat.app" developer-id
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$DIST/PingStat.app/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$DIST/PingStat.app/Contents/Info.plist")
ZIP_NAME="PingStat-${VERSION}-${BUILD}.zip"
ZIP="$DIST/$ZIP_NAME"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$DIST/PingStat.app" "$ZIP"

if [[ "${PINGSTAT_NOTARIZE:-}" == "1" ]]; then
  if [[ "${PINGSTAT_ADHOC_SIGN:-}" == "1" ]]; then
    echo "error: PINGSTAT_NOTARIZE=1 is incompatible with PINGSTAT_ADHOC_SIGN=1" >&2
    exit 1
  fi
  echo "==> Notarization: submitting $ZIP (notarytool --wait)"
  NOTARY_CMD=(xcrun notarytool submit "$ZIP" --wait)
  if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    NOTARY_CMD+=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
  elif [[ -n "${NOTARY_API_KEY_ID:-}" && -n "${NOTARY_API_ISSUER:-}" && -n "${NOTARY_API_KEY_PATH:-}" ]]; then
    NOTARY_CMD+=(--key "$NOTARY_API_KEY_PATH" --key-id "$NOTARY_API_KEY_ID" --issuer "$NOTARY_API_ISSUER")
  elif [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]]; then
    NOTARY_TEAM="${NOTARY_TEAM_ID:-${DEVELOPMENT_TEAM:-}}"
    if [[ -z "${NOTARY_TEAM}" ]]; then
      echo "error: PINGSTAT_NOTARIZE=1 with apple-id auth needs NOTARY_TEAM_ID or DEVELOPMENT_TEAM" >&2
      exit 1
    fi
    NOTARY_CMD+=(--apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$NOTARY_TEAM")
  else
    echo "error: PINGSTAT_NOTARIZE=1 needs one of:" >&2
    echo "  NOTARY_KEYCHAIN_PROFILE, or" >&2
    echo "  NOTARY_API_KEY_ID + NOTARY_API_ISSUER + NOTARY_API_KEY_PATH, or" >&2
    echo "  NOTARY_APPLE_ID + NOTARY_PASSWORD (+ NOTARY_TEAM_ID or DEVELOPMENT_TEAM)" >&2
    exit 1
  fi
  if ! "${NOTARY_CMD[@]}"; then
    ec=$?
    if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
      echo "" >&2
      echo "Keychain profile \"${NOTARY_KEYCHAIN_PROFILE}\" is missing or wrong. Create it once (same name):" >&2
      echo "  xcrun notarytool store-credentials \"${NOTARY_KEYCHAIN_PROFILE}\" \\" >&2
      echo "    --apple-id \"YOUR_APPLE_ID\" --team-id \"${DEVELOPMENT_TEAM:-YOUR_TEAM_ID}\"   # omit --password for secure prompt" >&2
    fi
    exit "$ec"
  fi
  echo "==> Stapling notarization ticket to $DIST/PingStat.app"
  xcrun stapler staple "$DIST/PingStat.app"
  xcrun stapler validate "$DIST/PingStat.app"
  echo "==> Recreating zip after staple (ticket is inside the app bundle)"
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$DIST/PingStat.app" "$ZIP"
fi

echo ""
echo "Built: $DIST/PingStat.app"
echo "Zip:   $ZIP"
echo ""
if [[ "${PINGSTAT_KEEP_DIST_APP:-}" != "1" ]]; then
  echo "==> Removing $DIST/PingStat.app (keeps zip only; avoids duplicate Menu Bar rows on macOS 26)"
  echo "    Set PINGSTAT_KEEP_DIST_APP=1 to leave dist/PingStat.app in place."
  rm -rf "$DIST/PingStat.app"
  touch "$DIST/.metadata_never_index" 2>/dev/null || true
fi
echo ""
echo "Install: ditto dist/PingStat-*.zip or run scripts/reset-pingstat-install.sh"
echo "         (only /Applications/PingStat.app should remain for daily use)"
echo "GitHub:  ./scripts/release.sh from a clean tree to bump version, test, build zip + DMG, and publish."
