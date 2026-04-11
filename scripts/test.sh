#!/usr/bin/env bash
set -euo pipefail

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild not found. Install full Xcode and run xcode-select."
  exit 1
fi

xcodebuild \
  -scheme MacNetStatus \
  -destination "platform=macOS" \
  -derivedDataPath .build/DerivedData \
  test
