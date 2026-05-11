#!/usr/bin/env bash
# Full local release: require clean git tree, run tests, bump patch version + build number in
# project.yml, regenerate Xcode project, build ad-hoc zip + polished DMG, commit, push branch,
# push tag, and create a GitHub Release with both artifacts.
#
# Prerequisites: full Xcode, xcodegen, Python 3, GitHub CLI (`brew install gh` && `gh auth login`).
#
# Usage (from repo root):
#   ./scripts/release.sh
#   ./scripts/release.sh --dry-run    # print plan only
#
# Environment:
#   PINGSTAT_RELEASE_ALLOW_DIRTY=1   allow a dirty working tree (default: require clean)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

die() { echo "error: $*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "$1 not found in PATH"; }

need_cmd git
need_cmd xcodebuild
need_cmd xcodegen
need_cmd python3
need_cmd gh

if ! gh auth status >/dev/null 2>&1; then
  die "gh not authenticated — run: gh auth login"
fi

if [[ -z "${PINGSTAT_RELEASE_ALLOW_DIRTY:-}" && "$DRY_RUN" -eq 0 ]]; then
  if [[ -n "$(git status --porcelain)" ]]; then
    die "working tree is not clean (commit or stash first, or set PINGSTAT_RELEASE_ALLOW_DIRTY=1)"
  fi
fi
if [[ "$DRY_RUN" -eq 1 && -n "$(git status --porcelain)" ]]; then
  echo "note: working tree is dirty; a real release still requires a clean tree (or PINGSTAT_RELEASE_ALLOW_DIRTY=1)." >&2
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" == "HEAD" ]]; then
  die "detached HEAD — checkout a branch before releasing"
fi

echo "==> Running tests (must pass)"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[dry-run] would run: bash scripts/test.sh"
else
  bash "$ROOT/scripts/test.sh"
fi

restore_version_files() {
  git checkout -- project.yml PingStat.xcodeproj/project.pbxproj 2>/dev/null || true
  xcodegen generate >/dev/null 2>&1 || true
}

if [[ "$DRY_RUN" -eq 0 ]]; then
  trap 'ec=$?; echo "error: release failed (exit $ec); restoring project.yml / pbxproj from last commit" >&2; restore_version_files; exit "$ec"' ERR
fi

echo "==> Bumping MARKETING_VERSION (patch) and CURRENT_PROJECT_VERSION in project.yml"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[dry-run] would bump versions in project.yml then run xcodegen"
  NEW_MARKETING="$(python3 - <<'PY'
import pathlib, re
t = pathlib.Path("project.yml").read_text()
m = re.search(r'MARKETING_VERSION:\s*"(\d+)\.(\d+)\.(\d+)"', t)
if not m: raise SystemExit(1)
a, b, c = map(int, m.groups())
print(f"{a}.{b}.{c+1}")
PY
)"
  NEW_BUILD="$(python3 - <<'PY'
import pathlib, re
t = pathlib.Path("project.yml").read_text()
m = re.search(r'CURRENT_PROJECT_VERSION:\s*"(\d+)"', t)
if not m: raise SystemExit(1)
print(int(m.group(1)) + 1)
PY
)"
  echo "[dry-run] next marketing version would be: $NEW_MARKETING (build $NEW_BUILD)"
else
  OUT="$(python3 <<'PY'
import pathlib
import re
import sys

path = pathlib.Path("project.yml")
text = path.read_text()
m = re.search(r"^(\s*)MARKETING_VERSION:\s*\"(\d+)\.(\d+)\.(\d+)\"", text, re.MULTILINE)
if not m:
    sys.exit("could not parse MARKETING_VERSION in project.yml")
indent_m = m.group(1)
major, minor, patch = int(m.group(2)), int(m.group(3)), int(m.group(4))
new_marketing = f"{major}.{minor}.{patch + 1}"

m2 = re.search(r"^(\s*)CURRENT_PROJECT_VERSION:\s*\"(\d+)\"", text, re.MULTILINE)
if not m2:
    sys.exit("could not parse CURRENT_PROJECT_VERSION in project.yml")
