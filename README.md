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
