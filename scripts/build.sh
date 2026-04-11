#!/usr/bin/env bash
set -euo pipefail

xcodebuild \
  -scheme MacNetStatus \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath .build/DerivedData \
  build
