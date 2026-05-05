# PingStat

Menu bar macOS app that monitors gateway/WAN latency and DNS behavior with
offline/degraded/healthy/blazing states.

## Local development setup

This project is designed for local-only development to start (no paid Apple
Developer license required for local builds).

1. Install full Xcode.
2. Set active developer directory:

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
sudo xcodebuild -license accept
```

3. Bootstrap dependencies and generate the Xcode project (`PingStat.xcodeproj`):

```bash
./scripts/bootstrap.sh
```

If an older `MacNetStatus.xcodeproj` is still present, delete it so Xcode and `xcodebuild` do not open the wrong project.

4. Build:

```bash
./scripts/build.sh
```

5. Test:

```bash
./scripts/test.sh
```

6. Build and launch the debug app:

```bash
./scripts/launch-debug.sh
```

Both `build.sh` and `test.sh` regenerate the Xcode project from `project.yml` before running so local generated files do not drift from source.

## Unsigned release artifacts (no Apple Developer ID)

- **DMG (drag to Applications):** from the repo root, run `./scripts/package-dmg.sh`. This regenerates the Xcode project, builds **Release** with ad-hoc / local signing, then writes `dist/PingStat-<version>.dmg`. By default the script uses the vendored [create-dmg](https://github.com/create-dmg/create-dmg) helper (MIT: `scripts/third_party/create-dmg/LICENSE-create-dmg`) to produce a Finder window with a background, **PingStat.app**, and an **Applications** drop link. If `create-dmg` is missing or fails (for example no GUI / AppleScript in CI), it falls back to a plain `hdiutil` image with `PingStat.app` and an **Applications** symlink. In headless CI, set `PINGSTAT_DMG_SKIP_LAYOUT=1` so create-dmg passes `--skip-jenkins` (no Finder/osascript). **`CI` is not read** so a stray `CI=1` in your shell does not strip the layout. The `dist/` folder is gitignored; attach the DMG to a GitHub Release when publishing.
- **ZIP (alternate):** `./scripts/build-release.sh` with `PINGSTAT_ADHOC_SIGN=1` produces `dist/PingStat.app` and a versioned zip (see that script’s header).

These builds are **not notarized**; downloaders will need **Control-click → Open** (or **Privacy & Security → Open Anyway**) the first time.

## Troubleshooting

If you see `Build input file cannot be found ... AppContainer.swift` (or similar missing source file errors), your local generated project is stale. Regenerate:

```bash
xcodegen generate
```

## Notes

- Menu bar icon is monochrome and reflects current health state.
- Popover includes interface details, per-target means, and last 10 ping results.
- DNS checks run on a slower cadence and use fallback checks to Cloudflare/Google
  when configured DNS servers time out.
- Notifications fire on degraded/offline transitions and DNS filtering detection.
