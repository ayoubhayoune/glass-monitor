#!/bin/zsh
# Builds Glass Monitor and installs it to ~/Applications, then (re)launches it.
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Applications/Glass Monitor.app"
pkill -x GlassMonitor 2>/dev/null || true

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -target arm64-apple-macos26.0 Sources/*.swift -o "$APP/Contents/MacOS/GlassMonitor"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Glass Monitor</string>
    <key>CFBundleIdentifier</key><string>com.elabidi.glassmonitor</string>
    <key>CFBundleExecutable</key><string>GlassMonitor</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# App icon (Spotlight, Finder, Login Items). Regenerate with: swift Icon/make-icon.swift Icon/AppIcon.icns
mkdir -p "$APP/Contents/Resources"
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Login + crash-restart agent, registered by the app via SMAppService.agent.
mkdir -p "$APP/Contents/Library/LaunchAgents"
cat > "$APP/Contents/Library/LaunchAgents/com.elabidi.glassmonitor.agent.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.elabidi.glassmonitor.agent</string>
    <key>BundleProgram</key><string>Contents/MacOS/GlassMonitor</string>
    <key>AssociatedBundleIdentifiers</key><array><string>com.elabidi.glassmonitor</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
open "$APP"
echo "Installed and launched: $APP"
