#!/usr/bin/env bash
set -euo pipefail

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild not found. Install full Xcode and run xcode-select --switch ..."
  exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not found. Install with: brew install xcodegen"
  exit 1
fi

xcodegen generate
echo "Bootstrap complete."
