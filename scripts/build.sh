#!/usr/bin/env bash
set -euo pipefail

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild not found. Install full Xcode and run xcode-select."
  exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found. Install with: brew install xcodegen"
  exit 1
fi

# Always regenerate the Xcode project to avoid stale file references.
xcodegen generate >/dev/null

xcodebuild \
  -scheme MacNetStatus \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath .build/DerivedData \
  build
