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
- **Settings** also covers **automatic updates** (Sparkle), **Launch at login** (offered once on first launch), **debug logging**, **ping / DNS intervals and timeouts**, **DNS probe hostname** (default geared toward captive-network detection), **latency thresholds** (blazing / healthy / degraded), and **precision** controls (how many agreeing probe rounds and minimum seconds between state changes) to reduce flapping.

### Other behavior

- Runs as an **accessory app** (no Dock icon); closing the Settings window does not quit the app.
- **Unsigned local builds** are supported for development (`PINGSTAT_ADHOC_SIGN=1`); release scripts default to **Developer ID** signing (see below).

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

## Release artifacts (Developer ID signing)

Releases are built **entirely on your Mac** (no GitHub Actions build for binaries). You need a **paid Apple Developer Program** membership and a **Developer ID Application** certificate in your login keychain.

**One-time setup:**

```bash
cp .pingstat-signing.env.example .pingstat-signing.env
# Edit DEVELOPMENT_TEAM to match your Developer ID cert (see Keychain / Xcode → Accounts).
```

Optional: **`PINGSTAT_NOTARIZE=1`** and **`NOTARY_KEYCHAIN_PROFILE`** in that file (see comments in the example).

Use **`./scripts/release.sh`** from a **clean git tree** on the branch you want to ship (usually `main`). It:

1. Runs **`scripts/test.sh`** (fails the release if tests fail).
2. Bumps **`MARKETING_VERSION`** by one **patch** and increments **`CURRENT_PROJECT_VERSION`** in **`project.yml`**, then **`xcodegen generate`**.
3. Runs **`scripts/build-release.sh`** (Developer ID–signed **`dist/PingStat.app`** + versioned **zip**; verifies signature).
4. Runs **`scripts/package-dmg.sh`** reusing that app (**create-dmg** + Finder for the polished **DMG**).
5. Signs the zip with Sparkle's **`sign_update`** and prepends an entry to **`appcast.xml`**.
6. Commits the version bump + appcast, creates and **pushes tag `vX.Y.Z`**, runs **`gh release create`** with both the zip and DMG, then **pushes the branch** last so the feed never points at a missing asset.

Prerequisites: full Xcode, **xcodegen**, Python 3, Developer ID cert, and **[GitHub CLI](https://cli.github.com/)** (`brew install gh` then **`gh auth login`**). Dry run: **`./scripts/release.sh --dry-run`**. To allow uncommitted changes (not recommended): **`PINGSTAT_RELEASE_ALLOW_DIRTY=1 ./scripts/release.sh`**.

Manual build (without version bump): **`./scripts/build-release.sh`** (leaves only the zip in `dist/`; set **`PINGSTAT_KEEP_DIST_APP=1`** to keep the `.app`). Install and verify:

```bash
ditto -x -k dist/PingStat-*.zip /Applications
codesign -dv /Applications/PingStat.app 2>&1 | rg 'Authority=|Signature=adhoc|TeamIdentifier='
```

DMG only: **`./scripts/package-dmg.sh`** (builds signed app first) or **`PINGSTAT_DMG_REUSE_APP="$PWD/dist/PingStat.app"`** after a release build. **`dist/`** is gitignored.

For **unsigned** local artifacts only: **`PINGSTAT_ADHOC_SIGN=1 ./scripts/build-release.sh`**.

Without **notarization**, Gatekeeper may still prompt on first open; enable **`PINGSTAT_NOTARIZE=1`** in **`.pingstat-signing.env`** for stapled notarized builds.

### Automatic updates (Sparkle)

PingStat uses **[Sparkle 2](https://sparkle-project.org)**. Installed apps read **`appcast.xml`** from `main` (`SUFeedURL` in `project.yml`), check every 6 hours by default, and silently download the zip attached to the GitHub Release; the update installs the next time PingStat quits (quit, log out, or restart). Each zip is verified against **`SUPublicEDKey`** (and the Developer ID signature) before it replaces `/Applications/PingStat.app`. Silent install can be turned off in **Settings → Updates**.

- Users: right-click the menu bar icon → **Check for Updates…**, or **Settings → Updates**.
- Signing key: the EdDSA private key is in the **login keychain** of the release Mac (created once with `generate_keys` from `.build/*/SourcePackages/artifacts/sparkle/Sparkle/bin/`). Back it up with `generate_keys -x private-key-file`; without it, shipped apps cannot accept new updates.
- Builds before the first Sparkle release must be updated by hand once.

## License

PingStat is released under the [MIT License](LICENSE).

Third-party components (both MIT): [Sparkle](https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE) is embedded in the app for updates; [create-dmg](scripts/third_party/create-dmg/LICENSE-create-dmg) is used only to build the DMG.

## Troubleshooting

If you see `Build input file cannot be found ... AppContainer.swift` (or similar missing source file errors), your local generated project is stale. Regenerate:

```bash
xcodegen generate
```
