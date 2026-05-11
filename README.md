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

Releases are built **entirely on your Mac** (no GitHub Actions build for binaries). Use **`./scripts/release.sh`** from a **clean git tree** on the branch you want to ship (usually `main`). It:

1. Runs **`scripts/test.sh`** (fails the release if tests fail).
2. Bumps **`MARKETING_VERSION`** by one **patch** (e.g. `1.0.8` → `1.0.9`) and increments **`CURRENT_PROJECT_VERSION`** in **`project.yml`**, then **`xcodegen generate`**.
3. Runs **`PINGSTAT_ADHOC_SIGN=1 scripts/build-release.sh`** (Release archive → `dist/PingStat.app` + versioned **zip**).
4. Runs **`scripts/package-dmg.sh`** with the same app (**create-dmg** + Finder for the polished **DMG**).
5. Commits the version bump, **pushes the branch**, creates and **pushes tag `vX.Y.Z`**, and **`gh release create`** with both the zip and DMG.

Prerequisites: full Xcode, **xcodegen**, Python 3, and **[GitHub CLI](https://cli.github.com/)** (`brew install gh` then **`gh auth login`**). Dry run: **`./scripts/release.sh --dry-run`**. To allow uncommitted changes (not recommended): **`PINGSTAT_RELEASE_ALLOW_DIRTY=1 ./scripts/release.sh`**.

Manual pieces (without bumping): **`./scripts/build-release.sh`** with **`PINGSTAT_ADHOC_SIGN=1`** for zip only; **`./scripts/package-dmg.sh`** (or reuse **`PINGSTAT_DMG_REUSE_APP="$PWD/dist/PingStat.app"`** after a release build) for the DMG. **`dist/`** is gitignored.

These builds are **not notarized**; downloaders will need **Control-click → Open** (or **Privacy & Security → Open Anyway**) the first time.

## Troubleshooting

If you see `Build input file cannot be found ... AppContainer.swift` (or similar missing source file errors), your local generated project is stale. Regenerate:

```bash
xcodegen generate
```
