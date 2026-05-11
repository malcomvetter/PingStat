#!/usr/bin/env bash
# Build a polished DMG with package-dmg.sh (same machine: create-dmg + Finder), then attach it to an
# existing GitHub release for the given tag. Use this after the tag workflow has published the .zip.
#
# Prerequisites:
#   - GitHub CLI: https://cli.github.com/  (`brew install gh` then `gh auth login`)
#   - Full Xcode, xcodegen, Python 3 (same as local development)
#
# Usage (from repo root, on or matching the tagged release commit):
#   ./scripts/upload-release-dmg.sh v1.0.7
#
# Optional: skip rebuilding the .app if dist/PingStat.app already matches your intent:
#   PINGSTAT_DMG_REUSE_APP="$PWD/dist/PingStat.app" ./scripts/upload-release-dmg.sh v1.0.7
#   (script still runs package-dmg.sh; set reuse to avoid build-release if you already have the app)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TAG="${1:-}"
if [[ -z "$TAG" || "$TAG" != v* ]]; then
  echo "usage: $0 vX.Y.Z   (example: $0 v1.0.7)" >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh not found. Install: brew install gh && gh auth login" >&2
  exit 1
fi

if [[ -n "${PINGSTAT_DMG_REUSE_APP:-}" && -d "${PINGSTAT_DMG_REUSE_APP}" ]]; then
  echo "==> Using existing app: ${PINGSTAT_DMG_REUSE_APP}"
else
  echo "==> Building release app + zip (ad-hoc)…"
  PINGSTAT_ADHOC_SIGN=1 bash "$ROOT/scripts/build-release.sh"
fi

echo "==> Building DMG (package-dmg.sh / create-dmg)…"
export PINGSTAT_DMG_NO_OPEN=1
export PINGSTAT_DMG_REUSE_APP="${PINGSTAT_DMG_REUSE_APP:-$ROOT/dist/PingStat.app}"
bash "$ROOT/scripts/package-dmg.sh"

DMG_FILE="$(ls -t "$ROOT"/dist/PingStat-*.dmg 2>/dev/null | head -n 1 || true)"
if [[ -z "$DMG_FILE" || ! -f "$DMG_FILE" ]]; then
  echo "error: no dist/PingStat-*.dmg produced" >&2
  exit 1
fi

echo "==> Uploading to GitHub release $TAG: $DMG_FILE"
gh release upload "$TAG" "$DMG_FILE" --clobber

echo "Done. Release: $(gh repo view --json url -q .url)/releases/tag/${TAG}"
