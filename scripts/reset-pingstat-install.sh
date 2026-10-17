#!/usr/bin/env bash
# Remove all PingStat/MacNetStatus app copies (every historical bundle ID), reset state, reinstall from dist/.
# Usage: ./scripts/reset-pingstat-install.sh
# Optional: PINGSTAT_MENU_BAR_NUCLEAR=1 also resets Control Center group prefs (macOS 26 menu bar allow list).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/legacy-bundle-ids.sh
source "$ROOT/scripts/lib/legacy-bundle-ids.sh"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

echo "==> Quit PingStat / MacNetStatus"
killall PingStat 2>/dev/null || true
killall MacNetStatus 2>/dev/null || true
sleep 1

echo "==> Unregister + remove every app for legacy bundle IDs"
seen_apps=""
for bid in "${PINGSTAT_LEGACY_BUNDLE_IDS[@]}"; do
  while IFS= read -r app; do
    [[ -n "$app" && -d "$app" ]] || continue
    if [[ " $seen_apps " == *" $app "* ]]; then
      continue
    fi
    seen_apps="$seen_apps $app"
    echo "    [$bid] $app"
    "$LSREGISTER" -u "$app" 2>/dev/null || true
    rm -rf "$app"
  done < <(mdfind "kMDItemCFBundleIdentifier == '$bid'" 2>/dev/null || true)
done

echo "==> Remove repo dist/staging copies (macOS 26 lists each .app path separately in Menu Bar)"
rm -rf "$ROOT/dist/PingStat.app" "$ROOT/dist/dmg-layout" "$ROOT/dist/dmg-staging" 2>/dev/null || true
touch "$ROOT/dist/.metadata_never_index" 2>/dev/null || true

echo "==> App preferences and state (all legacy domains)"
for bid in "${PINGSTAT_LEGACY_BUNDLE_IDS[@]}"; do
  defaults delete "$bid" 2>/dev/null || true
  rm -f "$HOME/Library/Preferences/${bid}.plist" 2>/dev/null || true
  rm -rf "$HOME/Library/Saved Application State/${bid}.savedState" 2>/dev/null || true
  rm -rf "$HOME/Library/Caches/${bid}" 2>/dev/null || true
done
rm -f "$HOME/Library/Application Support/CrashReporter/PingStat_"*.plist 2>/dev/null || true
rm -f "$HOME/Library/Application Support/CrashReporter/MacNetStatus_"*.plist 2>/dev/null || true

echo "==> Scrub Control Center plist keys (legacy + PingStat)"
CC_PLIST="$HOME/Library/Preferences/com.apple.controlcenter.plist"
if [[ -f "$CC_PLIST" ]]; then
  python3 - "$CC_PLIST" "${PINGSTAT_LEGACY_KEY_SUBSTRINGS[@]}" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
needles = [s.lower() for s in sys.argv[2:]]
try:
    with path.open("rb") as f:
        data = plistlib.load(f)
except Exception as e:
    print(f"    skip ({e})")
    raise SystemExit(0)
if not isinstance(data, dict):
    raise SystemExit(0)
remove = []
for k in data:
    kl = k.lower()
    if any(n in kl for n in needles):
        remove.append(k)
for k in remove:
    del data[k]
    print(f"    removed: {k}")
if remove:
    with path.open("wb") as f:
        plistlib.dump(data, f)
else:
    print("    (no matching keys in com.apple.controlcenter.plist)")
PY
else
  echo "    (no com.apple.controlcenter.plist)"
fi

if [[ "${PINGSTAT_MENU_BAR_NUCLEAR:-}" == "1" ]]; then
  echo "==> NUCLEAR: reset Control Center group containers (macOS 26 menu bar allow list)"
  echo "    This clears stored allow/hide state for ALL menu bar extras, not only PingStat."
  killall ControlCenter 2>/dev/null || true
  for gc in \
    "$HOME/Library/Group Containers/group.com.apple.controlcenter" \
    "$HOME/Library/Group Containers/group.com.apple.secure-control-center-preferences"; do
    if [[ -d "$gc" ]]; then
      echo "    rm -rf $gc/*"
      rm -rf "${gc:?}/"* 2>/dev/null || echo "    (could not clear $gc — grant Full Disk Access to Terminal if needed)"
    fi
  done
fi

echo "==> Reinstall from dist/ zip or .app (run build-release.sh first if missing)"
INSTALL_SRC=""
if [[ -d "$ROOT/dist/PingStat.app" ]]; then
  INSTALL_SRC="$ROOT/dist/PingStat.app"
elif ls "$ROOT"/dist/PingStat-*.zip >/dev/null 2>&1; then
  ZIP="$(ls -t "$ROOT"/dist/PingStat-*.zip | head -1)"
  STAGE="$ROOT/dist/.install-stage"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  echo "    extracting $ZIP"
  ditto -x -k "$ZIP" "$STAGE"
  INSTALL_SRC="$STAGE/PingStat.app"
fi

if [[ -n "$INSTALL_SRC" && -d "$INSTALL_SRC" ]]; then
  echo "    ditto -> /Applications/PingStat.app"
  ditto "$INSTALL_SRC" "/Applications/PingStat.app"
  "$LSREGISTER" -f -R -trusted "/Applications/PingStat.app" 2>/dev/null || true
  rm -rf "$ROOT/dist/PingStat.app" "$ROOT/dist/.install-stage" 2>/dev/null || true
  codesign -dv "/Applications/PingStat.app" 2>&1 | awk -F= '/^Authority=|^Signature=|^TeamIdentifier=/{print "    "$0}' || true
  echo ""
  echo "Done. Removed dist/PingStat.app so only /Applications remains (avoids duplicate Menu Bar rows)."
  echo ""
  echo "Why you saw TWO PingStat rows in Menu Bar settings:"
  echo "  macOS 26 often registers each .app *path* separately, even with the same bundle ID."
  echo "  Common cause: /Applications/PingStat.app AND repo dist/PingStat.app both present."
  echo "  Older bundle IDs (com.example.PingStat, etc.) can add more rows if those builds were run."
  echo ""
  echo "Next:"
  echo "  1. open \"x-apple.systempreferences:com.apple.ControlCenter-Settings.extension\""
  echo "  2. If TWO PingStat rows remain, turn BOTH on — or re-run with:"
  echo "       PINGSTAT_MENU_BAR_NUCLEAR=1 bash scripts/reset-pingstat-install.sh"
  echo "  3. bash scripts/prune-launch-services-pingstat.sh  (clears stale com.example.PingStat DMG ghosts)"
  echo "  4. open /Applications/PingStat.app"
  echo "  5. bash scripts/diagnose-menubar.sh  (look for force_hidden_by_os=false)"
else
  echo "    No dist/PingStat.app or PingStat-*.zip — run:"
  echo "      source .pingstat-signing.env && bash scripts/build-release.sh"
  echo "      bash scripts/reset-pingstat-install.sh"
fi
