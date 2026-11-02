# Glass Monitor — instructions for Claude

Glass Monitor is a small macOS menu-less agent app: a Liquid Glass pill floating at the top-right of
the screen with live CPU / GPU / RAM / swap / disk / network, which expands into a panel listing the
processes eating resources (with Quit / Force Quit / admin kill), Docker containers, listening ports
and a developer-cache cleaner. Plain SwiftUI + AppKit, built with `swiftc` (no Xcode project).

## Reinstall (what the user wants when they hand you this folder)

1. Check the requirements:
   - macOS 26 (Tahoe) or later, Apple Silicon (`uname -m` → `arm64`).
   - Swift toolchain: `swiftc --version` (Xcode or Command Line Tools). If missing, ask the user to run
     `xcode-select --install` themselves (it opens a system dialog).
2. Build and install:
   ```bash
   ./build.sh
   ```
   This compiles `Sources/*.swift`, creates `~/Applications/Glass Monitor.app` (Info.plist + bundled
   launch agent), ad-hoc codesigns it and launches it. It kills any running copy first.
3. Turn on "Open at Login" (also gives crash auto-restart):
   ```bash
   pkill -x GlassMonitor; open "$HOME/Applications/Glass Monitor.app" --args --register-login
   ```
   (Kill first: a second copy started outside launchd exits immediately without registering.)
   Registering starts the launchd copy, which replaces the one `open` started.
   macOS may show a "Background item added" notification — that's expected. The item appears in
   System Settings → General → Login Items as an agent.
4. Verify:
   - `pgrep -lx GlassMonitor` shows exactly one process.
   - `launchctl print gui/$(id -u)/com.elabidi.glassmonitor.agent | grep -E 'state|pid'` → running.
   - CPU cost: `top -l 2 -pid $(pgrep -x GlassMonitor) -stats cpu` should be ≈0.3–0.6% collapsed.
   - The pill is hidden from screenshots by default ("Hide from Screen Sharing"), so a blank
     `screencapture` is normal. To check visually, ask the user to look, or temporarily run
     `defaults write com.elabidi.glassmonitor hideFromSharing -bool false` and restart the app
     (set it back to `true` afterwards).

## Uninstall

First have the user untick "Open at Login" in the pill's right-click menu (this unregisters the
agent), then:
```bash
pkill -x GlassMonitor; rm -rf "$HOME/Applications/Glass Monitor.app"; defaults delete com.elabidi.glassmonitor
```

## Using it

- Click the pill to expand; ⌥⌘M toggles from anywhere. Drag it to move it (any screen); position is
  remembered. Right-click for settings (pill items, opacity, click-through, hide in full screen,
  hide from screen sharing, runaway alerts, open at login, move to screen, minimize to screen edge, quit,
  shut down). **Quit** stays quit until next login; **Shut Down** (also the ⏻ icon in the pill, panel header and
  edge card — click twice: the first click turns it red) also unregisters the login agent, and opening the
  app again (Finder/Spotlight) turns Open at Login back on (`shutDown` default).
- The `»` button on the pill minimizes it to a rounded card docked on the right screen edge showing the pill
  items in a 2-column grid (`minimized` default). Click to restore; drag it anywhere — the card and the pill each
  remember their own position (`cardX/cardY` vs `anchorX/anchorY`). "Snap to Top-Right" resets both. An alert
  shows the full pill.
- The eye icon (pill, panel header, edge card, or "Hide to Menu Bar") hides the pill into a menu bar icon (a mini
  colour version of the app icon; `hidden` default). Monitoring, history and alerts keep running. Click the menu bar
  icon or press ⌥⌘M to bring it back; right-click it for Show / Open Panel / Shut Down. The status item only
  exists while hidden.
- Tabs: CPU, Memory, Disk, Network (Wi-Fi signal/link/IP strip), Energy (per-app Energy Impact from `top`,
  plus battery %, time left, health, cycles), Dev (right-click a server to free its port / copy its URL), Clean.
- Status strip: memory pressure, thermal state with CPU/GPU °C, fan rpm, power.
- Hover a graph to see the time and value of that point; CPU and Memory points also name the top app.
- Alerts (all behind "Runaway Process Alerts"): runaway process, memory pressure critical, memory pressure at
  "warning" for 3 min (max once an hour), startup disk under 15 GB free (max every 6 h, opens the Clean tab).
