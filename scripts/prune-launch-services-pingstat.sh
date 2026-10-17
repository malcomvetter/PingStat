#!/usr/bin/env bash
# Remove stale Launch Services registrations for PingStat (old com.example.* DMG mounts, .build paths, etc.).
# macOS 26 Menu Bar often shows one row per bundle ID — two rows = com.example.PingStat + org.malcomvetter.PingStat.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/legacy-bundle-ids.sh
source "$ROOT/scripts/lib/legacy-bundle-ids.sh"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
KEEP="/Applications/PingStat.app"

killall PingStat 2>/dev/null || true
sleep 1

echo "==> Eject mounted PingStat DMGs (if any)"
while IFS= read -r vol; do
  [[ -n "$vol" ]] || continue
  echo "    diskutil eject $vol"
  diskutil eject "$vol" 2>/dev/null || hdiutil detach "$vol" 2>/dev/null || true
done < <(mount | awk '/\/Volumes\/PingStat / {print $1}' | sort -u)

echo "==> Unregister stale Launch Services entries (keep only $KEEP)"
python3 - "$KEEP" <<'PY'
import re
import subprocess
import sys

keep = sys.argv[1]
lsreg = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
dump = subprocess.check_output([lsreg, "-dump"], text=True, errors="replace")
blocks = re.split(r"\n(?=bundle id:)", dump)
targets = []
for b in blocks:
    if "pingstat" not in b.lower():
        continue
    bid_m = re.search(r"identifier:\s+(\S+)", b)
    path_m = re.search(r"^\s*path:\s+(\S+.*?)(?:\s+\(0x|\s*$)", b, re.M)
    if not bid_m or not path_m:
        continue
    bid, path = bid_m.group(1), path_m.group(1).strip()
    if "PingStat" not in bid and "pingstat" not in bid.lower():
        continue
    if path == keep:
        continue
    targets.append((bid, path))

seen = set()
for bid, path in targets:
    key = (bid, path)
    if key in seen:
        continue
    seen.add(key)
    print(f"    -u {path}  [{bid}]")
    subprocess.run([lsreg, "-u", path], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print(f"    (unregistered {len(seen)} stale path(s))")
PY

echo "==> Re-register canonical install"
if [[ -d "$KEEP" ]]; then
  "$LSREGISTER" -f -R -trusted "$KEEP"
else
  echo "    warning: $KEEP missing — install with build-release.sh or reset-pingstat-install.sh"
fi

echo ""
echo "==> Remaining PingStat registrations (should be one path):"
python3 <<'PY'
import re, subprocess
dump = subprocess.check_output([
    "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
    "-dump"], text=True, errors="replace")
blocks = re.split(r"\n(?=bundle id:)", dump)
seen = set()
for b in blocks:
    if "pingstat" not in b.lower():
        continue
    bid = re.search(r"identifier:\s+(\S+)", b)
    path = re.search(r"^\s*path:\s+(\S+.*?)(?:\s+\(0x|\s*$)", b, re.M)
    if bid and path:
        key = (bid.group(1), path.group(1).strip())
        if key not in seen:
            seen.add(key)
            print(f"  {key[0]}\n    {key[1]}")
PY

echo ""
echo "Open Menu Bar settings — expect at most one PingStat per bundle ID still listed."
echo "Turn ON org.malcomvetter.PingStat; ignore or remove com.example.PingStat if it still appears."
open "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension" 2>/dev/null || true
