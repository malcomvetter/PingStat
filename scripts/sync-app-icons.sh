#!/usr/bin/env bash
# Resize Design/PingStat-app-icon-master.png into Assets.xcassets/AppIcon.appiconset (macOS).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MASTER="${ROOT}/Design/PingStat-app-icon-master.png"
DEST="${ROOT}/Assets.xcassets/AppIcon.appiconset"

if [[ ! -f "$MASTER" ]]; then
  echo "error: missing master icon: $MASTER" >&2
  exit 1
fi

mkdir -p "$DEST"

resize() {
  local px="$1" out="$2"
  sips -z "$px" "$px" "$MASTER" --out "$out" >/dev/null
}

resize 16  "$DEST/icon_16x16.png"
resize 32  "$DEST/icon_16x16@2x.png"
resize 32  "$DEST/icon_32x32.png"
resize 64  "$DEST/icon_32x32@2x.png"
resize 128 "$DEST/icon_128x128.png"
resize 256 "$DEST/icon_128x128@2x.png"
resize 256 "$DEST/icon_256x256.png"
resize 512 "$DEST/icon_256x256@2x.png"
resize 512 "$DEST/icon_512x512.png"
resize 1024 "$DEST/icon_512x512@2x.png"

echo "Updated AppIcon set in $DEST"
