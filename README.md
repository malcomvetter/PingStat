# PingStat

PingStat is a **menu bar utility for macOS** that watches **how your network actually feels**: ICMP latency to your **default gateway** and to several **public WAN targets**, plus **DNS reachability** against your system resolvers and sensible fallbacks. It rolls everything into a single **health state** you can read at a glance from the icon, then opens up for detail when you want it.

## Features

### At a glance

- **Menu bar icon** uses a monochrome template image (or bundled marks where available) and maps to four states: **Offline**, **Degraded**, **Healthy**, and **Blazing** (exceptionally low latency). Right after launch the icon stays on a neutral “starting up” look for a short period so a slow first probe does not flash a false alarm.
- **Left-click** the icon to open a **popover**: headline state, optional DNS footnotes (captive portal hints, resolver timeouts vs fallbacks), and a **summary grid** of targets.
- **Right-click** (or Control-left-click) for a **context menu**: current state, **Settings**, **Export Debug…** (save diagnostics), per-endpoint/DNS rows, and **Quit**.

### What is monitored

- **Local network** — discovers your **default gateway** from the active route and pings it over ICMP. Shows gateway IP / interface context when available.
- **WAN targets** — optional ICMP checks to well-known anycast-style endpoints (**Cloudflare**, **Google**, **OpenDNS**, **CenturyLink**, **Quad9**). Toggle each in Settings; from the popover you can **disable a WAN row** via context menu without opening Settings.
- **Custom target** — optional extra host by **label + IP**, with an optional **DNS probe** column tied to your custom resolver behavior.

### Latency and DNS

- Each target shows a **rolling mean of the last five** successful RTTs (and color hints for blazing vs healthy vs elevated latency based on your thresholds).
- **Detail view** — tap a row to see **up to the last 10 ICMP samples** (timestamp, RTT or timeout) and, where applicable, **recent DNS query log lines** for resolver debugging.
- **DNS** runs on its own cadence (slower than ping). Probes your **configured resolvers** and, when they time out, **fallback checks** against the public DNS addresses aligned with your enabled WAN targets. The popover summarizes **how many DNS columns are “green”** vs total, and calls out situations like **private IP answers** (possible captive portal) or **all resolvers failed**.

### Notifications and settings

- **User notifications** can fire on meaningful transitions (for example **offline / degraded** and **DNS filtering / resolver** style conditions), with a configurable **cooldown** so you are not spammed. Settings includes links and copy for **notification permission** issues on macOS.
- **Settings** also covers **Launch at login**, **debug logging**, **ping / DNS intervals and timeouts**, **DNS probe hostname** (default geared toward captive-network detection), **latency thresholds** (blazing / healthy / degraded), and **precision** controls (how many agreeing probe rounds and minimum seconds between state changes) to reduce flapping.

### Other behavior

- Runs as an **accessory app** (no Dock icon); closing the Settings window does not quit the app.
- **Unsigned local builds** are supported for development; release artifacts below are ad-hoc signed, not notarized.

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
