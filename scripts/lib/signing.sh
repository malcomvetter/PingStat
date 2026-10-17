# Shared code-signing helpers for PingStat release scripts.
# Source from repo root scripts: source "$(dirname "$0")/lib/signing.sh"
#
# Not executed directly.

pingstat_repo_root() {
  if [[ -n "${PINGSTAT_ROOT:-}" ]]; then
    echo "$PINGSTAT_ROOT"
    return
  fi
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  echo "$here"
}

# Load gitignored .pingstat-signing.env from repo root (optional).
pingstat_source_signing_env() {
  local root
  root="$(pingstat_repo_root)"
  local env_file="$root/.pingstat-signing.env"
  if [[ -f "$env_file" ]]; then
    # shellcheck disable=SC1090
    set -a
    source "$env_file"
    set +a
    echo "==> Loaded signing env from .pingstat-signing.env"
  fi
}

# Print team id from first "Developer ID Application: … (TEAMID)" identity, or empty.
pingstat_detect_developer_id_team() {
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*Developer ID Application:.*(\([A-Z0-9]\{10\}\)).*/\1/p' \
    | head -1
}

# Configure DEVELOPMENT_TEAM / Developer ID identity for distribution builds (mutates env).
pingstat_configure_developer_id_signing() {
  if [[ "${PINGSTAT_ADHOC_SIGN:-}" == "1" ]]; then
    return 0
  fi

  local detected
  detected="$(pingstat_detect_developer_id_team)"

  if [[ -z "${DEVELOPMENT_TEAM:-}" && -n "$detected" ]]; then
    export DEVELOPMENT_TEAM="$detected"
    echo "==> DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM (from Developer ID Application cert in keychain)"
  fi

  if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
    echo "error: no DEVELOPMENT_TEAM and no Developer ID Application cert in keychain." >&2
    echo "  Set DEVELOPMENT_TEAM in .pingstat-signing.env (see .pingstat-signing.env.example), or" >&2
    echo "  install a Developer ID Application cert (Xcode → Settings → Accounts → Manage Certificates)." >&2
    echo "  For unsigned local artifacts only: PINGSTAT_ADHOC_SIGN=1" >&2
    return 1
  fi

  if [[ -z "${CODE_SIGN_IDENTITY:-}" ]]; then
    export CODE_SIGN_IDENTITY="Developer ID Application"
  fi

  if [[ "${CODE_SIGN_IDENTITY}" == *"Developer ID"* ]]; then
    if [[ -z "${CODE_SIGN_STYLE:-}" || "${CODE_SIGN_STYLE}" == "Automatic" ]]; then
      export CODE_SIGN_STYLE=Manual
    fi
  fi

  echo "==> Distribution signing: DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM CODE_SIGN_IDENTITY=$CODE_SIGN_IDENTITY CODE_SIGN_STYLE=${CODE_SIGN_STYLE:-Automatic}"
}

# Populates global PINGSTAT_XCODE_SIGN_ARGS for xcodebuild (bash 3.2–safe; no namerefs).
pingstat_build_xcode_sign_args() {
  PINGSTAT_XCODE_SIGN_ARGS=()

  if [[ "${PINGSTAT_ADHOC_SIGN:-}" == "1" ]]; then
    echo "==> Ad-hoc signing (PINGSTAT_ADHOC_SIGN=1) — CODE_SIGN_IDENTITY=-"
    PINGSTAT_XCODE_SIGN_ARGS=(CODE_SIGN_IDENTITY=-)
    return 0
  fi

  if ! pingstat_configure_developer_id_signing; then
    return 1
  fi

  PINGSTAT_XCODE_SIGN_ARGS=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")
  if [[ -n "${CODE_SIGN_STYLE:-}" ]]; then
    PINGSTAT_XCODE_SIGN_ARGS+=(CODE_SIGN_STYLE="$CODE_SIGN_STYLE")
  fi
  if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
    PINGSTAT_XCODE_SIGN_ARGS+=(CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY")
  fi
}

# Verify codesign output for dist/PingStat.app. Mode: developer-id | adhoc
pingstat_verify_app_signature() {
  local app=$1
  local expect=${2:-developer-id}
  local info authority team signature

  if [[ ! -d "$app" ]]; then
    echo "error: not a bundle: $app" >&2
    return 1
  fi

  info="$(codesign -dv --verbose=4 "$app" 2>&1)" || {
    echo "error: codesign -dv failed for $app" >&2
    return 1
  }

  authority="$(echo "$info" | awk -F= '/^Authority=/{print $2; exit}')"
  team="$(echo "$info" | awk -F= '/^TeamIdentifier=/{print $2}')"
  signature="$(echo "$info" | awk -F= '/^Signature=/{print $2}')"

  case "$expect" in
    adhoc)
      if [[ "$signature" != "adhoc" ]]; then
        echo "error: expected ad-hoc signature on $app but got: ${authority:-unknown}" >&2
        return 1
      fi
      echo "==> Signature OK (ad hoc): $app"
      ;;
    developer-id)
      if [[ "$signature" == "adhoc" || "$team" == "not set" || -z "$team" ]]; then
        echo "error: $app is not Developer ID–signed (Signature=${signature:-?} TeamIdentifier=${team:-?})" >&2
        echo "  Install/copy a build from: DEVELOPMENT_TEAM=… bash scripts/build-release.sh" >&2
        echo "  Or use PINGSTAT_ADHOC_SIGN=1 only for local unsigned artifacts." >&2
        return 1
      fi
      if [[ "$authority" != *"Developer ID Application"* ]]; then
        echo "error: $app is signed but not with Developer ID Application (Authority=${authority:-?})" >&2
        return 1
      fi
      echo "==> Signature OK (Developer ID): $authority  TeamIdentifier=$team"
      ;;
    *)
      echo "error: unknown verify mode: $expect" >&2
      return 1
      ;;
  esac
}
