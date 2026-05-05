#!/usr/bin/env bash
# Build a Release PingStat.app (ad-hoc / local signing, no Developer ID) and wrap it in a .dmg
# with a Finder-style layout (background, drag-to-Applications) via vendored create-dmg, or
# a plain folder image if create-dmg is missing or fails (e.g. headless CI).
#
# Output: dist/PingStat-<version>.dmg  (dist/ is gitignored)
#
# Usage: from repo root:
#   ./scripts/package-dmg.sh
#
# Env:
#   PINGSTAT_DMG_SKIP_LAYOUT=1  — pass --skip-jenkins to create-dmg (no Finder AppleScript; plain window).
#       Use this in headless CI. Many shells export CI=1 for unrelated reasons; we do not read CI here.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild not found. Install full Xcode and run xcode-select." >&2
  exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found. Install with: brew install xcodegen" >&2
  exit 1
fi

xcodegen generate >/dev/null

DERIVED="$ROOT/.build/DmgDerived"
mkdir -p "$ROOT/dist"
rm -rf "$DERIVED"

echo "Building Release PingStat.app (ad-hoc sign, no Developer ID)…"
# Ad-hoc / “Sign to Run Locally” when no Developer ID team is configured.
xcodebuild \
  -project PingStat.xcodeproj \
  -scheme PingStat \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  build

APP="$DERIVED/Build/Products/Release/PingStat.app"
if [[ ! -d "$APP" ]]; then
  echo "Expected app at: $APP" >&2
  exit 1
fi

VERSION="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null \
    || (cd "$ROOT" && git describe --tags --always 2>/dev/null) \
    || echo dev
)"
SAFE_VERSION="${VERSION// /_}"

DMG="$ROOT/dist/PingStat-${SAFE_VERSION}.dmg"
rm -f "$DMG"

create_plain_dmg() {
  local stage="$1"
  echo "Creating compressed disk image (plain layout)…"
  hdiutil create \
    -volname "PingStat ${VERSION}" \
    -srcfolder "$stage" \
    -ov \
    -format UDZO \
    "$DMG"
}

LAYOUT="$ROOT/dist/dmg-layout"
rm -rf "$LAYOUT"
mkdir -p "$LAYOUT"
ditto "$APP" "$LAYOUT/PingStat.app"

BG="$ROOT/dist/dmg-background.png"
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not found; install Python 3 for DMG background generation." >&2
  exit 1
fi
python3 "$ROOT/scripts/dmg/make_background.py" "$BG"

CREATE_DMG="$ROOT/scripts/third_party/create-dmg/create-dmg"
USE_LAYOUT=0
DMG_STYLE="plain-hdiutil"
if [[ -f "$CREATE_DMG" ]]; then
  [[ -x "$CREATE_DMG" ]] || chmod +x "$CREATE_DMG"
  # Build one argv array (never expand an empty array): with set -u, "${arr[@]}"
  # for arr=() trips "unbound variable" on macOS bash 3.2.
  CDMG_CMD=(
    "$CREATE_DMG"
    --volname "PingStat ${VERSION}"
    --background "$BG"
    --window-pos 200 120
    --window-size 660 420
    --icon-size 100
    --text-size 12
    --icon "PingStat.app" 150 200
    --hide-extension "PingStat.app"
    --app-drop-link 500 200
    --format UDZO
  )
  if [[ "${PINGSTAT_DMG_SKIP_LAYOUT:-}" == "1" ]]; then
    CDMG_CMD+=(--skip-jenkins)
    echo "PINGSTAT_DMG_SKIP_LAYOUT=1: create-dmg will skip Finder/osascript (no custom window look)." >&2
  else
    echo "Creating polished DMG (create-dmg + Finder via osascript). Grant Automation if macOS prompts." >&2
  fi
  CDMG_CMD+=("$DMG" "$LAYOUT")
  set +e
  "${CDMG_CMD[@]}"
  CDMG_EXIT=$?
  set -e
  if [[ $CDMG_EXIT -eq 0 ]]; then
    USE_LAYOUT=1
    if [[ "${PINGSTAT_DMG_SKIP_LAYOUT:-}" == "1" ]]; then
      DMG_STYLE="create-dmg-unstyled"
    else
      DMG_STYLE="create-dmg-polished"
    fi
  else
    echo "create-dmg exited $CDMG_EXIT; falling back to plain hdiutil DMG…" >&2
    echo "If you expected a styled window, check the log above (osascript often fails without GUI access)." >&2
    rm -f "$DMG"
  fi
else
  echo "Vendored create-dmg not found at $CREATE_DMG; using plain hdiutil DMG…" >&2
fi

if [[ "$USE_LAYOUT" -ne 1 ]]; then
  STAGE="$ROOT/dist/dmg-staging"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  ditto "$APP" "$STAGE/PingStat.app"
  ln -sf /Applications "$STAGE/Applications"
  create_plain_dmg "$STAGE"
fi

echo "Done: $DMG"
case "$DMG_STYLE" in
  create-dmg-polished)
    echo "DMG style: polished (background, icon positions, Applications drop link)." >&2
    ;;
  create-dmg-unstyled)
    echo "DMG style: create-dmg without Finder layout (--skip-jenkins). Set PINGSTAT_DMG_SKIP_LAYOUT=0 for full look." >&2
    ;;
  *)
    echo "DMG style: plain folder (hdiutil). No create-dmg Finder step ran successfully." >&2
    ;;
esac
if [[ -z "${PINGSTAT_DMG_NO_OPEN:-}" ]]; then
  # Mount and open the volume so the layout is visible (not only Reveal in Finder for the .dmg file).
  open "$DMG" 2>/dev/null || true
fi
