# MacNetStatus

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

3. Bootstrap dependencies and generate project:

```bash
./scripts/bootstrap.sh
```

4. Build:

```bash
./scripts/build.sh
```

5. Test:

```bash
./scripts/test.sh
```

## Notes

- Menu bar icon is monochrome and reflects current health state.
- Popover includes interface details, per-target means, and last 10 ping results.
- DNS checks run on a slower cadence and use fallback checks to Cloudflare/Google
  when configured DNS servers time out.
- Notifications fire on degraded/offline transitions and DNS filtering detection.
