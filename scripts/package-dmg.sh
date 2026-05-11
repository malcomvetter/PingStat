#!/usr/bin/env bash
# Build a Release PingStat.app (ad-hoc / local signing, no Developer ID) and wrap it in a .dmg
# with a Finder-style layout (background, drag-to-Applications).
#
# Local default: vendored create-dmg + AppleScript (osascript) for the polished window.
# GitHub Actions / headless: set GITHUB_ACTIONS (set automatically on runners) or
# PINGSTAT_DMG_USE_DMGBUILD=1 to build the same layout via Python ``dmgbuild`` (no Finder).
#
# Output: dist/PingStat-<version>.dmg  (dist/ is gitignored)
#
# Usage: from repo root:
#   ./scripts/package-dmg.sh
#
# Env:
#   PINGSTAT_DMG_REUSE_APP=/path/PingStat.app — skip xcodebuild; package this bundle (e.g. after build-release.sh).
#   PINGSTAT_DMG_SKIP_LAYOUT=1 — with create-dmg only: pass --skip-jenkins (no AppleScript; plain window).
#   PINGSTAT_DMG_USE_DMGBUILD=1 — force dmgbuild instead of create-dmg (same look as CI).
#   PINGSTAT_DMG_NO_OPEN=1 — do not ``open`` the finished .dmg (CI).
#       Many shells export CI=1 for unrelated reasons; we do not read CI here.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

mkdir -p "$ROOT/dist"

REUSE_APP=""
if [[ -n "${PINGSTAT_DMG_REUSE_APP:-}" && -d "${PINGSTAT_DMG_REUSE_APP}" ]]; then
  REUSE_APP="${PINGSTAT_DMG_REUSE_APP}"
fi

if [[ -n "$REUSE_APP" ]]; then
  echo "==> Reusing app bundle (PINGSTAT_DMG_REUSE_APP): $REUSE_APP"
  APP="$REUSE_APP"
else
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
  rm -rf "$DERIVED"

  echo "Building Release PingStat.app (ad-hoc sign, no Developer ID)…"
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

USE_LAYOUT=0
DMG_STYLE="plain-hdiutil"

USE_DMGBUILD=0
if [[ "${GITHUB_ACTIONS:-}" == "true" ]] || [[ "${PINGSTAT_DMG_USE_DMGBUILD:-}" == "1" ]]; then
  USE_DMGBUILD=1
fi

if [[ "$USE_DMGBUILD" -eq 1 ]]; then
  echo "Creating polished DMG via dmgbuild (headless-safe, same layout as create-dmg)…" >&2
  if python3 "$ROOT/scripts/dmg/build_polished_dmg.py" \
    --app "$APP" \
    --output "$DMG" \
    --volume-name "PingStat ${VERSION}" \
    --background "$BG"; then
    USE_LAYOUT=1
    DMG_STYLE="dmgbuild-polished"
  else
    echo "error: dmgbuild failed (pip3 install dmgbuild on the runner?)" >&2
    exit 1
  fi
else
  CREATE_DMG="$ROOT/scripts/third_party/create-dmg/create-dmg"
  if [[ -f "$CREATE_DMG" ]]; then
    [[ -x "$CREATE_DMG" ]] || chmod +x "$CREATE_DMG"
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
fi

echo "Done: $DMG"
case "$DMG_STYLE" in
  create-dmg-polished)
    echo "DMG style: polished (create-dmg + Finder: background, icon positions, Applications link)." >&2
    ;;
  create-dmg-unstyled)
    echo "DMG style: create-dmg without Finder layout (--skip-jenkins). Set PINGSTAT_DMG_SKIP_LAYOUT=0 for full look." >&2
    ;;
  dmgbuild-polished)
    echo "DMG style: polished (dmgbuild: background, icon positions, Applications link)." >&2
    ;;
  *)
    echo "DMG style: plain folder (hdiutil). No styled layout step ran successfully." >&2
    ;;
esac
if [[ -z "${PINGSTAT_DMG_NO_OPEN:-}" ]]; then
  open "$DMG" 2>/dev/null || true
fi
