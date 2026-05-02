#!/usr/bin/env bash
# Regenerate the Xcode project, clean Debug artifacts, then build (same paths as build.sh).
#
# Usage: ./scripts/clean-build.sh   (from repo root or any directory)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild not found. Install full Xcode and run xcode-select." >&2
  exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found. Install with: brew install xcodegen" >&2
  exit 1
fi

xcodegen generate >/dev/null

echo "Cleaning and building Debug PingStat…"
xcodebuild \
  -project PingStat.xcodeproj \
  -scheme PingStat \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath .build/DerivedData \
  clean build

echo "Done."
