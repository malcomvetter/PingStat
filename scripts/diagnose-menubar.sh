#!/usr/bin/env bash
# Quick menu bar / install diagnostics for PingStat.
# Usage: ./scripts/diagnose-menubar.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/legacy-bundle-ids.sh
source "$ROOT/scripts/lib/legacy-bundle-ids.sh"
SUBSYSTEM="org.malcomvetter.PingStat"
LOG=/usr/bin/log
CC_PLIST="$HOME/Library/Preferences/com.apple.controlcenter.plist"

echo "==> macOS"
sw_vers | sed 's/^/    /'
major="$(sw_vers -productVersion | cut -d. -f1)"
major="${major:-0}"
if [[ "$major" -ge 26 ]]; then
  echo "    NOTE: macOS 26+ can hide menu bar extras until allowed in System Settings → Menu Bar"
  echo "          (AppKit may still log isVisible=true and image_nil=false.)"
fi

echo ""
echo "==> Legacy bundle IDs (each can be its own row in System Settings → Menu Bar)"
for bid in "${PINGSTAT_LEGACY_BUNDLE_IDS[@]}"; do
  apps="$(mdfind "kMDItemCFBundleIdentifier == '$bid'" 2>/dev/null | wc -l | tr -d ' ')"
  echo "    $bid  (${apps} app path(s) on disk)"
done

echo ""
echo "==> PingStat.app copies on disk (keep /Applications only when possible)"
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  if [[ -d "$path" ]]; then
    ver="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$path/Contents/Info.plist" 2>/dev/null || echo '?')"
    build="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$path/Contents/Info.plist" 2>/dev/null || echo '?')"
    sig="$(codesign -dv "$path" 2>&1 | awk -F= '/^Authority=/{print $2; exit}')"
    [[ -z "$sig" ]] && sig="$(codesign -dv "$path" 2>&1 | awk -F= '/^Signature=/{print $2}')"
    echo "    $path  ($ver build $build)  [$sig]"
  fi
done < <(mdfind "kMDItemCFBundleIdentifier == '$SUBSYSTEM'" 2>/dev/null | sort -u)

echo ""
echo "==> Running PingStat processes"
found=0
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  found=1
  pid="${line%% *}"
  exe="$(lsof -p "$pid" 2>/dev/null | awk '/\/PingStat.app\/Contents\/MacOS\/PingStat$/ {print $NF; exit}')"
  echo "    PID $pid  $exe"
done < <(pgrep -lf '/PingStat.app/Contents/MacOS/PingStat' 2>/dev/null || true)
if [[ "$found" -eq 0 ]]; then
  echo "    (none — launching /Applications/PingStat.app)"
  open /Applications/PingStat.app 2>/dev/null || true
  sleep 3
  pgrep -lf '/PingStat.app/Contents/MacOS/PingStat' 2>/dev/null | sed 's/^/    /' || echo "    (still none)"
fi

echo ""
echo "==> Control Center / Menu Bar prefs (PingStat keys)"
if [[ -f "$CC_PLIST" ]]; then
  if plutil -p "$CC_PLIST" 2>/dev/null | rg -qi 'pingstat|macnetstatus|malcomvetter|com\.example'; then
    plutil -p "$CC_PLIST" 2>/dev/null | rg -i 'pingstat|macnetstatus|malcomvetter|com\.example' | sed 's/^/    /'
  else
    echo "    No PingStat keys in com.apple.controlcenter.plist."
    echo "    On macOS 26, allow/hide is often in a secure group container — two \"PingStat\" rows"
    echo "    usually mean two old bundle IDs (e.g. com.example.PingStat + org.malcomvetter.PingStat)."
  fi
else
  echo "    (no $CC_PLIST)"
fi

MB_LOG="$HOME/Library/Application Support/org.malcomvetter.PingStat/menu-bar.log"

echo ""
echo "==> menu-bar.log (always written; tail after launch)"
if [[ -f "$MB_LOG" ]]; then
  tail -15 "$MB_LOG" | sed 's/^/    /'
else
  echo "    (no $MB_LOG — launch PingStat once with a current build)"
fi

echo ""
echo "==> ui.statusitem unified log (last 5m; use --info — notice lines are easy to miss)"
"$LOG" show --last 5m --info --predicate "subsystem == \"$SUBSYSTEM\" AND category == \"ui.statusitem\"" --style compact 2>/dev/null \
  | tail -12 | sed 's/^/    /' || echo "    (none)"
if ! "$LOG" show --last 5m --info --predicate "subsystem == \"$SUBSYSTEM\" AND category == \"ui.statusitem\"" --style compact 2>/dev/null | rg -q .; then
  echo "    Tip: in another terminal run: log stream --info --debug --predicate 'process == \"PingStat\"'"
  echo "         then: killall PingStat; open /Applications/PingStat.app"
fi

vis="$("$LOG" show --last 5m --info --predicate "subsystem == \"$SUBSYSTEM\" AND category == \"ui.statusitem\" AND eventMessage CONTAINS \"status_bar_visibility_check\"" --style compact 2>/dev/null | tail -1 || true)"
if [[ -z "$vis" && -f "$MB_LOG" ]]; then
  vis="$(rg 'status_bar_visibility_check' "$MB_LOG" 2>/dev/null | tail -1 || true)"
fi
if [[ -n "$vis" ]]; then
  echo ""
  echo "==> Latest visibility check"
  echo "    $vis"
  if echo "$vis" | rg -q 'force_hidden_by_os=true'; then
    echo ""
    echo "    >>> OS is hiding the menu bar item. Fix: System Settings → Menu Bar → turn PingStat ON."
    echo "    >>> Opening Menu Bar settings now…"
    open "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension" 2>/dev/null || true
  fi
else
  echo ""
  echo "    (no status_bar_visibility_check yet — app build may be older; rebuild/install latest dist/PingStat.app)"
fi

echo ""
echo "==> MDM / profiles"
if profiles status -type configuration 2>/dev/null | rg -q 'configuration profiles installed'; then
  count="$(profiles status -type configuration 2>/dev/null | awk '{print $1}')"
  echo "    $count system configuration profiles (corp MDM may restrict menu bar or login items)."
else
  echo "    No system configuration profiles reported."
fi

echo ""
echo "==> Interpretation"
cat <<'EOF'
    status_bar_chrome_installed + status_bar_icon_applied (image_nil=false)
      → App created a status item. If you still see nothing on macOS 26, use Menu Bar settings (above).
    status_bar_visibility_check force_hidden_by_os=true
      → Confirmed: macOS is hiding the icon; not a signing or SF Symbol bug.
    status_item_button_nil_exhausted
      → NSStatusItem.button never appeared (rare; contact IT).
EOF
