#!/usr/bin/env bash
# Production-style Release build: sync App Icon PNGs, xcodebuild archive, copy .app, zip for distribution.
# Usage: from repo root, `bash scripts/build-release.sh`
# Optional: PINGSTAT_ADHOC_SIGN=1 for local unsigned/ad-hoc archive (no Apple Developer account).
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

echo ""
echo "Built: $DIST/PingStat.app"
echo "Zip:   $ZIP"
echo ""
echo "GitHub: run ./scripts/release.sh from a clean tree to bump version, test, build zip + DMG, and publish a release."