indent_b = m2.group(1)
new_build = int(m2.group(2)) + 1

text, n = re.subn(
    r"^(\s*)MARKETING_VERSION:\s*\"[\d.]+\"",
    f'{indent_m}MARKETING_VERSION: "{new_marketing}"',
    text,
    count=1,
    flags=re.MULTILINE,
)
if n != 1:
    sys.exit("failed to replace MARKETING_VERSION")
text, n = re.subn(
    r"^(\s*)CURRENT_PROJECT_VERSION:\s*\"\d+\"",
    f'{indent_b}CURRENT_PROJECT_VERSION: "{new_build}"',
    text,
    count=1,
    flags=re.MULTILINE,
)
if n != 1:
    sys.exit("failed to replace CURRENT_PROJECT_VERSION")
path.write_text(text)
print(new_marketing)
print(new_build)
PY
)"
  NEW_MARKETING="$(echo "$OUT" | sed -n '1p' | tr -d '\n')"
  NEW_BUILD="$(echo "$OUT" | sed -n '2p' | tr -d '\n')"
  echo "    New version: $NEW_MARKETING (build $NEW_BUILD)"
  xcodegen generate >/dev/null
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  TAG="v${NEW_MARKETING}"
  echo "[dry-run] would run: PINGSTAT_ADHOC_SIGN=1 bash scripts/build-release.sh"
  echo "[dry-run] would run: PINGSTAT_DMG_REUSE_APP=... PINGSTAT_DMG_NO_OPEN=1 bash scripts/package-dmg.sh"
  echo "[dry-run] would commit, push $BRANCH, tag $TAG, gh release create with zip + dmg"
  exit 0
fi

echo "==> Building release zip (ad-hoc archive)"
PINGSTAT_ADHOC_SIGN=1 bash "$ROOT/scripts/build-release.sh"

VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$ROOT/dist/PingStat.app/Contents/Info.plist" | tr -d '\n')"
BUILD="$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$ROOT/dist/PingStat.app/Contents/Info.plist" | tr -d '\n')"
if [[ "$VERSION" != "$NEW_MARKETING" || "$BUILD" != "$NEW_BUILD" ]]; then
  die "built app version $VERSION ($BUILD) does not match bumped $NEW_MARKETING ($NEW_BUILD)"
fi

ZIP="$ROOT/dist/PingStat-${VERSION}-${BUILD}.zip"
DMG="$ROOT/dist/PingStat-${VERSION}.dmg"
[[ -f "$ZIP" ]] || die "missing zip: $ZIP"

echo "==> Building polished DMG (create-dmg; reuse dist/PingStat.app)"
export PINGSTAT_DMG_NO_OPEN=1
export PINGSTAT_DMG_REUSE_APP="$ROOT/dist/PingStat.app"
bash "$ROOT/scripts/package-dmg.sh"
[[ -f "$DMG" ]] || die "missing dmg after package-dmg: $DMG"

trap - ERR

TAG="v${VERSION}"
if git ls-remote --tags origin "refs/tags/${TAG}" | grep -q .; then
  echo "error: remote already has tag ${TAG}; restoring project.yml / pbxproj" >&2
  restore_version_files
  die "remove the tag and GitHub release on origin first, or adjust project.yml"
fi

echo "==> Committing version bump"
git add project.yml PingStat.xcodeproj/project.pbxproj
git commit -m "Release ${VERSION} (build ${BUILD})"

echo "==> Pushing branch $BRANCH and tag $TAG"
git push origin "$BRANCH"
if git rev-parse "$TAG" >/dev/null 2>&1; then
  die "tag $TAG already exists locally — delete it before retrying"
fi
git tag -a "$TAG" -m "PingStat ${VERSION} (build ${BUILD})"
git push origin "$TAG"

echo "==> Creating GitHub Release $TAG with zip + DMG"
gh release create "$TAG" \
  "$ZIP" \
  "$DMG" \
  --title "PingStat ${VERSION}" \
  --generate-notes

echo ""
echo "Done. Release: $(gh repo view --json url -q .url)/releases/tag/${TAG}"