- Graph ranges: 30m / 2h / 12h / 1d (`historyRange` default). Each keeps 150 averaged points. History is
  saved once a minute and on quit to `~/Library/Application Support/Glass Monitor/history.json`;
  time the app wasn't running is stored as NaN and drawn as a gap.
- The footer and the top of the right-click menu show Glass Monitor's own cost: CPU (incl. the ps/lsof
  helpers it runs) and memory footprint, matching Activity Monitor.
- Debug launch args: `--expanded`, `--tab=cpu|memory|disk|network|dev|clean`, `--test-alert`,
  `--register-login`, `--shut-down`.

## Code map (`Sources/`)

| File | What |
|---|---|
| `main.swift` | `FloatingPanel` (borderless non-activating NSPanel), Carbon hotkey, `AppDelegate` (placement, drag, click-through, full-screen hiding), app entry |
| `LoginItem.swift` | `SMAppService.agent` login item + single-instance logic |
| `Stats.swift` | CPU ticks, memory/swap/pressure, disk space & I/O, GPU, network, battery (Mach/sysctl/IOKit) |
| `Processes.swift` | `ps` sampling, per-process disk/net rates, app grouping, icon cache |
| `Monitor.swift` | `ObservableObject` model, 1.5 s tick, histories, kill/dev/clean actions |
| `Alerts.swift` | Runaway-process detector + notifications (Quit / Ignore actions) |
| `DevTools.swift` | Docker, listening ports (`lsof`), disk-cache cleaner |
| `Sensors.swift` | CPU/GPU temperatures (private IOHID API via `dlsym`, SMC fallback for GPU), fan rpm (SMC), Wi-Fi/IP (CoreWLAN, `getifaddrs`) |
| `Shell.swift` | Process runner, admin commands via AppleScript, system tools |
| `Prefs.swift` | UserDefaults-backed settings |
| `Components.swift`, `ListViews.swift`, `RootView.swift` | SwiftUI views and formatting |
| `../Icon/` | App icon: `make-icon.swift` draws it, `AppIcon.icns` is what `build.sh` bundles (regenerate with `swift Icon/make-icon.swift Icon/AppIcon.icns`) |

## Lessons already learned — don't regress these

- **No looping/per-tick SwiftUI animations behind the glass** (animated ring trims, `.numericText`,
  animated list reorders, `.clipShape`): they forced software re-rendering at ~24% CPU.
- **Disk-space query (`volumeAvailableCapacityForImportantUsage`) is expensive** — only every 20 ticks.
- **Helper tools are the expensive part**: `top` (Energy tab) costs ~1 s of CPU per run, so its results are
  cached for 6 s; `nettop` (Network tab) runs every 3 s. The footer's self-usage figure includes these helpers.
  Sensors, Wi-Fi and energy are only read while the panel is open.
- **Sensor names differ per chip**: this M1 Pro's HID sensors are only `PMU tdie*` (no GPU entry), so GPU °C
  comes from SMC keys (`Tg05`, `Tg0D`, `Tg0L` …). SSID is nil without Location permission — that's expected.
- **History can contain NaN** (gaps while the app wasn't running): filter with `isFinite` before
  `max()`/`min()`, and keep the NaN strategy on the history JSON encoder/decoder.
- **Counters can go backwards** (a disk/disk image ejected): skip the sample. They can also be garbage near
  `UInt64.max` (a process's rusage disk bytes), so add counters with `&+` — a plain `+` overflow traps and kills the app. All number formatting
  goes through `safe()` in `Components.swift`; converting a huge/NaN Double to `Int64` crashes.
- **Docker cleanup is `image prune -af` + `builder prune -af` only** — never `system prune`, which
  deletes stopped compose containers. Cleanup moves files to the Trash, never deletes permanently.
- The launch agent uses `KeepAlive.SuccessfulExit = false`: crash → relaunch in ~1 s; Quit → stays quit
  until next login. Keep `claimSingleInstance()` so a Finder launch doesn't create a second pill.
- Build is plain `swiftc` with `-swift-version 5`; top-level code must stay in `main.swift`.
