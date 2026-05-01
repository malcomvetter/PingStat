#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_NAME="PingStat"
APP_PATH="${REPO_ROOT}/.build/DerivedData/Build/Products/Debug/${APP_NAME}.app"

"${SCRIPT_DIR}/build.sh"

if pgrep -x "${APP_NAME}" >/dev/null 2>&1; then
  echo "Stopping existing ${APP_NAME} instance..."
  pkill -x "${APP_NAME}" || true
  sleep 1
fi

if [[ ! -d "${APP_PATH}" ]]; then
  echo "error: Expected app not found at ${APP_PATH}"
  exit 1
fi

echo "Launching ${APP_PATH}..."
open "${APP_PATH}"
echo "Done."
