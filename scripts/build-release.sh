#!/usr/bin/env bash
# Production-style Release build: sync App Icon PNGs, xcodebuild archive, copy .app, zip for distribution.
# Usage: from repo root, `bash scripts/build-release.sh`
#
# Signing:
#   PINGSTAT_ADHOC_SIGN=1 — ad-hoc only (CODE_SIGN_IDENTITY=-), no Apple Developer Program.
#   Otherwise (default): use Xcode automatic signing if the project + machine have a valid identity.
#   With a paid Apple Developer account, typical setups:
#     export DEVELOPMENT_TEAM=ABCDE12345
#     — alone: Xcode Automatic signing (usually Apple Development for Release archive; needs that cert).
#     export PINGSTAT_DEVELOPER_ID=1  # same team, plus a "Developer ID Application" cert in your keychain
#     — adds CODE_SIGN_IDENTITY=Developer ID Application + CODE_SIGN_STYLE=Manual for distributable builds.
#     Or set CODE_SIGN_IDENTITY yourself (e.g. full "Developer ID Application: Name (TEAMID)").
#   Optional: export CODE_SIGN_STYLE=Manual
#   Tip: put exports in a gitignored file and `source` it before this script, e.g. `source ./.pingstat-signing.env`
#
# Notarization (optional, after zip is built; Developer ID–signed app recommended):
#   export PINGSTAT_NOTARIZE=1
#   Auth (pick one):
#     NOTARY_KEYCHAIN_PROFILE — create once (name is arbitrary but must match this var).
#       Prefer no --password on the command line: notarytool then prompts securely (nothing sensitive in shell history):
#         xcrun notarytool store-credentials "PingStat-notary" --apple-id "you@example.com" --team-id "34S6MQZHXC"
#       Or read password from Keychain: --password "@keychain:ITEM_NAME"
#       Xcode: Product → Archive → Distribute App → Developer ID → upload with notarization (full GUI; separate from this script).
#     OR NOTARY_API_KEY_ID + NOTARY_API_ISSUER + NOTARY_API_KEY_PATH (App Store Connect API key .p8 — no Apple ID password)
#     OR NOTARY_APPLE_ID + NOTARY_PASSWORD (app-specific password) + NOTARY_TEAM_ID or DEVELOPMENT_TEAM
#   On success: staples ticket to dist/PingStat.app and recreates the zip so the archive matches the stapled bundle.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> Syncing App Icon sizes from Design/PingStat-app-icon-master.png"
bash "$ROOT/scripts/sync-app-icons.sh"

DERIVED="$ROOT/.build/ReleaseDerivedData"
ARCHIVE="$ROOT/.build/PingStat.xcarchive"
DIST="$ROOT/dist"
rm -rf "$DERIVED" "$ARCHIVE" "$DIST/PingStat.app"
mkdir -p "$DIST" "$ROOT/.build"

SIGN_ARGS=()
if [[ "${PINGSTAT_ADHOC_SIGN:-}" == "1" ]]; then
  echo "==> Ad-hoc signing (PINGSTAT_ADHOC_SIGN=1) — CODE_SIGN_IDENTITY=-"
  SIGN_ARGS+=(CODE_SIGN_IDENTITY=-)
else
  if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    echo "==> Signing: DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"
    SIGN_ARGS+=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")
  fi
  identity="${CODE_SIGN_IDENTITY:-}"
  if [[ "${PINGSTAT_DEVELOPER_ID:-}" == "1" && -n "${DEVELOPMENT_TEAM:-}" && -z "${identity}" ]]; then
    identity="Developer ID Application"
    echo "==> PINGSTAT_DEVELOPER_ID=1: CODE_SIGN_IDENTITY=$identity (requires Developer ID Application cert for team)"
  fi
  sign_style="${CODE_SIGN_STYLE:-}"
  # Automatic + explicit Developer ID identity fails with "conflicting provisioning settings".
  if [[ -n "${identity}" && "${identity}" == *"Developer ID"* ]]; then
    if [[ -z "${sign_style}" || "${sign_style}" == "Automatic" ]]; then
      sign_style=Manual
      echo "==> Using CODE_SIGN_STYLE=Manual (required with Developer ID; set CODE_SIGN_STYLE to override)"
    fi
  fi
  if [[ -n "${sign_style}" ]]; then
    SIGN_ARGS+=(CODE_SIGN_STYLE="$sign_style")
  fi
  if [[ -n "${identity}" ]]; then
    SIGN_ARGS+=(CODE_SIGN_IDENTITY="$identity")
  fi
fi

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
echo "GitHub: run ./scripts/release.sh from a clean tree to bump version, test, build zip + DMG, and publish a release."
