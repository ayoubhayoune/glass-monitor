# Glass Monitor — instructions for Claude

Glass Monitor is a small macOS menu-less agent app: a Liquid Glass pill floating at the top-right of
the screen with live CPU / GPU / RAM / swap / disk / network, which expands into a panel listing the
processes eating resources (with Quit / Force Quit / admin kill), a 7-day History tab ("why was my Mac
slow at 3pm?"), CPU/GPU temperatures, fan speed, battery health, runaway-CPU / memory-leak /
custom-threshold alerts, a Dev tab (Laravel log errors per project, Docker
containers, listening ports) and a developer-cache cleaner. Plain SwiftUI + AppKit + Swift Charts +
SQLite, built with `swiftc` (no Xcode project).

## Reinstall (what the user wants when they hand you this folder)

1. Check the requirements:
   - macOS 26 (Tahoe) or later, Apple Silicon (`uname -m` → `arm64`).
   - Swift toolchain: `swiftc --version` (Xcode or Command Line Tools). If missing, ask the user to run
     `xcode-select --install` themselves (it opens a system dialog).
2. Build and install:
   ```bash
   ./build.sh
   ```
   This compiles `Sources/*.swift`, assembles and ad-hoc codesigns the bundle in a temp folder, replaces
   `~/Applications/Glass Monitor.app` with it and launches it (through the login agent when that is
   loaded), killing the running copy just before the swap.
   If the sandbox blocks writing to `~/Applications` ("operation not permitted"), rerun it unsandboxed.
3. Turn on "Open at Login" (also gives crash auto-restart):
   ```bash
   pkill -x GlassMonitor; open "$HOME/Applications/Glass Monitor.app" --args --register-login
   ```
   (Kill first: a second copy started outside launchd exits immediately without registering.)
   This writes `~/Library/LaunchAgents/com.elabidi.glassmonitor.login.plist` and bootstraps it; the
   launchd copy then replaces the one `open` started. macOS may show a "Background item added"
   notification — that's expected.
4. Verify:
   - `pgrep -lx GlassMonitor` shows exactly one process.
   - `launchctl print gui/$(id -u)/com.elabidi.glassmonitor.login | grep -E 'state|pid'` → running.
   - CPU cost: `top -l 2 -pid $(pgrep -x GlassMonitor) -stats cpu` should be ≈0.4–1% collapsed.
   - After a minute, `sqlite3 ~/Library/Application\ Support/GlassMonitor/history.sqlite 'SELECT count(*) FROM samples'` ≥ 1.
   - The first time the Dev tab opens, macOS asks "Glass Monitor would like to access files in your
     Documents folder" (the Laravel log scan). Tell the user to click **Allow**; until then that section
     shows a spinner. Ad-hoc signing changes on every rebuild, so macOS may ask again after a rebuild.
   - The pill is hidden from screenshots by default ("Hide from Screen Sharing"), so a blank
     `screencapture` is normal. To check visually, ask the user to look, or temporarily run
     `defaults write com.elabidi.glassmonitor hideFromSharing -bool false` and restart the app
     (set it back to `true` afterwards).

## Uninstall

```bash
launchctl bootout gui/$(id -u)/com.elabidi.glassmonitor.login 2>/dev/null
rm -f ~/Library/LaunchAgents/com.elabidi.glassmonitor.login.plist
pkill -x GlassMonitor; rm -rf "$HOME/Applications/Glass Monitor.app" "$HOME/Library/Application Support/GlassMonitor"
defaults delete com.elabidi.glassmonitor
```

## Using it

- Click the pill to expand; ⌥⌘M toggles from anywhere. Drag it to move it (any screen); position is
  remembered. Right-click for settings (pill items, opacity, click-through, hide in full screen,
  hide from screen sharing, runaway & leak alerts, open at login, move to screen, minimize to screen edge,
  hide to menu bar, quit, shut down). The top of the menu and the panel footer show Glass Monitor's own cost:
  CPU (incl. its ps/lsof/top/nettop helpers) and memory footprint, matching Activity Monitor.
- Pill buttons: `»` minimizes it to a rounded card with the pill items in a 2-column grid (`minimized` default;
  click to restore). The card and the pill each remember their own position (`cardX/cardY` vs `anchorX/anchorY`);
  "Snap to Top-Right" resets both. Both may be dragged over the menu bar and the Dock; the expanded panel stays
  inside the visible area. An alert shows the full pill.
- Eye button (pill, card, or "Hide to Menu Bar"): hides the pill into a menu bar icon, a mini colour version of
  the app icon (`hidden` default). Monitoring, history and alerts keep running. Click the icon or press ⌥⌘M to
  bring it back; right-click it for Show / Open Panel / Shut Down. The status item only exists while hidden.
- Power button (click twice: the first click turns it red) / "Shut Down": quits and removes the login agent, so
  it stays off after a restart. Opening the app again (Spotlight) turns Open at Login back on (`shutDown`
  default). Plain Quit stays quit until next login.
- Graph range picker 30m / 2h / 12h / 1d (`graphRange` default): each keeps 150 averaged points, saved once a
  minute and on quit to `~/Library/Application Support/GlassMonitor/graphs.json`; time the app wasn't running
  is stored as NaN and drawn as a gap. Hover a graph for the time and value of a point; CPU and Memory points
  also name the top app at that moment.
- Energy tab: per-app Energy Impact from `top` (cached 6 s) plus a battery strip (time left, health, cycles).
  Network tab: Wi-Fi signal / link rate / IP strip (CoreWLAN; SSID needs Location permission, so it shows
  "Wi-Fi"). Dev tab: right-click a server to free its port, force-kill it, or open / copy its URL.
- Extra alerts: memory pressure at "warning" for 3 min (max once an hour, names the biggest app) and startup
  disk under 15 GB free (max every 6 h, opens the Clean tab).
- Sensors row under the status line: average CPU and GPU temperature, fan speed ("Fans off" when idle),
  battery health and cycle count (from `system_profiler -json SPPowerDataType`, refreshed every 30 min).
  The battery status shows time left / time to full. "TEMP" can be added to the pill.
- "Alert When…" (right-click menu): memory %, swap GB, disk %, CPU °C limits. Defaults: swap 8 GB,
  disk 95%, others off. Each fires once and re-arms after the value drops back.
- History tab: 1h / 6h / 24h / 7d chart of CPU and memory. Hover a minute to see which apps were
  using it, click to pin; with nothing selected the list is the range average.
- Memory-leak alert: a process grows ≥500 MB and ≥50% over an hour with every 10-minute average rising.
  Same banner/notification as runaway CPU (Quit / Ignore; ignoring applies to both).
- Dev tab, Laravel section: every folder with an `artisan` file under ~/Documents, ~/Projects, ~/Sites,
  ~/code, ~/dev, ~/src, ~/Developer, ~/Herd (depth 6); counts ERROR/CRITICAL/ALERT/EMERGENCY entries in
  `storage/logs/**/*.log` from the last 24 h (line format and JSON/ECS format; newest 4 MB of each log).
  Hover: Open Log, Restart (the project's running compose containers). Rescans every 5 min.
- Debug launch args: `--expanded`, `--tab=cpu|memory|disk|network|energy|history|dev|clean`, `--test-alert`,
  `--register-login`, `--unregister-login`, `--shut-down`. `--tab` also takes `energy`.

## Code map (`Sources/`)

| File | What |
|---|---|
| `main.swift` | `FloatingPanel` (borderless non-activating NSPanel), Carbon hotkey, `AppDelegate` (placement, drag, click-through, full-screen hiding), app entry |
| `LoginItem.swift` | Per-user launch agent (login + crash restart), migration from old SMAppService items, single-instance logic |
| `History.swift` | SQLite store (`~/Library/Application Support/GlassMonitor/history.sqlite`, 7-day retention) + `Timeline` model |
| `HistoryView.swift` | History tab (Swift Charts, hover/pin) |
| `Stats.swift` | CPU ticks, memory/swap/pressure, disk space & I/O, GPU, network, battery power/time/health (Mach/sysctl/IOKit) |
| `Sensors.swift` | Temperatures and fans from the SMC (`AppleSMC` IOKit user client; no public API exists) |
| `Processes.swift` | `ps` sampling, per-process disk/net rates and Energy Impact (`top`), app grouping, icon cache |
| `Network.swift` | Wi-Fi link (CoreWLAN) and interface IPs (`getifaddrs`) for the Network tab strip |
| `Monitor.swift` | `ObservableObject` model, 1.5 s tick, per-minute history recording, kill/dev/clean actions |
| `Alerts.swift` | Runaway-CPU and memory-leak detectors + notifications (Quit / Ignore actions) |
| `DevTools.swift` | Docker, Laravel log scanner, listening ports (`lsof`), disk-cache cleaner |
| `Shell.swift` | Process runner, admin commands via AppleScript, system tools |
| `Prefs.swift` | UserDefaults-backed settings |
| `Components.swift`, `ListViews.swift`, `RootView.swift` | SwiftUI views and formatting |
| `../Icon/` | App icon: `make-icon.swift` draws it, `AppIcon.icns` is what `build.sh` bundles (regenerate with `swift Icon/make-icon.swift Icon/AppIcon.icns`) |

## Lessons already learned — don't regress these

- **No looping/per-tick SwiftUI animations behind the glass** (animated ring trims, `.numericText`,
  animated list reorders, `.clipShape`): they forced software re-rendering at ~24% CPU.
- **Disk-space query (`volumeAvailableCapacityForImportantUsage`) is expensive** — only every 20 ticks.
- **Counters can go backwards** (a disk/disk image ejected): skip the sample. They can also be garbage near
  `UInt64.max` (a process's rusage disk bytes), so add counters with `&+` — a plain `+` overflow traps and kills the app. All number formatting
  goes through `safe()` in `Components.swift`; converting a huge/NaN Double to `Int64` crashes.
- **Docker cleanup is `image prune -af` + `builder prune -af` only** — never `system prune`, which
  deletes stopped compose containers. Cleanup moves files to the Trash, never deletes permanently.
- The launch agent uses `KeepAlive.SuccessfulExit = false`: crash → relaunch in ~1–2 s; Quit → stays quit
  until next login. Keep `claimSingleInstance()` so a Finder launch doesn't create a second pill.
- **Don't go back to `SMAppService.agent` / `.mainApp`.** build.sh replaces the bundle on every build and
  SMAppService then can't spawn it (launchd: `last exit code = 78: EX_CONFIG`, forever). The plain
  `~/Library/LaunchAgents` plist with an absolute path survives rebuilds.
- SMC: keys are enumerated once at launch on a background queue (≈0.4–0.8 s); only `flt ` keys with
  prefixes Tp/Te (CPU), Tg (GPU), F*Ac (fans) are read, ≈8 ms every 6 s. The `Param` struct must stay
  80 bytes with the explicit padding fields, or every call fails.
- History is recorded once a minute from the existing process sample; the chart lives in its own
  `Timeline` ObservableObject so hovering doesn't redraw the whole panel.
- **Helper tools are the expensive part**: `top` (Energy tab) costs ~1 s of CPU per run, so its results are
  cached for 6 s; `nettop` (Network tab) runs every 3 s. Wi-Fi and energy are only read while their tab is open.
- **Graph history can contain NaN** (gaps while the app wasn't running): filter with `isFinite` before
  `max()`/`min()`, and keep the NaN strategy on the graphs.json encoder/decoder.
- Two different range types: `GraphRange` (live tile graphs) and `HistoryRange` (the SQLite History tab).
- `LoginItem.migrate()` also catches the old bundled `com.elabidi.glassmonitor.agent` when launchd still has it
  loaded but SMAppService reports it missing (the rebuilt bundle no longer contains its plist); it boots it out
  and enables the plain agent instead, so Open at Login survives the upgrade.
- Build is plain `swiftc` with `-swift-version 5`; top-level code must stay in `main.swift`.
