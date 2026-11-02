# Glass Monitor

A Liquid Glass system monitor for macOS 26 (Tahoe). A small glass pill floats on your screen with live
CPU, GPU, RAM, swap, disk, network and temperature. Click it to see what is slowing your Mac down, and
quit it in one click.

It uses the native macOS 26 glass effect, so it looks like part of the system rather than a menu-bar
add-on.

## Features

### The pill

- Live **CPU, GPU, RAM, swap, disk, network** and **temperature** readings with colored rings
  (green → orange → red). Choose which ones to show.
- **Drag it anywhere**, on any screen; its position is remembered. Snap back to the top-right from the menu.
- **⌥⌘M** opens and closes the panel from any app.
- **Opacity** 50–100%, **click-through** mode (hold ⌥ to interact), **hidden in full-screen apps** and
  **hidden from screen sharing and recordings** (both on by default).

- **Minimize to a small card**: the `»` button turns the pill into a rounded card with your readings in a
  grid. Drag it anywhere, even over the menu bar or the Dock; click it to bring the pill back.
- **Hide to the menu bar**: the eye button hides the pill and puts a small Glass Monitor icon in the menu bar.
  Monitoring and alerts keep running; click the icon or press ⌥⌘M to bring it back.
- **Shut down**: the power button (click twice) closes Glass Monitor and keeps it off, even after a restart,
  until you open it again from Spotlight.
- Its own cost is always visible: the panel footer and the right-click menu show Glass Monitor's CPU and memory.

### Overview

- **Status line**: memory pressure, thermal state (Cool → Throttling), power draw, battery % and
  time left or time to full.
- **Sensors line**: average CPU and GPU temperature, fan speed ("Fans off" when idle),
  battery health and cycle count (the same figures System Information shows).
- **Six live graphs**: CPU (user / system), GPU, memory, swap and compressed memory, disk read/write
  speed and free space, network down/up. Switch between the last **30 minutes, 2 hours, 12 hours or day**;
  the graphs survive restarts (time the app wasn't running shows as a gap). **Hover a graph** to see the time and
  value of any point, and for CPU and memory, which app was on top then.

### Processes (CPU, Memory, Disk, Network, Energy tabs)

- Top processes ranked by CPU, memory, disk activity or network traffic.
- **Grouped by app**: all of Chrome's helpers count as one Chrome, with a row you can expand.
  Or list every single process.
- **Quit, Force Quit** or **kill as admin** (asks for your password) for processes owned by the system.
  Core system processes (kernel_task, WindowServer, launchd, loginwindow) are protected.
- Network tab: a Wi-Fi strip with signal quality, link speed and IP address.

### Energy

- Apps ranked by **Energy Impact**, the same figure as Activity Monitor's Energy tab.
- Battery strip: charge, time left, health and cycle count.

### History

- Records **one sample a minute for 7 days**, kept in a local SQLite database.
- Chart of CPU and memory for the last **1 hour, 6 hours, 24 hours or 7 days**.
- **Hover any moment** to see which apps were using CPU and memory then; click to pin it.
  With nothing selected, it shows each app's average CPU and highest memory over the range.

### Alerts

Shown in the pill and as macOS notifications with **Quit** / **Ignore** buttons where it makes sense.

- **Runaway CPU**: a process above 80% CPU for 2 minutes.
- **Memory leak**: a process that grows by 500 MB and 50% over an hour, rising the whole time.
- **Critical memory pressure**, with the biggest app named, and an earlier heads-up when pressure stays at
  "warning" for 3 minutes (at most once an hour).
- **Startup disk under 15 GB free** (at most every 6 hours), with a button to the Clean tab.
- **Your own limits** (right-click → Alert When…): memory %, swap GB, disk %, CPU temperature.
  Each alert fires once and fires again only after the value drops back below the limit.

### Dev

- **Laravel**: finds every project with an `artisan` file and counts the errors logged in the last
  24 hours (Laravel's line format and JSON logs). Shows the latest error; open the log or restart the
  project's Docker containers in one click.
- **Docker**: all containers with their Compose project, CPU and memory; start, stop, restart.
- **Listening ports**: every local server (Node, PHP, Docker…) with its ports; open in the browser or kill it.
  Right-click one to free its port, force-kill it, or copy its URL.

### Clean

Shows how much space each developer cache uses and frees it in one click. Files go to the **Trash**,
never deleted permanently.

- Xcode DerivedData, iOS Device Support, Simulator caches, unavailable simulators
- Homebrew, npm, Yarn, pnpm, Composer and pip caches
- Docker unused images and build cache (never your containers or volumes)
- `node_modules` folders in your projects, biggest first
- Shortcuts to review Xcode Archives and the Trash

### Tools menu

Free Up Memory, Restart Spotlight Indexing, Flush DNS Cache, Restart Finder, Restart Dock and
Open Activity Monitor.

### Reliability and cost

- **Open at Login**, with automatic restart within about 2 seconds if it ever crashes. Quitting it yourself
  keeps it closed until your next login.
- Only one copy runs at a time.
- About **1% CPU** while collapsed. Docker, port and log scans only run while the Dev tab is open.

## Privacy

Everything stays on your Mac. Glass Monitor has no network code of its own, sends nothing anywhere,
and stores its history only in `~/Library/Application Support/GlassMonitor/`.

## Requirements

- macOS 26 (Tahoe) or later on Apple Silicon
- The Swift toolchain: Xcode or the Command Line Tools (`xcode-select --install`)

## Install

```bash
git clone https://github.com/medab123/glass-monitor.git
cd glass-monitor
./build.sh
```

This builds and launches `~/Applications/Glass Monitor.app`. Then right-click the pill →
**Open at Login**.

The first time you open the Dev tab, macOS asks for access to your Documents folder (to read Laravel
logs). Click **Allow**.

Temperatures and fan speeds come from the Mac's System Management Controller (the same source Stats
and iStat Menus use), because macOS has no public API for them.

## Uninstall

```bash
launchctl bootout gui/$(id -u)/com.elabidi.glassmonitor.login 2>/dev/null
rm -f ~/Library/LaunchAgents/com.elabidi.glassmonitor.login.plist
pkill -x GlassMonitor
rm -rf ~/Applications/Glass\ Monitor.app ~/Library/Application\ Support/GlassMonitor
defaults delete com.elabidi.glassmonitor
```

## For developers

Plain SwiftUI + AppKit, Swift Charts and SQLite, built with `swiftc` (no Xcode project).
[CLAUDE.md](CLAUDE.md) has the code map and the lessons learned (what not to change and why).
